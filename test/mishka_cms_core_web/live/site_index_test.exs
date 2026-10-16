# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.SiteIndexTest do
  @moduledoc """
  The Sites page as a master uses it: the master site offers no way to switch it off or archive it,
  since every master signs in through it; any other site offers both.

  The resource refuses the same writes (`MasterSiteStays`); this is what the page offers.
  `async: false` — the install flag and `SiteState` are process-global.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.LiveSockets
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, ViewerState}
  alias MishkaCmsCore.Settings

  @path "/admin/dashboard/runtime/sites"

  setup %{conn: conn} do
    SiteState.clear()
    master_site = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    other_site = create_site!(active: true)

    for site <- [master_site, other_site] do
      :ok =
        SiteState.save(%{
          id: site.id,
          name: site.name,
          host: site.host,
          priority: site.priority,
          active: site.active,
          master: site.master
        })
    end

    :persistent_term.put(:mishka_installed, true)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    master = create_user_with_permissions!(["*"], site_id: nil)

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:master_mode, true)
      |> AshAuthentication.Plug.Helpers.store_in_session(master)

    {:ok, conn: conn, master: master, master_site: master_site, other_site: other_site}
  end

  defp open(conn) do
    {:ok, view, _html} = live(conn, @path)
    render_async(view)
    view
  end

  defp row(site), do: "#sites-table_sites-#{site.id}"

  # The modal reads its site after it opens, so the render that shows its buttons is the one after that
  # read lands.
  defp details(view, site) do
    send(view.pid, {:row_action, "show_site_modal", %{"id" => site.id}})
    _handled = :sys.get_state(view.pid)
    render_async(view)
  end

  test "the master site's row offers no Delete, another site's does", %{
    conn: conn,
    master_site: master_site,
    other_site: other_site
  } do
    view = open(conn)

    assert has_element?(view, row(master_site))
    refute has_element?(view, ~s(#{row(master_site)} button[title="Delete"]))
    assert has_element?(view, ~s(#{row(other_site)} button[title="Delete"]))
  end

  # A 1280px screen leaves about 950px for the table beside the sidebar. Every column, Actions
  # included, keeps its title and buttons in at most 930px of it, and none can shrink to nothing.
  # The Actions column is as wide as its widest row of 30px buttons, 4px apart, with 16px of
  # padding either side.
  test "the table fits a laptop screen beside the sidebar", %{conn: conn} do
    view = open(conn)
    html = view |> render() |> LazyHTML.from_fragment()

    [style] =
      html
      |> LazyHTML.query("#sites-table_sites-grid")
      |> LazyHTML.attribute("style")

    {tracks, ["max-content"]} =
      ~r/grid-template-columns:\s*(.+?);/
      |> Regex.run(style, capture: :all_but_first)
      |> List.first()
      |> String.split(~r/\s+(?![^(]*\))/, trim: true)
      |> Enum.split(-1)

    buttons =
      html
      |> LazyHTML.query(~s(#sites-table_sites [data-role="gervaz-row-actions"]))
      |> Enum.map(&(&1 |> LazyHTML.query("button, a") |> Enum.count()))
      |> Enum.max()

    actions = buttons * 30 + (buttons - 1) * 4 + 32

    for width <- ["minmax(185px,1.7fr)", "minmax(135px,1.6fr)", "minmax(105px,1.2fr)"] do
      assert width in tracks, "#{width} is not one of the tracks #{inspect(tracks)}"
    end

    refute Enum.any?(tracks, &String.starts_with?(&1, "minmax(0")),
           "a track can shrink to nothing: #{inspect(tracks)}"

    minimum =
      tracks
      |> Enum.map(fn track ->
        [px] = Regex.run(~r/^(?:minmax\()?(\d+)px/, track, capture: :all_but_first)
        String.to_integer(px)
      end)
      |> Enum.sum()
      |> Kernel.+(actions)

    assert minimum <= 930, "the table needs #{minimum}px: #{inspect(tracks)} and #{actions}px"
  end

  test "the master site's details offer no Deactivate, another site's do", %{
    conn: conn,
    master_site: master_site,
    other_site: other_site
  } do
    view = open(conn)

    refute details(view, master_site) =~ ~s(phx-click="site_deactivate")
    assert details(view, other_site) =~ ~s(phx-click="site_deactivate")
  end

  # A NARROW SCREEN PUTS THE BUTTONS UNDER THE TITLE, NOT OVER IT. They are a wrapping group of their
  # own in a wrapping row beside the icon and title, and the close button sits outside that row.
  test "a site's details keep their buttons in a wrapping group apart from the title", %{
    conn: conn,
    other_site: other_site
  } do
    view = open(conn)
    details(view, other_site)

    head = "#site-details-modal [data-role=modal-head]"
    row = "#{head} > .flex-wrap"

    assert has_element?(view, "#{row} > [data-role=modal-head-title]", other_site.name)
    refute has_element?(view, "#{head} [data-role=modal-head-title] button")

    for event <- ~w(site_deactivate site_set_master site_modal_set_tab) do
      assert has_element?(
               view,
               ~s(#{row} > [data-role=modal-head-actions].flex-wrap > button[phx-click="#{event}"])
             )
    end

    assert has_element?(view, ~s(#{head} > button[aria-label="close"]))
    refute has_element?(view, ~s(#{row} button[aria-label="close"]))
  end

  # MASTERS SIGN IN ON THE MASTER SITE'S ADDRESS ALONE, so moving the flag moves where they sign in.
  test "Set Master says where masters will sign in from then on", %{
    conn: conn,
    other_site: other_site
  } do
    view = open(conn)
    details(view, other_site)

    assert has_element?(
             view,
             ~s(button[phx-click="site_set_master"][data-confirm*="masters sign in only at #{other_site.host}"])
           )
  end

  test "a site's details link its robots.txt and sitemap on its own address", %{
    conn: conn,
    other_site: other_site
  } do
    view = open(conn)
    details(view, other_site)
    uri = MishkaCmsCore.TestEndpoint.struct_url()
    origin = "#{uri.scheme}://#{other_site.host}:#{uri.port}"

    assert has_element?(view, ~s(#site-details-robots[href="#{origin}/robots.txt"]))
    assert has_element?(view, ~s(#site-details-sitemap[href="#{origin}/sitemap.xml"]))
  end

  # AN API-ONLY SITE ANSWERS EVERY PAGE REQUEST WITH ITS 403, these two files included.
  test "an API-only site's details link neither", %{conn: conn} do
    headless = create_site!(active: true, mode: :api_only)
    view = open(conn)
    details(view, headless)

    assert has_element?(view, "#site-details-modal", headless.name)
    refute has_element?(view, "#site-details-robots")
    refute has_element?(view, "#site-details-sitemap")
  end

  test "a Set Master refused says why, in plain words", %{conn: conn} do
    switched_off = create_site!(active: false)

    :ok =
      SiteState.save(%{
        id: switched_off.id,
        name: switched_off.name,
        host: switched_off.host,
        priority: switched_off.priority,
        active: false
      })

    view = open(conn)
    details(view, switched_off)

    assert render_click(view, "site_set_master") =~
             "Masters sign in on the master site&#39;s web pages, so it must be switched on and take web visits."
  end

  describe "a site taken offline" do
    setup %{other_site: other_site} do
      snapshot = SettingsState.snapshot()
      on_exit(fn -> SettingsState.restore(snapshot) end)
      {:ok, _} = Settings.put("cms.offline", true, site_id: other_site.id)
      :ok
    end

    test "is marked in its row by its own switch, and a site that is up is not", %{
      conn: conn,
      master_site: master_site,
      other_site: other_site
    } do
      view = open(conn)

      assert view |> element("#{row(other_site)} #site-offline-#{other_site.id}") |> render() =~
               "Own switch"

      refute has_element?(view, "#site-offline-#{master_site.id}")
    end

    # Global closes the master's own site too; the host's pipeline would let the master through.
    test "is marked in every row by the Global switch", %{
      conn: conn,
      master: master,
      master_site: master_site
    } do
      master = Ash.load!(master, [:permissions], authorize?: false)
      ViewerState.remember(master)
      on_exit(fn -> ViewerState.forget(master.id) end)
      {:ok, _} = Settings.put("cms.offline", true, site_id: nil)

      view =
        conn
        |> Plug.Conn.put_session(:live_socket_id, LiveSockets.live_socket_id(master))
        |> open()

      assert view |> element("#site-offline-#{master_site.id}") |> render() =~ "Global"
    end

    test "has an amber health pill in its details, not the grey an inactive one has", %{
      conn: conn,
      other_site: other_site
    } do
      view = open(conn)

      [class] =
        view
        |> details(other_site)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#site-details-health")
        |> LazyHTML.attribute("class")

      assert class =~ "bg-[#fbf1df]"
      refute class =~ "bg-[#f2f1ec]"
    end
  end
end
