# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.LiveView.JsonEncoderTest do
  @moduledoc """
  The builder converter turns a HEEx template into the AST-JSON the editor consumes,
  attaching a `rendered_html` preview to component/eex nodes. A node that can't be
  rendered (an unknown component, a missing assign) must still produce a
  JSON-encodable result — the node is kept, only its preview is dropped — rather
  than leaking a non-encodable `{:error, _}` tuple into the payload.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.PageBuilder.LiveView.JsonEncoder

  defp render_fun, do: fn heex -> LiveViewCompiler.render_template(heex, %{}) end

  defp encode!(template) do
    {:ok, ast} = JsonEncoder.encode(template, render_fun())
    ast
  end

  test "an unknown component is kept without a preview and stays JSON-encodable" do
    ast = encode!(~s|<div><.cp foo="bar">hi</.cp></div>|)

    assert [%{"tag" => "div", "content" => [cp]}] = ast
    assert cp["tag"] == ".cp"
    assert cp["attrs"] == %{"foo" => "bar"}
    assert cp["content"] == ["hi"]
    refute Map.has_key?(cp, "rendered_html")
    assert is_binary(Jason.encode!(ast))
  end

  test "an eex expression with a missing assign degrades gracefully (no tuple leak)" do
    ast = encode!(~s|<span><%= @missing %></span>|)
    assert is_binary(Jason.encode!(ast))
  end

  test "plain markup round-trips with its structure preserved" do
    ast = encode!(~s|<div class="a"><span>hi</span></div>|)

    assert [%{"tag" => "div", "attrs" => %{"class" => "a"}, "content" => [span]}] = ast
    assert span["tag"] == "span"
    assert span["content"] == ["hi"]
    assert is_binary(Jason.encode!(ast))
  end

  test "an eex if-block is encoded with its preview and nested ast" do
    ast = encode!(~s|<%= if true do %><span>yes</span><% end %>|)

    assert [%{"tag" => "eex_block", "arg" => "if true do"} = block] = ast
    assert block["rendered_html"] =~ "yes"
    assert is_binary(block["ast"])
    assert is_binary(Jason.encode!(ast))
  end

  test "an eex for-block renders each iteration" do
    ast = encode!(~s|<ul><%= for x <- [1, 2, 3] do %><li><%= x %></li><% end %></ul>|)

    assert [%{"tag" => "ul", "content" => [block]}] = ast
    assert block["tag"] == "eex_block"
    assert block["rendered_html"] =~ "1"
    assert block["rendered_html"] =~ "3"
    assert is_binary(Jason.encode!(ast))
  end

  test "an eex block with an unknown component keeps its ast but drops the preview" do
    ast = encode!(~s|<div><%= if true do %><.cp /><% end %></div>|)

    assert [%{"tag" => "div", "content" => [block]}] = ast
    assert block["tag"] == "eex_block"
    assert block["rendered_html"] == nil
    assert is_binary(block["ast"])
    assert is_binary(Jason.encode!(ast))
  end
end
