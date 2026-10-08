defmodule MishkaCmsCore.PlainText do
  @moduledoc """
  What a plain-text field stores: the text a person typed, with every tag taken out and nothing
  escaped.

  A title, a name, a short description or a notification's line is text, not HTML. It is stored as
  it was typed — `Tom & Jerry's "cat"` stays exactly that — and escaped where it is written out:
  HEEx escapes it into a page, `MishkaCmsCore.Runtime.Seo` into the head and its JSON-LD. Stored
  escaped instead, each of those escapes it a second time, and a reader sees `Tom &amp; Jerry`.

  Markup is taken out, never kept, by `MishkaGervaz.Helpers.strip_tags/1`: `Tom <b>"cat"</b>` is
  stored as `Tom "cat"`, and `<script>alert(1)</script>Hi` as `alert(1)Hi` — the script's text,
  without the script. Removal repeats until there is nothing left to remove, so a tag hidden inside
  a tag (`<<b>b>`) goes too, and the result is stable: `text(text(value)) == text(value)`, so saving
  a form twice changes nothing. An entity typed into a field is text like any other: `&amp;` is kept
  as the five characters typed.

      iex> MishkaCmsCore.PlainText.text(~s(Tom & Jerry's <b>"cat"</b>))
      ~s(Tom & Jerry's "cat")

  ## On a field

  A GuardedStruct field takes `field/2` as its `validator:`, which runs before the field's
  `derives:`, so `trim` and the `validate(...)` ops see the text without its markup:

      field :title, :string,
        validator: {MishkaCmsCore.PlainText, :field},
        derives: "sanitize(trim) validate(string, not_empty, max_len=255)"

  Not a `sanitize(...)` op: an Ash resource's GuardedStruct pipeline only reaches the derive
  extensions the host application lists in its own config, and an op nobody listed passes the
  value through as it came. The validator needs no configuration, and a missing one fails
  compilation.
  """

  @escaped %{"&amp;" => "&", "&lt;" => "<", "&gt;" => ">"}

  @doc """
  `value` without its tags, everything else as it was — `MishkaGervaz.Helpers.strip_tags/1`, the
  rule Gervaz's forms, table search and URL filters use too. Anything but a string is returned as
  it is, for the field's own `validate(...)` to judge.
  """
  @spec text(term()) :: term()
  defdelegate text(value), to: MishkaGervaz.Helpers, as: :strip_tags

  @doc """
  GuardedStruct's per-field `validator:` hook: the field's value as `text/1` returns it.
  """
  @spec field(atom(), term()) :: {:ok, atom(), term()}
  def field(name, value), do: {:ok, name, text(value)}

  @doc """
  The text an HTML fragment shows — a rich-text field's, for a description or a summary. Its tags
  are taken out by `HtmlSanitizeEx.strip_tags/1` and its entities read: `<p>Tom &amp; Jerry</p>` is
  `Tom & Jerry`. Anything but a string is returned as it is.
  """
  @spec from_html(term()) :: term()
  def from_html(html) when is_binary(html),
    do:
      html
      |> HtmlSanitizeEx.strip_tags()
      |> String.replace(Map.keys(@escaped), &Map.fetch!(@escaped, &1))

  def from_html(value), do: value
end
