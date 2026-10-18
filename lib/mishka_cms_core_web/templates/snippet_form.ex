# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Templates.SnippetForm do
  @moduledoc """
  A MishkaGervaz custom form template: the "Save as snippet" box at the top of the Studio's Snippets
  tab.

  It owns the whole box and nothing below it — the saved list is a Gervaz TABLE,
  `MishkaCmsCoreWeb.Templates.StudioSnippets`.

  ## The scope control is the point

  Before this, scope was decided FOR the author: a node selected saved `:page`, nothing selected
  saved `:shared`, and there was no way to say otherwise. The three radios here are that choice made
  explicit, in the same chip idiom as the list's own filter chips.

  They are radios rather than buttons so the browser holds the selection: no `phx-change` round trip
  per click, which also means clicking one cannot disturb a half-typed name. The selected styling is
  `peer-checked:`, so it is CSS rather than a re-render.

  What each one means, and why `visibility` is not simply the stored `scope`:

  | Radio      | `scope`   | `site_id`        | Who sees the snippet          |
  |------------|-----------|------------------|-------------------------------|
  | This page  | `:page`   | this site        | only this document's editor   |
  | Shared     | `:shared` | this site        | every editor on this site     |
  | All sites  | `:shared` | `nil`            | every editor on every site    |

  "All sites" is a `site_id` decision, not a `scope` one — which is why the radio posts a
  `visibility` param that `MishkaCmsCore.Runtime.Snippet`'s `before_save` hook translates, rather
  than posting `scope` directly. It is offered to a master only: a tenant's `:create` action forces
  `site_id` to its own tenant, so showing the choice would be a promise the action cannot keep.

  ## The markup the source rides in on

  `source` — the serialised subtree, recomputed on every canvas edit — is NOT a form field. It
  reaches the action through a hidden input that `Panels` renders OUTSIDE this component and
  associates with `form="pb-snippet-form"`; `FormData` collects form-associated controls wherever
  they sit in the DOM, so LiveView serialises it with the rest. Passing it through the component's
  `defaults` instead would rebuild the form on every keystroke-adjacent edit and wipe the name the
  author was typing.
  """

  use MishkaGervaz.Form.Behaviours.Template
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCoreWeb.Live.Admin.Builder.Panels

  @scopes [
    {"page", gettext_noop("This page")},
    {"shared", gettext_noop("Shared")},
    {"global", gettext_noop("All sites")}
  ]

  @impl true
  def name, do: :studio_snippet

  @impl true
  def label, do: dgettext("mishka_gervaz", "Save as snippet")

  @impl true
  def icon, do: "hero-document-plus"

  @impl true
  def render_loading(assigns) do
    ~H"""
    <div
      data-role="pb-snippet-form-skeleton"
      class="mb-3 h-[148px] animate-pulse rounded-[13px] border border-[#e8e6f8] bg-[#f7f6fd]"
    >
    </div>
    """
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:scopes, scopes(assigns.state))
      |> assign(:selected_scope, selected_scope(assigns.state))
      |> assign(:selection_tag, defaults(assigns.state)[:selection_tag] || gettext("whole page"))
      |> assign(
        :save_label,
        defaults(assigns.state)[:save_label] || gettext("Save this page as a snippet")
      )

    ~H"""
    <div class="mb-3 rounded-[13px] border border-[#e8e6f8] bg-[#f7f6fd] p-[13px]">
      <div class="flex items-center gap-[9px]">
        <span class="grid size-7 flex-none place-items-center rounded-[9px] bg-[#e4e2f7] text-[#4f4bcc]">
          <Panels.icon name={:draft} size={15} />
        </span>
        <div class="min-w-0">
          <div class="text-[12.5px] font-bold text-[#2e2b6b]">{gettext("Save as snippet")}</div>
          <div class="mt-0.5 text-[10.5px] font-medium text-[#7d79c4]">
            {gettext("Reuse this on any page")}
          </div>
        </div>
        <span class="flex-1"></span>
        <span class="flex-none rounded-[6px] bg-[#e4e2f7] px-2 py-[3px] font-['Space_Grotesk'] text-[10px] font-bold text-[#4f4bcc]">
          {@selection_tag}
        </span>
      </div>

      <form id="pb-snippet-form" phx-change="validate" phx-submit="save" phx-target={@myself}>
        <input
          type="text"
          id="pb-snippet-name"
          name="form[name]"
          value={typed(@state, :name)}
          phx-debounce="blur"
          dir="auto"
          placeholder={gettext("Name this snippet…")}
          autocomplete="off"
          class="mt-[11px] h-[38px] w-full rounded-[10px] border border-[#dcdbf5] bg-white px-3 text-[12px] font-medium text-[#1b1a18] outline-none focus:border-[#c3c1f0] focus:shadow-[0_0_0_3px_rgba(91,87,214,.1)]"
        />

        <%!-- Who the snippet is for, chosen rather than inferred. --%>
        <div class="mt-[9px] flex gap-1.5" data-role="pb-snippet-scopes">
          <label :for={{value, label} <- @scopes} class="flex-none">
            <input
              type="radio"
              id={"pb-snippet-scope-#{value}"}
              name="form[visibility]"
              value={value}
              checked={@selected_scope == value}
              class="peer sr-only"
            />
            <span class="inline-flex h-[27px] cursor-pointer items-center rounded-full border border-[#dcdbf5] bg-white px-[11px] text-[10.5px] font-semibold text-[#7d79c4] peer-checked:border-[#4f4bcc] peer-checked:bg-[#4f4bcc] peer-checked:text-white">
              {label}
            </span>
          </label>
        </div>

        <button
          type="submit"
          id="pb-snippet-save"
          class="mt-2 flex h-9 w-full items-center justify-center gap-[7px] rounded-[10px] bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] text-[11.5px] font-bold text-white"
        >
          <Panels.icon name={:plus} size={14} />
          {@save_label}
        </button>
      </form>
    </div>
    """
  end

  # "This page" needs a document to sit beside. Without one, a `:page` snippet is unreachable
  # forever — `for_editor` offers only shared snippets when it has no document to match — so the
  # choice is not offered rather than offered and quietly ignored.
  #
  # "All sites" is master-only: a tenant's `:create` forces `site_id` to its own tenant.
  defp scopes(state) do
    defaults = defaults(state)

    @scopes
    |> Enum.reject(fn {value, _label} ->
      value == "page" and is_nil(defaults[:editor_document_id])
    end)
    |> Enum.reject(fn {value, _label} -> value == "global" and !master?(state) end)
    |> Enum.map(fn {value, label} -> {value, Gettext.gettext(MishkaCmsCore.Gettext, label)} end)
  end

  defp selected_scope(state) do
    allowed = state |> scopes() |> Enum.map(&elem(&1, 0))
    preferred = typed(state, :visibility) || defaults(state)[:visibility] || "shared"

    if preferred in allowed, do: preferred, else: List.first(allowed) || "shared"
  end

  defp typed(%{form: %Phoenix.HTML.Form{params: %{} = params}}, field),
    do: Map.get(params, to_string(field))

  defp typed(_state, _field), do: nil

  defp defaults(%{defaults: defaults}) when is_map(defaults), do: defaults
  defp defaults(_state), do: %{}

  defp master?(%{master_user?: true}), do: true
  defp master?(_state), do: false
end
