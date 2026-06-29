defmodule MishkaCmsCore.Runtime.PageBuilder.Comment do
  @moduledoc """
  The shape and the wording of a review note — what the storage layer is built around.

  ## What this is now

  Notes live in the database: `MishkaCmsCore.Runtime.PageComment`. This module is what that resource
  was built from, and what is left of it is the two things a struct is better at than a table:

    * `new/1` — the validated constructor, including the id shape and the sanitising of a note's
      text. Still the only place a note's fields are described in one piece.
    * `ago/2` — "just now" / "4m" / "3h" / "2d". Coarse on purpose: a review is read in the order it
      was written, and a timestamp to the second is noise beside a sentence.

  It used to be the storage as well: a list on the `EditorSession` in ETS, swept after a day idle.
  Its own moduledoc said the next step was an Ash resource, and that is what happened. The field
  names were kept, so the swap was storage rather than a rewrite of the panel.
  """
  use Gettext, backend: MishkaCmsCore.Gettext
  use GuardedStruct

  # The text is stripped of tags and trimmed before it is stored — a review note is prose, and the
  # sheet renders it as text, so markup in it is never wanted. Sanitizers run before validators, so a
  # note that was nothing but whitespace fails `not_empty` and is refused rather than posted, which
  # is what makes an accidental Enter on an empty box a no-op.
  guardedstruct do
    field(:id, :string, enforce: true, derives: "validate(string)")
    field(:node_id, :string, derives: "validate(string, regex=^n[a-z0-9]{8}$)")
    field(:node_label, :string, derives: "sanitize(strip_tags, trim)")
    field(:author, :string, derives: "sanitize(strip_tags, trim)")

    field(:author_id, :string)

    field(:text, :string,
      enforce: true,
      derives: "sanitize(strip_tags, trim) validate(not_empty)"
    )

    field(:resolved?, :boolean, default: false)
    field(:at, :any)
  end

  @doc """
  Builds a comment, minting the id and timestamp.

  Returns `{:error, _}` when the note is blank, so the caller can leave the composer alone instead of
  posting nothing.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    attrs
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put("id", generate_id())
    |> Map.put("at", DateTime.utc_now())
    |> Map.put_new("node_label", gettext("the whole page"))
    |> Map.put_new("author", gettext("Someone"))
    |> builder()
  end

  @doc "A fresh comment id — the same shape the tree uses for nodes, with a `c` prefix."
  @spec generate_id() :: String.t()
  def generate_id do
    "c" <> Base.encode32(:crypto.strong_rand_bytes(5), case: :lower, padding: false)
  end

  @doc "Marks a comment resolved, or leaves it alone when it already is."
  @spec resolve(t()) :: t()
  def resolve(comment), do: %{comment | resolved?: true}

  @doc "The comments still awaiting attention, newest first."
  @spec open([t()]) :: [t()]
  def open(comments), do: Enum.reject(comments, & &1.resolved?)

  @doc """
  A short, human relative time for the sheet — "just now", "4m", "3h", "2d".

  Deliberately coarse: a review thread wants "roughly when", and a coarse label does not need the
  page to re-render every second to stay honest.
  """
  @spec ago(t(), DateTime.t()) :: String.t()
  def ago(%{at: %DateTime{} = at}, now) do
    now |> DateTime.diff(at, :second) |> label()
  end

  def ago(_comment, _now), do: ""

  defp label(seconds) when seconds < 60, do: gettext("just now")
  defp label(seconds) when seconds < 3_600, do: gettext("%{count}m", count: div(seconds, 60))
  defp label(seconds) when seconds < 86_400, do: gettext("%{count}h", count: div(seconds, 3_600))
  defp label(seconds), do: gettext("%{count}d", count: div(seconds, 86_400))
end
