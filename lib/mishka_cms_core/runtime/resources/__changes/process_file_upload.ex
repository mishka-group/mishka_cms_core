# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Changes.ProcessFileUpload do
  @moduledoc """
  Processes uploaded file from consumed uploads and sets derived media attributes.

  Supports both create and update actions:
  - **Create**: requires at least one file, generates new UUID path via `save_file_to_storage`.
    Sets all file attributes: `name`, `type`, `size`, `format`, `relative_path`.
  - **Update**: skips when no new file uploaded. When a new file is provided,
    replaces at the same path using backup/restore. Only updates `size`, `format`,
    and `relative_path` (path changes only when the file extension changes, or when the old path
    was not a file of the row's own site folder, which is never replaced).
    `name` and `type` are left to the user's form input.

  Either way the entry's `path` must be a file a form's upload was staged as — see
  `MishkaCmsCore.Runtime.Media.staged_upload/2` — or nothing is copied, replaced or deleted and the
  action is refused: `media_files` reaches the action from the request as well, and the file it
  names is removed once stored.
  """

  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      media_files = Ash.Changeset.get_argument(changeset, :media_files) || []

      case {changeset.action.type, media_files} do
        {:create, []} ->
          refuse(changeset, dgettext_noop("errors", "Please select a file to upload"))

        {_action_type, []} ->
          changeset

        {:create, [file | _]} ->
          process_create(changeset, file)

        {:update, [file | _]} ->
          process_update(changeset, file)
      end
    end)
  end

  defp process_create(changeset, file) do
    with {:ok, path, client_name} <- extract_file_info(file, changeset),
         {:ok, file_info} <- validate_file(path, client_name),
         {:ok, saved_path} <- save_new_file(changeset, file_info) do
      apply_create_attributes(changeset, file_info, saved_path)
    else
      {:error, error} -> add_file_error(changeset, error)
    end
  end

  defp process_update(changeset, file) do
    existing_path = Map.get(changeset.data, :relative_path)

    with {:ok, path, client_name} <- extract_file_info(file, changeset),
         {:ok, file_info} <- validate_file(path, client_name) do
      if existing_path do
        replace_file(changeset, file_info, existing_path)
      else
        case save_new_file(changeset, file_info) do
          {:ok, saved_path} -> apply_create_attributes(changeset, file_info, saved_path)
          {:error, error} -> add_file_error(changeset, error)
        end
      end
    else
      {:error, error} -> add_file_error(changeset, error)
    end
  end

  # ONLY A FILE OF THE ROW'S OWN FOLDER IS REPLACED. A path naming anything else — set while
  # `relative_path` could still be edited — is left where it is, and the upload is stored as a new
  # file of the row's own site.
  defp replace_file(changeset, file_info, existing_path) do
    stored =
      case MishkaCmsCore.Runtime.Media.replace_file_in_storage(
             file_info,
             existing_path,
             changeset.data.site_id
           ) do
        {:error, :not_own_file} -> save_new_file(changeset, file_info)
        replaced -> replaced
      end

    case stored do
      {:ok, result_path} -> apply_update_attributes(changeset, file_info, result_path)
      {:error, error} -> add_file_error(changeset, error)
    end
  end

  defp extract_file_info(file, changeset) do
    path = map_get(file, :path)
    client_name = map_get(file, :client_name)

    with false <- is_nil(path) or is_nil(client_name),
         {:ok, staged} <- MishkaCmsCore.Runtime.Media.staged_upload(path, site_id(changeset)) do
      {:ok, staged, client_name}
    else
      _invalid -> {:error, dgettext_noop("errors", "Invalid upload entry")}
    end
  end

  defp validate_file(path, client_name) do
    MishkaCmsCore.Runtime.Media.validate_and_process_file(%{
      file: Ash.Type.File.from_path(path),
      original_filename: client_name
    })
  end

  defp save_new_file(changeset, file_info) do
    category_id = Ash.Changeset.get_attribute(changeset, :media_category_id)

    MishkaCmsCore.Runtime.Media.save_file_to_storage(
      file_info,
      site_id(changeset),
      category_id
    )
  end

  defp site_id(changeset),
    do: Ash.Changeset.get_attribute(changeset, :site_id) || changeset.tenant

  defp apply_create_attributes(changeset, file_info, path) do
    changeset
    |> Ash.Changeset.force_change_attribute(:name, file_info.name)
    |> Ash.Changeset.force_change_attribute(:type, file_info.type)
    |> Ash.Changeset.force_change_attribute(:size, file_info.size)
    |> Ash.Changeset.force_change_attribute(:format, file_info.format)
    |> Ash.Changeset.force_change_attribute(:relative_path, path)
  end

  defp apply_update_attributes(changeset, file_info, path) do
    changeset
    |> Ash.Changeset.force_change_attribute(:size, file_info.size)
    |> Ash.Changeset.force_change_attribute(:format, file_info.format)
    |> Ash.Changeset.force_change_attribute(:relative_path, path)
  end

  defp add_file_error(changeset, %Ash.Error.Invalid{} = error) do
    Enum.reduce(error.errors, changeset, &Ash.Changeset.add_error(&2, &1))
  end

  defp add_file_error(changeset, message) when is_binary(message) do
    refuse(changeset, message)
  end

  defp add_file_error(changeset, error) do
    refuse(changeset, inspect(error))
  end

  # NO VALUE LINE AT ALL, which is what the struct form gives and the keyword form cannot:
  # `Ash.Changeset.add_error/2` always hands `:value` on, so a keyword without one renders
  # "Value: nil" under a message about an upload that is not nil. There is nothing to name here —
  # the value is the upload entry itself, a struct carrying a temporary path that says nothing to
  # whoever is reading the refusal — and the message already carries what went wrong.
  defp refuse(changeset, message) do
    Ash.Changeset.add_error(
      changeset,
      Ash.Error.Changes.InvalidAttribute.exception(field: :media_files, message: message)
    )
  end

  defp map_get(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end
end
