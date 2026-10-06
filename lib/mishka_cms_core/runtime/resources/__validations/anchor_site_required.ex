defmodule MishkaCmsCore.Runtime.Resources.Validations.AnchorSiteRequired do
  @moduledoc """
  A page and an error page are never global; a layout and a component can be.

  `MishkaCmsCore.Runtime.PageBuilderEvent` anchors to all four through one polymorphic
  `source_type`, so it is `global? true` — a component's history has to be writable with a `nil`
  `site_id`. That makes the resource unable to say, by its multitenancy alone, the thing that is
  nonetheless true of half its rows:

      source_type in [:page, :error_page]  ⟹  site_id is present

  Verified against the resources themselves rather than assumed: `Page` and `ErrorPage` declare
  `global? false`, `Layout` and `Component` declare `global? true`.

  Paired with a check constraint of the same name on the table. This catches the bug with a message;
  the constraint catches the code path that skipped the validation — worth having both, because these
  rows are written from the editor's hot path by batched, retried upserts, which is exactly the sort
  of path that grows a shortcut.
  """
  use Gettext, backend: MishkaCmsCore.Gettext
  use Ash.Resource.Validation

  @anchored_to_a_site [:page, :error_page]

  @impl true
  def validate(changeset, _opts, _context) do
    source_type = Ash.Changeset.get_attribute(changeset, :source_type)
    site_id = Ash.Changeset.get_attribute(changeset, :site_id)

    check(source_type, site_id)
  end

  defp check(source_type, nil) when source_type in @anchored_to_a_site do
    {:error,
     field: :site_id,
     message:
       dgettext_noop(
         "errors",
         "a %{source_type} always belongs to a site, so its history cannot be global"
       ),
     vars: [source_type: source_type]}
  end

  defp check(_source_type, _site_id), do: :ok
end
