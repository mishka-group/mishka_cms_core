# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.Behaviours.UnionSource do
  @moduledoc """
  A table of an extension's own merged into the activity log, as one more branch of the `UNION ALL`
  `MishkaCmsCore.Activity.Query` runs.

  The core's branches read what every installation has: AshPaperTrail versions, AshEvents logs, the
  runtime drafts and Oban jobs. A record that is none of those — the visual editor's history is the
  first — would never reach the log, so its owner contributes the branch. It registers on
  `activity:sources`, a collect event, through `MishkaCmsCore.ProviderRegistry`:

      use MishkaCmsCore.ProviderRegistry, event: "activity:sources", priority: 50
      @behaviour MishkaCmsCore.Activity.Behaviours.UnionSource

  With no source registered the log is the core's branches alone.

  ## The branch

  `union_branch/1` answers `{sql, params}` for one read, or `nil` when the read cannot reach any of
  its rows (a `warn` read of a table that only ever holds information, say), so its table is not
  scanned to return nothing. `sql` is one parenthesised `(SELECT … LIMIT $1)` selecting, in this
  order and with these types, the columns every branch selects:

      source text      -- the source's id/0, which is how its rows find entry_from_row/1 again
      resource text    -- the module name an entry is filed under ("Elixir.MishkaCmsCore.Runtime.Page")
      action text, source_id text, event_id text, site_id text, user_id text,
      inserted_at timestamp, payload jsonb

  It filters and orders itself, newest first, and caps itself at `$1`, so the merged top of the log
  is the top of each branch. The read's filters arrive as the shared positional parameters, which
  `MishkaCmsCore.Activity.Query`'s public clause builders write: `$1` the cap, `$4` the resource
  (`resource_clause/1`), `$5` the search (`search_clause/1`) and `$6` the tenant's site
  (`version_site_clause/2`, only when `site_id` is set); `shown_clause/2` and
  `content_severity_clause/2` narrow it by the viewer's resources and the read's severity.

  A value of the source's own is a parameter too, never text written into the SQL: `params` lists
  them, and the first is `$` followed by `first_param`, the next `first_param + 1`, and so on. Each
  is cast where it is used (`$7::text`), because Postgres must infer every parameter's type.

  ## Its resources in the Resource filter

  The log's Resource filter lists the resources the core's branches discover. A source whose rows
  are filed under resources of its own names them in `resources/0`, as `{label, module_string}`,
  and they join the filter under their extension's group (`MishkaCmsCore.Activity.Query.resource_options/0`):

      def resources, do: [{"Order", "Elixir.MyShop.Order"}]

  Filing a row under a real resource module also decides who sees it: an admin who is not a full
  dashboard admin sees the rows of the resources whose areas their own policies ask for
  (`MishkaCmsCore.Activity.Helpers.resources_for/1`, the `shown` of the read).

  ## A link to the record

  An entry may carry `link`, a path of the same site (`"/admin/dashboard/shop/orders/1"`): the log
  draws its message as a link to it. Anything that is not a local path is dropped
  (`MishkaCmsCore.Activity.Helpers.local_path/1`), so a row can never send an admin to another host.

  ONE BROKEN BRANCH EMPTIES THE WHOLE LOG. The read is one query, so SQL that Postgres refuses fails
  every source with it, and the log answers "no matching events" (the failure is logged). A branch
  that raises or answers anything but `{sql, params}` is left out of the read on its own.
  """

  alias MishkaCmsCore.Activity.Behaviours.Source
  alias MishkaCmsCore.ProviderRegistry

  @event "activity:sources"

  @typedoc """
  The read a branch is asked for. `site_id` is the one site read, `nil` for every site (a master);
  `severity` is `"info"`, `"warn"`, `"error"` or `nil`; `shown` is `:all` or the module strings
  the viewer may see; `first_param` is the position of the source's first own parameter.
  """
  @type read :: %{
          site_id: String.t() | nil,
          severity: String.t() | nil,
          shown: :all | [String.t()],
          first_param: pos_integer()
        }

  @doc "The value the branch writes in the `source` column: unique, and none of the core's own."
  @callback id() :: String.t()

  @doc "The branch for one read and its own parameters, or `nil` when the read reaches none of it."
  @callback union_branch(read()) :: {String.t(), [term()]} | nil

  @doc "One row the branch produced, as an entry of the log."
  @callback entry_from_row(map()) :: Source.entry()

  @doc "The resources its rows are filed under, as `{label, module_string}`, for the Resource filter."
  @callback resources() :: [{String.t(), String.t()}]

  @optional_callbacks resources: 0

  @doc "The event a union source registers on."
  @spec event() :: String.t()
  def event, do: @event

  @doc "Every union source installed, the first of each id."
  @spec all() :: [module()]
  def all, do: ProviderRegistry.all(@event, __MODULE__)

  @doc """
  The resources every installed source files its rows under (`resources/0`), as
  `{label, module_string}`; a source that names none, or answers anything else, adds nothing.
  """
  @spec resources([module()]) :: [{String.t(), String.t()}]
  def resources(sources \\ all()) do
    for source <- sources,
        function_exported?(source, :resources, 0),
        {label, module} <- List.wrap(source.resources()),
        is_binary(label) and is_binary(module),
        do: {label, module}
  end
end
