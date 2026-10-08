defmodule MishkaCmsCore.Runtime.Resources.Validations.FolderIsEmpty do
  @moduledoc """
  Refuses to archive or delete a media folder that still holds a file or another folder.

  Archived ones count. An archived file still names its folder, and restoring it after the folder
  went would leave it in none; an archived folder still names its parent the same way. So a folder
  goes only once nothing at all is left in it — each file and folder moved out, or deleted for good.
  That also keeps a delete for good clear of the references the database holds it to.

  The rows are counted in their tables, archived ones included, whoever writes: the rule is about
  the folder, not the actor. Each refusal is on `:id`, in the `errors` domain.
  """
  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ecto.Query

  alias MishkaCmsCore.Runtime.{Media, MediaCategory}

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(%{data: %{id: id}}, _opts, _context) do
    cond do
      holds?(MediaCategory, :parent_id, id) ->
        refuse(
          dgettext_noop(
            "errors",
            "This folder still holds other folders, archived ones included. Move them out or delete them for good first."
          )
        )

      holds?(Media, :media_category_id, id) ->
        refuse(
          dgettext_noop(
            "errors",
            "This folder still holds files, archived ones included. Move them out or delete them for good first."
          )
        )

      true ->
        :ok
    end
  end

  # The reads leave archived rows out, so the rows are looked up in their table.
  defp holds?(resource, attribute, id) do
    column = Ash.Resource.Info.attribute(resource, attribute).source
    key = Ecto.UUID.dump!(id)

    Ecto.Query.from(row in AshPostgres.DataLayer.Info.table(resource))
    |> Ecto.Query.where([row], field(row, ^column) == ^key)
    |> AshPostgres.DataLayer.Info.repo(resource, :read).exists?()
  end

  defp refuse(message), do: {:error, field: :id, message: message}

  @impl true
  def has_validate?, do: true

  @impl true
  def supports(_opts), do: [Ash.Changeset]
end
