# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Mixins.HeadCodePaperTrailMixin do
  @moduledoc """
  Mixin for configuring PaperTrail version tracking on `MishkaCmsCore.Runtime.HeadCode`.

  It defines the `cms_head_code_versions` table, whose rows are deleted with the entry they record,
  the bypass reads the activity log and the version history use, and the policies every runtime
  version resource shares (`MishkaCmsCore.Runtime.Resources.Mixins.VersionReach`): an
  entry's versions are read as the entry is, and an entry is always a site's own.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  @doc """
  Generates the PostgreSQL configuration for head code version tracking.
  """
  def postgres do
    label = gettext_noop("Head code")

    quote do
      postgres do
        table "cms_head_code_versions"
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
          source: MishkaCmsCore.Runtime.HeadCode,
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
