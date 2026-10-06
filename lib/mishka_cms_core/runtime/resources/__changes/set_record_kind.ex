defmodule MishkaCmsCore.Runtime.Resources.Changes.SetRecordKind do
  @moduledoc """
  Writes the action's `record` argument — the kind of record each address of a page shows,
  `"blog:post"` — into `extra["record"]`, where `MishkaCmsCore.Runtime.Seo.record_of/1` reads it. An
  empty one takes it out: the page shows one thing at one address.

  The kind is a key of `extra` rather than a column, and the forms offer it as a field of its own,
  so the actions that save those forms take it as an argument and this puts it in place. It merges
  into the `extra` the same changeset is writing, so a form that edits both keeps both. An action
  that is not handed the argument leaves `extra` as it is.

      update :update do
        argument :record, :string, allow_nil?: true
        change MishkaCmsCore.Runtime.Resources.Changes.SetRecordKind
      end
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_argument(changeset, :record) do
      {:ok, kind} -> Ash.Changeset.force_change_attribute(changeset, :extra, put(changeset, kind))
      :error -> changeset
    end
  end

  defp put(changeset, kind) do
    extra =
      case Ash.Changeset.get_attribute(changeset, :extra) do
        %{} = extra when not is_struct(extra) -> Map.drop(extra, [:record, "record"])
        _none -> %{}
      end

    case kind do
      kind when is_binary(kind) and kind != "" -> Map.put(extra, "record", kind)
      _none -> extra
    end
  end
end
