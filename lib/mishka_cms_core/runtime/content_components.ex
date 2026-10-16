defmodule MishkaCmsCore.Runtime.ContentComponents do
  @moduledoc """
  Components inside content: a marker an author writes into stored HTML — a post's body — drawn as
  the runtime component it names. WordPress calls these shortcodes; Joomla, content plugins.

      [[component chelekom-alert title="Heads up"]]Text, <b>with</b> HTML[[/component]]
      [[component chelekom-badge size="small" /]]

  A template draws such content with `rich_content/1`, imported into every runtime template — see
  `MishkaCmsCore.Runtime.LiveViewHelpers.rich_content/1`:

      <.rich_content
        id={"\#{@id}-body"}
        html={@body}
        site={site_name()}
        current_user={@current_user}
      />

  ## The marker

    * `[[component NAME ATTRS]]INNER[[/component]]` — `INNER` is HTML, and becomes the component's
      `inner_block` slot when the component declares one.
    * `[[component NAME ATTRS /]]` — no inner content.
    * `NAME` is letters, digits, `-` and `_`. It names a component of the site being drawn, or a
      global one when the site has none of that name.
    * Each of `ATTRS` is `key="value"`, `key='value'`, `key=value` or a bare `key`, which is `true`.
      A quote may arrive as an entity — `&quot;`, `&#34;`, `&#39;`, `&#x27;`, `&apos;` — and a value
      is entity-decoded. A value cannot hold both kinds of quote: the sanitizer content is stored
      through decodes every quote entity back into the quote itself.
    * Whitespace is spaces, tabs, line breaks and the non-breaking space, written or as an entity.

  A marker is found only in text: never inside a tag, and never inside `<pre>` or `<code>`, so a
  page can show the syntax. A marker that does not parse, an opening marker nothing closes and a
  closing marker nothing opened are left in the text as they are.

  ## Inside a component

  `INNER` may hold markers of its own, drawn inside the component — a timeline holding its sections,
  a card holding its title:

      [[component chelekom-timeline]]
        [[component chelekom-timeline-section title="Started" /]]
        [[component chelekom-timeline-section title="Shipped" /]]
      [[/component]]

  and, for a component that declares named slots, a slot marker for each entry it takes:

      [[component chelekom-video]][[slot source src="/intro.mp4" type="video/mp4" /]][[/component]]
      [[slot item title="Question"]]The answer, as <b>HTML</b>[[/slot]]

  A slot marker is read with the same rules as a component's, belongs to the component it sits
  directly inside, and is passed as that slot when the component declares it — its attributes cast
  against the slot's own. A slot marker anywhere else is text. Markers are drawn eight levels deep;
  the content of a deeper one is drawn as it is written.

  What a component hands its content — `render_slot(@inner_block, value)`, or a slot entry's
  `render_slot(entry, value)` — reaches each marker inside that content, at any depth, as
  `runtime:render:before_content_component`'s `slot_arg` meta. A marker outside the component never
  sees it, and a component inside that hands nothing (`render_slot(@inner_block)`) passes on the one
  it was given.

  A paragraph holding one marker and nothing else — whitespace and non-breaking spaces aside — is
  drawn as the component alone, without the `<p>` an editor wraps a line in: a block inside a `<p>`
  is HTML a browser takes apart. A marker sharing its paragraph with other text keeps it.

  ## What is drawn

  Only a component the request's site may render: active, and the site's own or a global one — the
  rule `MishkaCmsCore.Runtime.LiveViewHelpers.component/1` holds every template to. The name is
  first checked, as a string, against the active components `SiteState` knows the site and the
  global scope have: a name an author typed that names none of them makes no module name, no atom
  and no remembered failure. A name that resolves to nothing, an inactive component, another site's,
  one that draws content itself (it could draw the content that holds it, forever), one missing an
  attribute it requires, and one whose list or map value cannot be read (see Lists and maps) are
  drawn as nothing. The same render in a preview (`MishkaCmsCore.Runtime.StaticHelpers`) draws a
  notice saying why in their place. On a page, one that passes every check and then raises while it
  draws is drawn as a small box, and the content around it draws — see
  `MishkaCmsCore.Runtime.ComponentBoundary`.

  A component is handed what `<.component>` in a template would hand it: the attributes the marker
  writes, and for one it leaves out the default the component declares, or nothing at all when it
  declares none, as Phoenix leaves it. A clause matching `%{navigate: _}` is taken only when the
  marker writes `navigate`, and a template reads an attribute with no default as `assigns[:label]`,
  never `@label`.

  Only the attributes the component declares are read from the marker, each cast to its declared
  type: `string` and `any` as written, `boolean` from `true`/`false` or a bare key, `integer` and
  `float` from a number, `list` and `map` from JSON (see Lists and maps), and anything that declares
  `values` only as one of them — which is the only way an `atom` is taken. `id`, `site`, `component_name`, `current_user`, `rest` and any `phx-` name are never an
  author's. A stateful component, and one declaring `id`, gets the id `"<id>-<n>"`, `n` counting
  the content's markers from 0 — `"<id>-<n>-<m>"` for the `m`th inside it — so it stays the same
  component across renders.

  A component declaring a `global` attribute (`attr :rest, :global, include: ~w(disabled circle)`)
  takes, through it, the HTML attributes that attribute names and a few every element has: each
  name in its `include` list, `aria-*`, `data-*`, and `accesskey`, `autocapitalize`,
  `autocorrect`, `autofocus`, `dir`, `draggable`, `enterkeyhint`, `hidden`, `inert`, `inputmode`,
  `lang`, `role`, `spellcheck`, `tabindex`, `title` and `translate`. A bare key or `"true"` is
  `true`, `"false"` leaves it out, and anything else is the text written. Never an event handler
  (`on…`), `style`, a `phx-` or `data-phx-` name, `data-method`, `data-to`, `data-csrf`, `method`,
  `csrf_token` or a name the component declares, and a link or source (`href`, `src`, `action`,
  `formaction`, `poster`, `cite`, `ping`) only when it is a path or an `http`, `https`, `mailto` or
  `tel` address:

      [[component my-video controls muted]][[slot source src="/intro.mp4" /]][[/component]]
      [[component my-button circle disabled aria-label="Scan"]][[/component]]

  A slot the component declares and the content does not fill is passed empty, and one it requires
  draws the component as nothing — as a required attribute does. A slot's attribute the marker
  leaves out is passed as its declared default, and an entry with nothing inside it draws nothing
  where the component renders its content.

  The HTML around the markers is drawn as it is given: pass only HTML that was sanitized.

  ## Lists and maps

  An attribute declared `list` takes a JSON array, and one declared `map` a JSON object, written in
  single quotes around JSON's own double ones:

      [[component chelekom-headless-tree nodes='[{"value":"src","label":"src","children":[{"value":"app","label":"app.ex"}]}]' /]]
      [[component chelekom-headless-sparkline values='[3,5,2,8,6]' /]]
      [[component chelekom-headless-segmented-control options='["Day","Week","Month"]' value="Week" /]]
      [[component chelekom-headless-countdown seconds="93784" show_labels labels='{"days":"d","hours":"h"}' /]]

  An `any` attribute that declares no `values` takes an array or an object the same way, and every
  other value as it is written: `option='{"series":[]}'` is a map, `option="{draft"` the text.

  The value reaches the component as data: strings, numbers, `true`, `false` and `null` as Elixir's
  own, an array as a list, an object as a map. Nothing in it is run, and no string in it becomes a
  module or an atom. An object's keys are atoms when it is a record — an object inside an array,
  such as a tree's node read as `node.label`, and the object of an attribute whose declared default
  is a map with atom keys. Any other object keeps its keys as written: a lookup such as a
  countdown's `labels`, read by the strings its `units` hold. A key becomes an atom only when the VM
  already has that atom — as it has every key the component's code reads — and a key starting with
  `__` is always a string.

  A value is at most 32 KB as written, and 8 levels deep, each array and object a level: a tree's
  node is two. A `'` inside the JSON is written `\\u0027`, and `&`, `<` and `>`, as in any value, as
  entities. A `list` or `map` value that is not JSON of its kind, that is larger or deeper, or that
  is a bare key draws the component as nothing, and a preview says which attribute and why. An
  `any` value is then handed as it is written.

  ## Cost

  Content holding no `[[component` is drawn as it is, and nothing is parsed. A marker asks only what
  the runtime keeps in memory: `SiteState` for the site and its component names, then the loaded
  code table for the compiled module. The first render of a component nothing has built yet builds
  it, once, as `component/1` does.

  ## Styles

  A site's stylesheet is built from the templates it reaches
  (`MishkaCmsCore.Runtime.Compilers.CssClosure`), and the components content names are in no
  template. Whoever stores content answers `runtime:compile:content_components` with the names
  its content uses — see `MishkaCmsCore.Runtime.Compilers.TailwindCompiler.content_components/1` —
  and a template that draws content reaches exactly those. `names/1` reads them out of content, to
  store beside it when it is written.

  The icons content names are in no template either: a marker's `icon="hero-inbox"` reaches the
  component as an expression, and a `<span class="hero-inbox">` in the HTML is never scanned. The
  same event answers them as `icons` — see
  `MishkaCmsCore.Runtime.Compilers.TailwindCompiler.content_icons/1` — and `icons/1` reads them out
  of content.

  Nor are the classes content writes: a `<div class="bg-[#282828]">` in the HTML, a marker's
  `class`, its `*_class` attributes, and the attributes its component takes a class string in. The
  same event answers them as `classes` — see
  `MishkaCmsCore.Runtime.Compilers.TailwindCompiler.content_classes/1` — and `site_classes/2` reads
  them out of content.

  ## The editor

  The admin's content editor holds content as `segments/1` splits it: the HTML it edits, and each
  component standing alone as a block it shows drawn. The block writes its marker back as a
  paragraph of its own, so content saved from the editor stores what it was opened with. Its
  palette is `palette/2`.

  ## Events

    * `runtime:render:before_content_component` — before each embedded component is drawn, with
      `%{component_name: name, site: site, attrs: attrs, inner: inner_html | nil}` and
      `%{site_id: site_id, index: n, marker_attrs: written, slot_arg: arg, slot_args: args}` as
      meta. `attrs` is atom-keyed and already cast; `marker_attrs` are the attributes as the marker
      writes them, string-keyed and uncast. `slot_arg` is the value the nearest component around the
      marker hands its content (`nil` when none does), and `slot_args` every such value, nearest
      first. A plugin answers the map with other `attrs` or `inner` to change what is drawn — an
      attribute taken out of `attrs` is not handed at all, for a component's own clause to fill, as
      a form field's `name` from its `field` — or `suppress: true` to draw nothing.
    * `runtime:component:crashed` — a marker's component raised while it was drawn, and a box was
      drawn in its place; see `MishkaCmsCore.Runtime.ComponentBoundary`.
    * `runtime:content:editor_palette` — before the content editor's palette is shown, with
      `%{site_id: site_id, components: entries}` (`embeddable/2`'s entries) and
      `%{current_user: user}` as meta. A plugin answers the map with other `components` to narrow or
      extend what an author may place; the editor places only what the palette lists.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  import Phoenix.Component, only: [sigil_H: 2]

  require Ash.Query

  alias MishkaCmsCore.Builder.Furnishing
  alias MishkaCmsCore.Runtime.{Component, ComponentBoundary, Helpers, LiveViewHelpers}
  alias MishkaCmsCore.Runtime.Translations
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler
  alias MishkaCmsCore.Runtime.PageBuilder.{CodeReads, Icons, Inspector, Markup}
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaInstaller.Event.Hook

  @event "runtime:render:before_content_component"
  @palette_event "runtime:content:editor_palette"

  @open "[[component"
  @close "[[/component]]"
  @slot_open "[[slot"
  @slot_close "[[/slot]]"

  # How many markers deep content is drawn.
  @depth 8

  @reserved ~w(id site component_name runtime_slot current_user inner_block rest)

  # The types a marker writes as JSON, and how large and how deep one such value may be.
  @json_types ~w(list map)
  @json_bytes 32_768
  @json_depth 8

  @quotes [
    {"\"", "\""},
    {"'", "'"},
    {"&quot;", "&quot;"},
    {"&#34;", "&#34;"},
    {"&#39;", "&#39;"},
    {"&#x27;", "&#x27;"},
    {"&apos;", "&apos;"}
  ]

  @entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => "\u00A0"
  }

  @tag ~r{<(/?)([A-Za-z][A-Za-z0-9-]*)[^>]*>}
  @paragraph_open ~r{<p(?:\s[^<>]*)?>(?:\s|&nbsp;|&#160;|\xC2\xA0)*\z}i
  @paragraph_close ~r{\A(?:\s|&nbsp;|&#160;|\xC2\xA0)*</p\s*>}i
  @paragraph_reach 256
  @entity ~r/&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z]+);/
  @key ~r/\A[A-Za-z_][A-Za-z0-9_-]*\z/
  @name ~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/

  # What `classes/2` keeps: how many tokens, how long each, and the bytes a class is made of.
  @class_cap 1000
  @class_length 512
  @class_token ~r/\A[A-Za-z0-9!#$%&'()*+,.\/:=>?@\[\]^_|~-]+\z/
  @tag_with_attrs ~r{<[A-Za-z][A-Za-z0-9-]*\s[^<>]*>}
  @class_attr ~r/\sclass\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/i

  @typedoc "One marker, as `parse/1` found it."
  @type marker :: %{
          name: String.t(),
          attrs: %{String.t() => String.t() | true},
          inner: String.t() | nil,
          index: non_neg_integer()
        }

  @typedoc "A piece of content: HTML drawn as it is, or a marker."
  @type chunk :: {:html, String.t()} | {:component, marker()}

  @typedoc """
  One component marker read apart, as `read/1` gives it and `write/1` takes it: its name, its
  attributes, and what it holds, in order — text, the components inside it, and its slot entries.
  """
  @type tree :: %{
          name: String.t(),
          attrs: %{String.t() => String.t() | true},
          parts: [
            {:text, String.t()}
            | {:component, tree()}
            | {:slot, %{name: String.t(), attrs: map(), parts: list()}}
          ]
        }

  @typedoc """
  A piece of content as the editor holds it: HTML, or a component standing alone. `marker` is the
  marker as written, `source` the bytes it was cut from, the paragraph around it included.
  """
  @type segment ::
          {:html, String.t()}
          | {:component,
             %{
               name: String.t(),
               attrs: %{String.t() => String.t() | true},
               inner: String.t() | nil,
               marker: String.t(),
               source: String.t()
             }}

  @void ~w(area base br col embed hr img input link meta param source track wbr)

  @typedoc "A component an author may embed, as `embeddable/2` lists it."
  @type entry :: %{
          name: String.t(),
          description: String.t() | nil,
          type: String.t() | nil,
          stateful: boolean(),
          global: boolean(),
          inner_block: boolean(),
          category: String.t(),
          examples: [String.t()],
          furnishing: Furnishing.t() | nil,
          switches: switches(),
          attrs: [attr_entry()],
          slots: [
            %{
              name: String.t(),
              doc: String.t() | nil,
              required: boolean(),
              inner: boolean(),
              attrs: [attr_entry()]
            }
          ]
        }

  @typedoc """
  Which clause of each of a component's helpers draws it: one list of clauses per helper, in order,
  each the attributes and the values it matches — `%{}` matching any — or `:unknown` when it matches
  on something no attribute holds; and the attributes whose every use in the template is through
  those helpers.
  """
  @type switches :: %{
          helpers: [[%{String.t() => [String.t()]} | :unknown]],
          through: [String.t()]
        }

  @typedoc """
  An attribute a marker can set, as `embeddable/2` lists it: `group` is the heading the page
  builder's Inspector files it under, untranslated, and `media` whether it holds a picture or a
  video.
  """
  @type attr_entry :: %{
          name: String.t(),
          type: String.t(),
          values: [term()],
          default: term(),
          doc: String.t() | nil,
          required: boolean(),
          group: String.t(),
          media: boolean()
        }

  @doc """
  Splits `html` into the HTML drawn as it is and the markers in it, in order.

      parse(~s(<p>Hi</p>[[component chelekom-badge size="small" /]]))
      #=> [
      #=>   {:html, "<p>Hi</p>"},
      #=>   {:component, %{name: "chelekom-badge", attrs: %{"size" => "small"}, inner: nil, index: 0}}
      #=> ]

  Content with no `[[component` in it is one `{:html, html}`, found with a single binary match. Only
  the outermost markers are pieces: a marker inside another is part of that one's `inner`.
  """
  @spec parse(String.t()) :: [chunk()]
  def parse(html) when is_binary(html) do
    case :binary.match(html, @open) do
      :nomatch -> [{:html, html}]
      _found -> html |> outermost() |> Enum.map(&unwrapped(&1, html)) |> chunks(html)
    end
  end

  @doc """
  The component names the markers in `html` name, each once, in the order they first appear — those
  inside other markers too — what a resource stores beside its content when it is written, for the
  site's stylesheet.

      names(~s([[component chelekom-alert /]]<p>x</p>[[component chelekom-card]][[component chelekom-alert /]][[/component]]))
      #=> ["chelekom-alert", "chelekom-card"]
  """
  @spec names(String.t() | nil) :: [String.t()]
  def names(html) when is_binary(html) do
    case :binary.match(html, @open) do
      :nomatch -> []
      _found -> html |> tree() |> named([]) |> Enum.reverse() |> Enum.uniq()
    end
  end

  def names(_html), do: []

  @doc """
  The icon classes `html` names, each once, in the order they first appear — a marker's attribute
  (`[[slot item icon="hero-inbox"]]`) and the HTML's own classes (`<span class="hero-inbox">`) alike
  — what a resource stores beside its content when it is written, for the site's stylesheet.

  A class is found by the prefixes `MishkaCmsCore.Runtime.PageBuilder.Icons` registers
  (`Icons.classes_in/1`), and kept only when a registered set ships it (`Icons.known?/1`): a
  `hero-section` in the text, or a prefix nothing registers, is left out.

      icons(~s([[slot item icon="hero-cloud" /]]<span class="hero-inbox size-4"></span>hero-nope))
      #=> ["hero-cloud", "hero-inbox"]
  """
  @spec icons(String.t() | nil) :: [String.t()]
  def icons(html) when is_binary(html),
    do: html |> Icons.classes_in() |> Enum.filter(&Icons.known?/1)

  def icons(_html), do: []

  @doc """
  The class tokens `html` names, each once — what a resource stores beside its content when it is
  written, for the site's stylesheet. The HTML's own class lists come first, then the markers':

    * every `class="…"` of an HTML tag, entities decoded;
    * a component's or a slot's `class` attribute, and every attribute named `*_class`;
    * a component's attribute `open` names for it — `%{"chelekom-badge" => ["size", "variant"]}`,
      what `open_attrs/2` reads off the components a site reaches: an attribute that takes one of
      its examples or a class string of the author's own;
    * any other attribute of a component or a slot whose value is nothing but utilities — every
      token holding a `-`, `:` or `[`, and none an icon: `height="h-16"`, `relative="md:relative"`.
      Of a component `declared` holds the declaration of — `%{"my-badge" => %{attrs: [...],
      slots: [...]}}`, what `site_classes/2` reads off the components a site reaches — and of its
      slots, only an attribute that declaration takes the value in (`cast/2`): a value outside an
      attribute's `values` never reaches the component.

  A token is kept when it could be a class (`class?/1`). At most 1000 are kept.

      classes(~s(<p class="text-sm bg-[#282828]">x</p>[[component chelekom-badge size="py-2 px-4" class="ml-1" /]]),
        %{"chelekom-badge" => ["size"]})
      #=> ["text-sm", "bg-[#282828]", "py-2", "px-4", "ml-1"]
  """
  @spec classes(String.t() | nil, %{String.t() => [String.t()]}, %{String.t() => map()}) ::
          [String.t()]
  def classes(html, open \\ %{}, declared \\ %{})

  def classes(html, open, declared) when is_binary(html) and is_map(open) and is_map(declared) do
    html
    |> html_class_values()
    |> Stream.concat(marker_class_values(html, open, declared))
    |> Stream.flat_map(&String.split/1)
    |> Stream.filter(&class?/1)
    |> Stream.uniq()
    |> Enum.take(@class_cap)
  end

  def classes(_html, _open, _declared), do: []

  @doc """
  The attributes each component `names` names takes a class string in — one declaring `examples`
  and no `values`, a `string` or an `any` — as `classes/2` takes them. Read off the active
  components of the site `site_id` and the global ones, a site's own hiding the global one of the
  same name, as the system: the stylesheet is the same whoever wrote the content.

      open_attrs(["chelekom-badge"], site_id)
      #=> %{"chelekom-badge" => ["size", "variant", "rounded"]}
  """
  @spec open_attrs([String.t()], String.t() | nil) :: %{String.t() => [String.t()]}
  def open_attrs([], _site_id), do: %{}

  def open_attrs(names, site_id) when is_list(names),
    do: names |> declarations(site_id) |> open_of()

  defp open_of(declared) do
    declared
    |> Map.new(fn {name, %{attrs: attrs}} -> {name, open_names(attrs)} end)
    |> Map.reject(fn {_name, attrs} -> attrs == [] end)
  end

  # The attributes and the slots each of `names` declares, of the active components the site
  # `site_id` reaches, a site's own hiding the global one of the same name.
  defp declarations([], _site_id), do: %{}

  defp declarations(names, site_id) do
    Component
    |> Ash.Query.for_read(:for_tenant_with_globals, %{}, tenant: site_id, authorize?: false)
    |> Ash.Query.filter(active == true and name in ^names)
    |> within(site_id)
    |> Ash.Query.select([:name, :attrs, :slots, :site_id])
    |> every([], 0, authorize?: false)
    |> case do
      {:ok, rows} ->
        rows
        |> own_first()
        |> Map.new(fn row ->
          {row.name, %{attrs: List.wrap(row.attrs), slots: List.wrap(row.slots)}}
        end)

      {:error, _reason} ->
        %{}
    end
  end

  @doc """
  The class tokens `html` names on the site `site_id` — `classes/2`, with the attributes the
  components it names take a class string in (`open_attrs/2`).
  """
  @spec site_classes(String.t() | nil, String.t() | nil) :: [String.t()]
  def site_classes(html, site_id) when is_binary(html) do
    declared = html |> names() |> declarations(site_id)
    classes(html, open_of(declared), declared)
  end

  def site_classes(_html, _site_id), do: []

  @doc """
  One component marker read apart into a `t:tree/0` — what the content editor's settings edit.
  `:error` when `marker` is not exactly one component marker.

      read(~s([[component chelekom-card]][[component chelekom-card-title title="Hi" /]]Text[[/component]]))
      #=> {:ok, %{name: "chelekom-card", attrs: %{}, parts: [
      #=>   {:component, %{name: "chelekom-card-title", attrs: %{"title" => "Hi"}, parts: []}},
      #=>   {:text, "Text"}
      #=> ]}}
  """
  @spec read(String.t()) :: {:ok, tree()} | :error
  def read(marker) when is_binary(marker) do
    case parse(String.trim(marker)) do
      [{:component, top}] -> {:ok, tree_of(top, 0)}
      _not_one_marker -> :error
    end
  end

  def read(_marker), do: :error

  @doc """
  The marker for `tree`, with every component and slot inside it — `read/1` the other way. `nil`
  when a name or a key in it could not be read back (`marker/3`).
  """
  @spec write(tree()) :: String.t() | nil
  def write(%{name: name, attrs: attrs, parts: parts}) do
    case written_parts(parts) do
      inner when is_binary(inner) -> marker(name, attrs, inner)
      nil -> nil
    end
  end

  def write(_tree), do: nil

  @doc """
  Splits `html` into the HTML the content editor edits and the components standing alone in it,
  which it holds as blocks.

  A marker stands alone when its paragraph holds nothing else — the marker `parse/1` draws without
  the `<p>` — or when it sits inside no element at all. A marker sharing its paragraph with text
  stays in the HTML around it. Each component's `source` is what it was cut from, so the pieces'
  HTML and the components' `source`, joined in order, are `html` again.

      segments(~s(<p>Hi</p><p>[[component chelekom-badge size="small" /]]</p>))
      #=> [
      #=>   {:html, "<p>Hi</p>"},
      #=>   {:component, %{name: "chelekom-badge", attrs: %{"size" => "small"}, inner: nil,
      #=>     marker: ~s([[component chelekom-badge size="small" /]]),
      #=>     source: ~s(<p>[[component chelekom-badge size="small" /]]</p>)}}
      #=> ]
  """
  @spec segments(String.t()) :: [segment()]
  def segments(html) when is_binary(html) do
    case :binary.match(html, @open) do
      :nomatch -> [{:html, html}]
      _found -> html |> outermost() |> Enum.flat_map(&standing(&1, html)) |> pieces(html)
    end
  end

  @doc """
  The attributes of `given` a component declaring `declared` takes, cast to their declared types.

  `declared` is the component's attribute declarations, as `__component_information__/1` or the
  row holds them; `given` is a marker's `attrs`. What is not declared, cannot be cast, or is one of
  the names an author never sets is left out. The HTML attributes a `global` attribute takes are
  gathered under its name, as the module documentation says.

      cast([%{name: "count", type: "integer"}, %{name: "open", type: "boolean"}],
           %{"count" => "3", "open" => true, "phx-click" => "boom"})
      #=> %{count: 3, open: true}

      cast([%{name: "rest", type: "global", opts: %{"include" => ["circle"]}}],
           %{"circle" => true, "aria-label" => "Scan", "onclick" => "boom"})
      #=> %{rest: %{:circle => true, "aria-label" => "Scan"}}

      cast([%{name: "nodes", type: "list"}, %{name: "labels", type: "map"}],
           %{"nodes" => ~s([{"label":"src"}]), "labels" => ~s({"days":"d"})})
      #=> %{nodes: [%{label: "src"}], labels: %{"days" => "d"}}
  """
  @spec cast([map()], %{String.t() => String.t() | true}) :: %{atom() => term()}
  def cast(declared, given) when is_list(declared) and is_map(given) do
    for attr <- declared,
        castable?(attr),
        name = Inspector.name(attr),
        Map.has_key?(given, name),
        {:ok, value} <- [cast_attr(attr, Map.fetch!(given, name))],
        into: global(declared, given),
        do: {String.to_existing_atom(name), value}
  end

  # THE HTML ATTRIBUTES A `global` ATTRIBUTE TAKES, under its name. An `include` name becomes the
  # atom the declaration spells, which a template reads as `@rest[:circle]`; any other stays a
  # string, which `{@rest}` writes the same and which mints no atom.
  defp global(declared, given) do
    with %{} = attr <- Enum.find(declared, &(type(&1) == "global")),
         name when is_binary(name) <- Inspector.name(attr),
         taken = taken_globals(declared, attr, given),
         true <- taken != %{} do
      %{String.to_existing_atom(name) => taken}
    else
      _none -> %{}
    end
  end

  defp taken_globals(declared, attr, given) do
    own = MapSet.new(declared, &Inspector.name/1)
    include = for name <- List.wrap(Inspector.opts(attr)["include"]), is_binary(name), do: name

    for {key, value} <- given,
        not MapSet.member?(own, key),
        key in include or global_html?(key),
        safe_global?(key),
        {:ok, value} <- [global_value(key, value)],
        into: %{},
        do: {(key in include && String.to_atom(key)) || key, value}
  end

  @globals ~w(accesskey autocapitalize autocorrect autofocus dir draggable enterkeyhint hidden inert
              inputmode lang role spellcheck tabindex title translate)

  defp global_html?(key),
    do: key in @globals or String.starts_with?(key, ["aria-", "data-"])

  @unsafe_globals ~w(style method csrf_token data-method data-to data-csrf)

  defp safe_global?(key) do
    lower = String.downcase(key)

    lower not in @reserved and lower not in @unsafe_globals and
      not String.starts_with?(lower, ["on", "phx", "data-phx"])
  end

  @addresses ~w(href src action formaction poster cite ping)

  defp global_value(_key, true), do: {:ok, true}
  defp global_value(_key, "true"), do: {:ok, true}
  defp global_value(_key, "false"), do: :error

  defp global_value(key, value) when key in @addresses and is_binary(value) do
    case safe_address?(value) do
      true -> {:ok, value}
      false -> :error
    end
  end

  defp global_value(_key, value) when is_binary(value), do: {:ok, value}
  defp global_value(_key, _value), do: :error

  # A browser drops control characters and spaces from an address before it reads its scheme, so
  # `java\tscript:` is read without them.
  defp safe_address?(value) do
    case value |> String.replace(~r/[\x00-\x20\x7F]/, "") |> URI.parse() do
      %URI{scheme: nil} -> true
      %URI{scheme: scheme} -> String.downcase(scheme) in ~w(http https mailto tel)
    end
  end

  @doc """
  The marker for component `name` with `attrs` and `inner` content — what the editor's Insert writes.

  A blank value is left out, so the component's own default applies; a blank `inner` writes the
  self-closing form. Attributes are written in name order, `&`, `<` and `>` in a value as entities.
  A value holding both kinds of quote has its double quotes written as single ones, since stored
  content cannot carry an escaped quote. `nil` when `name`, or a key, could not be read back as
  one, or is a key no author sets.

      marker("chelekom-alert", %{"title" => "Heads up", "size" => ""}, "Read <b>this</b>")
      #=> ~s([[component chelekom-alert title="Heads up"]]Read <b>this</b>[[/component]])
  """
  @spec marker(String.t(), map() | nil, String.t() | nil) :: String.t() | nil
  def marker(name, attrs, inner), do: written({@open, @close}, name, attrs, inner)

  @doc """
  The slot marker for the slot `name` with `attrs` and `inner` content, written as `marker/3` writes
  a component's.

      slot_marker("source", %{"src" => "/a.mp4", "type" => "video/mp4"}, nil)
      #=> ~s([[slot source src="/a.mp4" type="video/mp4" /]])
  """
  @spec slot_marker(String.t(), map() | nil, String.t() | nil) :: String.t() | nil
  def slot_marker(name, attrs, inner), do: written({@slot_open, @slot_close}, name, attrs, inner)

  defp written(tags, name, attrs, inner)
       when is_binary(name) and (is_map(attrs) or is_nil(attrs)) do
    written =
      (attrs || %{})
      |> Enum.map(fn {key, value} -> {to_string(key), written_value(value)} end)
      |> Enum.reject(fn {_key, value} -> value == "" end)
      |> Enum.sort()

    case Regex.match?(@name, name) and Enum.all?(written, fn {key, _} -> key?(key) end) do
      true -> written_marker(tags, name, Enum.map(written, &written_attr/1), blank_to_nil(inner))
      false -> nil
    end
  end

  defp written(_tags, _name, _attrs, _inner), do: nil

  @doc """
  Whether a component template draws content itself — calls `rich_content`. Such a component is
  never drawn inside content, which could hold a marker for it.
  """
  @spec draws_content?(String.t() | nil) :: boolean()
  def draws_content?(template) when is_binary(template),
    do: String.contains?(template, "rich_content")

  def draws_content?(_template), do: false

  @doc """
  The components an author may embed on the site `site_id`, with the attributes a marker can set —
  what the editor's picker offers. `nil` is the global components alone.

  Active components of the site and global ones, every one of them, read as `actor` through
  `:for_tenant_with_globals`; a site's own component hides the global one of the same name, as it
  does when drawn. Components that draw content themselves are left out, and so are those requiring
  an attribute the editor has no field for — a list or a map, which a marker is written with by
  hand (see Lists and maps), or a struct — and every such attribute, and every one `cast/2` would
  drop.
  """
  @spec embeddable(map() | nil, String.t() | nil) :: {:ok, [entry()]} | {:error, term()}
  def embeddable(actor, site_id) do
    {arguments, tenant} = scope(actor, site_id)

    Component
    |> Ash.Query.for_read(:for_tenant_with_globals, arguments, actor: actor, tenant: tenant)
    |> Ash.Query.filter(active == true and not contains(template, "rich_content"))
    |> within(site_id)
    |> Ash.Query.select([
      :id,
      :name,
      :description,
      :type,
      :stateful,
      :attrs,
      :slots,
      :template,
      :helpers,
      :examples,
      :site_id
    ])
    |> Ash.Query.load(:furnishing)
    |> Ash.Query.sort(name: :asc)
    |> every([], 0)
    |> case do
      {:ok, rows} -> {:ok, rows |> own_first() |> Enum.filter(&settable?/1) |> Enum.map(&entry/1)}
      {:error, _reason} = error -> error
    end
  end

  # A COMPONENT THAT REQUIRES WHAT THE EDITOR HAS NO FIELD FOR — a list or a map, written by hand as
  # JSON, or a struct, which no marker holds — would arrive from the palette drawing nothing, so it is
  # never offered. The ones a marker fills itself are not counted.
  defp settable?(row) do
    Enum.all?(row.attrs || [], fn attr ->
      name = to_string(Inspector.name(attr))
      not Inspector.required?(attr) or name in @reserved or offered?(attr)
    end)
  end

  # EVERY PAGE OF IT. The read pages at most 250 rows, and a site's own components with a kit's came
  # to more — the ones past the 250th by name were never offered.
  @page 250

  defp every(query, read, offset, opts \\ []) do
    case Ash.read(query, Keyword.put(opts, :page, limit: @page, offset: offset)) do
      {:ok, %{results: rows, more?: true}} -> every(query, [rows | read], offset + @page, opts)
      {:ok, %{results: rows}} -> {:ok, [rows | read] |> Enum.reverse() |> Enum.concat()}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The components the content editor's palette offers on the site `site_id`, read as `actor` —
  `embeddable/2`, as a plugin answering `runtime:content:editor_palette` leaves it.
  """
  @spec palette(map() | nil, String.t() | nil) :: {:ok, [entry()]} | {:error, term()}
  def palette(actor, site_id) do
    with {:ok, entries} <- embeddable(actor, site_id) do
      data = %{site_id: site_id, components: entries}

      case Hook.call(@palette_event, data, meta: %{current_user: actor}) do
        %{components: components} when is_list(components) -> {:ok, components}
        _unchanged -> {:ok, entries}
      end
    end
  end

  # The builder palette's scope: a master names the site as the read's argument, a site user reads
  # as its own site's tenant.
  defp scope(%{site_id: nil}, site_id) when is_binary(site_id), do: {%{site_id: site_id}, nil}
  defp scope(%{site_id: own}, _site_id) when is_binary(own), do: {%{}, own}
  defp scope(_master_without_a_site, _site_id), do: {%{}, nil}

  defp within(query, nil), do: Ash.Query.filter(query, is_nil(site_id))
  defp within(query, site_id), do: Ash.Query.filter(query, is_nil(site_id) or site_id == ^site_id)

  defp own_first(rows) do
    own = for %{site_id: id, name: name} <- rows, not is_nil(id), into: MapSet.new(), do: name
    Enum.reject(rows, &(is_nil(&1.site_id) and MapSet.member?(own, &1.name)))
  end

  # What the component says it arrives with, when it says anything a block can be made of.
  defp furnishing(declared) do
    case Furnishing.build(declared) do
      {:ok, furnishing} -> if(Furnishing.empty?(furnishing), do: nil, else: furnishing)
      :none -> nil
    end
  end

  # A KIT'S HELPER PICKS ITS CLASSES BY THE VALUES IT IS CALLED WITH, and says which values each of
  # its clauses matches: `color_variant("base", _)` matches every colour, so under the `base` variant
  # the colour draws nothing. The clauses are read here once, by attribute.
  defp switches(row) do
    template = Map.get(row, :template) || ""
    helpers = Enum.map(Map.get(row, :helpers) || [], &plain_map/1)

    bindings =
      UiKitHandler.axis_bindings(%{
        "name" => row.name,
        "template" => template,
        "helpers" => helpers,
        "attrs" => Enum.map(Map.get(row, :attrs) || [], &plain_map/1)
      })

    clauses =
      helpers
      |> Enum.group_by(& &1["name"])
      |> Enum.filter(fn {_name, clauses} -> Enum.any?(clauses, &(&1["discriminators"] != [])) end)
      |> Map.new(fn {name, clauses} -> {name, Enum.map(clauses, &clause(&1, bindings))} end)

    %{helpers: Map.values(clauses), through: through(template, Map.keys(clauses))}
  end

  defp clause(helper, bindings) do
    Enum.reduce_while(helper["discriminators"] || [], %{}, fn discriminator, clause ->
      discriminator = plain_map(discriminator)

      case Map.fetch(bindings, discriminator["axis"]) do
        {:ok, attr} ->
          {:cont, Map.put(clause, attr, Enum.map(discriminator["values"], &to_string/1))}

        :error ->
          {:halt, :unknown}
      end
    end)
  end

  # The attributes the template hands to those helpers and to nothing else.
  defp through(template, helper_names) do
    expressions = Markup.expressions(template)

    used =
      for expression <- expressions,
          {called, args} <- CodeReads.calls(expression),
          Atom.to_string(called) in helper_names,
          {:@, _meta, [{name, _name_meta, context}]} <- args,
          is_atom(name) and is_atom(context),
          uniq: true,
          do: Atom.to_string(name)

    Enum.filter(used, fn attr ->
      Enum.all?(expressions, &(uses(&1, attr) == handed(&1, attr, helper_names)))
    end)
  end

  defp uses(expression, attr), do: length(Regex.scan(~r/@#{Regex.escape(attr)}\b/, expression))

  defp handed(expression, attr, helper_names) do
    for {called, args} <- CodeReads.calls(expression),
        Atom.to_string(called) in helper_names,
        {:@, _meta, [{name, _name_meta, _context}]} <- args,
        Atom.to_string(name) == attr,
        reduce: 0,
        do: (count -> count + 1)
  end

  defp plain_map(%_struct{} = struct), do: struct |> Map.from_struct() |> plain_map()
  defp plain_map(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp plain_map(other), do: other

  @doc """
  Whether the attribute `name` of the palette `entry` draws nothing with the other attributes at
  `values` — the marker's, the rest at their defaults: the values of the other attributes that pick
  a clause of every helper it goes to that matches all of its own values alike, or `nil` when it
  draws something, or when that cannot be told.

      inert(blockquote, "color", %{"variant" => "base"})
      #=> %{"variant" => "base"}
  """
  @spec inert(entry(), String.t(), map()) :: %{String.t() => String.t()} | nil
  def inert(%{switches: %{helpers: helpers, through: through}, attrs: attrs}, name, values) do
    governing = Enum.filter(helpers, fn clauses -> Enum.any?(clauses, &matches_on?(&1, name)) end)

    with true <- name in through,
         [_ | _] <- governing,
         false <- Enum.any?(governing, &(:unknown in &1)),
         %{values: [_ | _] = choices} <- Enum.find(attrs, &(&1.name == name)) do
      current = current(attrs, values)

      governing
      |> Enum.map(&chosen(&1, name, choices, current))
      |> Enum.reduce_while(%{}, fn
        %{} = clause, reason ->
          {:cont, Map.merge(reason, Map.new(clause, &{elem(&1, 0), current[elem(&1, 0)]}))}

        nil, _reason ->
          {:halt, nil}
      end)
      |> case do
        reason when map_size(reason) > 0 -> reason
        _none -> nil
      end
    else
      _cannot_tell -> nil
    end
  end

  def inert(_entry, _name, _values), do: nil

  defp matches_on?(%{} = clause, name), do: Map.has_key?(clause, name)
  defp matches_on?(:unknown, _name), do: false

  # The one clause every value of `name` reaches, when it is one that does not match on it.
  defp chosen(clauses, name, choices, current) do
    case choices
         |> Enum.map(&first_clause(clauses, Map.put(current, name, to_string(&1))))
         |> Enum.uniq() do
      [%{} = clause] -> if(Map.has_key?(clause, name), do: nil, else: clause)
      _several_or_none -> nil
    end
  end

  defp first_clause(clauses, current) do
    Enum.find(clauses, fn clause ->
      Enum.all?(clause, fn {attr, accepted} -> current[attr] in accepted end)
    end)
  end

  defp current(attrs, values) do
    Map.new(attrs, fn attr ->
      case Map.get(values, attr.name) do
        value when is_binary(value) and value != "" -> {attr.name, value}
        true -> {attr.name, "true"}
        _unset -> {attr.name, written_default(attr.default)}
      end
    end)
  end

  defp written_default(value) when is_binary(value), do: value
  defp written_default(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp written_default(value) when is_number(value), do: to_string(value)
  defp written_default(_none_or_data), do: nil

  @doc """
  The classes a preview's notice is drawn with — a marker that draws nothing, or a component that
  could not be drawn — for whatever builds the stylesheet a preview is drawn with.
  """
  @spec unavailable_class() :: String.t()
  def unavailable_class,
    do: "inline-block rounded border border-red-300 px-2 py-1 text-sm text-red-600"

  @doc """
  The palette entry for a component `row` — a stored component, or anything with its fields — as
  `embeddable/2` lists it.
  """
  @spec entry(map()) :: entry()
  def entry(row) do
    %{
      name: row.name,
      description: row.description,
      type: row.type,
      stateful: row.stateful == true,
      global: is_nil(row.site_id),
      inner_block: Enum.any?(row.slots || [], &Inspector.inner_block?/1),
      category: category(row.name, row.type),
      examples: Enum.filter(row.examples || [], &is_binary/1),
      furnishing: furnishing(Map.get(row, :furnishing)),
      switches: switches(row),
      attrs: attr_entries(row.attrs),
      slots:
        for slot <- Inspector.addable_slots(row) do
          name = slot_name(slot)

          %{
            name: name,
            doc: Inspector.doc(slot),
            required: Inspector.required?(slot),
            inner: Inspector.renders_slot?(row, name),
            attrs: attr_entries(Inspector.attrs(slot))
          }
        end
    }
  end

  # THE BUILDER'S OWN READING OF AN ATTRIBUTE: the heading its Inspector files it under, and
  # whether it is a picture or a video — the kit's `editor: "media"` hint, or the name an HTML media
  # element gives one (`src`, `poster`, `srcset`) — so both editors ask the same question the same
  # way, of any kit.
  defp attr_entries(attrs) do
    groups =
      for {group, grouped} <- Inspector.grouped(%{attrs: attrs || []}),
          attr <- grouped,
          into: %{},
          do: {Inspector.name(attr), group}

    for attr <- attrs || [], offered?(attr) do
      name = to_string(Inspector.name(attr))

      %{
        name: name,
        type: type(attr),
        values: values(attr),
        default: Inspector.default(attr),
        doc: Inspector.doc(attr),
        required: Inspector.required?(attr),
        group: Map.get(groups, Inspector.name(attr), "Properties"),
        media: Inspector.widget(attr) == :media or Inspector.element_widget("img", name) == :media
      }
    end
  end

  # THE PALETTE'S HEADINGS, TEXT FIRST — what a post needs most. A kit's own `type` names the group
  # when it is one of these, under one spelling; a component typed `general`, or not at all, is
  # placed by the words its name is made of, read in order; a type of the kit's own that is none of
  # these keeps its name; and what nothing places is Other.
  @category_order ~w(text media layout buttons data disclosure feedback navigation overlays forms)

  @category_types %{
    "text" => "text",
    "typography" => "text",
    "media" => "media",
    "layout" => "layout",
    "button" => "buttons",
    "buttons" => "buttons",
    "actions" => "buttons",
    "data" => "data",
    "data display" => "data",
    "data-display" => "data",
    "disclosure" => "disclosure",
    "feedback" => "feedback",
    "nav" => "navigation",
    "navigation" => "navigation",
    "navigations" => "navigation",
    "overlay" => "overlays",
    "overlays" => "overlays",
    "form" => "forms",
    "forms" => "forms"
  }

  @category_words [
    {"text",
     ~w(h1 h2 h3 h4 h5 h6 heading headline p paragraph typography strong em mark small s u del ins abbr cite blockquote quote kbd keyboard code highlight link anchor list ul ol li dl dt dd table tr td th divider hr separator figcaption caption)},
    {"media", ~w(image img avatar video audio gallery carousel icon figure picture media embed)},
    {"layout",
     ~w(flex grid card jumbotron container wrapper stack row columns section timeline stepper stat accordion tabs collapse collapsible spoiler mockup shape scroller splitter)},
    {"buttons", ~w(button btn fab burger clipboard)},
    {"feedback",
     ~w(alert banner toast flash progress spinner skeleton meter rating badge indicator)},
    {"navigation", ~w(breadcrumb pagination navbar menu nav sidebar footer header dock)},
    {"overlays", ~w(modal drawer dialog popover tooltip overlay)},
    {"forms",
     ~w(form field input select checkbox radio textarea toggle switch slider range combobox autocomplete calendar otp fieldset)}
  ]

  @doc """
  The palette heading a component is listed under — `"text"`, `"media"`, `"layout"`, `"buttons"`,
  `"data"`, `"disclosure"`, `"feedback"`, `"navigation"`, `"overlays"`, `"forms"`, a kit's own
  type, or `"other"` — from its kit `type` and the words of its `name`.

      category("chelekom-h2", "general")   #=> "text"
      category("chelekom-video", "media")  #=> "media"
      category("acme-hero", "marketing")   #=> "marketing"
  """
  @spec category(String.t(), String.t() | nil) :: String.t()
  def category(name, type) do
    kind = type |> to_string() |> String.downcase() |> String.trim()

    case Map.fetch(@category_types, kind) do
      {:ok, category} -> category
      :error -> named_category(to_string(name)) || kit_category(kind)
    end
  end

  defp named_category(name) do
    name
    |> String.downcase()
    |> String.split(["-", "_"])
    |> Enum.find_value(fn word ->
      Enum.find_value(@category_words, fn {category, words} -> word in words && category end)
    end)
  end

  defp kit_category(kind) when kind in ["", "general", "misc", "other"], do: "other"
  defp kit_category(kind), do: kind

  @doc """
  `categories`' names in the order the palette shows them: text first, the ones above in their
  order, a kit's own after them by name, and Other last.
  """
  @spec sort_categories([String.t()]) :: [String.t()]
  def sort_categories(categories) do
    categories
    |> Enum.uniq()
    |> Enum.sort_by(fn category ->
      case Enum.find_index(@category_order, &(&1 == category)) do
        nil when category == "other" -> {2, category}
        nil -> {1, category}
        index -> {0, index}
      end
    end)
  end

  @doc "A palette heading's name, in the reader's language."
  @spec category_label(String.t()) :: String.t()
  def category_label("text"), do: gettext("Text")
  def category_label("media"), do: gettext("Media")
  def category_label("layout"), do: gettext("Layout")
  def category_label("buttons"), do: gettext("Buttons")
  def category_label("data"), do: gettext("Data")
  def category_label("disclosure"), do: gettext("Disclosure")
  def category_label("feedback"), do: gettext("Feedback")
  def category_label("navigation"), do: gettext("Navigation")
  def category_label("overlays"), do: gettext("Overlays")
  def category_label("forms"), do: gettext("Forms")
  def category_label("other"), do: gettext("Other")

  def category_label(kit),
    do: kit |> to_string() |> String.replace(["-", "_"], " ") |> String.capitalize()

  @doc """
  Draws `assigns.html` with its markers drawn as components — the body of `rich_content/1`.

  `mode` is `:live` where LiveView runs the result, and `:static` where it is rendered to a string:
  a stateful component is then drawn cold, and a marker that draws nothing says why.
  """
  @spec draw(map(), :live | :static) :: Phoenix.LiveView.Rendered.t()
  def draw(%{html: html} = assigns, mode) when is_binary(html) and mode in [:live, :static] do
    context = %{
      site: assigns[:site],
      prefix: assigns[:id] || "content",
      current_user: assigns[:current_user],
      level: 0,
      slot_args: []
    }

    html |> parse() |> drawn_parts(context, mode)
  end

  def draw(_assigns, _mode) do
    assigns = %{}
    ~H""
  end

  defp drawn_parts(chunks, context, mode) do
    assigns = %{parts: Enum.map(chunks, &part(&1, context, mode))}

    # NOT FORMATTED, because the formatter would put each part on a line of its own, and the
    # whitespace between them would be drawn into the content.
    ~H"<%= for part <- @parts do %>{part}<% end %>"noformat
  end

  defp part({:html, html}, _context, _mode), do: Phoenix.HTML.raw(html)

  defp part({:component, marker}, context, mode) do
    with {:ok, module, site} <- reach(marker.name, context.site),
         :ok <- placeable(module),
         %{component: component} = information <- module.__component_information__(),
         declared = List.wrap(component.attrs),
         :ok <- readable(unreadable(declared, marker.attrs, "")),
         {:ok, attrs, inner} <- before_draw(marker, site, cast(declared, marker.attrs), context),
         {content, entries} = held(inner, context.level),
         slots = List.wrap(component.slots),
         :ok <- readable(unreadable_entries(slots, entries)),
         :ok <- required(declared, attrs, slots, entries) do
      child = %{
        context
        | prefix: Enum.join([context.prefix, marker.index], "-"),
          level: context.level + 1
      }

      # WHAT THE MARKER WRITES, AND NOTHING FOR WHAT IT LEAVES OUT — what `<.component>` in a template
      # hands. The component's declaration merges its own defaults in, and an attribute declared
      # without one stays absent, as Phoenix leaves it: a kit's `%{navigate: _} = assigns` clause is
      # taken only when the marker writes `navigate`.
      attrs
      |> Map.merge(%{component_name: marker.name, site: site, __changed__: nil})
      |> inner_block(Enum.any?(slots, &Inspector.inner_block?/1), content, child, mode)
      |> named_slots(slots, entries, child, mode)
      |> with_id(information.private[:stateful] == true or declares_id?(declared), child.prefix)
      |> visitor(
        Enum.any?(declared, &(Inspector.name(&1) == "current_user")),
        context.current_user
      )
      |> drawn(mode)
    else
      :refused -> nil
      reason -> unavailable(marker.name, reason, mode)
    end
  end

  # What one component holds: the content its `inner_block` draws, and its slot entries. Past
  # `@depth` the content is drawn as it is written.
  defp held(nil, _level), do: {[], []}
  defp held(inner, level) when level >= @depth, do: {[{:html, inner}], []}
  defp held(inner, _level), do: inner |> inside() |> Enum.split_with(&(elem(&1, 0) != :slot))

  # THE SITE'S OWN COMPONENT FIRST, THEN THE GLOBAL ONE — a site that installed its own
  # `chelekom-alert` sees its own in its posts, and every other site the shared one. Each is asked
  # of `SiteState`'s names, as a string, before a module name is made from it.
  defp reach(name, site) when site in [nil, "Global"], do: global(name)

  defp reach(name, site) do
    with {:ok, %{id: site_id}} <- SiteState.get_by_name(site),
         true <- SiteState.component?(site_id, name),
         {:ok, module} <- LiveViewHelpers.resolve_component(name, site) do
      {:ok, module, site}
    else
      _not_the_sites -> global(name)
    end
  end

  defp global(name) do
    with true <- SiteState.component?(nil, name),
         {:ok, module} <- LiveViewHelpers.resolve_component(name, nil) do
      {:ok, module, nil}
    else
      _unknown -> :unavailable
    end
  end

  defp placeable(module) do
    case module.__component_information__([:private, :draws_content]) do
      true -> :draws_content
      _not_a_content_drawer -> :ok
    end
  end

  defp before_draw(marker, site, attrs, %{slot_args: args}) do
    data = %{component_name: marker.name, site: site, attrs: attrs, inner: marker.inner}

    meta = %{
      site_id: Translations.site(),
      index: marker.index,
      marker_attrs: marker.attrs,
      slot_arg: List.first(args),
      slot_args: args
    }

    case Hook.call(@event, data, meta: meta) do
      %{suppress: true} ->
        :refused

      %{attrs: %{} = changed} = answer ->
        {:ok, changed, Map.get(answer, :inner, marker.inner)}

      _unchanged ->
        {:ok, attrs, marker.inner}
    end
  end

  # The attributes and slots the component requires and the marker left out — a slot entry's
  # required attributes as `slot.attribute`.
  defp required(declared, attrs, slots, entries) do
    missing =
      for(
        attr <- declared,
        Inspector.required?(attr),
        name = Inspector.name(attr),
        name not in @reserved,
        not Map.has_key?(attrs, String.to_existing_atom(name)),
        do: name
      ) ++ Enum.flat_map(named(slots), &missing_slot(&1, entries))

    case missing do
      [] -> :ok
      names -> {:missing, names}
    end
  end

  defp readable([]), do: :ok
  defp readable(problems), do: {:unreadable, problems}

  # The `list` and `map` attributes `given` writes that cannot be read, each named as
  # `prefix <> name` with the reason.
  defp unreadable(declared, given, prefix) do
    for attr <- declared,
        castable?(attr),
        type(attr) in @json_types,
        name = Inspector.name(attr),
        Map.has_key?(given, name),
        {:error, reason} <- [cast_attr(attr, Map.fetch!(given, name))],
        do: {prefix <> name, reason}
  end

  # The same, of each slot entry against its slot's attributes, named as `slot.attribute`.
  defp unreadable_entries(slots, entries) do
    for slot <- named(slots),
        name = slot_name(slot),
        {:slot, %{name: ^name} = entry} <- entries,
        problem <- unreadable(Inspector.attrs(slot), entry.attrs, name <> "."),
        uniq: true,
        do: problem
  end

  defp missing_slot(slot, entries) do
    name = slot_name(slot)

    case for({:slot, %{name: ^name} = entry} <- entries, do: entry) do
      [] ->
        (Inspector.required?(slot) && [name]) || []

      given ->
        for entry <- given,
            attr <- Inspector.attrs(slot),
            Inspector.required?(attr),
            not Map.has_key?(entry.attrs, Inspector.name(attr)),
            uniq: true,
            do: name <> "." <> Inspector.name(attr)
    end
  end

  # The slots a marker fills with slot markers: every one declared but `inner_block`.
  defp named(slots), do: Enum.reject(slots, &Inspector.inner_block?/1)

  defp slot_name(slot), do: to_string(Inspector.name(slot))

  defp inner_block(assigns, false, _content, _child, _mode), do: assigns
  defp inner_block(assigns, true, [], _child, _mode), do: Map.put(assigns, :inner_block, [])

  defp inner_block(assigns, true, content, child, mode) do
    Map.put(assigns, :inner_block, [
      %{
        __slot__: :inner_block,
        inner_block: fn _changed, arg -> drawn_parts(content, handed(child, arg), mode) end
      }
    ])
  end

  # EVERY SLOT THE COMPONENT DECLARES IS PASSED, an empty list when the content fills none of it —
  # a template reads `@source` whether or not anything was written for it. Each entry carries the
  # attributes the slot declares, cast as a component's are, a declared one left out as its default,
  # and its own content drawn as content, its markers' ids under `<parent>-<slot>-<n>` so they never
  # take the id of one in the inner block. The slot's name becomes an atom only as the declaration
  # spells it.
  defp named_slots(assigns, slots, entries, child, mode) do
    Enum.reduce(named(slots), assigns, fn slot, assigns ->
      name = slot_name(slot)
      key = String.to_existing_atom(name)

      own = for {:slot, %{name: ^name} = entry} <- entries, do: entry

      given =
        for {entry, n} <- Enum.with_index(own) do
          slot_entry(
            key,
            slot,
            entry,
            %{child | prefix: Enum.join([child.prefix, name, n], "-")},
            mode
          )
        end

      Map.put(assigns, key, given)
    end)
  end

  # A SLOT ENTRY HOLDS WHAT WAS WRITTEN ON IT, as Phoenix's does: an attribute left out is absent,
  # not nil. A kit hands its entries on whole — `chelekom-list` spreads each `item` into a
  # `chelekom-li` — and a nil put there for every declared attribute overrode the li's own default,
  # or answered a `Map.get(entry, key, default)` with nil: a list, a carousel and a combobox that
  # arrived filled in drew nothing.
  defp slot_entry(key, slot, entry, child, mode) do
    declared = Inspector.attrs(slot)

    defaults =
      for attr <- declared,
          castable?(attr),
          default = Inspector.default(attr),
          not is_nil(default),
          into: %{},
          do: {attr |> Inspector.name() |> to_string() |> String.to_existing_atom(), default}

    defaults
    |> Map.merge(cast(declared, entry.attrs))
    |> Map.merge(%{__slot__: key, inner_block: slot_content(entry.inner, child, mode)})
  end

  # AN ENTRY WRITTEN WITH NOTHING INSIDE DRAWS NOTHING THERE. Phoenix raises on `render_slot` of an
  # entry whose `inner_block` is nil, so a `[[slot trigger /]]` took down the component around it —
  # and every component it sat inside.
  defp slot_content(nil, _child, _mode), do: fn _changed, _arg -> "" end

  defp slot_content(inner, child, mode) do
    content =
      case child.level >= @depth do
        true -> [{:html, inner}]
        false -> parse(inner)
      end

    fn _changed, arg -> drawn_parts(content, handed(child, arg), mode) end
  end

  # What a component hands `render_slot/2`, for every marker inside; `nil`, handed when it passes
  # nothing, keeps what the markers around it were given.
  defp handed(context, nil), do: context
  defp handed(context, arg), do: %{context | slot_args: [arg | context.slot_args]}

  # AN ID FROM ITS PLACE IN THE CONTENT, never from the marker, for a stateful component and for one
  # declaring `id` — a hook needs one — so it is the same element across renders and unique on the
  # page.
  defp with_id(assigns, true, id), do: Map.put(assigns, :id, id)
  defp with_id(assigns, false, _id), do: assigns

  defp declares_id?(declared), do: Enum.any?(declared, &(Inspector.name(&1) == "id"))

  # The visitor, `nil` for a guest, to a component that declares `current_user`.
  defp visitor(assigns, true, user), do: Map.put(assigns, :current_user, user)
  defp visitor(assigns, false, _user), do: assigns

  # A MARKER IS DRAWN INSIDE `ComponentBoundary.draw/3`: a component that raises while it draws is a
  # box in the content, and the page around it draws. Only here — a page's, a layout's and an error
  # page's own `<.component>` calls go straight to `LiveViewHelpers.component/1`.
  defp drawn(%{component_name: name, site: site} = assigns, :live),
    do: ComponentBoundary.draw(name, site, fn -> LiveViewHelpers.component(assigns) end)

  defp drawn(assigns, :static), do: LiveViewHelpers.static_component(assigns)

  defp unavailable(_name, _reason, :live), do: nil

  defp unavailable(name, reason, :static) do
    assigns = %{message: unavailable_message(name, reason), class: unavailable_class()}

    ~H"""
    <span data-role="content-component-unavailable" class={@class}>
      {@message}
    </span>
    """
  end

  defp unavailable_message(name, :draws_content),
    do:
      gettext("%{name} draws content of its own, so it cannot be placed inside content.",
        name: name
      )

  defp unavailable_message(name, {:missing, names}),
    do:
      gettext("%{name} needs %{attrs}, so visitors see nothing here.",
        name: name,
        attrs: Enum.join(names, ", ")
      )

  defp unavailable_message(name, {:unreadable, problems}),
    do:
      gettext("%{name} cannot read %{attrs}, so visitors see nothing here.",
        name: name,
        attrs: Enum.map_join(problems, ", ", &unreadable_message/1)
      )

  defp unavailable_message(name, _unavailable),
    do:
      gettext("%{name} is not a component this site can show, so visitors see nothing here.",
        name: name
      )

  defp unreadable_message({attr, :json}), do: gettext("%{attr} (not valid JSON)", attr: attr)

  defp unreadable_message({attr, {:kind, "list"}}),
    do: gettext("%{attr} (not a JSON array)", attr: attr)

  defp unreadable_message({attr, {:kind, "map"}}),
    do: gettext("%{attr} (not a JSON object)", attr: attr)

  defp unreadable_message({attr, :size}),
    do: gettext("%{attr} (larger than %{size} KB)", attr: attr, size: div(@json_bytes, 1024))

  defp unreadable_message({attr, :depth}),
    do: gettext("%{attr} (deeper than %{depth} levels)", attr: attr, depth: @json_depth)

  ####################################################################################
  ############################ (▰˘◡˘▰) Casting (▰˘◡˘▰) ###############################
  ####################################################################################

  defp castable?(attr) do
    name = Inspector.name(attr)

    is_binary(name) and name not in @reserved and not String.starts_with?(name, "phx") and
      castable_type?(type(attr), values(attr))
  end

  # An attribute the content editor shows a field for: a castable one that is not written as JSON.
  defp offered?(attr), do: castable?(attr) and type(attr) not in @json_types

  defp type(attr), do: attr |> Inspector.type() |> to_string()

  defp castable_type?(type, _values) when type in ~w(string any boolean integer float list map),
    do: true

  defp castable_type?("atom", [_ | _]), do: true
  defp castable_type?(_type, _values), do: false

  # One written value of `attr`, cast as `cast/2` casts it. A `list` or `map` one that cannot be
  # read is `{:error, reason}`, every other that cannot `:error`.
  defp cast_attr(attr, given) do
    case {type(attr), values(attr)} do
      {type, _values} when type in @json_types ->
        json(given, type, atom_keyed?(Inspector.default(attr)))

      {"any", []} when is_binary(given) ->
        case json(given, "any", atom_keyed?(Inspector.default(attr))) do
          {:ok, value} -> {:ok, value}
          {:error, _not_json} -> {:ok, given}
        end

      {type, values} ->
        cast_value(type, given, values)
    end
  end

  # A JSON VALUE IS DATA. Jason decodes it into lists, maps, strings, numbers, booleans and nil; an
  # object's key is made an atom only when that atom already exists, and a value never is — so the
  # content a visitor's page carries can mint no atom and name no module.
  defp json(given, kind, atom_keyed?) when is_binary(given) do
    with :ok <- json_size(given),
         {:ok, value} <- json_decode(given, kind),
         :ok <- json_kind(value, kind) do
      json_walk(value, 1, atom_keyed?)
    end
  end

  defp json(_bare_key, kind, _atom_keyed?), do: {:error, {:kind, kind}}

  defp json_size(given) when byte_size(given) > @json_bytes, do: {:error, :size}
  defp json_size(_given), do: :ok

  # Only text opening an array or an object is handed to the decoder.
  defp json_decode(given, kind) do
    case String.trim_leading(given) do
      <<first, _rest::binary>> when first in [?[, ?{] ->
        case Jason.decode(given) do
          {:ok, value} -> {:ok, value}
          {:error, _invalid} -> {:error, :json}
        end

      _not_an_array_or_an_object ->
        {:error, {:kind, kind}}
    end
  end

  defp json_kind(value, "list") when is_list(value), do: :ok
  defp json_kind(value, "map") when is_map(value), do: :ok
  defp json_kind(value, "any") when is_list(value) or is_map(value), do: :ok
  defp json_kind(_value, kind), do: {:error, {:kind, kind}}

  # The decoded value with each object's keys as `json_key/2` reads them, or `{:error, :depth}` past
  # `@json_depth`. An object inside an array is a record; the top one is one when `atom_keyed?`.
  defp json_walk(value, depth, _atom_keyed?)
       when (is_list(value) or is_map(value)) and depth > @json_depth,
       do: {:error, :depth}

  defp json_walk(list, depth, _atom_keyed?) when is_list(list) do
    json_each(list, &json_walk(&1, depth + 1, true))
  end

  defp json_walk(map, depth, atom_keyed?) when is_map(map) do
    map
    |> Map.to_list()
    |> json_each(fn {key, value} ->
      with {:ok, value} <- json_walk(value, depth + 1, false),
           do: {:ok, {json_key(key, atom_keyed?), value}}
    end)
    |> case do
      {:ok, pairs} -> {:ok, Map.new(pairs)}
      error -> error
    end
  end

  defp json_walk(scalar, _depth, _atom_keyed?), do: {:ok, scalar}

  defp json_each(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, done} ->
      case fun.(item) do
        {:ok, item} -> {:cont, {:ok, [item | done]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, done} -> {:ok, Enum.reverse(done)}
      error -> error
    end
  end

  defp json_key("__" <> _rest = key, _atom_keyed?), do: key
  defp json_key(key, true), do: Helpers.known_key(key)
  defp json_key(key, false), do: key

  # Whether a declared default is a map with atom keys — a bundle's `__atom_map__` envelope with
  # pairs in it, or a map — which says the component reads that attribute's keys as atoms. An empty
  # one says nothing.
  defp atom_keyed?(%{__atom_map__: pairs}), do: pairs != []
  defp atom_keyed?(%{"__atom_map__" => pairs}), do: pairs != []

  defp atom_keyed?(%{} = map) when not is_struct(map),
    do: map_size(map) > 0 and map |> Map.keys() |> Enum.all?(&is_atom/1)

  defp atom_keyed?(_default), do: false

  defp values(attr) do
    case Inspector.opts(attr)["values"] do
      values when is_list(values) -> values
      _none -> []
    end
  end

  # AN ATOM ONLY FROM THE DECLARATION. The value an author wrote picks one of the declared values,
  # and that declared value is what becomes the atom, so no text a visitor's page carries can mint
  # one.
  defp cast_value("atom", given, values) when is_binary(given) do
    case Enum.find(values, &(to_string(&1) == given)) do
      nil -> :error
      value when is_atom(value) -> {:ok, value}
      value -> {:ok, String.to_atom(value)}
    end
  end

  defp cast_value("atom", _given, _values), do: :error

  defp cast_value(type, given, values) do
    with {:ok, value} <- typed(type, given), do: one_of(value, values)
  end

  defp typed("boolean", true), do: {:ok, true}
  defp typed("boolean", "true"), do: {:ok, true}
  defp typed("boolean", "false"), do: {:ok, false}
  defp typed("boolean", _given), do: :error
  defp typed(_type, true), do: :error

  defp typed("integer", given) do
    case Integer.parse(String.trim(given)) do
      {value, ""} -> {:ok, value}
      _not_a_whole_number -> :error
    end
  end

  defp typed("float", given) do
    case Float.parse(String.trim(given)) do
      {value, ""} -> {:ok, value}
      _not_a_number -> :error
    end
  end

  defp typed(_string_or_any, given), do: {:ok, given}

  defp one_of(value, []), do: {:ok, value}

  defp one_of(value, values) do
    case Enum.any?(values, &(to_string(&1) == to_string(value))) do
      true -> {:ok, value}
      false -> :error
    end
  end

  ####################################################################################
  ############################ (▰˘◡˘▰) Classes (▰˘◡˘▰) ###############################
  ####################################################################################

  defp html_class_values(html) do
    case :binary.match(html, "class") do
      :nomatch ->
        []

      _found ->
        @tag_with_attrs
        |> Regex.scan(html, capture: :first)
        |> Stream.flat_map(fn [tag] -> Regex.scan(@class_attr, tag, capture: :all_but_first) end)
        |> Stream.map(fn captured -> captured |> Enum.join() |> decode() end)
    end
  end

  defp marker_class_values(html, open, declared) do
    case :binary.match(html, [@open, @slot_open]) do
      :nomatch -> []
      _found -> html |> tree() |> marker_values(open, declared, [])
    end
  end

  defp marker_values(nodes, open, declared, slots) do
    Enum.flat_map(nodes, fn %{kind: kind, name: name, attrs: attrs, children: children} ->
      takes = (kind == :component && Map.get(open, name)) || []
      {own_attrs, inner_slots} = declaration(kind, name, declared, slots)

      own =
        for {key, value} when is_binary(value) <- Enum.sort(attrs),
            class_key?(key) or key in takes or
              (utilities?(value) and taken?(own_attrs, key, value)),
            do: value

      own ++ marker_values(children, open, declared, inner_slots)
    end)
  end

  # The attributes a marker declares, and the slots the markers inside it are read against: a
  # component's own, a slot's from the component it sits in, `[]` when `declared` holds none.
  defp declaration(:component, name, declared, _slots) do
    case Map.fetch(declared, name) do
      {:ok, %{attrs: attrs, slots: slots}} -> {attrs, slots}
      :error -> {[], []}
    end
  end

  defp declaration(:slot, name, _declared, slots) do
    case Enum.find(slots, &(to_string(Inspector.name(&1)) == name)) do
      nil -> {[], slots}
      slot -> {Inspector.attrs(slot), slots}
    end
  end

  # Whether a marker declaring `attrs` hands `value` on in `key`, as `cast/2` does when it draws
  # it; every value when it declares nothing. Read by name, so a declaration no compiled module
  # has made an atom of yet — a kit just installed — is read the same.
  defp taken?([], _key, _value), do: true

  defp taken?(attrs, key, value) do
    Enum.any?(attrs, fn attr ->
      castable?(attr) and Inspector.name(attr) == key and match?({:ok, _}, cast_attr(attr, value))
    end)
  end

  defp class_key?(key), do: key == "class" or String.ends_with?(key, "_class")

  # A VALUE THAT IS NOTHING BUT UTILITIES IS READ, WHATEVER ATTRIBUTE HOLDS IT, as Tailwind reads
  # every word of a template. A kit takes classes in attributes that declare no list at all — a
  # skeleton's `height="h-16"`, a content item's `font_weight="font-thin"`, a tab slot's
  # `badge_size="size-[19px]"`, a dropdown's `relative="md:relative"` — and they drew nothing. A
  # token counts when it has a `-`, `:` or `[` and is no icon (`icons/1` carries those), so a title,
  # a label or `extra_large` stays out.
  defp utilities?(value) do
    case String.split(value) do
      [] -> false
      tokens -> Enum.all?(tokens, &utility?/1)
    end
  end

  defp utility?(token) do
    class?(token) and String.contains?(token, ["-", ":", "["]) and not Icons.known?(token)
  end

  @doc """
  Whether `token` could be a class: at most 512 bytes — an arbitrary value such as
  `mask-linear-[to_bottom,transparent_0,black_min(40px,var(--edge)),…]` runs past a hundred —
  printable ASCII holding a letter, its brackets and parentheses balanced, and none of `"`, `\\`,
  `{`, `}`, `<`, `;` or a backtick in it.

      class?("bg-[#282828]")
      #=> true
      class?("{brace}")
      #=> false
  """
  @spec class?(term()) :: boolean()
  def class?(token) when is_binary(token) do
    byte_size(token) <= @class_length and Regex.match?(@class_token, token) and
      Regex.match?(~r/[A-Za-z]/, token) and balanced?(token, ?[, ?]) and
      balanced?(token, ?(, ?))
  end

  def class?(_token), do: false

  defp balanced?(token, open, close), do: count(token, open) == count(token, close)

  defp count(token, char), do: for(<<byte <- token>>, byte == char, reduce: 0, do: (n -> n + 1))

  defp open_names(attrs) do
    for attr <- attrs || [],
        name = Inspector.name(attr),
        is_binary(name),
        type(attr) in ["string", "any"],
        opts = Inspector.opts(attr),
        match?([_ | _], opts["examples"]),
        not match?([_ | _], opts["values"]),
        do: name
  end

  ####################################################################################
  ############################ (▰˘◡˘▰) Writing (▰˘◡˘▰) ###############################
  ####################################################################################

  defp written_value(value) when is_binary(value), do: String.trim(value)
  defp written_value(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp written_value(_not_a_value), do: ""

  # THE CONTENT IS HTML, so `&`, `<` and `>` are written as entities — a `<` would be read as a tag,
  # by this parser and by the sanitizer the content is saved through. A quote cannot be: the
  # sanitizer turns its entity back into the quote, so the other quote delimits the value instead.
  defp written_attr({key, value}) do
    value =
      value
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

    cond do
      not String.contains?(value, "\"") -> ~s(#{key}="#{value}")
      not String.contains?(value, "'") -> ~s(#{key}='#{value}')
      true -> ~s(#{key}="#{String.replace(value, "\"", "'")}")
    end
  end

  defp written_marker({open, _close}, name, attrs, nil),
    do: Enum.join([open, name | attrs] ++ ["/]]"], " ")

  defp written_marker({open, close}, name, attrs, inner),
    do: Enum.join([open, name | attrs], " ") <> "]]" <> inner <> close

  defp written_parts(parts) when is_list(parts) do
    Enum.reduce_while(parts, "", fn part, written ->
      case written_part(part) do
        text when is_binary(text) -> {:cont, written <> text}
        nil -> {:halt, nil}
      end
    end)
  end

  defp written_parts(_parts), do: nil

  defp written_part({:text, text}) when is_binary(text), do: text
  defp written_part({:component, tree}), do: write(tree)

  defp written_part({:slot, %{name: name, attrs: attrs, parts: parts}}) do
    case written_parts(parts) do
      inner when is_binary(inner) -> slot_marker(name, attrs, inner)
      nil -> nil
    end
  end

  defp written_part(_part), do: nil

  # The pieces of one marker's inner content, as `read/1` hands them out; content past `@depth` is
  # text.
  defp tree_of(%{name: name, attrs: attrs, inner: inner}, level),
    do: %{name: name, attrs: attrs, parts: tree_parts(inner, level)}

  # A slot's own content holds components and no slots of its own, as it is drawn.
  defp tree_parts(inner, level, read \\ &inside/1)
  defp tree_parts(nil, _level, _read), do: []
  defp tree_parts(inner, level, _read) when level >= @depth, do: [{:text, inner}]

  defp tree_parts(inner, level, read) do
    Enum.map(read.(inner), fn
      {:html, html} ->
        {:text, html}

      {:component, marker} ->
        {:component, tree_of(marker, level + 1)}

      {:slot, slot} ->
        {:slot,
         %{name: slot.name, attrs: slot.attrs, parts: tree_parts(slot.inner, level + 1, &parse/1)}}
    end)
  end

  defp key?(key),
    do: Regex.match?(@key, key) and key not in @reserved and not String.starts_with?(key, "phx")

  defp blank_to_nil(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      _text -> text
    end
  end

  defp blank_to_nil(_text), do: nil

  ####################################################################################
  ############################ (▰˘◡˘▰) Parsing (▰˘◡˘▰) ###############################
  ####################################################################################

  # Every marker in the text of `html` that is outside `<pre>` and `<code>`, as
  # `{start, stop, token}` byte offsets in order.
  #
  # THE FOUR MARKERS ARE COMPILED ONCE A PARSE. `:binary.matches/2` handed a list compiles it on
  # every call, and there is a text run between every two tags: a page of 23 000 tags spent two
  # thirds of its parse compiling the same pattern.
  defp tokens(html) do
    markers = :binary.compile_pattern([@open, @close, @slot_open, @slot_close])
    html |> text_runs() |> Enum.flat_map(&run_tokens(html, &1, markers))
  end

  defp text_runs(html) do
    {runs, position, depth} =
      @tag
      |> Regex.scan(html, return: :index)
      |> Enum.reduce({[], 0, 0}, fn [{at, length}, {_slash_at, slash}, {name_at, name_length}],
                                    {runs, position, depth} ->
        runs = run(runs, position, at, depth)
        name = html |> binary_part(name_at, name_length) |> String.downcase()
        tag = binary_part(html, at, length)

        {runs, at + length, code_depth(name, slash, tag, depth)}
      end)

    runs |> run(position, byte_size(html), depth) |> Enum.reverse()
  end

  defp run(runs, from, to, 0) when to > from, do: [{from, to - from} | runs]
  defp run(runs, _from, _to, _depth), do: runs

  defp code_depth(name, 0, tag, depth) when name in ["pre", "code"] do
    case String.ends_with?(tag, "/>") do
      true -> depth
      false -> depth + 1
    end
  end

  defp code_depth(name, _closing, _tag, depth) when name in ["pre", "code"], do: max(depth - 1, 0)
  defp code_depth(_name, _slash, _tag, depth), do: depth

  defp run_tokens(html, {offset, length}, markers) do
    text = binary_part(html, offset, length)

    text
    |> :binary.matches(markers)
    |> Enum.reduce({[], 0}, fn {at, size}, {found, consumed} ->
      case at < consumed do
        true -> {found, consumed}
        false -> token(text, offset, at, size, found, consumed)
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp token(text, offset, at, size, found, consumed) do
    case binary_part(text, at, size) do
      @close ->
        {[{offset + at, offset + at + size, {:close, :component}} | found], at + size}

      @slot_close ->
        {[{offset + at, offset + at + size, {:close, :slot}} | found], at + size}

      opener ->
        of = (opener == @open && :component) || :slot
        rest = binary_part(text, at + size, byte_size(text) - at - size)

        case opening(rest) do
          {:ok, kind, name, attrs, used} ->
            stop = at + size + used
            {[{offset + at, offset + stop, {kind, of, name, attrs}} | found], stop}

          :error ->
            {found, consumed}
        end
    end
  end

  defp opening(rest) do
    with {:ok, rest_after_space} <- required_space(rest),
         {:ok, name, after_name} <- name(rest_after_space),
         {:ok, kind, attrs, after_marker} <- attrs(after_name, []) do
      {:ok, kind, name, Map.new(attrs), byte_size(rest) - byte_size(after_marker)}
    end
  end

  defp required_space(text) do
    spaced = skip_space(text)

    case byte_size(spaced) < byte_size(text) do
      true -> {:ok, spaced}
      false -> :error
    end
  end

  defp skip_space(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r, ?\f], do: skip_space(rest)
  defp skip_space(<<0xC2, 0xA0, rest::binary>>), do: skip_space(rest)
  defp skip_space("&nbsp;" <> rest), do: skip_space(rest)
  defp skip_space("&#160;" <> rest), do: skip_space(rest)
  defp skip_space(rest), do: rest

  defp name(text) do
    case word(text, 0) do
      0 ->
        :error

      size ->
        <<name::binary-size(^size), rest::binary>> = text
        {:ok, name, rest}
    end
  end

  defp word(<<c, rest::binary>>, size)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?_, ?-],
       do: word(rest, size + 1)

  defp word(_rest, size), do: size

  defp attrs(text, found) do
    rest = skip_space(text)

    case rest do
      "]]" <> after_marker ->
        {:ok, :open, Enum.reverse(found), after_marker}

      "/]]" <> after_marker ->
        {:ok, :self, Enum.reverse(found), after_marker}

      _attribute when byte_size(rest) < byte_size(text) ->
        with {:ok, attr, after_attr} <- attr(rest), do: attrs(after_attr, [attr | found])

      _unseparated ->
        :error
    end
  end

  defp attr(text) do
    with {:ok, key, after_key} <- name(text),
         true <- Regex.match?(@key, key) do
      case skip_space(after_key) do
        "=" <> value ->
          with {:ok, value, rest} <- value(skip_space(value)), do: {:ok, {key, value}, rest}

        _bare ->
          {:ok, {key, true}, after_key}
      end
    else
      _not_a_key -> :error
    end
  end

  defp value(text) do
    case Enum.find(@quotes, fn {open, _close} -> String.starts_with?(text, open) end) do
      {open, close} ->
        quoted(binary_part(text, byte_size(open), byte_size(text) - byte_size(open)), close)

      nil ->
        bare(text)
    end
  end

  defp quoted(text, close) do
    case :binary.match(text, close) do
      {at, size} ->
        {:ok, decode(binary_part(text, 0, at)),
         binary_part(text, at + size, byte_size(text) - at - size)}

      :nomatch ->
        :error
    end
  end

  defp bare(text) do
    case bare_size(text, 0) do
      0 ->
        :error

      size ->
        <<value::binary-size(^size), rest::binary>> = text
        {:ok, decode(value), rest}
    end
  end

  defp bare_size("/]]" <> _rest, size), do: size

  defp bare_size(<<c, rest::binary>>, size)
       when c not in [?\s, ?\t, ?\n, ?\r, ?\f, ?], ?", ?'],
       do: bare_size(rest, size + 1)

  defp bare_size(_rest, size), do: size

  defp decode(value) do
    case :binary.match(value, "&") do
      :nomatch -> value
      _entity -> Regex.replace(@entity, value, &entity/2)
    end
  end

  defp entity(whole, "#x" <> hex), do: codepoint(whole, String.to_integer(hex, 16))
  defp entity(whole, "#X" <> hex), do: codepoint(whole, String.to_integer(hex, 16))
  defp entity(whole, "#" <> decimal), do: codepoint(whole, String.to_integer(decimal))
  defp entity(whole, name), do: Map.get(@entities, name, whole)

  defp codepoint(whole, codepoint) do
    case :unicode.characters_to_binary([codepoint]) do
      character when is_binary(character) -> character
      _not_a_character -> whole
    end
  end

  # THE MARKERS AS A TREE. An opening marker holds everything up to the closing marker of its own
  # kind that closes it; one nothing closes is text, and what it held belongs to the marker around
  # it. A closing marker with nothing of its kind open is text. Each node is
  # `%{from, to, start, stop, kind, name, attrs, inner, children}`: the bytes it is cut from (`from`,
  # `to`, its paragraph's once `unwrapped/2` takes it), the marker's own (`start`, `stop`), and its
  # inner content's (`inner`, `nil` for a self-closing one).
  defp tree(html), do: html |> tokens() |> Enum.reduce([{nil, []}], &nest/2) |> unwind()

  defp nest({start, stop, {:self, kind, name, attrs}}, [{open, children} | frames]),
    do: [{open, [node(start, stop, kind, name, attrs, nil, []) | children]} | frames]

  defp nest({_start, _stop, {:open, _kind, _name, _attrs}} = open, frames),
    do: [{open, []} | frames]

  defp nest({start, stop, {:close, kind}}, frames) do
    case Enum.split_while(frames, &(not open?(&1, kind))) do
      {_above, []} ->
        frames

      {above, [{{open_start, open_stop, {:open, kind, name, attrs}}, children} | below]} ->
        held = Enum.reverse(promoted(above) ++ children)
        closed = node(open_start, stop, kind, name, attrs, {open_stop, start}, held)
        [{parent, siblings} | rest] = below

        [{parent, [closed | siblings]} | rest]
    end
  end

  defp open?({{_start, _stop, {:open, kind, _name, _attrs}}, _children}, kind), do: true
  defp open?(_frame, _kind), do: false

  # What markers left open held, newest first, for the marker around them.
  defp promoted(frames), do: Enum.flat_map(frames, fn {_open, children} -> children end)

  defp unwind(frames), do: frames |> promoted() |> Enum.reverse()

  defp node(start, stop, kind, name, attrs, inner, children) do
    %{
      from: start,
      to: stop,
      start: start,
      stop: stop,
      kind: kind,
      name: name,
      attrs: attrs,
      inner: inner,
      children: children
    }
  end

  # The outermost component markers. A slot marker outside any component is text, and the
  # components inside it are outermost themselves.
  defp outermost(html), do: html |> tree() |> components()

  defp components(nodes) do
    Enum.flat_map(nodes, fn
      %{kind: :component} = node -> [node]
      %{kind: :slot, children: children} -> components(children)
    end)
  end

  defp named(nodes, found) do
    Enum.reduce(nodes, found, fn
      %{kind: :component, name: name, children: children}, found ->
        named(children, [name | found])

      %{children: children}, found ->
        named(children, found)
    end)
  end

  # One component's inner content: the HTML drawn as it is, the components inside it, and its slot
  # entries — a slot marker belongs to the component it sits directly inside.
  defp inside(inner) do
    case :binary.match(inner, [@open, @slot_open]) do
      :nomatch -> [{:html, inner}]
      _found -> inner |> tree() |> Enum.map(&unwrapped(&1, inner)) |> chunks(inner)
    end
  end

  # A PARAGRAPH HOLDING ONLY THIS MARKER is taken with it, so the component is not drawn inside a
  # `<p>` — which a block element cannot be. Only the few bytes either side are read.
  defp unwrapped(%{start: start, stop: stop} = node, html) do
    from = max(start - @paragraph_reach, 0)
    before = binary_part(html, from, start - from)
    after_marker = binary_part(html, stop, min(@paragraph_reach, byte_size(html) - stop))

    with [{opens_at, _length}] <- Regex.run(@paragraph_open, before, return: :index),
         [{0, closes}] <- Regex.run(@paragraph_close, after_marker, return: :index) do
      %{node | from: from + opens_at, to: stop + closes}
    else
      _shares_its_paragraph -> node
    end
  end

  defp chunks(nodes, html) do
    {pieces, position, _counts} =
      Enum.reduce(nodes, {[], 0, %{component: 0, slot: 0}}, fn node, {pieces, position, counts} ->
        marker = %{
          name: node.name,
          attrs: node.attrs,
          inner: inner_html(html, node.inner),
          index: Map.fetch!(counts, node.kind)
        }

        {[{node.kind, marker} | html_piece(pieces, html, position, node.from)], node.to,
         Map.update!(counts, node.kind, &(&1 + 1))}
      end)

    pieces |> html_piece(html, position, byte_size(html)) |> Enum.reverse()
  end

  # A marker the editor holds as a block. Nothing for one sharing its paragraph.
  defp standing(%{start: start, stop: stop} = node, html) do
    case unwrapped(node, html) do
      %{from: ^start, to: ^stop} -> top_level(node, html)
      wrapped -> [wrapped]
    end
  end

  defp top_level(%{start: start} = node, html) do
    case depth(binary_part(html, 0, start)) do
      0 -> [node]
      _inside_an_element -> []
    end
  end

  # How many elements are open at the end of `html`.
  defp depth(html) do
    @tag
    |> Regex.scan(html)
    |> Enum.reduce(0, fn [tag, slash, name], depth ->
      cond do
        String.downcase(name) in @void or String.ends_with?(tag, "/>") -> depth
        slash == "/" -> max(depth - 1, 0)
        true -> depth + 1
      end
    end)
  end

  defp pieces(standing, html) do
    {pieces, position} =
      Enum.reduce(standing, {[], 0}, fn node, {pieces, position} ->
        segment = %{
          name: node.name,
          attrs: node.attrs,
          inner: inner_html(html, node.inner),
          marker: binary_part(html, node.start, node.stop - node.start),
          source: binary_part(html, node.from, node.to - node.from)
        }

        {[{:component, segment} | html_piece(pieces, html, position, node.from)], node.to}
      end)

    pieces |> html_piece(html, position, byte_size(html)) |> Enum.reverse()
  end

  defp html_piece(pieces, html, from, to) when to > from,
    do: [{:html, binary_part(html, from, to - from)} | pieces]

  defp html_piece(pieces, _html, _from, _to), do: pieces

  defp inner_html(_html, nil), do: nil
  defp inner_html(_html, {from, to}) when to == from, do: nil
  defp inner_html(html, {from, to}), do: binary_part(html, from, to - from)
end
