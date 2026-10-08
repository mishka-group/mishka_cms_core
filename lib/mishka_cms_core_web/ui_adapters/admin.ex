defmodule MishkaCmsCoreWeb.UIAdapters.Admin do
  @moduledoc """
  UI adapter for the admin card pages, extending the Tailwind adapter.

  Only the pieces the design redraws differ — the row-action `button`, the `nav_link`, and its
  `glyph` — and `textarea/1`, which is a code editor or a rich-text editor when the field asks for
  one. Everything else falls back, including the view switcher (`template_switcher/1`), which now
  lives in the Tailwind adapter as the single switcher every admin page shares.

  Declared via `presentation do ui_adapter … end` by the resources across the extensions whose pages
  draw these cards, and paired with `MishkaCmsCoreWeb.Templates.CardChrome`.
  """

  use MishkaGervaz.Behaviours.UIAdapter,
    fallback: MishkaGervaz.UIAdapters.Tailwind

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCoreWeb.Live.Admin.Components.ContentComponentPicker

  # The content editor's look, written on its root because the engine and the hook build the DOM
  # these reach: the document, a placed component's block, the drag handle, the fallback box.
  @content_editor_classes [
    "relative rounded-[12px] border border-[#ecebe6] bg-white transition-shadow",
    "data-[focused]:border-[#c3c1f0] data-[focused]:shadow-[0_0_0_3px_rgba(91,87,214,0.1)]",
    "[&[data-empty]_.ProseMirror]:before:pointer-events-none [&[data-empty]_.ProseMirror]:before:float-start [&[data-empty]_.ProseMirror]:before:h-0 [&[data-empty]_.ProseMirror]:before:text-[#b3b0a8] [&[data-empty]_.ProseMirror]:before:content-[attr(data-placeholder)]",
    "[&_[data-role=content-component]]:my-2 [&_[data-role=content-component]]:rounded-[12px] [&_[data-role=content-component]]:border [&_[data-role=content-component]]:border-dashed [&_[data-role=content-component]]:border-[#c3c1f0] [&_[data-role=content-component]]:bg-[#faf9ff] [&_[data-role=content-component]]:p-2",
    "[&_.ProseMirror-selectednode[data-role=content-component]]:border-solid [&_.ProseMirror-selectednode[data-role=content-component]]:border-[#6d69e6]",
    "[&_[data-role=content-component-head]]:flex [&_[data-role=content-component-head]]:items-center [&_[data-role=content-component-head]]:gap-1 [&_[data-role=content-component-head]]:text-[11.5px] [&_[data-role=content-component-head]]:font-bold [&_[data-role=content-component-head]]:text-[#4f4bcc]",
    "[&_[data-role=content-component-name]]:me-auto [&_[data-role=content-component-name]]:truncate",
    "[&_[data-role=content-component-head]_button]:flex [&_[data-role=content-component-head]_button]:size-7 [&_[data-role=content-component-head]_button]:items-center [&_[data-role=content-component-head]_button]:justify-center [&_[data-role=content-component-head]_button]:rounded-[8px] [&_[data-role=content-component-head]_button]:text-[#5c5a54] [&_[data-role=content-component-head]_button:hover]:bg-[#efeefb]",
    "[&_[data-role=content-component-preview]]:mt-1.5 [&_[data-role=content-component-preview]]:overflow-hidden [&_[data-role=content-component-preview]]:rounded-[8px] [&_[data-role=content-component-preview]]:bg-white [&_[data-role=content-component-preview]]:p-2 [&_[data-role=content-component-preview]:empty]:hidden",
    "[&_[data-role=content-drag-handle]]:flex [&_[data-role=content-drag-handle]]:h-6 [&_[data-role=content-drag-handle]]:w-5 [&_[data-role=content-drag-handle]]:cursor-grab [&_[data-role=content-drag-handle]]:items-center [&_[data-role=content-drag-handle]]:justify-center [&_[data-role=content-drag-handle]]:rounded-[6px] [&_[data-role=content-drag-handle]]:text-[#b3b0a8] [&_[data-role=content-drag-handle]:hover]:bg-[#f2f1ec] [&_[data-role=content-drag-handle]:hover]:text-[#5c5a54]",
    "[&_[data-role=content-editor-plain]]:min-h-[14rem] [&_[data-role=content-editor-plain]]:w-full [&_[data-role=content-editor-plain]]:rounded-[10px] [&_[data-role=content-editor-plain]]:border [&_[data-role=content-editor-plain]]:border-[#ecebe6] [&_[data-role=content-editor-plain]]:p-3 [&_[data-role=content-editor-plain]]:font-mono [&_[data-role=content-editor-plain]]:text-[12.5px]"
  ]

  # The document's own look: Preflight flattens headings and lists, and the editor shows them.
  @content_surface_classes [
    "relative max-h-[min(65vh,36rem)] overflow-y-auto px-3 py-3 ps-9 text-[14px] leading-[1.7] text-[#1b1a18]",
    "[&_.ProseMirror]:min-h-[14rem] [&_.ProseMirror]:whitespace-pre-wrap [&_.ProseMirror]:break-words [&_.ProseMirror]:outline-none",
    "[&_.ProseMirror_p]:my-2 [&_.ProseMirror_h1]:mb-2 [&_.ProseMirror_h1]:mt-4 [&_.ProseMirror_h1]:text-[22px] [&_.ProseMirror_h1]:font-bold [&_.ProseMirror_h2]:mb-2 [&_.ProseMirror_h2]:mt-4 [&_.ProseMirror_h2]:text-[19px] [&_.ProseMirror_h2]:font-bold [&_.ProseMirror_h3]:mb-1.5 [&_.ProseMirror_h3]:mt-3 [&_.ProseMirror_h3]:text-[16.5px] [&_.ProseMirror_h3]:font-bold [&_.ProseMirror_h4]:mb-1 [&_.ProseMirror_h4]:mt-3 [&_.ProseMirror_h4]:text-[14.5px] [&_.ProseMirror_h4]:font-bold",
    "[&_.ProseMirror_ul]:my-2 [&_.ProseMirror_ul]:list-disc [&_.ProseMirror_ul]:ps-6 [&_.ProseMirror_ol]:my-2 [&_.ProseMirror_ol]:list-decimal [&_.ProseMirror_ol]:ps-6 [&_.ProseMirror_li_p]:my-0.5",
    "[&_.ProseMirror_blockquote]:my-3 [&_.ProseMirror_blockquote]:border-s-[3px] [&_.ProseMirror_blockquote]:border-[#c3c1f0] [&_.ProseMirror_blockquote]:ps-4 [&_.ProseMirror_blockquote]:text-[#5c5a54]",
    "[&_.ProseMirror_pre]:my-3 [&_.ProseMirror_pre]:overflow-x-auto [&_.ProseMirror_pre]:rounded-[10px] [&_.ProseMirror_pre]:bg-[#17161a] [&_.ProseMirror_pre]:p-3 [&_.ProseMirror_pre]:font-mono [&_.ProseMirror_pre]:text-[12.5px] [&_.ProseMirror_pre]:text-[#e8e6ef]",
    "[&_.ProseMirror_code]:rounded [&_.ProseMirror_code]:bg-[#f0efea] [&_.ProseMirror_code]:px-1 [&_.ProseMirror_code]:font-mono [&_.ProseMirror_code]:text-[12.5px] [&_.ProseMirror_pre_code]:bg-transparent [&_.ProseMirror_pre_code]:p-0",
    "[&_.ProseMirror_a]:text-[#4f4bcc] [&_.ProseMirror_a]:underline [&_.ProseMirror_hr]:my-4 [&_.ProseMirror_hr]:border-[#e4e2dc]"
  ]

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
  A textarea, and a real code editor or a rich-text editor when the field asks for one.

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

  ## The content editor

  `ui do extra %{content_editor: true} end` on a `:textarea` field holding HTML turns it into a
  rich-text editor, with components placed in the content as blocks. It is Mishka Chelekom's
  headless `editor` engine, drawn with that component's markup contract — the `root`, a `toolbar`
  of `data-editor-command` buttons, the hidden `value` textarea carrying the field's `name`, and
  the `surface` the `ContentEditor` hook mounts the engine on — written here, so the admin needs no
  site to have installed the kit. The engine writes the HTML into the hidden textarea and
  dispatches `input` there: the textarea is the field, as it is for the code editor.

  A placed component is stored as its marker, in a paragraph of its own — see
  `MishkaCmsCore.Runtime.ContentComponents`. The palette, a component's settings and the answers
  the hook asks for are `MishkaCmsCoreWeb.Live.Admin.Components.ContentComponentPicker`, mounted
  inside the editor and named on the surface as `data-components`; a master's record places the
  components of the site its Site field names. Every id is the field's control id, which Gervaz
  writes from the form's, so two forms on one page draw two editors.

  The document scrolls inside the editor past a height of its own, so the toolbar stays in view on a
  long post — a sticky toolbar would not stick inside the form's modal, whose box clips what
  overflows it. The editable element itself is the textbox: the engine names it with the field's
  label, from the surface's `data-label-id`. An empty field shows its `placeholder`, or a line
  saying what to do.

  The page must set `:content_editor` for the bundle's address to be published;
  `MishkaCmsCore.Layouts.Nav` does it for every admin page.
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

  def textarea(%{extra: %{content_editor: true}} = assigns) do
    editor = "#{assigns[:id] || assigns[:name]}-editor"
    state = assigns[:state]

    assigns =
      assign(assigns,
        editor: editor,
        components: editor <> "-components",
        site_id: ContentComponentPicker.site(state),
        user: state && Map.get(state, :current_user),
        debounce: editor_debounce(assigns[:"phx-debounce"]),
        editable: to_string(!assigns[:disabled] and !assigns[:readonly]),
        label_id: assigns[:label_id],
        placeholder:
          assigns[:placeholder] ||
            gettext("Write here — or place a component from Components."),
        root_class: @content_editor_classes,
        surface_class: @content_surface_classes
      )

    ~H"""
    <div id={@editor} data-part="root" data-readonly={@readonly} class={@root_class}>
      <div
        data-part="toolbar"
        role="toolbar"
        aria-label={gettext("Formatting")}
        aria-controls={@editor <> "-surface"}
        class="flex flex-wrap items-center gap-0.5 rounded-t-[12px] border-b border-[#ecebe6] bg-[#faf9f6] px-1.5 py-1.5"
      >
        <.tool command="paragraph" label={gettext("Paragraph")} text="¶" />
        <.tool command="h2" label={gettext("Heading 2")} text="H2" />
        <.tool command="h3" label={gettext("Heading 3")} text="H3" />
        <.tool command="h4" label={gettext("Heading 4")} text="H4" />
        <span class="mx-1 h-5 w-px bg-[#e4e2dc]" aria-hidden="true"></span>
        <.tool command="bold" label={gettext("Bold")} icon="hero-bold-mini" />
        <.tool command="italic" label={gettext("Italic")} icon="hero-italic-mini" />
        <.tool command="link" label={gettext("Link")} icon="hero-link-mini" />
        <span class="mx-1 h-5 w-px bg-[#e4e2dc]" aria-hidden="true"></span>
        <.tool command="bullet_list" label={gettext("Bulleted list")} icon="hero-list-bullet-mini" />
        <.tool command="ordered_list" label={gettext("Numbered list")} icon="hero-numbered-list-mini" />
        <.tool command="blockquote" label={gettext("Quote")} text="“”" />
        <.tool command="code_block" label={gettext("Code block")} icon="hero-code-bracket-mini" />
        <.tool command="horizontal_rule" label={gettext("Divider")} icon="hero-minus-mini" />
        <span class="mx-1 h-5 w-px bg-[#e4e2dc]" aria-hidden="true"></span>
        <.tool command="undo" label={gettext("Undo")} icon="hero-arrow-uturn-left-mini" />
        <.tool command="redo" label={gettext("Redo")} icon="hero-arrow-uturn-right-mini" />

        <button
          type="button"
          id={@components <> "-toggle"}
          phx-click="toggle"
          phx-target={"#" <> @components}
          class="ms-auto inline-flex h-8 items-center gap-1.5 rounded-[9px] border border-[#ecebe6] bg-white px-2.5 text-[12px] font-semibold text-[#3a382f] hover:bg-[#f7f6f3]"
        >
          <.icon name="hero-squares-plus-mini" class="size-4" />
          {gettext("Components")}
        </button>
      </div>

      <textarea
        id={@editor <> "-value"}
        data-part="value"
        name={@name}
        disabled={@disabled}
        hidden
      >{@value}</textarea>

      <div
        id={@editor <> "-surface"}
        phx-hook="ContentEditor"
        phx-update="ignore"
        data-part="surface"
        data-root-id={@editor}
        data-value-id={@editor <> "-value"}
        data-format="html"
        data-value={@value}
        data-placeholder={@placeholder}
        data-editable={@editable}
        data-debounce={@debounce}
        data-components={"#" <> @components}
        data-label-edit={gettext("Component settings")}
        data-label-remove={gettext("Remove component")}
        data-label-link={gettext("Link address — leave it empty to remove the link")}
        data-label-plain={gettext("The editor did not load — this is the content's HTML.")}
        data-label-id={@label_id}
        class={@surface_class}
      >
        <p data-role="content-editor-loading" class="text-[12.5px] font-medium text-[#8a877f]">
          {gettext("Loading the editor…")}
        </p>
      </div>

      <.live_component
        module={ContentComponentPicker}
        id={@components}
        editor={@editor}
        site_id={@site_id}
        current_user={@user}
      />
    </div>
    """
  end

  # EVERY OTHER TEXTAREA IS THE FALLBACK'S. `use MishkaGervaz.Behaviours.UIAdapter` writes a
  # `defdelegate` for each component and then `defoverridable`, so defining `textarea/1` here takes
  # the whole function over — without this clause the description box on the same form, and every
  # other plain textarea in the admin, would raise `FunctionClauseError`.
  def textarea(assigns), do: super(assigns)

  attr :command, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, default: nil
  attr :text, :string, default: nil

  # One toolbar button: the editor runs its `data-editor-command` and marks it `data-active`.
  defp tool(assigns) do
    ~H"""
    <button
      type="button"
      data-editor-command={@command}
      aria-label={@label}
      title={@label}
      class="inline-flex size-8 items-center justify-center rounded-[8px] text-[12px] font-bold text-[#5c5a54] hover:bg-[#efeee9] data-[active]:bg-[#eeedfb] data-[active]:text-[#4f4bcc]"
    >
      <.icon :if={@icon} name={@icon} class="size-4" />
      <span :if={@text} aria-hidden="true">{@text}</span>
    </button>
    """
  end

  defp editor_debounce(debounce) when is_integer(debounce) and debounce >= 0, do: debounce
  defp editor_debounce(_blur_or_unset), do: 300

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
