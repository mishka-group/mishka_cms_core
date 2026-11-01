# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.PagePathUnique do
  @moduledoc """
  Refuses a page draft whose path another page of its site already has, with the sentence `Page`'s
  `unique_path_per_site` identity gives. That identity is asked only when the draft is published,
  so a draft's settings were saved with the path and its publish then failed.

  The page the draft edits (`source_page_id`), or the page being updated, keeps its own path. Asked
  when the path changes, and checked whoever writes: the rule is about the pages, not the actor.

  On `Page`'s creates and updates it is asked before the write, where the index would refuse the
  path. The refusal carries the path in its `vars` as `:answered_at`, as
  `Validations.PublicAddress`'s does, so `MishkaCmsCore.Runtime.PageProvision.create/2` leaves a
  page whose path arrived after its plan out of a run instead of raising.

      validate {MishkaCmsCore.Runtime.Resources.Validations.PagePathUnique, []},
        on: [:create, :update]
  """
  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query

  alias MishkaCmsCore.Runtime.Page

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    path = Ash.Changeset.get_attribute(changeset, :path)
    site_id = Ash.Changeset.get_attribute(changeset, :site_id)

    if Ash.Changeset.changing_attribute?(changeset, :path) and is_binary(path) and
         is_binary(site_id) and
         taken?(path, site_id, own_page(changeset)) do
      {:error,
       field: :path,
       answered_at: path,
       message: dgettext("errors", "Page path must be unique within a site.")}
    else
      :ok
    end
  end

  defp own_page(%{resource: Page, action_type: :update, data: page}), do: page.id
  defp own_page(changeset), do: Ash.Changeset.get_attribute(changeset, :source_page_id)

  defp taken?(path, site_id, own_page_id) do
    Page
    |> Ash.Query.filter(path == ^path)
    |> other_than(own_page_id)
    |> Ash.exists?(tenant: site_id, authorize?: false)
  end

  defp other_than(query, nil), do: query
  defp other_than(query, id), do: Ash.Query.filter(query, id != ^id)
end
