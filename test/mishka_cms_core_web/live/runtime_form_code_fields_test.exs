# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.RuntimeFormCodeFieldsTest do
  @moduledoc """
  The code of a page, layout, component, error page, JS hook and stylesheet is written on its list's
  Configuration form, by whoever may write the record: each form draws its code fields, and a holder
  of the record's own area (`admin:dashboard:runtime:<section>`) or of `admin:dashboard:code` saves a
  change to them through the form.

  Its own file: the six forms are opened here through the pencil each list draws, as a site admin
  holding one name.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.{Component, ErrorPage, JsHook, Layout, Page, Stylesheet}
  alias MishkaCmsCore.Runtime.States.SiteState

  @await 5_000

  @event %{name: "save", code: "{:noreply, socket}"}
  @info %{name: ":tick", code: "{:noreply, socket}"}
  @helper %{name: "shout", args: "word", code: "String.upcase(word)"}

  setup %{conn: conn} do
    SiteState.clear()
    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    :persistent_term.put(:mishka_installed, true)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    {:ok, conn: conn, site: site, lists: lists(site)}
  end

  # Each list: where it lives, its table, its resource, the name of its area, a record carrying one
  # of every code field, the code controls its form draws, and one code change saved through it with
  # what the record reads back after.
  defp lists(site) do
    n = unique()

    [
      %{
        url: "/admin/dashboard/runtime/pages",
        table: "pages-table",
        resource: Page,
        area: "admin:dashboard:runtime:page",
        record:
          create_page!(
            site_id: site.id,
            name: "form-p-#{n}",
            path: "/form-p-#{n}",
            template: "<p>before</p>",
            events: [@event],
            infos: [@info],
            helpers: [@helper]
          ),
        drawn:
          ~w(form[template] form[events][0][code] form[infos][0][code] form[helpers][0][code]),
        change: %{"template" => "<p>after</p>"},
        saved: & &1.template,
        expected: "<p>after</p>"
      },
      %{
        url: "/admin/dashboard/runtime/layouts",
        table: "layouts-table",
        resource: Layout,
        area: "admin:dashboard:runtime:layout",
        record:
          create_layout!(
            site_id: site.id,
            name: "form-l-#{n}",
            path: "/form-l-#{n}",
            helpers: [@helper]
          ),
        drawn: ~w(form[template] form[helpers][0][code]),
        change: %{"template" => "<main>{@inner_content}</main>"},
        saved: & &1.template,
        expected: "<main>{@inner_content}</main>"
      },
      %{
        url: "/admin/dashboard/runtime/components",
        table: "components-table",
        resource: Component,
        area: "admin:dashboard:runtime:component",
        record:
          create_component!(
            site_id: site.id,
            name: "form-c-#{n}",
            template: "<b>before</b>",
            helpers: [@helper]
          ),
        drawn: ~w(form[template] form[helpers][0][code]),
        change: %{"template" => "<b>after</b>"},
        saved: & &1.template,
        expected: "<b>after</b>"
      },
      %{
        url: "/admin/dashboard/runtime/error-pages",
        table: "error-pages-table",
        resource: ErrorPage,
        area: "admin:dashboard:runtime:error_page",
        record: create_error_page!(site_id: site.id, name: "form-e-#{n}", helpers: [@helper]),
        drawn:
          ~w(form[root_layout_template] form[error_pages][0][template] form[helpers][0][code]),
        change: %{
          "root_layout_template" => "<main>{@inner_content}</main>",
          "error_pages" => %{"0" => %{"template" => "<h1>Gone</h1>"}}
        },
        saved: &{&1.root_layout_template, hd(&1.error_pages).template},
        expected: {"<main>{@inner_content}</main>", "<h1>Gone</h1>"}
      },
      %{
        url: "/admin/dashboard/runtime/js-hooks",
        table: "js-hooks-table",
        resource: JsHook,
        area: "admin:dashboard:runtime:js_hook",
        record: create_js_hook!(site_id: site.id, name: "form-h-#{n}"),
        drawn: ~w(form[content]),
        change: %{"content" => "console.log('after');"},
        saved: & &1.content,
        expected: "console.log('after');"
      },
      %{
        url: "/admin/dashboard/runtime/stylesheets",
        table: "stylesheets-table",
        resource: Stylesheet,
        area: "admin:dashboard:runtime:stylesheet",
        record:
          Ash.create!(
            Stylesheet,
            %{name: "form-s-#{n}", content: ".a { color: red; }", format: :css},
            action: :create,
            tenant: site.id,
            authorize?: false
          ),
        drawn: ~w(form[content]),
        change: %{"content" => ".a { color: blue; }"},
        saved: & &1.content,
        expected: ".a { color: blue; }"
      }
    ]
  end

  defp unique, do: System.unique_integer([:positive])

  defp form_selector(resource),
    do: "#" <> MishkaGervaz.Resource.Info.Form.component_id(resource) <> "-form"

  defp control(resource, name), do: form_selector(resource) <> " textarea[name='#{name}']"

  defp log_in(conn, site, permissions) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, false)
    |> AshAuthentication.Plug.Helpers.store_in_session(
      create_user_with_permissions!(permissions, site_id: site.id)
    )
  end

  # The record's own pencil on its list, which opens the inspector on its Configuration form.
  defp edit(conn, %{url: url, table: table, record: record}) do
    {:ok, view, _html} = live(conn, url)
    render_async(view, @await)

    view
    |> element(~s(##{table} [id$="-#{record.id}"] button[phx-value-event="edit_preview_modal"]))
    |> render_click()

    render_async(view, @await)
    view
  end

  defp stored(%{resource: resource, record: record}),
    do: Ash.get!(resource, record.id, tenant: record.site_id, authorize?: false)

  test "each form draws its code fields, writable, for a holder of the record's area", %{
    conn: conn,
    site: site,
    lists: lists
  } do
    for %{resource: resource, area: area, drawn: drawn} = list <- lists do
      view = conn |> log_in(site, [area]) |> edit(list)

      for name <- drawn do
        assert has_element?(view, control(resource, name)),
               "#{inspect(resource)}'s form does not draw #{name}"

        refute has_element?(view, control(resource, name) <> "[readonly]"),
               "#{inspect(resource)}'s form draws #{name} read-only"
      end
    end
  end

  # `:area` stands for each record's own area.
  for holds <- [:area, "admin:dashboard:code"] do
    @holds holds

    test "a holder of #{if holds == :area, do: "the record's area", else: holds} alone saves a code change through each form",
         %{conn: conn, site: site, lists: lists} do
      for %{resource: resource, change: change, saved: saved, expected: expected} = list <- lists do
        names = [if(@holds == :area, do: list.area, else: @holds)]
        view = conn |> log_in(site, names) |> edit(list)

        view
        |> form(form_selector(resource), %{"form" => change})
        |> render_submit()

        assert saved.(stored(list)) == expected,
               "#{inspect(resource)}: a holder of #{Enum.join(names)} did not save the change"
      end
    end
  end
end
