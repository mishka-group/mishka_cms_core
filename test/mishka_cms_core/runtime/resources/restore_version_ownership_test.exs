# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.RestoreVersionOwnershipTest do
  @moduledoc """
  A restore copies a version back onto the record it was taken of — and only onto that record.

  One rule across the seven runtime resources that keep versions, so it is asserted once, over all
  seven, rather than copied into each resource's own file. A master is a user whose `site_id` is nil;
  a site user, whatever it holds, restores only its own site's records, and only from their own
  versions.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  require Ash.Query

  alias MishkaCmsCore.Runtime.{
    Component,
    ErrorPage,
    JsHook,
    Layout,
    Media,
    MediaCategory,
    Page,
    Stylesheet
  }

  @moduletag :unit

  @resources [
    {Layout, &__MODULE__.layout/1},
    {Page, &__MODULE__.page/1},
    {ErrorPage, &__MODULE__.error_page/1},
    {Component, &__MODULE__.component/1},
    {JsHook, &__MODULE__.js_hook/1},
    {Media, &__MODULE__.media/1},
    {MediaCategory, &__MODULE__.media_category/1}
  ]

  # The three that restore without a tenant check of their own: they are global-capable, and their
  # `:restore_version` used to treat a missing tenant as a master.
  @global_capable [Layout, Component, JsHook]

  def layout(site_id), do: create_layout!(site_id: site_id)
  def page(site_id), do: create_page!(site_id: site_id)
  def error_page(site_id), do: create_error_page!(site_id: site_id)
  def component(site_id), do: create_component!(site_id: site_id)
  def js_hook(site_id), do: create_js_hook!(site_id: site_id)
  def media(site_id), do: create_media!(site_id: site_id)
  def media_category(site_id), do: create_media_category!(site_id: site_id)

  def stylesheet(site_id) do
    Stylesheet
    |> Ash.Changeset.for_create(
      :master_create,
      %{
        name: "sheet-#{System.unique_integer([:positive])}",
        kind: :custom,
        content: ".x { color: red; }",
        site_id: site_id,
        active: true
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp versions_of(resource, record) do
    resource
    |> Module.concat(Version)
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(version_source_id == ^record.id)
    |> Ash.read!(authorize?: false)
  end

  defp reload(resource, record) do
    resource
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(id == ^record.id)
    |> Ash.read_one!(authorize?: false)
  end

  # A record read through a bypass read carries no tenant, so a write built from it has none either —
  # unlike one the factory hands back, which remembers the site it was created under.
  defp untenanted(resource, record) do
    loaded = reload(resource, record)
    assert is_nil(loaded.__metadata__[:tenant])
    loaded
  end

  defp restore(record, version, opts) do
    actor = Keyword.get(opts, :actor)

    record
    |> Ash.Changeset.for_update(:restore_version, %{version_id: version.id}, opts)
    |> Ash.update(actor: actor)
  end

  setup do
    site_a = create_site!()
    site_b = create_site!()

    %{
      site_a: site_a,
      site_b: site_b,
      star_a: create_user_with_permissions!(["*"], site_id: site_a.id),
      master: create_user_with_permissions!(["*"])
    }
  end

  for {resource, factory} <- @resources do
    @resource resource
    @factory factory
    @label resource |> Module.split() |> List.last()

    describe "#{@label} :restore_version" do
      test "refuses a version of another site's record, even for a site user holding every permission",
           context do
        mine = @factory.(context.site_a.id)
        theirs = @factory.(context.site_b.id)
        [their_version | _] = versions_of(@resource, theirs)

        assert {:error, _refused} =
                 restore(mine, their_version, tenant: context.site_a.id, actor: context.star_a)

        assert reload(@resource, mine).name == mine.name
      end

      test "refuses a version of another record even when the system restores it", context do
        mine = @factory.(context.site_a.id)
        theirs = @factory.(context.site_b.id)
        [their_version | _] = versions_of(@resource, theirs)

        assert {:error, _refused} =
                 restore(mine, their_version, tenant: context.site_a.id, authorize?: false)

        assert reload(@resource, mine).name == mine.name
      end

      if Ash.Resource.Info.calculation(resource, :version_preview) do
        test "a preview shows the record's own version and no other record's", context do
          mine = @factory.(context.site_a.id)
          theirs = @factory.(context.site_b.id)
          [their_version | _] = versions_of(@resource, theirs)
          [own_version | _] = versions_of(@resource, mine)

          preview = fn version ->
            @resource
            |> reload(mine)
            |> Ash.load!([version_preview: %{version_id: version.id}], authorize?: false)
            |> Map.fetch!(:version_preview)
          end

          assert preview.(their_version) == nil
          assert %{"name" => name} = preview.(own_version)
          assert name == mine.name
        end
      end

      test "restores the record's own version and keeps its site", context do
        mine = @factory.(context.site_a.id)
        [own_version | _] = versions_of(@resource, mine)

        assert {:ok, restored} =
                 restore(mine, own_version, tenant: context.site_a.id, actor: context.star_a)

        assert restored.site_id == context.site_a.id
      end
    end
  end

  # THE ROUTED WRAPPERS read and restore as the system once they have decided whose record it is, so
  # that decision must come from the actor: a site user naming another site as its tenant acts on
  # nothing, whatever it holds.
  @preview_argument %{
    Layout => :layout_id,
    Page => :page_id,
    ErrorPage => :error_page_id,
    Component => :component_id,
    JsHook => :js_hook_id,
    Media => :media_id,
    MediaCategory => :category_id
  }

  defp rename!(record, tenant) do
    record
    |> Ash.Changeset.for_update(:update, %{name: "renamed-#{System.unique_integer([:positive])}"},
      tenant: tenant,
      authorize?: false
    )
    |> Ash.update!(authorize?: false)
  end

  defp run_wrapper(resource, action, arguments, actor, tenant) do
    resource
    |> Ash.ActionInput.for_action(action, arguments, actor: actor, tenant: tenant)
    |> Ash.run_action()
  end

  for {resource, factory} <- @resources do
    @resource resource
    @factory factory
    @label resource |> Module.split() |> List.last()
    @record_argument Map.fetch!(@preview_argument, resource)

    describe "#{@label} :preview_version and :restore_version_api" do
      test "a site user naming another site as its tenant previews and restores nothing",
           context do
        theirs = @factory.(context.site_b.id)
        [version | _] = versions_of(@resource, theirs)
        renamed = rename!(theirs, context.site_b.id)

        assert {:error, _refused} =
                 run_wrapper(
                   @resource,
                   :preview_version,
                   %{@record_argument => theirs.id, version_id: version.id},
                   context.star_a,
                   context.site_b.id
                 )

        assert {:error, _refused} =
                 run_wrapper(
                   @resource,
                   :restore_version_api,
                   %{id: theirs.id, version_id: version.id},
                   context.star_a,
                   context.site_b.id
                 )

        assert reload(@resource, theirs).name == renamed.name
      end

      test "a site user previews and restores its own site's record", context do
        mine = @factory.(context.site_a.id)
        [version | _] = versions_of(@resource, mine)

        assert {:ok, _preview} =
                 run_wrapper(
                   @resource,
                   :preview_version,
                   %{@record_argument => mine.id, version_id: version.id},
                   context.star_a,
                   context.site_a.id
                 )

        assert {:ok, _restored} =
                 run_wrapper(
                   @resource,
                   :restore_version_api,
                   %{id: mine.id, version_id: version.id},
                   context.star_a,
                   context.site_a.id
                 )
      end

      test "a master previews and restores any site's record through its tenant", context do
        theirs = @factory.(context.site_b.id)
        [version | _] = versions_of(@resource, theirs)

        assert {:ok, _preview} =
                 run_wrapper(
                   @resource,
                   :preview_version,
                   %{@record_argument => theirs.id, version_id: version.id},
                   context.master,
                   context.site_b.id
                 )

        assert {:ok, _restored} =
                 run_wrapper(
                   @resource,
                   :restore_version_api,
                   %{id: theirs.id, version_id: version.id},
                   context.master,
                   context.site_b.id
                 )
      end
    end
  end

  for resource <- @global_capable do
    @resource resource
    @factory @resources |> List.keyfind(resource, 0) |> elem(1)
    @label resource |> Module.split() |> List.last()

    describe "#{@label} :restore_version without a tenant" do
      test "a site user restores no other site's record", context do
        theirs = untenanted(@resource, @factory.(context.site_b.id))
        [own_version | _] = versions_of(@resource, theirs)

        assert {:error, _refused} = restore(theirs, own_version, actor: context.star_a)
      end

      test "a site user restores no other site's record when it is the actor only at run time",
           context do
        theirs = untenanted(@resource, @factory.(context.site_b.id))
        [own_version | _] = versions_of(@resource, theirs)

        assert {:error, _refused} =
                 theirs
                 |> Ash.Changeset.for_update(:restore_version, %{version_id: own_version.id},
                   actor: context.master
                 )
                 |> Ash.update(actor: context.star_a)
      end

      test "a master restores any site's record", context do
        theirs = untenanted(@resource, @factory.(context.site_b.id))
        [own_version | _] = versions_of(@resource, theirs)

        assert {:ok, _restored} = restore(theirs, own_version, actor: context.master)
      end

      # NOT A SITE USER IS NOT A MASTER: an actor that is no user, or no actor on a call made as a
      # user, restores nothing — not even under the record's own site as the tenant.
      test "an actor that is not a user restores nothing, even under the record's own site",
           context do
        mine = @factory.(context.site_a.id)
        [version | _] = versions_of(@resource, mine)

        for actor <- [%{id: Ecto.UUID.generate()}, nil] do
          refute Ash.Changeset.for_update(mine, :restore_version, %{version_id: version.id},
                   actor: actor,
                   tenant: context.site_a.id,
                   authorize?: true
                 ).valid?
        end
      end

      test "the system and a master restore under the record's own site", context do
        mine = @factory.(context.site_a.id)
        [version | _] = versions_of(@resource, mine)

        for opts <- [[authorize?: false], [actor: context.master]] do
          assert Ash.Changeset.for_update(
                   mine,
                   :restore_version,
                   %{version_id: version.id},
                   [tenant: context.site_a.id] ++ opts
                 ).valid?
        end
      end
    end
  end

  # A VERSION IS A COPY OF ITS RECORD, so who reads it follows who reads the record: a master any
  # site's, a site user its own site's — and the shared records' where the resource has them — through
  # whichever read it asks, `:read_any` included. System reads pass `authorize?: false`.
  @versioned @resources ++ [{Stylesheet, &__MODULE__.stylesheet/1}]
  @shared_capable [Layout, Component, JsHook, Stylesheet]

  defp version_ids_read_by(resource, record, actor) do
    resource
    |> Module.concat(Version)
    |> Ash.Query.for_read(:read_any, %{}, actor: actor)
    |> Ash.Query.filter(version_source_id == ^record.id)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, versions} -> Enum.map(versions, & &1.id)
      {:error, _refused} -> []
    end
  end

  for {resource, factory} <- @versioned do
    @resource resource
    @factory factory
    @label resource |> Module.split() |> List.last()

    describe "#{@label}.Version reads" do
      test "a site user reads no other site's versions, even through :read_any", context do
        theirs = @factory.(context.site_b.id)
        assert [_ | _] = versions_of(@resource, theirs)

        assert version_ids_read_by(@resource, theirs, context.star_a) == []
      end

      test "a site user reads its own site's versions", context do
        mine = @factory.(context.site_a.id)

        assert [_ | _] = version_ids_read_by(@resource, mine, context.star_a)
      end

      test "a master reads any site's versions", context do
        theirs = @factory.(context.site_b.id)

        assert [_ | _] = version_ids_read_by(@resource, theirs, context.master)
      end

      test "no user reads none", context do
        mine = @factory.(context.site_a.id)

        assert version_ids_read_by(@resource, mine, nil) == []
      end

      test "a site user who may not read the record reads none of its versions", context do
        mine = @factory.(context.site_a.id)
        nobody = create_user!(site_id: context.site_a.id)

        assert version_ids_read_by(@resource, mine, nobody) == []
      end

      if resource in @shared_capable do
        test "a site user reads a shared record's versions, as it reads the record", context do
          shared = @factory.(nil)

          assert [_ | _] = version_ids_read_by(@resource, shared, context.star_a)
        end
      end
    end
  end
end
