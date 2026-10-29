# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Changes.PublishErrorPageDraft do
  @moduledoc """
  After a `:publish` / `:master_publish` of a `MishkaCmsCore.Runtime.ErrorPageDraft`, writes the
  draft's fields (including the whole `error_pages` collection) to the live
  `MishkaCmsCore.Runtime.ErrorPage` — creating it when the draft has no `source_error_page_id`,
  otherwise updating it.

  Scoped to the draft's site (`tenant: draft.site_id`, `authorize?: false`), in an `after_action`, so
  a write failure rolls the whole publish transaction back. The ErrorPage analogue of
  `MishkaCmsCore.Runtime.Resources.Changes.PublishPageDraft`.
  """
  use Ash.Resource.Change

  alias MishkaCmsCore.Runtime.ErrorPage
  alias MishkaCmsCore.Runtime.Authoring.CodeAccess

  # A PUBLISH COPIES WHAT THE DRAFT HOLDS, templates included, and checks no code: the check ran
  # when a person wrote the draft. See `MishkaCmsCore.Runtime.Resources.Validations.CodeChange`.
  @publish %{page_code: :publish}

  @error_page_fields [
    :name,
    :path,
    :root_layout_template,
    :format,
    :priority,
    :error_pages,
    :helpers,
    :active,
    :precompile,
    :extra
  ]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, draft ->
      case apply_to_live(draft) do
        {:ok, _error_page} -> {:ok, draft}
        {:error, error} -> {:error, error}
      end
    end)
  end

  defp apply_to_live(%{source_error_page_id: nil} = draft) do
    ErrorPage
    |> Ash.Changeset.for_create(:create, error_page_attrs(draft),
      tenant: draft.site_id,
      authorize?: false,
      context: @publish
    )
    |> Ash.create()
  end

  # THE ERROR PAGE'S `helpers` ARE NOT THE DRAFT'S TO WRITE — the code drawer saves them to the live
  # error page and the draft holds only the copy it forked. See `Changes.PublishPageDraft`.
  defp apply_to_live(%{source_error_page_id: error_page_id} = draft) do
    case Ash.get(ErrorPage, error_page_id, tenant: draft.site_id, authorize?: false) do
      {:ok, error_page} ->
        error_page
        |> Ash.Changeset.for_update(
          :update,
          Map.drop(error_page_attrs(draft), CodeAccess.fields()),
          tenant: draft.site_id,
          authorize?: false,
          context: @publish
        )
        |> Ash.update()

      {:error, _} = error ->
        error
    end
  end

  defp error_page_attrs(draft), do: Map.take(draft, @error_page_fields)
end
