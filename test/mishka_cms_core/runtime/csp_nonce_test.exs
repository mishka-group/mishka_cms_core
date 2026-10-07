defmodule MishkaCmsCore.Runtime.CspNonceTest do
  @moduledoc """
  The nonce a response's header names has to reach every template that response renders — the
  LiveView's own, a database page's, a layout's and a component's, which never sees the page's
  assigns. These pin each hop.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Compilers.ComponentCompiler
  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.CspNonce
  alias MishkaCmsCore.Runtime.LiveViewHelpers

  setup do
    on_exit(fn -> CspNonce.put(nil) end)
    :ok
  end

  describe "the live_session hand-off" do
    test "signs this response's nonce into the LiveView session" do
      conn = Plug.Conn.assign(Plug.Test.conn(:get, "/"), :csp_nonce, "abc123")

      assert CspNonce.session(conn) == %{"csp_nonce" => "abc123"}
    end

    test "signs nothing where the plug never ran" do
      assert CspNonce.session(Plug.Test.conn(:get, "/")) == %{}
    end

    test "the mount assigns it and records it for the process" do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

      assert {:cont, socket} = CspNonce.on_mount(:default, %{}, %{"csp_nonce" => "n0nce"}, socket)
      assert socket.assigns.csp_nonce == "n0nce"
      assert CspNonce.current() == "n0nce"
    end

    test "a mount with no nonce leaves none behind from an earlier render" do
      :ok = CspNonce.put("stale")
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

      assert {:cont, socket} = CspNonce.on_mount(:default, %{}, %{}, socket)
      assert socket.assigns.csp_nonce == nil
      assert CspNonce.current() == nil
    end
  end

  describe "csp_nonce/0 in a runtime template" do
    test "is imported, unless the template's own helpers define one" do
      assert {:csp_nonce, 0} in LiveViewHelpers.imports(nil)
      refute {:csp_nonce, 0} in LiveViewHelpers.imports([%{name: "csp_nonce", args: ""}])
    end

    test "a database page renders the response's nonce" do
      module = Module.concat(__MODULE__, "Page#{System.unique_integer([:positive])}")

      %{
        title: "nonce",
        path: "/nonce",
        site: "site",
        page_module: module,
        template: ~S|<style nonce={csp_nonce()}>.x { color: red; }</style>|,
        events: [],
        infos: [],
        helpers: []
      }
      |> LiveViewCompiler.build_assigns()
      |> LiveViewCompiler.build_page_forms()
      |> LiveViewCompiler.build_event_handlers()
      |> LiveViewCompiler.build_info_handlers()
      |> LiveViewCompiler.build_renders()
      |> LiveViewCompiler.build_helpers()
      |> LiveViewCompiler.create_module_ast()
      |> Code.compile_quoted()

      :ok = CspNonce.put("page-nonce")

      assert render(module.render(%{__changed__: nil, flash: %{}})) =~
               ~s(<style nonce="page-nonce">)
    end

    test "a component renders it too, though it never sees the page's assigns" do
      module = Module.concat(__MODULE__, "Component#{System.unique_integer([:positive])}")

      %{
        id: nil,
        title: "nonced",
        component_module: module,
        site: nil,
        site_id: nil,
        host: nil,
        template: ~S|<style nonce={csp_nonce()}>.y { color: blue; }</style>|,
        priority: 0,
        format: :heex,
        timestamp: nil,
        attrs: [],
        slots: [],
        helpers: [],
        permissions: [],
        body: nil,
        stateful: false,
        extra: %{},
        prelude: nil,
        module_attributes: [],
        clauses: []
      }
      |> ComponentCompiler.build_component_information()
      |> ComponentCompiler.build_module_attributes()
      |> ComponentCompiler.build_attributes()
      |> ComponentCompiler.build_slots()
      |> ComponentCompiler.build_component_function()
      |> ComponentCompiler.build_helpers()
      |> ComponentCompiler.build_event_fallback()
      |> ComponentCompiler.create_module_ast()
      |> Code.compile_quoted()

      :ok = CspNonce.put("component-nonce")

      assert render(apply(module, :nonced, [%{__changed__: nil}])) =~
               ~s(<style nonce="component-nonce">)
    end

    test "renders no attribute outside a response" do
      :ok = CspNonce.put(nil)

      assert LiveViewHelpers.csp_nonce() == nil
    end
  end

  defp render(rendered), do: rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
end
