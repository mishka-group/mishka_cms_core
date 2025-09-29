defmodule MishkaCmsCoreWeb.Live.Admin.Components.UserDetailsModal do
  @moduledoc """
  User record modal: a read-only **view** of a user (id, email, site, confirmation status, permissions)
  that flips to the editable `MishkaGervaz.Form.Web.Live` user form via the **Edit User** button, and
  hosts the create form when opened with no record (the "+ Add User" flow).

  Shares the modal shell + card helpers with the runtime preview / site modals through
  `MishkaCmsCoreWeb.Live.Admin.Components.DetailModal` (used here without a tab bar — `tabs={[]}`). Driven
  by the parent's `@user_modal` map (`record`, `edit_mode?`, `loading?`, `form_record_id`); the form's
  `record_id` flows through the template (NOT `send_update`) so a parent re-render can't reset it, and the
  form stays mounted across the view/edit toggle. See the parent
  `MishkaCmsCoreWeb.Live.Admin.Dashboard.Account.User.Index`.
  """
  use Phoenix.Component
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCoreWeb.Live.Admin.Components.DetailModal

  import MishkaCmsCore.CoreComponents, only: [icon: 1]
  import DetailModal, only: [datetime: 1]

  @modal_id "user-details-modal"
  @head_button "inline-flex h-9 items-center gap-[7px] rounded-[10px] border border-[#ecebe6] bg-white px-[13px] text-[12px] font-semibold transition-colors"

  attr :user_modal, :map, required: true
  attr :current_user, :any, default: nil

  def modal(assigns) do
    um = assigns.user_modal

    assigns =
      assigns
      |> assign(:modal_id, @modal_id)
      |> assign(:record, um.record)
      |> assign(:edit_mode?, Map.get(um, :edit_mode?) == true)
      |> assign(:loading?, Map.get(um, :loading?) == true)
      |> assign(:form_record_id, Map.get(um, :form_record_id))
      |> assign(:allowed, Map.get(um, :allowed, []))
      |> assign(:head_button, @head_button)
      |> assign(:form_id, MishkaGervaz.Resource.Info.Form.component_id(User))

    ~H"""
    <DetailModal.shell
      id={@modal_id}
      icon="hero-user"
      icon_class="bg-gradient-to-br from-indigo-500 to-violet-600"
      max_width="max-w-2xl"
      title={
        if(@record,
          do: dgettext("mishka_gervaz", "User Details"),
          else: dgettext("mishka_gervaz", "Add User")
        )
      }
      active_tab="view"
      tabs={[]}
      tab_event="noop"
      close_event="close_user_modal"
    >
      <:subtitle>
        <span class="text-xs text-zinc-500">{gettext("View and manage user information")}</span>
      </:subtitle>

      <:actions :if={@record}>
        <button
          :if={:confirm_by_admin in @allowed and is_nil(@record.confirmed_at)}
          type="button"
          id="user-modal-confirm"
          phx-click="user_modal_confirm"
          data-confirm={
            dgettext(
              "mishka_gervaz",
              "Confirm this account's email address without the confirmation email?"
            )
          }
          class={[@head_button, "text-[#5c5a54] hover:bg-[#f7f6f3]"]}
        >
          <.icon name="hero-check-badge" class="size-4" /> {gettext("Confirm account")}
        </button>
      </:actions>

      <div class="max-h-[72vh] overflow-y-auto px-6 py-5">
        <div :if={@loading? and is_nil(@record)} class="py-16 text-center text-sm text-zinc-400">
          {gettext("Loading…")}
        </div>

        <div :if={@record && not @edit_mode?} class="space-y-4">
          {view(assigns)}
        </div>

        <%!-- Form stays mounted so its template-driven record_id survives the view/edit toggle --%>
        <div class={[not @edit_mode? && "hidden"]}>
          <.live_component
            module={MishkaGervaz.Form.Web.Live}
            id={@form_id}
            resource={User}
            current_user={@current_user}
            record_id={@form_record_id}
          />
        </div>
      </div>
    </DetailModal.shell>
    """
  end

  defp view(assigns) do
    confirmed? = !is_nil(assigns.record.confirmed_at)
    site_name = if loaded?(assigns.record.site), do: assigns.record.site.name

    permissions =
      assigns.record.permissions
      |> List.wrap()
      |> Enum.reject(&match?(%Ash.NotLoaded{}, &1))
      |> Enum.map(& &1.name)

    assigns =
      assigns
      |> assign(:confirmed?, confirmed?)
      |> assign(:site_name, site_name)
      |> assign(:permissions, permissions)

    ~H"""
    <div class="grid gap-4 sm:grid-cols-2">
      <.field label={gettext("User ID")}>
        <span dir="ltr" class="font-mono text-sm text-zinc-800">{@record.id}</span>
      </.field>

      <.field label={gettext("Email")}>
        <span class="inline-flex items-center gap-1.5">
          <.icon name="hero-envelope" class="size-4 text-zinc-400" />
          <span dir="ltr" class="truncate">{to_string(@record.email)}</span>
        </span>
      </.field>

      <.field label={gettext("Site")}>
        <span class="inline-flex items-center gap-1.5">
          <.icon name="hero-building-office-2" class="size-4 text-zinc-400" />
          {if is_nil(@record.site_id),
            do: gettext("Global"),
            else: @site_name || gettext("Unknown")}
        </span>
      </.field>

      <.field label={gettext("Confirmation Status")}>
        <span :if={@confirmed?} class="inline-flex items-center gap-1.5">
          <.icon name="hero-check-circle" class="size-5 text-green-600" />
          <span class="leading-tight">
            <span class="block font-medium text-green-700">{gettext("Confirmed")}</span>
            <span class="block text-xs text-zinc-400">{datetime(@record.confirmed_at)}</span>
          </span>
        </span>
        <span :if={!@confirmed?} class="inline-flex items-center gap-1.5">
          <.icon name="hero-x-circle" class="size-5 text-rose-500" />
          <span class="leading-tight">
            <span class="block font-medium text-rose-600">{gettext("Pending")}</span>
            <span class="block text-xs text-zinc-400">{gettext("Not confirmed")}</span>
          </span>
        </span>
      </.field>
    </div>

    <div>
      <dt class="mb-1 text-xs text-zinc-400">{gettext("Permissions")}</dt>
      <dd class="rounded-lg bg-zinc-50 px-3 py-2">
        <div :if={@permissions != []} class="flex flex-wrap gap-1.5">
          <span
            :for={name <- @permissions}
            class="inline-flex rounded-full bg-rose-50 px-2 py-0.5 text-xs font-medium text-rose-700"
          >
            {name}
          </span>
        </div>
        <span :if={@permissions == []} class="text-sm text-zinc-400">—</span>
      </dd>
    </div>

    <div class="flex items-center justify-end gap-3 border-t border-zinc-100 pt-4">
      <button
        type="button"
        phx-click={DetailModal.dismiss(@modal_id, "close_user_modal")}
        class="rounded-lg border border-zinc-200 px-4 py-2 text-sm font-medium text-zinc-700 hover:bg-zinc-50"
      >
        {gettext("Close")}
      </button>
      <button
        type="button"
        phx-click="user_modal_toggle_edit"
        class="inline-flex items-center gap-1.5 rounded-lg bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800"
      >
        <.icon name="hero-pencil-square" class="size-4" /> {gettext("Edit User")}
      </button>
    </div>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp field(assigns) do
    ~H"""
    <div>
      <dt class="mb-1 text-xs text-zinc-400">{@label}</dt>
      <dd class="rounded-lg bg-zinc-50 px-3 py-2 text-sm font-medium text-zinc-800">
        {render_slot(@inner_block)}
      </dd>
    </div>
    """
  end

  defp loaded?(%Ash.NotLoaded{}), do: false
  defp loaded?(nil), do: false
  defp loaded?(_), do: true
end
