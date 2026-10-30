# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.Containment do
  @moduledoc """
  The one authority on "may this node go inside that one" — the HTML content model plus the
  component/slot rules, in Elixir, on the server.

  The React editor spread this over four competing lists in three files and only ever consulted them
  in the browser, so a tampered payload (or the structure tree, which used a different list than the
  canvas) could build markup no parser would accept. Here the client gets a **hint** — an `accepts`
  map precomputed per node for instant drag feedback — and the server re-checks every insert and
  every move before it mutates anything. Client hints, server decides (ADR-6).

  ## The rules

    * **Void elements** (`br`, `img`, `input`, …) take no children at all.
    * **Phrasing-only elements** (`span`, `a`, `p`, `h1`–`h6`, `button`, `pre`, …) take text and
      other phrasing content, never a block element. This is deliberately stricter than the spec —
      `<p>` may legally hold some things this rejects — because the stricter rule is the one that
      matches what an author means to build. Ported from `containment.js`, with one correction: a
      paragraph, a heading and the other text blocks hold phrasing content without BEING it, so
      none of them goes inside another one or inside a link.
    * **Structural pairs** the spec fixes exactly: a `table` section takes only `tr`, a `tr` takes
      only `td`/`th`, a list takes only `li`, a `dl` takes `dt`/`dd`/`div`, a `select` takes
      `option`/`optgroup`.
    * **Anchors** may not contain another interactive element — nested interactive content is
      invalid and unusable with a keyboard.
    * **Components and slots** accept children when their metadata declares a slot (or when they
      already hold content, which means a previous author put something there legitimately). A
      dotted tag the kit catalog has never heard of is asked of the compiled module instead, so the
      CMS's own `<.form>` and `<.input>` are containers here the same way they are on the page.
    * **A component is the element its own markup opens with** for the phrasing and landmark
      rules: a kit navbar whose markup is one `<nav>` is a `<nav>`, a kit heading is a heading. A
      component whose markup opens with something else, or that has no markup to read, stays
      opaque and is let through as before.
    * **A form may not go inside a form**, and nothing HTML forbids at silently. What counts as a
      form is `MishkaCmsCore.Runtime.Authoring.Fields.form_node?/2`, the same answer the insert
      funnel and the audit rail take, so a kit's own form wrapper is one here too. The thing being
      dragged is asked about with everything under it, because a Block opens with a band tag and
      carries its form as a child.
    * **Landmarks keep out of each other**: a `<header>` or a `<footer>` holds no header, footer or
      `<main>`, and a `<main>` goes in no article, aside, header, footer or nav — HTML's own rules.
      A `<nav>` holds no header, footer or main either, which is stricter than the spec and is what
      a page footer clicked in while the navbar was selected needs. Asked of every ancestor, like
      the form rule.

  Every refusal carries a sentence written for the person dragging, which the canvas shows as the
  demo's danger toast near the drop point.

  A field that lands with no form around it is not refused: see
  `MishkaCmsCore.Runtime.Authoring.PageForms.FormPlacement`, which wraps it instead. Building a
  form top-down is an ordinary gesture, so only the nesting HTML itself forbids is an error here.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.Authoring.Fields
  alias MishkaCmsCore.Runtime.Authoring.Inspector
  alias MishkaCmsCore.Runtime.Authoring.Tree
  alias MishkaCmsCore.Runtime.Authoring.Tree.Node

  @void ~w(area base br col embed hr img input link meta param source track wbr)

  @phrasing_only ~w(
    a span b i em strong small code label sub sup mark abbr cite q s u kbd samp var
    time bdi bdo p h1 h2 h3 h4 h5 h6 button summary legend dt figcaption pre
  )

  # TAKING PHRASING CONTENT IS NOT BEING IT. These hold inline content only, which is why they are in
  # the list above, and are blocks themselves, which the list above cannot say: reading it both ways
  # let a paragraph clicked in while a heading was selected become the heading's child, and a `<p>`
  # inside an `<h1>` (or another `<p>`, which the parser closes on the spot) is markup no page means.
  @text_blocks ~w(p h1 h2 h3 h4 h5 h6 pre summary legend dt figcaption)

  # WHAT A LANDMARK MAY NOT HOLD, by the landmark. `header`, `footer` and `main` are HTML's own:
  # header and footer take no header, footer or main, and main goes in no article, aside, header,
  # footer or nav. `nav` refusing the first three is this editor's, stricter than the spec, for the
  # same reason the phrasing rule is: a page footer inside the navigation bar is valid markup and is
  # never what the author clicking it in meant.
  @landmark_bars %{
    "header" => ~w(header footer main),
    "footer" => ~w(header footer main),
    "nav" => ~w(header footer main),
    "article" => ~w(main),
    "aside" => ~w(main)
  }

  @landmarks @landmark_bars |> Map.values() |> List.flatten() |> Enum.uniq()

  @interactive ~w(a button input select textarea details label)

  @only_children %{
    "table" => ~w(thead tbody tfoot tr caption colgroup),
    "thead" => ~w(tr),
    "tbody" => ~w(tr),
    "tfoot" => ~w(tr),
    "tr" => ~w(td th),
    "ul" => ~w(li script template),
    "ol" => ~w(li script template),
    "menu" => ~w(li script template),
    "dl" => ~w(dt dd div),
    "select" => ~w(option optgroup),
    "optgroup" => ~w(option),
    "colgroup" => ~w(col),
    "picture" => ~w(source img),
    "audio" => ~w(source track),
    "video" => ~w(source track)
  }

  @doc "Tags that can never hold children."
  @spec void_tags() :: [String.t()]
  def void_tags, do: @void

  @doc """
  Whether a bare HTML tag can hold children **at all** — false only for void elements.

  This is deliberately narrower than the React `canAcceptChild` it replaces. That one also answered
  false for every phrasing-only tag, and its single caller used the answer as "accepts any child",
  so the editor refused to drop even a word of text into a `<span>` or an `<a>`. Whether a *block*
  child is allowed is a separate question, asked per-pair by `can_drop?/4`.

  Components and slots answer `true`; whether they really have somewhere to put a child depends on
  their slot metadata, which `can_drop?/4` checks.
  """
  @spec accepts_children?(String.t() | nil) :: boolean()
  def accepts_children?(nil), do: true
  def accepts_children?("." <> _rest), do: true
  def accepts_children?(":" <> _rest), do: true
  def accepts_children?(tag) when is_binary(tag), do: String.downcase(tag) not in @void

  @doc "Whether a tag holds phrasing content only, so no block element may be dropped into it."
  @spec phrasing_only?(String.t() | nil) :: boolean()
  def phrasing_only?(tag) when is_binary(tag), do: String.downcase(tag) in @phrasing_only
  def phrasing_only?(_tag), do: false

  # Flow content that @only_children happens to also permit somewhere narrow. `<img>` is listed
  # under `picture` and `<script>`/`<template>` under the lists, but all three are ordinary content
  # that belongs anywhere, so none of them is waiting on a particular parent.
  @unrestricted ~w(div img script template)

  # Read off @only_children rather than written out: a tag whose every permitted parent refuses a
  # `div` cannot have one put around it. A kit adding a structural pair is covered by adding it
  # there.
  @parent_restricted for {_parent, children} <- @only_children,
                         child <- children,
                         child not in @unrestricted,
                         Enum.all?(@only_children, fn {_parent, allowed} ->
                           child not in allowed or "div" not in allowed
                         end),
                         uniq: true,
                         do: child

  @doc """
  Whether a tag may only appear under a specific parent — `<td>` outside a `<tr>` is not a cell, it is
  foster-parented out of the table by the parser.

  The page builder asks this before it wraps a node in its own element: an editor wrapper around a
  `<td>` lands where only a `<td>` may go, so the parser moves it out and the wrapper becomes an
  orphan sitting above the table, taking the node's markers with it.
  """
  @spec parent_restricted?(String.t() | nil) :: boolean()
  def parent_restricted?(tag) when is_binary(tag), do: String.downcase(tag) in @parent_restricted
  def parent_restricted?(_tag), do: false

  @doc """
  Whether this node may hold children at all, asked without a node being dragged.

  The two rules `can_drop?/4` applies to the TARGET alone — what HTML lets an element contain, and a
  component needing somewhere to put content — and nothing about what is arriving. The layers rail
  has to answer this while it renders a row, long before anything has been picked up, and answering
  it a second way is how the rail came to refuse drops the server allows: `drop_target?/2` required a
  palette row, so the `<.form>` this editor wraps every loose field in — a component Phoenix declares
  a slot for, and one no kit ships — was drawn as a row nothing could be dropped inside, and a field
  aimed at the middle of it landed beside it instead.

  A guess, not a verdict: it knows nothing about the node being moved, so `can_drop?/4` still decides.
  """
  @spec holds_children?(Node.t() | term(), keyword()) :: boolean()
  def holds_children?(node, opts \\ [])

  def holds_children?(%Node{} = node, opts) do
    case check_container(node) do
      :ok -> check_component_slots(nil, node, opts) == :ok
      {:error, _refused} -> false
    end
  end

  def holds_children?(_node, _opts), do: false

  @doc """
  Whether `dragged` may be dropped into `target`.

  `dragged` is a `Tree.Node`, or a palette entry — any map carrying `:tag` (what it will become) and
  optionally `:slots`. `target` is a node id or `:root`.

  Options:

    * `:components` — the palette metadata list (maps with `name` and `slots`), used to decide
      whether a component declares somewhere to put a child and what part it plays in a form.
    * `:dragged_tree` — the tree `dragged` belongs to, which for an insert is the parsed template
      rather than the document. Without it a Block's own `<.form>` is invisible here, because a
      block opens with a band tag and only its head node arrives.
    * `:roles` — the memo `MishkaCmsCore.Runtime.Authoring.Fields.roles/2` builds, computed once
      per drag by `accepts_map/3` and rebuilt here when a caller asks about a single drop.
    * `:outer_tags` — the element each component's markup opens with, by component name; built
      once per drag by `accepts_map/3`, and read off `:components` as needed for a single drop.

  Returns `:ok` or `{:error, message}` with a sentence meant for the person dragging.
  """
  @spec can_drop?(Tree.t(), Node.t() | map(), Tree.parent(), keyword()) ::
          :ok | {:error, String.t()}
  def can_drop?(tree, dragged, target, opts \\ [])

  def can_drop?(_tree, _dragged, :root, _opts), do: :ok

  def can_drop?(tree, dragged, target_id, opts) when is_binary(target_id) do
    case Tree.get(tree, target_id) do
      nil -> {:error, gettext("That drop target no longer exists.")}
      target -> check(tree, dragged, target, memoised(tree, dragged, opts))
    end
  end

  @doc """
  Whether `child` may sit inside a tag that does not exist yet.

  A wrap mints its wrapper on the spot, so there is no node to point `can_drop?/4` at and no place in
  the tree to ask about — but the pairing still has to hold: a `<span>` will not take a `<section>`,
  and an `<img>` will not take anything at all. Only the rules that are a property of the PAIR are
  asked here; the ones that depend on where the wrapper lands (cycles, form nesting, an interactive
  ancestor) are asked of the wrapper's destination instead, which is a real position in a real tree.

  Returns `:ok` or `{:error, message}`, in the same words a refused drop uses.
  """
  @spec can_hold?(Node.t() | map(), String.t()) :: :ok | {:error, String.t()}
  def can_hold?(child, tag) when is_binary(tag) do
    target = Node.new(:tag, tag: tag)

    with :ok <- check_container(target),
         :ok <- check_only_children(child, target) do
      check_phrasing(child, target, [])
    end
  end

  defp check(tree, dragged, target, opts) do
    with :ok <- check_cycle(tree, dragged, target),
         :ok <- check_container(target),
         :ok <- check_component_slots(tree, target, opts),
         :ok <- check_only_children(dragged, target),
         :ok <- check_phrasing(dragged, target, opts),
         :ok <- check_form_nesting(tree, dragged, target, opts),
         :ok <- check_landmarks(tree, dragged, target, opts),
         :ok <- check_field_nesting(tree, dragged, target, opts) do
      check_interactive(tree, dragged, target)
    end
  end

  # Deciding a component's form role parses that component's own markup, and `accepts_map/3` asks
  # this question once per node in the document — so the answers are memoised per component name for
  # the whole drag rather than recomputed per node.
  defp memoised(tree, dragged, opts) do
    case Keyword.has_key?(opts, :roles) do
      true -> opts
      false -> Keyword.put(opts, :roles, drag_roles(tree, dragged, opts))
    end
  end

  defp drag_roles(tree, dragged, opts) do
    Fields.roles(
      Tree.walk(tree) ++ [dragged | dragged_descendants(dragged, tree, opts)],
      Keyword.get(opts, :components, [])
    )
  end

  defp check_cycle(tree, %Node{id: id}, %Node{id: target_id}) do
    case id == target_id or Tree.descendant?(tree, id, target_id) do
      true -> {:error, gettext("An element cannot be moved inside itself.")}
      false -> :ok
    end
  end

  defp check_cycle(_tree, _dragged, _target), do: :ok

  defp check_container(%Node{kind: kind}) when kind not in [:tag, :component, :slot],
    do: {:error, gettext("That element holds text only — drop next to it instead of inside it.")}

  defp check_container(%Node{tag: tag} = target) do
    case accepts_children?(tag) or component_like?(target) do
      true -> :ok
      false -> {:error, gettext("%{label} cannot contain other elements.", label: label(tag))}
    end
  end

  # A SLOT THE COMPONENT NEVER RENDERS IS NOT SOMEWHERE TO PUT ANYTHING.
  #
  # Declaring a slot and rendering its body are different things, and thirteen of the kit's slots do
  # only the first — `chelekom-video` reads `source.src` and `source.type` off `:source` and never
  # calls `render_slot`. Every surface said yes to a drop into one: the rail drew it as a container,
  # the map offered it, the drop landed, the tree kept it, and the canvas drew nothing. The author is
  # left looking at a slot with a card in it and a page that disagrees.
  #
  # Asked BEFORE the "it already holds something" rule below, which for a slot is not proof of
  # anything: whatever is in there is not being drawn either, and letting a second thing follow it
  # only makes the disagreement bigger.
  defp check_component_slots(tree, %Node{kind: :slot} = target, opts) do
    case slot_rendered?(tree, target, opts) do
      true ->
        :ok

      false ->
        {:error,
         gettext("%{label} is set by its properties — it does not draw content.",
           label: label(target.tag)
         )}
    end
  end

  # A component needs somewhere to PUT a child. It has one if its metadata declares a slot, or if it
  # already holds content — a previous author having put something there is proof enough, and it
  # keeps a component whose metadata has not been re-imported from becoming a dead end.
  defp check_component_slots(_tree, %Node{kind: :component} = target, opts) do
    cond do
      target.children != [] ->
        :ok

      declares_slots?(target, opts) ->
        :ok

      true ->
        {:error,
         gettext("%{label} does not declare a slot to put content in.", label: label(target.tag))}
    end
  end

  defp check_component_slots(_tree, _target, _opts), do: :ok

  # WHICH COMPONENT OWNS THIS SLOT, resolved two ways because the two callers know different things.
  #
  # `can_drop?/4` has the tree, so the owner is the slot's parent looked up in the palette.
  # `holds_children?/2` has no tree — the layers rail asks about one row at a time — but it passes
  # the owner's own entry as the only member of `:components`, because a slot row borrows its
  # parent's entry to find its properties in the first place.
  #
  # Every path that cannot answer says the slot RENDERS. A false "nothing can go here" would shut an
  # author out of a slot that does take content, which is worse than the silence this is ending.
  defp slot_rendered?(tree, %Node{} = slot, opts) do
    case {Node.slot_name(slot), slot_owner(tree, slot, opts)} do
      {name, %{} = owner} when is_binary(name) -> Inspector.renders_slot?(owner, name)
      _cannot_tell -> true
    end
  end

  defp slot_owner(%Tree{} = tree, %Node{parent_id: parent_id}, opts) when is_binary(parent_id) do
    with %Node{kind: :component} = parent <- Tree.get(tree, parent_id),
         name when is_binary(name) <- Node.component_name(parent) do
      opts |> Keyword.get(:components, []) |> Enum.find(&(component_meta_name(&1) == name))
    else
      _unknown -> nil
    end
  end

  # The rail's shape. Guarded on the entry actually declaring a slot by this name, so a caller that
  # hands over an unrelated component cannot make this answer about the wrong one.
  defp slot_owner(_tree, %Node{} = slot, opts) do
    name = Node.slot_name(slot)

    case Keyword.get(opts, :components, []) do
      [only] -> (declares_named_slot?(only, name) && only) || nil
      _many_or_none -> nil
    end
  end

  defp declares_named_slot?(entry, name) when is_binary(name),
    do: entry |> Inspector.slots() |> Enum.any?(&(Inspector.name(&1) == name))

  defp declares_named_slot?(_entry, _name), do: false

  defp declares_slots?(target, opts), do: catalog_slots?(target, opts) or local_slots?(target)

  defp catalog_slots?(target, opts) do
    name = Node.component_name(target)

    opts
    |> Keyword.get(:components, [])
    |> Enum.find(&(component_meta_name(&1) == name))
    |> component_meta_slots()
    |> Kernel.!=([])
  end

  # A CMS-LOCAL FUNCTION COMPONENT IS NOT IN THE KIT CATALOG. `<.form>` declares `inner_block` and
  # would otherwise answer "does not declare a slot to put content in" for every field dropped into
  # it — an empty form nothing can be put inside is a dead end the author cannot get out of.
  defp local_slots?(%Node{tag: "." <> name}),
    do: Enum.any?(Fields.local_modules(), &declares_slot?(&1, name))

  defp local_slots?(_target), do: false

  # Read off the module's own declarative metadata, so a name arriving in a template never mints an
  # atom: an undeclared one simply does not match.
  defp declares_slot?(module, name) do
    module
    |> declared_components()
    |> Map.get(name, %{})
    |> Map.get(:slots, [])
    |> Kernel.!=([])
  end

  defp declared_components(module) do
    case Code.ensure_loaded?(module) and function_exported?(module, :__components__, 0) do
      true -> Map.new(module.__components__(), fn {fun, meta} -> {Atom.to_string(fun), meta} end)
      false -> %{}
    end
  end

  defp component_meta_name(%{name: name}), do: name
  defp component_meta_name(%{"name" => name}), do: name
  defp component_meta_name(_meta), do: nil

  defp component_meta_slots(%{slots: slots}) when is_list(slots), do: slots
  defp component_meta_slots(%{"slots" => slots}) when is_list(slots), do: slots
  defp component_meta_slots(_meta), do: []

  defp check_only_children(dragged, %Node{tag: tag}) when is_binary(tag) do
    case Map.get(@only_children, String.downcase(tag)) do
      nil -> :ok
      allowed -> check_allowed(dragged, tag, allowed)
    end
  end

  defp check_only_children(_dragged, _target), do: :ok

  # Text and expressions are always allowed through a structural gate: `<tr>{@cell}</tr>` is how a
  # dynamic table is written, and refusing it would make loops uneditable.
  defp check_allowed(%{kind: kind}, _tag, _allowed)
       when kind in [:text, :eex, :eex_block, :eex_comment, :html_comment],
       do: :ok

  defp check_allowed(dragged, tag, allowed) do
    child = dragged_tag(dragged)

    cond do
      is_nil(child) ->
        :ok

      component_tag?(child) ->
        :ok

      String.downcase(child) in allowed ->
        :ok

      true ->
        {:error,
         gettext("%{label} can only contain %{list}.",
           label: label(tag),
           list: humanize_list(allowed)
         )}
    end
  end

  defp check_phrasing(dragged, target, opts) do
    case rendered(target, opts) do
      tag when is_binary(tag) ->
        case phrasing_only?(tag) and block?(dragged, opts) do
          true ->
            {:error,
             gettext("%{label} can only hold text and inline elements.", label: label(tag))}

          false ->
            :ok
        end

      nil ->
        :ok
    end
  end

  # HTML FORBIDS A NESTED FORM AND FAILS SILENTLY AT IT: the parser's form-element pointer discards
  # the inner start tag, `data-node-id` and all, and lets the inner `</form>` close the OUTER one —
  # ejecting every later sibling from submission with nothing on the canvas to show it happened.
  # This is the one ancestor rule in this module, and it is here because the failure is invisible.
  #
  # WHAT COUNTS AS A FORM IS `Fields.form_node?/2`'s ANSWER and no longer a second, narrower one
  # here. This module used to read the tag and the `for=` assign only, so a kit's own form wrapper —
  # a `.component` node whose seeded `for` is `{%{}}` — was neither, and the drop it exists to refuse
  # went through and was reported by the audit rail afterwards instead.
  defp check_form_nesting(tree, dragged, target, opts) do
    roles = Keyword.fetch!(opts, :roles)

    case brings_form?(dragged, tree, roles, opts) and
           Enum.any?([target | Tree.ancestors(tree, target.id)], &Fields.form_node?(&1, roles)) do
      true ->
        {:error, gettext("A form cannot go inside another form — browsers drop the inner one.")}

      false ->
        :ok
    end
  end

  # A LANDMARK ARRIVING WHERE ITS HOST'S RULES SAY IT MAY NOT. Asked of the target and every
  # ancestor, like the form rule above: a `<footer>` dropped into a `<div>` inside a `<header>` is
  # inside the header all the same. What arrives is the dragged node with everything under it, so a
  # section carrying a footer is held to the footer's rule.
  defp check_landmarks(tree, dragged, target, opts) do
    arriving =
      [dragged | dragged_descendants(dragged, tree, opts)]
      |> Enum.map(&rendered(&1, opts))
      |> Enum.filter(&(&1 in @landmarks))
      |> Enum.uniq()

    case arriving != [] and barred(tree, target, arriving, opts) do
      {host, landmark} ->
        {:error,
         gettext("%{label} cannot hold a `<%{tag}>`. Put it next to it instead.",
           label: label(host),
           tag: landmark
         )}

      _none ->
        :ok
    end
  end

  defp barred(tree, target, arriving, opts) do
    Enum.find_value([target | Tree.ancestors(tree, target.id)], fn node ->
      host = rendered(node, opts)
      refused = Map.get(@landmark_bars, host, [])

      case Enum.find(arriving, &(&1 in refused)) do
        nil -> nil
        landmark -> {host, landmark}
      end
    end)
  end

  # A FIELD DOES NOT HOLD ANOTHER FIELD. A kit field that declares slots (a label, a description)
  # reads as a container to `check_component_slots/3`, so a field clicked or dropped onto another one
  # landed inside it, where no slot draws it. Refused here, a placement climbs to beside it instead.
  # What is a field is `Fields.field_node?/2`'s answer, as it is for the form rule above.
  defp check_field_nesting(tree, dragged, target, opts) do
    roles = Keyword.fetch!(opts, :roles)

    case Fields.field_node?(target, roles) and brings_field?(dragged, tree, roles, opts) do
      true -> {:error, gettext("A field cannot go inside another field. Put it next to it.")}
      false -> :ok
    end
  end

  defp brings_field?(dragged, tree, roles, opts) do
    Enum.any?(
      [dragged | dragged_descendants(dragged, tree, opts)],
      &Fields.field_node?(&1, roles)
    )
  end

  # A BLOCK IS ITS OWN SUBTREE. Every form block opens with a band tag by design, so the head node
  # that arrives here is a `<section>` and the form is one of its children.
  defp brings_form?(dragged, tree, roles, opts) do
    Enum.any?([dragged | dragged_descendants(dragged, tree, opts)], &Fields.form_node?(&1, roles))
  end

  # The document, unless the caller says otherwise. A MOVE drags a node that is already in the tree,
  # so its own children answer; an INSERT drags the head of a freshly parsed template, whose ids the
  # document has never seen — which reads as no descendants rather than the wrong ones, and is why
  # an editor inserting a template hands the parsed template over as `:dragged_tree`.
  defp dragged_descendants(%Node{id: id}, tree, opts) do
    dragged_tree = Keyword.get(opts, :dragged_tree) || tree

    dragged_tree
    |> Tree.descendant_ids(id)
    |> Enum.map(&Tree.get(dragged_tree, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp dragged_descendants(_dragged, _tree, _opts), do: []

  defp check_interactive(tree, dragged, %Node{tag: tag}) when is_binary(tag) do
    case String.downcase(tag) in @interactive and interactive?(tree, dragged) do
      true ->
        {:error, gettext("%{label} cannot contain another clickable element.", label: label(tag))}

      false ->
        :ok
    end
  end

  defp check_interactive(_tree, _dragged, _target), do: :ok

  defp interactive?(tree, %Node{} = dragged) do
    interactive_tag?(dragged.tag) or
      Enum.any?(Tree.descendant_ids(tree, dragged.id), fn id ->
        tree |> Tree.get(id) |> then(&(&1 && interactive_tag?(&1.tag)))
      end)
  end

  defp interactive?(_tree, dragged), do: interactive_tag?(dragged_tag(dragged))

  defp interactive_tag?(tag) when is_binary(tag), do: String.downcase(tag) in @interactive
  defp interactive_tag?(_tag), do: false

  # A component whose markup cannot be read is opaque here: it may render anything, so it is let
  # through rather than guessed at. One whose markup opens with an element is that element.
  defp block?(%{kind: kind}, _opts) when kind in [:text, :eex, :eex_comment, :html_comment],
    do: false

  defp block?(dragged, opts) do
    case rendered(dragged, opts) do
      nil -> false
      tag -> tag in @text_blocks or tag not in @phrasing_only
    end
  end

  # THE ELEMENT A NODE PUTS ON THE PAGE, lowercased: a tag is itself, and a component is the one
  # element its own markup opens with (a kit navbar's `<nav>`), read off the palette entry's
  # template. `nil` for anything else — a slot, text, a component with no markup, one whose markup
  # opens with another component or with several elements — which every rule here reads as
  # "nothing to check", the way a component always used to be read.
  defp rendered(%Node{kind: :component} = node, opts),
    do: node |> Node.component_name() |> outer_tag(opts)

  defp rendered(%Node{kind: :tag, tag: tag}, _opts) when is_binary(tag), do: String.downcase(tag)
  defp rendered(%Node{}, _opts), do: nil

  defp rendered(dragged, _opts) do
    tag = dragged_tag(dragged)

    case is_binary(tag) and not component_tag?(tag) do
      true -> String.downcase(tag)
      false -> nil
    end
  end

  # Memoised for a whole drag by `accepts_map/3`, which asks about every node in the document; a
  # single drop asks about a handful and reads them as it goes.
  defp outer_tag(nil, _opts), do: nil

  defp outer_tag(name, opts) do
    case Keyword.fetch(opts, :outer_tags) do
      {:ok, memo} when is_map_key(memo, name) -> Map.fetch!(memo, name)
      _unread -> read_outer_tag(name, Keyword.get(opts, :components, []))
    end
  end

  defp read_outer_tag(name, components) do
    with %{} = entry <- Fields.entry(name, components),
         {:ok, tree} <- entry |> Inspector.template() |> Tree.parse(),
         [%Node{kind: :tag, tag: tag}] when is_binary(tag) <- outer_elements(tree) do
      String.downcase(tag)
    else
      _unreadable -> nil
    end
  end

  defp outer_elements(tree) do
    tree.roots
    |> Enum.map(&Tree.get(tree, &1))
    |> Enum.filter(&match?(%Node{kind: kind} when kind in [:tag, :component], &1))
  end

  defp outer_tags(tree, dragged, opts) do
    components = Keyword.get(opts, :components, [])

    (Tree.walk(tree) ++ [dragged | dragged_descendants(dragged, tree, opts)])
    |> Enum.flat_map(&component_names/1)
    |> Enum.uniq()
    |> Map.new(&{&1, read_outer_tag(&1, components)})
  end

  defp component_names(%Node{kind: :component} = node), do: List.wrap(Node.component_name(node))
  defp component_names(_node), do: []

  defp dragged_tag(%Node{tag: tag}), do: tag
  defp dragged_tag(%{tag: tag}), do: tag
  defp dragged_tag(%{"tag" => tag}), do: tag
  defp dragged_tag(_dragged), do: nil

  defp component_tag?("." <> _rest), do: true
  defp component_tag?(":" <> _rest), do: true
  defp component_tag?(<<first, _rest::binary>>) when first in ?A..?Z, do: true
  defp component_tag?(_tag), do: false

  defp component_like?(%Node{kind: kind}), do: kind in [:component, :slot]

  defp label(nil), do: gettext("This element")
  defp label(tag), do: gettext("A `<%{tag}>`", tag: tag)

  defp humanize_list([one]), do: gettext("`<%{tag}>` elements", tag: one)

  defp humanize_list(tags) do
    {front, [last]} = Enum.split(tags, -1)

    gettext("%{front} or `<%{last}>` elements",
      front: Enum.map_join(front, ", ", &"`<#{&1}>`"),
      last: last
    )
  end

  @doc """
  Precomputes, for every node in the tree, whether `dragged` may land inside it — the hint map the
  drag hook uses to paint drop targets without a round trip per hover. The server still re-checks
  the drop it is actually asked to perform.

  An editor asks for it at `dragstart`; the visual editor (`mishka_cms_builder`) also folds in its
  session's locks. A refusal here is not the end of the gesture there: it places the node beside the
  target instead.
  """
  @spec accepts_map(Tree.t(), Node.t() | map(), keyword()) :: %{String.t() => boolean()}
  def accepts_map(tree, dragged, opts \\ []) do
    memoised =
      tree
      |> memoised(dragged, opts)
      |> Keyword.put_new_lazy(:outer_tags, fn -> outer_tags(tree, dragged, opts) end)

    Map.new(tree.nodes, fn {id, _node} ->
      {id, can_drop?(tree, dragged, id, memoised) == :ok}
    end)
  end
end
