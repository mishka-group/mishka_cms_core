# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.ElementCss do
  @moduledoc """
  CSS an author writes by hand for one element.

  ## Why this is not the style panel, and not a reusable class

  The inspector writes a fixed vocabulary — padding, gap, colour — because a panel can only offer
  what someone thought to add to it. `MishkaCmsCore.Runtime.PageBuilder.Classes` covers the twenty
  cards that are meant to match. Neither answers "this one element needs a `border-image` and a
  `:hover` transform", which is the request every builder eventually gets and which Elementor,
  Bricks, Divi and WordPress all answer with a per-element CSS box.

  ## What the author writes

  Declarations, and `&` where they mean the element itself:

      padding: 20px;

      &:hover { transform: translateY(-2px); }
      @media (max-width: 900px) { padding: 12px; }

  `&` is plain CSS nesting rather than Elementor's `selector` keyword or Bricks' `%root%`. Three
  reasons, none of them aesthetic: it is real CSS, so it can be checked by reading it rather than by
  substituting into it; wrapping the text in `.pb-xxxxxxxx { … }` scopes it as long as every nested
  selector starts with `&`, which is one rule to enforce; and Tailwind v4 already flattens nesting
  and resolves `@apply` in the same pass, so there is no flattener to write.

  ## Where it lives

  The element carries a minted class — `MishkaCmsCore.Runtime.PageBuilder.Tree.scope/2` — and the
  rule body lives in a stylesheet row keyed by it. The class is in the markup, so it survives a save
  and a re-parse and travels with the node on copy; the body is in a row, so it is cached CSS that
  the compiler already knows how to build rather than a `<style>` block shipped to every visitor on
  every request.

  One row per document, rewritten whole from the scopes the document currently contains — which is
  also what prunes the rule for an element somebody deleted, without anything having to notice the
  deletion. That pruning is `live_rules/2`, and the builder runs it on save.

  The row IS the live site: writing one recompiles the site's stylesheet. So a rule written while the
  builder's stage says Draft is not in it at all — it waits in the editing session beside the markup
  that carries its class, as `place/3` rather than `put/5`, and the publish that writes that markup
  folds it back in with `merge/2`.

  Every write starts from the row as it is now — `put/5` reads it, and `merge/2` is given it — because
  the row is SHARED. An error page's five statuses are five documents in one row, a second editor on
  the same document is a second browser writing it, and a caller that wrote a map it read when it
  opened would delete everything written since. That is one rule with no exceptions: nothing writes a
  snapshot.

  ### The two places this could have lived instead

  `meta` on the node loses the CSS on the first save: `meta` is derived at parse, so anything put
  there that is not in the markup is gone the next time the document is read back.

  A `data-` attribute holding the rule text round-trips perfectly and was still wrong: it ships to
  every visitor on every request, uncached, and it forfeits `@apply` — the rule never reaches
  Tailwind, so it cannot use the design system the rest of the page is built out of.

  ## Security

  The row is written as the builder's own (`page_code: :builder` in the changeset context), so it
  is written by whoever may open a builder rather than by the stylesheet area alone — see
  `MishkaCmsCore.Runtime.Stylesheet`. `valid_body/1` refuses anything that closes the wrapper early
  and escapes onto the rest of the site.

  ## Deliberately not layered

  `Classes` wraps its rules in `@layer components` so a per-element utility still beats a shared
  class. This is one tier further in: the author wrote it for this element specifically, so it is
  emitted unlayered and therefore last, and it beats the inspector's utilities. That ordering is
  what Bricks, Webflow and WordPress 7.0 all settled on.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.PageBuilder.ElementScopes
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.Stylesheet

  require Ash.Query

  # WHAT THE BUILDER WRITES IT GENERATED: the stylesheet row is written by whoever may open a
  # builder, rather than by the stylesheet area alone. See `MishkaCmsCore.Runtime.Stylesheet`.
  @builder %{page_code: :builder}

  @doc "The reserved row a document's element CSS lives in."
  @spec row_name(String.t()) :: String.t()
  def row_name(owner), do: "builder-elements-#{owner}"

  @doc """
  Every rule this document holds, as `%{scope => body}`.

  Read back out of the compiled row rather than kept anywhere else: the stylesheet IS the record, so
  a rule edited by hand on the Stylesheets page is still the rule here.
  """
  @spec all(map() | nil, String.t() | nil, String.t()) :: %{String.t() => String.t()}
  def all(actor, site_id, owner) do
    case row(actor, site_id, owner) do
      nil -> %{}
      %{content: content} -> parse(content)
    end
  end

  @doc """
  Writes one element's CSS, or clears it when the body is blank.

  Returns the whole map so a caller can hold the current state without reading again.
  """
  @spec put(map() | nil, String.t() | nil, String.t(), String.t(), String.t()) ::
          {:ok, %{String.t() => String.t()}} | {:error, term()}
  def put(actor, site_id, owner, scope, body) do
    with {:ok, rules} <- place(all(actor, site_id, owner), scope, body) do
      write(rules, actor, site_id, owner)
    end
  end

  @doc """
  One element's CSS placed in a set of rules, checked but not written anywhere.

  The builder's draft stage holds its rules in the editing session instead of writing them — the row
  is the live site — and it has to refuse exactly what `put/5` refuses, or the box takes CSS in one
  stage that the publish then throws out.
  """
  @spec place(%{String.t() => String.t()}, String.t() | nil, String.t() | nil) ::
          {:ok, %{String.t() => String.t()}} | {:error, term()}
  def place(rules, scope, body) do
    with :ok <- valid_scope(scope),
         {:ok, body} <- valid_body(body) do
      {:ok, placed(rules, scope, body)}
    end
  end

  @doc """
  Edits laid over the rules as they stand, a blank body clearing the rule it names.

  Per element rather than as one map, and that is the whole point: the publish that folds a draft's
  held CSS into the row is told which elements the author touched, so everything else in the row —
  the four statuses they were not looking at, the rule a second editor wrote a minute ago — is left
  exactly as it is.
  """
  @spec merge(%{String.t() => String.t()}, %{String.t() => String.t()} | nil) ::
          %{String.t() => String.t()}
  def merge(rules, nil), do: rules

  def merge(rules, edits),
    do: Enum.reduce(edits, rules, fn {scope, body}, acc -> placed(acc, scope, body) end)

  @doc "Rewrites the row to hold exactly `rules`, which is what prunes a deleted element's CSS."
  @spec sync(map() | nil, String.t() | nil, String.t(), %{String.t() => String.t()}) ::
          {:ok, %{String.t() => String.t()}} | {:error, term()}
  def sync(actor, site_id, owner, rules), do: write(rules, actor, site_id, owner)

  @doc """
  The rules a tree still refers to. Anything else in the row belongs to an element that is gone.
  """
  @spec live_rules(Tree.t(), %{String.t() => String.t()}) :: %{String.t() => String.t()}
  def live_rules(tree, rules) do
    present =
      tree
      |> Tree.walk()
      |> Enum.map(&Tree.scope(tree, &1.id))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Map.filter(rules, fn {scope, _body} -> MapSet.member?(present, scope) end)
  end

  @doc """
  The CSS for a set of rules. Public because it is the whole contract with the compiler.
  """
  @spec css(%{String.t() => String.t()}) :: String.t()
  def css(rules) when map_size(rules) == 0, do: ""

  def css(rules) do
    rules
    |> Enum.sort_by(fn {scope, _body} -> scope end)
    |> Enum.map_join("\n", fn {scope, body} -> ".#{scope} {\n#{indent(body)}\n}" end)
    |> Kernel.<>("\n")
  end

  @doc """
  Reads a row back into `%{scope => body}`.

  Brace-counted rather than matched with a regular expression, because a body nests — `&:hover { … }`
  and `@media (…) { … }` are the point of the feature — and a pattern that stops at the first `}`
  would truncate every rule that used them. Counted by the same scanner the declarations are read
  with, so a brace inside a string or a comment is text: `content: "}"` ends nothing.
  """
  @spec parse(String.t() | nil) :: %{String.t() => String.t()}
  def parse(nil), do: %{}

  def parse(content) do
    content
    |> String.split(~r/^\.(?=pb-[a-f0-9]{8}\s*\{)/m, trim: true)
    |> Enum.reduce(%{}, &collect/2)
  end

  defp collect(chunk, rules) do
    with [_all, scope, rest] <- Regex.run(~r/^(pb-[a-f0-9]{8})\s*\{(.*)$/s, chunk),
         {:ok, body} <- balanced(rest) do
      Map.put(rules, scope, dedent(body))
    else
      _not_a_rule -> rules
    end
  end

  # Everything up to the `}` that closes the brace the rule opened with, found with `block_end/4` —
  # the same scanner the declaration reader uses, so a `}` inside a string or a comment ends the rule
  # here no more than it ends a declaration there. Nothing closing it at all means the chunk is not a
  # rule, and it is dropped rather than half-read.
  defp balanced(rest) do
    stop = byte_size(rest)

    case block_end(rest, 0, stop, 1) do
      ^stop -> :error
      close -> {:ok, binary_part(rest, 0, close)}
    end
  end

  @typedoc """
  One hand-written declaration, and the bucket of the style panel it competes with.

  `from`/`to` are byte offsets into the body it was read from, so `without/2` can take exactly the
  text the author typed back out again — comments, spacing and all the rest left where they were.
  """
  @type declaration :: %{
          bucket: :base | :hover | :focus | :active,
          property: String.t(),
          value: String.t(),
          text: String.t(),
          from: non_neg_integer(),
          to: non_neg_integer()
        }

  # THE BUCKETS A HAND-WRITTEN RULE CAN REACH, and the reason the list stops there. Custom CSS is
  # emitted last and unlayered, so a top-level `padding: 20px` beats the panel's `p-4`; but it does
  # NOT beat `hover:p-4`, which carries a pseudo-class and therefore more specificity. So a
  # declaration only ever competes with the bucket wearing the same selector, and `&:hover` is the
  # only way to write that by hand.
  #
  # Tablet and Mobile are absent on purpose: they are media queries, and an author's `@media` need
  # not use the panel's breakpoints — claiming a collision would be a guess.
  @pseudo_buckets %{"&:hover" => :hover, "&:focus" => :focus, "&:active" => :active}

  @doc """
  Every declaration a body applies to the element itself, in the order they were written.

  Read with a scanner rather than a regular expression for the reason `parse/1` is: the body nests,
  and a pattern that stops at the first `}` would read `&:hover { color: red }` as a top-level
  declaration of `color`. Nested selectors that are not one of `@pseudo_buckets` — `& > .badge`, a
  media query — are skipped entirely: they style something else, or at a width the panel cannot name.
  """
  @spec declarations(String.t() | nil) :: [declaration()]
  def declarations(nil), do: []

  def declarations(body) when is_binary(body),
    do: body |> scan(0, 0, byte_size(body), :base, []) |> Enum.reverse()

  @doc """
  The nested selectors in a body that reach past the element itself — `& > .badge`, `& .title`.

  On a plain tag that is ordinary CSS about the author's own markup. On a COMPONENT it is a rule
  aimed at markup the kit owns and the author did not write, which the next version of the kit is
  free to rename; the panel says so rather than refusing it, because reaching in is sometimes the
  only way to style something and an author who is told can decide for themselves.

  A pseudo bucket is not one of these: `&:hover` is still this element.
  """
  @spec reaching_selectors(String.t() | nil) :: [String.t()]
  def reaching_selectors(nil), do: []

  def reaching_selectors(body) when is_binary(body),
    do: body |> top_level_selectors() |> Enum.filter(&reaching?/1) |> Enum.uniq()

  # THE SELECTORS WRITTEN AT THE TOP LEVEL OF THE BODY, which is one fact and therefore one scanner:
  # `reaching_selectors/1` asks which of them leave the element, `advice/1` asks which of them are a
  # bare tag name. Read with the same offsets as everything else here, so a brace inside a string or
  # a comment is not mistaken for the start of a block — `content: "{"` is a declaration, and telling
  # its author they had styled a `content: "` inside their element is worse than saying nothing.
  defp top_level_selectors(body),
    do: body |> preludes(0, 0, byte_size(body), []) |> Enum.reverse()

  defp preludes(_body, pos, start, stop, acc) when pos >= stop or start > stop, do: acc

  defp preludes(body, pos, start, stop, acc) do
    case binary_part(body, pos, min(2, stop - pos)) do
      "/*" ->
        preludes(body, past_comment(comment_end(body, pos + 2, stop), stop), start, stop, acc)

      _other ->
        prelude_step(body, :binary.at(body, pos), pos, start, stop, acc)
    end
  end

  defp prelude_step(body, ?{, pos, start, stop, acc) do
    close = block_end(body, pos + 1, stop, 1)
    prelude = body |> binary_part(start, pos - start) |> strip_comments() |> String.trim()

    preludes(body, close + 1, close + 1, stop, collected(prelude, acc))
  end

  defp prelude_step(body, char, pos, _start, stop, acc) when char in [?;, ?}],
    do: preludes(body, pos + 1, pos + 1, stop, acc)

  defp prelude_step(body, quote_char, pos, start, stop, acc) when quote_char in [?", ?'],
    do: preludes(body, quoted_end(body, pos + 1, stop, quote_char), start, stop, acc)

  defp prelude_step(body, _char, pos, start, stop, acc),
    do: preludes(body, pos + 1, start, stop, acc)

  # A block with nothing in front of it — `{ … }` typed by hand, or half a line still being written —
  # names no selector at all, and reporting it as one puts an empty pair of backticks in front of the
  # author.
  defp collected("", acc), do: acc
  defp collected(prelude, acc), do: [prelude | acc]

  # An at-rule is not a selector — `@media (…)` styles this element at a width, not something inside
  # it — and a pseudo bucket is still this element.
  defp reaching?(prelude) do
    cond do
      String.starts_with?(prelude, "@") -> false
      Map.has_key?(@pseudo_buckets, String.downcase(prelude)) -> false
      !String.contains?(prelude, "&") -> true
      true -> Regex.match?(~r/&\s*[>+~\s]\S|&\s+\S/, prelude)
    end
  end

  @doc """
  The body with one declaration taken out — what **Move to controls** leaves behind.

  `index` is a position in `declarations/1`. Out of range, the body is returned untouched, because a
  stale click from a panel rendered against an older body must not delete a different rule.
  """
  @spec without(String.t() | nil, non_neg_integer()) :: String.t()
  def without(body, index) when is_binary(body) and is_integer(index) and index >= 0 do
    case Enum.at(declarations(body), index) do
      nil -> body
      declaration -> body |> cut(declaration) |> tidy()
    end
  end

  def without(body, _index), do: body || ""

  defp cut(body, %{from: from, to: to}) do
    binary_part(body, 0, from) <> binary_part(body, to, byte_size(body) - to)
  end

  # Taking a line out of the middle leaves its indentation and its newline behind, which reads as the
  # author having typed a blank line on purpose. Only whitespace is touched.
  defp tidy(body) do
    body
    |> String.replace(~r/[ \t]+$/m, "")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.replace(~r/\{\s*\n\s*\n/, "{\n")
    |> String.trim()
  end

  # Clamped, because `declarations/1` is also read against what is CURRENTLY in the textarea — which
  # is unbalanced for as long as somebody is halfway through typing a `&:hover {` block.
  defp scan(body, pos, start, stop, bucket, acc) when pos >= stop,
    do: declare(body, min(start, stop), stop, stop, bucket, acc)

  defp scan(body, pos, start, stop, bucket, acc) do
    case binary_part(body, pos, min(2, stop - pos)) do
      "/*" ->
        scan(body, past_comment(comment_end(body, pos + 2, stop), stop), start, stop, bucket, acc)

      _other ->
        step(body, :binary.at(body, pos), pos, start, stop, bucket, acc)
    end
  end

  # A QUOTED VALUE IS OPAQUE. `background-image: url("a;b.png")` holds a `;` that ends nothing, and
  # reading it as one would split a declaration in half. Nothing a control can hold looks like this,
  # so the cost of getting it wrong is small — but so is the cost of getting it right.
  defp step(body, quote_char, pos, start, stop, bucket, acc) when quote_char in [?", ?'],
    do: scan(body, quoted_end(body, pos + 1, stop, quote_char), start, stop, bucket, acc)

  defp step(body, ?;, pos, start, stop, bucket, acc) do
    scan(body, pos + 1, pos + 1, stop, bucket, declare(body, start, pos, pos + 1, bucket, acc))
  end

  defp step(body, ?{, pos, start, stop, bucket, acc) do
    close = block_end(body, pos + 1, stop, 1)
    prelude = binary_part(body, start, pos - start)

    scan(
      body,
      close + 1,
      close + 1,
      stop,
      bucket,
      nested(body, prelude, pos + 1, close, bucket, acc)
    )
  end

  defp step(body, ?}, pos, _start, stop, bucket, acc),
    do: scan(body, pos + 1, pos + 1, stop, bucket, acc)

  defp step(body, _char, pos, start, stop, bucket, acc),
    do: scan(body, pos + 1, start, stop, bucket, acc)

  # One level only. `&:hover { & > .badge { … } }` styles the badge on hover, which is neither this
  # element nor a bucket, so the inner block falls through `@pseudo_buckets` and is dropped.
  defp nested(body, prelude, from, to, :base, acc) do
    case Map.get(@pseudo_buckets, prelude |> String.trim() |> String.downcase()) do
      nil -> acc
      bucket -> scan(body, from, from, to, bucket, []) ++ acc
    end
  end

  defp nested(_body, _prelude, _from, _to, _bucket, acc), do: acc

  defp declare(body, start, stop, cut_to, bucket, acc) do
    raw = binary_part(body, start, stop - start)
    text = raw |> strip_comments() |> String.trim()

    case String.split(text, ":", parts: 2) do
      [property, value] -> collect(property, value, text, start + lead(raw), cut_to, bucket, acc)
      _not_a_declaration -> acc
    end
  end

  # WHERE THE DECLARATION REALLY BEGINS inside the span the scanner handed over. A span runs from
  # just after the previous `;`, so it carries whatever sat between the two — the blank line, and the
  # comment somebody wrote above this line. Cutting from the front of the span would take that
  # comment out along with the declaration it explains.
  defp lead(raw), do: lead(raw, 0)

  defp lead(<<char, rest::binary>>, offset) when char in ~c" \t\n\r",
    do: lead(rest, offset + 1)

  defp lead(<<"/*", rest::binary>>, offset) do
    case :binary.match(rest, "*/") do
      {at, _length} -> lead(binary_part(rest, at + 2, byte_size(rest) - at - 2), offset + at + 4)
      :nomatch -> offset
    end
  end

  defp lead(_raw, offset), do: offset

  # `--brand: red` is a custom property and `@apply p-4` an at-rule; neither is something a control
  # could ever hold, and both would otherwise be read as a declaration of `--brand` and `@apply`.
  defp collect(property, value, text, start, cut_to, bucket, acc) do
    property = String.trim(property)
    value = String.trim(value)

    case property == "" or value == "" or String.starts_with?(property, ["-", "@"]) do
      true ->
        acc

      false ->
        [
          %{
            bucket: bucket,
            property: String.downcase(property),
            value: value,
            text: text,
            from: start,
            to: cut_to
          }
          | acc
        ]
    end
  end

  defp strip_comments(text), do: String.replace(text, ~r|/\*.*?\*/|s, "")

  # WHERE A COMMENT ENDS, and `:none` when nobody closed it. The scanners that read half-typed text
  # take `:none` as running to the end of what there is; `structure/4` refuses it, because in a body
  # about to be saved it swallows the `}` that closes the wrapper and eats the rest of the sheet.
  defp comment_end(body, pos, stop) do
    case :binary.match(body, "*/", scope: {pos, stop - pos}) do
      {at, _length} -> at + 2
      :nomatch -> :none
    end
  end

  defp past_comment(:none, stop), do: stop
  defp past_comment(at, _stop), do: at

  defp quoted_end(_body, pos, stop, _quote_char) when pos >= stop, do: stop

  defp quoted_end(body, pos, stop, quote_char) do
    case :binary.at(body, pos) do
      ?\\ -> quoted_end(body, pos + 2, stop, quote_char)
      ^quote_char -> pos + 1
      _other -> quoted_end(body, pos + 1, stop, quote_char)
    end
  end

  # WHERE A BLOCK ENDS, and the only place in this module that answers it. A brace inside a string or
  # a comment is text — `content: "}"` is a declaration and `/* } */` is a note — so both are skipped
  # whole. Counting them instead ends the block early, which reads the rest of the author's rule as
  # though it were written at the level above.
  defp block_end(_body, pos, stop, _depth) when pos >= stop, do: stop

  defp block_end(body, pos, stop, depth) do
    case binary_part(body, pos, min(2, stop - pos)) do
      "/*" -> block_end(body, past_comment(comment_end(body, pos + 2, stop), stop), stop, depth)
      _other -> block_step(body, :binary.at(body, pos), pos, stop, depth)
    end
  end

  defp block_step(body, quote_char, pos, stop, depth) when quote_char in [?", ?'],
    do: block_end(body, quoted_end(body, pos + 1, stop, quote_char), stop, depth)

  defp block_step(body, ?{, pos, stop, depth), do: block_end(body, pos + 1, stop, depth + 1)
  defp block_step(_body, ?}, pos, _stop, 1), do: pos
  defp block_step(body, ?}, pos, stop, depth), do: block_end(body, pos + 1, stop, depth - 1)
  defp block_step(body, _char, pos, stop, depth), do: block_end(body, pos + 1, stop, depth)

  defp placed(rules, scope, ""), do: Map.delete(rules, scope)
  defp placed(rules, scope, body), do: Map.put(rules, scope, body)

  defp valid_scope(scope) do
    case ElementScopes.scope?(scope) do
      true -> :ok
      false -> {:error, gettext("That element has no style scope.")}
    end
  end

  # THE ONE STRUCTURAL RULE, and it is about braces rather than selectors. Scoping works because the
  # text is wrapped in `.pb-xxxxxxxx { … }`, so the only way out is to close that wrapper early with
  # a `}` — after which everything is loose CSS on the whole site. A nested selector cannot escape:
  # under CSS nesting `body { … }` inside the braces means `.pb-xxxxxxxx body { … }`, which is a
  # descendant of this element and is a thing authors legitimately want.
  #
  # An earlier version also demanded that every nested selector start with `&`. It refused
  # `body { … }` written first and allowed the same thing written after a declaration, because a
  # pattern anchored on `^` or `}` cannot see the second one — inconsistent, and guarding against
  # nothing.
  #
  # A BRACE THAT IS TEXT CLOSES NOTHING. `content: "}"`, `url("a}b.png")` and `/* } */` are all
  # ordinary CSS, and a check that counted every brace in the body refused all three with a message
  # about an unmatched brace — the author reads it, cannot find one, and the box has nothing more to
  # say. The one thing that IS refused alongside them is a comment nobody closed: it swallows the
  # `}` that ends the wrapper, so everything after it in the stylesheet is eaten until the next `*/`.
  @doc """
  What is worth telling an author about CSS that is valid and probably not what they meant.

  `nil` when there is nothing to say. This never refuses anything: a nested selector is real CSS and
  a descendant rule is a thing people write on purpose.

  The one it catches is the mistake this box invites. The pane is titled with the element — `main —
  this element's own` — so an author writes what looks like the rule for it:

      main { color: red }

  Wrapped, that is `.pb-xxxxxxxx { main { color: red } }`: a `main` INSIDE the element, which for a
  `main` is nothing at all. It saves, it is announced as applied, and the page does not change. The
  author has no way to tell that from a feature that is broken.
  """
  @spec advice(String.t() | nil) :: String.t() | nil
  def advice(body) when is_binary(body) do
    case descendant_selectors(body) do
      [] ->
        nil

      [one] ->
        gettext(
          "`%{selector}` styles a %{selector} INSIDE this element. For the element itself write the declarations on their own, or start the selector with `&`.",
          selector: one
        )

      many ->
        gettext(
          "%{selectors} style elements INSIDE this one. For the element itself write the declarations on their own, or start the selector with `&`.",
          selectors: Enum.map_join(many, ", ", &"`#{&1}`")
        )
    end
  end

  def advice(_body), do: nil

  # Only the selectors at the TOP level of the body, because a nested one is already inside somebody
  # else's block and means what it says. `@media` and friends carry declarations for this element, so
  # they are not descendants; `&` is the element, so nor is that.
  defp descendant_selectors(body) do
    body
    |> top_level_selectors()
    |> Enum.reject(&(String.starts_with?(&1, "&") or String.starts_with?(&1, "@")))
    |> Enum.uniq()
  end

  defp valid_body(nil), do: {:ok, ""}
  defp valid_body(body), do: body |> String.trim() |> checked()

  defp checked(""), do: {:ok, ""}
  defp checked(body), do: body |> structure() |> verdict(body)

  defp verdict(:ok, body), do: {:ok, body}
  defp verdict(:unbalanced, _body), do: {:error, gettext("That CSS has an unmatched { or }.")}

  defp verdict(:open_comment, _body),
    do: {:error, gettext("That CSS has a /* that is never closed.")}

  defp structure(body), do: structure(body, 0, byte_size(body), 0)

  defp structure(_body, pos, stop, 0) when pos >= stop, do: :ok
  defp structure(_body, pos, stop, _depth) when pos >= stop, do: :unbalanced

  defp structure(body, pos, stop, depth) do
    case binary_part(body, pos, min(2, stop - pos)) do
      "/*" -> commented(comment_end(body, pos + 2, stop), body, stop, depth)
      _other -> structure_step(body, :binary.at(body, pos), pos, stop, depth)
    end
  end

  defp commented(:none, _body, _stop, _depth), do: :open_comment
  defp commented(at, body, stop, depth), do: structure(body, at, stop, depth)

  defp structure_step(body, quote_char, pos, stop, depth) when quote_char in [?", ?'],
    do: structure(body, quoted_end(body, pos + 1, stop, quote_char), stop, depth)

  defp structure_step(body, ?{, pos, stop, depth), do: structure(body, pos + 1, stop, depth + 1)
  defp structure_step(_body, ?}, _pos, _stop, 0), do: :unbalanced
  defp structure_step(body, ?}, pos, stop, depth), do: structure(body, pos + 1, stop, depth - 1)
  defp structure_step(body, _char, pos, stop, depth), do: structure(body, pos + 1, stop, depth)

  defp indent(body) do
    body
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> "  " <> line
    end)
  end

  defp dedent(body) do
    body
    |> String.trim("\n")
    |> String.split("\n")
    |> Enum.map_join("\n", &String.replace_prefix(&1, "  ", ""))
    |> String.trim()
  end

  defp write(rules, actor, site_id, owner) do
    case {row(actor, site_id, owner), map_size(rules)} do
      {nil, 0} -> {:ok, %{}}
      {nil, _some} -> create(actor, site_id, owner, rules)
      {existing, _any} -> update(actor, existing, rules)
    end
  end

  defp create(%{site_id: nil} = actor, site_id, owner, rules) do
    Stylesheet
    |> Ash.Changeset.for_create(
      :master_create,
      Map.put(attrs(owner, rules), :site_id, site_id),
      actor: actor,
      tenant: nil,
      context: @builder
    )
    |> Ash.create()
    |> saved(rules)
  end

  defp create(actor, site_id, owner, rules) do
    Stylesheet
    |> Ash.Changeset.for_create(:create, attrs(owner, rules),
      actor: actor,
      tenant: site_id,
      context: @builder
    )
    |> Ash.create()
    |> saved(rules)
  end

  defp attrs(owner, rules) do
    %{
      name: row_name(owner),
      description: "Per-element CSS, written by the page builder",
      content: content(rules),
      kind: :custom,
      format: :css,
      active: true
    }
  end

  defp update(%{site_id: nil} = actor, existing, rules) do
    existing
    |> Ash.Changeset.for_update(:master_update, %{content: content(rules)},
      actor: actor,
      tenant: nil,
      context: @builder
    )
    |> Ash.update()
    |> saved(rules)
  end

  defp update(actor, existing, rules) do
    existing
    |> Ash.Changeset.for_update(:update, %{content: content(rules)},
      actor: actor,
      tenant: existing.site_id,
      context: @builder
    )
    |> Ash.update()
    |> saved(rules)
  end

  # A row must have content, and clearing the last rule must not therefore fail.
  defp content(rules) do
    case css(rules) do
      "" -> "/* No element has its own CSS on this page yet. */\n"
      css -> css
    end
  end

  defp saved({:ok, _record}, rules), do: {:ok, rules}
  defp saved({:error, reason}, _rules), do: {:error, reason}

  # SCOPED, NOT CAPPED. The same read `MishkaCmsCore.Runtime.PageBuilder.Classes` makes, and for the
  # same reason: `:master_read` bypasses multitenancy, so asking for one row before saying which
  # site it is for can answer with another site's. A tenant's read Ash has already scoped, and the
  # globals are the scope whose `site_id` is `nil`, so the filter is written once for both. The
  # identity is `[:name, :site_id]`, so the site belongs in the query.
  defp row(actor, site_id, owner) do
    name = row_name(owner)

    Stylesheet
    |> Ash.Query.filter(name == ^name)
    |> scoped(site_id)
    |> read(actor, site_id)
  end

  defp scoped(query, nil), do: Ash.Query.filter(query, is_nil(site_id))
  defp scoped(query, site_id), do: Ash.Query.filter(query, site_id == ^site_id)

  defp read(query, %{site_id: nil} = actor, _site_id) do
    query
    |> Ash.Query.for_read(:master_read, %{}, actor: actor)
    |> Ash.read()
    |> first()
  end

  defp read(query, actor, site_id) do
    query
    |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: site_id)
    |> Ash.read()
    |> first()
  end

  # The identity leaves a scoped query at most one row to answer with. Pagination is on for the
  # master read, so what comes back is a page rather than a list.
  defp first({:ok, %Ash.Page.Offset{results: rows}}), do: first({:ok, rows})
  defp first({:ok, [row | _rest]}), do: row
  defp first({:ok, []}), do: nil
  defp first({:error, _reason}), do: nil
end
