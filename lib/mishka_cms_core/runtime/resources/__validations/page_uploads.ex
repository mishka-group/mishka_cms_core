# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.PageUploads do
  @moduledoc """
  Refuses a page whose `uploads` declares a file field no visitor could use.

  A published page is a form an anonymous visitor posts to, so every upload names the types it
  takes, checked at the action boundary every writer passes — the builder, the page form, the JSON
  API and a seed alike:

    * `accept` is required: `image/*, .pdf` says what is wanted, and nothing says "anything";
    * every type in it is one `MishkaCmsCore.Runtime.PageUpload.allowed_types/0` lists. HTML, SVG, XML
      and script files are never among them, because the site serves what a visitor uploads from its
      own origin.

  A row with no name is left to the compiler, which drops it: a half-filled row is one keystroke
  away from a finished one.
  """

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.PageUpload

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.changing_attribute?(changeset, :uploads) do
      false ->
        :ok

      true ->
        changeset |> Ash.Changeset.get_attribute(:uploads) |> List.wrap() |> checked()
    end
  end

  defp checked(entries) do
    entries
    |> Enum.filter(&is_map/1)
    |> Enum.find_value(:ok, &refusal/1)
  end

  defp refusal(entry) do
    case field(entry, :name) do
      name when is_binary(name) -> refusal(String.trim(name), field(entry, :accept))
      _unnamed -> nil
    end
  end

  defp refusal("", _accept), do: nil

  defp refusal(name, accept) do
    case {PageUpload.allowed_extensions(accept), PageUpload.unsupported(accept)} do
      {[], []} ->
        {:error, field: :uploads, message: required(name)}

      {_allowed, []} ->
        nil

      {_allowed, unsupported} ->
        {:error, field: :uploads, message: unsupported(name, unsupported)}
    end
  end

  defp required(name) do
    dgettext(
      "errors",
      "The upload %{name} needs Accepted Types, such as image/*, .pdf. Choose from: %{types}.",
      name: name,
      types: types()
    )
  end

  defp unsupported(name, tokens) do
    dgettext(
      "errors",
      "The upload %{name} cannot take %{unsupported}. HTML, SVG, XML and script files can never be uploaded; choose from: %{types}.",
      name: name,
      unsupported: Enum.join(tokens, ", "),
      types: types()
    )
  end

  defp types, do: Enum.map_join(PageUpload.allowed_types(), ", ", &("." <> &1))

  defp field(entry, key), do: Map.get(entry, key) || Map.get(entry, Atom.to_string(key))

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def describe(_opts),
    do: [message: "Validates that each upload names the file types a visitor may send", vars: []]
end
