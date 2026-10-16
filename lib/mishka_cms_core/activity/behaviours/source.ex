# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.Behaviours.Source do
  @moduledoc """
  Behaviour for activity-feed data sources. Each adapter answers four
  questions:

    * `topics/1`         — which PubSub topics the parent LiveView must
      subscribe to so the feed receives live updates.
    * `handles?/1`       — whether a given broadcast belongs to this source.
    * `to_entry/1`       — turn a live broadcast into a feed entry.
    * `initial_fetch/2`  — fetch the most recent entries for first render.
    * `in_scope?/2`      — (optional) whether a live broadcast belongs in a
      resource-scoped feed; only needed by sources on a global topic.

  Adapters live under `MishkaCmsCore.Activity.Sources.*` (e.g.
  `PaperTrail`, `Oban`). The `ActivityFeed` LiveComponent composes any
  list of sources without knowing what each one does.
  """

  @type scope :: %{
          optional(:current_user) => map() | nil,
          optional(:resources) => [module()] | nil
        }

  @typedoc """
  One activity entry. Every key here is one a renderer reads, so a source that omits one hands a
  template a map `entry.that_key` raises on — `MishkaCmsCore.Activity.Helpers.complete_entry/1` fills
  the gap at both seams, and `entry_contract_test.exs` fails the source that left it. The optional
  tail is the pipeline's own: `:actor_label` and `:site_label` are resolved downstream by
  `MishkaCmsCore.Activity.ActivityEntry`, `:host` by the dashboard's Recent activity widget.
  """
  @type entry :: %{
          required(:id) => String.t(),
          required(:resource_label) => String.t(),
          required(:action) => atom(),
          required(:severity) => :info | :warn | :error,
          required(:tone) => :created | :updated | :destroyed | nil,
          required(:badge_label) => String.t() | nil,
          required(:badge_tone) => atom() | nil,
          required(:inserted_at) => DateTime.t(),
          required(:source_id) => String.t() | nil,
          required(:site_id) => String.t() | nil,
          required(:user_id) => String.t() | nil,
          required(:message) => String.t(),
          optional(atom()) => any()
        }

  @callback topics(scope) :: [String.t()]
  @callback handles?(Phoenix.Socket.Broadcast.t()) :: boolean()
  @callback to_entry(Phoenix.Socket.Broadcast.t()) :: entry() | nil
  @callback initial_fetch(scope, limit :: pos_integer()) :: [entry()]

  @doc """
  Whether a live broadcast belongs in a feed of the given `scope`. Sources whose
  `topics/1` already encode the scope (per-resource topics, e.g. `PaperTrail` /
  `Oban`) can omit it — the subscription alone filters them. A source on a GLOBAL
  topic (e.g. `EventLog`'s `"event_log:created"`) implements it so a
  resource-scoped feed drops out-of-scope broadcasts. A missing callback is
  treated as always in scope.
  """
  @callback in_scope?(Phoenix.Socket.Broadcast.t(), scope) :: boolean()

  @optional_callbacks in_scope?: 2
end
