# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.PageForms.Naming do
  @moduledoc """
  One seed per form, and the five names derived from it.

  | derived      | from seed `contact`            | with token `k7m2q`       |
  |--------------|--------------------------------|--------------------------|
  | DOM id       | `contact-form`                 | `contact-form`           |
  | param name   | `as={:contact}`                | `as={:contact}`          |
  | page assign  | `for={assigns[:contact_form]}` | the same                 |
  | change event | `contact_validate`             | `contact-k7m2q-validate` |
  | submit event | `contact_submit`               | `contact-k7m2q-submit`   |

  ## Tokens

  A form carries a random 5-character token in both event names. A rename keeps it, so a handler
  stored under the old event name is still found by token and kind (`event_key/1`). A form arriving
  in the tree gets a token when it has none or shares one, and any form whose token an earlier form
  already holds gets a fresh one (`dedupe/2`). A form without a token keeps the untagged names until
  it is renamed or placed again; a markup edit of an ancestor is neither (`dedupe/3`).

  There is no control anywhere in the editor that edits one of the five alone, so they cannot
  disagree: the Inspector's Form name control writes `attrs/2` in one batch, and every other route
  into the tree goes through `dedupe/1`. Two forms on one page are therefore impossible to collide
  rather than merely reported as colliding.

  ## Everything here is a string

  A seed is a binary, a field key is a binary, and nothing in this module calls `String.to_atom/1`.
  What the editor is producing is SOURCE TEXT — `as={:contact}` and `field={f[:email]}` are markup,
  and the atom in them is a literal the page compiler interns once, not a value this module needs.
  Minting an atom per label typed into a text box would leak the atom table for no gain, so a caller
  writing a key into markup interpolates it as `":" <> key`.

  The param name is written as `as={:contact}` rather than `as="contact"` because that is what a
  hand-written LiveView form carries, and it is what `Phoenix.Component.form/1` documents;
  `MishkaCmsCore.Runtime.Authoring.PageForms.param_name/1` reads both forms back.

  ## Why a seed is re-minted on the way out

  `attrs/1` slugs whatever it is handed. A seed that reached the tree some other way — hand-typed
  into the code drawer, pasted from another page — could otherwise produce `as={:2 items}`, which is
  not an atom literal and does not compile, or `for={assigns[:my form_form]}`, which is not an
  assign. Slugging is idempotent, so a seed that is already legal survives untouched.

  A seed already in the page is minted the same way before it is compared, so what a rename writes
  is measured against what every other form would be called — `as={:"my form"}` cannot be renumbered
  into a name a second form is already using.

  ## Why renumbering runs at the op layer

  `dedupe/2` is applied to the whole tree after a mutating op rather than at one insert route,
  because paste (`kind: :insert`, built by `MishkaCmsBuilder.EditorSession.paste/2`)
  and duplicate (`kind: :duplicate`) never pass through the insert funnel — and "duplicate this form"
  is how an author actually makes the second one. `MishkaCmsCore.Runtime.Authoring.Tree.duplicate/2`
  re-mints NODE ids and copies every attribute verbatim, so the copy arrives carrying the original's
  seed in all five places.

  `rekey/2` is the same rule one level down: a duplicated FIELD arrives carrying the key its
  original owns, and several inputs bound to one key overwrite each other on submit. Both take the
  ids the op just created, and in both the arrival is what gets renamed — see `dedupe/2` for what
  renaming the wrong one costs.

  ## Gaps are filled, not skipped

  A page whose forms are `contact` and `contact_3` mints `contact_2` next. Numbering is a search for
  the lowest free member of a family, not a counter, so deleting the second of three forms does not
  push the next one to `contact_4`.

  See also `MishkaCmsCore.Runtime.Authoring.PageForms` for what declares a form in the first place.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.Authoring.PageForms
  alias MishkaCmsCore.Runtime.Authoring.Tree
  alias MishkaCmsCore.Runtime.Authoring.Tree.Node

  @attrs ~w(id as for phx-change phx-submit)

  @events [{"phx-change", :validate}, {"phx-submit", :submit}]

  @event ~r/^(?<seed>[a-z][a-z0-9_]*)-(?<token>[a-z2-7]{5})-(?<kind>validate|submit)$/

  @kinds %{"validate" => :validate, "submit" => :submit}

  @token_length 5

  @form_fallback "form"

  @field_fallback "field"

  @length 40

  @doc """
  The seed a label mints: lowercased, accents folded away, every other run of characters turned into
  a single `_`, and never starting with a digit.

  A label that leaves nothing usable — blank, punctuation only, or written in a script that has no
  ASCII form — falls back to `#{@form_fallback}`, because every one of the five derived names has to
  exist.
  """
  @spec seed(String.t() | nil) :: String.t()
  def seed(label), do: slug(label, @form_fallback)

  @doc """
  The name a site admin reads for a form's seed: `form` is "Form 1", `form_3` is "Form 3", and any
  other seed is its words with a capital ("contact_us" is "Contact us"). `nil` for `nil`.
  """
  @spec people_name(String.t() | nil) :: String.t() | nil
  def people_name(nil), do: nil

  def people_name(seed) when is_binary(seed) do
    case Regex.run(~r/^#{@form_fallback}(?:_(\d+))?$/, seed) do
      [_whole] -> numbered_name(1)
      [_whole, number] -> numbered_name(number)
      nil -> seed |> String.replace("_", " ") |> String.trim() |> String.capitalize()
    end
  end

  @doc "The name of form number `number`, as a person reads it: \"Form 3\"."
  @spec numbered_name(pos_integer() | String.t()) :: String.t()
  def numbered_name(number), do: gettext("Form %{number}", number: number)

  @doc """
  `people_name/1` for a name an author typed rather than a seed: `"Contáct Us"` is "Contact us", and
  a name that leaves no seed is "Form 1".
  """
  @spec label(String.t() | nil) :: String.t()
  def label(name), do: name |> seed() |> people_name()

  @doc """
  The five attributes a form node carries with the untagged event names, in the order a reader
  expects them, ready for `MishkaCmsCore.Runtime.Authoring.Tree.set_attr/4`.
  """
  @spec attrs(String.t() | nil) :: [{String.t(), {:string | :expr, String.t()}}]
  def attrs(name), do: attrs(name, nil)

  @doc """
  The five attributes with `token` inside both event names: `contact-k7m2q-validate` and
  `contact-k7m2q-submit`. A `nil` token writes the untagged names, as `attrs/1` does.
  """
  @spec attrs(String.t() | nil, String.t() | nil) :: [{String.t(), {:string | :expr, String.t()}}]
  def attrs(name, token) do
    name
    |> seed()
    |> derive(token)
  end

  @doc """
  `attrs/2` for the form `node`, and its `phx-trigger-action` under the new seed when it sends to
  another address (`PageForms.sends_elsewhere?/1`), so a rename or a renumber keeps that working.
  What every writer of the five names writes.
  """
  @spec names_for(Node.t(), String.t() | nil, String.t() | nil) ::
          [{String.t(), {:string | :expr, String.t()}}]
  def names_for(node, name, token), do: attrs(name, token) ++ kept_trigger(node, name)

  defp kept_trigger(node, name) do
    case PageForms.sends_elsewhere?(node) do
      true -> [trigger(name)]
      false -> []
    end
  end

  @doc """
  The `phx-trigger-action` a form sending to another address carries: the page assign
  `MishkaCmsCore.Runtime.PageForm.submit/5` sets once its answers are checked, `assigns[:contact_send]`
  for the seed `contact`.
  """
  @spec trigger(String.t() | nil) :: {String.t(), {:expr, String.t()}}
  def trigger(name), do: {"phx-trigger-action", {:expr, "assigns[:#{seed(name)}_send]"}}

  defp derive(seed, token) do
    [
      {"id", {:string, dom_id(seed)}},
      {"as", {:expr, ":" <> seed}},
      {"for", {:expr, "assigns[:#{seed}_form]"}},
      {"phx-change", {:string, event(seed, token, :validate)}},
      {"phx-submit", {:string, event(seed, token, :submit)}}
    ]
  end

  @doc "One event name: `contact-k7m2q-submit` with a token, `contact_submit` with `nil`."
  @spec event(String.t(), String.t() | nil, :validate | :submit) :: String.t()
  def event(seed, nil, kind), do: "#{seed}_#{kind}"
  def event(seed, token, kind), do: "#{seed}-#{token}-#{kind}"

  @doc "`{token, kind}` of a tagged event name, or `nil` for any other name."
  @spec event_key(term()) :: {String.t(), :validate | :submit} | nil
  def event_key(name), do: name |> parts() |> key()

  defp key(%{"token" => token, "kind" => kind}), do: {token, Map.fetch!(@kinds, kind)}
  defp key(nil), do: nil

  defp parts(name) when is_binary(name), do: Regex.named_captures(@event, name)
  defp parts(_name), do: nil

  @doc "The token inside a tagged event name, or `nil`."
  @spec token(term()) :: String.t() | nil
  def token(name), do: name |> event_key() |> token_of()

  defp token_of({token, _kind}), do: token
  defp token_of(nil), do: nil

  @doc "Whether two event names carry the same token and the same kind, whatever their seeds."
  @spec same_event?(term(), term()) :: boolean()
  def same_event?(a, b), do: a |> event_key() |> same?(event_key(b))

  @doc "Whether two event names carry the same token, so they belong to the same form."
  @spec same_form?(term(), term()) :: boolean()
  def same_form?(a, b), do: a |> token() |> same?(token(b))

  defp same?(nil, _other), do: false
  defp same?(value, value), do: true
  defp same?(_value, _other), do: false

  @doc "The token a form carries in its `phx-submit`, else in its `phx-change`, or `nil`."
  @spec form_token(Node.t() | nil) :: String.t() | nil
  def form_token(nil), do: nil
  def form_token(node), do: attr_token(node, "phx-submit") || attr_token(node, "phx-change")

  defp attr_token(node, attr), do: node |> Node.attr_text(attr) |> token()

  @doc "A fresh token no event name in `tree` carries: 5 characters of `a-z2-7`."
  @spec mint_token(Tree.t()) :: String.t()
  def mint_token(tree), do: tree |> tokens() |> fresh_token()

  @doc """
  The form's own token when no other form in `tree` carries it; otherwise, or when it has none, a
  fresh one. What a renumbered form is written with.
  """
  @spec kept_token(Tree.t(), Node.t()) :: String.t()
  def kept_token(tree, node), do: node |> form_token() |> kept(tree, node)

  defp kept(nil, tree, _node), do: mint_token(tree)

  defp kept(token, tree, node) do
    tree
    |> Tree.walk()
    |> Enum.any?(&(&1.id != node.id and form_token(&1) == token))
    |> kept_or_minted(token, tree)
  end

  defp kept_or_minted(false, token, _tree), do: token
  defp kept_or_minted(true, _token, tree), do: mint_token(tree)

  @doc """
  The event attributes of `node` rewritten to carry `token`, ready for
  `MishkaCmsCore.Runtime.Authoring.Tree.set_attr/4`.

  Only names this module writes change: a tagged name keeps its own seed and kind, and an untagged
  `<seed>_validate`/`<seed>_submit` of the form's own seed gets the token. Any other name is a
  developer's and is left out.
  """
  @spec retokened(Node.t(), String.t()) :: [{String.t(), {:string, String.t()}}]
  def retokened(node, token) do
    own = node |> PageForms.param_name() |> seed()

    for {attr, kind} <- @events,
        name = Node.attr_text(node, attr),
        retagged = retag(parts(name), name, own, kind, token),
        is_binary(retagged),
        do: {attr, {:string, retagged}}
  end

  defp retag(%{"seed" => seed, "kind" => kind}, _name, _own, _attr_kind, token),
    do: event(seed, token, Map.fetch!(@kinds, kind))

  defp retag(nil, name, own, kind, token),
    do: untagged(name == event(own, nil, kind), own, kind, token)

  defp untagged(true, own, kind, token), do: event(own, token, kind)
  defp untagged(false, _own, _kind, _token), do: nil

  defp tokens(tree) do
    for node <- Tree.walk(tree),
        {attr, _kind} <- @events,
        token = attr_token(node, attr),
        is_binary(token),
        into: MapSet.new(),
        do: token
  end

  defp fresh_token(held),
    do: Enum.find(Stream.repeatedly(&random_token/0), &(!MapSet.member?(held, &1)))

  defp random_token do
    5
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(case: :lower, padding: false)
    |> binary_part(0, @token_length)
  end

  # `contact` is a `contact-form`, but the fallback seed is already the word `form` and `form-form`
  # reads like a mistake rather than a default. The whole fallback FAMILY is spared, not just the
  # first of them: sparing `form` alone would leave a page of unnamed forms reading `form`,
  # `form_2-form`, `form_3-form`, which is worse than stuttering consistently.
  #
  # Only the DOM id is affected — `as={:form}` and `form_validate` say it once either way.
  defp dom_id(seed) do
    case String.split(seed, "_") do
      [@form_fallback | _numbered] -> seed
      _named -> seed <> "-form"
    end
  end

  @doc "Which attributes a rename touches — read by the Inspector so it can batch them as one op."
  @spec derived() :: [String.t()]
  def derived, do: @attrs

  @doc """
  Every form already in this tree, as `{node id, seed}` in document order.

  The seeds are PARSED off the nodes rather than counted, so a page whose only form is `contact_2`
  answers `contact_2` and the next one minted is not the same name again.

  A node is a form when `MishkaCmsCore.Runtime.Authoring.PageForms.form?/1` says so — it holds the
  page assign its values live in. Asking only for an `as` would take `as` at its HTML word, and `as`
  is an ordinary attribute of an ordinary tag:

      <link rel="preload" as="font" href="/inter.woff2" />

  Two of those on a page read as two forms both seeded `font`, and `dedupe/1` renames the second by
  writing five form attributes onto a `<link>` — breaking the preload, minting a form nobody placed,
  and raising a duplicate-seed blocker about it. It runs on every insert, duplicate, wrap AND on
  every save, draft restore and history revert, so the wreckage is what gets stored.
  """
  @spec seeds(Tree.t()) :: [{String.t(), String.t()}]
  def seeds(tree) do
    for node <- Tree.walk(tree),
        PageForms.form?(node),
        seed = PageForms.param_name(node),
        is_binary(seed),
        do: {node.id, seed}
  end

  @doc """
  A seed based on `base` that no form in `tree` is using.

  `base` may be an author's label; it is minted through `seed/1` first, so the answer is always a
  legal name.
  """
  @spec unique(Tree.t(), String.t() | nil) :: String.t()
  def unique(tree, base) do
    base
    |> seed()
    |> free(taken(tree))
  end

  @doc """
  Renumbers every form that shares a seed with one that claimed it first, rewriting all five derived
  names in one pass.

  `arrived` is the node ids the op just created, and THEY ARE THE ONES THAT YIELD. Claiming in
  document order renamed whichever form came first, so dropping a second Contact form ABOVE the
  first rewrote the form already on the page — its param name, its page assign and both event names
  — and the `contact_submit` clause its author had written on the Events tab was left bound to
  nothing while the page went on compiling. A form nobody has typed a handler for yet is the only
  one that can be renamed for free.

  With no arrivals named, document order decides, which is what a whole document arriving at once
  (`MishkaCmsBuilder.EditorSession.put_tree/3`) wants: there is no incumbent there.

  Tokens follow the same order. A renumbered form keeps its token unless an earlier form holds it,
  and gets a fresh one otherwise. A form whose token an earlier form holds gets a fresh one. An
  arriving form with no token gets one (`retokened/2`). An incumbent form with no token is left
  alone.

  `carried` is the event names the page's forms carried before the change. An arriving form with no
  token that answers one of them is the same form parsed again (a markup edit of an ancestor), so it
  keeps its untagged names unless its seed is taken.

  Answers the tree it was given when nothing needs a new name or token.
  """
  @spec dedupe(Tree.t(), Enumerable.t(), Enumerable.t()) :: Tree.t()
  def dedupe(tree, arrived \\ [], carried \\ []) do
    arrived = MapSet.new(arrived)

    tree
    |> seeds()
    |> yielding(arrived)
    |> renumber(tree, arrived, MapSet.new(carried))
  end

  defp yielding(pairs, arrived) do
    {arrivals, incumbents} =
      Enum.split_with(pairs, fn {node_id, _seed} -> MapSet.member?(arrived, node_id) end)

    incumbents ++ arrivals
  end

  @doc """
  Re-keys a field that arrived carrying a key the form it landed in already uses.

  The same rule forms get, applied to the keys inside one. `MishkaCmsCore.Runtime.Authoring.Tree`
  copies every attribute verbatim on a duplicate or a paste, so duplicating a field gave several
  inputs one key: all of them render `name="contact[email]"`, typing in one shows that value in all
  of them, only the last one submitted survives, and the spec carries a single field — with nothing
  in the audit rail to say so. Duplicating a field is how a non-programmer builds the second one.

  Every node bound to the colliding key moves together, because a label and its input are one field
  and re-keying the input alone would point the label at a field that no longer exists.

  A whole form arriving is not a collision. Each form scopes its own params, so the copy keeps every
  key it had and only `dedupe/2` renames it.
  """
  @spec rekey(Tree.t(), Enumerable.t()) :: Tree.t()
  def rekey(tree, arrived), do: settle(tree, MapSet.new(arrived))

  defp settle(tree, arrived) do
    case MapSet.size(arrived) do
      0 -> tree
      _some -> tree |> Tree.walk() |> Enum.filter(&PageForms.form?/1) |> recut(tree, arrived)
    end
  end

  defp recut(forms, tree, arrived), do: Enum.reduce(forms, tree, &scoped(&2, &1, arrived))

  defp scoped(tree, form, arrived), do: keyed(tree, form, PageForms.let_var(form), arrived)

  defp keyed(tree, _form, nil, _arrived), do: tree

  defp keyed(tree, form, var, arrived) do
    tree
    |> bound(form, var)
    |> renames(arrived)
    |> Enum.reduce(tree, &recast(&2, &1, var))
  end

  defp bound(tree, form, var) do
    for id <- Tree.descendant_ids(tree, form.id),
        node = Tree.get(tree, id),
        !is_nil(node),
        key = PageForms.bound_key(node, var),
        !is_nil(key),
        do: {id, key}
  end

  defp renames(pairs, arrived) do
    {arrivals, incumbents} =
      Enum.split_with(pairs, fn {node_id, _key} -> MapSet.member?(arrived, node_id) end)

    arrivals
    |> clashes(MapSet.new(incumbents, fn {_node_id, key} -> key end))
    |> Enum.reduce({[], Enum.map(pairs, fn {_node_id, key} -> to_string(key) end)}, &mint/2)
    |> elem(0)
  end

  defp clashes(arrivals, held) do
    arrivals
    |> Enum.group_by(fn {_node_id, key} -> key end, fn {node_id, _key} -> node_id end)
    |> Enum.filter(fn {key, _ids} -> MapSet.member?(held, key) end)
    |> Enum.sort()
  end

  defp mint({key, node_ids}, {renames, taken}) do
    minted = field_key(to_string(key), taken)

    {renames ++ Enum.map(node_ids, &{&1, key, minted}), [minted | taken]}
  end

  defp recast(tree, {node_id, replaced, minted}, var) do
    tree
    |> Tree.get(node_id)
    |> PageForms.rebindings(var, replaced, minted)
    |> Enum.reduce(tree, &write(&2, node_id, &1))
  end

  @doc """
  A field key minted from a label, unique within its form.

  `taken` is the keys already bound in that form, as atoms or as binaries — the parsed side of the
  editor reads them out of `f[:email]` expressions as atoms, and this compares them as text.
  """
  @spec field_key(String.t() | nil, [atom() | String.t()]) :: String.t()
  def field_key(label, taken) do
    label
    |> slug(@field_fallback)
    |> free(MapSet.new(taken, &to_string/1))
  end

  defp renumber([], tree, _arrived, _carried), do: tree

  defp renumber(pairs, tree, arrived, carried) do
    start = %{tree: tree, taken: MapSet.new(), held: MapSet.new(), all: nil, carried: carried}

    pairs
    |> Enum.reduce(start, &claim(&1, &2, arrived))
    |> Map.fetch!(:tree)
  end

  defp claim({node_id, parsed}, state, arrived) do
    node = Tree.get(state.tree, node_id)
    seed = seed(parsed)
    token = form_token(node)
    shared? = token != nil and MapSet.member?(state.held, token)
    bare? = token == nil and MapSet.member?(arrived, node_id) and not carried?(node, state)

    state
    |> settle(MapSet.member?(state.taken, seed), shared? or bare?, node, seed, token)
    |> hold_token(node_id)
  end

  defp settle(state, true = _seed_taken?, needs_token?, node, seed, token) do
    renamed = free(seed, state.taken)
    {token, state} = keep_or_mint(needs_token? or token == nil, token, state)

    %{
      state
      | tree: Enum.reduce(names_for(node, renamed, token), state.tree, &write(&2, node.id, &1)),
        taken: MapSet.put(state.taken, renamed)
    }
  end

  defp settle(state, false, true = _needs_token?, node, seed, _token) do
    {token, state} = keep_or_mint(true, nil, state)

    %{
      state
      | tree: Enum.reduce(retokened(node, token), state.tree, &write(&2, node.id, &1)),
        taken: MapSet.put(state.taken, seed)
    }
  end

  defp settle(state, false, false, _node, seed, _token),
    do: %{state | taken: MapSet.put(state.taken, seed)}

  defp carried?(node, state),
    do: Enum.any?(@events, fn {attr, _kind} -> Node.attr_text(node, attr) in state.carried end)

  defp keep_or_mint(false, token, state), do: {token, state}

  # Every token in the tree is read once, on the first mint.
  defp keep_or_mint(true, _token, state) do
    all = state.all || tokens(state.tree)
    token = fresh_token(all)
    {token, %{state | all: MapSet.put(all, token)}}
  end

  defp hold_token(state, node_id),
    do: state.tree |> Tree.get(node_id) |> form_token() |> held(state)

  defp held(nil, state), do: state
  defp held(token, state), do: %{state | held: MapSet.put(state.held, token)}

  defp write(tree, node_id, {name, value}) do
    tree
    |> Tree.set_attr(node_id, name, value)
    |> written(tree)
  end

  defp written({:ok, tree}, _previous), do: tree
  defp written({:error, _missing}, previous), do: previous

  defp taken(tree), do: MapSet.new(seeds(tree), fn {_node_id, parsed} -> seed(parsed) end)

  defp free(base, taken), do: Enum.find(candidates(base), &(!MapSet.member?(taken, &1)))

  # The family is the base with any number stripped off it, so the second `contact_2` looks for
  # `contact_3` instead of `contact_2_2`. The stream is unbounded because a bounded one has to answer
  # `nil` at the end, and a `nil` seed is a page that will not compile.
  defp candidates(base), do: Stream.concat([base], family(strip(base)))

  defp family(base), do: Stream.map(Stream.iterate(2, &(&1 + 1)), &"#{base}_#{&1}")

  defp strip(seed), do: Regex.replace(~r/_\d+$/, seed, "")

  defp slug(label, fallback) do
    (label || "")
    |> decompose()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.replace(~r/^[^a-z]+/, "")
    |> String.slice(0, @length)
    |> String.trim_trailing("_")
    |> presence(fallback)
  end

  # Folding an accent needs the letter and the mark to be separate characters first, and the mark is
  # then dropped rather than turned into a separator: `Contáct` is `contact`, not `cont_ct`. Text
  # that is not valid UTF-8 mints the fallback instead of being carried into a unicode regex, which
  # is the only input that could raise here.
  defp decompose(label) do
    label
    |> :unicode.characters_to_nfd_binary()
    |> usable()
  end

  defp usable(decomposed) when is_binary(decomposed), do: decomposed
  defp usable(_malformed), do: ""

  defp presence("", fallback), do: fallback
  defp presence(value, _fallback), do: value
end
