defmodule MishkaCmsCore.Runtime.Resources.Calculations.VersionPreview do
  @moduledoc """
  What a record said in one of its own versions, for a preview before a restore.

  The `:version_id` argument must name a version of THE RECORD being loaded; any other version — of
  another record, or of another site's — answers `nil`, the same as a version that does not exist.
  The record itself was read as the caller, so the version is read as the system once it is known to
  be the record's own.

  ## Options

    * `:version` — the resource's AshPaperTrail version resource. Required. It must have a
      `:get_any` read.

  ## Usage

      calculate :version_preview,
                :map,
                {MishkaCmsCore.Runtime.Resources.Calculations.VersionPreview,
                 version: MishkaCmsCore.Runtime.Layout.Version} do
        argument :version_id, :uuid, allow_nil?: false
      end
  """
  use Ash.Resource.Calculation

  alias MishkaCmsCore.Runtime.Resources.Changes.RestoreVersion

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :version) do
      {:ok, version} when is_atom(version) and not is_nil(version) -> {:ok, opts}
      _missing -> {:error, "VersionPreview needs the :version resource"}
    end
  end

  @impl true
  def calculate(records, opts, context) do
    version =
      case Ash.get(opts[:version], context.arguments[:version_id],
             action: :get_any,
             authorize?: false
           ) do
        {:ok, version} -> version
        _missing -> nil
      end

    Enum.map(records, &changes_for(&1, version))
  end

  defp changes_for(%{id: id}, %{version_source_id: id, changes: changes}),
    do: RestoreVersion.decode(changes)

  defp changes_for(_record, _not_its_version), do: nil
end
