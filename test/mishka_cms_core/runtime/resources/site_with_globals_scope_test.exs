# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.SiteWithGlobalsScopeTest do
  @moduledoc """
  The reads that answer "this site's rows plus the shared ones" — `:for_tenant_with_globals` and its
  single-row twin, the builder's `:for_editor` reads, a stylesheet's `:for_compiler` and a setting's
  own — decide whose rows they show from WHO IS ASKING, never from a missing tenant.

  A master is a user whose `site_id` is nil. A site user, whatever it holds, reads its own site and
  the shared rows and nothing else: not with no tenant, not by naming another site in `site_id`, not
  by passing another site's tenant. A call made as the system (`authorize?: false`, no actor) keeps
  the master's reach; a call made as nobody reads nothing.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.{
    Component,
    JsHook,
    Layout,
    PageComment,
    Setting,
    Snippet,
    Stylesheet
  }

  @moduletag :unit

  def layout(site_id), do: create_layout!(site_id: site_id)
  def component(site_id), do: create_component!(site_id: site_id)
  def js_hook(site_id), do: create_js_hook!(site_id: site_id)

  def stylesheet(site_id) do
    Stylesheet
    |> Ash.Changeset.for_create(
      :master_create,
      %{
        name: "scope-sheet-#{System.unique_integer([:positive])}",
        kind: :custom,
        content: ".scope { color: red; }",
        site_id: site_id,
        active: true
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  @listing [
    {Layout, &__MODULE__.layout/1},
    {Component, &__MODULE__.component/1},
    {JsHook, &__MODULE__.js_hook/1},
    {Stylesheet, &__MODULE__.stylesheet/1}
  ]

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

  defp ids(resource, action, args, build_opts, read_opts) do
    resource
    |> Ash.Query.for_read(action, args, build_opts)
    |> Ash.read(read_opts)
    |> case do
      {:ok, %{results: rows}} -> MapSet.new(rows, & &1.id)
      {:ok, rows} when is_list(rows) -> MapSet.new(rows, & &1.id)
      {:error, _refused} -> MapSet.new()
    end
  end

  for {resource, factory} <- @listing do
    @resource resource
    @factory factory
    @label resource |> Module.split() |> List.last()

    describe "#{@label} :for_tenant_with_globals" do
      setup context do
        %{
          mine: @factory.(context.site_a.id),
          theirs: @factory.(context.site_b.id),
          shared: @factory.(nil)
        }
      end

      test "a site user holding every permission and no tenant reads its own site and the shared rows",
           context do
        read =
          ids(@resource, :for_tenant_with_globals, %{}, [actor: context.star_a],
            actor: context.star_a
          )

        assert MapSet.member?(read, context.mine.id)
        assert MapSet.member?(read, context.shared.id)
        refute MapSet.member?(read, context.theirs.id)
      end

      test "a site user naming another site reads nothing of it", context do
        read =
          ids(
            @resource,
            :for_tenant_with_globals,
            %{site_id: context.site_b.id},
            [actor: context.star_a],
            actor: context.star_a
          )

        refute MapSet.member?(read, context.theirs.id)
      end

      test "a site user passing another site's tenant reads nothing of it", context do
        read =
          ids(
            @resource,
            :for_tenant_with_globals,
            %{},
            [actor: context.star_a, tenant: context.site_b.id],
            actor: context.star_a
          )

        refute MapSet.member?(read, context.theirs.id)
      end

      test "a site user who is the actor only when the read runs still reads nothing of another site",
           context do
        read =
          ids(
            @resource,
            :for_tenant_with_globals,
            %{site_id: context.site_b.id},
            [actor: context.master],
            actor: context.star_a
          )

        refute MapSet.member?(read, context.theirs.id)
      end

      test "a master reads every site with no tenant, and one site when it names one", context do
        every =
          ids(@resource, :for_tenant_with_globals, %{}, [actor: context.master],
            actor: context.master
          )

        assert MapSet.subset?(
                 MapSet.new([context.mine.id, context.theirs.id, context.shared.id]),
                 every
               )

        one =
          ids(
            @resource,
            :for_tenant_with_globals,
            %{site_id: context.site_b.id},
            [actor: context.master],
            actor: context.master
          )

        assert MapSet.member?(one, context.theirs.id)
        assert MapSet.member?(one, context.shared.id)
        refute MapSet.member?(one, context.mine.id)
      end

      test "the system reads every site", context do
        read =
          ids(@resource, :for_tenant_with_globals, %{}, [authorize?: false], authorize?: false)

        assert MapSet.member?(read, context.theirs.id)
      end

      test "a read asked for as a user with no user in it reads nothing without a tenant",
           context do
        read =
          ids(@resource, :for_tenant_with_globals, %{}, [authorize?: true], authorize?: false)

        refute MapSet.member?(read, context.mine.id)
        refute MapSet.member?(read, context.theirs.id)
      end

      test "the single-row read gives a site user no other site's row", context do
        assert {:error, _gone} =
                 Ash.get(@resource, context.theirs.id,
                   action: :get_for_tenant_with_globals,
                   actor: context.star_a
                 )
      end
    end
  end

  describe "Stylesheet :for_compiler" do
    test "a site user naming another site compiles none of its sheets", context do
      theirs = stylesheet(context.site_b.id)

      read =
        ids(
          Stylesheet,
          :for_compiler,
          %{site_id: context.site_b.id},
          [actor: context.star_a],
          actor: context.star_a
        )

      refute MapSet.member?(read, theirs.id)
    end

    test "the compiler, as the system, reads the site it names", context do
      theirs = stylesheet(context.site_b.id)

      read =
        ids(Stylesheet, :for_compiler, %{site_id: context.site_b.id}, [authorize?: false],
          authorize?: false
        )

      assert MapSet.member?(read, theirs.id)
    end
  end

  describe "Setting :for_tenant_with_globals" do
    defp setting!(site_id, key) do
      Setting
      |> Ash.Changeset.for_create(
        :master_set,
        %{key: key, value: %{"value" => key}, site_id: site_id},
        authorize?: false
      )
      |> Ash.create!()
    end

    test "a site user naming another site reads none of its settings", context do
      theirs = setting!(context.site_b.id, "scope.test.theirs")

      read =
        ids(
          Setting,
          :for_tenant_with_globals,
          %{site_id: context.site_b.id},
          [actor: context.star_a],
          actor: context.star_a
        )

      refute MapSet.member?(read, theirs.id)
    end

    test "a master naming a site reads its settings", context do
      theirs = setting!(context.site_b.id, "scope.test.master")

      read =
        ids(
          Setting,
          :for_tenant_with_globals,
          %{site_id: context.site_b.id},
          [actor: context.master],
          actor: context.master
        )

      assert MapSet.member?(read, theirs.id)
    end
  end

  describe "the builder's :for_editor reads" do
    setup context do
      page_b = create_page!(site_id: context.site_b.id)

      note =
        PageComment
        |> Ash.Changeset.for_create(
          :create,
          %{body: "site B's note", type: :information, section: :page, document_id: page_b.id},
          tenant: context.site_b.id,
          authorize?: false
        )
        |> Ash.create!()

      snippet =
        Snippet
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "site-b-snippet",
            source: "<p>site B</p>",
            section: :page,
            scope: :shared,
            site_id: context.site_b.id
          },
          authorize?: false
        )
        |> Ash.create!()

      %{page_b: page_b, note: note, snippet: snippet}
    end

    test "a site user reads no note of another site, by site_id or by tenant", context do
      args = %{site_id: context.site_b.id, section: :page, document_id: context.page_b.id}

      by_argument =
        ids(PageComment, :for_editor, args, [actor: context.star_a], actor: context.star_a)

      by_tenant =
        ids(
          PageComment,
          :for_editor,
          args,
          [actor: context.star_a, tenant: context.site_b.id],
          actor: context.star_a
        )

      refute MapSet.member?(by_argument, context.note.id)
      refute MapSet.member?(by_tenant, context.note.id)
    end

    test "nor through the system read the builder's own thread list makes", context do
      read =
        ids(
          PageComment,
          :for_editor,
          %{site_id: context.site_b.id, section: :page, document_id: context.page_b.id},
          [actor: context.star_a, authorize?: false],
          actor: context.star_a,
          authorize?: false
        )

      refute MapSet.member?(read, context.note.id)
    end

    test "a site user reads no snippet of another site", context do
      read =
        ids(
          Snippet,
          :for_editor,
          %{site_id: context.site_b.id, section: :page},
          [actor: context.star_a],
          actor: context.star_a
        )

      refute MapSet.member?(read, context.snippet.id)
    end

    test "a master reads another site's note and snippet by naming the site", context do
      notes =
        ids(
          PageComment,
          :for_editor,
          %{site_id: context.site_b.id, section: :page, document_id: context.page_b.id},
          [actor: context.master],
          actor: context.master
        )

      snippets =
        ids(
          Snippet,
          :for_editor,
          %{site_id: context.site_b.id, section: :page},
          [actor: context.master],
          actor: context.master
        )

      assert MapSet.member?(notes, context.note.id)
      assert MapSet.member?(snippets, context.snippet.id)
    end
  end

  # THE PREPARATION NARROWS BY WHO BUILT THE QUERY; THE POLICY HOLDS WHO RUNS IT. A query built as
  # the system, or as one actor and run as another, is scoped by the first — so each read that uses
  # the preparation must also be held, when it runs, by a policy on the actor's own site.
  describe "every read that scopes by who built it" do
    defp site_with_globals?(%{preparation: {module, _opts}}),
      do: module == MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals

    defp site_with_globals?(_preparation), do: false

    defp applies_to_reads?(%{condition: conditions}) do
      Enum.all?(conditions, fn
        {Ash.Policy.Check.ActionType, opts} -> :read in List.wrap(opts[:type])
        {Ash.Policy.Check.Static, opts} -> opts[:result] == true
        _other -> false
      end)
    end

    defp masters_only_by_identity?(%{policies: checks}) do
      Enum.any?(checks, fn
        %{
          type: :authorize_if,
          check_module: Ash.Policy.Check.ActorAttributeEquals,
          check_opts: opts
        } ->
          opts[:attribute] == :site_id and Keyword.has_key?(opts, :value) and is_nil(opts[:value])

        _other ->
          false
      end)
    end

    defp held_by_identity?(resource) do
      resource
      |> Ash.Policy.Info.policies()
      |> Enum.any?(&(applies_to_reads?(&1) and masters_only_by_identity?(&1)))
    end

    test "is held by a policy on the actor when it runs" do
      scoped =
        for resource <- Ash.Domain.Info.resources(MishkaCmsCore.Runtime),
            action <- Ash.Resource.Info.actions(resource),
            action.type == :read,
            Enum.any?(action.preparations, &site_with_globals?/1),
            do: {resource, action.name}

      assert length(scoped) >= 11, "found #{length(scoped)}; the scan proves nothing"

      for {resource, action} <- scoped do
        assert held_by_identity?(resource),
               "#{inspect(resource)}.#{action} uses SiteWithGlobals with no read policy on the actor"
      end
    end
  end
end
