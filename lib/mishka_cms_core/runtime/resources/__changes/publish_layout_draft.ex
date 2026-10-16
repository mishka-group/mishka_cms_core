# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Changes.PublishLayoutDraft do
  @moduledoc """
  After a `:publish` / `:master_publish` of a `MishkaCmsCore.Runtime.LayoutDraft`, writes the draft's
  fields to the live `MishkaCmsCore.Runtime.Layout` — creating the layout when the draft has no
  `source_layout_id`, otherwise updating the existing layout.

  The write is scoped to the draft's site (`tenant: draft.site_id`, `authorize?: false`) — which is
  `nil` for a global layout draft (master-managed) — so it behaves identically for master and tenant
  publishes and triggers the normal Layout compile pipeline. It runs in an `after_action`, so a
  Layout write failure rolls the whole publish transaction back and surfaces the error.

  The Layout analogue of `MishkaCmsCore.Runtime.Resources.Changes.PublishPageDraft`.
  """
  use Ash.Resource.Change

  alias MishkaCmsCore.Runtime.Layout
  alias MishkaCmsCore.Runtime.PageBuilder.CodeAccess

  # A PUBLISH COPIES WHAT THE DRAFT HOLDS, templates included, and checks no code: the check ran
  # when a person wrote the draft. See `MishkaCmsCore.Runtime.Resources.Validations.CodeChange`.
  @publish %{page_code: :publish}

  @layout_fields [
    :name,
    :path,
    :description,
    :template,
    :format,
    :priority,
    :extra,
    :content,
    :resource_links,
    :seo_tags,
    :helpers,
    :active,
    :precompile,
    :permissions,
    :example
  ]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, draft ->
      case apply_to_live(draft) do
        {:ok, _layout} -> {:ok, draft}
        {:error, error} -> {:error, error}
      end
    end)
  end

  defp apply_to_live(%{source_layout_id: nil} = draft) do
    Layout
    |> Ash.Changeset.for_create(:create, layout_attrs(draft),
      tenant: draft.site_id,
      authorize?: false,
      context: @publish
    )
    |> Ash.create()
  end

  # THE LAYOUT'S `helpers` ARE NOT THE DRAFT'S TO WRITE — the code drawer saves them to the live
  # layout and the draft holds only the copy it forked. See `Changes.PublishPageDraft`.
  defp apply_to_live(%{source_layout_id: layout_id} = draft) do
    case Ash.get(Layout, layout_id, tenant: draft.site_id, authorize?: false) do
      {:ok, layout} ->
        layout
        |> Ash.Changeset.for_update(:update, Map.drop(layout_attrs(draft), CodeAccess.fields()),
          tenant: draft.site_id,
          authorize?: false,
          context: @publish
        )
        |> Ash.update()

      {:error, _} = error ->
        error
    end
  end

  defp layout_attrs(draft), do: Map.take(draft, @layout_fields)
end
