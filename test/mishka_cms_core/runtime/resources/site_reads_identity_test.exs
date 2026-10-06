defmodule MishkaCmsCore.Runtime.Resources.SiteReadsIdentityTest do
  @moduledoc """
  Whose rows a read of a runtime resource shows — decided by the actor when the read runs, whichever
  read it is.

  One rule across every runtime resource that keeps rows per site, so it is asserted once over all
  of them. A master is a user whose `site_id` is nil and reads every site. A site user, whatever it
  holds, reads its own site's rows and the shared ones: not through `:read_any` or `:get_any`, which
  skip tenancy, and not by passing another site's tenant. System reads pass `authorize?: false`.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  require Ash.Query

  alias MishkaCmsCore.Runtime.{
    Component,
    ErrorPage,
    ErrorPageDraft,
    JsHook,
    Layout,
    LayoutDraft,
    Media,
    MediaCategory,
    Page,
    PageComment,
    PageDraft,
    Setting,
    Snippet,
    Stylesheet
  }

  @moduletag :unit

  def row(Layout, site), do: create_layout!(site_id: site.id)
  def row(Component, site), do: create_component!(site_id: site.id)
  def row(JsHook, site), do: create_js_hook!(site_id: site.id)
  def row(Page, site), do: create_page!(site_id: site.id)
  def row(ErrorPage, site), do: create_error_page!(site_id: site.id)
  def row(Media, site), do: create_media!(site_id: site.id)
  def row(MediaCategory, site), do: create_media_category!(site_id: site.id)

  def row(Stylesheet, site) do
    master_create(Stylesheet, %{
      name: "sheet-#{System.unique_integer([:positive])}",
      kind: :custom,
      content: ".x { color: red; }",
      site_id: site.id,
      active: true
    })
  end

  def row(PageDraft, site) do
    page = create_page!(site_id: site.id)
    n = System.unique_integer([:positive])

    PageDraft
    |> Ash.Changeset.for_create(
      :create,
      %{
        source_page_id: page.id,
        name: "Draft #{n}",
        title: "Draft #{n}",
        path: "/draft-#{n}",
        template: "<div></div>"
      },
      tenant: site.id,
      authorize?: false
    )
    |> Ash.create!()
  end

  def row(LayoutDraft, site) do
    n = System.unique_integer([:positive])

    master_create(LayoutDraft, %{
      name: "layout-draft-#{n}",
      path: "/layout-draft-#{n}",
      template: "<body>{@inner_content}</body>",
      site_id: site.id
    })
  end

  def row(ErrorPageDraft, site) do
    n = System.unique_integer([:positive])

    master_create(ErrorPageDraft, %{
      name: "errors-#{n}",
      path: "/errors-#{n}",
      error_pages: [%{status: 404, template: "<h1>Not Found</h1>"}],
      site_id: site.id
    })
  end

  def row(Snippet, site) do
    master_create(Snippet, %{
      name: "snippet-#{System.unique_integer([:positive])}",
      source: "<p>snippet</p>",
      section: :page,
      scope: :shared,
      site_id: site.id
    })
  end

  def row(PageComment, site) do
    PageComment
    |> Ash.Changeset.for_create(
      :create,
      %{body: "a note", type: :information, section: :page},
      tenant: site.id,
      authorize?: false
    )
    |> Ash.create!()
  end

  def row(Setting, site) do
    Setting
    |> Ash.Changeset.for_create(
      :master_set,
      %{
        key: "identity.#{System.unique_integer([:positive])}",
        value: %{"value" => 1},
        site_id: site.id
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp master_create(resource, attrs) do
    resource
    |> Ash.Changeset.for_create(:master_create, attrs, authorize?: false)
    |> Ash.create!()
  end

  @resources [
    Layout,
    Component,
    JsHook,
    Stylesheet,
    Page,
    ErrorPage,
    Media,
    MediaCategory,
    PageDraft,
    LayoutDraft,
    ErrorPageDraft,
    Snippet,
    PageComment,
    Setting
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

  # Narrowed to the two rows under test, so a paginated read answers both on its first page.
  defp read_ids(resource, action, opts, context) do
    ids = [context.mine.id, context.theirs.id]

    resource
    |> Ash.Query.for_read(action, %{}, opts)
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read(opts)
    |> case do
      {:ok, rows} when is_list(rows) -> MapSet.new(rows, & &1.id)
      {:ok, %{results: rows}} -> MapSet.new(rows, & &1.id)
      {:error, _refused} -> MapSet.new()
    end
  end

  for resource <- @resources do
    @resource resource
    @label resource |> Module.split() |> List.last()

    describe "#{@label}" do
      setup context do
        %{mine: row(@resource, context.site_a), theirs: row(@resource, context.site_b)}
      end

      test "a site user holding every permission reads no other site's row through :read_any",
           context do
        read = read_ids(@resource, :read_any, [actor: context.star_a], context)

        assert MapSet.member?(read, context.mine.id)
        refute MapSet.member?(read, context.theirs.id)
      end

      test "a master, and the system, read every site's rows through :read_any", context do
        for opts <- [[actor: context.master], [authorize?: false]] do
          read = read_ids(@resource, :read_any, opts, context)

          assert MapSet.member?(read, context.mine.id)
          assert MapSet.member?(read, context.theirs.id)
        end
      end

      if Ash.Resource.Info.action(resource, :get_any) do
        test "a site user gets no other site's row through :get_any", context do
          refute match?(
                   {:ok, %{}},
                   Ash.get(@resource, context.theirs.id, action: :get_any, actor: context.star_a)
                 )
        end
      end

      if Ash.Resource.Info.primary_action(resource, :read) && resource != Setting do
        test "a site user passing another site's tenant reads none of its rows", context do
          read =
            read_ids(
              @resource,
              :read,
              [actor: context.star_a, tenant: context.site_b.id],
              context
            )

          refute MapSet.member?(read, context.theirs.id)
        end
      end
    end
  end
end
