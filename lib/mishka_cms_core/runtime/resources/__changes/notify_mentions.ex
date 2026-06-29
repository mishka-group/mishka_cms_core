defmodule MishkaCmsCore.Runtime.Resources.Changes.NotifyMentions do
  @moduledoc """
  Tells the people a note names that it names them.

  ## Why it is on the resource and not in the panel

  The builder is not the only way a note is written — the JSON:API reaches the same actions, and a
  seed or an AI reviewer will too. A mention that only notifies when it was typed in the sidebar is
  a mention that quietly stops working the first time something else writes one.

  ## Why `after_action` and not `before_action`

  The notification carries the note's id and links to the document it is about, so it has nothing
  to say until the row exists. It also runs on the way out on purpose: a create that is going to
  fail should not have told anybody it succeeded.

  `MishkaCmsCore.Runtime.PageBuilder.Mentions.notify/2` swallows its own failures and returns `:ok`,
  so a notification centre that is unavailable cannot turn a saved note into a failed write in
  front of the person who typed it.
  """
  use Ash.Resource.Change

  alias MishkaCmsCore.Runtime.PageBuilder.Mentions

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, comment ->
      Mentions.notify(comment)
      {:ok, comment}
    end)
  end
end
