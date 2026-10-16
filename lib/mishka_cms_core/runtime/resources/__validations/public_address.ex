# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.PublicAddress do
  @moduledoc """
  Refuses a page whose public addresses cannot be what it says, or are already another page's.

    * A page marked as answering every language (`PageProvision.serves_all_languages?/1`) on a path
      that captures no `lang` is refused: only a `lang` capture answers more than one language.
    * An active page is refused when one of its public addresses is one another active page of its
      site already answers at. The refusal names that page — its title and its stored path — and
      the address.

  A page's public addresses are `MishkaCmsCore.Runtime.PageEditions.urls/3`'s — a literal page's
  one, one per language a page whose only capture is the language answers in — compared as the site
  builds them with its primary language unprefixed. Two addresses that are one with a prefix for
  every language are one without, so this holds in both URL modes
  (`MishkaCmsCore.Runtime.Languages.url_mode/1`), and a site that switches modes finds no page
  hidden behind another: while English is the site's first language, `/en/about` and `/about` are
  refused together, and so are a literal `/fa/about` and an `/:lang/about` answering Persian. A
  pattern with any other capture is the template of many addresses, left to the resolver's
  precedence — `/post/new` before `/post/:slug`.

  Asked when the path, the language, `extra` or `active` changes, before the write and with the
  actor and the authorization the action runs with. The second refusal carries the address in its
  `vars` as `:answered_at`, which is how `MishkaCmsCore.Runtime.PageProvision.create/2` tells it
  from any other and leaves the page out of a run instead of raising.

      validate {MishkaCmsCore.Runtime.Resources.Validations.PublicAddress, []},
        before_action?: true
  """
  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query

  alias MishkaCmsCore.Runtime.{Languages, Page, PageEditions, PageProvision}

  @fields [:path, :language, :extra, :active]

  # The form every address is compared in — see the moduledoc.
  @compared "prefix_others"

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, context) do
    page =
      Map.new([:id, :path, :language, :extra, :active, :site_id], &{&1, attribute(changeset, &1)})

    cond do
      not Enum.any?(@fields, &Ash.Changeset.changing_attribute?(changeset, &1)) ->
        :ok

      PageProvision.serves_all_languages?(page) and not Languages.captures?(page.path) ->
        {:error,
         field: :path,
         message:
           dgettext(
             "errors",
             "Only a path with :lang in it can answer every language. Add :lang to the path, or let the page answer its own language."
           )}

      page.active != true ->
        :ok

      true ->
        taken(page, context)
    end
  end

  defp attribute(changeset, field), do: Ash.Changeset.get_attribute(changeset, field)

  defp taken(%{site_id: site_id} = page, context) when is_binary(site_id) do
    case PageEditions.urls(page, site_id, @compared) do
      [] -> :ok
      addresses -> answered(page, MapSet.new(addresses), context)
    end
  end

  defp taken(_page, _context), do: :ok

  defp answered(page, addresses, context) do
    page
    |> others(context)
    |> Enum.find_value(:ok, fn other ->
      case Enum.find(PageEditions.urls(other, page.site_id, @compared), &(&1 in addresses)) do
        nil ->
          nil

        address ->
          shown = Languages.url(address, %{}, page.site_id) || address

          {:error,
           field: :path,
           answered_at: shown,
           message:
             dgettext("errors", "The page “%{page}” at %{path} already answers at %{address}.",
               page: other.title || other.name,
               path: other.path,
               address: shown
             )}
      end
    end)
  end

  defp others(%{id: id, site_id: site_id}, context) do
    Page
    |> Ash.Query.filter(active == true)
    |> then(&if is_nil(id), do: &1, else: Ash.Query.filter(&1, id != ^id))
    |> Ash.Query.select([:id, :name, :title, :path, :language, :extra])
    |> Ash.read(
      tenant: site_id,
      actor: context.actor,
      authorize?: context.authorize?,
      page: false
    )
    |> case do
      {:ok, pages} -> pages
      {:error, _unreadable} -> []
    end
  end

  @impl true
  def describe(_opts),
    do: [message: "Refuses a page whose public address another page already answers", vars: []]
end
