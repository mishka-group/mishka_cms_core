defmodule MishkaCmsCoreWeb.Test.AdminLanguageTest do
  @moduledoc """
  The language an admin reads the dashboard in, and the line under every admin page.

  The language is chosen in the topbar's user menu, kept in the session by
  `MishkaCmsCoreWeb.AdminLanguageController`, and spoken by `MishkaCmsCore.Layouts.Nav` on every
  admin page: English until one is chosen. The menu offers the site's own languages and English.

  This suite's backend marks a message the locale has no translation for with `"[<locale>] "`, so a
  word read in a language other than English shows as `"[fa] Sign out"`.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Settings

  @home "/admin/dashboard"
  @pages "/admin/dashboard/runtime/pages"

  setup %{conn: conn} do
    SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()

    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    MishkaCmsCore.DataCase.forget_settings(~w(site.languages), [site.id])
    {:ok, _} = Settings.put("site.languages", ["fa", "de"], site_id: site.id)

    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    conn =
      conn
      |> on_localhost()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:master_mode, true)
      |> AshAuthentication.Plug.Helpers.store_in_session(create_user_with_permissions!(["*"]))

    {:ok, conn: conn, site: site}
  end

  defp on_localhost(conn) do
    conn
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end

  defp close(view) do
    render_async(view, 5_000)
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid, :normal)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
  end

  defp choose(conn, params), do: put(conn, "/admin/language", params)

  describe "the user menu" do
    test "offers the site's languages and English, with English chosen until one is", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, @home)

      for code <- ["fa", "de", "en"] do
        assert has_element?(view, "#admin-language-form button#admin-language-#{code}")
      end

      assert has_element?(view, "#admin-language-en[aria-current='true']")
      refute has_element?(view, "#admin-language-fa[aria-current='true']")
      assert has_element?(view, "#admin-language-form input[name='return_to'][value='#{@home}']")
      assert has_element?(view, "#topbar-user a[href='/auth/sign-out']", "Sign out")

      assert has_element?(
               view,
               "#topbar-account-settings[href='/admin/dashboard/settings?tab=preferences']"
             )

      close(view)
    end

    test "lists two, the chosen one among them, and the rest behind Show more", %{conn: conn} do
      {:ok, view, _html} = live(conn, @home)

      for code <- ["fa", "en"],
          do: refute(has_element?(view, "#admin-language-rest #admin-language-#{code}"))

      assert has_element?(view, "#admin-language-rest #admin-language-de")
      assert has_element?(view, "#admin-language-more", "Show 1 more")
      assert has_element?(view, "#admin-language-less.hidden")
      close(view)
    end
  end

  describe "choosing a language" do
    test "keeps it, goes back to the page, and the dashboard reads in it", %{conn: conn} do
      conn = choose(conn, %{"language" => "fa", "return_to" => @pages})

      assert redirected_to(conn) == @pages
      assert get_session(conn, Languages.admin_session()) == "fa"

      {:ok, view, _html} = conn |> recycle() |> on_localhost() |> live(@home)

      assert has_element?(view, "#admin-language-fa[aria-current='true']")
      assert has_element?(view, "#topbar-user a[href='/auth/sign-out']", "[fa] Sign out")
      assert has_element?(view, "#admin-language-form", "[fa] Language")
      close(view)
    end

    test "keeps nothing for a language the site does not offer", %{conn: conn} do
      conn = choose(conn, %{"language" => "xx", "return_to" => @pages})

      assert redirected_to(conn) == @pages
      assert get_session(conn, Languages.admin_session()) == nil
    end

    test "sends anything but an admin page back to the dashboard", %{conn: conn} do
      for return_to <- [
            "https://elsewhere.example/admin/x",
            "//elsewhere.example/admin",
            "/admin//elsewhere.example",
            "/en/about",
            nil
          ] do
        conn = choose(conn, %{"language" => "de", "return_to" => return_to})

        assert redirected_to(conn) == @home
      end
    end

    test "leaves the visitor's language alone", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_session(Languages.session(), "de")
        |> choose(%{"language" => "fa", "return_to" => @home})

      assert get_session(conn, Languages.session()) == "de"
      assert get_session(conn, Languages.admin_session()) == "fa"
    end
  end

  describe "the line under every page" do
    test "is the copyright and the credit to Mishka CMS on the core's pages", %{conn: conn} do
      {:ok, view, _html} = live(conn, @home)

      assert has_element?(
               view,
               "#admin-footer a[href='https://mishka.tools/cms'][target='_blank'][rel~='noopener']",
               "Mishka CMS"
             )

      footer = render(element(view, "#admin-footer"))
      assert footer =~ "© #{MishkaCmsCore.Layouts.copyright_years()}"
      assert footer =~ "Powered by"
      close(view)
    end
  end

  describe "MishkaCmsCore.Layouts.copyright_years/1" do
    test "is the first year alone during that year" do
      assert MishkaCmsCore.Layouts.copyright_years(~D[2026-03-01]) == "2026"
    end

    test "runs from the first year to the current one afterwards" do
      assert MishkaCmsCore.Layouts.copyright_years(~D[2027-01-01]) == "2026-2027"
      assert MishkaCmsCore.Layouts.copyright_years(~D[2031-12-31]) == "2026-2031"
    end

    test "defaults to today" do
      assert MishkaCmsCore.Layouts.copyright_years() ==
               MishkaCmsCore.Layouts.copyright_years(Date.utc_today())
    end
  end
end
