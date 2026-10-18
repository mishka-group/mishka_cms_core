# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.BuilderLive.TokenSetTest do
  @moduledoc """
  A design token set in the Studio: the `set_token` event, asked through `builder:token:before_set`
  before anything is written.

  The value a plugin returns is the value written, a plugin's refusal is shown to the author and
  writes nothing, and with no plugin the value is written as typed.
  """
  use MishkaCmsCore.BuilderLiveCase

  alias MishkaCmsCore.Runtime.PageBuilder.Tokens
  alias MishkaCmsCore.Test.Plugins.BuilderTokenGate

  @key "iris"

  defp value_of(site_id, key) do
    site_id
    |> Tokens.list()
    |> Enum.find(&(&1.key == key))
    |> case do
      nil -> nil
      token -> token.value
    end
  end

  setup %{conn: conn, page: page} do
    Application.put_env(
      :mishka_cms_core,
      :builder_marketplace,
      MishkaCmsCore.Runtime.PageBuilder.Marketplace.Mock
    )

    on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_marketplace) end)

    {:ok, _theme} =
      MishkaCmsCore.Runtime.Stylesheet
      |> Ash.Changeset.for_create(
        :master_create,
        %{
          name: "token-set-theme-#{System.unique_integer([:positive])}",
          kind: :theme,
          content: ":root {\n  --#{@key}: #5b57d6;\n}\n",
          site_id: nil,
          active: true
        },
        authorize?: false
      )
      |> Ash.create()

    %{view: open_studio(conn, page)}
  end

  test "writes the value the author typed", %{view: view, site: site} do
    render_click(view, "set_token", %{"key" => @key, "value" => "#123456"})

    assert value_of(site.id, @key) == "#123456"
    refute has_element?(view, "#flash-error")
  end

  describe "with a design-system plugin" do
    setup do: register_plugin(BuilderTokenGate, "builder:token:before_set")

    test "writes the value the plugin snapped it to", %{view: view, site: site} do
      render_click(view, "set_token", %{"key" => @key, "value" => "snap-me"})

      assert value_of(site.id, @key) == BuilderTokenGate.snapped()
    end

    test "shows a refusal and writes nothing", %{view: view, site: site} do
      before = value_of(site.id, @key)

      html =
        render_click(view, "set_token", %{"key" => @key, "value" => BuilderTokenGate.refused()})

      assert html =~ "That value is not on the scale."
      assert value_of(site.id, @key) == before
    end
  end
end
