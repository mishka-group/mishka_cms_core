# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.ErrorPageCompiles do
  @moduledoc """
  Refuses an Error Page whose code will not compile, before it is stored, as
  `MishkaCmsCore.Runtime.Resources.Validations.PageCodeCompiles` refuses a page.

  All the entries of an Error Page, its root layout and its helpers compile into one module, so one
  entry that calls a function nobody defines would take the site's 404, its 500 and its offline page
  with it.

  The error is on the attribute the fault is in and names the entry: "The 404 page: …". Only a write
  that changes `:error_pages`, `:root_layout_template` or `:helpers` is judged, so a row stored before
  the rule stays editable.

  Declare it with `before_action?: true`: it compiles, so it is asked once, when a write that is
  otherwise valid is made, and not at each change of a form.
  `MishkaCmsCore.Runtime.Resources.Validations.TemplateCompiles` reads the markup alone there.
  """

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.Authoring.CodeCheck
  alias MishkaCmsCore.Runtime.Resources.Validations.TemplateCompiles

  @fields [:error_pages, :root_layout_template, :helpers]

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    case Enum.any?(@fields, &Ash.Changeset.changing_attribute?(changeset, &1)) do
      true -> check(changeset)
      false -> :ok
    end
  end

  # The whole row, not just what changed: an entry may call a helper this write removes.
  defp check(changeset) do
    error_page = Map.new(@fields, &{&1, Ash.Changeset.get_attribute(changeset, &1)})

    with {:error, {part, fault}} <- CodeCheck.error_page(error_page) do
      {:error, field: field(part), message: message(part, CodeCheck.message(fault))}
    end
  end

  defp field({:status, _status}), do: :error_pages
  defp field(field), do: field

  defp message({:status, status}, detail), do: TemplateCompiles.status_refusal(status, detail)
  defp message(_shared, detail), do: detail

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def describe(_opts) do
    [
      message: "Validates that the error page's entries, root layout and helpers compile",
      vars: []
    ]
  end
end
