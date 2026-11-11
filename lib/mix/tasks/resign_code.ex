# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Mishka.ResignCode do
  @shortdoc "Re-signs every stored snippet with this deployment's code signing key"

  @moduledoc """
  Re-signs the Elixir stored in pages, layouts, components and error pages.

  ## When this is needed

  A database restored from another environment carries signatures made with that environment's key,
  so `MishkaCmsCore.Runtime.Authoring.CodeSignature` refuses them and every handler and helper in
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

  The work is `MishkaCmsCore.Runtime.Authoring.CodeAudit.resign/0`, which a release (no Mix) calls
  through `bin/<app> rpc`; see its docs.
  """

  use Mix.Task

  alias MishkaCmsCore.Runtime.Authoring.CodeAudit

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case CodeAudit.resign() do
      {:error, :signing_off} ->
        Mix.raise(
          "No :code_signing_key is configured — signing is off and there is nothing to do."
        )

      {:ok, count} ->
        Mix.shell().info(
          "Re-signed #{count} document(s). Recompile the runtime for it to take effect."
        )
    end
  end
end
