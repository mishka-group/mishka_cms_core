defmodule MishkaCmsCore.Runtime.Resources.BooleanColumnRenderTest do
  @moduledoc """
  A column's `render` fn is handed one of two different things, and picking the wrong one crashes at
  runtime rather than at compile time — so both shapes are pinned here.

  A plain attribute column's render fn receives the CELL VALUE (`record.active`, a boolean). Naming
  that argument `record` and reaching into it raises `BadMapError: expected a map, got: false`.

  A `static true` column's render fn receives the WHOLE RECORD, because it draws several fields at
  once and names them in `requires`. `:active_compile` is that: one cell showing both `active` and
  `precompile`, which is why the four runtime resources that precompile no longer carry a separate
  `:precompile` column.

  `State.init/3` reads the database (a table's relationship filters load their options), so each
  test owns a sandboxed connection instead of reaching whichever one the previous test shared.
  """
  use MishkaCmsCore.DataCase, async: false

  import Phoenix.LiveViewTest

  alias MishkaGervaz.Table.Web.State

  @user %{id: "bool-col", site_id: nil, role: :admin}

  defp column(resource, source) do
    State.init("bool-col", resource, @user)
    |> Map.fetch!(:static)
    |> Map.fetch!(:columns)
    |> Enum.find(&(Map.get(&1, :source) == source))
  end

  describe "a plain attribute column renders from the cell value" do
    test "Stylesheet :active" do
      col = column(MishkaCmsCore.Runtime.Stylesheet, :active)

      assert col, "Stylesheet: :active column not found"
      refute col.static, "Stylesheet: :active should not be a static column"
      assert is_function(col.render, 1)

      assert col.render.(true) |> rendered_to_string() =~ "Active"
      assert col.render.(false) |> rendered_to_string() =~ "Inactive"
    end
  end

  describe "a static column renders from the whole record" do
    for {resource, label} <- [
          {MishkaCmsCore.Runtime.Page, "Page"},
          {MishkaCmsCore.Runtime.Layout, "Layout"},
          {MishkaCmsCore.Runtime.ErrorPage, "ErrorPage"},
          {MishkaCmsCore.Runtime.Component, "Component"}
        ] do
      # All four runtime tables read the same two fields now. Components were the exception —
      # `precompile` was added to that resource after this column was written, so the one list where
      # precompilation is most often decided was the one that would not tell you the answer.
      test "#{label} :active_compile reads both fields" do
        col = column(unquote(resource), :active_compile)
        label = unquote(label)

        assert col, "#{label}: :active_compile column not found"
        assert col.static, "#{label}: :active_compile must be static to read two fields"
        assert :active in col.requires and :precompile in col.requires
        assert is_function(col.render, 1)

        on_html = col.render.(%{active: true, precompile: true}) |> rendered_to_string()
        off_html = col.render.(%{active: false, precompile: false}) |> rendered_to_string()

        assert on_html =~ "Active", "#{label}: an active record should read Active"
        assert off_html =~ "Inactive", "#{label}: an inactive record should read Inactive"
      end
    end
  end

  describe "a column driven by the :badge type needs no render fn of its own" do
    test "JsHook :active" do
      col = column(MishkaCmsCore.Runtime.JsHook, :active)

      assert col, "JsHook: :active column not found"
      assert col.ui.type == :badge
      assert col.ui.extra.labels == %{"true" => "Active", "false" => "Inactive"}
    end
  end
end
