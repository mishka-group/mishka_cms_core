defmodule MishkaCmsCore.Runtime.Resources.RuntimeAreaPoliciesTest do
  @moduledoc """
  Who reads the data behind the Pages, Layouts, Components, Error Pages, JS Hooks and Stylesheets
  screens: anyone under the surface the request came from, so a dashboard admin of any section reads
  every list, its versions and its drafts. Someone with no admin name reads nothing. Who writes it is
  `MishkaCmsCore.Runtime.RuntimeSectionRulesTest`'s.
  """
  use MishkaCmsCore.DataCase, async: false

  require Ash.Query

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.{
    Component,
    ErrorPage,
    ErrorPageDraft,
    JsHook,
    Layout,
    LayoutDraft,
    Page,
    PageDraft,
    Stylesheet
  }

  @moduletag :capture_log

  setup do
    {:ok, site: create_site!()}
  end

  defp holder(names, site), do: create_user_with_permissions!(List.wrap(names), site_id: site.id)

  defp n, do: System.unique_integer([:positive])

  defp read(resource, actor, site),
    do: Ash.read(resource, actor: actor, tenant: site.id, page: false)

  @documents [
    {Page, "admin:dashboard:runtime:error_page"},
    {Layout, "admin:dashboard:runtime:page"},
    {Component, "admin:dashboard:runtime:layout"},
    {ErrorPage, "admin:dashboard:runtime:component"}
  ]

  for {resource, other} <- @documents do
    describe "#{inspect(resource)}" do
      @resource resource
      @other other

      test "a holder of #{other} reads the list", %{site: site} do
        record = create!(@resource, site)

        assert {:ok, rows} = read(@resource, holder(@other, site), site)
        assert Enum.any?(rows, &(&1.id == record.id))
      end

      test "the version fields are read by a holder of #{other}", %{site: site} do
        record = create!(@resource, site)
        reader = holder(@other, site)

        assert {:ok, loaded} = Ash.load(record, [:version_count], actor: reader, tenant: site.id)
        assert is_integer(loaded.version_count)
      end

      test "someone with no admin name reads nothing", %{site: site} do
        create!(@resource, site)

        assert {:ok, []} = read(@resource, holder([], site), site) |> empty_on_forbidden()
      end
    end
  end

  defp create!(Page, site), do: create_page!(site_id: site.id)
  defp create!(Layout, site), do: create_layout!(site_id: site.id)
  defp create!(Component, site), do: create_component!(site_id: site.id)
  defp create!(ErrorPage, site), do: create_error_page!(site_id: site.id)

  defp empty_on_forbidden({:error, %Ash.Error.Forbidden{}}), do: {:ok, []}
  defp empty_on_forbidden(result), do: result

  describe "a page's versions" do
    test "are read by another section", %{site: site} do
      page = create_page!(site_id: site.id)
      Ash.update!(page, %{title: "Second"}, tenant: site.id, authorize?: false)

      assert {:ok, [_ | _]} =
               Page.Version
               |> Ash.Query.for_read(:read_any, %{},
                 actor: holder("admin:dashboard:runtime:layout", site)
               )
               |> Ash.Query.filter(version_source_id == ^page.id)
               |> Ash.read(page: false)
    end
  end

  describe "the version fields of a record" do
    test "are read by anyone under the surface", %{site: site} do
      page = create_page!(site_id: site.id)
      reader = holder("admin:dashboard:runtime:js_hook", site)

      assert {:ok, loaded} = Ash.load(page, [:version_count], actor: reader, tenant: site.id)
      assert is_integer(loaded.version_count)
    end
  end

  describe "drafts" do
    for {draft, other, attrs} <- [
          {PageDraft, "admin:dashboard:runtime:layout", %{title: "D", template: "<div>x</div>"}},
          {LayoutDraft, "admin:dashboard:runtime:page",
           %{template: "<main>{@inner_content}</main>"}},
          {ErrorPageDraft, "admin:dashboard:runtime:page", %{}}
        ] do
      @draft draft
      @draft_other other
      @draft_attrs attrs

      test "#{inspect(draft)} is read by #{other}", %{site: site} do
        m = n()
        attrs = Map.merge(%{name: "d#{m}", path: "/d#{m}"}, @draft_attrs)
        system = Ash.create!(@draft, attrs, action: :create, tenant: site.id, authorize?: false)

        assert {:ok, rows} = read(@draft, holder(@draft_other, site), site)
        assert Enum.any?(rows, &(&1.id == system.id))
      end
    end
  end

  describe "JS hooks and stylesheets" do
    test "a hook's version fields are read by any dashboard admin", %{site: site} do
      hook = create_js_hook!(site_id: site.id)
      reader = holder("admin:dashboard:runtime:page", site)

      assert {:ok, loaded} = Ash.load(hook, [:version_count], actor: reader, tenant: site.id)
      assert is_integer(loaded.version_count)
    end

    test "any dashboard admin reads both lists", %{site: site} do
      hook = create_js_hook!(site_id: site.id)
      sheet = stylesheet!(site)
      reader = holder("admin:dashboard:runtime:page", site)

      assert {:ok, hooks} = read(JsHook, reader, site)
      assert Enum.any?(hooks, &(&1.id == hook.id))
      assert {:ok, sheets} = read(Stylesheet, reader, site)
      assert Enum.any?(sheets, &(&1.id == sheet.id))
    end
  end

  defp stylesheet!(site) do
    Stylesheet
    |> Ash.Changeset.for_create(
      :create,
      %{name: "s#{n()}", content: ".a { color: red; }", format: :css},
      tenant: site.id,
      authorize?: false
    )
    |> Ash.create!()
  end
end
