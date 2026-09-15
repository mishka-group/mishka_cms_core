defmodule MishkaCmsCoreWeb.Live.Admin.Components.KitUpgradePanel do
  @moduledoc """
  Where a site stands against the version of an extension it is running, read and drawn.

  Setting a site up installs what it is missing and never touches what it has, which is the only
  safe thing a button called "Set up" can do — and it leaves a site that was provisioned months ago
  on months-old components and months-old pages for ever. This is the other half, and it has two
  halves of its own because a site has two things to fall behind on:

    * `MishkaCmsCore.Runtime.Handlers.UiKitUpgrade` says where each of the kit's COMPONENTS stands,
      and writes the ones the admin chooses;
    * `MishkaCmsCore.Runtime.PageSamples` says where each of the extension's sample PAGES stands,
      and offers the newer ones as drafts. A page is somebody's work in a way a kit component is
      not — it is what their readers are looking at — so nothing here writes a live page at all.
      A page whose newer version draws a component this site has not got is not offered either:
      the two halves fall behind together, and publishing that draft would put an error message
      where the block should be.

  Both report BEFORE anything is written, and the admin decides.

  ## Wiring

  One call in `mount/3` and three event clauses. Nothing draws this directly: `standings/1` is
  drawn inside the modal
  `MishkaCmsCoreWeb.Live.Admin.Components.ExtensionInstallerPanel.doctor_modal/1` opens, which is
  where the site picker and the `kit_check` form live.

      socket =
        KitUpgradePanel.setup(socket,
          bundle: MishkaBlog.Kit.bundle_path(),
          noun: "blog components",
          pages: &MishkaBlog.Provision.sample_pages/2,
          draft_label: "Blog sample page"
        )

      def handle_event("kit_check", params, socket),
        do: {:noreply, KitUpgradePanel.check(socket, chosen_site(socket, params), socket.assigns.may_provision?)}

      def handle_event("kit_upgrade", %{"mode" => mode}, socket),
        do: {:noreply, KitUpgradePanel.upgrade(socket, mode, socket.assigns.may_provision?)}

      def handle_event("page_drafts", _params, socket),
        do: {:noreply, KitUpgradePanel.offer(socket, socket.assigns.may_provision?)}

  Which site the check runs against is the dashboard's answer, not this module's: a tenant admin has
  one site and a master picks from the ones their page offered, and that is the same question the
  "Set up" button already answers. `check/3` takes what `chosen_site/2` decided — a site id, `:none`
  or `:refused` — and the permission the dashboard already computed, so the wording of a refusal is
  written once here rather than once per extension.

  ## Why the two component buttons are two

  The write is `upgrade!/3` with `:safe` or `:all`, and nothing here presses `:all` on the
  admin's behalf. A row whose fingerprint no longer matches what the kit installed is a row
  somebody worked on, and the only honest thing to do with it is to say so and wait — which is why
  the second button spells out that the version being replaced stays in the component's history.

  The pages have one button and it is the safe one, because there is no unsafe one to offer: a draft
  is the whole of what this can do to a page.
  """

  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  alias MishkaCmsCore.Runtime.Handlers.UiKitUpgrade
  alias MishkaCmsCore.Runtime.PageSamples

  require Logger

  @doc """
  One-call wiring for a dashboard: assigns `@kit_upgrade`, which `standings/1` is given whole.

  ## Options

    * `:bundle` — the extension's bundle path, e.g. `MishkaBlog.Kit.bundle_path()`.
    * `:noun` — what this kit's components are called in a sentence ("blog components"), used
      when a read or a write fails and the admin is told which of them it was about.
    * `:pages` — a two-argument function from a site id and the actor to the extension's sample
      pages as attribute maps, e.g. `&MishkaBlog.Provision.sample_pages/2`. The same function the "Set up"
      button's own pages come from, so this cannot be comparing against different ones.
    * `:draft_label` — what a draft this creates is called in the builder's picker.
  """
  @spec setup(Phoenix.LiveView.Socket.t(), keyword()) :: Phoenix.LiveView.Socket.t()
  def setup(socket, opts) do
    assign(socket, :kit_upgrade, %{
      bundle: Keyword.fetch!(opts, :bundle),
      noun: Keyword.fetch!(opts, :noun),
      pages: Keyword.fetch!(opts, :pages),
      draft_label: Keyword.fetch!(opts, :draft_label),
      site_id: nil,
      plan: nil,
      pages_plan: nil,
      message: nil,
      pages_message: nil
    })
  end

  @doc """
  Reads where the site stands and puts it on the socket. Writes nothing.

  `site_id` is whatever the dashboard's own site check returned, and `allowed?` the permission it
  already computed — both refusals are answered here so every extension says the same thing.
  """
  @spec check(Phoenix.LiveView.Socket.t(), String.t() | :none | :refused, boolean()) ::
          Phoenix.LiveView.Socket.t()
  def check(socket, _site_id, false),
    do: refuse(socket, gettext("You are not allowed to update this site's components."))

  def check(socket, :none, _allowed),
    do: refuse(socket, gettext("Choose the site to check first."))

  def check(socket, :refused, _allowed),
    do: refuse(socket, gettext("That is not a site this page can update."))

  def check(socket, site_id, _allowed) when is_binary(site_id) do
    setup = socket.assigns.kit_upgrade

    case UiKitUpgrade.plan(setup.bundle, site_id, actor(socket)) do
      {:ok, plan} -> checked(socket, setup, site_id, plan)
      {:error, reason} -> failed(socket, setup, "read against the bundle", reason)
    end
  rescue
    error -> failed(socket, socket.assigns.kit_upgrade, "read against the bundle", error)
  end

  # THE PAGES READ IS RESCUED WHERE IT IS MADE, not with the components' one. `setup.pages` raises
  # on a site row that has gone and `PageSamples.plan/2` raises on anything Ash refuses, and both
  # arrived at the rescue around the bundle read — where the admin was told the COMPONENTS could not
  # be read and sent to the logs to look for something that is not there.
  #
  # The components' report is still drawn when this half fails: half an answer is what the admin came
  # for, and the sentence beside it says which half is missing.
  defp checked(socket, setup, site_id, plan) do
    {pages_plan, socket} = pages_plan(socket, setup, site_id)

    assign(socket, :kit_upgrade, %{
      setup
      | site_id: site_id,
        plan: plan,
        pages_plan: pages_plan,
        message: nil,
        pages_message: nil
    })
  end

  defp pages_plan(socket, setup, site_id) do
    actor = actor(socket)

    {PageSamples.plan(site_id, setup.pages.(site_id, actor), actor), socket}
  rescue
    error -> {nil, refused_pages(socket, setup, "read", error)}
  end

  @doc """
  Writes the components the admin asked for and redraws the standings from the database afterwards.

  `mode` comes from the button that was pressed, so anything but `"all"` is taken as the safe
  half — an unexpected value cannot be read as permission to write over an edited row.
  """
  @spec upgrade(Phoenix.LiveView.Socket.t(), String.t(), boolean()) :: Phoenix.LiveView.Socket.t()
  def upgrade(socket, _mode, false),
    do: refuse(socket, gettext("You are not allowed to update this site's components."))

  def upgrade(%{assigns: %{kit_upgrade: %{site_id: nil}}} = socket, _mode, _allowed),
    do: refuse(socket, gettext("Check for updates first."))

  def upgrade(socket, mode, _allowed) do
    setup = socket.assigns.kit_upgrade

    case UiKitUpgrade.upgrade!(setup.bundle, setup.site_id,
           include: include(mode),
           actor: actor(socket)
         ) do
      {:ok, report} ->
        socket
        |> check(setup.site_id, true)
        |> announce(:message, UiKitUpgrade.message(report))

      {:error, reason} ->
        failed(socket, setup, "updated", reason)
    end
  rescue
    error -> failed(socket, socket.assigns.kit_upgrade, "updated", error)
  end

  @doc """
  Offers every sample page the site is behind on as a draft of itself, and redraws the standings
  from the database afterwards.

  Takes no mode, because there is only one thing to do: a draft is not a change to anything anybody
  is reading, so there is no second, riskier button for the admin to be asked about.
  """
  @spec offer(Phoenix.LiveView.Socket.t(), boolean()) :: Phoenix.LiveView.Socket.t()
  def offer(socket, false),
    do: refuse(socket, gettext("You are not allowed to update this site's pages."))

  def offer(%{assigns: %{kit_upgrade: %{site_id: nil}}} = socket, _allowed),
    do: refuse(socket, gettext("Check for updates first."))

  def offer(socket, _allowed) do
    setup = socket.assigns.kit_upgrade

    actor = actor(socket)

    report =
      PageSamples.offer!(setup.site_id, setup.pages.(setup.site_id, actor),
        label: setup.draft_label,
        actor: actor
      )

    socket
    |> check(setup.site_id, true)
    |> announce(:pages_message, PageSamples.message(report))
  rescue
    error -> refused_pages(socket, socket.assigns.kit_upgrade, "offered as drafts", error)
  end

  # A REFUSED WRITE IS NOT AN `{:error, _}`. Both calls reach Ash through `read!`, `create!` and
  # `update!`, and `Ash.transaction/3` re-raises whatever they raise — so a template the bundle
  # cannot compile, a stateful component with nowhere to sit or a check constraint arrives here as
  # an exception. Without this the admin's answer to pressing Update is a dead LiveView and a
  # reconnect. The Repair button in the same modal rescues for the same reason and says the same
  # kind of thing.
  defp failed(socket, setup, what, reason) do
    Logger.error("[KitUpgradePanel] #{setup.bundle} could not be #{what}: #{detail(reason)}")

    refuse(socket, failed_message(what, setup.noun))
  end

  defp failed_message("read against the bundle", noun),
    do: gettext("The %{noun} could not be read against the bundle. The logs say why.", noun: noun)

  defp failed_message("updated", noun),
    do: gettext("The %{noun} could not be updated. The logs say why.", noun: noun)

  # THE PAGES ARE NOT THE KIT, so a failure on them does not say the components' name back to the
  # admin: the two halves fail for different reasons and an admin sent to the logs has
  # to know which half to read about.
  defp refused_pages(socket, setup, what, reason) do
    Logger.error(
      "[KitUpgradePanel] #{setup.bundle} sample pages could not be #{what}: #{detail(reason)}"
    )

    refuse(socket, refused_pages_message(what))
  end

  defp refused_pages_message("read"),
    do: gettext("The sample pages could not be read. The logs say why.")

  defp refused_pages_message("offered as drafts"),
    do: gettext("The sample pages could not be offered as drafts. The logs say why.")

  defp detail(%{__exception__: true} = error), do: Exception.message(error)
  defp detail(reason), do: inspect(reason)

  attr :setup, :map, required: true
  attr :id, :string, required: true

  @doc """
  Where the site stands, given the `@kit_upgrade` assign `setup/2` wrote: the components in one
  block and the pages in the other, neither drawn until `check/3` has read.

  The site picker and the `kit_check` form that fill these in belong to the modal these are drawn
  in — `MishkaCmsCoreWeb.Live.Admin.Components.ExtensionInstallerPanel.doctor_modal/1`.
  """
  def standings(assigns) do
    ~H"""
    <div
      :if={@setup.plan}
      id={"#{@id}-report"}
      class="mt-[14px] rounded-xl border border-[#ecebe6] bg-[#f6f5f2] p-[15px]"
    >
      <div id={"#{@id}-headline"} class="text-[12px] font-semibold text-[#3a382f]">
        {@setup.message || headline(@setup.plan)}
      </div>

      <.group
        id={"#{@id}-ready"}
        label={gettext("Ready to update")}
        entries={@setup.plan.outdated}
        note={&UiKitUpgrade.note/1}
      >
        <button
          id={"#{@id}-safe"}
          type="button"
          phx-click="kit_upgrade"
          phx-value-mode="safe"
          class="mt-[11px] flex h-[40px] items-center gap-[9px] rounded-xl border border-[#dcdbf5] bg-[#f2f1fc] px-[15px] text-[12.5px] font-semibold text-[#4f4bcc] transition-colors hover:bg-[#e9e7fb]"
        >
          <.icon name="hero-arrow-up-tray" class="size-4" />
          {ngettext(
            "Update %{count} component",
            "Update %{count} components",
            length(@setup.plan.outdated)
          )}
        </button>
      </.group>

      <.group
        id={"#{@id}-choice"}
        label={gettext("Edited here since install")}
        entries={@setup.plan.choice}
        note={&UiKitUpgrade.note/1}
      >
        <div class="mt-[7px] text-[11.5px] font-medium text-[#6d6a63]">
          {gettext(
            "Updating these replaces what is on the site now. What each holds today is kept in the component's history, so you can restore it from there."
          )}
        </div>

        <button
          id={"#{@id}-all"}
          type="button"
          phx-click="kit_upgrade"
          phx-value-mode="all"
          class="mt-[11px] flex h-[40px] items-center gap-[9px] rounded-xl border border-[#f0dcc2] bg-[#fbf3e6] px-[15px] text-[12.5px] font-semibold text-[#a5691a] transition-colors hover:bg-[#f7ecda]"
        >
          <.icon name="hero-exclamation-triangle" class="size-4" />
          {ngettext(
            "Update these %{count} component too",
            "Update these %{count} components too",
            length(@setup.plan.choice)
          )}
        </button>
      </.group>

      <.group
        id={"#{@id}-current"}
        label={gettext("Up to date")}
        entries={@setup.plan.current}
        note={&UiKitUpgrade.note/1}
      />
      <.group
        id={"#{@id}-archived"}
        label={gettext("Archived here")}
        entries={@setup.plan.archived}
        note={&UiKitUpgrade.note/1}
      />

      <.group
        id={"#{@id}-absent"}
        label={gettext("Not on this site")}
        entries={@setup.plan.absent}
        note={&UiKitUpgrade.note/1}
      >
        <div class="mt-[7px] text-[11.5px] font-medium text-[#6d6a63]">
          {gettext("An update never installs a component a site does not have — Repair, below, does.")}
        </div>
      </.group>
    </div>

    <%!-- THE PAGES, UNDER THE SAME CHECK. A site falls behind on both at once — the blog's
            featured strip became a component of its own and the index page that places it was
            rewritten in the same commit — so an admin who is told about one and not the other
            takes half an update and wonders why nothing looks different. --%>
    <div
      :if={@setup.pages_plan}
      id={"#{@id}-pages"}
      class="mt-[14px] rounded-xl border border-[#ecebe6] bg-[#f6f5f2] p-[15px]"
    >
      <div id={"#{@id}-pages-headline"} class="text-[12px] font-semibold text-[#3a382f]">
        {@setup.pages_message || pages_headline(@setup.pages_plan)}
      </div>

      <div
        :if={not @setup.pages_plan.serves_pages?}
        id={"#{@id}-pages-mode"}
        class="mt-[7px] text-[11.5px] font-medium text-[#a5691a]"
      >
        {gettext(
          "This site is API-only, so it answers 403 for every one of these pages until its mode changes. They are kept up to date all the same."
        )}
      </div>

      <.group
        id={"#{@id}-pages-behind"}
        label={gettext("Behind the pages this version ships")}
        entries={@setup.pages_plan.outdated}
        note={&PageSamples.note/1}
      >
        <div class="mt-[7px] text-[11.5px] font-medium text-[#6d6a63]">
          {gettext(
            "Each one is offered as a draft of the page it belongs to. Nothing your readers see changes until you open the page in the builder and publish the draft yourself."
          )}
        </div>

        <button
          id={"#{@id}-pages-offer"}
          type="button"
          phx-click="page_drafts"
          class="mt-[11px] flex h-[40px] items-center gap-[9px] rounded-xl border border-[#dcdbf5] bg-[#f2f1fc] px-[15px] text-[12.5px] font-semibold text-[#4f4bcc] transition-colors hover:bg-[#e9e7fb]"
        >
          <.icon name="hero-document-plus" class="size-4" />
          {ngettext(
            "Create %{count} draft",
            "Create %{count} drafts",
            length(@setup.pages_plan.outdated)
          )}
        </button>
      </.group>

      <.group
        id={"#{@id}-pages-blocked"}
        label={gettext("Waiting on components")}
        entries={@setup.pages_plan.blocked}
        note={&PageSamples.note/1}
      >
        <div class="mt-[7px] text-[11.5px] font-medium text-[#6d6a63]">
          {gettext(
            "A page is not offered while a component it draws is missing, archived or switched off here: the page would answer with a red \"failed to render\" line where that block should be. Install or restore them — Repair, below, puts back the ones this extension ships — and check again."
          )}
        </div>
      </.group>

      <.group
        id={"#{@id}-pages-waiting"}
        label={gettext("Waiting as a draft")}
        entries={@setup.pages_plan.offered}
        note={&PageSamples.note/1}
      />
      <.group
        id={"#{@id}-pages-current"}
        label={gettext("Up to date")}
        entries={@setup.pages_plan.current}
        note={&PageSamples.note/1}
      />

      <.group
        id={"#{@id}-pages-taken"}
        label={gettext("Somebody else's address")}
        entries={@setup.pages_plan.taken}
        note={&PageSamples.note/1}
      >
        <div class="mt-[7px] text-[11.5px] font-medium text-[#6d6a63]">
          {gettext(
            "Repair leaves these alone as well: the site answers there already, with a page that is not one of ours."
          )}
        </div>
      </.group>

      <.group
        id={"#{@id}-pages-archived"}
        label={gettext("Archived here")}
        entries={@setup.pages_plan.archived}
        note={&PageSamples.note/1}
      >
        <div class="mt-[7px] text-[11.5px] font-medium text-[#6d6a63]">
          {gettext(
            "Nothing is written to an archived page, here or by Repair. Restore it from the page list and check again."
          )}
        </div>
      </.group>

      <.group
        id={"#{@id}-pages-absent"}
        label={gettext("Not on this site")}
        entries={@setup.pages_plan.absent}
        note={&PageSamples.note/1}
      >
        <div class="mt-[7px] text-[11.5px] font-medium text-[#6d6a63]">
          {gettext("This never creates a page a site does not have — Repair, below, does.")}
        </div>
      </.group>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :entries, :list, required: true
  attr :note, :any, required: true
  slot :inner_block

  # One group of the report, whichever report it is: the component standings and the page standings
  # are the same shape, and each says what its own `note` says. Drawn only when it has rows in it —
  # an empty "Edited here since install" heading reads as a warning on a site that has none.
  defp group(assigns) do
    ~H"""
    <div :if={@entries != []} id={@id} class="mt-[14px] first:mt-[11px]">
      <div class="text-[11px] font-semibold uppercase tracking-[0.06em] text-[#8a877f]">
        {@label} · {length(@entries)}
      </div>

      <ul class="mt-[7px] flex flex-col gap-[5px]">
        <li
          :for={{entry, index} <- Enum.with_index(@entries)}
          id={"#{@id}-#{index}"}
          class="text-[12px] font-medium text-[#6d6a63]"
        >
          <span class="font-semibold text-[#3a382f]">{entry.name}</span> — {@note.(entry)}
        </li>
      </ul>

      {render_slot(@inner_block)}
    </div>
    """
  end

  # What the standings say before anything has been pressed: the kit, the version on disk, and whether
  # there is anything to do at all.
  #
  # THE SAME FIRST ANSWER `message/1` GIVES, and for the same reason. A site whose rows of this kit
  # are all archived or all gone has nothing an upgrade can speak for, and telling the admin that
  # everything is up to date reads as a failure to look — which on the read-only path is the
  # FIRST thing they see, before any button has been pressed.
  defp headline(%{current: [], outdated: [], choice: []} = plan),
    do:
      gettext("%{kit} %{version} — this site has none of this kit's components in use.",
        kit: plan.kit,
        version: plan.version
      )

  defp headline(%{outdated: [], choice: []} = plan),
    do:
      gettext("%{kit} %{version} — everything this site has is up to date.",
        kit: plan.kit,
        version: plan.version
      )

  defp headline(plan) do
    waiting = length(plan.outdated) + length(plan.choice)

    ngettext(
      "%{kit} %{version} — %{count} component behind the bundle.",
      "%{kit} %{version} — %{count} components behind the bundle.",
      waiting,
      kit: plan.kit,
      version: plan.version
    )
  end

  # The same sentence for the pages, and the same reason for each of its clauses: a site holding
  # none of them is not a site where everything is up to date, and one whose behind pages already
  # have drafts waiting has nothing for the button to do without anything being wrong.
  #
  # AND NEITHER IS A SITE HOLDING SOME OF THEM. "Every sample page on this site is the one this
  # version ships" fired on a site holding one of six, with the other five listed underneath it —
  # and it is the first thing the admin reads.
  defp pages_headline(%{current: [], outdated: [], offered: [], blocked: []}),
    do: gettext("This site has none of the sample pages this version ships.")

  defp pages_headline(%{outdated: [_ | _]} = plan),
    do:
      ngettext(
        "%{count} of your sample pages is not the one this version ships — create a draft?",
        "%{count} of your sample pages are not the ones this version ships — create drafts?",
        length(plan.outdated)
      )

  defp pages_headline(%{offered: [], blocked: [_ | _]} = plan),
    do:
      ngettext(
        "%{count} sample page behind, waiting on components this site does not have — set it up first.",
        "%{count} sample pages behind, waiting on components this site does not have — set it up first.",
        length(plan.blocked)
      )

  defp pages_headline(%{offered: [_ | _]} = plan),
    do:
      ngettext(
        "%{count} sample page is behind, and its draft is waiting in the builder.",
        "%{count} sample pages are behind, and their drafts are waiting in the builder.",
        length(plan.offered)
      )

  defp pages_headline(%{taken: [], archived: [], absent: []}),
    do: gettext("Every sample page on this site is the one this version ships.")

  defp pages_headline(plan) do
    elsewhere = length(plan.taken) + length(plan.archived) + length(plan.absent)

    gettext("%{current}, and %{elsewhere}.",
      current:
        ngettext(
          "%{count} sample page on this site is up to date",
          "%{count} sample pages on this site are up to date",
          length(plan.current)
        ),
      elsewhere: ngettext("%{count} page is not here", "%{count} pages are not here", elsewhere)
    )
  end

  defp include("all"), do: :all
  defp include(_safe), do: :safe

  # THE HALF THAT WAS PRESSED, and only it. The two reports sit one above the other and
  # each keeps its own headline, so updating components does not leave a sentence about components
  # standing over the pages.
  defp announce(socket, key, message) do
    socket
    |> assign(:kit_upgrade, Map.put(socket.assigns.kit_upgrade, key, message))
    |> Phoenix.LiveView.put_flash(:info, message)
  end

  # THE ACTOR IS ALREADY ON THE SOCKET. A dashboard is a session and `:current_user` is who it is
  # for, so nothing has to be handed in and nothing can go stale between the mount and the click.
  # A host with no user — a test standing in for a dashboard — is a system caller, and the
  # provisioners answer that the way they always have.
  defp actor(socket), do: socket.assigns[:current_user]

  defp refuse(socket, message), do: Phoenix.LiveView.put_flash(socket, :error, message)
end
