# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.ErrorStatusTest do
  @moduledoc """
  The offline page and the default page as entries of a site's Error Page, beside its 404 and 500:
  stored, read back, drafted, compiled and previewed as `:offline` and `:default`, whichever way they
  were spelled on the way in.
  """
  use MishkaCmsCore.DataCase, async: false

  doctest MishkaCmsCore.Runtime.ErrorStatus

  import MishkaCmsCore.Test.Factory

  require Ash.Query

  alias MishkaCmsCore.Runtime.{ErrorAddress, ErrorPage, ErrorPageDraft, ErrorStatus}
  alias MishkaCmsCore.Runtime.RuntimePreview
  alias MishkaCmsCore.Runtime.Compilers.{ErrorCompiler, ModuleCompiler}

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  describe "parse/1" do
    test "reads a code, the offline page and the default page however they are spelled" do
      assert ErrorStatus.parse(404) == 404
      assert ErrorStatus.parse("404") == 404
      assert ErrorStatus.parse(" 500 ") == 500
      assert ErrorStatus.parse(:offline) == :offline
      assert ErrorStatus.parse("offline") == :offline
      assert ErrorStatus.parse(:default) == :default
      assert ErrorStatus.parse("default") == :default
    end

    test "and names nothing for anything else" do
      for other <- ["teapot", "", "404px", nil, :maintenance, 4.04] do
        assert ErrorStatus.parse(other) == nil, "#{inspect(other)} was read as a status"
      end
    end
  end

  test "the Error Page form offers the offline and the default page, then 404 and 500" do
    [offline, default | groups] = ErrorStatus.choices()
    codes = for {_group, options} <- groups, {_label, code} <- options, do: code

    assert elem(offline, 1) == "offline"
    assert elem(default, 1) == "default"
    assert 404 in codes
    assert 500 in codes
  end

  test "a person reads each status by its name" do
    assert ErrorStatus.label(:offline) == "Offline"
    assert ErrorStatus.label(:default) == "Default"
    assert ErrorStatus.label(404) =~ "Not Found"
  end

  describe "an Error Page" do
    setup do
      %{site: create_site!()}
    end

    test "stores the entries the form sends as text, and reads them back as :offline and :default",
         %{site: site} do
      error_page =
        create!(site, [
          %{"status" => "404", "template" => "<p>Not here</p>"},
          %{"status" => "offline", "template" => "<p>Soon</p>"},
          %{"status" => "default", "template" => "<p>Something went wrong</p>"}
        ])

      assert Enum.map(error_page.error_pages, & &1.status) == [404, :offline, :default]

      reread =
        Ash.get!(ErrorPage, error_page.id,
          tenant: site.id,
          authorize?: false,
          load: [:configured_statuses]
        )

      assert Enum.map(reread.error_pages, & &1.status) == [404, :offline, :default]
      assert reread.configured_statuses == [404, :default, :offline]

      %{rows: [[stored]]} =
        @repo.query!("SELECT error_pages FROM error_pages WHERE id = $1", [
          Ecto.UUID.dump!(error_page.id)
        ])

      assert Enum.map(stored, & &1["status"]) == [404, "offline", "default"]
    end

    test "refuses a second entry for a status, naming it, however its status is spelled", %{
      site: site
    } do
      for {status, again} <- [{404, "404"}, {:default, "default"}, {:offline, "offline"}] do
        assert {:error, %Ash.Error.Invalid{errors: [error]}} =
                 create(site, [entry(500), entry(status), entry(again)])

        assert error.field == :error_pages
        assert error.message =~ "Entry 3"
        assert error.message =~ "#{status} page"
      end

      error_page = create!(site, [entry(404), entry(:default)])

      for {action, tenant} <- [update: site.id, master_update: nil] do
        assert {:error, %Ash.Error.Invalid{errors: [%{field: :error_pages}]}} =
                 error_page
                 |> Ash.Changeset.for_update(
                   action,
                   %{error_pages: [entry(404), entry(:default), entry(:default)]},
                   tenant: tenant,
                   authorize?: false
                 )
                 |> Ash.update()
      end
    end

    test "refuses a draft that holds two entries for a status when it is published", %{site: site} do
      draft =
        ErrorPageDraft
        |> Ash.Changeset.for_create(:create, attrs(site, [entry(404), entry(404)]),
          tenant: site.id,
          authorize?: false
        )
        |> Ash.create!()

      assert {:error, %Ash.Error.Invalid{} = error} =
               draft
               |> Ash.Changeset.for_update(:publish, %{}, tenant: site.id, authorize?: false)
               |> Ash.update()

      assert Exception.message(error) =~ "second 404 page"
    end

    # As a row stored before the rule holds them.
    test "stored with two entries for a status is read and edited as before", %{site: site} do
      error_page =
        Ash.Seed.update!(create!(site, [entry(404)]), %{error_pages: [entry(404), entry(404)]})

      held = Ash.get!(ErrorPage, error_page.id, tenant: site.id, authorize?: false)
      assert Enum.map(held.error_pages, & &1.status) == [404, 404]

      assert {:ok, %{priority: 3}} =
               held
               |> Ash.Changeset.for_update(:update, %{priority: 3, error_pages: held.error_pages},
                 tenant: site.id,
                 authorize?: false
               )
               |> Ash.update()
    end

    test "refuses a status that is neither a code nor one of the two names", %{site: site} do
      assert {:error, _invalid} = create(site, [entry("teapot")])
    end

    test "refuses a default entry whose template does not compile, naming it", %{site: site} do
      for status <- [404, :default] do
        assert {:error, %Ash.Error.Invalid{} = error} =
                 create(site, [%{status: status, template: "<div :foo={@a}>x</div>"}])

        assert Exception.message(error) =~ "The #{status} page"
      end
    end

    test "has its default entry again when a version of it is restored", %{site: site} do
      error_page = create!(site, [entry(404), entry(:default)])

      without =
        error_page
        |> Ash.Changeset.for_update(:update, %{error_pages: [entry(404)]},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

      assert Enum.map(without.error_pages, & &1.status) == [404]

      [_removal, first] =
        Ash.load!(without, :sorted_versions, tenant: site.id, authorize?: false).sorted_versions

      restored =
        without
        |> Ash.Changeset.for_update(:restore_version, %{version_id: first.id},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

      assert Enum.map(restored.error_pages, & &1.status) == [404, :default]
    end

    test "is drafted and published with its offline and default entries", %{site: site} do
      draft =
        ErrorPageDraft
        |> Ash.Changeset.for_create(
          :master_create,
          Map.put(
            attrs(site, [entry(404), entry(:offline), entry(:default)]),
            :site_id,
            site.id
          ),
          authorize?: false
        )
        |> Ash.create!(authorize?: false)

      assert Enum.map(draft.error_pages, & &1.status) == [404, :offline, :default]

      draft
      |> Ash.Changeset.for_update(:master_publish, %{}, authorize?: false)
      |> Ash.update!(authorize?: false)

      error_page =
        ErrorPage
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(site_id == ^site.id)
        |> Ash.read_one!(authorize?: false)

      assert Enum.map(error_page.error_pages, & &1.status) == [404, :offline, :default]
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
    test "round-trips the offline and default entries through the Code tab" do
      entries = [entry(:default), entry(404), entry(:offline)]
      source = RuntimePreview.source(%{error_pages: entries})

      assert source =~ "<!-- offline -->"
      assert source =~ "<!-- default -->"
      assert RuntimePreview.parse_error_pages(source) == entries
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

    # The page answers many codes, so it is drawn with one of them, never with `:default`.
    test "draws the default entry its address asks for, as a code a visitor gets" do
      record = %{
        error_pages: [
          entry(404),
          %{
            status: "default",
            template:
              ~S|<p id="why">{@status + 0}, {Plug.Conn.Status.reason_phrase(@status)}</p>|,
            layout: %{"template" => ~S|<div id="wrap">{@conn.status}{@inner_content}</div>|}
          }
        ]
      }

      html =
        RuntimePreview.inner_html(record, ErrorPage, nil, nil, nil,
          query_params: %{"status" => "default"}
        )

      assert html =~ ~s(<p id="why">403, Forbidden</p>)
      assert html =~ ~s(<div id="wrap">403)
      refute html =~ "Template for 404"

      {document, nil} = RuntimePreview.render_error_document(record, :default)
      assert document =~ "403, Forbidden"
    end

    test "offers the default entry beside the others" do
      record = %{error_pages: [entry(404), entry("default"), entry(:offline)]}

      assert RuntimePreview.error_statuses(record) == [404, :default, :offline]
    end
  end

  defp entry(status), do: %{status: status, template: "<p>Template for #{status}</p>"}

  defp attrs(site, entries),
    do: %{name: "#{site.name} errors", path: ErrorAddress.path(site.name), error_pages: entries}

  defp create!(site, entries) do
    {:ok, error_page} = create(site, entries)
    error_page
  end

  defp create(site, entries) do
    ErrorPage
    |> Ash.Changeset.for_create(:create, attrs(site, entries), tenant: site.id, authorize?: false)
    |> Ash.create()
  end
end
