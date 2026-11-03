# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.AdminSiteIconsTest do
  @moduledoc """
  `MishkaCmsCore.Runtime.AdminSiteIcons`: an admin page names the icons of the site it is served
  on, read from the page a browser gets (the test root layout fires `RootHtml.MetaTags` as a host's
  does), and the plugin leaves any other page's head as it was.

  `async: false` — the site cache, the settings cache and the icon cache are process-global.
  """
  use MishkaCmsCore.ConnCase, async: false

  import MishkaCmsCore.Test.Admin,
    only: [build_conn_for_host: 1, cache_site: 1, create_admin: 2, log_in: 2]

  import MishkaCmsCore.Test.Factory, only: [create_site!: 1]

  alias MishkaCmsCore.Runtime.AdminSiteIcons
  alias MishkaCmsCore.Runtime.SiteIcon
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Settings

  @path "/admin/dashboard"

  setup do
    SiteState.clear()
    snapshot = SettingsState.snapshot()

    home = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    other = create_site!(name: "other", host: "other.test", active: true)
    cache_site(home)
    cache_site(other)
    :persistent_term.put(:mishka_installed, true)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
      SettingsState.restore(snapshot)
      SiteIcon.forget(home.id)
      SiteIcon.forget(other.id)
    end)

    %{home: home, other: other}
  end

  describe "an admin page" do
    test "names the favicon its site's setting holds", %{home: home} do
      {:ok, _} =
        Settings.put("site.favicon", "https://cdn.example.com/home.png", site_id: home.id)

      html = admin_page(home)

      assert hrefs(html, "icon") == ["https://cdn.example.com/home.png"]
    end

    test "names the favicon as the address says it, whatever the address holds", %{home: home} do
      address = "https://cdn.example.com/it's.png?a=1&b=2"
      {:ok, _} = Settings.put("site.favicon", address, site_id: home.id)

      html = admin_page(home)

      assert hrefs(html, "icon") == [address]
      assert html |> head_links() |> Enum.count() == 1
    end

    test "names no icon when its site has none", %{home: home} do
      html = admin_page(home)

      assert hrefs(html, "icon") == []
      assert hrefs(html, "apple-touch-icon") == []
      assert html =~ "<title>MishkaCmsCore test</title>"
    end

    test "names the home-screen icon too when its site has a picture of its own", %{home: home} do
      dir = Path.join(System.tmp_dir!(), "admin_site_icons_#{System.unique_integer([:positive])}")
      Application.put_env(:mishka_cms_core, :media_static_dir, dir)

      on_exit(fn ->
        Application.delete_env(:mishka_cms_core, :media_static_dir)
        File.rm_rf(dir)
      end)

      address = "/uploads/#{home.id}/media/brand/icon.png"
      file = Path.join(dir, address)
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, png())
      {:ok, _} = Settings.put("site.favicon", address, site_id: home.id)

      html = admin_page(home)

      assert hrefs(html, "icon") == [address]
      assert [touch] = hrefs(html, "apple-touch-icon")
      assert touch == SiteIcon.url(home.id, 180)
    end

    test "never names another site's favicon", %{home: home, other: other} do
      {:ok, _} =
        Settings.put("site.favicon", "https://cdn.example.com/home.png", site_id: home.id)

      assert hrefs(admin_page(home), "icon") == ["https://cdn.example.com/home.png"]
      assert hrefs(admin_page(other), "icon") == []

      {:ok, _} =
        Settings.put("site.favicon", "https://cdn.example.com/other.png", site_id: other.id)

      assert hrefs(admin_page(home), "icon") == ["https://cdn.example.com/home.png"]
      assert hrefs(admin_page(other), "icon") == ["https://cdn.example.com/other.png"]
    end

    test "names the favicon of the host a master in master mode is on", %{
      home: home,
      other: other
    } do
      {:ok, _} =
        Settings.put("site.favicon", "https://cdn.example.com/home.png", site_id: home.id)

      {:ok, _} =
        Settings.put("site.favicon", "https://cdn.example.com/other.png", site_id: other.id)

      html =
        "localhost"
        |> build_conn_for_host()
        |> log_in(create_admin("master@example.com", nil))
        |> get(@path)
        |> html_response(200)

      assert hrefs(html, "icon") == ["https://cdn.example.com/home.png"]
    end
  end

  describe "call/1" do
    test "adds to the head it is handed and keeps what is there", %{home: home} do
      {:ok, _} =
        Settings.put("site.favicon", "https://cdn.example.com/home.png", site_id: home.id)

      tag = ~s(<meta name="author" content="someone">\n)

      assert {:reply, %{html: html, assigns: assigns}} =
               AdminSiteIcons.call(%{html: tag, assigns: admin_assigns(home)})

      assert String.starts_with?(html, tag)
      assert hrefs(html, "icon") == ["https://cdn.example.com/home.png"]
      assert assigns == admin_assigns(home)
    end

    test "hands back a head that is not an admin page's as it came", %{home: home} do
      {:ok, _} =
        Settings.put("site.favicon", "https://cdn.example.com/home.png", site_id: home.id)

      site = %{id: home.id, name: home.name}

      for assigns <- [
            %{current_site: site, runtime_page: true},
            %{current_site: site, admin_css: false},
            %{current_site: site},
            %{admin_css: true},
            %{admin_css: true, current_site: nil},
            %{admin_css: true, current_site: %{name: "no id"}},
            %{}
          ] do
        state = %{html: "<meta>", assigns: assigns}
        assert AdminSiteIcons.call(state) == {:reply, state}, inspect(assigns)
      end
    end

    test "hands back the head as it came for a site with no icon", %{home: home} do
      state = %{html: "<meta>", assigns: admin_assigns(home)}

      assert AdminSiteIcons.call(state) == {:reply, state}
    end

    test "gives one site no icon of another's", %{home: home, other: other} do
      {:ok, _} =
        Settings.put("site.favicon", "https://cdn.example.com/home.png", site_id: home.id)

      state = %{html: "", assigns: admin_assigns(other)}

      assert AdminSiteIcons.call(state) == {:reply, state}
    end
  end

  defp admin_assigns(site), do: %{admin_css: true, current_site: %{id: site.id, name: site.name}}

  # The document an admin of `site` is sent, on the site's own address.
  defp admin_page(site) do
    admin = create_admin("admin#{System.unique_integer([:positive])}@example.com", site.id)

    site.host
    |> build_conn_for_host()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, false)
    |> AshAuthentication.Plug.Helpers.store_in_session(admin)
    |> get(@path)
    |> html_response(200)
  end

  defp head_links(html),
    do: html |> LazyHTML.from_document() |> LazyHTML.query("head link")

  defp hrefs(html, rel) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s(head link[rel="#{rel}"]))
    |> LazyHTML.attribute("href")
  end

  defp png, do: 16 |> Image.new!(16, color: :purple) |> Image.write!(:memory, suffix: ".png")
end
