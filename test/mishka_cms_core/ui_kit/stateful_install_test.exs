# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.UiKit.StatefulInstallTest do
  @moduledoc """
  A kit bundle shipping a live component, installed.

  ## Why the contract's own tests are not this test

  `MishkaCmsCore.UiKit.ContractTest` proves the SHAPE gate: a bundle carrying `"stateful": true`
  passes and one carrying `"stateful": "yes"` is dropped. It says nothing about whether the flag
  survives the rest of the pipeline — `create_component/3` normalising the params,
  `accepted_only/2` filtering them against the action's accept list, and `upsert_row/2` writing the
  row. A key that every check approves and the writer then drops is exactly the shape of failure
  this whole feature keeps meeting.

  One line in `@admin_fields` is what carries it, because `accepted_inputs/1` reads the action's
  accept list rather than a list of its own. This is the assertion that keeps that true.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler, as: Installer

  require Ash.Query

  @moduletag :integration

  @kit "statefulkit"

  defp bundle_file(components) do
    path = Path.join(System.tmp_dir!(), "#{@kit}-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      Jason.encode!(%{
        "$schema" => "mishka.ui_kit.bundle.v3",
        "name" => @kit,
        "version" => "0.0.1",
        "components" => components,
        "js_hooks" => [],
        "stylesheets" => []
      })
    )

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp component(name, extra \\ %{}) do
    Map.merge(
      %{
        "name" => "#{@kit}-#{name}",
        "template" => ~s(<div id={@id} {@rest}>#{name}</div>),
        "attrs" => [%{"name" => "rest", "type" => "global", "opts" => %{}}]
      },
      extra
    )
  end

  defp row(name) do
    Component
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(name == ^"#{@kit}-#{name}")
    |> Ash.read_one!()
  end

  describe "a bundle carrying a live component" do
    test "installs it as one, and the flag survives the whole pipeline" do
      path =
        bundle_file([
          component("live", %{"stateful" => true}),
          component("plain")
        ])

      on_exit(fn -> Installer.uninstall_kit!(path) end)

      assert {:ok, _installed} = Installer.install_kit!(path)

      assert row("live").stateful == true,
             "the bundle said stateful and the row does not — a key every check approved and the writer dropped"

      assert row("plain").stateful == false
    end

    # THE SHAPE RULES REACH THE INSTALL PATH TOO, and they have to: every component in a bundle is
    # created inside ONE `Ash.transaction` where `Ash.create!` raises, so a component the resource
    # would refuse must be dropped by the contract BEFORE the transaction — or it costs every other
    # component in the kit rather than only itself.
    test "and one shaped so it cannot be live costs that component and no other" do
      path =
        bundle_file([
          component("fine"),
          component("clauses", %{
            "stateful" => true,
            "extra" => %{"clauses" => [%{"match" => "%{}"}]}
          }),
          component("reserved", %{
            "stateful" => true,
            "attrs" => [%{"name" => "socket", "type" => "any", "opts" => %{}}]
          })
        ])

      on_exit(fn -> Installer.uninstall_kit!(path) end)

      assert {:ok, _installed} = Installer.install_kit!(path)

      assert row("fine"), "the good component did not install"
      refute row("clauses"), "a live component with clauses was installed"
      refute row("reserved"), "a live component declaring :socket was installed"
    end
  end
end
