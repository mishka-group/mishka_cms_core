defmodule MishkaCmsCore.Runtime.Resources.Validations.PageCodeCompiles do
  @moduledoc """
  Refuses a page whose code will not compile, at the action boundary, before it is stored.

  A page's `template`, `events`, `infos` and `helpers` are Elixir by the time
  `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler` is finished with them, and until this validation
  existed nothing read them first. What followed was quiet in a way that is worse than a crash: a
  page whose `precompile` is false — the default — is not compiled when it is saved, so the save
  succeeded, `MishkaCmsCore.Runtime.RuntimeStatus` reported `Ready`, and the first visitor got the
  500. A page whose module was already loaded kept serving the previous version, because the old code
  is only purged on the success branch, so the author's change simply never appeared.

  Running the check here rather than in a form means every writer gets it — the page form, the
  builder, the JSON:API and a seed script alike — which is the same reason `PathFormat` lives here.

  The error is attached to the attribute it came from, so a form puts it under the right box.
  `MishkaCmsCore.Runtime.PageBuilder.CodeCheck` explains what it can and cannot catch.
  """

  use Ash.Resource.Validation

  alias MishkaCmsCore.Runtime.PageBuilder.CodeCheck

  @fields [:template, :events, :infos, :state, :helpers]

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    case Enum.any?(@fields, &Ash.Changeset.changing_attribute?(changeset, &1)) do
      true -> check(changeset)
      false -> :ok
    end
  end

  defp check(changeset) do
    case CodeCheck.check(page(changeset)) do
      :ok ->
        :ok

      {:error, [fault | _rest]} ->
        {:error, field: field(fault.tab), message: CodeCheck.message(fault)}
    end
  end

  # THE WHOLE PAGE, not just what changed. A helper that a handler calls may be the thing that was
  # deleted, so checking the fragment in isolation would pass a page that no longer compiles.
  defp page(changeset) do
    Map.new(@fields, fn field -> {field, Ash.Changeset.get_attribute(changeset, field)} end)
  end

  # A fault in the assembled module belongs to no single box; the template is where an author looks
  # first and is by far the most likely source.
  defp field(:page), do: :template
  defp field(tab), do: tab

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def describe(_opts) do
    [message: "Validates that the page's template, handlers and helpers compile", vars: []]
  end
end
