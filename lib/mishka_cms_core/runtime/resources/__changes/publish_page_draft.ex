defmodule MishkaCmsCore.Runtime.Resources.Changes.PublishPageDraft do
  @moduledoc """
  After a `:publish` / `:master_publish` of a `MishkaCmsCore.Runtime.PageDraft`, writes the
  draft's fields to the live `MishkaCmsCore.Runtime.Page` — creating the page when the draft has
  no `source_page_id`, otherwise updating the existing page.

  The write is scoped to the draft's site (`tenant: draft.site_id`, `authorize?: false`), so it
  behaves identically for master and tenant publishes and triggers the normal Page compile
  pipeline (`Changes.SendToOban`). It runs in an `after_action`, so a Page write failure (e.g. a
  duplicate path for a brand-new draft) rolls the whole publish transaction back and surfaces the
  error.

  An existing page keeps its own code — `MishkaCmsCore.Runtime.PageBuilder.CodeAccess.fields/0`. The
  builder's code drawer writes it to the page directly, so a draft only holds the copy it forked.
  """
  use Ash.Resource.Change

  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.PageBuilder.CodeAccess

  # A PUBLISH COPIES WHAT THE DRAFT HOLDS, templates included, and checks no code: the check ran
  # when a person wrote the draft. See `MishkaCmsCore.Runtime.Resources.Validations.CodeChange`.
  @publish %{page_code: :publish}

  @page_fields [
    :name,
    :title,
    :path,
    :section,
    :template,
    :description,
    :format,
    :priority,
    :extra,
    :content,
    :seo_tags,
    :schema,
    :events,
    :infos,
    :resource_links,
    :helpers,
    :active,
    :precompile,
    :permissions,
    :layout_id,
    :language,
    :language_group_id
  ]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, draft ->
      case apply_to_live(draft) do
        {:ok, _page} -> {:ok, draft}
        {:error, error} -> {:error, error}
      end
    end)
  end

  defp apply_to_live(%{source_page_id: nil} = draft) do
    Page
    |> Ash.Changeset.for_create(:create, page_attrs(draft),
      tenant: draft.site_id,
      authorize?: false,
      context: @publish
    )
    |> Ash.create()
  end

  # THE PAGE'S CODE IS NOT THE DRAFT'S TO WRITE. The code drawer saves it to the live page, and a
  # draft holds only the copy it forked when it was taken — so writing that back would delete code
  # saved since. A new page has no code but the draft's, so the create above keeps it.
  defp apply_to_live(%{source_page_id: page_id} = draft) do
    case Ash.get(Page, page_id, tenant: draft.site_id, authorize?: false) do
      {:ok, page} ->
        page
        |> Ash.Changeset.for_update(:update, Map.drop(page_attrs(draft), CodeAccess.fields()),
          tenant: draft.site_id,
          authorize?: false,
          context: @publish
        )
        |> Ash.update()

      {:error, _} = error ->
        error
    end
  end

  # A DRAFT THAT NAMES NO LANGUAGE GROUP SAYS NOTHING ABOUT ONE. Handing the page `nil` would make a
  # translation the master of a group of its own — `SetLanguageGroupId` turns an emptied group into
  # the page's own id — so the key is left out, and a new page starts its group the way any create
  # does.
  defp page_attrs(draft) do
    draft
    |> Map.take(@page_fields)
    |> Map.reject(fn {key, value} -> key == :language_group_id and is_nil(value) end)
  end
end
