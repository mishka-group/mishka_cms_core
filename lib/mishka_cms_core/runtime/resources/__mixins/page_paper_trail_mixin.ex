# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Mixins.PagePaperTrailMixin do
  @moduledoc """
  Mixin for configuring PaperTrail version tracking on Page resources.

  This mixin provides the database and action configuration needed for the
  PaperTrail extension to track page versions. It defines the version table
  structure, database relationships, and actions required for version management,
  ensuring consistent configuration across the page versioning system.

  The mixin sets up the 'page_versions' table with proper foreign key references
  that cascade delete when the source page is removed. It also defines a bypass
  action for retrieving versions without tenant restrictions, enabling cross-site
  version access for administrative purposes.

  By using a mixin approach, the versioning configuration is kept separate from
  the main Page resource definition, improving maintainability and allowing the
  versioning setup to be reused or modified independently. The configuration ensures
  that page history is properly tracked while maintaining referential integrity.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  @doc """
  Generates the PostgreSQL configuration for page version tracking.

  Returns quoted code that defines the version table, repository, and
  foreign key relationships with cascade delete behavior.
  """
  def postgres do
    label = gettext_noop("Page")

    quote do
      multitenancy do
        global? true
      end

      postgres do
        table "page_versions"
        repo Application.compile_env!(:mishka_cms_core, :repo)

        references do
          reference :version_source, on_delete: :delete
        end

        custom_indexes do
          index [:version_inserted_at]
          index [:version_inserted_at], all_tenants?: true
        end
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

      changes do
        change MishkaCmsCore.Runtime.Resources.Changes.SetVersionSiteId, on: [:create]
      end

      unquote(
        MishkaCmsCore.Runtime.Resources.Mixins.VersionReach.policies(
          source: MishkaCmsCore.Runtime.Page,
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
