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
  page can show the syntax. A marker that does not parse, an opening marker with another marker
  before its closing one, and a closing marker nothing opened are left in the text as they are —
  markers do not nest.

  A paragraph holding one marker and nothing else — whitespace and non-breaking spaces aside — is
  drawn as the component alone, without the `<p>` an editor wraps a line in: a block inside a `<p>`
  is HTML a browser takes apart. A marker sharing its paragraph with other text keeps it.

  ## What is drawn

  Only a component the request's site may render: active, and the site's own or a global one — the
  rule `MishkaCmsCore.Runtime.LiveViewHelpers.component/1` holds every template to. The name is
  first checked, as a string, against the active components `SiteState` knows the site and the
  global scope have: a name an author typed that names none of them makes no module name, no atom
  and no remembered failure. A name that resolves to nothing, an inactive component, another site's,
  one that draws content itself (it could draw the content that holds it, forever), and one missing
  an attribute it requires are drawn as nothing. The same render in a preview (`MishkaCmsCore.Runtime.StaticHelpers`) draws a
  notice saying why in their place.

  Only the attributes the component declares are passed, each cast to its declared type: `string`
  and `any` as written, `boolean` from `true`/`false` or a bare key, `integer` and `float` from a
  number, and anything that declares `values` only as one of them — which is the only way an `atom`
  is taken. `id`, `site`, `component_name`, `current_user`, `rest` and any `phx-` name are never an
  author's. A stateful component gets the id `"<id>-<n>"`, `n` counting the content's markers from
  0, so it stays the same component across renders.

  The HTML around the markers is drawn as it is given: pass only HTML that was sanitized.

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

  ## Events

    * `runtime:render:before_content_component` — before each embedded component is drawn, with
      `%{component_name: name, site: site, attrs: attrs, inner: inner_html | nil}` and
      `%{site_id: site_id, index: n}` as meta. `attrs` is atom-keyed and already cast. A plugin
      answers the map with other `attrs` or `inner` to change what is drawn, or with
      `suppress: true` set to draw nothing.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  import Phoenix.Component, only: [sigil_H: 2]

  require Ash.Query

  alias MishkaCmsCore.Runtime.{Component, LiveViewHelpers, Translations}
  alias MishkaCmsCore.Runtime.PageBuilder.Inspector
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaInstaller.Event.Hook

  @event "runtime:render:before_content_component"

  @open "[[component"
  @close "[[/component]]"

  @reserved ~w(id site component_name runtime_slot current_user inner_block rest)

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

  @typedoc "One marker, as `parse/1` found it."
  @type marker :: %{
          name: String.t(),
          attrs: %{String.t() => String.t() | true},
          inner: String.t() | nil,
          index: non_neg_integer()
        }

  @typedoc "A piece of content: HTML drawn as it is, or a marker."
  @type chunk :: {:html, String.t()} | {:component, marker()}

  @typedoc "A component an author may embed, as `embeddable/2` lists it."
  @type entry :: %{
          name: String.t(),
          description: String.t() | nil,
          type: String.t() | nil,
          stateful: boolean(),
          global: boolean(),
          inner_block: boolean(),
          attrs: [
            %{
              name: String.t(),
              type: String.t(),
              values: [term()],
              default: term(),
              doc: String.t() | nil,
              required: boolean()
            }
          ]
        }

  @doc """
  Splits `html` into the HTML drawn as it is and the markers in it, in order.

      parse(~s(<p>Hi</p>[[component chelekom-badge size="small" /]]))
      #=> [
      #=>   {:html, "<p>Hi</p>"},
      #=>   {:component, %{name: "chelekom-badge", attrs: %{"size" => "small"}, inner: nil, index: 0}}
      #=> ]

  Content with no `[[component` in it is one `{:html, html}`, found with a single binary match.
  """
  @spec parse(String.t()) :: [chunk()]
  def parse(html) when is_binary(html) do
    case :binary.match(html, @open) do
      :nomatch -> [{:html, html}]
      _found -> html |> tokens() |> pair([]) |> Enum.map(&unwrapped(&1, html)) |> chunks(html)
    end
  end

  @doc """
  The component names the markers in `html` name, each once, in the order they first appear — what
  a resource stores beside its content when it is written, for the site's stylesheet.

      names(~s([[component chelekom-alert /]]<p>x</p>[[component chelekom-alert]]y[[/component]]))
      #=> ["chelekom-alert"]
  """
  @spec names(String.t() | nil) :: [String.t()]
  def names(html) when is_binary(html),
    do: for({:component, %{name: name}} <- parse(html), uniq: true, do: name)

  def names(_html), do: []

  @doc """
  The attributes of `given` a component declaring `declared` takes, cast to their declared types.

  `declared` is the component's attribute declarations, as `__component_information__/1` or the
  row holds them; `given` is a marker's `attrs`. What is not declared, cannot be cast, or is one of
  the names an author never sets is left out.

      cast([%{name: "count", type: "integer"}, %{name: "open", type: "boolean"}],
           %{"count" => "3", "open" => true, "phx-click" => "boom"})
      #=> %{count: 3, open: true}
  """
  @spec cast([map()], %{String.t() => String.t() | true}) :: %{atom() => term()}
  def cast(declared, given) when is_list(declared) and is_map(given) do
    for attr <- declared,
        castable?(attr),
        name = Inspector.name(attr),
        Map.has_key?(given, name),
        {:ok, value} <- [cast_value(type(attr), Map.fetch!(given, name), values(attr))],
        into: %{},
        do: {String.to_existing_atom(name), value}
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
  def marker(name, attrs, inner) when is_binary(name) and (is_map(attrs) or is_nil(attrs)) do
    written =
      (attrs || %{})
      |> Enum.map(fn {key, value} -> {to_string(key), written_value(value)} end)
      |> Enum.reject(fn {_key, value} -> value == "" end)
      |> Enum.sort()

    case Regex.match?(@name, name) and Enum.all?(written, fn {key, _} -> key?(key) end) do
      true -> written_marker(name, Enum.map(written, &written_attr/1), blank_to_nil(inner))
      false -> nil
    end
  end

  def marker(_name, _attrs, _inner), do: nil

  @doc """
  `content` with `marker` written after it, on a line of its own.
  """
  @spec append(String.t() | nil, String.t()) :: String.t()
  def append(content, marker) when content in [nil, ""], do: marker

  def append(content, marker) do
    case String.ends_with?(content, "\n") do
      true -> content <> marker
      false -> content <> "\n" <> marker
    end
  end

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

  Active components of the site and global ones, read as `actor` through
  `:for_tenant_with_globals`; a site's own component hides the global one of the same name, as it
  does when drawn. Components that draw content themselves are left out, and so is every attribute
  `cast/2` would drop.
  """
  @spec embeddable(map() | nil, String.t() | nil) :: {:ok, [entry()]} | {:error, term()}
  def embeddable(actor, site_id) do
    {arguments, tenant} = scope(actor, site_id)

    Component
    |> Ash.Query.for_read(:for_tenant_with_globals, arguments, actor: actor, tenant: tenant)
    |> Ash.Query.filter(active == true and not contains(template, "rich_content"))
    |> within(site_id)
    |> Ash.Query.select([:id, :name, :description, :type, :stateful, :attrs, :slots, :site_id])
    |> Ash.Query.sort(name: :asc)
    |> Ash.read(page: [limit: 1000])
    |> case do
      {:ok, %{results: rows}} -> {:ok, rows |> own_first() |> Enum.map(&entry/1)}
      {:ok, rows} when is_list(rows) -> {:ok, rows |> own_first() |> Enum.map(&entry/1)}
      {:error, _reason} = error -> error
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

  defp entry(row) do
    %{
      name: row.name,
      description: row.description,
      type: row.type,
      stateful: row.stateful == true,
      global: is_nil(row.site_id),
      inner_block: Enum.any?(row.slots || [], &Inspector.inner_block?/1),
      attrs:
        for attr <- row.attrs || [], castable?(attr) do
          %{
            name: Inspector.name(attr),
            type: type(attr),
            values: values(attr),
            default: Inspector.default(attr),
            doc: Inspector.doc(attr),
            required: Inspector.required?(attr)
          }
        end
    }
  end

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
      current_user: assigns[:current_user]
    }

    assigns = %{parts: Enum.map(parse(html), &part(&1, context, mode))}

    # NOT FORMATTED, because the formatter would put each part on a line of its own, and the
    # whitespace between them would be drawn into the content.
    ~H"<%= for part <- @parts do %>{part}<% end %>"noformat
  end

  def draw(_assigns, _mode) do
    assigns = %{}
    ~H""
  end

  defp part({:html, html}, _context, _mode), do: Phoenix.HTML.raw(html)

  defp part({:component, marker}, context, mode) do
    with {:ok, module, site} <- reach(marker.name, context.site),
         :ok <- placeable(module),
         declared = declared_attrs(module),
         {:ok, attrs, inner} <- before_draw(marker, site, cast(declared, marker.attrs)),
         :ok <- required(declared, attrs) do
      module
      |> component_assigns(marker, site, attrs, inner, context)
      |> drawn(mode)
    else
      :refused -> nil
      reason -> unavailable(marker.name, reason, mode)
    end
  end

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

  defp declared_attrs(module),
    do: List.wrap(module.__component_information__([:component, :attrs]))

  defp before_draw(marker, site, attrs) do
    data = %{component_name: marker.name, site: site, attrs: attrs, inner: marker.inner}

    case Hook.call(@event, data, meta: %{site_id: Translations.site(), index: marker.index}) do
      %{suppress: true} -> :refused
      %{attrs: %{} = changed} = answer -> {:ok, changed, Map.get(answer, :inner, marker.inner)}
      _unchanged -> {:ok, attrs, marker.inner}
    end
  end

  defp required(declared, attrs) do
    missing =
      for attr <- declared,
          Inspector.required?(attr),
          name = Inspector.name(attr),
          name not in @reserved,
          not Map.has_key?(attrs, String.to_existing_atom(name)),
          do: name

    case missing do
      [] -> :ok
      names -> {:missing, names}
    end
  end

  defp component_assigns(module, marker, site, attrs, inner, context) do
    information = module.__component_information__()
    declared = Enum.map(information.component.attrs || [], &Inspector.name/1)

    attrs
    |> Map.merge(%{component_name: marker.name, site: site, __changed__: nil})
    |> inner_block(Enum.any?(information.component.slots || [], &Inspector.inner_block?/1), inner)
    |> stateful_id(information.private[:stateful] == true, "#{context.prefix}-#{marker.index}")
    |> visitor("current_user" in declared, context.current_user)
  end

  defp inner_block(assigns, false, _inner), do: assigns
  defp inner_block(assigns, true, nil), do: Map.put(assigns, :inner_block, [])

  defp inner_block(assigns, true, inner) do
    Map.put(assigns, :inner_block, [
      %{
        __slot__: :inner_block,
        inner_block: fn _changed, _argument -> Phoenix.HTML.raw(inner) end
      }
    ])
  end

  defp stateful_id(assigns, true, id), do: Map.put(assigns, :id, id)
  defp stateful_id(assigns, false, _id), do: assigns

  defp visitor(assigns, true, user) when not is_nil(user),
    do: Map.put(assigns, :current_user, user)

  defp visitor(assigns, _declared, _user), do: assigns

  defp drawn(assigns, :live), do: LiveViewHelpers.component(assigns)
  defp drawn(assigns, :static), do: LiveViewHelpers.static_component(assigns)

  defp unavailable(_name, _reason, :live), do: nil

  defp unavailable(name, reason, :static) do
    assigns = %{message: unavailable_message(name, reason)}

    ~H"""
    <span
      data-role="content-component-unavailable"
      class="inline-block rounded border border-red-300 px-2 py-1 text-sm text-red-600"
    >
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

  defp unavailable_message(name, _unavailable),
    do:
      gettext("%{name} is not a component this site can show, so visitors see nothing here.",
        name: name
      )

  ####################################################################################
  ############################ (▰˘◡˘▰) Casting (▰˘◡˘▰) ###############################
  ####################################################################################

  defp castable?(attr) do
    name = Inspector.name(attr)

    is_binary(name) and name not in @reserved and not String.starts_with?(name, "phx") and
      castable_type?(type(attr), values(attr))
  end

  defp type(attr), do: attr |> Inspector.type() |> to_string()

  defp castable_type?(type, _values) when type in ~w(string any boolean integer float), do: true
  defp castable_type?("atom", [_ | _]), do: true
  defp castable_type?(_type, _values), do: false

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

  defp written_marker(name, attrs, nil), do: Enum.join([@open, name | attrs] ++ ["/]]"], " ")

  defp written_marker(name, attrs, inner),
    do: Enum.join([@open, name | attrs], " ") <> "]]" <> inner <> @close

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
  defp tokens(html), do: html |> text_runs() |> Enum.flat_map(&run_tokens(html, &1))

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

  defp run_tokens(html, {offset, length}) do
    text = binary_part(html, offset, length)

    text
    |> :binary.matches([@open, @close])
    |> Enum.reduce({[], 0}, fn {at, size}, {found, consumed} ->
      cond do
        at < consumed ->
          {found, consumed}

        size == byte_size(@close) ->
          {[{offset + at, offset + at + size, :close} | found], at + size}

        true ->
          rest = binary_part(text, at + size, byte_size(text) - at - size)

          case opening(rest) do
            {:ok, kind, name, attrs, used} ->
              stop = at + size + used
              {[{offset + at, offset + stop, {kind, name, attrs}} | found], stop}

            :error ->
              {found, consumed}
          end
      end
    end)
    |> elem(0)
    |> Enum.reverse()
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

  # An opening marker pairs with the closing one right after it; anything else between them, or a
  # closing marker with nothing open, stays text.
  defp pair(
         [{start, open_stop, {:open, name, attrs}}, {close_start, stop, :close} | rest],
         found
       ),
       do: pair(rest, [{start, stop, name, attrs, {open_stop, close_start}} | found])

  defp pair([{start, stop, {:self, name, attrs}} | rest], found),
    do: pair(rest, [{start, stop, name, attrs, nil} | found])

  defp pair([_unpaired | rest], found), do: pair(rest, found)
  defp pair([], found), do: Enum.reverse(found)

  # A PARAGRAPH HOLDING ONLY THIS MARKER is taken with it, so the component is not drawn inside a
  # `<p>` — which a block element cannot be. Only the few bytes either side are read.
  defp unwrapped({start, stop, name, attrs, inner} = marker, html) do
    from = max(start - @paragraph_reach, 0)
    before = binary_part(html, from, start - from)
    after_marker = binary_part(html, stop, min(@paragraph_reach, byte_size(html) - stop))

    with [{opens_at, _length}] <- Regex.run(@paragraph_open, before, return: :index),
         [{0, closes}] <- Regex.run(@paragraph_close, after_marker, return: :index) do
      {from + opens_at, stop + closes, name, attrs, inner}
    else
      _shares_its_paragraph -> marker
    end
  end

  defp chunks(markers, html) do
    {pieces, position, _index} =
      Enum.reduce(markers, {[], 0, 0}, fn {start, stop, name, attrs, inner},
                                          {pieces, position, index} ->
        marker = %{name: name, attrs: attrs, inner: inner_html(html, inner), index: index}

        {[{:component, marker} | html_piece(pieces, html, position, start)], stop, index + 1}
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
