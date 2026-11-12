# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.PathFormat do
  @moduledoc """
  Validates a resource `path` as a safe, canonical URL route path — used by the
  Page, Layout, and ErrorPage resources and their drafts.

  A valid path:

    * starts with `/`
    * contains no `..` (directory traversal) and no `//` (empty segment)
    * uses only letters, marks and digits of any script, and `- _ / . : *` (covering nested
      paths, route params like `:id`, and wildcards like `*rest`): `/fa/وردپرس` is a path, and so
      is the zero-width non-joiner a Persian word is written with. No space and no other
      punctuation.
    * holds at most one `*` wildcard, at the start of a segment (`/*category/:slug`, `/blog/*`)
    * is at most 255 characters

  It is checked as `MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState.canonical_path/1` reads
  it, so a path pasted with its `%XX` escapes is checked as the letters they stand for, which is
  what `MishkaCmsCore.Runtime.Resources.Changes.PagePath` stores.

  This runs at the action boundary in every environment, so no page can be created
  or edited with a path that is traversal-prone, ambiguous (`//`), or unroutable. It
  reports the specific rule that failed, which the JSON:API surfaces to the caller —
  strict enough for production, clear enough for development.

  Mirrors `MishkaCmsCore.Runtime.Resources.Validations.DomainValidator`.
  """

  use Gettext, backend: MishkaCmsCore.Gettext
  use Ash.Resource.Validation

  alias MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState

  @max_length 255
  @allowed_chars ~r|\A[\p{L}\p{M}\p{N}\x{200C}/_.:*-]+\z|u

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :path) do
      nil ->
        :ok

      path when is_binary(path) ->
        path |> WebRunTimeMetaDataState.canonical_path() |> validate_path()

      path ->
        validate_path(path)
    end
  end

  defp validate_path(path) when not is_binary(path),
    do: {:error, field: :path, message: dgettext_noop("errors", "Path must be a string.")}

  defp validate_path(path) do
    cond do
      !String.starts_with?(path, "/") ->
        error(dgettext_noop("errors", "Path must start with '/'"))

      String.length(path) > @max_length ->
        error(dgettext_noop("errors", "Path must be at most %{max} characters"), max: @max_length)

      String.contains?(path, "..") ->
        error(dgettext_noop("errors", "Path must not contain '..' (directory traversal)"))

      String.contains?(path, "//") ->
        error(dgettext_noop("errors", "Path must not contain '//' (empty path segment)"))

      !String.match?(path, @allowed_chars) ->
        error(
          dgettext_noop(
            "errors",
            "Path may only contain letters, digits, and the characters - _ / . : *"
          )
        )

      match?([_, _, _ | _], String.split(path, "*")) ->
        error(dgettext_noop("errors", "Path may hold only one wildcard like *rest"))

      String.match?(path, ~r{[^/]\*}) ->
        error(dgettext_noop("errors", "A wildcard like *rest must start a path segment"))

      true ->
        :ok
    end
  end

  defp error(message, bindings \\ []) do
    {:error,
     field: :path, message: Gettext.dgettext(MishkaCmsCore.Gettext, "errors", message, bindings)}
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def describe(_opts) do
    [message: "Validates that path is a safe, canonical URL route path", vars: []]
  end
end
