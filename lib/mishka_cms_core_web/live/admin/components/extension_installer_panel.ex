defmodule MishkaCmsCoreWeb.Live.Admin.Components.ExtensionInstallerPanel do
  @moduledoc """
  Setting an extension up on a site: the form, the report it leaves on screen afterwards, and the
  three places a dashboard puts them.

  Written once here because it was written twice: the blog's card and the document's differed in a
  noun, two flash sentences and a DOM-id prefix, and each carried its own copy of picking a site,
  refusing a picker with no permission, and wording a run that changed nothing.

  ## Wiring

  One call in `mount/3`, two event clauses, one tag:

      socket = ExtensionInstallerPanel.setup(socket, app: :mishka_blog, noun: "blog")

      def handle_event("extension_install", params, socket),
        do: {:noreply, ExtensionInstallerPanel.install(socket, chosen_site(socket, params), socket.assigns.may_provision?)}

      def handle_event("extension_site", params, socket),
        do: {:noreply, ExtensionInstallerPanel.choose(socket, chosen_site(socket, params))}

      <ExtensionInstallerPanel.first_run_screen :if={@showing_installer?} setup={@extension_install} … />
      <ExtensionInstallerPanel.doctor_button setup={@extension_install} id="blog-kit-upgrade" … />
      <ExtensionInstallerPanel.doctor_modal setup={@extension_install} kit={@kit_upgrade} … />

  A dashboard draws the card itself nowhere. Until the site has been set up it IS the screen, under
  `first_run_screen/1`; afterwards it is the Repair half of `doctor_modal/1`, which the header icon
  opens. A set-up site's dashboard is the extension's own work and nothing else.

  Which site it runs against is the dashboard's answer, not this module's — a tenant admin has one
  and a master picks from the ones their page offered — which is the same question
  `MishkaCmsCoreWeb.Live.Admin.Components.KitUpgradePanel` already takes that way.

  ## The report is the point

  An admin pressed a button and is owed the answer, not a flash that the next click clears: what
  arrived, what was written under another name because the one it wanted was taken, and what was
  left alone because something of theirs holds it. A page whose PATH is held is the one that needed
  saying — it was not written, no later run will write it, and only the admin can decide what to do
  about it.

  ## It never writes the second time by itself

  Pressing it again is safe and is meant to be: the run adds only what is missing, so an admin who
  fixed a clash can press it again and get the page they were missing without losing anything they
  have edited.
  """

  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [icon: 1, modal: 1, show_modal: 1]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias MishkaCmsCore.Install.Extensions
  alias MishkaCmsCore.Runtime.{PageProvision, ShareCard}
  alias MishkaCmsCoreWeb.Live.Admin.Components.{KitUpgradePanel, ShareCardRedraw}

  require Logger

  @doc """
  Puts the card's state on the socket.

    * `:app` — the extension's OTP app, which is the key its plugin answers to.
    * `:noun` — what the card calls this extension in a sentence: "blog", "documentation".
  """
  @spec setup(Phoenix.LiveView.Socket.t(), keyword()) :: Phoenix.LiveView.Socket.t()
  def setup(socket, opts) do
    assign(socket, :extension_install, %{
      app: Keyword.fetch!(opts, :app),
      noun: Keyword.fetch!(opts, :noun),
      site_id: nil,
      report: nil,
      message: nil,
      # WHETHER THE SCREEN IS THE INSTALLER OR THE DASHBOARD. `nil` means nobody has said — the
      # first render works it out from the site, and a click either way pins it, so an admin who
      # opens the installer from the badge is not thrown back to the dashboard by the next render.
      showing: nil
    })
  end

  @doc """
  Whether this site has never been set up with this extension — which is what makes the menu open on
  the installer instead of the dashboard.

  Read from the site's own settings, so it survives a restart and answers per site: the same admin
  may run a set-up blog on one and meet the installer on another.

  A site that HAS been set up answers `false` for ever after, and the card is still there to press —
  pressing it again adds only what is missing, which is how an admin repairs a site that lost a page.
  """
  @spec first_run?(Phoenix.LiveView.Socket.t()) :: boolean()
  def first_run?(%{assigns: %{extension_install: state}}),
    do: is_binary(state.site_id) and not Extensions.installed?(state.site_id, state.app)

  def first_run?(_socket), do: false

  @doc """
  Whether this dashboard should draw the installer instead of itself.

  The first visit to an extension nobody has set up on this site, or any visit where the admin asked
  for it from the badge. Pinned once either is true, so a render caused by something else does not
  change what the admin is looking at.
  """
  @spec showing_installer?(Phoenix.LiveView.Socket.t()) :: boolean()
  def showing_installer?(%{assigns: %{extension_install: %{showing: showing}}})
      when is_boolean(showing),
      do: showing

  def showing_installer?(socket), do: first_run?(socket)

  @doc "Opens the installer over the dashboard — what the badge does."
  @spec open(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def open(socket), do: showing(socket, true)

  @doc "Puts the dashboard back, for an admin who came to look rather than to install."
  @spec close(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def close(socket), do: showing(socket, false)

  defp showing(socket, value) do
    state = socket.assigns.extension_install
    assign(socket, :extension_install, %{state | showing: value})
  end

  @doc "Remembers which site the card is about, and clears a report that was about another one."
  @spec choose(Phoenix.LiveView.Socket.t(), String.t() | :none | :refused) ::
          Phoenix.LiveView.Socket.t()
  def choose(socket, site_id) when is_binary(site_id) do
    state = socket.assigns.extension_install

    if state.site_id == site_id,
      do: socket,
      else:
        assign(socket, :extension_install, %{state | site_id: site_id, report: nil, message: nil})
  end

  def choose(socket, _not_a_site), do: socket

  @doc """
  The site the card starts on, before anybody has touched the picker.

  Without it `first_run?/1` has no site on the first render and every dashboard would look set up.
  """
  @spec start_on(Phoenix.LiveView.Socket.t(), String.t() | nil) :: Phoenix.LiveView.Socket.t()
  def start_on(socket, site_id) when is_binary(site_id) do
    state = socket.assigns.extension_install
    assign(socket, :extension_install, %{state | site_id: site_id})
  end

  def start_on(socket, _no_site), do: socket

  @doc """
  Runs the install for `site_id` and leaves the report on the card.

  `allowed?` is the permission the dashboard already computed. Every refusal is worded here, so
  every extension says the same thing.
  """
  @spec install(Phoenix.LiveView.Socket.t(), String.t() | :none | :refused, boolean(), map()) ::
          Phoenix.LiveView.Socket.t()
  def install(socket, site_id, allowed?, answers \\ %{})

  def install(socket, _site_id, false, _answers),
    do: refuse(socket, gettext("You are not allowed to set this site up."))

  def install(socket, :none, _allowed, _answers),
    do: refuse(socket, gettext("Choose the site to set up first."))

  def install(socket, :refused, _allowed, _answers),
    do: refuse(socket, gettext("That is not a site this page can set up."))

  def install(socket, site_id, _allowed, answers) when is_binary(site_id) do
    state = socket.assigns.extension_install

    case Extensions.install(site_id, state.app, answers, socket.assigns[:current_user]) do
      {:ok, report} ->
        socket
        |> assign(:extension_install, %{
          state
          | site_id: site_id,
            report: report,
            message: message(report, state.noun)
        })
        |> put_flash(:info, message(report, state.noun))

      {:error, reason} ->
        # AND WHAT THE SITE DID GET STAYS ON THE SCREEN. A run that fails has usually written
        # something first — the components go in before the pages — so clearing the card here would
        # answer the admin's "what happened?" with less than they had before they pressed it.
        Logger.error("[Installer] #{state.app} on #{site_id}: #{inspect(reason)}")

        socket
        |> assign(:extension_install, %{state | site_id: site_id})
        |> put_flash(
          :error,
          gettext("The %{noun} could not be set up. The logs say why.", noun: state.noun)
        )
    end
  end

  @doc """
  What one run did, worded from what happened rather than from what was asked for.

  A run that finds everything already there is a success with nothing to add, not a failure.
  """
  @spec message(map(), String.t()) :: String.t()
  def message(report, noun) do
    counts =
      [
        {length(Map.get(report, :permissions, [])), &permissions_phrase/1},
        {length(Map.get(report, :components, [])), &components_phrase/1},
        {length(Map.get(report, :pages, [])), &pages_phrase/1},
        {length(Map.get(report, :snippets, [])), &snippets_phrase/1}
      ]
      |> Enum.reject(&(elem(&1, 0) == 0))
      |> Enum.map_join(", ", fn {count, phrase} -> phrase.(count) end)

    added =
      case counts do
        "" ->
          gettext("This site already has everything the %{noun} ships. Nothing to add.",
            noun: noun
          )

        counted ->
          gettext("Added %{counted}.", counted: counted)
      end

    Enum.join(
      [added] ++
        renamed(Map.get(report, :renamed_pages, [])) ++
        left_alone(Map.get(report, :skipped_pages, [])),
      " "
    )
  end

  defp permissions_phrase(count),
    do: ngettext("%{count} permission", "%{count} permissions", count)

  defp components_phrase(count), do: ngettext("%{count} component", "%{count} components", count)
  defp pages_phrase(count), do: ngettext("%{count} page", "%{count} pages", count)
  defp snippets_phrase(count), do: ngettext("%{count} snippet", "%{count} snippets", count)

  # A RENAME AND A SKIP BELONG IN THE SENTENCE, not only in the list below it. The card is scrolled
  # past; the flash is read. "Added six pages" where one of them was written under another name is
  # true and misleading, and the admin finds out when they go looking for a page that is not called
  # what they expect.
  defp renamed([]), do: []

  defp renamed(pages) do
    [
      ngettext(
        "%{count} page created under another name.",
        "%{count} pages created under another name.",
        length(pages)
      )
    ]
  end

  defp left_alone([]), do: []

  # THE TWO KINDS OF SKIP ARE NOT ONE THING. A page whose own row is there is a run repeated; a page
  # something ELSE holds was never written and no later run will write it. Counted together, the
  # second disappears into the first.
  defp left_alone(skipped) do
    {there, elsewhere} = Enum.split_with(skipped, &PageProvision.answered?/1)

    Enum.reject([already_there(length(there)), held_elsewhere(length(elsewhere))], &is_nil/1)
  end

  defp already_there(0), do: nil

  defp already_there(count) do
    ngettext(
      "%{count} page already there, left alone.",
      "%{count} pages already there, left alone.",
      count
    )
  end

  defp held_elsewhere(0), do: nil

  defp held_elsewhere(count) do
    ngettext(
      "%{count} page held by something else.",
      "%{count} pages held by something else.",
      count
    )
  end

  @doc "One line per page written under a name of its own, for the card to list."
  @spec renamed_notes(map()) :: [String.t()]
  def renamed_notes(report),
    do: report |> Map.get(:renamed_pages, []) |> Enum.map(&PageProvision.note/1)

  @doc """
  One line per page left alone, saying which of the two kinds of skip it was.

  A page whose own row is already there is the ordinary case of a run repeated. A page whose NAME or
  PATH a DIFFERENT page holds was never written and no later run will write it — and those are the
  ones the admin has to decide about.
  """
  @spec skipped_notes(map()) :: [String.t()]
  def skipped_notes(report),
    do: report |> Map.get(:skipped_pages, []) |> Enum.map(&PageProvision.note/1)

  @doc """
  The skipped pages somebody ELSE holds — the ones no later run will write, and the only ones an
  admin has to answer for.

  Not `answered?/1`: that asks whether the site serves something at the address, which is true of
  our own page on a second run and of a stranger's page on the first. The difference is the mark a
  provisioned page carries — see `MishkaCmsCore.Runtime.PageProvision.stamp/3` — and it is why that
  mark exists at all.
  """
  @spec clashes(map()) :: [map()]
  def clashes(report),
    do: report |> Map.get(:skipped_pages, []) |> Enum.reject(&Map.get(&1, :ours?, false))

  attr :setup, :map, required: true
  attr :id, :string, required: true
  attr :sites, :list, default: []
  attr :allowed?, :boolean, default: false
  attr :title, :string, required: true
  attr :blurb, :string, required: true
  attr :action, :string, default: nil
  # A CARD ON THE FIRST-RUN SCREEN, A SECTION IN THE DOCTOR MODAL. The same form and the same
  # report either way; only the border around them is the question.
  attr :card?, :boolean, default: true

  # THE FORM AND ITS REPORT, drawn by the two things above that a dashboard actually calls. Private
  # because a dashboard that drew this on its own is what this change took away: a card offering to
  # install an extension the site already had, under the tables, for ever.
  defp panel(assigns) do
    ~H"""
    <div
      :if={@allowed?}
      id={@id}
      class={
        @card? &&
          "rounded-[18px] border border-[#ecebe6] bg-white p-[22px] shadow-[0_1px_2px_rgba(30,28,24,0.04)]"
      }
    >
      <div class="font-['Space_Grotesk'] text-[16px] font-semibold text-[#17161a]">
        {@title}
      </div>
      <div class="mt-[3px] max-w-[640px] text-[12px] font-medium text-[#8a877f]">
        {@blurb}
      </div>

      <%!-- CHANGING THE SITE CLEARS THE REPORT. Without it a master picks another site and reads
            the previous one's answer as though it were about this one. --%>
      <form
        id={"#{@id}-form"}
        phx-change="extension_site"
        phx-submit="extension_install"
        class="mt-[18px] flex flex-wrap items-center gap-2.5"
      >
        <%!-- A CARD WITH NO PICKER STILL SAYS WHICH SITE IT IS ABOUT. In the doctor modal the
              picker is the one at the top — there is only ever one — so without this the submit
              carries no site and a master is told to choose one they have already chosen. --%>
        <input :if={@sites == []} type="hidden" name="site_id" value={@setup.site_id} />

        <select
          :if={@sites != []}
          id={"#{@id}-site"}
          name="site_id"
          aria-label={gettext("Site")}
          class="h-[34px] min-w-[220px] rounded-[9px] border border-[#ecebe6] bg-white px-2.5 text-[12.5px] font-semibold text-[#3a382f]"
        >
          <option
            :for={{label, value} <- @sites}
            value={value}
            selected={@setup.site_id == value}
          >
            {label}
          </option>
        </select>

        <button
          id={"#{@id}-submit"}
          type="submit"
          class="h-[34px] rounded-[9px] bg-[#17161a] px-3.5 text-[12.5px] font-semibold text-white hover:bg-[#2a2830]"
        >
          {@action || gettext("Set up")}
        </button>
      </form>

      <div
        :if={@setup.report}
        id={"#{@id}-report"}
        class="mt-[14px] rounded-xl border border-[#ecebe6] bg-[#f6f5f2] p-[15px]"
      >
        <div id={"#{@id}-added"} class="text-[12px] font-semibold text-[#3a382f]">
          {@setup.message}
        </div>

        <.notes
          :if={renamed_notes(@setup.report) != []}
          id={"#{@id}-renamed"}
          title={gettext("Created under another name")}
          notes={renamed_notes(@setup.report)}
        />

        <.notes
          :if={skipped_notes(@setup.report) != []}
          id={"#{@id}-skipped"}
          title={gettext("Left alone")}
          notes={skipped_notes(@setup.report)}
        />

        <%!-- THE ONE THING AN ADMIN HAS TO ACT ON. A page something else holds was not written and
              no later run will write it, so saying what to do about it is the whole difference
              between a report and a list. --%>
        <%!-- THE ONE THING AN ADMIN HAS TO ANSWER. A page something else holds was not written and
              no later run will write it, so the report asks rather than only reporting: give ours
              another address, or move all of them under one segment. Nothing here touches the page
              that holds the address — it is theirs. --%>
        <form
          :if={clashes(@setup.report) != []}
          id={"#{@id}-clashes"}
          phx-submit="extension_retry"
          class="mt-[13px] rounded-lg border border-[#f3e3c3] bg-[#fdf8ee] p-[13px]"
        >
          <input type="hidden" name="site_id" value={@setup.site_id} />

          <div class="text-[11.5px] font-semibold text-[#8a5514]">
            {gettext(
              "Those addresses belong to pages you already have. Give ours another one, or move them all — nothing of yours is changed either way."
            )}
          </div>

          <label
            :for={clash <- clashes(@setup.report)}
            class="mt-[10px] flex flex-wrap items-center gap-2 text-[12px] font-medium text-[#6d6a63]"
          >
            <span dir="ltr" class="min-w-[180px] font-['JetBrains_Mono'] text-[11.5px] rtl:text-right">{clash.path}</span>
            <input
              type="text"
              name={"paths[#{clash.path}]"}
              dir="ltr"
              placeholder={gettext("a path of its own")}
              class="h-[30px] min-w-[200px] flex-1 rounded-[8px] border border-[#ecebe6] bg-white px-2.5 text-[12px]"
            />
          </label>

          <div class="mt-[11px] flex flex-wrap items-center gap-2 border-t border-[#f3e3c3] pt-[11px]">
            <span class="text-[12px] font-medium text-[#6d6a63]">
              {gettext("Or move them all under")}
            </span>
            <input
              type="text"
              name="prefix"
              dir="ltr"
              placeholder="/mish"
              class="h-[30px] w-[140px] rounded-[8px] border border-[#ecebe6] bg-white px-2.5 text-[12px]"
            />
            <button
              id={"#{@id}-retry"}
              type="submit"
              class="h-[30px] rounded-[8px] bg-[#8a5514] px-3 text-[12px] font-semibold text-white hover:bg-[#6f440f]"
            >
              {gettext("Set up again")}
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  @doc """
  The whole screen an extension shows instead of its dashboard, until it has been set up here.

  A dashboard for an extension a site has never installed is a page of zeroes over pages that do not
  exist, and nothing on it says why or what to do. This says both, and the thing to press is the
  only thing on it.

  `Not now` is a real answer: the dashboard opens, empty, and the badge in its header brings this
  back. Nothing is written by saying no — the site simply stays as it is.
  """
  attr :setup, :map, required: true
  attr :id, :string, required: true
  attr :sites, :list, default: []
  attr :allowed?, :boolean, default: false
  attr :title, :string, required: true
  attr :blurb, :string, required: true

  def first_run_screen(assigns) do
    ~H"""
    <div id={"#{@id}-first-run"} class="mx-auto max-w-[720px] py-[40px]">
      <div class="mb-[6px] text-[11.5px] font-semibold uppercase tracking-[0.14em] text-[#5b57d6]">
        {gettext("Set up")}
      </div>
      <h1 class="m-0 mb-[10px] font-['Newsreader'] text-[30px] font-medium leading-[1.1] tracking-[-0.01em] text-[#17161a]">
        {@title}
      </h1>
      <p class="m-0 mb-[22px] max-w-[560px] text-[13.5px] font-medium leading-relaxed text-[#7c7a75]">
        {@blurb}
      </p>

      <.panel
        setup={@setup}
        id={@id}
        sites={@sites}
        allowed?={@allowed?}
        title={gettext("Install it on this site")}
        blurb={
          gettext(
            "Adds its permission names, the components and the sample pages. Anything already there — including your own edits — is left alone, and you can press this again whenever you like."
          )
        }
      />

      <p :if={!@allowed?} id={"#{@id}-not-allowed"} class="text-[13px] font-medium text-[#8a877f]">
        {gettext(
          "This has not been set up on this site yet, and your account may not set it up. An administrator who may write this site's runtime can do it from here."
        )}
      </p>

      <button
        :if={@allowed?}
        id={"#{@id}-skip"}
        type="button"
        phx-click="extension_skip"
        class="mt-[16px] text-[12.5px] font-semibold text-[#8a877f] underline underline-offset-2 hover:text-[#3a382f]"
      >
        {gettext("Not now — open the dashboard anyway")}
      </button>
    </div>
    """
  end

  @doc """
  The mark in a dashboard's header saying this extension has not been set up on this site, and the
  way back to the installer once the admin has skipped past it.

  Drawn only when there is something to do about it: an extension already installed here needs no
  badge, and an admin who may not install one is not offered a button that would refuse them.
  """
  attr :setup, :map, required: true
  attr :id, :string, required: true
  attr :allowed?, :boolean, default: false

  def badge(assigns) do
    ~H"""
    <button
      :if={@allowed? and not Extensions.installed?(@setup.site_id || "", @setup.app)}
      id={"#{@id}-badge"}
      type="button"
      phx-click="extension_open"
      title={gettext("This site has not been set up with the %{noun} yet", noun: @setup.noun)}
      class="inline-flex h-[30px] items-center gap-1.5 rounded-full border border-[#f3e3c3] bg-[#fdf8ee] px-3 text-[11.5px] font-bold text-[#8a5514] hover:bg-[#fbf1dc]"
    >
      <span class="hero-exclamation-triangle size-[13px]" /> {gettext("Not set up")}
    </button>
    """
  end

  @doc """
  The icon beside a dashboard's Settings button that opens `doctor_modal/1`.

  Never drawn with `badge/1` and never instead of it: a site that has not been set up has nothing
  to compare and is offered the installer, and a site that has been set up has nothing to be warned
  about and is offered the check. Which of the two a header carries is which of the two is true.
  """
  attr :setup, :map, required: true
  attr :id, :string, required: true
  attr :allowed?, :boolean, default: false

  def doctor_button(assigns) do
    ~H"""
    <button
      :if={@allowed? and Extensions.installed?(@setup.site_id || "", @setup.app)}
      id={"#{@id}-open"}
      type="button"
      phx-click={show_modal("#{@id}-doctor")}
      title={gettext("Check and repair the %{noun} on this site", noun: @setup.noun)}
      aria-label={gettext("Check and repair the %{noun} on this site", noun: @setup.noun)}
      class="flex size-10 items-center justify-center rounded-[11px] border border-[#ecebe6] bg-white text-[#5c5a54] transition-colors hover:bg-[#f7f6f3]"
    >
      <.icon name="hero-wrench-screwdriver" class="size-[15px]" />
    </button>
    """
  end

  @doc """
  Everything an admin does to an extension on a site that already has it, behind one icon.

  A dashboard is for the extension's own work, and a set-up site needs none of this until the day
  it does — so it is a modal rather than two cards under the tables, which is what this was: one
  card to install on a site that already had it, and another to compare, both drawn for ever on a
  dashboard where both were nearly always nothing to do.

  One site picker for the whole modal. Choosing in it is itself the check — see
  `MishkaCmsCoreWeb.Live.Admin.Components.KitUpgradePanel` — and the dashboard's `kit_check` clause
  hands the same site to `choose/2`, so the Repair below writes to the site whose standings are on
  screen rather than to whichever one the page opened on.

  When the extension answers `MishkaCmsCore.Runtime.ShareCard.targets_event/0` under its app's
  name, the modal ends with a button that draws its own share cards on that site again
  (`MishkaCmsCoreWeb.Live.Admin.Components.ShareCardRedraw`).
  """
  attr :id, :string, required: true
  attr :install_id, :string, required: true
  attr :setup, :map, required: true
  attr :kit, :map, required: true
  attr :sites, :list, default: []
  attr :site_name, :string, default: nil
  attr :allowed?, :boolean, default: false
  attr :title, :string, required: true

  def doctor_modal(assigns) do
    ~H"""
    <.modal :if={@allowed?} id={"#{@id}-doctor"}>
      <div id={@id}>
        <div class="font-['Space_Grotesk'] text-[17px] font-semibold text-[#17161a]">
          {@title}
        </div>
        <div class="mt-[4px] max-w-[560px] text-[12.5px] font-medium text-[#8a877f]">
          {gettext(
            "Compares what this site has with what this version ships, and puts back anything it has lost. Nothing is written until you press one of the buttons below."
          )}
        </div>

        <form
          id={"#{@id}-form"}
          phx-change="kit_check"
          phx-submit="kit_check"
          class="mt-[18px] flex flex-wrap gap-2.5"
        >
          <%!-- A TENANT ADMIN HAS ONE SITE AND IS SHOWN IT, not a dropdown they cannot move. The
                page never reads a site out of this form for them — `chosen_site/2` answers with
                their own whatever arrives — so this says which site the buttons below are about
                and submits nothing. A master gets the picker. --%>
          <div
            :if={@sites == [] and @site_name}
            id={"#{@id}-site-fixed"}
            class="flex h-[42px] min-w-[220px] flex-1 items-center rounded-xl border border-[#ecebe6] bg-[#f6f5f2] px-[15px] text-[12.5px] font-semibold text-[#6d6a63]"
          >
            {@site_name}
          </div>

          <select
            :if={@sites != []}
            id={"#{@id}-site"}
            name="site_id"
            aria-label={gettext("Site")}
            class="h-[42px] min-w-[220px] flex-1 cursor-pointer appearance-none rounded-xl border border-[#ecebe6] bg-white px-[15px] text-[12.5px] font-semibold text-[#3a382f] outline-none"
          >
            <option
              :for={{label, value} <- @sites}
              value={value}
              selected={(@kit.site_id || @setup.site_id) == value}
            >
              {label}
            </option>
          </select>

          <button
            id={"#{@id}-check"}
            type="submit"
            class="flex h-[42px] items-center gap-[11px] rounded-xl border border-[#ecebe6] bg-white px-[15px] text-[12.5px] font-semibold text-[#3a382f] transition-colors hover:bg-[#f6f5f2]"
          >
            <.icon name="hero-arrow-path" class="size-4 text-[#6d6a63]" /> {gettext(
              "Check for updates"
            )}
          </button>
        </form>

        <%!-- THE STANDINGS SCROLL, THE MODAL DOES NOT. A site with every component and every
              sample page listed is taller than the screen, and a modal that grows past it takes
              its own picker and its own Repair button off the top and bottom with it. --%>
        <div class="max-h-[42vh] overflow-y-auto">
          <KitUpgradePanel.standings setup={@kit} id={@id} />
        </div>

        <div class="mt-[18px] border-t border-[#ecebe6] pt-[16px]">
          <.panel
            setup={@setup}
            id={@install_id}
            sites={[]}
            allowed?={@allowed?}
            card?={false}
            action={gettext("Repair")}
            title={gettext("Put back what is missing")}
            blurb={
              gettext(
                "Installs any component or page this site has lost. Anything already here — including your own edits — is left alone, so this is safe to press whenever you like."
              )
            }
          />
        </div>

        <div
          :if={share_cards?(@setup, @kit)}
          id={"#{@id}-share-cards"}
          class="mt-[18px] border-t border-[#ecebe6] pt-[16px]"
        >
          <.live_component
            module={ShareCardRedraw}
            id={"#{@id}-share-cards-redraw"}
            site_id={@kit.site_id || @setup.site_id}
            producer={Atom.to_string(@setup.app)}
            allowed?={@allowed?}
            title={gettext("Redraw the %{noun}'s share cards", noun: @setup.noun)}
            blurb={
              gettext(
                "Draws every share card the %{noun} shows on this site again, one at a time, in the background.",
                noun: @setup.noun
              )
            }
            action={gettext("Redraw")}
          />
        </div>
      </div>
    </.modal>
    """
  end

  # Whether the extension draws share cards of its own on the site the modal is about.
  defp share_cards?(setup, kit) do
    case kit.site_id || setup.site_id do
      site_id when is_binary(site_id) -> Atom.to_string(setup.app) in ShareCard.producers(site_id)
      _no_site -> false
    end
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :notes, :list, required: true

  defp notes(assigns) do
    ~H"""
    <div class="mt-[11px]">
      <div class="text-[11px] font-semibold uppercase tracking-[0.06em] text-[#8a877f]">
        {@title}
      </div>

      <ul id={@id} class="mt-[7px] flex flex-col gap-[5px]">
        <li
          :for={{note, index} <- Enum.with_index(@notes)}
          id={"#{@id}-#{index}"}
          class="text-[12px] font-medium text-[#6d6a63]"
        >
          {note}
        </li>
      </ul>
    </div>
    """
  end

  defp refuse(socket, message), do: put_flash(socket, :error, message)
end
