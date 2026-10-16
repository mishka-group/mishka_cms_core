# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.ErrorStatusTest do
  @moduledoc """
  The offline page as one entry of a site's Error Page, beside its 404 and 500: stored, read back,
  drafted, compiled and previewed as `:offline`, whichever way it was spelled on the way in.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  require Ash.Query

  alias MishkaCmsCore.Runtime.{ErrorAddress, ErrorPage, ErrorPageDraft, ErrorStatus}
  alias MishkaCmsCore.Runtime.RuntimePreview
  alias MishkaCmsCore.Runtime.Compilers.{ErrorCompiler, ModuleCompiler}

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  describe "parse/1" do
    test "reads a code and the offline page however they are spelled" do
      assert ErrorStatus.parse(404) == 404
      assert ErrorStatus.parse("404") == 404
      assert ErrorStatus.parse(" 500 ") == 500
      assert ErrorStatus.parse(:offline) == :offline
      assert ErrorStatus.parse("offline") == :offline
    end

    test "and names nothing for anything else" do
      for other <- ["teapot", "", "404px", nil, :maintenance, 4.04] do
        assert ErrorStatus.parse(other) == nil, "#{inspect(other)} was read as a status"
      end
    end
  end

  test "the Error Page form offers the offline page next to 404 and 500" do
    [offline | groups] = ErrorStatus.choices()
    codes = for {_group, options} <- groups, {_label, code} <- options, do: code

    assert elem(offline, 1) == "offline"
    assert 404 in codes
    assert 500 in codes
  end

  describe "an Error Page" do
    setup do
      %{site: create_site!()}
    end

    test "stores the offline entry the form sends as text, and reads it back as :offline", %{
      site: site
    } do
      error_page =
        create!(site, [
          %{"status" => "404", "template" => "<p>Not here</p>"},
          %{"status" => "offline", "template" => "<p>Soon</p>"}
        ])

      assert Enum.map(error_page.error_pages, & &1.status) == [404, :offline]

      reread = Ash.get!(ErrorPage, error_page.id, tenant: site.id, authorize?: false)
      assert Enum.map(reread.error_pages, & &1.status) == [404, :offline]

      %{rows: [[stored]]} =
        @repo.query!("SELECT error_pages FROM error_pages WHERE id = $1", [
          Ecto.UUID.dump!(error_page.id)
        ])

      assert Enum.map(stored, & &1["status"]) == [404, "offline"]
    end

    test "refuses a status that is neither a code nor the offline page", %{site: site} do
      assert {:error, _invalid} =
               ErrorPage
               |> Ash.Changeset.for_create(:create, attrs(site, [entry("teapot")]),
                 tenant: site.id,
                 authorize?: false
               )
               |> Ash.create()
    end

    test "is drafted and published with its offline entry", %{site: site} do
      draft =
        ErrorPageDraft
        |> Ash.Changeset.for_create(
          :master_create,
          Map.put(attrs(site, [entry(404), entry(:offline)]), :site_id, site.id),
          authorize?: false
        )
        |> Ash.create!(authorize?: false)

      assert Enum.map(draft.error_pages, & &1.status) == [404, :offline]

      draft
      |> Ash.Changeset.for_update(:master_publish, %{}, authorize?: false)
      |> Ash.update!(authorize?: false)

      error_page =
        ErrorPage
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(site_id == ^site.id)
        |> Ash.read_one!(authorize?: false)

      assert Enum.map(error_page.error_pages, & &1.status) == [404, :offline]
    end
  end

  test "the compiled Error Page answers :offline, whichever way the entry spelled it" do
    module = Module.concat(__MODULE__, "Errors#{System.unique_integer([:positive])}")

    {:ok, ^module, _diagnostics} =
      %{
        title: "errors",
        error_module: module,
        site: "offline-site",
        error_pages: [
          %{status: 404, template: "<p>Not here</p>"},
          %{status: "offline", template: ~S|<p id="soon">Soon, {@status}</p>|}
        ]
      }
      |> ErrorCompiler.build_module()
      |> ModuleCompiler.compile_module()

    html =
      %{assigns: %{}} |> module.render(:offline) |> Phoenix.HTML.Safe.to_iodata() |> to_string()

    assert html =~ ~s(<p id="soon">Soon, offline</p>)
    assert html =~ "Down for maintenance"
  end

  describe "the preview" do
    test "round-trips the offline entry through the Code tab" do
      source = RuntimePreview.source(%{error_pages: [entry(404), entry(:offline)]})

      assert source =~ "<!-- offline -->"

      assert Enum.map(RuntimePreview.parse_error_pages(source), & &1.status) == [404, :offline]
    end

    test "draws the offline entry its address asks for" do
      record = %{error_pages: [entry(404), entry(:offline)]}

      html =
        RuntimePreview.inner_html(record, ErrorPage, nil, nil, nil,
          query_params: %{"status" => "offline"}
        )

      assert html =~ "Template for offline"
      refute html =~ "Template for 404"
    end
  end

  defp entry(status), do: %{status: status, template: "<p>Template for #{status}</p>"}

  defp attrs(site, entries),
    do: %{name: "#{site.name} errors", path: ErrorAddress.path(site.name), error_pages: entries}

  defp create!(site, entries) do
    ErrorPage
    |> Ash.Changeset.for_create(:create, attrs(site, entries), tenant: site.id, authorize?: false)
    |> Ash.create!()
  end
end
