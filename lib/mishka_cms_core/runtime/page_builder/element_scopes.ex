defmodule MishkaCmsCore.Runtime.PageBuilder.ElementScopes do
  @moduledoc """
  What a document's minted element classes have to become when its markup lands in ANOTHER document.

  The Visual Editor names an element by a `pb-xxxxxxxx` class
  (`MishkaCmsCore.Runtime.PageBuilder.Tree.scope/2`), and that class is both the key
  `MishkaCmsCore.Runtime.PageBuilder.ElementCss` files the element's CSS under and the `to:` of an
  interaction aimed at it. The rules live in one stylesheet row per document — `owner/2` names it —
  and EVERY row is compiled into the one site stylesheet, so markup that keeps the classes it was
  written under is a second element wearing somebody else's rule:

    * it is styled by the other document's row while its own CSS box reads empty;
    * CSS written on it is a second rule for the same class, and restyles the other document;
    * the builder pruning that element from the other document deletes the rule it was relying on.

  `rescope/1` mints one fresh class per class the markup holds and swaps them; `carry_css/5` writes
  the source's rules for those classes under the copy's own owner, inside the create that writes the
  copy — so a copy whose CSS could not be written is not written either.

  ## What does NOT come through here, and why

  A DRAFT IS THE SAME DOCUMENT. A draft row, a fork of one and the publish that writes it back all
  end as the record they were taken from, under the owner that record already has: rescoping one
  would leave every rule the live document is wearing pointing at nothing. Copy, paste and Duplicate
  inside one editing session are the same story — two elements of one document may share a rule, and
  the class is how they do it.

  COPYING AN ELEMENT AND COPYING A LOOK ARE NOT THE SAME GESTURE, which is why `drop_scopes/1` lives
  here beside all that. Copy and Duplicate carry the element, and the name it answers to comes with
  it on purpose. Copy styles carries only the look onto an element that already has a name of its
  own, and a name arriving with it is a second element keyed to the first one's rule — so that is
  the one gesture inside a session the name is taken off for.

  What comes through here is markup that ends up in a DIFFERENT document: another component
  (`MishkaCmsCore.Runtime.ComponentCopy`), another page
  (`MishkaCmsCore.Runtime.PageEditions.translate/4`), or a snippet, an example or a wizard's
  composition placed into the document someone is editing — which is TWO doors, not one, because a
  card can be clicked (`MishkaCmsCore.Runtime.PageBuilder.EditorSession.place_template/3`) or
  dragged (`MishkaCmsCore.Runtime.PageBuilder.EditorSession.apply_drop/2`, where the markup arrives
  in the payload instead), and one gesture told two ways must not give the author two answers.
  """

  alias MishkaCmsCore.Runtime.PageBuilder.ElementCss
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Styles

  # `Tree.scope/2`'s `pb-xxxxxxxx` as it sits in text: a whole class in `class="…"`, or the `.pb-…`
  # selector an interaction points at. Not the tail of a longer token or a variant's `hover:pb-…`.
  @scope ~r/(?<![\w:-])pb-[a-f0-9]{8}(?![\w-])/

  @doc """
  Whether `class` — ONE class, not a whole `class` attribute — is a minted one.

  THE ONE ANSWER TO THAT QUESTION. `MishkaCmsCore.Runtime.PageBuilder.Tree.scope/2` finds an
  element's own class by it and `MishkaCmsCore.Runtime.PageBuilder.ElementCss` refuses to file a
  rule under anything else, so a second spelling of the format is a rule keyed on a class the other
  spelling does not read back.

  It is asked by matching the class against the pattern the rest of this module scans text with,
  and checking that the match is the WHOLE of it: `hover:pb-0a1b2c3d` and `pb-0a1b2c3d-lg` are
  classes of their own, and the lookarounds already say so.
  """
  @spec scope?(term()) :: boolean()
  def scope?(class) when is_binary(class), do: Regex.run(@scope, class) == [class]
  def scope?(_class), do: false

  @doc """
  `class` — a whole `class` attribute's text — with the minted classes taken out.

  A COPIED LOOK IS NOT THE ELEMENT IT WAS COPIED FROM. The minted class names one element to its own
  CSS rule and is the `to:` of every interaction aimed at it, so carrying it onto a second element
  keys both to one rule: `Tree.scope/2` answers with the first class it finds, the second element's
  own rule stops being live and the next save prunes it away.
  """
  @spec drop_scopes(String.t()) :: String.t()
  def drop_scopes(class) when is_binary(class),
    do: class |> String.split(~r/\s+/, trim: true) |> Enum.reject(&scope?/1) |> Enum.join(" ")

  @doc """
  A `class={[…]}` expression's source with the minted classes taken out of its literal elements, and
  `nil` when they were the whole of it.

  AN EXPRESSION HOLDS THE NAME TOO. `MishkaCmsCore.Runtime.PageBuilder.Tree.ensure_scope/2` splices
  the minted class into the list rather than flattening `class={@variant}` into the literal text of
  the expression, so a look copied off such an element carries the name exactly the way a string
  class did — and the target, wearing the source's name ahead of its own, is styled by the source's
  rule while its own is pruned by the next save.

  An expression that is not a list comes back as it went in: there is nowhere in it a class can be
  read, so there is nothing there to take out.
  """
  @spec drop_expr_scopes(String.t()) :: String.t() | nil
  def drop_expr_scopes(source) when is_binary(source) do
    case Styles.list_parts(source) do
      :not_a_list -> source
      parts -> parts |> Enum.map(&drop_part_scopes/1) |> Styles.list_expr()
    end
  end

  defp drop_part_scopes({:classes, classes}), do: {:classes, Enum.reject(classes, &scope?/1)}
  defp drop_part_scopes({:logic, _source} = part), do: part

  @doc """
  The row a document's element CSS is filed under: its builder section and its id.

  One definition, because the builder writing `page-<id>` while a copy reads `page_<id>` is a copy
  styled by nothing and a row nobody prunes.
  """
  @spec owner(String.t() | atom() | nil, String.t()) :: String.t()
  def owner(section, id), do: "#{section}-#{id}"

  @doc """
  `value` with a fresh class in place of every scope class it holds, and the `%{held => fresh}` map
  that says which became which — what `carry_css/5` needs to bring the source's rules over.

  `value` is anything a copy is made of: a string, a list, a map of them.
  """
  @spec rescope(term()) :: {term(), %{String.t() => String.t()}}
  def rescope(value) do
    scopes = fresh(value)
    {rescope(value, scopes), scopes}
  end

  defp rescope(value, scopes),
    do: rewrite(value, fn text -> Regex.replace(@scope, text, &Map.fetch!(scopes, &1)) end)

  @doc """
  `fun` over every string inside `value`, however deep it sits.

  The walker `rescope/1` swaps classes with, public because a copy usually has one more thing to
  rewrite in the same text and it has to happen FIRST: a component may itself be called
  `pb-deadbeef`, and its `component_name="pb-deadbeef"` is a name, not an element.

  It rewrites strings, lists and plain maps. A STRUCT IS LEFT AS WRITTEN, which is what a page's
  `helpers` are — hand-written code, stored as an embedded resource. The builder mints a class onto
  an element of the TEMPLATE and keys that element's rule on it, so a class a helper holds is one no
  rule is filed under and one no copy can carry; a helper aiming an interaction at `.pb-…` by hand
  is the case this leaves pointing where it pointed, rather than rebuilding every struct a copy
  might be carrying to chase it.
  """
  @spec rewrite(term(), (String.t() -> String.t())) :: term()
  def rewrite(value, fun) when is_binary(value), do: fun.(value)
  def rewrite(value, fun) when is_list(value), do: Enum.map(value, &rewrite(&1, fun))

  def rewrite(value, fun) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {key, inner} -> {key, rewrite(inner, fun)} end)

  def rewrite(value, _fun), do: value

  @doc """
  Copies the source document's rules for `scopes` into the copy's own row, as the create's
  after-action.

  AFTER THE ROW, INSIDE ITS TRANSACTION: the row is named after the copy's id, and a refusal here
  takes the copy back out with it. A rule whose class is not in the copied text is one the builder
  has not pruned yet, and it is left behind rather than filed under nothing.
  """
  @spec carry_css(
          Ash.Changeset.t(),
          String.t() | atom() | nil,
          struct(),
          %{String.t() => String.t()},
          map() | nil
        ) :: Ash.Changeset.t()
  def carry_css(changeset, section, source, scopes, actor) do
    Ash.Changeset.after_action(changeset, fn _changeset, copy ->
      rules =
        for {scope, body} <- ElementCss.all(actor, source.site_id, owner(section, source.id)),
            Map.has_key?(scopes, scope),
            into: %{},
            do: {Map.fetch!(scopes, scope), body}

      with {:ok, _rules} <- ElementCss.sync(actor, copy.site_id, owner(section, copy.id), rules),
           do: {:ok, copy}
    end)
  end

  # One fresh class per class the text holds, none of them one the text already uses, so no two
  # elements of the copy — nor an element of the copy and one of the source — share a rule.
  defp fresh(value) do
    held =
      value |> texts() |> Enum.flat_map(&Regex.scan(@scope, &1)) |> List.flatten() |> Enum.uniq()

    Enum.reduce(held, %{}, fn scope, scopes ->
      Map.put(scopes, scope, mint(MapSet.new(held ++ Map.values(scopes))))
    end)
  end

  defp mint(taken) do
    scope = "pb-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    case MapSet.member?(taken, scope) do
      true -> mint(taken)
      false -> scope
    end
  end

  defp texts(value) when is_binary(value), do: [value]
  defp texts(value) when is_list(value), do: Enum.flat_map(value, &texts/1)

  defp texts(value) when is_map(value) and not is_struct(value),
    do: value |> Map.values() |> Enum.flat_map(&texts/1)

  defp texts(_value), do: []
end
