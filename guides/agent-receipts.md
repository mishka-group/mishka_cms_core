# Agent receipts

An AI agent that publishes a post through the CMS gets back `{:ok, post}`. That says the action
returned success. It does not say the row holds `published`, that the sitemap will be rebuilt, or
that the admin who has the posts page open saw it change. A receipt says which of those were
checked, how, and what each check found.

Receipts live in `mishka_cms_core` under `MishkaCmsCore.Agent`. Extensions declare their own
operations; the core never names them.

## Turning it on

Receipts are off by default. A master turns them on under Settings, General, Agents ("Keep agent
receipts", the `agent.receipts` setting). Off, a tracked operation is the plain operation plus one
`:persistent_term` read: no table, no query, and the receipt is `nil`.

## Running an operation with a receipt

An Ash action:

```elixir
alias MishkaCmsCore.Agent.Receipts

{:ok, post, receipt} =
  post
  |> Ash.Changeset.for_update(:publish, %{}, actor: admin, tenant: site.id)
  |> Receipts.run("blog:blog_post:publish", source: :agent)
```

Anything else:

```elixir
{result, receipt} =
  Receipts.track("installer:extension:install", [site_id: site.id, actor: admin], fn _id ->
    MishkaCmsCore.Install.Extensions.install(site.id, "mishka_blog")
  end)
```

Neither changes what the operation returns or raises. The core's installer steps already have
wrappers: `MishkaCmsCore.Agent.Installer`.

## What a receipt holds

```elixir
%MishkaCmsCore.Agent.Receipt{
  id: "rcpt_...",                 # the correlation id, unguessable
  operation: "blog:blog_post:publish",
  resource: MishkaBlog.BlogPost, action: :master_publish,
  subject_id: "…", site_id: "…",  # ids, never content
  actor: %{id: "…", kind: :master},
  source: :agent,
  status: :verified,              # computed from the stages, never set by a caller
  required: [:action_committed, :db_read_back],
  stages: [%MishkaCmsCore.Agent.Receipt.Stage{...}, ...],
  started_at: ..., finished_at: ..., elapsed_us: 4120,
  error: nil, node: :"cms@host", meta: %{}
}
```

Each stage has a `kind`, a `layer` (`:app`, `:db` or `:ui`), a `status` (`:verified`, `:failed`,
`:skipped`, `:unverified`), a `reason` when it is not verified, and `expected` / `observed`
evidence.

### Status

- `:failed`: some stage failed.
- `:verified`: every stage the operation lists as `required` is verified, and none failed.
- `:partial`: something beyond the dispatch was verified, not every required stage.
- `:unverified`: nothing beyond the dispatch was verified.

A declared stage the operation never got to (the action was refused) is `:unverified,
:not_reached`, so the first unreached stage points at the layer that stopped. `:skipped` means the
stage does not apply (no sitemap job in a test run); it is never a pass.

## Stages and their limits

A stage is verified only by its own check, from evidence the check gathered itself. A caller hands
over evidence, never a verdict.

| Kind | Layer | Verified when | It does not prove |
|---|---|---|---|
| `:dispatched` | app | the operation is declared and the action is the declared one (or its master twin) | anything about the work |
| `:validated` | app | the changeset was valid when built | that the action will commit |
| `:action_committed` | app | the action returned success (`source: :notifier` when `ReceiptHook` heard its post-commit notification) | what the row holds; inside an outer transaction, a commit |
| `:db_read_back` | db | a separate query straight to the table found the row with every expected value | side effects, caches, other nodes, a read replica's lag |
| `:job_enqueued` | db | the `oban_jobs` row is there, read back (`correlated: :receipt` or `:coalesced`) | that the job will succeed |
| `:job_done` | app | Oban reported the job's success on this node (arrives later) | what the job did beyond succeeding; jobs run on another node |
| `:broadcast_published` | app | a listener of its own heard this operation's broadcast on the topic | that anyone else listens |
| `:ui_observed` | ui | a LiveView with `UiObserver` received this operation's broadcast (arrives later) | that the view updated, rendered or that anybody saw it |
| `:side_effect` | declared | the extension's own check of a named effect | anything beyond that check |

Each kind's moduledoc (`MishkaCmsCore.Agent.Stages.*`) has the full text. The UI layer stops at a
LiveView process receiving the message; the page itself is for a browser test to check.

## Declaring operations in an extension

An extension supervises one plugin on the `"agent:operations"` event:

```elixir
defmodule MyExtension.Agent.Operations do
  use MishkaCmsCore.Agent.Operation

  alias MishkaCmsCore.Agent.Operation
  alias MishkaCmsCore.Agent.Stages.{JobDone, JobEnqueued}

  @operations [
    Operation.new!(%{
      name: "my_extension:article:publish",
      resource: MyExtension.Article,
      action: :publish,
      master_action: :master_publish,
      visibility: ["admin:dashboard:my_extension:article", "admin:api:my_extension:article"],
      stages: [
        :dispatched,
        :validated,
        :action_committed,
        {:db_read_back, expect: [status: :published, published_at: :present]},
        :broadcast_published,
        JobEnqueued.sitemap(),
        JobDone.sitemap(),
        {:side_effect, :feed, check: &MyExtension.Agent.Checks.feed/1},
        :ui_observed
      ],
      required: [:action_committed, :db_read_back]
    })
  ]

  @impl MishkaCmsCore.Agent.Operation
  def operations, do: @operations
end
```

`required` is the operation's own definition of "it worked", and it cannot be empty. Stages left out
of it enrich the receipt and never decide it. A function in a stage's options is a remote capture or
`{module, fun, args}`, so the declaration is built at compile time and a malformed one fails the
build.

A check gets the context (`:id`, `:operation`, `:resource`, `:action`, `:changeset`, `:result`,
`:subject_id`, `:site_id`, `:actor`, `:params`, `:receipt`) and answers with evidence:
`{:ok, observed}`, `{:mismatch, expected, observed}`, `{:error, reason}`, `{:skip, reason}` or
`{:unverified, reason}`. A check that raises is a failed stage, and the operation's result is
untouched.

Two optional additions make the evidence stronger:

- `MishkaCmsCore.Agent.Notifiers.ReceiptHook` in the resource's notifiers: `:action_committed`
  then knows the post-commit notifications ran.
- `on_mount MishkaCmsCore.Agent.UiObserver` in the LiveView that shows the records: it reports the
  broadcasts it receives, for `:ui_observed`.

## The correlation id

While an operation runs, its id is `Receipts.current/0` and the Logger's `receipt_id` metadata
(add `:receipt_id` to the host's Logger metadata to see it in the log). It goes into the Ash
action's shared context, so every notifier and the broadcast payload carry it, and into an Oban
job's `meta` built with `Receipts.job_meta/1`. Work handed to another process carries it with
`Receipts.carry/1`.

## Reading receipts (and the MCP seam)

```elixir
Receipts.get(id, viewer)                  # {:ok, receipt} | {:error, :not_found}
Receipts.get(id, viewer, surface: :api)
Receipts.recent(viewer, operation: "blog:blog_post:publish", status: :failed, limit: 20)
MishkaCmsCore.Agent.Receipt.to_public(receipt)   # a JSON-safe map
Receipts.stats()                          # count, dropped, bounds; no receipt data
```

A viewer reads a receipt when it holds `admin:<surface>:agent:receipts` (a full admin of the
surface holds it), the receipt's site is in its reach (a master reads every site, a site user its
own), and it holds one of the operation's `visibility` names or is a full admin of the surface. A
receipt the viewer may not read answers `:not_found`, exactly like one that does not exist. Filters
narrow and never widen.

These are the functions a future MCP tool calls with its session's user and returns
`to_public/1` of. No MCP code ships in the core.

## Saving and showing receipts elsewhere

Receipts live in memory for an hour. An extension that keeps them longer, shows them on a page of
its own or alerts when one fails listens on the `agent:receipt:finished` event
(`Receipts.finished_event/0`), and the core does not need to know it:

```elixir
defmodule MyExtension.Agent.ReceiptLog do
  use MishkaInstaller.Event.Hook, event: "agent:receipt:finished"

  @impl true
  def call(%{receipt: receipt, site_id: site_id, operation: operation} = payload) do
    MyExtension.ReceiptLog.save(site_id, operation, receipt)
    if receipt["status"] == "failed", do: MyExtension.Alerts.notify(site_id, receipt)
    {:reply, payload}
  end
end
```

- `receipt` is `Receipt.to_public/1`: redacted and JSON-safe, the same map an API returns. Never the
  record, the params or the changeset.
- `trigger` is `:finished` when the receipt is stored with its status, and `:late` each time late
  evidence (`:job_done`, `:ui_observed`) is kept for it, with the receipt read again. Save by
  `receipt["id"]` and keep the last: the same receipt may come more than once. `node` is the node
  that announced it, the one that ran the operation and heard the late evidence.
- The map holds what a saved receipt needs later without the operation's declaration:
  `"required"` (the stage names that decide it), `"visibility"` (the permission names whose holders
  may read it, to check a reader against as `Receipts.get/3` does), and per stage its `"at"` (when it
  was recorded) and `"key"` (what late evidence is matched by, such as a job's worker).
- A consumer that merges late stages into a saved receipt never decides the status itself:
  `Receipt.public_status(receipt["stages"], receipt["required"])` answers the core's verdict
  (`"verified"`, `"failed"`, `"partial"` or `"unverified"`) for the public maps.
- The plugin runs in a task under `MishkaCmsCore.Runtime.TaskSupervisor`, after the operation has
  returned. It never slows the operation or changes its result; a plugin that raises is logged and
  nothing else.
- With receipts off, or no plugin on the event, nothing is started: one `:persistent_term` read.
  Announcing makes no query.

The event carries what any viewer of the receipt could read. Who may see what the plugin saves is the
plugin's own question: a receipt's `"site_id"` and `"operation"` are there to scope it.

### Telemetry

For tracing tools (OpenTelemetry and the like), without a plugin:

| Event | Measurements | Metadata |
|---|---|---|
| `[:mishka_cms, :agent, :receipt, :stop]` | `elapsed_us`, `stage_count` | `id`, `operation`, `status`, `site_id` |
| `[:mishka_cms, :agent, :receipt, :stage]` (once per stage) | `elapsed_us` | `id`, `operation`, `site_id`, `kind`, `name`, `layer`, `status`, `reason` |
| `[:mishka_cms, :agent, :receipt, :late]` | `system_time` | `id`, `kind`, `name`, `layer`, `status`, `reason` |

They carry ids, names and statuses only, in the process that ran the operation or heard the late
evidence, as `:telemetry` handlers always run. None is sent with receipts off.

## What is never stored

Content, params, assigns, sockets, changesets, emails, names, tokens, job args and exception
messages. Evidence keeps atom keys and scalar values only (statuses, booleans, numbers, times,
UUIDs, short identifiers), and anything else is dropped rather than shortened. An error keeps its
kind, its exception module, the top stack frame and, for an Ash error, the error classes and the
field names. A record's text is compared, never stored: `:claimed` stores `:matches` or `:differs`.
See `MishkaCmsCore.Agent.Redactor`.

## Storage, bounds and cost

Receipts are ETS tables owned by `MishkaCmsCore.Agent.ReceiptStore`, written by the process that
ran the operation and read by whoever asks: no process call on either path. Bounds, under
`config :mishka_cms_core, MishkaCmsCore.Agent.Receipts`: `max_receipts` (1000), `per_site_max`
(200, so one site cannot push out another's evidence) and `max_age_seconds` (3600). Dropped
receipts are counted.

They are evidence, not records: they live in memory on the node that ran the operation and go when
it restarts. The Activity log and the version trail remain the record of who changed what.

With receipts on, an operation costs what its stages read: one primary-key query for a
`:db_read_back`, one indexed query for a `:job_enqueued`, a subscription for a
`:broadcast_published`. Reading receipts never touches the database.

## Several nodes

A receipt is kept on the node that ran the operation; `get/3` on another node is `:not_found`. A
job run on another node, or a LiveView on another node, reports there, so those late stages stay
unverified. Reading across nodes is left for later.
