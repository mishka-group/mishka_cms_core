defmodule MishkaCmsCoreWeb.UIAdapters.Admin do
  @moduledoc """
  UI adapter for the admin card pages, extending the Tailwind adapter.

  Only the pieces the design redraws differ — the row-action `button`, the `nav_link`, and its
  `glyph`. Everything else falls back, including the view switcher (`template_switcher/1`), which now
  lives in the Tailwind adapter as the single switcher every admin page shares.

  Declared via `presentation do ui_adapter … end` by the resources across the extensions whose pages
  draw these cards, and paired with `MishkaCmsCoreWeb.Templates.CardChrome`.
  """

  use MishkaGervaz.Behaviours.UIAdapter,
    fallback: MishkaGervaz.UIAdapters.Tailwind

  attr :label, :string, default: nil
  attr :class, :string, default: nil
  attr :type, :string, default: "button"
  attr :icon, :string, default: nil
  attr :variant, :atom, default: :default

  attr :rest, :global,
    include:
      ~w(phx-click phx-target phx-value-id phx-value-event phx-value-values data-confirm disabled)

  @doc """
  A row-action button, drawn with this design's glyphs at this design's size.

  The label always reaches the DOM — as `title`, and as a `.lbl` span an action's `ui do class end`
  hides with `[&_.lbl]:hidden` — but so does the Tailwind adapter's, so that is not why this exists.
  It exists for `glyph/1`: the fallback renders any name that is not a heroicon as an empty span, and
  `MishkaBlog.Comment` asks for `icon "reply"`. It also pins hero icons to the 15px the cards' action
  squares are drawn around, rather than the fallback's 16px.

  Retire this the day gervaz can render a non-heroicon name and the 1px is settled — and retire it
  together with `nav_link/1`, never one alone, or a card's link actions and its button actions would
  wear different icon sizes side by side in the same row.
  """
  def button(assigns) do
    ~H"""
    <button type={@type} class={@class} title={@label} {@rest}>
      <.glyph :if={@icon} name={@icon} />
      <span :if={@label not in [nil, ""]} class="lbl">{@label}</span>
    </button>
    """
  end

  attr :label, :string, default: nil
  attr :class, :string, default: nil
  attr :icon, :string, default: nil
  attr :navigate, :string, default: nil
  attr :variant, :atom, default: :default
  attr :external, :boolean, default: false

  @doc """
  A `:link` row action, drawn the same way `button/1` is — the card's row mixes the two.

  An external link leaves the admin, so it opens in its own tab and disowns this one, exactly as the
  Tailwind adapter does it. `MishkaGervaz.Table.Types.Column.Link` is what sets `external`.
  """
  def nav_link(%{external: true} = assigns) do
    ~H"""
    <a href={@navigate} target="_blank" rel="noopener noreferrer" class={@class} title={@label}>
      <.glyph :if={@icon} name={@icon} />
      <span :if={@label not in [nil, ""]} class="lbl">{@label}</span>
    </a>
    """
  end

  def nav_link(assigns) do
    ~H"""
    <.link navigate={@navigate} class={@class} title={@label}>
      <.glyph :if={@icon} name={@icon} />
      <span :if={@label not in [nil, ""]} class="lbl">{@label}</span>
    </.link>
    """
  end

  attr :name, :string, required: true

  @doc """
  A row-action's glyph, from its `ui do icon … end` name.

  A `hero-*` name renders the heroicon; any other name is a design glyph the icon set has no match for,
  drawn inline here — the row-action contract passes a string, so an SVG cannot travel through the
  resource DSL, and this is where it lands instead. Each inline glyph is sized to 13px to match what
  the card's action class shrinks the heroicons to. Add a clause per glyph the design needs.
  """
  def glyph(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <.icon name={@name} class="size-[15px]" />
    """
  end

  def glyph(%{name: "reply"} = assigns) do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.9"
      stroke-linecap="round"
      stroke-linejoin="round"
      class="size-[13px]"
      aria-hidden="true"
    >
      <path d="M9 17 4 12l5-5" />
      <path d="M4 12h11a5 5 0 0 1 5 5v2" />
    </svg>
    """
  end

  attr :name, :string, required: true
  attr :id, :string, default: nil
  attr :value, :any, default: nil
  attr :placeholder, :string, default: nil
  attr :rows, :integer, default: 4
  attr :class, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :readonly, :boolean, default: false
  attr :extra, :map, default: %{}
  attr :phx_debounce, :any, default: 300

  @doc """
  A textarea, and a real code editor when the field asks for one.

  `ui do extra %{code: "js"} end` on a `:textarea` field turns it into CodeMirror with that
  language's grammar, line numbers and bracket matching — the same editor the page builder's drawer
  uses, loaded from the same on-demand bundle. Anything else falls through to the Tailwind adapter's
  plain box, so this costs nothing to every other form in the admin.

  The textarea is still the form field. CodeMirror mounts beside it and writes into it on every
  change, so validation, `phx-change` and save never learn that an editor exists — and a page where
  the bundle fails to load has a working textarea rather than an empty div.

  `phx-update="ignore"` is what keeps LiveView from reconciling away the DOM CodeMirror builds, and
  the id is the FIELD's, not the content's: a form echoes a sanitized value back on every keystroke,
  and keying on the text would remount the editor — and drop the cursor to the end — mid-word.

  The page must set `:code_editor` for the bundle's address to be published; `MishkaCmsCore.Layouts.Nav`
  does it for every admin page.

  The box's height is `rows × 1.75rem` with a floor of six, and it is a CLASS rather than a `style`
  attribute so the policy in `MishkaCmsCore.Runtime.Plugs.SecurityHeaders` can close
  `style-src-attr`, which no nonce can ever reopen for an attribute. `code_height_class/1` writes
  each height out whole, one clause per row count, because Tailwind reads source text — an
  interpolated class name gets no rule at all, the box collapses to nothing and the editor inside it
  disappears. Its clauses run to twenty, comfortably past the largest `rows` any resource declares;
  a field asking for more takes twenty's height until a clause is added for it.
  """
  def textarea(%{extra: %{code: language}} = assigns) when is_binary(language) do
    assigns = assign(assigns, :language, language)

    ~H"""
    <div
      id={"gvz-code-#{@id || @name}"}
      phx-hook="PbCodeEditor"
      phx-update="ignore"
      data-language={@language}
      data-fill="true"
      class={[
        "overflow-hidden rounded-[10px] border border-[#ecebe6] bg-[#17161a] px-3 py-1 [[data-theme=dark]_&]:[filter:invert(1)_hue-rotate(180deg)]",
        code_height_class(@rows)
      ]}
    >
      <textarea
        id={@id}
        name={@name}
        placeholder={@placeholder}
        rows={@rows}
        disabled={@disabled}
        readonly={@readonly}
        phx-debounce={@phx_debounce}
        spellcheck="false"
        class="h-full w-full resize-none border-0 bg-transparent font-['Space_Grotesk'] text-[12.5px] leading-[1.7] text-[#c9c7d1] outline-none"
      >{@value}</textarea>
    </div>
    """
  end

  # EVERY OTHER TEXTAREA IS THE FALLBACK'S. `use MishkaGervaz.Behaviours.UIAdapter` writes a
  # `defdelegate` for each component and then `defoverridable`, so defining `textarea/1` here takes
  # the whole function over — without this clause the description box on the same form, and every
  # other plain textarea in the admin, would raise `FunctionClauseError`.
  def textarea(assigns), do: super(assigns)

  defp code_height_class(7), do: "h-[12.25rem]"
  defp code_height_class(8), do: "h-[14rem]"
  defp code_height_class(9), do: "h-[15.75rem]"
  defp code_height_class(10), do: "h-[17.5rem]"
  defp code_height_class(11), do: "h-[19.25rem]"
  defp code_height_class(12), do: "h-[21rem]"
  defp code_height_class(13), do: "h-[22.75rem]"
  defp code_height_class(14), do: "h-[24.5rem]"
  defp code_height_class(15), do: "h-[26.25rem]"
  defp code_height_class(16), do: "h-[28rem]"
  defp code_height_class(17), do: "h-[29.75rem]"
  defp code_height_class(18), do: "h-[31.5rem]"
  defp code_height_class(19), do: "h-[33.25rem]"
  defp code_height_class(rows) when is_integer(rows) and rows >= 20, do: "h-[35rem]"
  defp code_height_class(rows) when is_integer(rows), do: "h-[10.5rem]"
end
