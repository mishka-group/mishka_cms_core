# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.ElementCssRules do
  @moduledoc """
  Validates a draft's `element_css`: `%{scope => body}`, the CSS an author applied to single
  elements while the editor's stage said Draft. A blank body stands for a rule the author cleared.

  Each pair must be one `MishkaCmsCore.Runtime.Authoring.ElementCss.place/3` takes: a scope class the
  editor mints, and a body that cannot close the `.pb-xxxxxxxx { … }` wrapper it is written into.
  The draft preview compiles these rules, and publishing the draft writes them into the site's
  stylesheet row, so a pair the editor's own box refuses is refused here too, whoever writes the draft.
  """
  use Gettext, backend: MishkaCmsCore.Gettext
  use Ash.Resource.Validation

  alias MishkaCmsCore.Runtime.Authoring.ElementCss

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.changing_attribute?(changeset, :element_css) do
      true -> changeset |> Ash.Changeset.get_attribute(:element_css) |> checked()
      false -> :ok
    end
  end

  defp checked(nil), do: :ok
  defp checked(rules) when is_map(rules), do: Enum.reduce_while(rules, :ok, &rule/2)
  defp checked(_rules), do: shape_error()

  defp rule({scope, body}, :ok) when is_binary(scope) and is_binary(body) do
    case ElementCss.place(%{}, scope, body) do
      {:ok, _rules} -> {:cont, :ok}
      {:error, message} -> {:halt, {:error, field: :element_css, message: message}}
    end
  end

  defp rule(_pair, :ok), do: {:halt, shape_error()}

  defp shape_error,
    do:
      {:error,
       field: :element_css,
       message: dgettext_noop("errors", "Element CSS must map each element's scope to its CSS.")}
end
