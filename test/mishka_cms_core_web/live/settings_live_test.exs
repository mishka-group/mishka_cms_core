# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.SettingsLiveTest do
  @moduledoc """
  Real LiveView tests for the settings admin page. A master admin sees the registry's tabs + a scope
  picker (Global + each site), switches tabs/scope, and saves — global writes land globally, a site
  scope writes a per-site override. A tenant admin is NOT redirected: they get the page locked to
  their own site, editing `:site`/`:both` settings while `:global` ones show read-only.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Test.Plugins.{GatedSettingsProvider, ValidatedSettingsProvider}
  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Settings

  require Ash.Query

  @password "Password123!"
  @path "/admin/dashboard/settings"

  setup %{conn: conn} do
    SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()
    Application.put_env(:ash_json_api, MishkaCmsCore.Accounts, router: MishkaCmsWeb.Router)

    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    cache_site(site)
    :persistent_term.put(:mishka_installed, true)

    # The settings cache is process-global ETS, not sandboxed, so start each test from a clean one:
    # a sibling test's write outlives its rolled-back transaction and would read back as a real value.
    SettingsState.refresh()
    Settings.load_definitions()

    snapshot = SettingsState.snapshot()

    on_exit(fn ->
      :persistent_term.erase({Settings, :definitions})
      :persistent_term.erase(:mishka_installed)
      SettingsState.restore(snapshot)
    end)

    # `conn.host` feeds the LiveView socket/origin check; the raw `host` header is what SiteLookupPlug
    # reads (Plug forbids `put_req_header("host", …)`, so set it directly like the plug tests do).
    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    {:ok, conn: conn, site: site}
  end

  defp cache_site(site) do
    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })
  end

  defp permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
        |> Ash.create!()

      {:ok, permission} ->
        permission
    end
  end

  defp create_admin(email, site_id, permission \\ "*") do
    attrs = %{email: email, password: @password, password_confirmation: @password}

    {:ok, user} =
      User
      |> Ash.Changeset.for_create(:register_with_password, attrs, authorize?: false)
      |> then(fn cs -> if site_id, do: Ash.Changeset.set_tenant(cs, site_id), else: cs end)
      |> Ash.create()

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, permission!(permission).id)
    |> Ash.create!(authorize?: false)

    user
  end

  # An admin an offline site lets through: the host's pipeline writes the viewer and the socket id on
  # every page load, and the page's own hook reads the one by the other.
  defp let_through(conn, email, site_id) do
    user = email |> create_admin(site_id) |> Ash.load!([:permissions], authorize?: false)
    MishkaCmsCore.Runtime.States.ViewerState.remember(user)
    on_exit(fn -> MishkaCmsCore.Runtime.States.ViewerState.forget(user.id) end)

    conn
    |> log_in(user, is_nil(site_id))
    |> Plug.Conn.put_session(
      :live_socket_id,
      MishkaCmsCore.Accounts.LiveSockets.live_socket_id(user)
    )
  end

  # Who is a master is read from the signed-in user's own token — issued with no site, on the master
  # site's address — so `master_mode` only stands for the choice the sign-in page would have kept, and
  # changes nothing once someone is signed in. A tenant admin's token names their own site.
  defp log_in(conn, user, master_mode \\ true) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, master_mode)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  test "a master admin sees the settings page with the registry's category tabs", %{conn: conn} do
    conn = log_in(conn, create_admin("boss@example.com", nil))

    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#settings-tabs")
    assert has_element?(view, "#tab-general")
    assert has_element?(view, "#tab-notifications")
    assert has_element?(view, "#settings-save")
    # Master gets the scope picker (Global + each site), not a locked badge.
    assert has_element?(view, "#scope-select")
    refute has_element?(view, "#scope-badge")
  end

  # A SETTING IS SHOWN TO WHOEVER MAY WRITE IT: a pages-only admin holds no setting area, so only
  # their own Preferences are theirs, and the site-wide tabs are not drawn.
  test "an admin of the pages alone gets only the Preferences tab", %{conn: conn, site: site} do
    user = create_admin("pages@example.com", site.id, "admin:dashboard:runtime:page")
    conn = log_in(conn, user, false)

    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#tab-preferences")
    refute has_element?(view, "#tab-general")
    refute has_element?(view, "#tab-notifications")
    refute has_element?(view, "#tab-security")
    refute has_element?(view, "#tab-sidebar")
  end

  test "an admin holding admin:dashboard:setting gets the site-wide tabs", %{
    conn: conn,
    site: site
  } do
    user = create_admin("settings@example.com", site.id, "admin:dashboard:setting")
    conn = log_in(conn, user, false)

    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#tab-general")
    assert has_element?(view, "#tab-preferences")
  end

  # A switched-off site's settings are still the master's to manage, so it stays in the picker.
  test "the scope picker lists a switched-off site too, marked as such", %{conn: conn} do
    off = create_site!(name: "dormant", host: "dormant.test", active: false)
    cache_site(off)
    conn = log_in(conn, create_admin("boss@example.com", nil))
    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, ~s(#scope-select option[value="#{off.id}"]), "dormant (inactive)")
  end

  test "switching tabs shows that category's settings", %{conn: conn} do
    conn = log_in(conn, create_admin("boss@example.com", nil))
    {:ok, view, _html} = live(conn, @path)

    # General has cms.offline; Email has mailer.from.
    assert has_element?(view, "#set-cms-offline")
    refute has_element?(view, "#set-mailer-from")

    view |> element("#tab-email") |> render_click()

    assert has_element?(view, "#set-mailer-from")
    refute has_element?(view, "#set-cms-offline")
  end

  test "saving a setting writes it through to the store", %{conn: conn} do
    conn = log_in(conn, create_admin("boss@example.com", nil))
    {:ok, view, _html} = live(conn, @path)

    view
    |> form("#settings-form", settings: %{"site.title" => "Edited Title"})
    |> render_submit()

    assert Settings.get("site.title") == "Edited Title"
  end

  test "a master can switch to a site scope and save a per-site override", %{
    conn: conn,
    site: site
  } do
    conn = log_in(conn, create_admin("boss@example.com", nil))
    {:ok, view, _html} = live(conn, @path)

    global_before = Settings.get("site.title")

    # Switch from Global to the site, then save a per-site title.
    view |> form("#scope-form") |> render_change(%{"scope" => site.id})

    view
    |> form("#settings-form", settings: %{"site.title" => "Per-Site Title"})
    |> render_submit()

    # The override lands on the site; the global value is untouched.
    assert Settings.get("site.title", nil, site.id) == "Per-Site Title"
    assert Settings.get("site.title") == global_before
  end

  describe "the site's logo, favicon and app icon" do
    test "a site's view offers Media Manager under each address; Global takes an address alone",
         %{conn: conn, site: site} do
      conn = log_in(conn, create_admin("boss@example.com", nil))
      {:ok, view, _html} = live(conn, @path <> "?tab=general")

      for key <- ~w(site-logo site-favicon site-app_icon) do
        assert has_element?(view, "#set-#{key}")
        refute has_element?(view, "#media-#{key}-library")
      end

      view |> form("#scope-form") |> render_change(%{"scope" => site.id})

      for key <- ~w(site-logo site-favicon site-app_icon) do
        assert has_element?(view, "#set-#{key}")
        assert has_element?(view, "#media-#{key}-library")
      end
    end

    test "a picture picked reaches the form as the field's own change, and is saved", %{
      conn: conn,
      site: site
    } do
      conn = log_in(conn, create_admin("boss@example.com", nil))
      {:ok, view, _html} = live(conn, @path <> "?tab=general")
      view |> form("#scope-form") |> render_change(%{"scope" => site.id})
      logo = "/uploads/#{site.id}/media/brand/logo.svg"

      # What a pick in Media Manager pushes (`MediaField`'s `select`).
      render_hook(view, "validate", %{"settings" => %{"site.logo" => logo}})
      assert view |> element("#set-site-logo") |> render() =~ ~s(value="#{logo}")
      assert view |> element("#media-site-logo-preview img") |> render() =~ logo

      view |> form("#settings-form") |> render_submit()
      assert Settings.get("site.logo", nil, site.id) == logo

      # ✕ empties it the same way.
      view |> element("#media-site-logo-clear") |> render_click()
      view |> form("#settings-form") |> render_submit()
      assert Settings.get("site.logo", nil, site.id) == ""
    end

    test "an address that is neither a path nor a web address is not saved", %{
      conn: conn,
      site: site
    } do
      conn = log_in(conn, create_admin("boss@example.com", nil))
      {:ok, view, _html} = live(conn, @path <> "?tab=general")
      view |> form("#scope-form") |> render_change(%{"scope" => site.id})

      view
      |> form("#settings-form", settings: %{"site.favicon" => "javascript:alert(1)"})
      |> render_submit()

      refute Settings.get("site.favicon", nil, site.id) == "javascript:alert(1)"
    end
  end

  # A LIST IS TYPED AS TEXT. Drawn as a list, HEEx joins it with spaces, and the save that followed
  # would split on commas and store one entry, `"en fa"`, which is no language at all.
  test "a site's languages are shown comma-separated and saved as a list", %{
    conn: conn,
    site: site
  } do
    conn = log_in(conn, create_admin("boss@example.com", nil))
    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
    {:ok, view, _html} = live(conn, @path)

    view |> form("#scope-form") |> render_change(%{"scope" => site.id})

    assert has_element?(view, ~s(#set-site-languages[value="en, fa"]))

    view
    |> form("#settings-form", settings: %{"site.languages" => "en, fa, ar"})
    |> render_submit()

    assert Settings.get("site.languages", nil, site.id) == ["en", "fa", "ar"]
    assert has_element?(view, ~s(#set-site-languages[value="en, fa, ar"]))
  end

  # A LIST THAT IS NOT LANGUAGE CODES IS REFUSED WHERE IT IS TYPED. Stored, it would read back as
  # English alone, and every `:lang` page would stop answering the others without a word.
  test "a site's languages that are not language codes are not saved", %{conn: conn, site: site} do
    conn = log_in(conn, create_admin("boss@example.com", nil))
    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
    {:ok, view, _html} = live(conn, @path)

    view |> form("#scope-form") |> render_change(%{"scope" => site.id})

    for typed <- ["English, Persian", ""] do
      view
      |> form("#settings-form", settings: %{"site.languages" => typed})
      |> render_submit()

      assert has_element?(view, "#flash-error")
      assert Settings.get("site.languages", nil, site.id) == ["en", "fa"]
    end
  end

  test "a :master setting is editable in Global but hidden entirely in a site scope",
       %{conn: conn, site: site} do
    conn = log_in(conn, create_admin("boss@example.com", nil))
    {:ok, view, _html} = live(conn, @path)

    # Global view: the master-only list of languages sites may publish is editable.
    assert has_element?(view, "#set-site-allowed_languages")
    refute has_element?(view, "#set-site-allowed_languages[disabled]")

    view |> form("#scope-form") |> render_change(%{"scope" => site.id})

    # Site view: a :master setting disappears completely (not even read-only); a :both stays editable.
    refute has_element?(view, "#set-site-allowed_languages")
    assert has_element?(view, "#set-site-title")
  end

  # A MASTER BOUNDS EVERY SITE'S LANGUAGES from Global, and nowhere else: the two lists are
  # `scope: :master`, so a site view — a master's or a tenant's — does not draw them at all.
  describe "the languages a master allows and requires" do
    test "are edited in Global, and hidden in a site view", %{conn: conn, site: site} do
      conn = log_in(conn, create_admin("boss@example.com", nil))
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#set-site-allowed_languages")
      assert has_element?(view, "#set-site-required_languages")
      refute has_element?(view, "#set-site-allowed_languages[disabled]")

      view |> form("#scope-form") |> render_change(%{"scope" => site.id})

      refute has_element?(view, "#set-site-allowed_languages")
      refute has_element?(view, "#set-site-required_languages")
      assert has_element?(view, "#set-site-languages")
    end

    test "are never shown to a site admin", %{conn: conn, site: site} do
      conn = log_in(conn, create_admin("tenant.admin@example.com", site.id), false)
      {:ok, view, _html} = live(conn, @path)

      refute has_element?(view, "#set-site-allowed_languages")
      refute has_element?(view, "#set-site-required_languages")
      assert has_element?(view, "#set-site-languages")
    end

    test "are saved as lists, and may be left empty", %{conn: conn} do
      conn = log_in(conn, create_admin("boss@example.com", nil))
      {:ok, view, _html} = live(conn, @path)

      view
      |> form("#settings-form",
        settings: %{"site.allowed_languages" => "en, fa", "site.required_languages" => ""}
      )
      |> render_submit()

      assert Settings.get("site.allowed_languages", nil, nil) == ["en", "fa"]
      assert Settings.get("site.required_languages", nil, nil) == []
    end

    test "then a master cannot save a site language outside the allowed ones", %{
      conn: conn,
      site: site
    } do
      {:ok, _} = Settings.put("site.allowed_languages", ["en", "fa"])
      {:ok, _} = Settings.put("site.languages", ["en"], site_id: site.id)
      conn = log_in(conn, create_admin("boss@example.com", nil))
      {:ok, view, _html} = live(conn, @path)
      view |> form("#scope-form") |> render_change(%{"scope" => site.id})

      view
      |> form("#settings-form", settings: %{"site.languages" => "en, fr"})
      |> render_submit()

      assert has_element?(view, "#flash-error")
      assert Settings.get("site.languages", nil, site.id) == ["en"]

      view
      |> form("#settings-form", settings: %{"site.languages" => "en, fa"})
      |> render_submit()

      assert Settings.get("site.languages", nil, site.id) == ["en", "fa"]
    end

    test "nor can a site admin, on their own site", %{conn: conn, site: site} do
      {:ok, _} = Settings.put("site.allowed_languages", ["en", "fa"])
      {:ok, _} = Settings.put("site.languages", ["en"], site_id: site.id)
      conn = log_in(conn, create_admin("tenant.admin@example.com", site.id), false)
      {:ok, view, _html} = live(conn, @path)

      view
      |> form("#settings-form", settings: %{"site.languages" => "en, fr"})
      |> render_submit()

      assert has_element?(view, "#flash-error")
      assert Settings.get("site.languages", nil, site.id) == ["en"]
    end
  end

  # The offline switch reaches both views on purpose: a master throws it in Global to cover every
  # site, or on one site to cover that site; a tenant throws their own. `MishkaCmsCore.Settings`
  # `offline?/1` is what stops a site undoing the master's.
  test "the offline switch is editable in Global and in a site scope alike",
       %{conn: conn, site: site} do
    conn = log_in(conn, create_admin("boss@example.com", nil))
    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#set-cms-offline")
    refute has_element?(view, "#set-cms-offline[disabled]")

    view |> form("#scope-form") |> render_change(%{"scope" => site.id})

    assert has_element?(view, "#set-cms-offline")
    refute has_element?(view, "#set-cms-offline[disabled]")
  end

  test "a tenant admin sees the page locked to their own site (no Global picker)", %{
    conn: conn,
    site: site
  } do
    conn = log_in(conn, create_admin("tenant.admin@example.com", site.id), false)

    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#settings")
    assert has_element?(view, "#scope-badge")
    refute has_element?(view, "#scope-select")
    # A tenant edits :site/:both settings; :master settings (whole-CMS) are hidden entirely.
    assert has_element?(view, "#set-site-title")
    refute has_element?(view, "#set-site-allowed_languages")
  end

  # The built-in holding page reads the site's own words, so the site writes them.
  test "and words its own holding page, leaving the global message alone", %{
    conn: conn,
    site: site
  } do
    conn = log_in(conn, create_admin("tenant.admin@example.com", site.id), false)
    {:ok, view, _html} = live(conn, @path)
    global_before = Settings.get("cms.maintenance_message")

    assert has_element?(view, "#set-cms-maintenance_message")
    refute has_element?(view, "#set-cms-maintenance_message[disabled]")

    view
    |> form("#settings-form", settings: %{"cms.maintenance_message" => "Back on Monday"})
    |> render_submit()

    assert Settings.get("cms.maintenance_message", nil, site.id) == "Back on Monday"
    assert Settings.get("cms.maintenance_message") == global_before
  end

  # Global and a site's own switch are OR-ed. A site view showing the global value offered a switch
  # that, turned off and saved, left the site offline and said "Settings saved".
  describe "a site's offline switch while Global holds every site offline" do
    setup do
      {:ok, _} = Settings.put("cms.offline", true)
      :ok
    end

    test "shows the site's own switch, and says Global holds it", %{conn: conn, site: site} do
      conn = let_through(conn, "tenant.admin@example.com", site.id)
      {:ok, view, _html} = live(conn, @path)

      refute has_element?(view, "#set-cms-offline[checked]")
      assert has_element?(view, "#held-cms-offline")
    end

    test "and a master sees the same in a site's view, not in Global", %{conn: conn, site: site} do
      conn = let_through(conn, "boss@example.com", nil)
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#set-cms-offline[checked]")
      refute has_element?(view, "#held-cms-offline")

      view |> form("#scope-form") |> render_change(%{"scope" => site.id})

      refute has_element?(view, "#set-cms-offline[checked]")
      assert has_element?(view, "#held-cms-offline")
    end

    test "a site that took itself offline shows its own switch on", %{conn: conn, site: site} do
      {:ok, _} = Settings.put("cms.offline", true, site_id: site.id)
      conn = let_through(conn, "tenant.admin@example.com", site.id)
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#set-cms-offline[checked]")
    end
  end

  test "no hold is shown while Global is off", %{conn: conn, site: site} do
    conn = log_in(conn, create_admin("tenant.admin@example.com", site.id), false)
    {:ok, view, _html} = live(conn, @path)

    refute has_element?(view, "#held-cms-offline")
  end

  test "the Global view names the switch for what it does there", %{conn: conn, site: site} do
    conn = log_in(conn, create_admin("boss@example.com", nil))
    {:ok, view, _html} = live(conn, @path)

    assert view |> element("#settings-form") |> render() =~ "Take every site offline"

    view |> form("#scope-form") |> render_change(%{"scope" => site.id})

    html = view |> element("#settings-form") |> render()
    assert html =~ "Take this site offline"
    refute html =~ "Take every site offline"
  end

  test "and can take its own site offline from that page", %{conn: conn, site: site} do
    conn = log_in(conn, create_admin("tenant.admin@example.com", site.id), false)
    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#set-cms-offline")
    refute has_element?(view, "#set-cms-offline[disabled]")

    on_exit(fn -> MishkaCmsCore.Runtime.States.SettingsState.delete(site.id, "cms.offline") end)

    view
    |> form("#settings-form", settings: %{"cms.offline" => "true"})
    |> render_submit()

    assert Settings.offline?(site.id)
    refute Settings.offline?(nil)
  end

  test "a tenant cannot escalate to a global write via a forged switch_scope event", %{
    conn: conn,
    site: site
  } do
    conn = log_in(conn, create_admin("tenant.admin@example.com", site.id), false)
    {:ok, view, _html} = live(conn, @path)

    global_before = Settings.get("site.title")

    # Forge the master-only event over the socket, then save a :both setting.
    render_hook(view, "switch_scope", %{"scope" => "global"})

    view
    |> form("#settings-form", settings: %{"site.title" => "Hacked Global"})
    |> render_submit()

    # The write landed on the tenant's OWN site, never the global value.
    assert Settings.get("site.title") == global_before
    assert Settings.get("site.title", nil, site.id) == "Hacked Global"
  end

  test "a tenant cannot write a NEIGHBOUR's site via a forged switch_scope event", %{
    conn: conn,
    site: site
  } do
    neighbour = create_site!(name: "neighbour", host: "neighbour.test")
    conn = log_in(conn, create_admin("tenant.admin@example.com", site.id), false)
    {:ok, view, _html} = live(conn, @path)

    render_hook(view, "switch_scope", %{"scope" => neighbour.id})

    view
    |> form("#settings-form", settings: %{"site.title" => "Hacked Neighbour"})
    |> render_submit()

    assert Settings.get("site.title", :unset, neighbour.id) != "Hacked Neighbour"
    assert Settings.get("site.title", nil, site.id) == "Hacked Neighbour"
  end

  # Belt and braces: the page clamps a tenant to their own site, but that clamp is a convenience.
  # Even reaching past the page straight into the façade, the resource's policies refuse.
  test "the resource refuses a tenant's cross-site write even with the page out of the way", %{
    site: site
  } do
    neighbour = create_site!(name: "neighbour", host: "neighbour.test")
    tenant = create_admin("tenant.admin@example.com", site.id)

    assert {:error, _} =
             Settings.put_as(tenant, "site.title", "Hacked", site_id: neighbour.id)

    assert Settings.get("site.title", :unset, neighbour.id) != "Hacked"
  end

  describe "attention dot" do
    test "flags the tab whose setting still holds a placeholder default, and clears once set", %{
      conn: conn
    } do
      conn = log_in(conn, create_admin("boss@example.com", nil))

      # `mailer.from` ships empty (attention_on_default: true) and lives under
      # Email, so that tab is flagged while nobody has set a real address.
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#tab-email span.bg-\\[\\#e5484d\\]")
      refute has_element?(view, "#tab-general span.bg-\\[\\#e5484d\\]")

      view |> element("#tab-email") |> render_click()

      view
      |> form("#settings-form", settings: %{"mailer.from" => "hello@mishka.tools"})
      |> render_submit()

      refute has_element?(view, "#tab-email span.bg-\\[\\#e5484d\\]")
    end

    test "a setting without attention_on_default never flags its tab", %{conn: conn} do
      conn = log_in(conn, create_admin("boss@example.com", nil))
      {:ok, view, _html} = live(conn, @path)

      # site.title is also at its default, but it is not a placeholder — General stays unflagged.
      assert Settings.get("site.title") == "MishkaCMS"
      refute has_element?(view, "#tab-general span.bg-\\[\\#e5484d\\]")
    end
  end

  test "each rendered field shows its definition's description", %{conn: conn} do
    conn = log_in(conn, create_admin("boss@example.com", nil))
    {:ok, view, _html} = live(conn, @path)

    assert render(view) =~ "Show a holding page to visitors while you make changes."

    view |> element("#tab-notifications") |> render_click()

    assert render(view) =~ "Sends an email to all administrators on any grant or revoke."

    view |> element("#tab-email") |> render_click()

    assert render(view) =~ "Every email this site sends comes from this address"
  end

  describe "realtime reach" do
    test "a master's open page picks up a global write made elsewhere", %{conn: conn} do
      conn = log_in(conn, create_admin("boss@example.com", nil))
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#set-site-title[value='MishkaCMS']")

      # Nobody touches the view: the resource publishes "setting:updated" and the page re-reads.
      Settings.put("site.title", "Changed Elsewhere")

      assert has_element?(view, "#set-site-title[value='Changed Elsewhere']")
    end

    test "a master watching Global also sees a site's write land", %{conn: conn, site: site} do
      conn = log_in(conn, create_admin("boss@example.com", nil))
      {:ok, view, _html} = live(conn, @path)

      Settings.put("site.title", "Site Write", site_id: site.id)

      # The master's Global view is unchanged in VALUE (that write was the site's), but the page
      # refreshed rather than ignoring the broadcast — the global value still reads through.
      assert has_element?(view, "#set-site-title[value='MishkaCMS']")
      assert Settings.get("site.title", nil, site.id) == "Site Write"
    end

    test "a tenant refreshes for its own site and for global, but ignores another site", %{
      conn: conn,
      site: site
    } do
      other = create_site!(name: "other", host: "other.test", active: true)
      cache_site(other)

      conn = log_in(conn, create_admin("tenant.admin@example.com", site.id), false)
      {:ok, view, _html} = live(conn, @path)

      # Another site's write is out of this tenant's reach — the page must not re-read for it.
      Settings.put("site.title", "Other Site Title", site_id: other.id)
      assert has_element?(view, "#set-site-title[value='MishkaCMS']")

      # Their own site's write does reach them.
      Settings.put("site.title", "My Site Title", site_id: site.id)
      assert has_element?(view, "#set-site-title[value='My Site Title']")
    end
  end

  describe "a definition's own rules are enforced, not just displayed" do
    setup do
      Application.put_env(:mishka_cms_core, :settings_providers, [ValidatedSettingsProvider])
      Settings.load_definitions()
      on_exit(fn -> Application.put_env(:mishka_cms_core, :settings_providers, []) end)
      :ok
    end

    defp security_tab(conn) do
      conn = log_in(conn, create_admin("boss@example.com", nil))
      {:ok, view, _html} = live(conn, @path)
      view |> element("#tab-security") |> render_click()
      view
    end

    test "a locked setting renders read-only and cannot be written by posting its key", %{
      conn: conn
    } do
      view = security_tab(conn)

      # The input renders disabled, which is why `form/3` cannot even fill it — that is the UI half.
      assert has_element?(view, "#set-locked-fingerprint[disabled]")

      # The half that matters: posting the key anyway, as anything not a browser would, still writes
      # nothing. `render_submit/2` on the element sends params the rendered form never offered.
      view
      |> element("#settings-form")
      |> render_submit(%{"settings" => %{"locked.fingerprint" => "tampered"}})

      assert Settings.get("locked.fingerprint") == "do-not-touch"
    end

    test "an integer is clamped to the bounds its definition declared", %{conn: conn} do
      view = security_tab(conn)

      view
      |> form("#settings-form", settings: %{"bounded.retention_days" => "500"})
      |> render_submit()

      assert Settings.get("bounded.retention_days") == 90

      view
      |> form("#settings-form", settings: %{"bounded.retention_days" => "0"})
      |> render_submit()

      assert Settings.get("bounded.retention_days") == 1
    end

    test "a number that will not parse is refused instead of being written as zero", %{conn: conn} do
      view = security_tab(conn)

      html =
        view
        |> element("#settings-form")
        |> render_submit(%{"settings" => %{"bounded.retention_days" => "soon"}})

      assert html =~ "could not be saved"
      assert Settings.get("bounded.retention_days") == 30
    end

    test "a select value that is not on its list is refused", %{conn: conn} do
      view = security_tab(conn)

      html =
        view
        |> element("#settings-form")
        |> render_submit(%{"settings" => %{"choice.level" => "paranoid"}})

      assert html =~ "could not be saved"
      assert Settings.get("choice.level") == "standard"

      view
      |> form("#settings-form", settings: %{"choice.level" => "strict"})
      |> render_submit()

      assert Settings.get("choice.level") == "strict"
    end

    # The save loop walks every editable field on the tab, so a form that posts one input used to
    # blank out its neighbours. Only what the browser actually sent may be written.
    test "a field the form did not send is left alone", %{conn: conn} do
      view = security_tab(conn)

      view
      |> form("#settings-form", settings: %{"choice.level" => "strict"})
      |> render_submit()

      view
      |> form("#settings-form", settings: %{"bounded.retention_days" => "45"})
      |> render_submit()

      assert Settings.get("choice.level") == "strict"
      assert Settings.get("bounded.retention_days") == 45
    end
  end

  describe "permission-gated settings" do
    setup do
      Application.put_env(:mishka_cms_core, :settings_providers, [GatedSettingsProvider])
      Settings.load_definitions()
      on_exit(fn -> Application.put_env(:mishka_cms_core, :settings_providers, []) end)
      :ok
    end

    test "a user holding the permission sees the setting and its tab", %{conn: conn} do
      conn = log_in(conn, create_admin("boss@example.com", nil))
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#tab-deploy")

      view |> element("#tab-deploy") |> render_click()

      assert has_element?(view, "#set-secret-token")
    end

    test "a full dashboard admin holds it too, and sees it", %{conn: conn} do
      user = create_admin("full@example.com", nil, "admin:dashboard:*")
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, @path <> "?tab=deploy")

      assert has_element?(view, "#set-secret-token")
    end

    test "the setting area alone does not show it, whose leaf does not cover the setting's own name" do
      secret = Settings.definition("secret.token")
      setting_area = create_admin("narrow@example.com", nil, "admin:dashboard:setting")
      setting_area = Ash.load!(setting_area, [:permissions], authorize?: false)

      refute Settings.writable?(secret, setting_area)
      assert Settings.writable?(Settings.definition("site.title"), setting_area)
    end

    test "a full dashboard admin sees neither a setting it may not write nor its tab", %{
      conn: conn
    } do
      conn = log_in(conn, create_admin("dashboard@example.com", nil, "admin:dashboard:*"))
      {:ok, view, _html} = live(conn, @path)

      refute has_element?(view, "#tab-vault")
      refute has_element?(view, "#set-vault-key")

      # Asked for by URL, the tab falls back to the first one this admin may see.
      {:ok, view, _html} = live(conn, @path <> "?tab=vault")

      refute has_element?(view, "#set-vault-key")
      assert has_element?(view, "#set-site-title")
    end

    test "a holder of the setting's own permission sees it on its tab", %{conn: conn} do
      conn = log_in(conn, create_admin("vault@example.com", nil))
      {:ok, view, _html} = live(conn, @path <> "?tab=vault")

      assert has_element?(view, "#tab-vault")
      assert has_element?(view, "#set-vault-key")
    end
  end

  test "a realtime broadcast does not clobber an in-progress edit", %{conn: conn} do
    conn = log_in(conn, create_admin("boss@example.com", nil))
    {:ok, view, _html} = live(conn, @path)

    # The user is mid-edit (phx-change fired) but has not saved.
    view |> form("#settings-form", settings: %{"site.title" => "Typing…"}) |> render_change()

    # A setting change broadcasts to the shared topic — it must NOT reset the dirty form.
    send(view.pid, %Phoenix.Socket.Broadcast{
      topic: "setting:updated",
      event: "updated",
      payload: %{}
    })

    render(view)

    assert has_element?(view, "#set-site-title[value='Typing…']")
  end

  # How often anyone may sign in, ask for a reset or a sign-in link, or try their password to change
  # it is the whole CMS's to set, so only a master sees the limits — on a Security tab a site admin
  # does not get at all.
  describe "the sign-in limits" do
    @sign_in_limits [
      sign_in_per_account: 10,
      sign_in_per_ip: 30,
      reset_request_per_account: 3,
      reset_request_per_ip: 10,
      magic_link_per_account: 3,
      magic_link_per_ip: 10,
      change_password_per_account: 10
    ]

    test "are a master's to edit, on the Security tab, set to what the actions are written with",
         %{conn: conn} do
      conn = log_in(conn, create_admin("boss@example.com", nil))
      {:ok, view, _html} = live(conn, @path <> "?tab=security")

      assert has_element?(view, "#tab-security")

      for {key, default} <- @sign_in_limits do
        assert has_element?(view, "#set-security-#{key}[type='number'][value='#{default}']")
        refute has_element?(view, "#set-security-#{key}[disabled]")
      end
    end

    test "are not a site admin's, who sees only the site's own switches on the tab", %{
      conn: conn,
      site: site
    } do
      conn = log_in(conn, create_admin("tenant.admin@example.com", site.id), false)
      {:ok, view, _html} = live(conn, @path <> "?tab=security")

      assert has_element?(view, "#tab-security")
      assert has_element?(view, "#set-auth-sign_in-closed")
      assert has_element?(view, "#set-auth-sign_in-sign_out")

      for {key, _default} <- @sign_in_limits,
          do: refute(has_element?(view, "#set-security-#{key}"))
    end

    test "a limit a master saves holds from the next sign-in on", %{conn: conn, site: site} do
      previous = Application.fetch_env(:mishka_cms_core, MishkaCmsCore.Accounts.AuthRateLimit)
      Application.delete_env(:mishka_cms_core, MishkaCmsCore.Accounts.AuthRateLimit)

      on_exit(fn ->
        with {:ok, env} <- previous,
             do: Application.put_env(:mishka_cms_core, MishkaCmsCore.Accounts.AuthRateLimit, env)
      end)

      conn = log_in(conn, create_admin("boss@example.com", nil))
      {:ok, view, _html} = live(conn, @path <> "?tab=security")

      view
      |> form("#settings-form", settings: %{"security.sign_in_per_account" => "1"})
      |> render_submit()

      assert Settings.get("security.sign_in_per_account") == 1

      email = "limited-#{System.unique_integer([:positive])}@example.com"

      sign_in = fn ->
        User
        |> Ash.Query.for_read(
          :sign_in_with_password,
          %{email: email, password: "not-the-password"},
          tenant: site.id,
          context: %{ash_authentication_request: %{remote_ip: "192.0.2.10"}}
        )
        |> Ash.read_one()
      end

      assert {:error,
              %Ash.Error.Forbidden{errors: [%AshAuthentication.Errors.AuthenticationFailed{}]}} =
               sign_in.()

      assert {:error, %Ash.Error.Forbidden{errors: [%AshRateLimiter.LimitExceeded{}]}} =
               sign_in.()
    end
  end

  # What a search engine reads of a site: its robots.txt rules, which Global may set for every site,
  # and the extra addresses its sitemap lists, which are the site's alone.
  describe "the SEO tab" do
    test "holds the robots rules in Global, and both fields in a site's view", %{
      conn: conn,
      site: site
    } do
      conn = log_in(conn, create_admin("boss@example.com", nil))
      {:ok, view, _html} = live(conn, @path <> "?tab=seo")

      assert has_element?(view, "#tab-seo", "SEO")
      assert has_element?(view, "textarea#set-seo-robots-extra")
      refute has_element?(view, "#set-seo-sitemap-paths")

      view |> form("#scope-form") |> render_change(%{"scope" => site.id})

      assert has_element?(view, "textarea#set-seo-robots-extra")
      assert has_element?(view, "#set-seo-sitemap-paths")
    end

    test "saves a site's extra sitemap addresses as a list", %{conn: conn, site: site} do
      conn = log_in(conn, create_admin("tenant.admin@example.com", site.id), false)
      {:ok, view, _html} = live(conn, @path <> "?tab=seo")

      view
      |> form("#settings-form", settings: %{"seo.sitemap.paths" => "/pricing, /search?q=a"})
      |> render_submit()

      assert Settings.get("seo.sitemap.paths", nil, site.id) == ["/pricing", "/search?q=a"]
      assert has_element?(view, ~s(#set-seo-sitemap-paths[value="/pricing, /search?q=a"]))
    end

    # AN ADDRESS WITH A CAPTURE IS A PATTERN, which the sitemap would hand a crawler as written; one
    # with a space is not a URL.
    test "refuses an address that is not one path on the site", %{conn: conn, site: site} do
      conn = log_in(conn, create_admin("tenant.admin@example.com", site.id), false)
      {:ok, _} = Settings.put("seo.sitemap.paths", ["/pricing"], site_id: site.id)
      {:ok, view, _html} = live(conn, @path <> "?tab=seo")

      for typed <- ["/:lang/pricing", "/docs/*rest", "pricing", "/pricing, about", "/a b"] do
        view
        |> form("#settings-form", settings: %{"seo.sitemap.paths" => typed})
        |> render_submit()

        assert has_element?(view, "#flash-error"), "#{typed} was saved"
        assert Settings.get("seo.sitemap.paths", nil, site.id) == ["/pricing"]
      end
    end

    test "holds the share-card workers in Global alone, as a number from 0 to 4", %{
      conn: conn,
      site: site
    } do
      conn = log_in(conn, create_admin("boss@example.com", nil))
      {:ok, view, _html} = live(conn, @path <> "?tab=seo")

      assert has_element?(
               view,
               ~s(input#set-share_cards-workers[type="number"][min="0"][max="4"][value="1"])
             )

      view |> form("#scope-form") |> render_change(%{"scope" => site.id})
      refute has_element?(view, "#set-share_cards-workers")
    end

    test "saves the share-card workers held to 0..4, and refuses what is not a number", %{
      conn: conn
    } do
      conn = log_in(conn, create_admin("boss@example.com", nil))
      {:ok, view, _html} = live(conn, @path <> "?tab=seo")

      for {typed, saved} <- [{"3", 3}, {"9", 4}, {"-2", 0}, {"0", 0}, {"2", 2}] do
        view
        |> form("#settings-form", settings: %{"share_cards.workers" => typed})
        |> render_submit()

        assert Settings.get("share_cards.workers") == saved, "#{typed} saved as #{saved}"
      end

      html =
        view
        |> element("#settings-form")
        |> render_submit(%{"settings" => %{"share_cards.workers" => "two"}})

      assert html =~ "could not be saved"
      assert Settings.get("share_cards.workers") == 2
    end
  end

  describe "the Email tab" do
    @key "mailer.resend.api_key"

    test "offers the registered providers, each one's fields while it is the one chosen", %{
      conn: conn
    } do
      conn = log_in(conn, create_admin("boss@example.com", nil))
      {:ok, view, _html} = live(conn, @path <> "?tab=email")
      # The history is a Gervaz table, which draws once its rows are read.
      _loaded = render_async(view)

      assert has_element?(view, ~s(#set-mailer-provider option[value="resend"]))
      assert has_element?(view, ~s(#set-mailer-provider option[value="none"]))
      refute has_element?(view, "#set-mailer-resend-api_key")

      choose!(view, "mailer.provider", "resend")
      assert has_element?(view, "#set-mailer-resend-api_key[type=password]")

      choose!(view, "mailer.provider", "none")
      refute has_element?(view, "#set-mailer-resend-api_key")

      assert has_element?(view, "#mail-test-form")
      assert has_element?(view, "#mail-deliveries")
    end

    test "a saved key is never drawn back, an empty save keeps it, and Remove clears it", %{
      conn: conn,
      site: site
    } do
      conn = log_in(conn, create_admin("boss@example.com", nil))
      {:ok, view, _html} = live(conn, @path <> "?tab=email")
      view |> element("#scope-form") |> render_change(%{"scope" => site.id})
      choose!(view, "mailer.provider", "resend")

      view
      |> form("#settings-form", settings: %{@key => "re_secret_key_9z9z"})
      |> render_submit()

      assert Settings.secret(@key, site.id) == "re_secret_key_9z9z"

      html = render(view)
      refute html =~ "re_secret_key_9z9z"
      assert view |> element("#set-mailer-resend-api_key") |> render() =~ "ends in 9z9z"

      view |> form("#settings-form", settings: %{@key => ""}) |> render_submit()
      assert Settings.secret(@key, site.id) == "re_secret_key_9z9z"

      view |> element("#clear-mailer-resend-api_key") |> render_click()
      assert Settings.secret(@key, site.id) == nil
      refute has_element?(view, "#clear-mailer-resend-api_key")
    end

    test "a test email goes to the typed address and lands in the history", %{conn: conn} do
      conn = log_in(conn, create_admin("boss@example.com", nil))
      {:ok, view, _html} = live(conn, @path <> "?tab=email")

      view
      |> form("#mail-test-form", %{"to" => "someone@example.org"})
      |> render_submit()

      assert_receive {:email, %Swoosh.Email{to: [{_name, "someone@example.org"}]}}
      assert render(view) =~ "Test email sent to someone@example.org."
    end

    test "a site that picked no provider is told so by the test email", %{conn: conn, site: site} do
      {:ok, _} = Settings.put("mailer.provider", "none", site_id: site.id)
      conn = log_in(conn, create_admin("boss@example.com", site.id))
      {:ok, view, _html} = live(conn, @path <> "?tab=email")

      view |> form("#mail-test-form", %{"to" => "someone@example.org"}) |> render_submit()

      assert render(view) =~ "No email provider is set for this site."
    end
  end

  describe "the Security tab's captcha" do
    test "offers the registered providers, and only the chosen one's fields", %{conn: conn} do
      conn = log_in(conn, create_admin("boss@example.com", nil))
      {:ok, view, _html} = live(conn, @path <> "?tab=security")

      assert has_element?(view, ~s(#set-security-captcha-provider option[value="none"]))
      assert has_element?(view, ~s(#set-security-captcha-provider option[value="turnstile"]))
      assert has_element?(view, ~s(#set-security-captcha-provider option[value="recaptcha"]))
      refute has_element?(view, "#set-security-captcha-check_domain")
      refute has_element?(view, "#set-security-captcha-turnstile-site_key")
      refute has_element?(view, "#set-security-captcha-recaptcha-site_key")

      choose!(view, "security.captcha.provider", "turnstile")
      assert has_element?(view, "#set-security-captcha-check_domain")
      assert has_element?(view, "#set-security-captcha-turnstile-secret_key[type=password]")
      refute has_element?(view, "#set-security-captcha-recaptcha-site_key")

      choose!(view, "security.captcha.provider", "recaptcha")
      refute has_element?(view, "#set-security-captcha-turnstile-site_key")
      assert has_element?(view, "#set-security-captcha-recaptcha-version")
      refute has_element?(view, "#set-security-captcha-recaptcha-min_score")

      choose!(view, "security.captcha.recaptcha.version", "v3")
      assert has_element?(view, "#set-security-captcha-recaptcha-min_score")
    end

    test "a key saved under an older server key says so, flags the tab, and is typed again", %{
      conn: conn,
      site: site
    } do
      {:ok, _} = Settings.put("security.captcha.provider", "turnstile", site_id: site.id)
      {:ok, _} = Settings.put("security.captcha.turnstile.site_key", "site-key", site_id: site.id)

      # What a key sealed under another SECRET_KEY_BASE looks like to this server: text it cannot open.
      SettingsState.put(site.id, "security.captcha.turnstile.secret_key", %{
        "value" => "sealed-under-an-older-key"
      })

      conn = log_in(conn, create_admin("boss@example.com", site.id))
      {:ok, view, _html} = live(conn, @path <> "?tab=security")

      assert has_element?(view, "#unreadable-security-captcha-turnstile-secret_key")
      assert has_element?(view, "#tab-security span.bg-\\[\\#e5484d\\]")

      assert view |> element("#set-security-captcha-turnstile-secret_key") |> render() =~
               "Saved with an older server key"

      assert has_element?(view, "#clear-security-captcha-turnstile-secret_key")
      assert has_element?(view, "#captcha-test-none")

      view
      |> form("#settings-form",
        settings: %{
          "security.captcha.turnstile.secret_key" => "1x0000000000000000000000000000000AA"
        }
      )
      |> render_submit()

      refute has_element?(view, "#unreadable-security-captcha-turnstile-secret_key")
      refute has_element?(view, "#tab-security span.bg-\\[\\#e5484d\\]")

      assert view |> element("#set-security-captcha-turnstile-secret_key") |> render() =~
               "ends in 00AA"
    end

    test "a field not shown is not saved: the other provider's keys and switches stay", %{
      conn: conn,
      site: site
    } do
      {:ok, _} = Settings.put("security.captcha.turnstile.site_key", "kept", site_id: site.id)
      conn = log_in(conn, create_admin("boss@example.com", site.id))
      {:ok, view, _html} = live(conn, @path <> "?tab=security")

      choose!(view, "security.captcha.provider", "recaptcha")

      view
      |> form("#settings-form", settings: %{"security.captcha.recaptcha.site_key" => "google"})
      |> render_submit()

      assert Settings.get_own("security.captcha.provider", nil, site.id) == "recaptcha"
      assert Settings.get_own("security.captcha.recaptcha.site_key", nil, site.id) == "google"
      assert Settings.get_own("security.captcha.turnstile.site_key", nil, site.id) == "kept"

      choose!(view, "security.captcha.provider", "none")
      view |> form("#settings-form") |> render_submit()

      assert Settings.get_own("security.captcha.provider", nil, site.id) == "none"
      assert Settings.get_own("security.captcha.check_domain", true, site.id) == true
    end

    test "has nothing to test while the scope asks none", %{conn: conn} do
      conn = log_in(conn, create_admin("boss@example.com", nil))
      {:ok, view, _html} = live(conn, @path <> "?tab=security")

      assert has_element?(view, "#captcha-test-none")
      assert has_element?(view, "#captcha-test-run[disabled]")
      refute has_element?(view, "#captcha-test-form [phx-hook=Captcha]")
    end

    test "draws the scope's saved captcha and says what the provider answered", %{
      conn: conn,
      site: site
    } do
      for {key, value} <- [
            {"security.captcha.provider", "turnstile"},
            {"security.captcha.turnstile.site_key", "1x00000000000000000000AA"},
            {"security.captcha.turnstile.secret_key", "1x0000000000000000000000000000000AA"}
          ] do
        {:ok, _} = Settings.put(key, value, site_id: site.id)
      end

      conn = log_in(conn, create_admin("boss@example.com", site.id))
      {:ok, view, _html} = live(conn, @path <> "?tab=security")

      assert has_element?(view, "#captcha-test-form [phx-hook=Captcha][data-provider=turnstile]")

      Req.Test.allow(MishkaCmsCore.Captcha, self(), view.pid)
      Req.Test.stub(MishkaCmsCore.Captcha, &Req.Test.json(&1, %{"success" => true}))

      view
      |> form("#captcha-test-form")
      |> render_submit(%{captcha: %{captcha_token: "token-#{System.unique_integer()}"}})

      assert render(view) =~ "accepted the check"
      assert_push_event(view, "mishka:captcha:reset", %{})

      view |> form("#captcha-test-form") |> render_submit()
      assert render(view) =~ "Solve the check first"
    end
  end

  # What the select does in a browser: the form's change event, with the chosen value.
  defp choose!(view, key, value),
    do: view |> element("#settings-form") |> render_change(%{"settings" => %{key => value}})

  describe "the scope badge" do
    defp badge(view, id),
      do:
        view
        |> element(~s(label[for="set-#{id}"] span))
        |> render()
        |> String.replace(~r/<[^>]*>/, "")
        |> String.trim()

    test "names the scope a save writes: the one in view, not the ones a setting allows", %{
      conn: conn,
      site: site
    } do
      conn = log_in(conn, create_admin("boss@example.com", nil))
      {:ok, view, _html} = live(conn, @path <> "?tab=general")

      assert badge(view, "site-title") == "Global"

      view |> element("#tab-email") |> render_click()
      assert badge(view, "mailer-provider") == "Global"

      view |> element("#scope-form") |> render_change(%{"scope" => site.id})
      assert badge(view, "mailer-provider") == "This site"

      view |> element("#tab-notifications") |> render_click()
      assert badge(view, "notify-retention_read_days") == "Global"
    end
  end

  defp closed_here?(site), do: Settings.get_own("auth.sign_in.closed", false, site.id) == true

  # Closing the way in behind yourself — signed out at once, or unable to sign in again — is refused
  # whole, judged on the tab as it will stand, so the same save that adds you to Still allowed passes.
  describe "an admin closing sign-in" do
    setup %{conn: conn, site: site} do
      editor = create_admin("editor@example.com", site.id, "admin:dashboard:*")
      {:ok, view, _html} = live(log_in(conn, editor, false), @path <> "?tab=security")
      %{view: view}
    end

    test "is refused when it would sign them out, and nothing is saved", %{view: view, site: site} do
      view
      |> form("#settings-form",
        settings: %{"auth.sign_in.closed" => "true", "auth.sign_in.sign_out" => "true"}
      )
      |> render_submit()

      assert has_element?(view, "#flash-error", "shut you out")
      refute closed_here?(site)
    end

    test "is refused when it would keep them from signing in again", %{view: view, site: site} do
      view
      |> form("#settings-form", settings: %{"auth.sign_in.closed" => "true"})
      |> render_submit()

      assert has_element?(view, "#flash-error", "shut you out")
      refute closed_here?(site)
    end

    test "is saved once the same save keeps them in", %{view: view, site: site} do
      view
      |> form("#settings-form",
        settings: %{
          "auth.sign_in.closed" => "true",
          "auth.sign_in.sign_out" => "true",
          "auth.allowed_emails" => "editor@example.com"
        }
      )
      |> render_submit()

      refute has_element?(view, "#flash-error")
      assert closed_here?(site)
    end

    test "is a master's to save freely", %{conn: conn, site: site} do
      {:ok, view, _html} =
        live(log_in(conn, create_admin("boss@example.com", nil)), @path <> "?tab=security")

      view |> form("#scope-form") |> render_change(%{"scope" => site.id})

      view
      |> form("#settings-form",
        settings: %{"auth.sign_in.closed" => "true", "auth.sign_in.sign_out" => "true"}
      )
      |> render_submit()

      refute has_element?(view, "#flash-error")
      assert closed_here?(site)
    end
  end

  describe "the players pages may embed" do
    test "the setting takes https origins and refuses anything else" do
      definition = Settings.definition("security.frame_origins")

      assert definition.category == "security"

      assert {:ok, ["https://www.youtube-nocookie.com", "https://player.vimeo.com"]} =
               Settings.cast(
                 definition,
                 "https://www.youtube-nocookie.com, https://player.vimeo.com"
               )

      assert :error = Settings.cast(definition, "https://ok.example.com, javascript:x")
      assert :error = Settings.cast(definition, "https://www.youtube.com/embed/x")
    end
  end
end
