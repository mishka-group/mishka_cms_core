defmodule MishkaCmsCore.Runtime.PageBuilder.PageForms do
  @moduledoc """
  What can be learned about a page's forms by parsing the page's own template.

  The answer is what `__page_forms__/0` carries into the compiled page, so everything the runtime
  needs — the page assign, the param name, the DOM id, both event names, the success message and
  every field with its key, its type and its rules — is read out of the markup the author already
  wrote. There is no second place to declare any of it and therefore nothing that can drift.

  ## What declares a form

  A node carrying `for={assigns[:something]}`. That is `Phoenix.Component.form/1`'s own attribute
  name and the one a third-party wrapper forwards (`chelekom-form-wrapper` renders
  `<.form :let={f} for={@for} as={@as} id={@id}>`), so nothing here reads a component name, a role or
  a database row. A form that names no page assign, or no param name with `as`, declares no spec at
  all: the compiler generates nothing for it and the audit rail is where the author is told.

  ## What declares a field

  Any attribute of any descendant whose expression is `<letvar>[:key]`, where `<letvar>` is the name
  the form node bound with `:let`. `field={f[:email]}`, `bind={f[:email]}` and a hand-written
  `value={f[:email].value}` are all the same fact, and the key is authored in exactly one place —
  there is no parallel `data-field` marker to drift from it.

  A plain `<input name="email">` inside the form falls back to its `name`. That fallback is limited
  to HTML's own value-carrying controls (`input`, `select`, `textarea`, and not the `input` types
  that submit rather than carry), because `name` is an ordinary attribute on everything else: an
  icon written `<.icon name="hero-user" />` inside a form is not a field, and reading `name` off any
  node at all would put one in the spec.

  ## Which form a field belongs to

  Its nearest one. Walking every descendant of a form would give an outer form the inner one's
  fields the moment a nested form arrives — through the code drawer, a paste or an import, since the
  editor itself refuses to nest one — and the outer form would then validate and clear keys that are
  not its own.

  ## What declares a rule

  The HTML constraint attributes already on the field node: `required`, `minlength`, `maxlength`,
  `min`, `max`, `pattern`, plus `data-format` and `data-confirms` for the two things HTML has no word
  for. One declaration that the browser enforces and the server re-checks.

  ## Why the spec's keys are atoms, and why the editor never asks for them

  A spec is built once per compile, from a template the site's own author saved, and its keys are
  handed to `Ecto.Changeset.cast/4` and to `Phoenix.Component.assign/3` — both of which want atoms.
  `declared/1`, `read/1`, `spec/2` and `fields/2` are that half, and `control_key/1` is the one place
  a `name=` attribute is interned.

  The editor is the opposite case and asks `names/2` and `field_name/2`, which answer the same fact
  in binaries. It matters because the editor asks on every pass of the audit rail and on every drop,
  from a `name=` an author is still typing: `FormChecks.findings/3` is recomputed while the rail is
  the open tab, so an atom per intermediate value — `e`, `em`, `ema`, `emai`, `email` — was interned
  permanently from an unbounded source, and `Naming.field_key/2`, the only consumer, compared them
  as text anyway. `MishkaCmsCore.Runtime.PageBuilder.PageForms.Naming` says the same thing from the
  other side: minting an atom per label typed into a text box leaks the atom table for no gain.

  Read-only. `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler` still compiles the stored template
  byte for byte, and nothing here rewrites what is published.

  See also `MishkaCmsCore.Runtime.PageForm.Rules`, which executes the rules this module lifts, and
  `MishkaCmsCore.Runtime.PageBuilder.PageForms.FormPlacement`, which writes the bindings it reads.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.Naming
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node

  @controls ~w(input select textarea)

  @submitters ~w(submit reset button image)

  @sends ~w(submit image)

  @success gettext_noop("Sent. Thank you.")

  # Written on a form that works as visitors type, with no Send button.
  @as_typed "data-sends-as-typed"

  @doc """
  Every form this template declares, as the specs `__page_forms__/0` carries, in document order.

  An unparseable template answers `[]`. A compile must not fail because one page's markup is broken,
  and the audit rail is where a broken document is reported; `read/1` is the same question for a
  caller that wants the parse error itself.
  """
  @spec declared(String.t() | nil) :: [map()]
  def declared(template), do: template |> read() |> forms()

  defp forms({:ok, specs}), do: specs
  defp forms({:error, _unparseable}), do: []

  @doc """
  Every form this template declares, or the parse error that stopped the reading.

  `{:error, %{line:, column:, message:}}` is `MishkaCmsCore.Runtime.PageBuilder.Tree.parse/1`'s own
  answer, passed through so the caller can say where the document broke.
  """
  @spec read(String.t() | nil) :: {:ok, [map()]} | {:error, map()}
  def read(template), do: template |> Tree.parse() |> specs()

  defp specs({:ok, tree}), do: {:ok, tree |> Tree.walk() |> Enum.flat_map(&spec(tree, &1))}
  defp specs({:error, error}), do: {:error, error}

  @doc """
  The spec this node declares, as a list of nothing or one, so it composes with a walk.

  Both the page assign and the param name are required. A form missing either is not half-compiled
  into a page that answers some events and not others.
  """
  @spec spec(Tree.t(), Node.t()) :: [map()]
  def spec(tree, node), do: assemble(tree, node, source_assign(node), param_name(node))

  defp assemble(tree, node, assign, as)
       when is_atom(assign) and not is_nil(assign) and is_binary(as) do
    [
      %{
        assign: assign,
        as: as,
        id: Node.attr_text(node, "id") || as <> "-form",
        change: Node.attr_text(node, "phx-change"),
        submit: Node.attr_text(node, "phx-submit"),
        success: Node.attr_text(node, "data-success") || @success,
        trigger: node |> sends_elsewhere?() |> sent_trigger(node),
        fields: fields(tree, node)
      }
    ]
  end

  defp assemble(_tree, _node, _assign, _as), do: []

  # A trigger with no address to post to is never set.
  defp sent_trigger(true, node), do: trigger_assign(node)
  defp sent_trigger(false, _node), do: nil

  @doc "Whether this node is a form — the one question the rest of the editor asks about a node."
  @spec form?(Node.t()) :: boolean()
  def form?(node), do: source_assign(node) != nil

  @doc "The attribute that records a form working as visitors type, with no Send button."
  @spec as_typed_attr() :: String.t()
  def as_typed_attr, do: @as_typed

  @doc "Whether this form works as visitors type (it carries `as_typed_attr/0`)."
  @spec as_typed?(Node.t()) :: boolean()
  def as_typed?(node), do: Node.attr(node, @as_typed) != nil

  @doc """
  The page assign a form's `phx-trigger-action` reads (`assigns[:contact_send]` gives
  `:contact_send`), or `nil`. `MishkaCmsCore.Runtime.PageForm.submit/5` sets it on a valid submit, so
  the browser then posts the form to its `action`.
  """
  @spec trigger_assign(Node.t()) :: atom() | nil
  def trigger_assign(node), do: node |> Node.attr("phx-trigger-action") |> assign_key()

  @doc """
  The web address a form sends its answers to after they are checked (`sends_elsewhere?/1`), or
  `nil`.
  """
  @spec address(Node.t()) :: String.t() | nil
  def address(node), do: node |> sends_elsewhere?() |> sent_to(node)

  defp sent_to(true, node), do: node |> Node.attr_text("action") |> presence()
  defp sent_to(false, _node), do: nil

  @doc """
  Whether a form posts to another address once its answers are checked: it names an `action` and a
  `phx-trigger-action` the page sets.
  """
  @spec sends_elsewhere?(Node.t()) :: boolean()
  def sends_elsewhere?(node),
    do: trigger_assign(node) != nil and presence(Node.attr_text(node, "action")) != nil

  @doc """
  Every `phx-change` and `phx-submit` name the forms in `tree` carry, in document order: the
  `current` names `follow/2` renames stored handlers to.
  """
  @spec events(Tree.t()) :: [String.t()]
  def events(tree) do
    for node <- Tree.walk(tree),
        form?(node),
        attr <- ~w(phx-change phx-submit),
        name = Node.attr_text(node, attr),
        is_binary(name),
        do: name
  end

  @doc """
  Whether a stored handler answers `event`: one named exactly `event`, or one whose name carries the
  same token and kind (`Naming.same_event?/2`).

  `entries` are Events-tab entries (`%{name: _}` or `%{"name" => _}`) or bare names.
  """
  @spec answered?([map() | String.t()], String.t() | nil) :: boolean()
  def answered?(_entries, event) when event in [nil, ""], do: false

  def answered?(entries, event) when is_binary(event),
    do: Enum.any?(entries, &answers?(entry_name(&1), event))

  defp answers?(name, event), do: name == event or Naming.same_event?(name, event)

  @doc """
  A form's events as rows for the editor, On change first: `kind`, `event`, and `custom?` when a
  stored handler answers it (`answered?/2`). An event the form does not name has no row.
  """
  @spec handlers(Node.t(), [map() | String.t()]) :: [
          %{kind: :validate | :submit, event: String.t(), custom?: boolean()}
        ]
  def handlers(node, entries) do
    for {attr, kind} <- [{"phx-change", :validate}, {"phx-submit", :submit}],
        event = node |> Node.attr_text(attr) |> presence(),
        is_binary(event),
        do: %{kind: kind, event: event, custom?: answered?(entries, event)}
  end

  @doc """
  Every named form in `tree`, in document order: its `node_id`, the `name` a person reads
  (`Naming.label/1`) and its `handlers/2`. Read from the tree, so no field name becomes an atom.
  """
  @spec handler_forms(Tree.t(), [map() | String.t()]) :: [map()]
  def handler_forms(tree, entries) do
    for {node_id, seed} <- Naming.seeds(tree),
        node = Tree.get(tree, node_id),
        do: %{node_id: node_id, name: Naming.label(seed), handlers: handlers(node, entries)}
  end

  @doc "The row of `handler_forms/2` that names `event`, with its form's `node_id`, or `nil`."
  @spec handler_for(Tree.t(), [map() | String.t()], String.t() | nil) :: map() | nil
  def handler_for(tree, entries, event) do
    Enum.find_value(handler_forms(tree, entries), fn form ->
      form.handlers |> Enum.find(&(&1.event == event)) |> with_form(form)
    end)
  end

  defp with_form(nil, _form), do: nil
  defp with_form(row, form), do: Map.put(row, :node_id, form.node_id)

  @doc """
  The stored handlers, each renamed to the event its form answers to now.

  An entry follows when its name carries the token and kind of one of the `current` event names but
  is not that name, which is what a renamed form leaves behind. `retagged` maps an untagged name to
  the tagged name a rename gave its form (`MishkaCmsCore.Runtime.PageBuilder.Inspector.retagged/3`),
  and such an entry follows by that tagged name's token and kind; its code's quoted mentions of the
  untagged name move with it, since no form answers that name any more. An exact match, a name no
  current event shares a token with, and a rename that would give two entries one name are left as
  they are. Every other key of an entry is kept.
  """
  @spec follow([map() | String.t()], [String.t() | nil], %{String.t() => String.t()}) ::
          [map() | String.t()]
  def follow(entries, current, retagged \\ %{}) do
    current = Enum.filter(current, &is_binary/1)
    claimed = MapSet.new(entries, &entry_name/1)

    entries
    |> Enum.map_reduce(claimed, &followed(&1, &2, current, retagged))
    |> elem(0)
  end

  defp followed(entry, claimed, current, retagged) do
    name = entry_name(entry)

    name
    |> target(Map.get(retagged, name, name), current, claimed)
    |> moved(entry, claimed)
  end

  defp target(name, key, current, claimed) do
    with false <- name in current,
         found when is_binary(found) <- Enum.find(current, &Naming.same_event?(key, &1)),
         false <- MapSet.member?(claimed, found) do
      found
    else
      _stays -> nil
    end
  end

  defp moved(nil, entry, claimed), do: {entry, claimed}

  defp moved(name, entry, claimed),
    do: {entry |> renamed(name) |> requoted(entry_name(entry), name), MapSet.put(claimed, name)}

  defp renamed(%{name: _old} = entry, name), do: %{entry | name: name}
  defp renamed(%{"name" => _old} = entry, name), do: Map.put(entry, "name", name)
  defp renamed(old, name) when is_binary(old), do: name

  # An untagged name no form answers once its entry moves, so the entry's code quoting it takes the
  # new name; a tagged one still reaches its form by its token and is left as written.
  defp requoted(entry, old, name), do: old |> Naming.event_key() |> quoted_in(entry, old, name)

  defp quoted_in(nil, %{code: code} = entry, old, name) when is_binary(code),
    do: %{entry | code: String.replace(code, inspect(old), inspect(name))}

  defp quoted_in(nil, %{"code" => code} = entry, old, name) when is_binary(code),
    do: Map.put(entry, "code", String.replace(code, inspect(old), inspect(name)))

  defp quoted_in(_key, entry, _old, _name), do: entry

  defp entry_name(%{name: name}) when is_binary(name), do: name
  defp entry_name(%{"name" => name}) when is_binary(name), do: name
  defp entry_name(name) when is_binary(name), do: name
  defp entry_name(_entry), do: nil

  @doc """
  Whether this node is one of HTML's own value-carrying controls.

  `input`, `select` and `textarea` carry a value, and the `type` values that submit or reset carry
  none, read by `written_type/1` whatever their case. Nothing else is matched by name, and this
  module is the ONE place HTML's control and type words are written down:
  `MishkaCmsCore.Runtime.PageBuilder.Fields` asks it for the node question, for the markup half of
  a component's role and for what a button sends, and the fallback that reads a control's own `name`
  asks it here. It was stated four times, so adding HTML's `<output>` meant editing four files and
  missing one made the audit and the insert funnel disagree about what a field is.
  """
  @spec control?(Node.t()) :: boolean()
  def control?(%{kind: :tag, tag: tag} = node) when tag in @controls,
    do: not (node |> Node.attr("type") |> written_type() |> button_type?())

  def control?(_node), do: false

  @doc """
  The type an attribute value names, trimmed and lowercased as HTML reads it: a literal, or an
  expression that is only a literal (`{"submit"}`, or `{:submit}` as the Inspector writes an atom
  attribute). `nil` for an unset, bare, blank or computed value.

  Takes what `MishkaCmsCore.Runtime.PageBuilder.Tree.Node.attr/2` answers.
  """
  @spec written_type({:string, String.t()} | {:expr, String.t()} | :boolean | nil) ::
          String.t() | nil
  def written_type(value), do: value |> written_word() |> type_word()

  @doc "A type given as a string or an atom, trimmed and lowercased; `nil` for none."
  @spec type_word(term()) :: String.t() | nil
  def type_word(type) when is_binary(type), do: type |> String.downcase() |> presence()

  def type_word(type) when is_atom(type) and not is_boolean(type) and not is_nil(type),
    do: type |> Atom.to_string() |> type_word()

  def type_word(_other), do: nil

  @doc "Whether this type makes an `<input>` or a `<button>` a button, which carries no value."
  @spec button_type?(String.t() | nil) :: boolean()
  def button_type?(type), do: type in @submitters

  @doc "Whether this type sends the form the button is in: `submit` or `image`."
  @spec sending_type?(String.t() | nil) :: boolean()
  def sending_type?(type), do: type in @sends

  @doc "`assigns[:contact_form]` gives `:contact_form`; anything else gives `nil`."
  @spec source_assign(Node.t()) :: atom() | nil
  def source_assign(node), do: node |> Node.attr("for") |> assign_key()

  defp assign_key({:expr, source}), do: field_key_from(source, :assigns)
  defp assign_key(_other), do: nil

  @doc ~S(`as={:contact}` or `as="contact"` gives `"contact"`.)
  @spec param_name(Node.t()) :: String.t() | nil
  def param_name(node), do: node |> Node.attr("as") |> written_word()

  defp written_word({:string, value}), do: presence(value)
  defp written_word({:expr, source}), do: literal_atom(source)
  defp written_word(_absent), do: nil

  @doc "The `:let` variable a form binds, as an atom, or `nil` when it binds none."
  @spec let_var(Node.t()) :: atom() | nil
  def let_var(node), do: node |> Node.attr(":let") |> variable()

  defp variable({:expr, source}), do: source |> String.trim() |> Code.string_to_quoted() |> var()
  defp variable(_absent), do: nil

  defp var({:ok, {name, _meta, nil}}) when is_atom(name), do: name
  defp var(_other), do: nil

  @doc """
  Every field the form at `node` owns, in document order and one entry per key.

  A key bound twice is one field: the label and the input of the same control both carry it, and the
  form has one value for it either way.
  """
  @spec fields(Tree.t(), Node.t()) :: [map()]
  def fields(tree, node), do: collect(tree, node, let_var(node))

  @doc """
  The names already bound inside the form at `node`, as TEXT, in document order and one per name.

  What a newly minted key is measured against, and the answer the editor takes. `fields/2` is the
  compile-time half and interns each name; this one never does, because it is asked on every drop and
  on every pass of the audit rail from a `name=` the author has not finished typing.
  `MishkaCmsCore.Runtime.PageBuilder.PageForms.Naming.field_key/2` compares text either way.
  """
  @spec names(Tree.t(), Node.t()) :: [String.t()]
  def names(tree, node), do: gather(tree, node, let_var(node))

  defp gather(tree, node, var) do
    tree
    |> owned(node)
    |> Enum.map(&field_name(&1, var))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp collect(tree, node, var) do
    tree
    |> owned(node)
    |> Enum.flat_map(&field(&1, var))
    |> Enum.uniq_by(& &1.key)
  end

  defp owned(tree, node) do
    tree
    |> Tree.children(node.id)
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&claimed(tree, &1))
  end

  defp claimed(tree, node), do: claim(form?(node), tree, node)

  defp claim(true, _tree, _node), do: []
  defp claim(false, tree, node), do: [node | owned(tree, node)]

  defp field(node, var), do: described(node, field_key(node, var))

  defp described(_node, nil), do: []
  defp described(node, key), do: [%{key: key, type: type(node), rules: rules(node)}]

  @doc """
  The field key this node carries: its binding first, its own `name` second.

  `var` is the form's `:let` variable, so a node bound to some other variable is not this form's
  field even when it sits inside it.
  """
  @spec field_key(Node.t(), atom() | nil) :: atom() | nil
  def field_key(node, var), do: bound_key(node, var) || control_key(node)

  @doc """
  The same answer as `field_key/2`, as text and interning nothing.

  The editor's half of the question — see the moduledoc for why the two halves exist.
  """
  @spec field_name(Node.t(), atom() | nil) :: String.t() | nil
  def field_name(node, var), do: node |> bound_key(var) |> written() || control_name(node)

  defp written(nil), do: nil
  defp written(key), do: Atom.to_string(key)

  @doc "The key this node binds, ignoring any literal `name` it also carries."
  @spec bound_key(Node.t(), atom() | nil) :: atom() | nil
  def bound_key(%{attrs: attrs}, var) do
    Enum.find_value(attrs, fn
      {_name, {:expr, source}} -> field_key_from(source, var)
      _attr -> nil
    end)
  end

  def bound_key(_node, _var), do: nil

  @doc """
  The variable this node reads a field off — `field={f[:email]}` gives `:f` — or `nil` when it reads
  a field off nothing.

  `bound_key/2` answers for a KNOWN form; this answers where no form is known, which is the one case
  that matters: a field outside every form is bound to a `:let` variable nothing binds any more, and
  `MishkaCmsCore.Runtime.PageBuilder.CodeCheck` refuses the whole page for it. A control that names
  itself outright merely stops submitting. Two different costs, so the audit tells them apart.

  `assigns` is never the answer. It is in scope in every template, so `assigns[:contact_form]` is a
  page assign being read rather than a form binding waiting for a `:let`.
  """
  @spec bound_var(Node.t()) :: atom() | nil
  def bound_var(%{attrs: attrs}) do
    Enum.find_value(attrs, fn
      {_name, {:expr, source}} -> accessed_var(source)
      _attr -> nil
    end)
  end

  def bound_var(_node), do: nil

  defp accessed_var(source) when is_binary(source),
    do: source |> String.trim() |> Code.string_to_quoted() |> variable_of()

  defp accessed_var(_other), do: nil

  defp variable_of({:ok, ast}), do: accessed(ast)
  defp variable_of(_unparseable), do: nil

  defp accessed({{:., _dot, [Access, :get]}, _call, [{var, _var_meta, nil}, key]})
       when is_atom(key) and not is_nil(key) and var != :assigns,
       do: var

  defp accessed({{:., _dot, [inner, field]}, _call, []}) when is_atom(field), do: accessed(inner)

  defp accessed(_other), do: nil

  @doc """
  The key an attribute expression binds, or `nil`.

  `"f[:email]"` and `"f[:email].value"` are the same fact — the source is parsed and never
  evaluated, the rule the canvas follows for every other expression — and `"g[:email]"` under a form
  bound to `f` is not this form's field.
  """
  @spec field_key_from(String.t(), atom() | nil) :: atom() | nil
  def field_key_from(source, var), do: source |> field_access(var) |> bound()

  defp bound({key, _path}), do: key
  defp bound(nil), do: nil

  @doc """
  The key an attribute expression binds **and what it reads off it**: `"f[:email]"` gives
  `{:email, []}`, `"f[:email].name"` gives `{:email, [:name]}`.

  `field_key_from/2` deliberately forgets the second half — the key is the same fact whichever
  member of the field is read — but a renderer cannot forget it. `name={f[:email].name}` wants the
  input name, a string; handing it the whole `%Phoenix.HTML.FormField{}` because both expressions
  answer `:email` is how the canvas red-boxed a kit that binds by name and value
  (`MishkaCmsCoreWeb.Live.Admin.Builder.CanvasLive`, which is the surface the form is authored on).

  The source is parsed and never evaluated, and the path is whatever dots the author wrote — this
  module does not decide which members exist, the struct does.
  """
  @spec field_access(String.t(), atom() | nil) :: {atom(), [atom()]} | nil
  def field_access(_source, nil), do: nil

  def field_access(source, var) when is_binary(source) and is_atom(var),
    do: source |> String.trim() |> Code.string_to_quoted() |> access_key(var)

  def field_access(_source, _var), do: nil

  defp access_key({:ok, ast}, var), do: access(ast, var, [])
  defp access_key(_unparseable, _var), do: nil

  defp access({{:., _dot, [Access, :get]}, _call, [{var, _var_meta, nil}, key]}, var, path)
       when is_atom(key) and not is_nil(key),
       do: {key, path}

  defp access({{:., _dot, [inner, field]}, _call, []}, var, path) when is_atom(field),
    do: access(inner, var, [field | path])

  defp access(_other, _var, _path), do: nil

  @doc """
  The same binding expression, bound to a different key: `"f[:email].name"` rebound to `phone` is
  `"f[:phone].name"`.

  `nil` for a source that is not this form's binding at all, so a caller can leave it exactly as the
  author wrote it. What is rebuilt is only what `field_access/2` recognised — the variable, the key
  and the dots — so nothing here has to reproduce an expression it did not understand.
  """
  @spec rebind(String.t(), atom() | nil, String.t(), atom() | nil) :: String.t() | nil
  def rebind(source, var, key, to_var \\ nil),
    do: source |> field_access(var) |> rebound(to_var || var, key)

  defp rebound(nil, _var, _key), do: nil

  defp rebound({_replaced, path}, var, key),
    do: "#{var}[:#{key}]" <> Enum.map_join(path, "", &".#{&1}")

  @doc """
  Every attribute on `node` that binds `key`, rebound to `to`, ready for
  `MishkaCmsCore.Runtime.PageBuilder.Tree.set_attr/4`.

  All of them together, because one control carries the key more than once —
  `name={f[:email].name}` beside `value={f[:email].value}` — and moving one of the pair alone would
  leave the input posting under one key and redisplaying another. Attributes bound to some other key
  are not touched.

  Read by `MishkaCmsCore.Runtime.PageBuilder.PageForms.Naming.rekey/2`, which writes straight to a
  tree, and by `MishkaCmsCore.Runtime.PageBuilder.PageForms.FormChecks`, which turns each one into
  an op — one answer, two shapes.

  `to_var` rebinds onto another form's `:let` variable as well; `nil` keeps `var`.
  """
  @spec rebindings(Node.t(), atom() | nil, atom(), String.t(), atom() | nil) ::
          [{String.t(), {:expr, String.t()}}]
  def rebindings(node, var, key, to, to_var \\ nil)

  def rebindings(%{attrs: attrs}, var, key, to, to_var) do
    for {name, {:expr, source}} <- attrs,
        field_key_from(source, var) == key,
        rebound = rebind(source, var, to, to_var),
        is_binary(rebound),
        do: {name, {:expr, rebound}}
  end

  def rebindings(_node, _var, _key, _to, _to_var), do: []

  defp control_name(node), do: node |> control?() |> carried(node)

  defp carried(true, node), do: Node.literal(node, "name")
  defp carried(false, _node), do: nil

  defp control_key(node), do: node |> control_name() |> to_key()

  defp to_key(nil), do: nil
  defp to_key(value), do: String.to_atom(value)

  defp type(node), do: node |> Node.attr_text("data-cast") |> cast()

  defp cast("integer"), do: :integer
  defp cast("float"), do: :float
  defp cast("boolean"), do: :boolean
  defp cast("date"), do: :date
  defp cast(_default), do: :string

  defp rules(node) do
    [
      required_rule(node),
      integer_rule(node, "minlength", :min_length),
      integer_rule(node, "maxlength", :max_length),
      number_rule(node, "min", :min),
      number_rule(node, "max", :max),
      pattern_rule(node),
      format_rule(node),
      confirms_rule(node)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp required_rule(node), do: node |> Node.attr("required") |> required()

  defp required(nil), do: nil
  defp required(_present), do: :required

  # `minlength` and `maxlength` count characters, so half a character is not a bound the browser
  # would enforce either.
  defp integer_rule(node, attr, rule) do
    with text when is_binary(text) <- Node.attr_text(node, attr),
         {number, ""} <- text |> String.trim() |> Integer.parse() do
      {rule, number}
    else
      _absent -> nil
    end
  end

  # HTML'S `min` AND `max` ARE FLOATING POINT on `type="number"`, and lifting them with
  # `Integer.parse/1` discarded every fractional one without a log, an audit finding or anything in
  # the editor to show it: `min="0.5"` parses as `{0, ".5"}`, which is not a whole parse, so the rule
  # was dropped and the server accepted the 0.1 the browser had just refused. `data-cast="float"` and
  # `MishkaCmsCore.Runtime.PageForm.Rules` were both ready for it — only the lift was not. An integer
  # stays an integer so the message a visitor reads says `10` rather than `10.0`.
  defp number_rule(node, attr, rule) do
    with text when is_binary(text) <- Node.attr_text(node, attr),
         {number, ""} <- text |> String.trim() |> parse_number() do
      {rule, number}
    else
      _absent -> nil
    end
  end

  defp parse_number(text), do: text |> Integer.parse() |> whole(text)

  defp whole({number, ""}, _text), do: {number, ""}
  defp whole(_fractional_or_absent, text), do: Float.parse(text)

  # A pattern that will not compile contributes no rule rather than raising into a page compile. The
  # source travels and is compiled once at runtime, because it is matched on every keystroke.
  defp pattern_rule(node) do
    with source when is_binary(source) <- Node.attr_text(node, "pattern"),
         {:ok, _regex} <- Regex.compile(source) do
      {:pattern, source}
    else
      _unusable -> nil
    end
  end

  defp format_rule(node), do: node |> Node.attr_text("data-format") |> format()

  defp format("email"), do: {:format, :email}
  defp format("url"), do: {:format, :url}
  defp format(_other), do: nil

  defp confirms_rule(node), do: node |> Node.attr_text("data-confirms") |> confirms()

  defp confirms(name) when is_binary(name) and name != "", do: {:confirms, name}
  defp confirms(_absent), do: nil

  defp presence(nil), do: nil
  defp presence(value), do: value |> String.trim() |> filled()

  defp filled(""), do: nil
  defp filled(value), do: value

  defp literal_atom(source), do: source |> String.trim() |> Code.string_to_quoted() |> atom_text()

  defp atom_text({:ok, atom}) when is_atom(atom) and not is_nil(atom), do: Atom.to_string(atom)
  defp atom_text({:ok, binary}) when is_binary(binary), do: presence(binary)
  defp atom_text(_other), do: nil
end
