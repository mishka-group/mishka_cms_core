# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Mixins.RedirectPaperTrailMixin do
  @moduledoc """
  Mixin for configuring PaperTrail version tracking on `MishkaCmsCore.Runtime.Redirect`.

  It defines the `cms_redirect_versions` table, whose rows are deleted with the rule they record,
  the bypass reads the activity log and the version history use, and the policies every runtime
  version resource shares (`MishkaCmsCore.Runtime.Resources.Mixins.VersionReach`): a rule's
  versions are read as the rule is, and a rule is always a site's own.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  @doc """
  Generates the PostgreSQL configuration for redirect version tracking.
  """
  def postgres do
    label = gettext_noop("Redirect")

    quote do
      postgres do
        table "cms_redirect_versions"
        repo Application.compile_env!(:mishka_cms_core, :repo)

        references do
          reference :version_source, on_delete: :delete
        end

        custom_indexes do
          index [:version_inserted_at]
          index [:version_inserted_at], all_tenants?: true
        end
      end

      multitenancy do
        strategy :attribute
        attribute :site_id
        global? true
      end

      actions do
        read :get_any do
          get? true
          multitenancy :bypass
        end

        read :read_any do
          multitenancy :bypass
        end

        read :sorted_versions do
          multitenancy :bypass
          pagination offset?: true, default_limit: 20, max_page_size: 100, required?: false

          prepare fn query, _context ->
            Ash.Query.sort(query, version_inserted_at: :desc)
          end
        end
      end

      unquote(
        MishkaCmsCore.Runtime.Resources.Mixins.VersionReach.policies(
          source: MishkaCmsCore.Runtime.Redirect,
          shared?: false
        )
      )

      calculations do
        calculate :severity,
                  :atom,
                  MishkaCmsCore.Activity.Calculations.Severity

        calculate :resource_label,
                  :string,
                  {MishkaCmsCore.Activity.Calculations.ResourceLabel, label: unquote(label)}
      end
    end
  end
end
