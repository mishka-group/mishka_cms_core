# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Changes.InternalName do
  @moduledoc """
  Writes an internal name: the `name` of a component, layout, page, site, media item and the rest,
  which becomes an Elixir module segment, a CSS or JS name and a file name.

  The name is the `MishkaSlug.slugify/2` slug of what was typed with `options/0`: Latin letters and
  `0-9` only (Persian, Arabic-Indic and Devanagari digits become `0-9`, so `Header ۱۲۳` is `header-123`), accents removed (`Café Crème` is `cafe-creme`), and every other character a word
  break, `_` and `.` too, so a name is always lowercase `a-z`, `0-9` and single inner `-`. Letters
  of other scripts are dropped, so `Hello قیمت` is `hello`. A name with nothing Latin left is
  refused with this module's own message on the field the admin typed, whatever reason the slug
  gives and whatever the site languages are, never stored empty.

      create :create do
        change MishkaCmsCore.Runtime.Resources.Changes.InternalName
      end

  It reads `:name` and writes `:name` unless `from:`/`into:` say otherwise, and takes every other
  `MishkaSlug.Change` option, which `init/1` checks. Code that needs a name outside an action uses
  `slug/1`; a form preview reads the change off the action (`MishkaCmsCore.Runtime.Helpers.slugifiers/1`).
  """
  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  alias Ash.Changeset

  @options [locales: ["en"], keep: [], digits: :ascii]

  @doc "The `MishkaSlug.slugify/2` options every internal name is made with."
  @spec options() :: keyword()
  def options, do: @options

  @doc """
  The name a save stores for `text`, or `nil` when nothing Latin is left in it.

      InternalName.slug("Café Crème") #=> "cafe-creme"
      InternalName.slug("قیمت")       #=> nil
  """
  @spec slug(String.t()) :: String.t() | nil
  def slug(text) when is_binary(text) do
    case MishkaSlug.slugify(text, @options) do
      {:ok, slug} -> slug
      {:error, _nothing_latin} -> nil
    end
  end

  @impl true
  def init(opts), do: MishkaSlug.Change.init(Keyword.merge([from: :name] ++ @options, opts))

  @impl true
  def change(changeset, opts, context) do
    with {:ok, text} when is_binary(text) <-
           Changeset.fetch_argument_or_change(changeset, opts[:from]),
         {:error, _no_latin} <-
           MishkaSlug.slugify(text, MishkaSlug.Change.slug_options(opts, changeset)) do
      Changeset.add_error(changeset, field: opts[:from], message: latin_only())
    else
      _named_or_untouched -> MishkaSlug.Change.change(changeset, opts, context)
    end
  end

  defp latin_only,
    do:
      dgettext(
        "errors",
        "must have Latin letters (a-z) or digits: a name is used in code and file names, so other letters are removed"
      )
end
