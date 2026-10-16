# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Review do
  @moduledoc """
  What the builder needs from the review thread: the counter, and getting to an element.

  The thread itself is drawn by Gervaz — `MishkaCmsCoreWeb.Templates.ReviewComments` reads
  `MishkaCmsCore.Runtime.PageComment` through the `:for_editor` action and owns everything about
  listing, filtering and paging. Nothing here duplicates that. This is the two things the EDITOR
  needs that a table cannot answer.

  ## The counter

  The red number beside Review is unresolved BUGS, and it is a `COUNT` — not `length/1` over a list
  the sheet happens to have loaded. The sheet may be closed, may be showing "All", may have loaded
  one page of fifty; none of that can be allowed to change the number. Asking the database is both
  cheaper and the only answer that is always right.

  ## Getting to an element

  A note's `node_id` is the editor's own `n<8>` handle, minted fresh by every `Tree.parse/1`. It is
  a soft reference by construction: the element can be deleted, or the document re-parsed under it,
  and the id will point at nothing. `locate/2` is the whole of what to do about that — `{:ok, id}`
  when the element is still there, `:gone` when it is not — so that the caller shows a message
  instead of selecting nil and every caller behaves the same way.
  """

  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.PageComment

  require Ash.Query

  @doc """
  How many unresolved bugs this document has.

  Derived, always: it counts rows, so creating a bug, resolving one, reopening one and deleting one
  all move it without anything having to remember to.

  Returns 0 rather than raising when the read fails. A counter is chrome; a builder that will not
  open because a badge could not be computed is a worse outcome than a badge that reads zero.
  """
  @spec open_bugs(map()) :: non_neg_integer()
  def open_bugs(scope) do
    scope
    |> query(status: :open)
    |> Ash.Query.filter(type == :bug)
    |> Ash.count(actor: scope[:actor], authorize?: false)
    |> case do
      {:ok, count} -> count
      _unavailable -> 0
    end
  end

  @doc """
  Every note on this document, newest first.

  Used by the counter's siblings and by tests; the sheet itself reads through the Gervaz table.
  """
  @spec list(map(), keyword()) :: [PageComment.t()]
  def list(scope, opts \\ []) do
    scope
    |> query(opts)
    # The replies come with the note they answer. `:for_editor` returns top-level notes only, so a
    # caller reading the thread without this sees the questions and none of the answers.
    |> Ash.Query.load([:author, :resolved_by, replies: [:author, :resolved_by]])
    |> Ash.read(actor: scope[:actor], authorize?: false)
    |> case do
      {:ok, %{results: results}} -> results
      {:ok, results} when is_list(results) -> results
      _unavailable -> []
    end
  end

  @doc """
  One note by id, with its author and resolver loaded, or `nil`.

  Scoped to WHO IS ASKING, not to the id: `:get_any` bypasses multitenancy, so the id alone reached
  every site's notes — and the id travels in a `phx-value-id` that anyone can type. A master reads
  any note; a tenant reads its own site's; nobody else reads one at all.
  `MishkaCmsCore.Runtime.PageBuilder.Snippets.delete/2` scopes its own by-id path the same way.
  """
  @spec fetch(String.t(), map()) :: PageComment.t() | nil
  def fetch(id, scope) do
    PageComment
    |> Ash.Query.for_read(:get_any, %{}, actor: scope[:actor], authorize?: false)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.load([:author, :resolved_by])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, comment} -> readable(comment, scope[:actor])
      _missing -> nil
    end
  end

  # A note nobody can say belongs to the asker is not there. The last clause is the one that
  # matters: an actor without a `site_id` field at all — a bare map, or nothing — reads nothing.
  defp readable(nil, _actor), do: nil
  defp readable(comment, %{site_id: nil}), do: comment
  defp readable(%{site_id: site_id} = comment, %{site_id: site_id}), do: comment
  defp readable(_comment, _actor), do: nil

  @doc """
  Where a note points, if it still points anywhere.

    * `{:ok, node_id}` — the element is in the document and can be selected.
    * `:page` — the note was never anchored to an element; it is about the whole page.
    * `:gone` — it was anchored, and that element is no longer here.

  Three answers rather than two, because "about the page" and "the element was deleted" deserve
  different words in front of the reader, and a caller that cannot tell them apart will pick one and
  be wrong half the time.
  """
  @spec locate(PageComment.t() | map() | nil, Tree.t()) :: {:ok, String.t()} | :page | :gone
  def locate(nil, _tree), do: :gone

  def locate(comment, tree) when is_map(comment) do
    node_id = Map.get(comment, :node_id)
    node_path = Map.get(comment, :node_path)

    cond do
      is_nil(node_id) and is_nil(node_path) -> :page
      Tree.get(tree, node_id) -> {:ok, node_id}
      found = at_path(tree, node_path, comment) -> {:ok, found}
      true -> :gone
    end
  end

  def locate(_comment, _tree), do: :gone

  # THE PATH IS CHECKED, NOT TRUSTED. Deleting an element slides its next sibling into that index, so
  # a bare positional hit would select a different thing with total confidence. The label the note
  # captured at write time is what makes a positional anchor safe: same place AND same kind of
  # element, or nothing.
  defp at_path(tree, path, comment) do
    with id when is_binary(id) <- Tree.at_address(tree, path),
         node when not is_nil(node) <- Tree.get(tree, id),
         label when is_binary(label) <- Map.get(comment, :node_label),
         true <- Node.label(node) == label do
      id
    else
      _mismatch -> nil
    end
  end

  @doc """
  The `defaults` the composer is seeded with — everything the editor already knows.

  This is what makes the form two fields instead of seven, and what makes an element note and a page
  note the same code path: with nothing selected, `node_id` is simply nil.

  `node_label` is captured HERE, at compose time, and stored with the note, because the element it
  names can be deleted afterwards.
  """
  @spec compose_defaults(map()) :: map()
  def compose_defaults(scope) do
    # A REPLY IS ABOUT WHAT ITS PARENT WAS ABOUT. Anchoring it to whatever happens to be selected
    # when you press Reply would file the answer against a different element than the question.
    {node_id, node_path, node_label} = anchor(scope)

    %{
      section: scope[:section] || :page,
      document_id: scope[:document_id],
      editor_site_id: scope[:site_id],
      author_id: scope[:author_id],
      node_id: node_id,
      # WHERE THE ELEMENT IS, not what this parse happens to call it. The id is session-local by
      # construction; this is derived from the document's shape, so the colleague reading the note in
      # their own session resolves it to the same element.
      node_path: node_path,
      node_label: node_label,
      # WHAT THE COMPOSER IS ANSWERING, or nil for a note that starts a thread. Changing it rebuilds
      # the form, which is the reset that turns the box into a reply box and back again.
      parent_comment_id: reply_to_id(scope[:reply_to]),
      # A COMPOSER THAT KEEPS THE NOTE YOU JUST POSTED IS BROKEN. The form has no `phx-change` — a
      # round trip per keystroke is not worth it for two fields — so LiveView does not own its
      # inputs and cannot clear them. Changing `defaults` rebuilds the form, which is exactly the
      # reset that is wanted, and the revision changes on every write. Nothing is lost by it:
      # `refresh_review/1` bumps it only after a note has already been saved.
      revision: scope[:revision]
    }
  end

  defp anchor(%{reply_to: %{node_id: node_id, node_path: node_path, node_label: node_label}}),
    do: {node_id, node_path, node_label}

  # "ABOUT THE WHOLE PAGE" IS A NOTE WITH NO ANCHOR — the same shape as a note written with nothing
  # selected, and the same code path. The override only reaches here; the canvas keeps its selection,
  # because clearing that to say one thing about the page would lose the place you were working in.
  defp anchor(%{on_page?: true}), do: {nil, nil, nil}

  defp anchor(scope), do: {scope[:node_id], scope[:node_path], scope[:node_label]}

  defp reply_to_id(%{id: id}), do: id
  defp reply_to_id(_none), do: nil

  @doc """
  The `path_params` the Gervaz thread is scoped by.

  PREFIXED keys, and keyed by ATOM. Gervaz turns any path param whose name matches a resource
  attribute into an equality filter and tests membership against `Ash.Resource.Info.attributes/1`,
  whose names are atoms — so `site_id` would drop the global rows this read exists to include, and a
  string key would match nothing at all.
  """
  @spec thread_params(map()) :: map()
  def thread_params(scope) do
    %{
      editor_site_id: scope[:site_id],
      editor_section: scope[:section] || :page,
      editor_document_id: scope[:document_id]
    }
  end

  defp query(scope, opts) do
    PageComment
    |> Ash.Query.for_read(
      :for_editor,
      %{
        site_id: scope[:site_id],
        section: scope[:section] || :page,
        document_id: scope[:document_id],
        status: opts[:status]
      },
      actor: scope[:actor],
      authorize?: false
    )
    |> Ash.Query.page(limit: opts[:limit] || 200)
  end
end
