# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.FlashKindsTest do
  @moduledoc """
  Every flash kind (`:success`, `:info`, `:warning`, `:error`) renders through both `flash_group/1`
  and `flash/1` with its own colour, its own icon and the announcement role that fits it.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MishkaCmsCore.CoreComponents
  alias MishkaCmsCore.Layouts

  @kinds %{
    success: {"hero-check-circle", "status"},
    info: {"hero-information-circle", "status"},
    warning: {"hero-exclamation-triangle", "alert"},
    error: {"hero-x-circle", "alert"}
  }

  defp group(flash), do: render_component(&Layouts.flash_group/1, flash: flash)

  describe "flash_group/1" do
    for {kind, {icon, role}} <- @kinds do
      test "#{kind} renders its own icon, role and dismiss kind" do
        html = group(%{unquote(to_string(kind)) => "Hello #{unquote(kind)}"})

        assert html =~ ~s(id="flash-#{unquote(kind)}")
        assert html =~ "Hello #{unquote(kind)}"
        assert html =~ unquote(icon)
        assert html =~ ~s(role="#{unquote(role)}")
        assert html =~ ~s(data-kind="#{unquote(kind)}")
        assert html =~ ~s(phx-hook="FlashAutoDismiss")
      end
    end

    test "each kind has a colour no other kind shares" do
      colours =
        for kind <- Map.keys(@kinds) do
          html = group(%{to_string(kind) => "x"})
          [colour] = Regex.run(~r/\[background:#[0-9a-f]{6}\]/, html)
          colour
        end

      assert length(Enum.uniq(colours)) == 4
    end

    test "a kind that is not set draws nothing" do
      html = group(%{"warning" => "careful"})

      assert html =~ "careful"
      assert html =~ "flash-warning"
      refute html =~ "flash-success"
      refute html =~ "flash-error"
    end

    test "kinds stack together" do
      html = group(%{"success" => "a", "warning" => "b"})

      assert html =~ "flash-success"
      assert html =~ "flash-warning"
    end
  end

  describe "flash/1" do
    for {kind, {icon, role}} <- @kinds do
      test "#{kind} renders its icon and role" do
        html =
          render_component(&CoreComponents.flash/1,
            kind: unquote(kind),
            flash: %{unquote(to_string(kind)) => "msg"}
          )

        assert html =~ "msg"
        assert html =~ unquote(icon)
        assert html =~ ~s(role="#{unquote(role)}")
        assert html =~ ~s(data-kind="#{unquote(kind)}")
      end
    end
  end
end
