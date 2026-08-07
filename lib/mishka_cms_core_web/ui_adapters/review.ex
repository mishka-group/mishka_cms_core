defmodule MishkaCmsCoreWeb.UIAdapters.Review do
  @moduledoc """
  The UI adapter for the builder's Review panel — the editor's own look, over Gervaz's behaviour.

  ## The two axes, and which one this is

  Gervaz separates them deliberately: a **template** decides WHERE things go, an **adapter** decides
  HOW they look. `MishkaCmsCoreWeb.Templates.ReviewComments` and `…ReviewCommentForm` are the
  templates; this is the paint. Splitting them is what lets the Review panel look like the editor
  rather than like an admin table dropped into a sidebar, without either one reimplementing what
  Gervaz already does.

  ## Fallback is the point

  `use MishkaGervaz.Behaviours.UIAdapter, fallback: …` emits a `defdelegate` for every one of the
  ~90 components in the behaviour and then lets this module override any of them. Everything not
  written here — every input type, every upload control, every pagination button, the empty state,
  the spinner — is `MishkaGervaz.UIAdapters.Tailwind`'s, unchanged, and starts working the day the
  Review panel starts using it.

  So the list below is not "the components Review needs". It is "the components whose stock version
  looked wrong in a 360px sidebar":

    * `badge/1` — the type and status chips. The stock badge is a table cell's; these are the
      editor's own chip idiom, and the type has to be legible at a glance because the counter
      counts one of them.
    * `textarea/1` and `select/1` — the composer's two fields, at the editor's control height and
      radius rather than a form page's.
    * `button/1` — the editor's buttons, and the reason `MishkaCmsCoreWeb.UIAdapters.Admin` has one
      too: the fallback renders any icon name that is not a heroicon as an empty span.
    * `empty_state/1` — the sheet is 360px wide; the stock empty state is built for a page.

  Add to this list only when the stock version is genuinely wrong here. Every override is a piece of
  Gervaz that stops improving on its own.

  A chip's colour arrives as a whole class from `tone_classes/1` rather than a `style` attribute:
  CSP has no nonce for an attribute, so the policy in
  `MishkaCmsCore.Runtime.Plugs.SecurityHeaders` can only close `style-src-attr` by there being none.
  Each tone is written out per clause because Tailwind reads source text — an interpolated class name
  gets no rule at all, which is what `MishkaCmsWeb.InterpolatedClassTest` guards.
  """

  use MishkaGervaz.Behaviours.UIAdapter,
    fallback: MishkaGervaz.UIAdapters.Tailwind

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  # The type chips carry colour because the counter counts one of them: a bug has to be findable in
  # a thread without reading it. The rest are quiet on purpose — a review where everything shouts is
  # a review nobody reads.
  defp tone_classes("bug"),
    do: {"[background:#fdf3f1] [border-color:#f0dcd8] [color:#c0473d]", "[background:#c0473d]"}

  defp tone_classes("task"),
    do: {"[background:#f2f1fc] [border-color:#dcdbf5] [color:#4f4bcc]", "[background:#4f4bcc]"}

  defp tone_classes("question"),
    do: {"[background:#fdf7ea] [border-color:#f0e3c9] [color:#8a5514]", "[background:#8a5514]"}

  defp tone_classes(green) when green in ["suggestion", "resolved"],
    do: {"[background:#e6f6ee] [border-color:#d7eddf] [color:#177a53]", "[background:#177a53]"}

  defp tone_classes(_quiet),
    do: {"[background:#f4f3ef] [border-color:#ecebe6] [color:#6d6a63]", "[background:#6d6a63]"}

  attr :label, :string, default: nil
  attr :variant, :atom, default: :tag
  attr :dot, :boolean, default: false
  attr :class, :string, default: nil
  attr :rest, :global

  @doc "A type or status chip, in the editor's chip idiom rather than a table cell's."
  def badge(assigns) do
    {chip, dot} = assigns.label |> tone_key() |> tone_classes()

    assigns = assigns |> assign(:chip_tone, chip) |> assign(:dot_tone, dot)

    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1.5 rounded-full border px-2 py-[2px] text-[10px] font-bold",
        @chip_tone,
        @class
      ]}
      {@rest}
    >
      <span :if={@dot} class={["size-[5px] rounded-full", @dot_tone]}></span>{@label}
    </span>
    """
  end

  attr :field, :any, default: nil
  attr :name, :string, default: nil
  attr :value, :any, default: nil
  attr :label, :string, default: nil
  attr :placeholder, :string, default: nil
  attr :rows, :any, default: 3
  attr :required, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :readonly, :boolean, default: false
  attr :class, :string, default: nil
  attr :errors, :list, default: []
  attr :rest, :global

  @doc "The note itself. One field, at the editor's control height."
  def textarea(assigns) do
    ~H"""
    <textarea
      name={@name}
      rows={@rows}
      required={@required}
      disabled={@disabled}
      readonly={@readonly}
      placeholder={@placeholder || gettext("Leave a note for the team…")}
      class={[
        "w-full resize-none rounded-[9px] border bg-[#faf9f6] px-2.5 py-2 text-[12px] font-medium leading-[1.5] text-[#1b1a18] outline-none focus:bg-white",
        (@errors == [] && "border-[#ecebe6] focus:border-[#c3c1f0]") || "border-[#e8b7b1]",
        @class
      ]}
      {@rest}
    >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
    """
  end

  attr :field, :any, default: nil
  attr :name, :string, default: nil
  attr :value, :any, default: nil
  attr :options, :list, default: []
  attr :label, :string, default: nil
  attr :prompt, :string, default: nil
  attr :required, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :class, :string, default: nil
  attr :errors, :list, default: []
  attr :rest, :global

  @doc "What kind of note it is. Short list, so a plain select rather than a search."
  def select(assigns) do
    ~H"""
    <select
      name={@name}
      required={@required}
      disabled={@disabled}
      class={[
        "appearance-none rounded-[7px] border bg-white px-2 text-[10.5px] font-bold text-[#5c5a54] outline-none",
        (@errors == [] && "border-[#ecebe6] focus:border-[#c3c1f0]") || "border-[#e8b7b1]",
        @class
      ]}
      {@rest}
    >
      <option :if={@prompt} value="">{@prompt}</option>
      <option
        :for={{label, value} <- normalize_options(@options)}
        value={value}
        selected={to_string(value) == to_string(@value)}
      >
        {label}
      </option>
    </select>
    """
  end

  attr :label, :string, default: nil
  attr :class, :string, default: nil
  attr :type, :string, default: "button"
  attr :icon, :string, default: nil
  attr :variant, :atom, default: :default

  attr :rest, :global,
    include:
      ~w(phx-click phx-target phx-value-id phx-value-event phx-value-values data-confirm disabled)

  @doc """
  A Review button.

  The same reason `MishkaCmsCoreWeb.UIAdapters.Admin` carries one: the fallback renders any icon
  name that is not a heroicon as an empty span, and the label has to reach the DOM either way.
  """
  def button(assigns) do
    ~H"""
    <button type={@type} class={@class} title={@label} {@rest}>
      <span :if={@label not in [nil, ""]} class="lbl">{@label}</span>
    </button>
    """
  end

  attr :message, :string, default: nil
  attr :icon, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global

  @doc "Nothing here yet, at sidebar width — the stock one is built for a page."
  def empty_state(assigns) do
    ~H"""
    <div
      class={["px-3 py-10 text-center", @class]}
      {@rest}
    >
      <p class="text-[12px] font-medium text-[#a8a5a0]">
        {@message || gettext("No notes on this page yet")}
      </p>
    </div>
    """
  end

  defp tone_key(label) when is_binary(label), do: label |> String.trim() |> String.downcase()
  defp tone_key(label) when is_atom(label) and not is_nil(label), do: to_string(label)
  defp tone_key(_label), do: ""

  # Gervaz hands options through as `{label, value}` pairs, bare values, or maps depending on where
  # they were declared. Normalising here keeps the template from having to care.
  defp normalize_options(options) when is_list(options), do: Enum.map(options, &option_pair/1)
  defp normalize_options(_options), do: []

  defp option_pair({label, value}), do: {label, value}
  defp option_pair(%{label: label, value: value}), do: {label, value}
  defp option_pair(value), do: {value, value}
end
