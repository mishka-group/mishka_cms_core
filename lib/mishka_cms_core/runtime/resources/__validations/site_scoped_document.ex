# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.SiteScopedDocument do
  @moduledoc """
  Refuses a global row about a document that cannot itself be global.

  ## What it is for

  `MishkaCmsCore.Runtime.PageComment` is `global? true`, because the builder edits documents that
  are global — components and layouts — as well as documents that are not. But the two `global?
  false` documents, **pages** and **error pages**, always belong to exactly one site, so a note
  about one has no honest reading as "belongs to no site". Left unguarded, such a row is visible to
  every tenant on every site, which is the opposite of what a page note means.

  It was true in practice already, by accident: the builder happens to hand a master the record's
  own `site_id`. That is a LiveView doing the right thing, not a rule — and a JSON:API caller, a
  seed, or a future screen would not know to. This makes it a rule.

  ## Options

    * `:sections` — the section values that require a site. Required.
    * `:attribute` — where the section is stored. Defaults to `:section`.

  ## Usage

      create :master_create do
        validate {SiteScopedDocument, sections: [:page, :error_page]}
      end

  A section not in the list is left alone: a note on a component may be global, and a tenant's note
  on that same component is stamped with their own site by the tenant action, not by this.
  """
  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  @impl true
  def init(opts) do
    case Keyword.get(opts, :sections) do
      sections when is_list(sections) and sections != [] ->
        {:ok, Keyword.put_new(opts, :attribute, :section)}

      other ->
        raise ArgumentError,
              "SiteScopedDocument requires a non-empty :sections list, got: #{inspect(other)}"
    end
  end

  @impl true
  def validate(changeset, opts, context) do
    section = Ash.Changeset.get_attribute(changeset, opts[:attribute])
    site_id = Ash.Changeset.get_attribute(changeset, :site_id) || Map.get(context, :tenant)

    if section in opts[:sections] and is_nil(site_id) do
      {:error, field: :site_id, message: refusal(section)}
    else
      :ok
    end
  end

  defp refusal(:page),
    do: dgettext_noop("errors", "A note about a page belongs to one site, so it needs that site.")

  defp refusal(:error_page),
    do:
      dgettext_noop(
        "errors",
        "A note about an error page belongs to one site, so it needs that site."
      )

  defp refusal(_section),
    do: dgettext_noop("errors", "A note about this belongs to one site, so it needs that site.")

  @impl true
  def has_validate?, do: true

  @impl true
  def supports(_opts), do: [Ash.Changeset]
end
