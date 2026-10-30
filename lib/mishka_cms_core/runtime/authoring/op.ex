# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.Op do
  @moduledoc """
  One validated edit request — the only thing allowed to reach a
  `MishkaCmsCore.Runtime.Authoring.Tree` combinator.

  Every `handle_event` in the editor turns its raw params into an `Op` with `build/1` before the
  session touches the tree (ADR-13). That is what makes the server the authority rather than a
  transcription service: a tampered payload fails validation here, and a plugin that wants to veto
  or rewrite an edit gets a typed struct on the `builder:node:before_*` hook instead of a bag of
  strings.

  ## Why one struct and not twelve

  ADR-13 sketches a struct per combinator. One struct with a validated `kind` and a per-kind
  required-field check gives the same guarantee — nothing unvalidated reaches a combinator — with
  one module to read and one hook payload shape for plugins to match on. It follows the house
  precedent (`MishkaCmsCore.Dashboard.Widget` is likewise one struct with a `type`), and pattern
  matching on `%Op{kind: :move}` reads the same as matching a `Move` struct would.

  ## Insertion is always "parse this template"

  Dropping a palette component, inserting an example variant and pasting the clipboard are the same
  operation: take HEEx, parse it, splice the subtree in. `:insert` therefore carries a `template`
  string rather than a pre-built node, which means an example keeps its attributes and children (the
  React editor used only `ast[0][0]` and dropped both) and a pasted subtree is validated by the same
  parser as everything else.
  """
  use GuardedStruct
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Builder.Literal
  alias MishkaCmsCore.Runtime.Authoring.Tree
  alias MishkaCmsCore.Runtime.Authoring.Tree.Node

  @kinds [
    :insert,
    :move,
    :delete,
    :duplicate,
    :set_attr,
    :delete_attr,
    :set_text,
    :set_style,
    :reset_styles,
    :wrap,
    :wrap_many,
    :unwrap
  ]

  # ASKED OF THE VOCABULARY, not written out again. A bucket is a width AND a state now, and the six
  # pairs that adds are exactly the ones a second list here would have been missing — a `set_style`
  # naming `mobile_hover` came back "unknown bucket", so the panel offered the control, the author
  # used it, and the change was refused.
  @buckets MishkaCmsCore.Runtime.Authoring.Tree.Styles.buckets()

  @required %{
    insert: [:template],
    move: [:node_id],
    delete: [:node_id],
    duplicate: [:node_id],
    set_attr: [:node_id, :name],
    delete_attr: [:node_id, :name],
    set_text: [:node_id],
    set_style: [:node_id, :bucket, :prop],
    reset_styles: [:node_id, :bucket],
    wrap: [:node_id, :tag],
    wrap_many: [:node_ids, :tag],
    unwrap: [:node_id]
  }

  guardedstruct do
    field(:kind, atom(),
      enforce: true,
      derives:
        "validate(enum=Atom[insert::move::delete::duplicate::set_attr::delete_attr::set_text::set_style::reset_styles::wrap::wrap_many::unwrap])"
    )

    field(:node_id, String.t(), derives: "validate(string, regex=^n[a-z0-9]{8}$)")
    # SEVERAL nodes, for the one op that acts on a selection rather than an element — see
    # `Tree.wrap_many/3`. Kept separate from `node_id` so every other kind still reads as exactly
    # one target and cannot be handed a list by accident.
    field(:node_ids, list(), default: [])
    field(:parent_id, String.t())
    field(:index, integer(), default: 0)
    field(:template, String.t())
    field(:name, String.t(), derives: "sanitize(trim)")
    field(:value, String.t())
    # No default on purpose: "not stated" and "stated as a string" are different answers, and
    # `apply_to/2` reads the difference — see `attr_value/2`.
    field(:value_kind, atom())
    field(:text, String.t())
    field(:bucket, atom())
    field(:prop, String.t(), derives: "sanitize(trim)")
    field(:tag, String.t(), derives: "sanitize(trim)")
  end

  @doc "Every op kind the editor can issue."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "The style buckets an override may be recorded in — every width crossed with every state."
  @spec buckets() :: [atom()]
  def buckets, do: @buckets

  @doc """
  Builds an op from raw client params.

  Accepts string or atom keys, coerces the handful of fields the wire sends as strings (`index`,
  `kind`, `bucket`, `value_kind`) and then enforces the fields that kind actually needs — a `:move`
  without a `node_id`, or a `:set_style` naming a bucket that does not exist, is refused here rather
  than halfway through a combinator.
  """
  @spec build(map()) :: {:ok, t()} | {:error, term()}
  def build(params) when is_map(params) do
    with {:ok, normalized} <- normalize(params),
         {:ok, op} <- builder(normalized) do
      validate_required(op)
    end
  end

  defp normalize(params) do
    params
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> then(fn params ->
      with {:ok, kind} <- known_atom(params["kind"], @kinds, :kind),
           {:ok, bucket} <- optional_atom(params["bucket"], @buckets, :bucket),
           {:ok, value_kind} <-
             optional_atom(params["value_kind"], [:string, :expr, :boolean], :value_kind) do
        {:ok,
         %{
           kind: kind,
           node_id: params["node_id"],
           parent_id: parent_id(params["parent_id"]),
           index: integer(params["index"]),
           template: params["template"],
           name: params["name"],
           value: params["value"],
           value_kind: value_kind,
           text: params["text"],
           bucket: bucket,
           prop: params["prop"],
           tag: params["tag"],
           node_ids: node_ids(params["node_ids"])
         }
         |> Enum.reject(fn {_key, value} -> is_nil(value) end)
         |> Map.new()}
      end
    end)
  end

  # `:root` arrives from the client as the string "root" — a top-level drop is a real target, not a
  # missing one, so it has to survive the trip as something the tree understands.
  # A list off the wire is a list of ids or it is nothing: one bad entry means the caller does not
  # know what it is asking for, and half a wrap is worse than none.
  defp node_ids(ids) when is_list(ids) do
    case Enum.all?(ids, &is_binary/1) and ids != [] do
      true -> ids
      false -> nil
    end
  end

  defp node_ids(_other), do: nil

  defp parent_id("root"), do: :root
  defp parent_id(""), do: :root
  defp parent_id(other), do: other

  defp integer(nil), do: 0
  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> parsed
      :error -> 0
    end
  end

  defp integer(_value), do: 0

  defp known_atom(value, allowed, field) when is_atom(value) and not is_nil(value) do
    case value in allowed do
      true -> {:ok, value}
      false -> {:error, [%{field: field, message: gettext("unknown %{field}", field: field)}]}
    end
  end

  defp known_atom(value, allowed, field) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, [%{field: field, message: gettext("unknown %{field}", field: field)}]}
      found -> {:ok, found}
    end
  end

  defp known_atom(_value, _allowed, field),
    do: {:error, [%{field: field, message: gettext("%{field} is required", field: field)}]}

  defp optional_atom(nil, _allowed, _field), do: {:ok, nil}
  defp optional_atom("", _allowed, _field), do: {:ok, nil}
  defp optional_atom(value, allowed, field), do: known_atom(value, allowed, field)

  defp validate_required(%{kind: kind} = op) do
    @required
    |> Map.fetch!(kind)
    |> Enum.reject(&present?(Map.get(op, &1)))
    |> case do
      [] ->
        {:ok, op}

      missing ->
        {:error,
         [
           %{
             field: hd(missing),
             message: gettext("%{field} is required for %{kind}", field: hd(missing), kind: kind)
           }
         ]}
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true

  @doc """
  Applies a validated op to a tree.

  Returns `{:ok, tree}`, `{:ok, tree, node_id}` for the ops that produce a node the caller wants to
  select afterwards, or `{:error, reason}`. Containment is **not** checked here — the session does
  that, so a plugin rewriting an op on the `before_*` hook cannot accidentally bypass it.
  """
  @spec apply_to(t(), Tree.t()) ::
          {:ok, Tree.t()} | {:ok, Tree.t(), String.t()} | {:error, term()}
  def apply_to(%{kind: :insert} = op, tree) do
    with {:ok, subtree} <- Tree.parse(op.template),
         {:ok, fresh} <- non_empty(subtree),
         {:ok, updated} <- Tree.insert(tree, fresh, op.parent_id || :root, op.index) do
      {:ok, updated, hd(fresh.roots)}
    end
  end

  def apply_to(%{kind: :move} = op, tree),
    do: Tree.move(tree, op.node_id, op.parent_id || :root, op.index)

  def apply_to(%{kind: :delete} = op, tree), do: Tree.delete(tree, op.node_id)

  def apply_to(%{kind: :duplicate} = op, tree), do: Tree.duplicate(tree, op.node_id)

  def apply_to(%{kind: :set_attr} = op, tree),
    do: Tree.set_attr(tree, op.node_id, op.name, attr_value(op, tree))

  def apply_to(%{kind: :delete_attr} = op, tree), do: Tree.delete_attr(tree, op.node_id, op.name)

  def apply_to(%{kind: :set_text} = op, tree), do: Tree.set_text(tree, op.node_id, op.text || "")

  def apply_to(%{kind: :set_style} = op, tree),
    do: Tree.set_style(tree, op.node_id, op.bucket, op.prop, blank_to_nil(op.value))

  def apply_to(%{kind: :reset_styles} = op, tree),
    do: Tree.reset_styles(tree, op.node_id, op.bucket)

  # THE WRAPPER IS WHAT THE AUTHOR IS NOW LOOKING AT — it is the thing that was just made, and the
  # reason for making it is always something to be done to it: a class on the container, an address
  # in the link. `wrap_many` already answered this way; the single one left the selection on the
  # node it had just buried, so the CSS box's own "Wrap it in a div" offered a div and then went on
  # showing the element that still takes no CSS.
  def apply_to(%{kind: :wrap} = op, tree) do
    wrapper = wrapper(op.tag)

    with {:ok, updated} <- Tree.wrap(tree, op.node_id, wrapper) do
      {:ok, updated, wrapper.id}
    end
  end

  def apply_to(%{kind: :wrap_many} = op, tree) do
    wrapper = wrapper(op.tag)

    with {:ok, updated} <- Tree.wrap_many(tree, op.node_ids, wrapper) do
      {:ok, updated, wrapper.id}
    end
  end

  def apply_to(%{kind: :unwrap} = op, tree), do: Tree.unwrap(tree, op.node_id)

  # A WRAPPER ARRIVES WITH WHATEVER MAKES ITS TAG MEAN ANYTHING. An `<a>` with no `href` is not a
  # link — nothing renders differently, the browser gives it no pointer, and the inspector's
  # Attributes list has nothing to draw, so the one field the author opened the action for is the
  # one they still have to know the name of. A `div` needs no such thing, and neither does anything
  # else the editor wraps with, which is why this is a table of one rather than a flag.
  @wrapper_attrs %{"a" => [{"href", {:string, "#"}}]}

  defp wrapper(tag),
    do: Node.new(:tag, tag: tag, attrs: Map.get(@wrapper_attrs, tag, []))

  defp non_empty(%Tree{roots: []}), do: {:error, :empty_template}

  defp non_empty(%Tree{} = subtree), do: {:ok, Tree.refresh_ids(subtree)}

  defp attr_value(%{value_kind: :boolean}, _tree), do: :boolean
  defp attr_value(%{value_kind: :expr, value: value}, _tree), do: {:expr, value || ""}
  defp attr_value(%{value_kind: :string, value: value}, _tree), do: {:string, value || ""}

  # An attribute that holds an expression goes on holding one.
  #
  # Every property control in the inspector shows an expression's SOURCE — `@icon` for
  # `name={@icon}` — and posts that source straight back as an ordinary value. With no kind stated
  # the write landed as `name="@icon"`: a string literal, identical in the panel, no longer bound to
  # anything, and round-tripped into the stored markup by the serializer. A component that nests
  # another component is made of exactly these bindings, so editing any property of an inner
  # component quietly cut it off from the attribute it was passing down.
  #
  # Only where nothing was stated. `Inspector.rename_ops/2` and `rule_op/3` say `:string` when a
  # string is what they mean, and clearing a box is a `delete_attr` — so a literal stays reachable
  # both ways.
  #
  # AND ONLY WHILE WHAT WAS TYPED IS STILL AN EXPRESSION. The box offers the binding's source to
  # edit, and an author who types words over it means the words: `E2E-0` over `f[:field].value` was
  # stored as `{E2E - 0}` — the alias `E2E` minus zero, which compiles and raises ArithmeticError on
  # every render, so the published page answered HTTP 500. The source posted back unchanged stays an
  # expression, so does source that still reads something (`Literal.expression?/1`), and so does a
  # literal (`{45}`, `{:danger}`), which is how the editor writes a number or an atom; anything else
  # is the text it looks like.
  defp attr_value(%{value: value} = op, tree) do
    case Tree.get(tree, op.node_id) do
      %Node{} = node -> as_held(Node.attr(node, op.name), value || "")
      _gone -> {:string, value || ""}
    end
  end

  defp as_held({:expr, source}, value) do
    case value == source or Literal.expression?(value) or
           match?({:ok, _term}, Literal.value(value)) do
      true -> {:expr, value}
      false -> {:string, value}
    end
  end

  defp as_held(_plain_or_unset, value), do: {:string, value}

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @doc """
  Whether an op changes the document (and so belongs in the undo history) — every kind currently
  does, but the editor also routes selection and viewport changes through the same funnel, and those
  must not consume a history slot.
  """
  @spec mutating?(t()) :: boolean()
  def mutating?(%{kind: kind}), do: kind in @kinds

  @doc """
  A short label for the history sheet and the plugin payload — "Moved element", "Set class", …
  """
  @spec label(t()) :: String.t()
  def label(%{kind: :insert}), do: gettext("Inserted element")
  def label(%{kind: :move}), do: gettext("Moved element")
  def label(%{kind: :delete}), do: gettext("Deleted element")
  def label(%{kind: :duplicate}), do: gettext("Duplicated element")
  # `MishkaCmsCore.Runtime.Authoring.Visibility.attribute/0`, which a pattern cannot call.
  def label(%{kind: :set_attr, name: "data-pb-hidden"}), do: gettext("Hidden from visitors")
  def label(%{kind: :delete_attr, name: "data-pb-hidden"}), do: gettext("Shown to visitors")
  def label(%{kind: :set_attr, name: name}), do: gettext("Set %{name}", name: name)
  def label(%{kind: :delete_attr, name: name}), do: gettext("Removed %{name}", name: name)
  def label(%{kind: :set_text}), do: gettext("Edited text")

  def label(%{kind: :set_style, prop: prop, bucket: bucket}),
    do: gettext("Set %{prop} (%{bucket})", prop: prop, bucket: bucket)

  def label(%{kind: :reset_styles, bucket: bucket}),
    do: gettext("Reset %{bucket} overrides", bucket: bucket)

  def label(%{kind: :wrap, tag: tag}), do: gettext("Wrapped in <%{tag}>", tag: tag)

  def label(%{kind: :wrap_many, tag: tag, node_ids: ids}),
    do:
      ngettext(
        "Wrapped %{count} element in <%{tag}>",
        "Wrapped %{count} elements in <%{tag}>",
        length(ids),
        tag: tag
      )

  def label(%{kind: :unwrap}), do: gettext("Removed wrapper")
end
