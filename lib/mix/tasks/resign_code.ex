defmodule Mix.Tasks.Mishka.ResignCode do
  @shortdoc "Re-signs every stored snippet with this deployment's code signing key"

  @moduledoc """
  Re-signs the Elixir stored in pages, layouts, components and error pages.

  ## When this is needed

  A database restored from another environment carries signatures made with that environment's key,
  so `MishkaCmsCore.Runtime.PageBuilder.CodeSignature` refuses them and every handler and helper in
  it compiles to a clause that does nothing. That is the feature working — but on a staging copy of
  production it is a chore rather than an attack, and this is the answer the log line names.

      CODE_SIGNING_KEY=… mix mishka.resign_code

  ## Read this before running it

  It signs WHATEVER IS THERE. That is the point on a restored dump, and it is exactly the wrong thing
  to do if the reason a signature does not match is that somebody changed the code in the database —
  running this would bless their edit. On a machine that is not yours to restore, read the
  `[CodeSignature]` warnings in the log first — each one names the snippet that did not verify —
  and satisfy yourself that a restore is what you are looking at.

  Refuses to run with no key configured, because signing with no key is a no-op that would report
  success and change nothing.
  """

  use Mix.Task

  alias MishkaCmsCore.Runtime.PageBuilder.CodeAudit
  alias MishkaCmsCore.Runtime.PageBuilder.CodeSignature

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case CodeSignature.enabled?() do
      false ->
        Mix.raise(
          "No :code_signing_key is configured — signing is off and there is nothing to do."
        )

      true ->
        CodeAudit.sources() |> Enum.map(&resign/1) |> Enum.sum() |> report()
    end
  end

  # STREAMED, NOT PAGED. This asked `:master_read` for `page: [limit: 1000]`, and that action caps
  # `max_page_size` at 100 — so a deployment with more than a hundred pages re-signed the first
  # hundred, reported success, and left every row after them inert. Silently, and exactly on the
  # deployments large enough for it to matter.
  #
  # `:read_any` bypasses multitenancy and paginates by keyset, which is what makes a stream of every
  # row across every site possible — the same read `MishkaCmsCore.Runtime.Handlers.BootHandler` uses
  # to walk the whole runtime.
  defp resign({resource, fields}) do
    resource
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.stream!(authorize?: false, batch_size: 100)
    |> Enum.map(&resign_row(&1, resource, fields))
    |> Enum.sum()
  end

  defp resign_row(row, resource, fields) do
    changes =
      for field <- fields,
          entries = Map.get(row, field),
          is_list(entries) and entries != [],
          into: %{},
          do: {field, Enum.map(entries, &CodeSignature.put/1)}

    case map_size(changes) do
      0 ->
        0

      _some ->
        # A RE-SIGN IS NOT A CODE CHANGE. `Validations.CodeChange` refuses `events`, `infos` and
        # `helpers` from a write with no actor, and this task has no actor at all — so every write
        # it made was refused and the task could not do its job on a single row carrying code,
        # which is every row it exists for. It announces what it is the same way the kit installer
        # and the seeds do; the bytes it writes are the bytes it read, with a signature attached.
        row
        |> Ash.Changeset.for_update(:master_update, changes,
          authorize?: false,
          context: %{page_code: :package}
        )
        |> Ash.update!()

        Mix.shell().info("  signed #{inspect(resource)} #{row.name}")
        1
    end
  end

  defp report(count) do
    Mix.shell().info(
      "Re-signed #{count} document(s). Recompile the runtime for it to take effect."
    )
  end
end
