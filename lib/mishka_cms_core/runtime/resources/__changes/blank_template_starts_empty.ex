# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Changes.BlankTemplateStartsEmpty do
  @moduledoc """
  Lets a document be created without any markup, by giving a blank one the empty starter container.

  Add it to a create action, **before** the validations that demand a template:

      create :create do
        change MishkaCmsCore.Runtime.Resources.Changes.BlankTemplateStartsEmpty
        validate present([:template])
        ...
      end

  A layout wraps a page, so it takes the starter that already has `@inner_content` in it:

      change {MishkaCmsCore.Runtime.Resources.Changes.BlankTemplateStartsEmpty, starter: :layout}

  ## Why a change and not a relaxed attribute

  `template` is `NOT NULL` in Postgres with a `length(template) >= 3` check and a `no_empty_strings`
  constraint. Making the column nullable to allow an empty page would weaken a guarantee every other
  reader of that column relies on — including the runtime compiler, which has no meaningful answer
  for `nil`. Filling the blank instead keeps the column's promise exactly as it was and moves the
  choice to where it belongs: what an *empty page* means.

  It means one centred container. `MishkaCmsCore.Runtime.Authoring.PageStarter.blank/0` owns that
  answer so the form, the API and the seeds all create the same empty page.

  ## Why it runs everywhere, not just in the form

  A page created through JSON:API or a seed with no template used to be a validation error. There is
  no reason it should be: the visual editor opens an empty document perfectly well, and the author
  who left the field alone plainly meant "I will build it there". Putting the default in the action
  rather than in the form is what makes that true for every caller.

  Whitespace counts as blank. A template of `"   "` was already refused by the actions' own
  emptiness check; now it is simply treated as "none given".
  """
  use Ash.Resource.Change

  alias MishkaCmsCore.Runtime.Authoring.PageStarter

  @impl true
  def change(changeset, opts, _context) do
    changeset
    |> Ash.Changeset.get_attribute(:template)
    |> blank?()
    |> fill(changeset, Keyword.get(opts, :starter, :page))
  end

  defp fill(true, changeset, starter),
    do: Ash.Changeset.force_change_attribute(changeset, :template, PageStarter.blank(starter))

  defp fill(false, changeset, _starter), do: changeset

  defp blank?(nil), do: true
  defp blank?(template) when is_binary(template), do: String.trim(template) == ""
  defp blank?(_template), do: false
end
