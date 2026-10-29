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

  # ONE BUILD PER EDIT, AND IT IS THE ROW'S. Saving the sheet queues the site's CSS rebuild, which
  # builds and stores the CSS (`MishkaCmsCore.Runtime.PageBuilder.TokensTest`). The event used to run
  # a second Tailwind build of its own, keep nothing of it, and make the author wait for it.
  test "runs no Tailwind build while the author waits", %{view: view, site: site} do
    test_pid = self()
    handler = "token-set-build-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:mishka_cms, :runtime, :compilers, :tailwind, :start],
        fn _event, _measurements, meta, _config -> send(test_pid, {:tailwind, meta[:site]}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    render_click(view, "set_token", %{"key" => @key, "value" => "#123456"})

    assert value_of(site.id, @key) == "#123456"
    refute_received {:tailwind, _site}, "the Studio built the site's CSS and threw it away"
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
