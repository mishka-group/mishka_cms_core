# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Templates.StudioTokens do
  @moduledoc """
  A MishkaGervaz custom table template: the Design tokens list inside the page builder's Studio.

  It owns the whole of the list and nothing around it. The tab's heading, the export-format tabs and
  the export block below stay in `MishkaCmsCoreWeb.Live.Admin.Builder.Panels` — they are not a table.

  `features/0` is empty on purpose: the Studio is a 480px sheet, and Gervaz's own filter bar,
  selection checkboxes and pagination footer would each be a control the design does not have. The
  category chips ARE Gervaz filters, but drawn here in the sheet's own idiom and pushed as the
  table's own `filter` event; the load-more button is drawn here too, for the same reason.

  The rows come from `@state.loaded_records` rather than from the stream, because the design groups
  them under category headings and a stream is one flat container that appends — it cannot express a
  heading. That is what `keep_loaded_records true` on the resource is for: Gervaz keeps every loaded
  page, so its own `load_more` event works for a grouped list exactly as it does for a flat one.

  The category chips' counts arrive in `path_params` already computed, because they count the WHOLE
  token set and the whole set is a 33 ms parse of the site's stylesheets — a cost worth paying once
  per revision in the LiveView, not once per render here.

  ## The one `style` attribute left, and why

  A category heading's dot is one of seven colours `Panels.grouped_tokens/2` hands over, so
  `dot_class/1` spells each out and the attribute is gone — CSP has no nonce for an attribute, so
  `style-src-attr` can only be closed by there being none.

  The plain swatch beside a token cannot follow. Its colour is `@token.value`, a declaration read out
  of whatever stylesheet the site's theme happens to be — any hex, `oklch(…)`, a gradient, a
  `var(--x)` — so there is no finite set to write out and none to declare with `@source inline`
  either. It stays an attribute until the swatch can be given a rule of its own in a nonced `<style>`,
  which needs a nonce this template is not handed.

  See `MishkaCmsCore.Runtime.PageBuilder.DesignToken`, which points its `presentation` here.
  """

  use MishkaGervaz.Table.Behaviours.Template
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.PageBuilder.Marketplace
  alias MishkaCmsCoreWeb.Live.Admin.Builder.Panels

  @impl true
  def name, do: :studio_tokens

  @impl true
  def label, do: dgettext("mishka_gervaz", "Design tokens")

  @impl true
  def icon, do: "hero-swatch"

  @impl true
  def description, do: dgettext("mishka_gervaz", "The Studio's design token list")

  @impl true
  # Nothing: this template draws its own chips and its own load-more, in the sheet's idiom.
  def features, do: []

  @impl true
  def default_options, do: []

  # THE FILTERS ARE REAL FROM THE FIRST FRAME; only the LIST waits, and it waits as a shape. That is
  # the promise the sheet around this makes in its own words — see the skeleton note in
  # `MishkaCmsCoreWeb.Live.Admin.Builder.Panels` — and the chips are filters, so they are drawn here
  # too. They used to live only in `render/1`, so every first read blinked the whole row out and put
  # it back, which is a jump in the one part of the sheet that was supposed not to move.
  #
  # The counts are already in `path_params` by now: they are computed in the LiveView when the sheet
  # opens, and the table's own read is the slower of the two.
  @impl true
  def render_loading(assigns) do
    assigns =
      assigns
      |> assign(:categories, categories(assigns[:state]))
      |> assign(:selected_category, selected_category(assigns[:state]))

    ~H"""
    <div class="mishka-gervaz-studio-tokens">
      <.chips categories={@categories} selected={@selected_category} myself={@myself} />

      <div data-role="pb-token-skeleton" class="flex flex-col gap-[5px]">
        <div
          :for={row <- 1..6}
          id={"pb-token-skel-#{row}"}
          class="h-[42px] animate-pulse rounded-[10px] border border-[#f0efea] bg-[#faf9f6]"
        >
        </div>
      </div>
    </div>
    """
  end

  attr(:categories, :list, required: true)
  attr(:selected, :string, required: true)
  attr(:myself, :any, required: true)

  # Counts come from the tokens themselves, so a category only appears when it has one.
  defp chips(assigns) do
    ~H"""
    <div data-role="pb-tokcats" class="mb-3 flex flex-wrap gap-[5px]">
      <button
        :for={{category, label, count} <- @categories}
        type="button"
        id={"pb-tokcat-#{category}"}
        phx-click="filter"
        phx-value-category={(category in ["all", "custom"] && "") || category}
        phx-value-custom={(category == "custom" && "true") || ""}
        phx-target={@myself}
        class={[
          "inline-flex h-[26px] flex-none items-center gap-[5px] whitespace-nowrap rounded-full border px-2.5 text-[10px] font-semibold",
          (@selected == category && "border-[#17161a] bg-[#17161a] text-white") ||
            "border-[#ecebe6] bg-[#f6f5f2] text-[#6d6a63]"
        ]}
      >
        {Gettext.gettext(MishkaCmsCore.Gettext, label)}
        <span class={[
          "font-['Space_Grotesk'] text-[9px] font-bold",
          (@selected == category && "text-white/70") || "text-[#6d6a63]"
        ]}>
          {count}
        </span>
      </button>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:tokens, records(assigns.state))
      # The chips count the WHOLE set, not the page: counting the loaded rows made every chip but
      # the selected one vanish the moment you narrowed, which is the opposite of what they are for.
      |> assign(:categories, categories(assigns.state))
      |> assign(:selected_category, selected_category(assigns.state))
      |> assign(:token_format, Map.get(assigns.state.path_params, :token_format, :tw))
      |> assign(:more?, more?(assigns.state))
      |> assign(:loading?, loading?(assigns.state))

    ~H"""
    <div class="mishka-gervaz-studio-tokens">
      <.chips categories={@categories} selected={@selected_category} myself={@myself} />

      <div
        :for={{label, dot, tokens} <- Panels.grouped_tokens(@tokens, @selected_category)}
        class="mb-[18px]"
      >
        <div class="mb-[9px] flex items-center gap-2">
          <span class={["size-[5px] flex-none rounded-full", dot_class(dot)]} />
          <span class="text-[10px] font-bold uppercase tracking-[0.11em] text-[#6d6a63]">
            {Gettext.gettext(MishkaCmsCore.Gettext, label)}
          </span>
          <span class="h-px flex-1 bg-[#f0efea]"></span>
          <span class="font-['Space_Grotesk'] text-[9.5px] font-semibold text-[#6d6a63]">
            {length(tokens)}
          </span>
        </div>

        <div class="flex flex-col gap-[5px]">
          <.render_item
            :for={token <- tokens}
            id={"pb-token-#{token.key}"}
            token={token}
            token_format={@token_format}
            static={@static}
            state={@state}
            myself={@myself}
          />
        </div>
      </div>

      <p
        :if={@tokens == [] and not @loading?}
        class="px-2.5 py-9 text-center text-[12px] font-medium text-[#6d6a63]"
      >
        {gettext("No design tokens found.")}
      </p>

      <%!-- Gervaz's own `load_more` event, drawn in the sheet's idiom rather than through the
            pagination footer `features/0` suppresses. Nothing counts here, so there is no "x of y"
            to claim — load-more reads `page_size + 1` rows and infers "there is more". --%>
      <button
        :if={@more?}
        type="button"
        id="pb-token-more"
        phx-click="load_more"
        phx-target={@myself}
        disabled={@loading?}
        class="mb-2 mt-1 h-8 w-full rounded-[9px] border border-[#ecebe6] bg-[#faf9f6] text-[10.5px] font-bold text-[#6d6a63] hover:bg-[#f2f1ec] disabled:opacity-60"
      >
        {(@loading? && gettext("Loading…")) || gettext("Load more tokens")}
      </button>
    </div>
    """
  end

  @impl true
  def render_item(assigns) do
    assigns = assign(assigns, :picker, picker_value(assigns.token))

    ~H"""
    <div
      id={@id}
      class={[
        "flex items-center gap-2.5 rounded-[10px] border px-2.5 py-2",
        (@token.custom && "border-[#f0e3c9] bg-[#fdfaf3]") || "border-[#ecebe6] bg-white"
      ]}
    >
      <%!-- The swatch IS the colour picker. It writes through the same `set_token` event as the text
            field beside it, in its own form so the two inputs do not share a name. --%>
      <Panels.field_form
        :if={@picker}
        id={"pb-token-swatch-form-#{@token.key}"}
        class="flex-none"
        phx-value-key={@token.key}
        event="set_token"
      >
        <input
          type="color"
          id={"pb-token-swatch-#{@token.key}"}
          name="value"
          value={@picker}
          phx-debounce="400"
          aria-label={gettext("%{label} colour", label: @token.label)}
          class="size-[26px] cursor-pointer rounded-[7px] border border-[#ecebe6] bg-transparent p-0 [&::-moz-color-swatch]:rounded-[6px] [&::-moz-color-swatch]:border-none [&::-webkit-color-swatch-wrapper]:p-0 [&::-webkit-color-swatch]:rounded-[6px] [&::-webkit-color-swatch]:border-none"
        />
      </Panels.field_form>
      <%!-- A colour this input cannot represent — `var(--x)`, `oklch(…)`, a gradient — keeps the
            plain swatch, and the text field stays the way to edit it. --%>
      <span
        :if={!@picker and @token.category == "color"}
        class="size-[26px] flex-none rounded-[7px] border border-[#ecebe6]"
        style={"background:#{@token.value}"}
      />
      <span
        :if={@token.category != "color"}
        class="grid size-[26px] flex-none place-items-center overflow-hidden rounded-[7px] border border-[#ecebe6] bg-[#f2f1ec] font-['Space_Grotesk'] text-[9px] font-bold text-[#6d6a63]"
      >
        {@token.glyph}
      </span>
      <span class="min-w-0 flex-1">
        <span class="block truncate text-[11px] font-semibold text-[#3a382f]">
          {@token.label}
        </span>
        <%!-- The reference in the FORMAT currently selected, so what the row shows is what Copy
              would give you — `theme.colors.ink` for Tailwind, `--ink` for CSS. --%>
        <span
          dir="ltr"
          class="block truncate font-['Space_Grotesk'] text-[9.5px] font-medium text-[#6d6a63] rtl:text-right"
        >
          {Marketplace.reference(@token_format, @token)}
        </span>
      </span>
      <%!-- The value is EDITABLE, because a token is a declaration in the site's own theme
            stylesheet and changing it changes every component that resolves through it. The form
            carries no `phx-target`, so `set_token` reaches BuilderLive, which owns the write; the
            row's save rebuilds the site's CSS. --%>
      <Panels.field_form
        id={"pb-token-form-#{@token.key}"}
        class="flex-none"
        phx-value-key={@token.key}
        event="set_token"
      >
        <input
          type="text"
          id={"pb-token-value-#{@token.key}"}
          dir="ltr"
          name="value"
          value={@token.value}
          phx-debounce="500"
          spellcheck="false"
          class="h-7 w-[104px] rounded-[7px] border border-transparent bg-transparent px-1.5 text-end font-['Space_Grotesk'] text-[10px] font-medium text-[#6d6a63] hover:border-[#ecebe6] focus:border-[#c3c1f0] focus:bg-white focus:text-[#1b1a18] focus:outline-none"
        />
      </Panels.field_form>
      <%!-- A token nobody uses is worth knowing about; one that came from this site rather than the
            kit is worth knowing about too. --%>
      <span
        :if={@token.custom}
        class="flex-none rounded-[5px] bg-[#fbf1df] px-1.5 py-0.5 text-[8.5px] font-bold uppercase tracking-[0.04em] text-[#8a5514]"
      >
        {gettext("Custom")}
      </span>
      <span
        :if={@token.usage == 0}
        title={gettext("Not used by any component")}
        class="flex-none rounded-[5px] bg-[#f2f1ec] px-1.5 py-0.5 text-[8.5px] font-bold uppercase tracking-[0.04em] text-[#6d6a63]"
      >
        {gettext("Unused")}
      </span>
      <span
        :if={@token.usage > 0}
        title={gettext("Times used across this site")}
        class="flex-none rounded-[5px] bg-[#f4f3ee] px-1.5 py-0.5 font-['Space_Grotesk'] text-[9px] font-bold text-[#6d6a63]"
      >
        {@token.usage}×
      </span>
    </div>
    """
  end

  # `<input type="color">` speaks only `#rrggbb`. A colour token declared as `var(--other)`,
  # `oklch(…)`, `rgb(…)` or a gradient has no such form, and handing the input a value it cannot
  # parse makes it silently show black — which would then be written back on the first click. Those
  # keep the read-only swatch instead.
  @hex ~r/^#(?<digits>[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/

  defp picker_value(%{category: "color", value: value}) when is_binary(value) do
    @hex
    |> Regex.named_captures(String.trim(value))
    |> case do
      %{"digits" => digits} -> "#" <> expand_hex(digits)
      nil -> nil
    end
  end

  defp picker_value(_token), do: nil

  # `#abc` is `#aabbcc`, and the alpha of `#rrggbbaa` has nowhere to go in a colour input.
  defp expand_hex(<<r, g, b>>), do: <<r, r, g, g, b, b>>
  defp expand_hex(<<rgb::binary-size(6)>>), do: rgb
  defp expand_hex(<<rgb::binary-size(6), _alpha::binary-size(2)>>), do: rgb

  # Every page loaded so far, kept by Gervaz because the resource asked for it — a grouped list
  # cannot be a stream. See `keep_loaded_records` in `MishkaGervaz.Table.Dsl.Presentation`.
  defp records(%{loaded_records: records}) when is_list(records), do: records
  defp records(_state), do: []

  # `render_loading/1` can be handed a nil state — the renderer draws it for that case too — so the
  # counts are read defensively here rather than off `state.path_params` at the call site.
  defp categories(%{path_params: params}) when is_map(params),
    do: Map.get(params, :token_categories, [])

  defp categories(_state), do: []

  defp loading?(%{records_result: %Phoenix.LiveView.AsyncResult{loading: loading}})
       when not is_nil(loading),
       do: true

  defp loading?(_state), do: false

  defp more?(%{has_more?: more?}), do: more? == true
  defp more?(_state), do: false

  # Gervaz keeps the applied filters in `filter_values`, keyed by the filter's name as an ATOM —
  # `FilterParser.parse_filter_values/2` does `Map.put(acc, field_atom, parsed)`, and it drops a
  # filter whose value is empty rather than storing "". Matching on string keys here is what made
  # every chip filter correctly and none of them light up.
  #
  # "Custom" is its own filter rather than a category, so which chip reads as selected is answered
  # by whichever of the two is set.
  defp selected_category(%{filter_values: %{custom: custom}})
       when custom in [true, "true"],
       do: "custom"

  defp selected_category(%{filter_values: %{category: value}})
       when is_binary(value) and value != "",
       do: value

  defp selected_category(_state), do: "all"

  defp dot_class("#1f9d6b"), do: "[background:#1f9d6b]"
  defp dot_class("#3a6cb5"), do: "[background:#3a6cb5]"
  defp dot_class("#7a5bd0"), do: "[background:#7a5bd0]"
  defp dot_class("#c07a2a"), do: "[background:#c07a2a]"
  defp dot_class("#0f8f86"), do: "[background:#0f8f86]"
  defp dot_class("#b03a76"), do: "[background:#b03a76]"
  defp dot_class(_indigo), do: "[background:#5b57d6]"
end
