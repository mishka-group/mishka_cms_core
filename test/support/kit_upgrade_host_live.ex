defmodule MishkaCmsCore.Test.KitUpgradeHostLive do
  @moduledoc """
  A minimal stand-in for the extension dashboards that host the doctor modal, so the standings can
  be driven through `Phoenix.LiveViewTest.live_isolated/3` with a real socket, a real flash and the
  same event clauses both dashboards write — against a bundle and pages a test wrote, rather than
  the ones an extension ships.

  It draws the real modal rather than the standings on their own, because the site picker and the
  `kit_check` form that fill them in live there: a host with a picker of its own would be testing
  its own markup.

  The session carries the bundle to compare against (`"bundle"`), the sites the page offers
  (`"sites"`, `[{label, id}]`), the sample pages this "version" ships (`"pages"`, `[{path,
  template}]`) and whether this admin may write them (`"may_upgrade?"`), so one host covers a master
  picking from several sites and a page that refuses.

  The pages arrive as data rather than as the function the panel takes, because a session is
  serialized: the host builds the function around them, the way a dashboard hands over its
  extension's own. `"pages"` of `"raise"` is the function failing, which an extension's own does on
  a site row that has gone.

  The flash is rendered here because there is no admin layout around an isolated view, and a refusal
  this answers with is the whole of what some of these tests assert.
  """

  use Phoenix.LiveView

  alias MishkaCmsCoreWeb.Live.Admin.Components.ExtensionInstallerPanel
  alias MishkaCmsCoreWeb.Live.Admin.Components.KitUpgradePanel

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:sites, session["sites"] || [])
     |> assign(:may_upgrade?, Map.get(session, "may_upgrade?", true))
     |> ExtensionInstallerPanel.setup(app: :mishka_kit_host, noun: "test extension")
     |> KitUpgradePanel.setup(
       bundle: session["bundle"],
       noun: "test components",
       pages: &sample_pages(session["pages"] || [], &1, &2),
       draft_label: "Test sample page"
     )}
  end

  @impl true
  def handle_event("kit_check", params, socket) do
    site_id = chosen_site(socket, params)

    {:noreply,
     socket
     |> ExtensionInstallerPanel.choose(site_id)
     |> KitUpgradePanel.check(site_id, socket.assigns.may_upgrade?)}
  end

  def handle_event("kit_upgrade", %{"mode" => mode}, socket) do
    {:noreply, KitUpgradePanel.upgrade(socket, mode, socket.assigns.may_upgrade?)}
  end

  def handle_event("page_drafts", _params, socket) do
    {:noreply, KitUpgradePanel.offer(socket, socket.assigns.may_upgrade?)}
  end

  def handle_event("extension_site", params, socket) do
    {:noreply, ExtensionInstallerPanel.choose(socket, chosen_site(socket, params))}
  end

  def handle_event("extension_install", params, socket) do
    {:noreply,
     ExtensionInstallerPanel.install(
       socket,
       chosen_site(socket, params),
       socket.assigns.may_upgrade?
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div id="kit-flash-error">{Phoenix.Flash.get(@flash, :error)}</div>
      <div id="kit-flash-info">{Phoenix.Flash.get(@flash, :info)}</div>

      <ExtensionInstallerPanel.doctor_modal
        id="kit"
        install_id="kit-install"
        setup={@extension_install}
        kit={@kit_upgrade}
        sites={@sites}
        allowed?={@may_upgrade?}
        title="Test components"
      />
    </div>
    """
  end

  # A SITE WHOSE ROW HAS GONE, which is what `"raise"` stands in for: an extension's own
  # `sample_pages/1` reads the site before it can name it in a template, and raises exactly this
  # when there is nothing to read. The standings have to say which half of it failed.
  defp sample_pages("raise", _site_id, _actor),
    do: raise(ArgumentError, "there is no site with that id to provision")

  # The attribute maps a page create takes, which is what an extension's `sample_pages/1` hands
  # over — one section for all of them, the way an extension stamps every page it writes.
  defp sample_pages(pages, site_id, _actor) do
    Enum.map(pages, fn {path, template} ->
      %{
        name: "Sample #{path}",
        path: path,
        section: "panelkit",
        description: "A sample page",
        format: :heex,
        template: template,
        active: true,
        site_id: site_id
      }
    end)
  end

  # The dashboards' own answer, in the words they use: a site the page never offered is refused
  # rather than read.
  defp chosen_site(%{assigns: %{sites: sites}}, params) do
    case params["site_id"] do
      asked when is_binary(asked) and asked != "" ->
        Enum.find_value(sites, :refused, fn {_label, id} -> id == asked && id end)

      _nothing_chosen ->
        :none
    end
  end
end
