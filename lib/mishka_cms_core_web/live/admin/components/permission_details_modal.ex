defmodule MishkaCmsCoreWeb.Live.Admin.Components.PermissionDetailsModal do
  @moduledoc """
  Permission record modal: a read-only **view** (name, description, created/updated) that flips to the
  editable `MishkaGervaz.Form.Web.Live` permission form via **Edit Permission** (master users only). Also
  hosts the create form when opened with no record (the "+ Add Permission" flow).

  Shares the modal shell + card helpers with the other admin record modals through
  `MishkaCmsCoreWeb.Live.Admin.Components.DetailModal` (used here without a tab bar — `tabs={[]}`). Driven
  by the parent's `@permission_modal` map (`record`, `edit_mode?`, `loading?`, `form_record_id`); the
  form's `record_id` flows through the template so the view/edit toggle keeps it mounted. See the parent
  `MishkaCmsCoreWeb.Live.Admin.Dashboard.Account.Permission.Index`.
  """
  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Accounts.Permission
  alias MishkaCmsCoreWeb.Live.Admin.Components.DetailModal

  import MishkaCmsCore.CoreComponents, only: [icon: 1]
  import DetailModal, only: [datetime: 1]

  @modal_id "permission-details-modal"

  attr :permission_modal, :map, required: true
  attr :current_user, :any, default: nil

  def modal(assigns) do
    pm = assigns.permission_modal

    assigns =
      assigns
      |> assign(:modal_id, @modal_id)
      |> assign(:record, pm.record)
      |> assign(:edit_mode?, Map.get(pm, :edit_mode?) == true)
      |> assign(:loading?, Map.get(pm, :loading?) == true)
      |> assign(:form_record_id, Map.get(pm, :form_record_id))
      |> assign(:form_id, MishkaGervaz.Resource.Info.Form.component_id(Permission))
      |> assign(:master?, master_user?(Map.get(assigns, :current_user)))

    ~H"""
    <DetailModal.shell
      id={@modal_id}
      icon="hero-key"
      icon_class="bg-gradient-to-br from-amber-500 to-orange-600"
      max_width="max-w-2xl"
      title={if(@record, do: gettext("Permission Details"), else: gettext("Add Permission"))}
      active_tab="view"
      tabs={[]}
      tab_event="noop"
      close_event="close_permission_modal"
    >
      <:subtitle>
        <span class="text-xs text-zinc-500">{gettext("View and manage permission information")}</span>
      </:subtitle>

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
            resource={Permission}
            current_user={@current_user}
            record_id={@form_record_id}
          />
        </div>
      </div>
    </DetailModal.shell>
    """
  end

  defp view(assigns) do
    ~H"""
    <div class="grid gap-4 sm:grid-cols-2">
      <.field label={gettext("Name")}>
        <span dir="ltr" class="font-mono text-sm text-zinc-800">{@record.name}</span>
      </.field>

      <.field label={gettext("Created")}>
        {datetime(@record.created_at)}
      </.field>
    </div>

    <.field label={gettext("Description")}>
      <span class="font-normal">{@record.description || "—"}</span>
    </.field>

    <div class="flex items-center justify-end gap-3 border-t border-zinc-100 pt-4">
      <button
        type="button"
        phx-click={DetailModal.dismiss(@modal_id, "close_permission_modal")}
        class="rounded-lg border border-zinc-200 px-4 py-2 text-sm font-medium text-zinc-700 hover:bg-zinc-50"
      >
        {gettext("Close")}
      </button>
      <button
        :if={@master?}
        type="button"
        phx-click="permission_modal_toggle_edit"
        class="inline-flex items-center gap-1.5 rounded-lg bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800"
      >
        <.icon name="hero-pencil-square" class="size-4" /> {gettext("Edit Permission")}
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

  defp master_user?(%{site_id: nil}), do: true
  defp master_user?(_), do: false
end
