defmodule MishkaCmsCore.CoreComponentsButtonTest do
  @moduledoc """
  `button/1` declares its `type`, defaulting to `"submit"`, so the page builder can read it as a Send
  button. The markup every existing caller renders stays exactly as it was: `"submit"` is what a
  `<button>` with no type already does, so it is not written.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MishkaCmsCore.CoreComponents

  defp button(assigns, text \\ "Send") do
    slot = [%{__slot__: :inner_block, inner_block: fn _changed, _arg -> text end}]

    (&CoreComponents.button/1)
    |> render_component(Map.put(assigns, :inner_block, slot))
    |> LazyHTML.from_fragment()
  end

  defp type_of(html), do: html |> LazyHTML.query("button") |> LazyHTML.attribute("type")

  test "declares its type, defaulting to submit, with the three HTML allows" do
    {_fun, meta} = Enum.find(CoreComponents.__components__(), &(elem(&1, 0) == :button))
    type = Enum.find(meta.attrs, &(&1.name == :type))

    assert type.opts[:default] == "submit"
    assert type.opts[:values] == ~w(button submit reset)
  end

  test "a caller that passes no type renders the same untyped button as before" do
    html = button(%{})

    assert LazyHTML.query(html, "button") |> Enum.count() == 1
    assert type_of(html) == []
  end

  test "an explicit submit is left to HTML's own default too" do
    assert type_of(button(%{type: "submit"})) == []
  end

  test "button and reset are written, so the button stops sending its form" do
    assert type_of(button(%{type: "button"})) == ["button"]
    assert type_of(button(%{type: "reset"})) == ["reset"]
  end

  test "a link-styled button is still a link, and its type is not written on the link" do
    html = button(%{navigate: "/home", type: "button"}, "Home")

    assert LazyHTML.query(html, "button") |> Enum.count() == 0
    assert html |> LazyHTML.query("a") |> LazyHTML.attribute("type") == []
  end
end
