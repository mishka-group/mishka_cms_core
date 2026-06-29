defmodule MishkaCmsCore.Runtime.Resources.Validations.ParentBelongsToDocument do
  @moduledoc """
  The two things a reply's parent has to be.

  Learned from `MishkaBlog.Comment`, which carries the same pair for the same reasons and has had
  longer to find out they were needed:

    * **On the same document.** A reply that answers a note about another page is not an answer; it
      is a note that has been moved somewhere nobody will look for it, silently, because the thread
      it appears in is chosen by `document_id` and not by the parent.
    * **Not itself.** A row that is its own parent is a cycle, and every renderer that walks the
      thread hangs on it. A form cannot produce this by hand, but a stale id or a copied payload
      can.

  Both are checked here rather than in the panel because the panel is not the only way in — the
  JSON:API and a seed reach the same actions.

  Nothing is checked when `parent_comment_id` is absent: a note that starts a thread is the common
  case and has no parent to be wrong about.
  """
  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.get_attribute(:parent_comment_id)
    |> check(changeset, context)
  end

  defp check(nil, _changeset, _context), do: :ok

  defp check(parent_id, changeset, context) do
    cond do
      parent_id == changeset.data.id ->
        {:error,
         field: :parent_comment_id,
         message: dgettext_noop("errors", "A note cannot be a reply to itself.")}

      true ->
        same_document(parent_id, changeset, context)
    end
  end

  # `:get_any` bypasses tenancy on purpose: a master replying to a note on a global component has no
  # tenant, and a tenant replying to one has a tenant the parent does not share. What makes the
  # answer safe is the document check below, not the read.
  defp same_document(parent_id, changeset, _context) do
    document_id = Ash.Changeset.get_attribute(changeset, :document_id)
    section = Ash.Changeset.get_attribute(changeset, :section)

    MishkaCmsCore.Runtime.PageComment
    |> Ash.get(parent_id, action: :get_any, authorize?: false)
    |> case do
      {:ok, %{document_id: ^document_id, section: ^section}} ->
        :ok

      {:ok, _elsewhere} ->
        {:error,
         field: :parent_comment_id,
         message:
           dgettext_noop(
             "errors",
             "That note is about a different document, so this cannot be a reply to it."
           )}

      _missing ->
        {:error,
         field: :parent_comment_id,
         message: dgettext_noop("errors", "The note being replied to is no longer here.")}
    end
  end

  @impl true
  def has_validate?, do: true

  @impl true
  def supports(_opts), do: [Ash.Changeset]
end
