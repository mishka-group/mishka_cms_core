defmodule MishkaCmsCore.Runtime.PageBuilder.LiveView.RenderedHtmlTest do
  @moduledoc """
  The builder's encoder attaches a `rendered_html` preview by actually rendering the node, so this is
  where the component import in `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler`'s eval env is
  proven end to end: `<.icon>` is compiled to a bare local call, and only resolves because that env
  imports the module `config :mishka_cms_core, :core_components` names — this library's own
  `MishkaCmsCore.CoreComponents` here, `MishkaCmsWeb.CoreComponents` in the CMS.

  A component the running application does not define is kept WITHOUT a preview rather than failing,
  which is the other half of the contract and is covered here too.

  See `MishkaCmsCore.Runtime.PageBuilder.LiveView.JsonEncoderTest` for the encoder's own shapes.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.PageBuilder.LiveView.JsonEncoder

  defp encode!(template) do
    {:ok, ast} =
      JsonEncoder.encode(template, fn heex -> LiveViewCompiler.render_template(heex, %{}) end)

    ast
  end

  test "a renderable component keeps its rendered_html preview" do
    ast = encode!(~s|<div><.icon name="hero-x-mark" /></div>|)

    assert [%{"tag" => "div", "content" => [icon]}] = ast
    assert is_binary(icon["rendered_html"])
    assert icon["rendered_html"] =~ "hero-x-mark"
  end

  test "a component the application does not define is kept without a preview" do
    ast = encode!(~s|<div><.no_such_component_anywhere /></div>|)

    assert [%{"tag" => "div", "content" => [unknown]}] = ast
    refute Map.has_key?(unknown, "rendered_html")
  end
end
