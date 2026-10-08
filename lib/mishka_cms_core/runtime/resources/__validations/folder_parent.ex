defmodule MishkaCmsCore.Runtime.Resources.Validations.FolderParent do
  @moduledoc """
  Refuses a media folder put inside itself, or inside one of its own subfolders.

  Either would cut the folder and everything under it off from the top level, with no way back
  through the library. Asked only when an existing folder's `parent_id` changes: a new folder has
  nothing under it yet.

  The folders above the new parent are read as the action's actor, one level at a time — see
  `MishkaCmsCore.Runtime.MediaCategory.trail/2`. When they cannot be read, the move is refused
  rather than let through unchecked.

  Each refusal is on `:parent_id`, in the `errors` domain. Whether the parent is a live folder of the
  same site is `MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference`'s check.
  """
  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.MediaCategory

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(%{action_type: :update, data: %{id: id}} = changeset, _opts, context) do
    if Ash.Changeset.changing_attribute?(changeset, :parent_id),
      do: changeset |> Ash.Changeset.get_attribute(:parent_id) |> check(id, context),
      else: :ok
  end

  def validate(_changeset, _opts, _context), do: :ok

  defp check(nil, _id, _context), do: :ok

  defp check(id, id, _context),
    do: refuse(dgettext_noop("errors", "A folder cannot go inside itself."))

  defp check(parent_id, id, context) do
    case MediaCategory.trail(parent_id, actor: context.actor, authorize?: context.authorize?) do
      {:ok, trail} ->
        if Enum.any?(trail, &(&1.id == id)) do
          refuse(dgettext_noop("errors", "A folder cannot go inside one of its own folders."))
        else
          :ok
        end

      {:error, _unread} ->
        refuse(dgettext_noop("errors", "That folder could not be checked. Try again."))
    end
  end

  defp refuse(message), do: {:error, field: :parent_id, message: message}

  @impl true
  def has_validate?, do: true

  @impl true
  def supports(_opts), do: [Ash.Changeset]
end
