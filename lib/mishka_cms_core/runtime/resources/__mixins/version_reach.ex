# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Mixins.VersionReach do
  @moduledoc """
  Who reads a runtime resource's versions — the policies of the version resources AshPaperTrail
  generates.

  A version is a copy of its record, so it is read as the record is: by anyone under the request's
  surface, and by a master (`site_id` nil) on any site, by a site user on its own site — and, with
  `shared?: true`, on the shared records too — through whichever read it asks, `:read_any`
  included. Anybody else, a missing actor included, reads none. System reads pass
  `authorize?: false`; AshPaperTrail writes versions without authorization.

  Versions loaded through their record — its `:sorted_versions` or AshPaperTrail's
  `:paper_trail_versions` — are the record's own, so the read that reached the record decides: a
  record's reads build the versions query ahead of the load, and Ash runs such a query with no
  actor.

  The version resource takes the authorizer through the source resource's `version_extensions`,
  and its mixin quotes these policies into its body:

      paper_trail do
        version_extensions authorizers: [Ash.Policy.Authorizer]
        mixin {MishkaCmsCore.Runtime.Resources.Mixins.LayoutPaperTrailMixin, :postgres, []}
      end

      # in the mixin's quoted body
      unquote(
        MishkaCmsCore.Runtime.Resources.Mixins.VersionReach.policies(
          source: MishkaCmsCore.Runtime.Layout,
          shared?: true
        )
      )

  ## Options

    * `:source` — the versioned resource. Required.
    * `:shared?` — whether the resource has shared (`site_id` nil) records a site user reads.
      Defaults to `false`.
  """

  @doc "The quoted `policies` block for a version resource."
  @spec policies(keyword()) :: Macro.t()
  def policies(opts) do
    source = Keyword.fetch!(opts, :source)

    # The column as the version resource's own source would name it: a variable quoted here carries
    # this module's context, which `expr/1` reads as a variable rather than as the column.
    site_id = Macro.var(:site_id, nil)

    rows =
      case Keyword.get(opts, :shared?, false) do
        true -> quote(do: expr(is_nil(unquote(site_id)) or unquote(site_id) == ^actor(:site_id)))
        false -> quote(do: expr(unquote(site_id) == ^actor(:site_id)))
      end

    quote do
      policies do
        policy action_type(:read) do
          access_type :strict

          authorize_if accessing_from(unquote(source), :sorted_versions)
          authorize_if accessing_from(unquote(source), :paper_trail_versions)

          authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions, under: :surface}
        end

        policy action_type(:read) do
          authorize_if accessing_from(unquote(source), :sorted_versions)
          authorize_if accessing_from(unquote(source), :paper_trail_versions)
          authorize_if actor_attribute_equals(:site_id, nil)
          authorize_if unquote(rows)
        end
      end
    end
  end
end
