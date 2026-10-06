defmodule MishkaCmsCore.Runtime.Resources.Mixins.StylesheetPaperTrailMixin do
  @moduledoc """
  PaperTrail version-tracking config for the Stylesheet resource.

  Mirrors `JsHookPaperTrailMixin` — the same `get_any` / `read_any` /
  `sorted_versions` action set, only the table name and on-delete cascade
  reference change. Versions live in the `stylesheet_versions` table and
  cascade-delete with their parent row.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  @doc """
  Generates the PostgreSQL configuration for stylesheet version tracking.
  """
  def postgres do
    label = gettext_noop("Stylesheet")

    quote do
      postgres do
        table "stylesheet_versions"
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

      unquote(
        MishkaCmsCore.Runtime.Resources.Mixins.VersionReach.policies(
          source: MishkaCmsCore.Runtime.Stylesheet,
          shared?: true
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
