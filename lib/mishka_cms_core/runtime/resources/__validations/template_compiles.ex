# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.TemplateCompiles do
  @moduledoc """
  Refuses a layout, component or error page whose markup HEEx will not take, at the action boundary.

  `MishkaCmsCore.Runtime.Resources.Validations.PageCodeCompiles` has done this for a `Page` since it
  existed, and it is the reason a page cannot even be seeded broken. The other three had nothing:
  the row was stored, `MishkaCmsCore.Runtime.RuntimeStatus` reported `Ready`, the compile then failed
  into `MishkaCmsCore.Runtime.States.CompileFailureState`, and the site went on serving the module it
  already had. The author is told nothing at any point in that.

  ## Why this is the syntax half and not the whole compile

  `PageCodeCompiles` builds the whole LiveView, which is about a second of work and the right price
  for a page — its handlers and helpers are author-written Elixir that only a real compile can judge.
  A layout, a component and an error page are markup plus, at most, helpers; the failure that
  actually happens is markup the tokenizer accepts and the engine does not:

      {@a + }              parses as an expression, is not Elixir      → caught by `to_heex/1`
      <div :foo={@a}>      a special attribute that does not exist     → caught HERE, and nowhere else
      <div :for={@a}>      `:for` without a generator                  → the same
      <:header>x</:header> a slot entry outside a component            → the same

  `CodeCheck.template/1` is `Phoenix.LiveView.TagEngine.compile/2` — the call every one of this
  runtime's compilers makes — with no module built around it, so it costs milliseconds. What it
  cannot see is anything semantic, which is what the compile pipeline is for.

  ## An error page is a list

  It keeps `error_pages`, one entry per status, so "the template" is several of them; each is checked
  and the first fault names the status it came from, because "line 4" means nothing when the reader
  has five documents open in one record.

  ## What is deliberately NOT checked

  `root_layout_template` is not HEEx and must not be judged as if it were.
  `MishkaCmsCore.Runtime.Compilers.ErrorCompiler` compiles it with `EEx.compile_string/2` and
  `Phoenix.HTML.Engine` — the classic engine — precisely *because* it relies on EEx interpolation
  inside an attribute (`content="<%= Phoenix.Controller.get_csrf_token() %>"`), which HEEx rejects
  and which the shipped seeds use. Every per-status template beside it goes through the TagEngine and
  is checked here; the root layout is a different language in the same record.
  """

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.PageBuilder.CodeCheck

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    changeset
    |> templates()
    |> Enum.find_value(:ok, &fault/1)
  end

  defp fault({field, scope, template}) do
    case CodeCheck.template(template) do
      :ok -> nil
      {:error, fault} -> {:error, field: field, message: refusal(scope, CodeCheck.message(fault))}
    end
  end

  defp refusal(:own, detail), do: detail

  defp refusal({:status, status}, detail) when status in [nil, false],
    do: dgettext("errors", "The error page: %{detail}", detail: detail)

  defp refusal({:status, status}, detail),
    do:
      dgettext("errors", "The %{status} page: %{detail}",
        status: to_string(status),
        detail: detail
      )

  # ONLY WHAT THIS WRITE CHANGED. A record whose stored markup predates this validation must stay
  # editable — refusing every other field on it because the template is old would lock the author out
  # of the one screen the template gets fixed in.
  defp templates(changeset) do
    case Ash.Changeset.changing_attribute?(changeset, :template) do
      true -> [{:template, :own, Ash.Changeset.get_attribute(changeset, :template) || ""}]
      false -> []
    end ++ status_templates(changeset)
  end

  defp status_templates(changeset) do
    case Ash.Changeset.changing_attribute?(changeset, :error_pages) do
      false ->
        []

      true ->
        changeset
        |> Ash.Changeset.get_attribute(:error_pages)
        |> List.wrap()
        |> Enum.map(&{:error_pages, {:status, status(&1)}, template(&1)})
    end
  end

  defp status(entry), do: Map.get(entry, "status") || Map.get(entry, :status)
  defp template(entry), do: Map.get(entry, "template") || Map.get(entry, :template) || ""

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def describe(_opts), do: [message: "Validates that the markup compiles as HEEx", vars: []]
end
