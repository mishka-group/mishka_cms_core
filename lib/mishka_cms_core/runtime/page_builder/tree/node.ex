# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Tree.Node do
  @moduledoc """
  One node of an editable template — **one shape for everything the editor can address**.

  This is the model the React editor never had. It carried two incompatible record shapes in one
  array (a palette-dragged element with `component`/`renderedHtml` and no `tag`, and a loaded element
  with `tag`/`attrs` and no `component`), so every consumer had to branch and the save serializer
  only understood one of them. Here a `<div>`, a `<.card>`, a `:slot` entry, a text run and an
  `<%= for %>` block are all the same struct, distinguished by `kind`.

  ## Fields

    * `id` — `"n"` plus eight lowercase base32 characters. Minted at parse, stable across moves, and
      what every `phx-value-id` in the canvas carries. It is **not** persisted: serializing drops it,
      and re-parsing mints fresh ones (see `MishkaCmsCore.Runtime.PageBuilder.Tree` on identity).
    * `kind` — one of #{inspect([:tag, :component, :slot, :text, :eex, :eex_block, :eex_comment, :html_comment])}.
    * `tag` — `"div"`, `".card"`, `"MyApp.Components.hero"`, `":item"`; `nil` for text and comments.
    * `attrs` — an **ordered** list of `{name, value}`. `name` is a binary, or `:root` for a
      `{@rest}`-style root attribute. `value` is `{:string, binary}`, `{:expr, binary}` or
      `:boolean` (a bare attribute such as `disabled`). Preserving both the order and the
      string/expression distinction is what lets a template round-trip; the old JSON encoding
      flattened `{:expr, v}` to the string `"{v}"` and guessed it back with a `binary_part` check.
    * `children` — child **ids**, not structs. The tree is flat and id-keyed.
    * `parent_id` — `nil` for a root node.
    * `text` — the content of `:text`, `:eex`, `:eex_comment` and `:html_comment` nodes, and the
      block argument (`"for post <- @posts"`) used as an `:eex_block` chip's label.
    * `meta` — parser and editor metadata: `:mode` (`:normal` | `:preserve` for `pre`/`textarea`/
      `phx-no-format`), `:form` (`:body` for `{expr}` versus `:eex` for `<%= expr %>`), `:opt` (the
      EEx marker), `:source` (an `:eex_block`'s verbatim source — see ADR-9) and `:styles` (the
      responsive/pseudo cascade the inspector records).

  ## Construction

  Internal callers — the parser and the combinators — build the struct literally, because a 2,000
  node page would otherwise pay validation on every keystroke. `builder/1` is the boundary check and
  is required for anything arriving from outside: a client-sent op, a plugin-contributed subtree, a
  pasted clipboard payload, an inserted example.

  See also `MishkaCmsCore.Runtime.PageBuilder.Tree`, `MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer`
  and `MishkaCmsCore.Runtime.PageBuilder.Containment`.
  """
  use GuardedStruct

  @kinds [:tag, :component, :slot, :text, :eex, :eex_block, :eex_comment, :html_comment]

  @container_kinds [:tag, :component, :slot]

  @comment_kinds [:eex_comment, :html_comment]

  guardedstruct do
    field(:id, String.t(), enforce: true, derives: "validate(string, regex=^n[a-z0-9]{8}$)")

    field(:kind, atom(),
      enforce: true,
      derives:
        "validate(enum=Atom[tag::component::slot::text::eex::eex_block::eex_comment::html_comment])"
    )

    field(:tag, String.t(), derives: "sanitize(trim)")
    field(:attrs, list(), default: [])
    field(:children, list(), default: [])
    field(:parent_id, String.t())
    field(:text, String.t())
    field(:meta, map(), default: %{})
  end

  @doc "Every kind a node may declare."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  The kinds that may hold children. Text, both comment kinds and `:eex` are leaves; `:eex_block` is
  a leaf too, deliberately — ADR-9 makes it atomic so its source survives byte-for-byte.
  """
  @spec container_kinds() :: [atom()]
  def container_kinds, do: @container_kinds

  # THE DOCUMENT'S OWN ELEMENTS. A layout is rooted at `<body>` — every one in this CMS is — and a
  # document holds exactly one of each of these, so there is no "beside" one and nothing to put
  # around one. `MishkaCmsBuilderWeb.Live.CanvasLive` substitutes a `div` for them so the
  # frame can hold the node at all, which is precisely what made breaking the rule invisible.
  @document_tags ~w(html head body)

  @doc "The tags that are the document itself rather than content in it."
  @spec document_tags() :: [String.t()]
  def document_tags, do: @document_tags

  @doc "Whether this node is one of the document's own elements — `<html>`, `<head>`, `<body>`."
  @spec document?(t() | nil) :: boolean()
  def document?(%{kind: :tag, tag: tag}), do: tag in @document_tags
  def document?(_node), do: false

  @doc "Whether this node may hold children at all."
  @spec container?(t()) :: boolean()
  def container?(%{kind: kind}), do: kind in @container_kinds

  @doc "The kinds that are a note to the author rather than anything the published page renders."
  @spec comment_kinds() :: [atom()]
  def comment_kinds, do: @comment_kinds

  @doc "Whether this node is a comment, in either syntax."
  @spec comment?(t()) :: boolean()
  def comment?(%{kind: kind}), do: kind in @comment_kinds

  @doc """
  Whether this node is folded away on the canvas, given the session's eye set.

  The set holds the ids whose eye has been FLIPPED from the default for their kind, not the ids that
  are hidden — because a comment starts folded and everything else starts drawn. A comment renders
  nothing on the published page, so the chip standing in for one is scaffolding: worth having while
  you are hunting for a note, noise every other minute of the day.

  Folding is a view preference and nothing else. `MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer`
  never reads it, so a note nobody can see is still a note the save writes back out.
  """
  @spec hidden?(t(), MapSet.t()) :: boolean()
  def hidden?(%{kind: kind, id: id}, flipped) when kind in @comment_kinds,
    do: !MapSet.member?(flipped, id)

  def hidden?(%{id: id}, flipped), do: MapSet.member?(flipped, id)

  @doc """
  A fresh node id: `"n"` + eight lowercase base32 characters, which is exactly five random bytes.
  The alphabet (`a-z2-7`) is a subset of the `id` derive's `[a-z0-9]`, so a generated id always
  passes `builder/1`.
  """
  @spec generate_id() :: String.t()
  def generate_id,
    do: "n" <> Base.encode32(:crypto.strong_rand_bytes(5), case: :lower, padding: false)

  @doc """
  Builds a node without validation — the internal constructor used by the parser and the
  combinators. Anything crossing a trust boundary goes through `builder/1` instead.
  """
  @spec new(atom(), keyword()) :: t()
  def new(kind, fields \\ []) do
    struct(__MODULE__, Keyword.merge([id: generate_id(), kind: kind], fields))
  end

  @doc """
  The name a `:component` node resolves to at render time.

  Runtime components are written as `<.component component_name="chelekom-card" site="Global">`,
  because a database-defined component's name is data (and often hyphenated, which is not a valid
  function-call tag). That wrapper form is the one the compilers emit and the one every stored
  template uses, so its `component_name` attribute — not the literal tag — is the answer here.
  A plain `<.card>` still resolves to `"card"`, and anything else gives `nil`.
  """
  @spec component_name(t()) :: String.t() | nil
  def component_name(%{kind: :component, tag: ".component"} = node),
    do: attr_text(node, "component_name")

  def component_name(%{kind: :component, tag: "." <> name}), do: name
  def component_name(%{kind: :component, tag: tag}) when is_binary(tag), do: tag
  def component_name(%{kind: _other}), do: nil

  @doc """
  The slot name a `:slot` node fills — `":item"` gives `"item"`. Returns `nil` for any other kind.
  """
  @spec slot_name(t()) :: String.t() | nil
  def slot_name(%{kind: :slot, tag: ":" <> name}), do: name
  def slot_name(%{kind: :slot, tag: tag}) when is_binary(tag), do: tag
  def slot_name(%{kind: _other}), do: nil

  @doc """
  What to call this node in front of a reader — `"h1"`, `"text"`, a component's name.

  Here rather than in the panel because it is not only a label any more: a review note captures it
  at write time, and `MishkaCmsBuilder.Review` compares it against the element a
  stored address resolves to. A positional anchor with nothing to check it against selects whatever
  slid into that slot after an edit; this is the check.
  """
  @spec label(map()) :: String.t()
  def label(%{kind: :component} = node), do: component_name(node) || node.tag
  def label(%{kind: :slot} = node), do: "__" <> (slot_name(node) || "slot") <> "_slot"
  def label(%{kind: :text}), do: "text"

  def label(%{kind: :eex_block, text: text}),
    do: "<%= #{String.slice(text || "", 0, 18)} %>"

  def label(%{kind: :eex}), do: "expression"
  def label(%{kind: :eex_comment}), do: "comment"
  def label(%{kind: :html_comment}), do: "comment"
  def label(%{tag: tag}), do: tag || "node"

  @doc """
  Reads one attribute's value, or `nil` when the node does not carry it. Bare attributes read as
  `:boolean`, so an absent attribute and a valueless one stay distinguishable.
  """
  @spec attr(t(), String.t()) :: {:string, String.t()} | {:expr, String.t()} | :boolean | nil
  def attr(%{attrs: attrs}, name) do
    Enum.find_value(attrs, fn
      {^name, value} -> value
      _other -> nil
    end)
  end

  @doc """
  An attribute's plain text value — the literal for a `{:string, _}`, the expression source for an
  `{:expr, _}`, `""` for a bare attribute and `nil` when unset. This is what property widgets and
  audit checks read; use `attr/2` when the string/expression distinction matters.
  """
  @spec attr_text(t(), String.t()) :: String.t() | nil
  def attr_text(node, name), do: node |> attr(name) |> attr_value_text()

  defp attr_value_text({:string, value}), do: value
  defp attr_value_text({:expr, value}), do: value
  defp attr_value_text(:boolean), do: ""
  defp attr_value_text(nil), do: nil

  @doc """
  A word the author actually wrote in this attribute: the literal of a `{:string, _}`, trimmed, and
  `nil` when the attribute is unset, holds an expression, or holds nothing but whitespace.

  `attr_text/2` is the other question and answers an expression's source too, which is what a
  property widget wants. Everything that MINES an author's own word out of markup wants this one:
  a palette card is seeded `name=""` so it renders standing alone, and reading that blank as a word
  is how a wrapped field came out `f[:field]` inside `form-form`; `name={@input_name}` is source, not
  a name. It was written out four times — once each in
  `MishkaCmsCore.Runtime.PageBuilder.PageForms`, its `FormChecks` and its `FormPlacement`, and again
  as the value test in `MishkaCmsCore.Runtime.PageBuilder.Fields` — and one of the four trimmed
  differently.
  """
  @spec literal(t(), String.t()) :: String.t() | nil
  def literal(node, name), do: node |> attr(name) |> literal_value()

  defp literal_value({:string, value}), do: value |> String.trim() |> filled()
  defp literal_value(_other), do: nil

  defp filled(""), do: nil
  defp filled(value), do: value

  @quote "&quot;"

  @doc """
  An attribute value as it has to be written between double quotes.

  A node holds what the author typed. Written back as source, a double quote in it closes the
  attribute early and the template stops parsing — and because the editor's save path is
  tree, serialize, re-parse, that does not surface as a rejected keystroke. The op is recorded, the
  history entry is written, the re-parse fails, and the draft simply stops being saved while the
  editor goes on saying it saved. A regex in a `pattern`, an apostrophe-and-quote in a success
  message: ordinary things to type.

  Pairs with `unescape_attr/1`, and the pair is stable — a value survives any number of round trips.
  """
  @spec escape_attr(String.t()) :: String.t()
  def escape_attr(value) when is_binary(value), do: String.replace(value, ~s("), @quote)

  @doc """
  An attribute value read back from source, as the author typed it.

  Only the double quote is decoded, because it is the only character `escape_attr/1` encodes. Every
  other entity in a template is the author's own text and is left exactly as they wrote it.
  """
  @spec unescape_attr(String.t()) :: String.t()
  def unescape_attr(value) when is_binary(value), do: String.replace(value, @quote, ~s("))
end
