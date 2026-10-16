# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Changes.NameFromTitle do
  @moduledoc """
  Names a page after its title when the writer did not name it.

  A page has two words for itself. `title` is what it is called, in the language it is written in,
  and it is never slugified. `name` is the key `unique_name_per_site` is keyed on — it is not in any
  URL, `path` is — so nobody reads it and nobody should have to type it.

  ## Only on create

  Renaming a page's title does not rename its key. A `name` derived on every save would be
  re-slugified on every save, and the row's identity would move under an author who only fixed a
  typo. So this runs in the create actions alone, and an update leaves `name` exactly as written.

  ## What it derives from

  `title` first, then `path` for a title that slugifies to nothing (a title of emoji, or of a script
  `Slug` does not transliterate), then `"page"`. A Persian title lands on its
  transliteration — `قیمت‌گذاری` becomes `qymtgdhry` — and that is fine for a key nobody sees.

  ## The suffix, and where it costs a query

  Two pages on one site may be called the same thing. The first free member of `base`, `base-2`,
  `base-3` … is taken, measured against the names the site already holds, so the second
  `قیمت‌گذاری` is `qymtgdhry-2` rather than a constraint error naming a field the author never saw.

  That measurement is the only part that reads the database, and it is deferred to a `before_action`
  so it runs once per WRITE rather than once per changeset. `AshPhoenix.Form` builds a changeset on
  every `phx-change`, so doing it inline would put a `SELECT` behind every keystroke in the Title
  box. The hook is attached only when this module supplied the name — a caller who passed one never
  pays for it.

      create :create do
        change MishkaCmsCore.Runtime.Resources.Changes.NameFromTitle
      end
  """
  use Ash.Resource.Change

  require Ash.Query

  @fallback "page"
  @min_length 3
  @max_length 200

  # NOT A `before_action`. `allow_nil? false` on `:name` is checked while the changeset is still
  # being built, so a hook that ran after that check would never be reached — the write would be
  # refused for a field this module exists to fill.
  @impl true
  def change(changeset, _opts, _context), do: named(changeset)

  # ALREADY NAMED IS LEFT ALONE. The seeds, the extension installs and the API name their pages, and
  # the resource's own `slugify(:name, into: :name)` has already run on what they passed.
  #
  # The slug itself is set here, not in the hook: `allow_nil? false` on `:name` is checked while the
  # changeset is still being built, so a name that only appeared in a `before_action` would be
  # refused before the hook was ever reached.
  defp named(changeset) do
    case Ash.Changeset.get_attribute(changeset, :name) do
      name when is_binary(name) and name != "" ->
        changeset

      _unnamed ->
        changeset
        |> Ash.Changeset.force_change_attribute(:name, base(changeset))
        |> Ash.Changeset.before_action(&free/1)
    end
  end

  # ONE QUERY, AT THE WRITE. Attached only for a name this module minted, so validating a form does
  # not pay for it.
  defp free(changeset) do
    base = Ash.Changeset.get_attribute(changeset, :name)
    held = held(changeset, base)

    taken =
      Stream.iterate(1, &(&1 + 1))
      |> Stream.map(fn
        1 -> base
        step -> cut(base, step) <> "-#{step}"
      end)
      |> Enum.find(&(&1 not in held))

    Ash.Changeset.force_change_attribute(changeset, :name, taken)
  end

  defp base(changeset) do
    [:title, :path]
    |> Enum.map(&Ash.Changeset.get_attribute(changeset, &1))
    |> Enum.concat([@fallback])
    |> Enum.find_value(@fallback, &slug/1)
    |> cut(0)
  end

  defp slug(text) when is_binary(text) do
    case Slug.slugify(text) do
      slug when is_binary(slug) and byte_size(slug) >= @min_length -> slug
      _too_little_survived_it -> nil
    end
  end

  defp slug(_not_a_binary), do: nil

  # `name` is `max_length: 200`, and the suffix has to fit inside that too.
  defp cut(base, step), do: String.slice(base, 0, @max_length - String.length("-#{step}"))

  # THE NAMES THIS SITE ALREADY HOLDS under this base, read in one query rather than one per
  # candidate. Archived rows are outside the resource's base filter and outside the identity with
  # it, so a name a discarded page used is free again.
  defp held(changeset, base) do
    changeset.resource
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(like(name, ^(base <> "%")))
    |> Ash.Query.select([:name])
    |> Ash.read!(authorize?: false, tenant: site(changeset), page: false)
    |> MapSet.new(& &1.name)
  end

  defp site(changeset) do
    changeset.tenant || Ash.Changeset.get_attribute(changeset, :site_id)
  end
end
