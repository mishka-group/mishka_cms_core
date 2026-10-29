# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.Tree do
  @moduledoc """
  The editable model of a template: a flat, id-keyed map of `MishkaCmsCore.Runtime.Authoring.Tree.Node`
  structs plus the list of root ids.

  A tree is produced by `parse/1` from a HEEx string and turned back into HEEx by
  `MishkaCmsCore.Runtime.Authoring.Tree.Serializer.serialize/1`. Everything in between — insert,
  move, delete, duplicate, attribute and text edits — is a pure function here, which is what makes
  the editor testable without a browser and what lets the server be the authority on every mutation
  a client asks for.

  ## Why flat, and why ids

  Nesting the structs would mean every edit rebuilds the spine down to the touched node and every
  lookup walks from a root. A map keyed by id makes a lookup, a parent hop and a subtree extraction
  all direct, and gives every node a stable handle for `phx-value-id`. The parser is unchanged and
  still lossless (`MishkaCmsCore.Runtime.Authoring.HtmlTokenizer`); this module only
  normalizes its tuples into one shape.

  ## Identity is per-parse, not persistent

  Ids are minted by `parse/1` and are stable for the life of an editing session, across every move
  and re-render. They are **not** written to the template, so re-parsing the same source yields
  different ids. Session state (selection, locks, hidden nodes, undo snapshots) may key on them
  freely; anything that has to outlive a parse — durable per-node comments, for instance — needs its
  own anchoring scheme and cannot simply store an id.

  ## Whitespace is part of the model

  Whitespace-only text nodes are kept rather than dropped: `<b>a</b> <i>b</i>` and
  `<b>a</b><i>b</i>` render differently, so discarding the run between two inline elements silently
  changes the page. They carry `meta.whitespace?: true` so the canvas and the layers panel can hide
  them without the serializer losing them.

  ## Error handling

  `parse/1` is the one place in the editor that rescues. `EEx.tokenize/1` and the LiveView tokenizer
  signal a malformed template by raising, there is no non-raising variant, and an admin pasting
  broken HEEx into the code drawer must get an inline `{:error, %{line:, column:, message:}}`
  instead of a 500. Every other function in this module is total.
  """

  alias MishkaCmsCore.Runtime.Authoring.ElementScopes
  alias MishkaCmsCore.Runtime.Authoring.HtmlTokenizer
  alias MishkaCmsCore.Runtime.Authoring.Tree.Node
  alias MishkaCmsCore.Runtime.Authoring.Tree.Styles

  defstruct nodes: %{}, roots: []

  @type t :: %__MODULE__{nodes: %{String.t() => Node.t()}, roots: [String.t()]}
  @type parent :: String.t() | :root
  @type error :: {:error, atom() | map()}

  @doc "An empty tree — what a brand-new page starts from."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Parses a HEEx template into a tree.

  Returns `{:error, %{line:, column:, message:}}` for a template the tokenizer cannot read; the
  editor surfaces that inline rather than failing the mount.
  """
  @spec parse(String.t() | nil) :: {:ok, t()} | error()
  def parse(nil), do: {:ok, new()}
  def parse(""), do: {:ok, new()}

  def parse(source) when is_binary(source) do
    case tokenize(source) do
      {:ok, tokens} -> {:ok, from_tokens(tokens)}
      {:error, _line, _column, _message} = error -> {:error, parse_error(error)}
      {:error, %{} = error} -> {:error, error}
    end
  end

  @doc "Parses a template, raising on a malformed one. For fixtures and tests, not request paths."
  @spec parse!(String.t() | nil) :: t()
  def parse!(source) do
    case parse(source) do
      {:ok, tree} -> tree
      {:error, error} -> raise ArgumentError, "unparseable template: #{inspect(error)}"
    end
  end

  defp tokenize(source) do
    HtmlTokenizer.build_tokenize(source)
  rescue
    error -> {:error, parse_error(error)}
  end

  defp parse_error({:error, line, column, message}),
    do: %{line: line, column: column, message: message}

  defp parse_error(%{line: line, column: column} = error),
    do: %{line: line, column: column, message: Exception.message(error)}

  defp parse_error(error),
    do: %{line: nil, column: nil, message: Exception.message(error)}

  @doc "Looks a node up by id."
  @spec get(t(), String.t() | nil) :: Node.t() | nil
  def get(%__MODULE__{}, nil), do: nil
  def get(%__MODULE__{nodes: nodes}, id), do: Map.get(nodes, id)

  @doc "How many nodes the tree holds."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{nodes: nodes}), do: map_size(nodes)

  @doc "The child nodes of `id`, or the root nodes for `:root`, in document order."
  @spec children(t(), parent()) :: [Node.t()]
  def children(tree, :root), do: Enum.map(tree.roots, &get(tree, &1))

  def children(tree, id) do
    case get(tree, id) do
      nil -> []
      node -> Enum.map(node.children, &get(tree, &1))
    end
  end

  @doc """
  Whether `id` renders nothing yet — no children at all, or nothing but the indentation.

  EMPTY THE WAY AN AUTHOR MEANS IT. Taking the last thing out of a container leaves behind the
  whitespace that used to sit around it, so `children` reads `[whitespace, whitespace]` rather than
  `[]`, and the box that had a floor a moment ago collapses back to nothing the instant it is
  emptied — the one moment it most needs to count as a hole to put something in.
  """
  @spec blank?(t(), parent()) :: boolean()
  def blank?(tree, id) do
    tree
    |> child_ids(id)
    |> Enum.all?(&match?(%Node{kind: :text, meta: %{whitespace?: true}}, get(tree, &1)))
  end

  @doc "The ids of `id`'s children, or the roots for `:root`."
  @spec child_ids(t(), parent()) :: [String.t()]
  def child_ids(tree, :root), do: tree.roots

  def child_ids(tree, id) do
    case get(tree, id) do
      nil -> []
      node -> node.children
    end
  end

  @doc "Ancestor nodes of `id`, nearest parent first."
  @spec ancestors(t(), String.t()) :: [Node.t()]
  def ancestors(tree, id) do
    case get(tree, id) do
      %Node{parent_id: nil} -> []
      %Node{parent_id: parent_id} -> [get(tree, parent_id) | ancestors(tree, parent_id)]
      nil -> []
    end
  end

  @doc """
  The selection path from the outermost ancestor down to `id` — what the canvas crumb bar renders.
  The React demo's crumb bar was static markup; this one is derived.
  """
  @spec path(t(), String.t()) :: [Node.t()]
  def path(tree, id) do
    case get(tree, id) do
      nil -> []
      node -> Enum.reverse([node | ancestors(tree, id)])
    end
  end

  @doc "Every descendant id of `id`, depth-first, excluding `id` itself."
  @spec descendant_ids(t(), String.t()) :: [String.t()]
  def descendant_ids(tree, id) do
    tree
    |> child_ids(id)
    |> Enum.flat_map(&[&1 | descendant_ids(tree, &1)])
  end

  @doc "Whether `maybe_descendant` sits anywhere beneath `id`."
  @spec descendant?(t(), String.t(), String.t()) :: boolean()
  def descendant?(tree, id, maybe_descendant),
    do: maybe_descendant in descendant_ids(tree, id)

  @doc """
  The document-order ADDRESS of `id` — sibling indices from the root, joined with dots (`"0.2.1"`).

  An id is minted by `MishkaCmsCore.Runtime.Authoring.Tree.Node.generate_id/0` and is therefore
  meaningful only inside the parse that minted it: two people with the same document open have two id
  spaces over identical structure. This is derived from the shape of the document alone, so both of
  them compute the same string for the same element — which is what anything outliving a parse has to
  anchor on. A review note is exactly that.

  Whitespace-only text nodes are counted, because the model keeps them and skipping them here would
  put this and `at_address/2` out of step with each other. That makes this address exact but not
  stable across a re-format — see `content_address/2` for the one that is.
  """
  @spec address(t(), String.t() | nil) :: String.t() | nil
  def address(tree, id) do
    case get(tree, id) do
      nil -> nil
      node -> tree |> chain(node, []) |> Enum.join(".")
    end
  end

  defp chain(tree, %Node{id: id, parent_id: nil}, acc), do: [index_of(tree, id) || 0 | acc]

  defp chain(tree, %Node{id: id, parent_id: parent_id}, acc),
    do: chain(tree, get(tree, parent_id), [index_of(tree, id) || 0 | acc])

  @doc """
  The id sitting at a document-order `address`, or `nil` when nothing is there any more.

  The inverse of `address/2`, and deliberately unforgiving: a segment that runs off the end of a
  child list answers `nil` rather than clamping to the nearest sibling. A caller wanting the nearest
  thing can ask for it; one that is silently handed a different element cannot tell.
  """
  @spec at_address(t(), String.t() | nil) :: String.t() | nil
  def at_address(_tree, nil), do: nil
  def at_address(_tree, ""), do: nil

  def at_address(tree, address) when is_binary(address) do
    address
    |> String.split(".", trim: true)
    |> Enum.reduce_while(:root, fn segment, parent ->
      with {index, ""} <- Integer.parse(segment),
           id when is_binary(id) <- tree |> child_ids(parent) |> Enum.at(index) do
        {:cont, id}
      else
        _gone -> {:halt, nil}
      end
    end)
    |> case do
      :root -> nil
      id -> id
    end
  end

  @doc """
  The address of `id` counting only the children that carry content — the one that survives a
  re-format.

  FORMATTING IS NOT STRUCTURE, but the model cannot tell them apart: `Serializer.to_heex/1` indents,
  and parsing that back turns every indent into a text node. A document written flat and read once
  through the serializer therefore gains a whitespace sibling before every element, and every
  `address/2` shifts by one — measured on `<div><h1>…` as `"0.0"` becoming `"0.1"`, then staying put
  forever after.

  So anything that has to find the same element on the far side of a HEEx round trip — restoring a
  snapshot is exactly that — anchors on this instead, where the indentation is not counted and the
  address does not move when the formatter runs.

  `nil` for a node that is itself only whitespace: formatting has no address of its own.
  """
  @spec content_address(t(), String.t() | nil) :: String.t() | nil
  def content_address(tree, id) do
    with %Node{} = node <- get(tree, id),
         chain when is_list(chain) <- content_chain(tree, node, []) do
      Enum.join(chain, ".")
    else
      _nowhere -> nil
    end
  end

  defp content_chain(tree, %Node{id: id, parent_id: nil}, acc) do
    case content_index(tree, :root, id) do
      nil -> nil
      index -> [index | acc]
    end
  end

  defp content_chain(tree, %Node{id: id, parent_id: parent_id}, acc) do
    with index when not is_nil(index) <- content_index(tree, parent_id, id),
         %Node{} = parent <- get(tree, parent_id) do
      content_chain(tree, parent, [index | acc])
    else
      _gone -> nil
    end
  end

  defp content_index(tree, parent, id) do
    tree |> content_ids(parent) |> Enum.find_index(&(&1 == id))
  end

  @doc """
  The id sitting at a `content_address/2`, or `nil` when nothing is there any more.

  As unforgiving as `at_address/2`: a segment past the end of a child list answers `nil` rather than
  clamping to the nearest sibling.
  """
  @spec at_content_address(t(), String.t() | nil) :: String.t() | nil
  def at_content_address(_tree, nil), do: nil
  def at_content_address(_tree, ""), do: nil

  def at_content_address(tree, address) when is_binary(address) do
    address
    |> String.split(".", trim: true)
    |> Enum.reduce_while(:root, fn segment, parent ->
      with {index, ""} <- Integer.parse(segment),
           id when is_binary(id) <- tree |> content_ids(parent) |> Enum.at(index) do
        {:cont, id}
      else
        _gone -> {:halt, nil}
      end
    end)
    |> case do
      :root -> nil
      id -> id
    end
  end

  @doc """
  Whether `address` names the same element in `before` and in `now`.

  AN INDEX ONLY MEANS SOMETHING WHEN BOTH DOCUMENTS AGREE ABOUT THE SHAPE. Delete the first of three
  `<li>`s and everything below slides up one, so the address that named the second now names the
  third — in bounds, same kind, same tag, and completely wrong. A position cannot tell you it has
  been handed a stranger, so the question has to be asked of the documents instead.

  The answer is yes when every step down the path has the same run of children, BY NAME, in both.
  Names and not contents on purpose: an element whose text, styles or attributes were edited is still
  the same element, and undoing exactly that edit is what a restore is for.

  So anything that changed only what is inside elements carries across, and anything that changed the
  document's shape does not — which is precisely when a position stops meaning anything.
  """
  @spec same_shape_at?(t(), t(), String.t() | nil) :: boolean()
  def same_shape_at?(_before, _now, nil), do: false

  def same_shape_at?(before, now, address) when is_binary(address) do
    shape_walk(before, now, :root, :root, String.split(address, ".", trim: true))
  end

  defp shape_walk(_before, _now, _in_before, _in_now, []), do: true

  defp shape_walk(before, now, in_before, in_now, [segment | rest]) do
    was = content_ids(before, in_before)
    is_now = content_ids(now, in_now)

    with true <- names(before, was) == names(now, is_now),
         {index, ""} <- Integer.parse(segment),
         true <- index >= 0,
         next_before when is_binary(next_before) <- Enum.at(was, index),
         next_now when is_binary(next_now) <- Enum.at(is_now, index) do
      shape_walk(before, now, next_before, next_now, rest)
    else
      _differs -> false
    end
  end

  defp names(tree, ids), do: Enum.map(ids, &named(get(tree, &1)))

  defp named(%Node{kind: :component, tag: tag} = node),
    do: {:component, tag, Node.attr(node, "component_name")}

  defp named(%Node{kind: kind, tag: tag}), do: {kind, tag}
  defp named(nil), do: nil

  defp content_ids(tree, parent) do
    tree |> child_ids(parent) |> Enum.filter(&content?(tree, &1))
  end

  # The same thing `blank?/2` asks, by the same flag the parser sets — with the text itself as a
  # fallback, so a tree assembled by hand rather than parsed still answers correctly.
  defp content?(tree, id) do
    case get(tree, id) do
      %Node{kind: :text, meta: %{whitespace?: true}} -> false
      %Node{kind: :text, text: text} -> String.trim(text || "") != ""
      %Node{} -> true
      nil -> false
    end
  end

  @doc "Every node, depth-first in document order."
  @spec walk(t()) :: [Node.t()]
  def walk(tree), do: Enum.flat_map(tree.roots, &walk_from(tree, &1))

  defp walk_from(tree, id) do
    case get(tree, id) do
      nil -> []
      node -> [node | Enum.flat_map(node.children, &walk_from(tree, &1))]
    end
  end

  @doc "The index of `id` among its siblings, or `nil` when it is not in the tree."
  @spec index_of(t(), String.t()) :: non_neg_integer() | nil
  def index_of(tree, id) do
    case get(tree, id) do
      nil -> nil
      node -> Enum.find_index(child_ids(tree, node.parent_id || :root), &(&1 == id))
    end
  end

  @doc """
  Inserts a node or a whole subtree under `parent` at `index`.

  `index` is clamped into the sibling list, so an out-of-range value appends rather than failing —
  a drop past the last child is a legitimate gesture, not an error. Fails when the parent is missing
  or cannot hold children.
  """
  @spec insert(t(), Node.t() | t(), parent(), non_neg_integer()) :: {:ok, t()} | error()
  def insert(tree, %Node{} = node, parent, index),
    do: insert(tree, %__MODULE__{nodes: %{node.id => node}, roots: [node.id]}, parent, index)

  def insert(tree, %__MODULE__{} = subtree, parent, index) do
    parent = settle_root(tree, parent)

    with :ok <- validate_parent(tree, parent) do
      parent_id = parent_id(parent)

      incoming =
        Map.new(subtree.nodes, fn {id, node} -> {id, reparent(node, subtree, parent_id)} end)

      siblings = child_ids(tree, parent)

      {:ok,
       %{tree | nodes: Map.merge(tree.nodes, incoming)}
       |> put_children(parent, split_insert(siblings, subtree.roots, clamp(index, siblings)))}
    end
  end

  defp reparent(node, subtree, parent_id) do
    case node.id in subtree.roots do
      true -> %{node | parent_id: parent_id}
      false -> node
    end
  end

  defp split_insert(existing, new_ids, index) do
    {before, rest} = Enum.split(existing, index)
    before ++ new_ids ++ rest
  end

  defp clamp(index, list) when is_integer(index) and index >= 0,
    do: min(index, length(list))

  # A NEGATIVE INDEX MEANS THE CALLER COULD NOT FIND THE NODE, not that it belongs last. The canvas
  # computes a drop index with `indexOf`, which answers `-1` when the sibling it measured against is
  # not among the children it can see — every drag inside a runtime component's slot, because slot
  # children are rendered through the component's own markup and have no wrapper to be found in.
  # Sending that to the end of the list threw the node clean out of the slot it was dropped into.
  defp clamp(index, _list) when is_integer(index) and index < 0, do: 0

  defp clamp(_index, list), do: length(list)

  @doc """
  Moves `id` under `new_parent` at `index`.

  `index` is interpreted against the sibling list **with the moving node already removed**, which is
  the contract the React `moveElementInList` tests pinned down: a same-parent reorder from position
  2 to position 4 passes `4` and lands at `4`, with no caller-side off-by-one. Refuses to move a
  node into itself or into one of its own descendants.
  """
  @spec move(t(), String.t(), parent(), non_neg_integer()) :: {:ok, t()} | error()
  def move(tree, id, new_parent, index) do
    with :ok <- validate_present(tree, id),
         :ok <- validate_parent(tree, new_parent),
         :ok <- validate_not_self(tree, id, new_parent) do
      node = get(tree, id)
      detached = tree |> detach(node) |> put_node(%{node | parent_id: parent_id(new_parent)})
      siblings = child_ids(detached, new_parent)

      {:ok,
       put_children(detached, new_parent, split_insert(siblings, [id], clamp(index, siblings)))}
    end
  end

  @doc "Deletes `id` and everything beneath it."
  @spec delete(t(), String.t()) :: {:ok, t()} | error()
  def delete(tree, id) do
    with :ok <- validate_present(tree, id) do
      node = get(tree, id)
      doomed = [id | descendant_ids(tree, id)]

      {:ok,
       tree
       |> detach(node)
       |> Map.update!(:nodes, &Map.drop(&1, doomed))}
    end
  end

  @doc """
  Deep-copies `id` with fresh ids and inserts the copy immediately after the source — the v2
  demo's semantics. Returns the new tree and the copy's root id.
  """
  @spec duplicate(t(), String.t()) :: {:ok, t(), String.t()} | error()
  def duplicate(tree, id) do
    with :ok <- validate_present(tree, id),
         :ok <- refuse_document_root(tree, id) do
      node = get(tree, id)
      copy = tree |> subtree(id) |> refresh_ids()
      parent = node.parent_id || :root

      case insert(tree, copy, parent, (index_of(tree, id) || 0) + 1) do
        {:ok, tree} -> {:ok, tree, hd(copy.roots)}
        error -> error
      end
    end
  end

  @doc """
  Extracts `id` and its descendants as a standalone tree — the shape the clipboard stores and
  `insert/4` accepts back.
  """
  @spec subtree(t(), String.t()) :: t()
  def subtree(tree, id) do
    ids = [id | descendant_ids(tree, id)]
    nodes = Map.take(tree.nodes, ids)

    %__MODULE__{nodes: Map.update!(nodes, id, &%{&1 | parent_id: nil}), roots: [id]}
  end

  @doc """
  Binds every runtime component's `site` attribute to the scope that component actually lives in.

  The compiled module's name is hashed from this attribute, so it has to be right: a TENANT component
  belongs to `site`, and a GLOBAL one belongs to `"Global"` no matter whose page it is placed on.
  Rewriting both to the page's site — which an earlier version did, on the theory that the kit's
  hardcoded `site="Global"` was always wrong — named modules nobody had built, and every global
  component inserted from an example came out as the runtime's red "failed to render".

  `components` is the palette, whose entries know which they are. A component the palette has never
  heard of is left exactly as authored rather than guessed at, and so is a node with no `site` at all.
  """
  @spec rewrite_site(t(), String.t() | nil, [map()]) :: t()
  def rewrite_site(tree, site, components \\ [])

  def rewrite_site(%__MODULE__{} = tree, site, components) do
    scopes = Map.new(components, &{entry_name(&1), entry_scope(&1, site)})

    %{tree | nodes: Map.new(tree.nodes, fn {id, node} -> {id, put_site(node, scopes)} end)}
  end

  defp entry_name(entry), do: Map.get(entry, :name)

  defp entry_scope(entry, site) do
    case Map.get(entry, :global?, true) do
      true -> "Global"
      false -> site || "Global"
    end
  end

  defp put_site(%Node{kind: :component, attrs: attrs} = node, scopes) do
    with true <- List.keymember?(attrs, "site", 0),
         name when is_binary(name) <- Node.component_name(node),
         {:ok, scope} <- Map.fetch(scopes, name) do
      %{node | attrs: List.keyreplace(attrs, "site", 0, {"site", {:string, scope}})}
    else
      _leave_alone -> node
    end
  end

  defp put_site(node, _scopes), do: node

  @doc """
  Re-mints every id in a tree, keeping the structure. Used by duplicate and by paste, so a pasted
  subtree never collides with the ids already in the document.
  """
  @spec refresh_ids(t()) :: t()
  def refresh_ids(%__MODULE__{} = tree) do
    mapping = Map.new(tree.nodes, fn {id, _node} -> {id, Node.generate_id()} end)

    nodes =
      Map.new(tree.nodes, fn {id, node} ->
        fresh = %{
          node
          | id: mapping[id],
            parent_id: node.parent_id && mapping[node.parent_id],
            children: Enum.map(node.children, &mapping[&1])
        }

        {fresh.id, fresh}
      end)

    %__MODULE__{nodes: nodes, roots: Enum.map(tree.roots, &mapping[&1])}
  end

  @doc "Sets an attribute, preserving declaration order and replacing an existing one in place."
  @spec set_attr(t(), String.t(), String.t() | :root, term()) :: {:ok, t()} | error()
  def set_attr(tree, id, name, value) do
    with :ok <- validate_present(tree, id) do
      node = get(tree, id)
      held = scope(tree, id)

      {:ok,
       put_node(
         tree,
         %{node | attrs: upsert_attr(node.attrs, name, value)}
         |> lift_typed_class(name)
         |> keep_scope(name, held)
       )}
    end
  end

  # A MINTED SCOPE IS NOT ONE OF THE AUTHOR'S CLASSES, and typing in the class box must not be able
  # to take it away. `delete_attr(tree, id, "class")` has guarded it since the day it was minted —
  # `cleared_class/2` puts it back when something still names it — and `set_attr/4`, the writer the
  # author actually uses, had no such guard: the box shows `pb-0167f46c` on its own, which reads as
  # junk, and typing over it left the element with no handle at all.
  #
  # What that cost was silent and not local. The class is the key `ElementCss` writes rules against
  # AND the `to:` of every interaction aimed here — including one written on a DIFFERENT node, which
  # is how "open that dialog" is spelled. So editing a modal's class broke a button somewhere else on
  # the page, with nothing said and nothing to undo.
  #
  # Kept unconditionally rather than only when something names it, because the thing that names it
  # is not always in reach: `cleared_class/2` can ask the node's own attributes and no more, and the
  # button holding the reference is elsewhere in the tree. `drop_scope/2` stays the one remover.
  defp keep_scope(%Node{} = node, "class", held) when is_binary(held),
    do: %{node | attrs: add_classes(node.attrs, [held])}

  defp keep_scope(%Node{} = node, _name, _held), do: node

  # TYPING A CLASS AND PARSING ONE HAVE TO MEAN THE SAME THING. A class arriving from the page source
  # has its recognised utilities lifted into `meta.styles` by `extract_styles/1`. The same string
  # typed into the inspector was stored verbatim instead — and then the serializer, which rebuilds
  # the attribute from the authored part plus whatever `meta.styles` holds, dropped every utility it
  # recognised on the way out. Typing `items-center` deleted it, silently, with nothing to undo.
  #
  # Lifting merges rather than replaces, because the box shows only the authored half: the padding a
  # slider recorded is not in the text the author is editing, and retyping the box must not erase it.
  defp lift_typed_class(%Node{} = node, "class") do
    case List.keyfind(node.attrs, "class", 0) do
      {"class", {:string, class}} ->
        {authored, typed} = Styles.from_classes(class)

        %{
          node
          | attrs: put_class(node.attrs, authored),
            meta: Map.put(node.meta, :styles, merge_styles(node.meta[:styles] || %{}, typed))
        }

      _expression_or_missing ->
        node
    end
  end

  defp lift_typed_class(node, _name), do: node

  defp merge_styles(current, typed) do
    Map.merge(current, typed, fn _bucket, held, fresh -> Map.merge(held, fresh) end)
  end

  defp upsert_attr(attrs, name, value) do
    case Enum.any?(attrs, &match?({^name, _}, &1)) do
      true -> Enum.map(attrs, fn {n, v} -> if(n == name, do: {n, value}, else: {n, v}) end)
      false -> attrs ++ [{name, value}]
    end
  end

  @doc "Removes an attribute. An unset attribute serializes to nothing, restoring the default."
  @spec delete_attr(t(), String.t(), String.t() | :root) :: {:ok, t()} | error()
  def delete_attr(tree, id, "class") do
    with :ok <- validate_present(tree, id) do
      node = get(tree, id)
      {:ok, put_node(tree, %{node | attrs: cleared_class(node, scope(tree, id))})}
    end
  end

  def delete_attr(tree, id, name) do
    with :ok <- validate_present(tree, id) do
      node = get(tree, id)
      {:ok, put_node(tree, %{node | attrs: Enum.reject(node.attrs, &match?({^name, _}, &1))})}
    end
  end

  # THE SCOPE CLASS IS NOT THE AUTHOR'S TO DELETE BY ACCIDENT. A minted `pb-xxxxxxxx` is the key the
  # element's own CSS rule is written against and the handle an interaction's `JS.toggle_class` points
  # at — so clearing the class row took both with it, silently: the Custom CSS box went blank and a
  # working click stopped working, with nothing said.
  #
  # It survives only while something still names it, which is the rule `drop_scope/2` already
  # follows; when nothing does, the row clears completely as the author asked.
  #
  # AND WHAT SURVIVES WITH IT IS THE AUTHOR'S EXPRESSION. Rebuilding the row as the bare name turned
  # `class={[@variant, "pb-…"]}` into the string `class="pb-…"`, so the branch whose whole purpose
  # is that the row does NOT clear took the computed class with it. Only the classes go.
  defp cleared_class(%Node{} = node, held) when is_binary(held) do
    case Enum.any?(node.attrs, &names_scope?(&1, held)) do
      true -> drop_classes(node.attrs, classes(node) -- [held])
      false -> Enum.reject(node.attrs, &match?({"class", _}, &1))
    end
  end

  defp cleared_class(%Node{} = node, _held),
    do: Enum.reject(node.attrs, &match?({"class", _}, &1))

  @doc "Replaces a node's text content."
  @spec set_text(t(), String.t(), String.t()) :: {:ok, t()} | error()
  def set_text(tree, id, text) when is_binary(text) do
    with :ok <- validate_present(tree, id) do
      node = get(tree, id)
      {:ok, put_node(tree, %{node | text: text, meta: Map.delete(node.meta, :whitespace?)})}
    end
  end

  @doc """
  The class that names this element for its own CSS, or `nil` when it has none yet.

  A minted class rather than an id: it goes in the `class` attribute like everything else, so it
  survives copy, duplicate and paste with the node, and `MishkaCmsCore.Runtime.Authoring.ElementCss`
  can key a rule on it without the editor needing to store anything that a re-parse would lose.
  """
  @spec scope(t(), String.t()) :: String.t() | nil
  def scope(tree, id) do
    case get(tree, id) do
      nil -> nil
      node -> node |> scopes_of() |> List.first()
    end
  end

  @doc """
  Leaves each element wearing one minted class, for markup that arrives wearing two.

  Paste styles used to carry the SOURCE element's minted class onto the target, so every document
  saved before that was fixed holds elements wearing somebody else's name ahead of their own — and
  `scope/2` answers with the first, which is what points the target's CSS box, its Apply and every
  interaction aimed at it at the source's rule, and what takes the target's own rule out of
  `MishkaCmsCore.Runtime.Authoring.ElementCss.live_rules/2` for the next save to prune away.

  The name it keeps is the one no other element in the document wears: a pasted name is on at least
  two elements and an element's own is on one, which is the whole of what that paste left behind.
  When that singles out none — two elements duplicated after such a paste wear the same pair — the
  markup no longer says which name was whose, and nothing is taken off.

  Run when a document is OPENED rather than on every parse: the runtime renders this markup too, and
  a name silently different from the one the stylesheet was compiled against is a live page losing
  its styling. In the editor the next save writes the answer back.
  """
  @spec unshare_scopes(t()) :: t()
  def unshare_scopes(tree) do
    nodes = walk(tree)
    worn = nodes |> Enum.flat_map(&Enum.uniq(scopes_of(&1))) |> Enum.frequencies()

    Enum.reduce(nodes, tree, fn node, acc -> unshare_scope(acc, node, worn) end)
  end

  defp unshare_scope(tree, %Node{} = node, worn) do
    case Enum.uniq(scopes_of(node)) do
      [_, _ | _] = shared ->
        keep_own_scope(tree, node, shared, Enum.filter(shared, &(worn[&1] == 1)))

      _own_or_none ->
        tree
    end
  end

  defp keep_own_scope(tree, %Node{} = node, shared, [own]),
    do: put_node(tree, %{node | attrs: drop_classes(node.attrs, shared -- [own])})

  defp keep_own_scope(tree, _node, _shared, _cannot_tell), do: tree

  defp scopes_of(%Node{} = node), do: node |> classes() |> Enum.filter(&ElementScopes.scope?/1)

  @doc "Gives the node a scope class if it has none, and returns it with the tree."
  @spec ensure_scope(t(), String.t()) :: {t(), String.t()} | {t(), nil}
  def ensure_scope(tree, id) do
    case {get(tree, id), scope(tree, id)} do
      {nil, _held} -> {tree, nil}
      {_node, held} when is_binary(held) -> {tree, held}
      {node, nil} -> mint_scope(tree, node)
    end
  end

  @doc "Takes the scope class off, for an element whose custom CSS has been cleared."
  @spec drop_scope(t(), String.t()) :: t()
  def drop_scope(tree, id) do
    case {get(tree, id), scope(tree, id)} do
      {%Node{} = node, held} when is_binary(held) ->
        drop_unless_referenced(tree, node, held)

      _nothing ->
        tree
    end
  end

  # THE SCOPE CLASS IS ALSO A HANDLE, not only a CSS key. An interaction on this node compiles to
  # `JS.toggle_class("is-open", to: ".pb-7f3a91b2")` — the same class — so taking it off because the
  # custom CSS box is now empty would leave that command pointing at nothing, silently. It stays for
  # as long as anything else on the node still names it.
  defp drop_unless_referenced(tree, %Node{} = node, held) do
    case Enum.any?(node.attrs, &names_scope?(&1, held)) do
      true -> tree
      false -> put_node(tree, %{node | attrs: drop_classes(node.attrs, [held])})
    end
  end

  defp names_scope?({"class", _value}, _held), do: false

  defp names_scope?({_name, {_kind, value}}, held) when is_binary(value),
    do: String.contains?(value, held)

  # AN ATTRIBUTE'S VALUE IS NOT ALWAYS A TAGGED TUPLE. `set_attr/4` stores an expression as a bare
  # string, which is exactly the shape an interaction is written in — so the reference this guard
  # exists to find was the one shape it could not see, and the scope class it protects was dropped
  # out from under a working `JS.toggle_class`.
  defp names_scope?({_name, value}, held) when is_binary(value),
    do: String.contains?(value, held)

  defp names_scope?(_attr, _held), do: false

  # The id is already unique within the document and is what the editor points at everywhere else,
  # so hashing it keeps two elements from ever sharing a rule without a counter to keep.
  #
  # READ BACK RATHER THAN ASSUMED: a name the author's own expression could not be given is not one
  # this element answers to, and handing it out anyway keys a CSS rule and an interaction's `to:` to
  # a class that is nowhere on the page.
  defp mint_scope(tree, node) do
    scope = "pb-" <> (:erlang.md5(node.id) |> Base.encode16(case: :lower) |> binary_part(0, 8))
    tree = put_node(tree, %{node | attrs: add_classes(node.attrs, [scope])})

    {tree, scope(tree, node.id)}
  end

  @doc """
  The literal classes an element wears, in the order they were written.

  A CLASS HELD IN A LIST EXPRESSION IS ONE OF THEM. `class={[@variant, "pb-0167f46c"]}` is the shape
  a scope is minted into when the author's class is an expression — the only shape that can name the
  element without writing the literal text `@variant` over the value it works out at render time —
  and reading the string form alone answered `nil` over a name that was right there: the element's
  own rule fell out of `MishkaCmsCore.Runtime.Authoring.ElementCss.live_rules/2` for the next save
  to prune away, and `ensure_scope/2` minted a second name beside the first on every visit to the
  CSS box.

  So this is what every reader of an element's classes asks, in the panels as much as in here. What
  the author works out at render time is not a class and is not answered.
  """
  @spec classes(Node.t()) :: [String.t()]
  def classes(%Node{} = node), do: attr_classes(node.attrs)

  defp attr_classes(attrs) do
    case List.keyfind(attrs, "class", 0) do
      {"class", {:string, value}} -> split_classes(value)
      {"class", {:expr, source}} -> expr_classes(source)
      _none -> []
    end
  end

  defp expr_classes(source) do
    case Styles.list_parts(source) do
      :not_a_list -> []
      parts -> Enum.flat_map(parts, &part_classes/1)
    end
  end

  defp part_classes({:classes, classes}), do: classes
  defp part_classes({:logic, _source}), do: []

  defp split_classes(value), do: String.split(value, ~r/\s+/, trim: true)

  @doc """
  The `class` value an element would carry with `classes` on it, as the `{kind, source}` pair
  `set_attr/4` takes.

  THE PANELS WRITE CLASSES TOO, and a class row rebuilt as one joined string is how the reusable
  classes list and the Behavior switches used to write `class={[@variant, "pb-…"] brand-card}` — the
  expression's own source turned into text beside a class, which is not Elixir and not a page that
  compiles. They ask for the value here instead, so an expression is spliced into exactly as a
  minted scope is.

  A class the element already wears is not added twice.
  """
  @spec class_with(Node.t(), [String.t()]) :: {:string | :expr, String.t()}
  def class_with(%Node{} = node, classes), do: class_value(add_classes(node.attrs, classes))

  @doc """
  The same, with `classes` taken off — `{:string, ""}` when nothing of the class is left, which is
  the editor's spelling of "remove the attribute".
  """
  @spec class_without(Node.t(), [String.t()]) :: {:string | :expr, String.t()}
  def class_without(%Node{} = node, classes), do: class_value(drop_classes(node.attrs, classes))

  defp class_value(attrs) do
    case List.keyfind(attrs, "class", 0) do
      {"class", {kind, source}} when kind in [:string, :expr] -> {kind, source}
      _gone -> {:string, ""}
    end
  end

  @doc """
  Records one responsive/pseudo style override on a node.

  Overrides live in `meta.styles` as `%{bucket => %{prop => value}}` where a bucket is `:base`,
  `:tablet`, `:mobile`, `:hover`, `:focus` or `:active`. They are compiled into Tailwind utilities
  on save (ADR-8) rather than written as inline styles, so the runtime Tailwind pass — which only
  sees server-rendered classes — can generate the rules.
  """
  @spec set_style(t(), String.t(), atom(), String.t(), String.t() | nil) :: {:ok, t()} | error()
  def set_style(tree, id, bucket, prop, value) do
    with :ok <- validate_present(tree, id) do
      node = get(tree, id)
      styles = Map.get(node.meta, :styles, %{})

      # Dropping what the new value orphans is part of the SAME write, so it is one undoable step and
      # every writer gets it — see `Styles.dependents/2`.
      bucket_styles =
        styles
        |> Map.get(bucket, %{})
        |> put_or_drop(prop, value)
        |> Map.drop(Styles.dependents(prop, value))

      {:ok,
       put_node(tree, %{
         node
         | attrs: important_variants(node, prop, value),
           meta: Map.put(node.meta, :styles, prune(styles, bucket, bucket_styles))
       })}
    end
  end

  # A COMPONENT'S OVERRIDE IS WRITTEN IMPORTANT, so the author's variants of the same property are
  # made important in the same write — see `Styles.with_important_variants/2`. Only when the editor
  # sets a value: a class nobody touched is never given a bang.
  defp important_variants(%Node{kind: kind, attrs: attrs}, prop, value)
       when kind in [:component, :slot] and not is_nil(value) do
    case List.keyfind(attrs, "class", 0) do
      {"class", {:string, class}} -> important_string_class(attrs, split_classes(class), prop)
      {"class", {:expr, source}} -> important_expr_class(attrs, Styles.list_parts(source), prop)
      _none -> attrs
    end
  end

  defp important_variants(%Node{attrs: attrs}, _prop, _value), do: attrs

  defp important_string_class(attrs, classes, prop) do
    case Styles.with_important_variants(classes, prop) do
      ^classes -> attrs
      important -> put_class(attrs, important)
    end
  end

  defp important_expr_class(attrs, :not_a_list, _prop), do: attrs

  defp important_expr_class(attrs, parts, prop) do
    case Enum.map(parts, &important_part(&1, prop)) do
      ^parts -> attrs
      important -> put_expr_class(attrs, Styles.list_expr(important))
    end
  end

  defp important_part({:classes, classes}, prop),
    do: {:classes, Styles.with_important_variants(classes, prop)}

  defp important_part(logic, _prop), do: logic

  defp put_or_drop(map, prop, nil), do: Map.delete(map, prop)
  defp put_or_drop(map, prop, value), do: Map.put(map, prop, value)

  defp prune(styles, bucket, bucket_styles) when map_size(bucket_styles) == 0,
    do: Map.delete(styles, bucket)

  defp prune(styles, bucket, bucket_styles), do: Map.put(styles, bucket, bucket_styles)

  @doc "Clears every override recorded in one bucket — the inspector's per-bucket Reset."
  @spec reset_styles(t(), String.t(), atom()) :: {:ok, t()} | error()
  def reset_styles(tree, id, bucket) do
    with :ok <- validate_present(tree, id) do
      node = get(tree, id)
      styles = node.meta |> Map.get(:styles, %{}) |> Map.delete(bucket)
      {:ok, put_node(tree, %{node | meta: Map.put(node.meta, :styles, styles)})}
    end
  end

  @doc "Wraps `id` in `wrapper`, which takes the node's place among its siblings."
  @spec wrap(t(), String.t(), Node.t()) :: {:ok, t()} | error()
  def wrap(tree, id, %Node{} = wrapper) do
    with :ok <- validate_present(tree, id),
         :ok <- refuse_document_root(tree, id) do
      node = get(tree, id)
      parent = node.parent_id || :root
      index = index_of(tree, id) || 0

      with {:ok, tree} <- insert(tree, %{wrapper | children: []}, parent, index) do
        move(tree, id, wrapper.id, 0)
      end
    end
  end

  @doc """
  Wraps several siblings in one container, which takes the place of the first of them.

  SIBLINGS ONLY. Three cards in a row have an obvious container; a heading here and a button two
  branches away do not, and inventing one would move them somewhere neither of them was. The
  document order of the selection is kept, not the order they were clicked in.
  """
  @spec wrap_many(t(), [String.t()], Node.t()) :: {:ok, t()} | error()
  def wrap_many(tree, [id], %Node{} = wrapper), do: wrap(tree, id, wrapper)

  def wrap_many(tree, ids, %Node{} = wrapper) when is_list(ids) do
    with :ok <- all_present(tree, ids),
         {:ok, parent} <- common_parent(tree, ids) do
      ordered = Enum.sort_by(ids, &(index_of(tree, &1) || 0))

      with {:ok, tree} <-
             insert(tree, %{wrapper | children: []}, parent, index_of(tree, hd(ordered)) || 0) do
        move_all(tree, ordered, wrapper.id)
      end
    end
  end

  def wrap_many(_tree, _ids, _wrapper), do: {:error, :unknown_node}

  defp all_present(tree, ids) do
    Enum.find_value(ids, :ok, fn id ->
      case get(tree, id) do
        nil -> {:error, :unknown_node}
        _node -> nil
      end
    end)
  end

  defp common_parent(tree, ids) do
    case ids |> Enum.map(&(get(tree, &1).parent_id || :root)) |> Enum.uniq() do
      [parent] -> {:ok, parent}
      _several -> {:error, :not_siblings}
    end
  end

  defp move_all(tree, ids, parent) do
    ids
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, tree}, fn {id, at}, {:ok, acc} ->
      case move(acc, id, parent, at) do
        {:ok, moved} -> {:cont, {:ok, moved}}
        error -> {:halt, error}
      end
    end)
  end

  @doc "Removes `id`, promoting its children into its place."
  @spec unwrap(t(), String.t()) :: {:ok, t()} | error()
  def unwrap(tree, id) do
    with :ok <- validate_present(tree, id),
         :ok <- refuse_document_root(tree, id) do
      node = get(tree, id)
      parent = node.parent_id || :root
      index = index_of(tree, id) || 0

      # A REFUSED CHILD USED TO BE A DELETED ONE. Skipping the ones that would not move left them
      # inside `id` — and the next line removes `id` and everything still beneath it, so "take the
      # wrapper off" quietly became "take the wrapper and its contents off", as one step, answering
      # `{:ok, tree}`. A wrapper that stays is recoverable; a subtree that is gone is not.
      node.children
      |> Enum.reduce_while({:ok, {tree, index}}, fn child_id, {:ok, {acc, at}} ->
        case move(acc, child_id, parent, at) do
          {:ok, moved} -> {:cont, {:ok, {moved, at + 1}}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, {promoted, _next}} -> delete(promoted, id)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp validate_present(tree, id) do
    case get(tree, id) do
      nil -> {:error, :unknown_node}
      _node -> :ok
    end
  end

  # `:root` IS NOT A PLACE IN A DOCUMENT-ROOTED TREE. A layout's roots are one `<body>`, so content
  # aimed at the root belongs INSIDE it — everything else is markup after `</body>`. Both clients
  # hardcode `"root"` for a drop on empty canvas and for the layers rail's top row, and
  # `Placement.after_node/2` answers `{:root, index + 1}` for a paste beside the body, so the answer
  # has to be given here, in the one funnel all of them reach, rather than at each door.
  defp settle_root(tree, :root) do
    case document_root(tree) do
      nil -> :root
      node -> node.id
    end
  end

  defp settle_root(_tree, parent), do: parent

  # And the document element itself is not content: wrapping it produced `<div><body>…</body></div>`
  # and duplicating it produced a layout with two bodies.
  defp refuse_document_root(tree, id) do
    case document_root(tree) do
      %Node{id: ^id} -> {:error, :document_root}
      _other -> :ok
    end
  end

  defp document_root(%__MODULE__{roots: [id]} = tree) do
    case get(tree, id) do
      %Node{} = node -> (Node.document?(node) && node) || nil
      _absent -> nil
    end
  end

  defp document_root(_tree), do: nil

  defp validate_parent(_tree, :root), do: :ok

  defp validate_parent(tree, id) do
    case get(tree, id) do
      nil -> {:error, :invalid_parent}
      node -> if Node.container?(node), do: :ok, else: {:error, :invalid_parent}
    end
  end

  defp validate_not_self(_tree, _id, :root), do: :ok

  defp validate_not_self(tree, id, new_parent) do
    case new_parent == id or descendant?(tree, id, new_parent) do
      true -> {:error, :cyclic_move}
      false -> :ok
    end
  end

  defp parent_id(:root), do: nil
  defp parent_id(id), do: id

  defp put_node(tree, node), do: %{tree | nodes: Map.put(tree.nodes, node.id, node)}

  defp put_children(tree, :root, ids), do: %{tree | roots: ids}

  defp put_children(tree, parent_id, ids) do
    case get(tree, parent_id) do
      nil -> tree
      node -> put_node(tree, %{node | children: ids})
    end
  end

  defp detach(tree, node) do
    parent = node.parent_id || :root
    put_children(tree, parent, List.delete(child_ids(tree, parent), node.id))
  end

  defp from_tokens(tokens) do
    {roots, nodes} = build_nodes(tokens, nil, %{})
    %__MODULE__{nodes: nodes, roots: roots}
  end

  defp build_nodes(tokens, parent_id, nodes) do
    {ids, nodes} =
      Enum.reduce(tokens, {[], nodes}, fn token, {ids, acc} ->
        {node, acc} = build_node(token, parent_id, acc)
        {[node.id | ids], acc}
      end)

    {Enum.reverse(ids), nodes}
  end

  defp build_node({:tag_block, tag, attrs, children, meta}, parent_id, nodes) do
    id = Node.generate_id()
    {child_ids, nodes} = build_nodes(children, id, nodes)
    kind = tag_kind(tag)
    {node_attrs, styles} = attrs |> normalize_attrs() |> extract_styles(kind)

    node = %Node{
      id: id,
      kind: kind,
      tag: tag,
      attrs: node_attrs,
      children: child_ids,
      parent_id: parent_id,
      meta: %{mode: Map.get(meta, :mode, :normal), styles: styles}
    }

    {node, Map.put(nodes, id, node)}
  end

  defp build_node({:tag_self_close, tag, attrs}, parent_id, nodes) do
    kind = tag_kind(tag)
    {node_attrs, styles} = attrs |> normalize_attrs() |> extract_styles(kind)

    node =
      Node.new(kind,
        tag: tag,
        attrs: node_attrs,
        parent_id: parent_id,
        meta: %{self_close: true, styles: styles}
      )

    {node, Map.put(nodes, node.id, node)}
  end

  defp build_node({:text, text, _meta}, parent_id, nodes) do
    node =
      Node.new(:text,
        text: text,
        parent_id: parent_id,
        meta: %{whitespace?: String.trim(text) == ""}
      )

    {node, Map.put(nodes, node.id, node)}
  end

  defp build_node({:body_expr, expr, _meta}, parent_id, nodes) do
    node = Node.new(:eex, text: expr, parent_id: parent_id, meta: %{form: :body})
    {node, Map.put(nodes, node.id, node)}
  end

  defp build_node({:eex, expr, meta}, parent_id, nodes) do
    node =
      Node.new(:eex,
        text: expr,
        parent_id: parent_id,
        meta: %{form: :eex, opt: Map.get(meta, :opt, ~c"=")}
      )

    {node, Map.put(nodes, node.id, node)}
  end

  defp build_node({:eex_comment, text}, parent_id, nodes) do
    node = Node.new(:eex_comment, text: text, parent_id: parent_id)
    {node, Map.put(nodes, node.id, node)}
  end

  defp build_node({:html_comment, children}, parent_id, nodes) do
    node = Node.new(:html_comment, text: comment_text(children), parent_id: parent_id)
    {node, Map.put(nodes, node.id, node)}
  end

  # ADR-9: a block is atomic. Its source is reconstructed from the tuple tree — the tokenizer
  # records only the block's opening position, so there is no end offset to slice against — and
  # re-emitted verbatim on serialize, which is what keeps the historic double-encoded-JSON and
  # four-tuple crash classes out of the model entirely.
  defp build_node({:eex_block, expr, block, _meta}, parent_id, nodes) do
    node =
      Node.new(:eex_block,
        text: expr,
        parent_id: parent_id,
        meta: %{source: block_source(expr, block)}
      )

    {node, Map.put(nodes, node.id, node)}
  end

  # The tokenizer hands an HTML comment back with its own `<!--` / `-->` still attached (it slices
  # the raw run), so the delimiters are stripped here and re-added by the serializer. Keeping them
  # in `text` would nest a fresh pair on every save.
  # Overrides live in `meta.styles` while editing and as Tailwind utilities in the template. Lifting
  # them out on parse is what lets the inspector show the real recorded state of a saved page rather
  # than an empty panel over classes it cannot read.
  # THE KIND DECIDES WHETHER A BANG IS OURS. `to_classes/2` writes `p-[8px]!` for a component and a
  # slot, because an override there has to beat the kit's own rules from inside its template; on a
  # plain tag it writes `p-[8px]`. Reading has to make the same distinction or a component's
  # override is never lifted — written, replaced correctly, and shown as empty ever after.
  defp extract_styles(attrs, kind) do
    opts = [important?: kind in [:component, :slot]]

    case List.keyfind(attrs, "class", 0) do
      {"class", {:string, class}} ->
        {authored, styles} = Styles.from_classes(class, opts)
        {put_class(attrs, authored), styles}

      # A LIST IS A CLASS TOO, and it is the shape the HEEx guidance asks for and every kit
      # component uses — so it is where an override actually lands. Reading only the string form
      # made the round trip one-way: the serializer appended the utility and the next parse could
      # not see it, so a second edit nested another list and kept the first value.
      {"class", {:expr, source}} ->
        case Styles.split_list_expr(source, opts) do
          :not_a_list -> {attrs, %{}}
          {parts, styles} -> {put_expr_class(attrs, Styles.list_expr(parts)), styles}
        end

      _other ->
        {attrs, %{}}
    end
  end

  # ADDING A CLASS MUST NOT COST THE AUTHOR THE ONE THEY WROTE. Every minted `pb-xxxxxxxx` arrives
  # through here, and rebuilding the attribute as a string from the classes read out of it put the
  # literal text `@variant` on the element — the value a component works out at render time, gone,
  # for the price of opening its Custom CSS box.
  #
  # So the name joins the expression instead, through the one splice `Serializer.computed_class/4`
  # also writes its utilities with. A string class is still a string class — a list there would be a
  # diff on every element the editor names.
  #
  # An expression `Styles.add_expr_classes/2` cannot write is left exactly as it was: an element
  # without a name loses a rule, and markup the page will not compile from loses the page.
  defp add_classes(attrs, classes) do
    case classes -- attr_classes(attrs) do
      [] -> attrs
      fresh -> put_fresh_classes(attrs, fresh)
    end
  end

  defp put_fresh_classes(attrs, fresh) do
    case List.keyfind(attrs, "class", 0) do
      {"class", {:expr, source}} -> put_spliced_class(attrs, source, fresh)
      {"class", {:string, value}} -> put_class(attrs, split_classes(value) ++ fresh)
      _none -> put_class(attrs, fresh)
    end
  end

  defp put_spliced_class(attrs, source, fresh) do
    case Styles.add_expr_classes(source, fresh) do
      nil -> attrs
      spliced -> put_expr_class(attrs, spliced)
    end
  end

  # And taking one off is the same trip back: a name this element has given up comes out of the list
  # it was spliced into, leaving the author's own elements where they were.
  defp drop_classes(attrs, gone) do
    case List.keyfind(attrs, "class", 0) do
      {"class", {:expr, source}} -> put_expr_class(attrs, drop_expr_classes(source, gone))
      {"class", {:string, value}} -> put_class(attrs, split_classes(value) -- gone)
      _none -> attrs
    end
  end

  defp drop_expr_classes(source, gone) do
    case Styles.list_parts(source) do
      :not_a_list -> source
      parts -> parts |> Enum.map(&drop_part_classes(&1, gone)) |> Styles.list_expr()
    end
  end

  defp drop_part_classes({:classes, classes}, gone), do: {:classes, classes -- gone}
  defp drop_part_classes({:logic, _source} = part, _gone), do: part

  # Nothing of the author's left means the attribute goes, the same as an emptied string class.
  defp put_expr_class(attrs, nil), do: List.keydelete(attrs, "class", 0)

  defp put_expr_class(attrs, source),
    do: List.keyreplace(attrs, "class", 0, {"class", {:expr, source}})

  defp put_class(attrs, []), do: List.keydelete(attrs, "class", 0)

  # UPSERT, NOT REPLACE. `keyreplace` alone is a no-op when the key is absent, so giving a scope
  # class to an element that had no `class` at all wrote nothing and the rule keyed on it could
  # never match. Every other caller reaches here with the attribute already present, which is why
  # it went unnoticed.
  defp put_class(attrs, authored) do
    class = {"class", {:string, Enum.join(authored, " ")}}

    case List.keymember?(attrs, "class", 0) do
      true -> List.keyreplace(attrs, "class", 0, class)
      false -> attrs ++ [class]
    end
  end

  defp comment_text(children) do
    children
    |> Enum.map_join("", fn
      {:text, text, _meta} -> text
      other -> inspect(other)
    end)
    |> String.replace_prefix("<!--", "")
    |> String.replace_suffix("-->", "")
  end

  defp block_source(expr, block) do
    IO.iodata_to_binary([
      "<%= ",
      expr,
      " %>",
      Enum.map(block, fn {children, clause} ->
        [Enum.map(children, &token_source/1), "<% ", clause, " %>"]
      end)
    ])
  end

  defp token_source({:tag_block, tag, attrs, children, _meta}),
    do: ["<", tag, attrs_source(attrs), ">", Enum.map(children, &token_source/1), "</", tag, ">"]

  defp token_source({:tag_self_close, tag, attrs}), do: ["<", tag, attrs_source(attrs), " />"]
  defp token_source({:text, text, _meta}), do: text
  defp token_source({:body_expr, expr, _meta}), do: ["{", expr, "}"]
  defp token_source({:eex, expr, %{opt: []}}), do: ["<% ", expr, " %>"]
  defp token_source({:eex, expr, _meta}), do: ["<%= ", expr, " %>"]
  defp token_source({:eex_comment, text}), do: ["<%!--", text, "--%>"]
  defp token_source({:html_comment, children}), do: ["<!--", comment_text(children), "-->"]

  defp token_source({:eex_block, expr, block, _meta}), do: block_source(expr, block)

  defp attrs_source([]), do: ""

  defp attrs_source(attrs) do
    [" ", Enum.map_join(attrs, " ", &attr_source/1)]
  end

  defp attr_source({:root, {:expr, value, _vmeta}, _ameta}), do: ["{", value, "}"]
  defp attr_source({name, {:string, value, _vmeta}, _ameta}), do: [name, ~s(="), value, ~s(")]
  defp attr_source({name, {:expr, value, _vmeta}, _ameta}), do: [name, "={", value, "}"]
  defp attr_source({name, _value, _meta}), do: name

  defp normalize_attrs(attrs), do: Enum.map(attrs, &normalize_attr/1)

  defp normalize_attr({name, {:string, value, _vmeta}, _ameta}),
    do: {name, {:string, Node.unescape_attr(value)}}

  defp normalize_attr({name, {:expr, value, _vmeta}, _ameta}), do: {name, {:expr, value}}
  defp normalize_attr({name, nil, _meta}), do: {name, :boolean}

  defp tag_kind("." <> _rest), do: :component
  defp tag_kind(":" <> _rest), do: :slot
  defp tag_kind(<<first, _rest::binary>>) when first in ?A..?Z, do: :component
  defp tag_kind(_tag), do: :tag
end
