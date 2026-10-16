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
    * uses only URL-path-safe characters — letters, digits, and `- _ / . : *`
      (covering nested paths, route params like `:id`, and wildcards like `*rest`)
    * is at most 255 characters

  This runs at the action boundary in every environment, so no page can be created
  or edited with a path that is traversal-prone, ambiguous (`//`), or unroutable. It
  reports the specific rule that failed, which the JSON:API surfaces to the caller —
  strict enough for production, clear enough for development.

  Mirrors `MishkaCmsCore.Runtime.Resources.Validations.DomainValidator`.
  """

  use Gettext, backend: MishkaCmsCore.Gettext
  use Ash.Resource.Validation

  @max_length 255
  @allowed_chars ~r|^[a-zA-Z0-9/_.:*-]+$|

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :path) do
      nil -> :ok
      path -> validate_path(path)
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
