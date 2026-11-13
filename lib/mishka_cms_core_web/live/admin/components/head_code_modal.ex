# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Components.HeadCodeModal do
  @moduledoc """
  The "Head code" modal of the Pages screen: a site's own head code entries in a Gervaz table, the
  entry being edited in a Gervaz form, and what extensions add to the head, read only.

  Drawn only while it is open, so the Pages screen reads no head code until the reader asks for it.
  `MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Page.Index` holds its state in `@head_code`:

      %{form: nil | :new | entry_id, extensions: %{items: [...], origins: [...]}}

  See `MishkaCmsCore.Runtime.HeadCode` for the table and the form, and
  `MishkaCmsCore.Runtime.HeadCodes` for what reaches a page.
  """
  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [button: 1]

  alias MishkaCmsCore.Runtime.HeadCode
  alias Phoenix.LiveView.JS

  @modal_id "head-code-modal"
  @table_id "head-codes-table"

  @doc "The modal's DOM id."
  @spec modal_id() :: String.t()
  def modal_id, do: @modal_id

  @doc "The id of the entries table, which the Pages screen sends its realtime updates to."
  @spec table_id() :: String.t()
  def table_id, do: @table_id

  attr :head_code, :map, required: true
  attr :current_user, :map, required: true
  attr :writable?, :boolean, default: false

  def modal(assigns) do
    assigns =
      assigns
      |> assign(:modal_id, @modal_id)
      |> assign(:table_id, @table_id)
      |> assign(:form_id, MishkaGervaz.Resource.Info.Form.component_id(HeadCode))

    ~H"""
    <MishkaCmsCore.CoreComponents.modal
      id={@modal_id}
      show
      on_cancel={JS.push("head_code_close")}
      width_class="max-w-4xl"
    >
      <div id="head-code">
        <div class="mb-2 text-[11.5px] font-semibold uppercase tracking-[0.14em] text-[#5b57d6]">
          {gettext("Pages")}
        </div>
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h2 class="m-0 font-['Newsreader'] text-[24px] font-medium leading-[1.05] text-[#17161a]">
              {gettext("Head code")}
            </h2>
            <p class="mt-2 text-[12px] font-medium text-[#9a978f]">
              {gettext(
                "Tags every public page of a site carries in its head, such as an analytics script or a verification tag. Admin and editor pages never get them."
              )}
            </p>
          </div>
          <.button
            :if={@writable?}
            type="button"
            id="head-code-add"
            phx-click="head_code_add"
            icon="hero-plus"
          >
            {gettext("Add entry")}
          </.button>
        </div>

        <div :if={@head_code.form} id="head-code-form" class="mt-5">
          <div class="mb-2 text-[13px] font-semibold text-[#3a382f]">
            {if @head_code.form == :new, do: gettext("New entry"), else: gettext("Edit entry")}
          </div>
          <.live_component
            module={MishkaGervaz.Form.Web.Live}
            id={@form_id}
            resource={HeadCode}
            current_user={@current_user}
            record_id={if @head_code.form == :new, do: nil, else: @head_code.form}
          />
        </div>

        <div id="head-code-entries" class="mt-5">
          <div class="mb-2 text-[13px] font-semibold text-[#3a382f]">{gettext("Your entries")}</div>
          <.live_component
            module={MishkaGervaz.Table.Web.Live}
            id={@table_id}
            resource={HeadCode}
            current_user={@current_user}
          />
        </div>

        <div id="head-code-extensions" class="mt-5">
          <div class="mb-2 text-[13px] font-semibold text-[#3a382f]">
            {gettext("From extensions")}
          </div>
          <p
            :if={@head_code.extensions.items == [] and @head_code.extensions.origins == []}
            class="text-[12px] font-medium text-[#9a978f]"
          >
            {gettext("No extension adds anything to this site's head.")}
          </p>
          <ul class="flex flex-col gap-2">
            <li
              :for={item <- @head_code.extensions.items}
              class="rounded-xl border border-[#ecebe6] bg-[#faf9f6] px-[15px] py-2 font-mono text-[12px] text-[#3a382f]"
              dir="ltr"
            >
              {describe(item)}
            </li>
          </ul>
          <p
            :if={@head_code.extensions.origins != []}
            id="head-code-extension-origins"
            class="mt-2 text-[12px] font-medium text-[#9a978f]"
            dir="ltr"
          >
            {gettext("Allowed origins")}: {Enum.join(@head_code.extensions.origins, ", ")}
          </p>
        </div>
      </div>
    </MishkaCmsCore.CoreComponents.modal>
    """
  end

  # One line a reader recognises the item by: its tag and its attributes, and the start of a
  # script's code.
  defp describe(%{tag: tag, attrs: attrs} = item) do
    attributes = Enum.map_join(attrs, "", fn {name, value} -> ~s( #{name}="#{value}") end)

    code =
      case item.content do
        code when is_binary(code) and code != "" -> " " <> String.slice(code, 0, 80)
        _none -> ""
      end

    "<" <> tag <> attributes <> ">" <> code
  end
end
