# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Builder.ActionRegistryTest do
  @moduledoc """
  A package can add a working On-click action, and core never learns its name.

  ## What was wrong

  `builder:interactions` was a registry in the catalog and half a seam in the code. The LIST was
  open — `Events.collect_appended(:interactions, …)` has always been what the dropdown reads — and
  everything after it was shut: the writer was a private table, so any action a plugin contributed
  appeared in the menu, was picked, and wrote nothing. The code said so in its own words:
  `source/3` "answers `nil` … for an action outside its own table, which is every action an
  extension contributes to the dropdown".

  ## What is pinned here

  That a contributed action is offered, draws its own boxes, writes, reads back and — for a server
  one — compiles its handler into a page. And that what it asked for is checked: what an action
  answers goes into a document the TagEngine compiles, so a registry that takes it on trust is a
  registry that lets a package run code on every visit.
  """
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Builder.Action
  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.Authoring.Interactions
  alias MishkaCmsCore.Test.Plugins.BuilderActionPlugin
  alias MishkaCmsCore.Test.Plugins.BuilderHijackPlugin
  alias MishkaInstaller.Event.{Event, EventHandler}

  @moduletag :unit

  @scope "pb-aaaa1111"

  defp clicking(source), do: ~s(<button phx-click={) <> source <> ~s(}>Go</button>)

  describe "core's own seven, before anything is installed" do
    test "are all there, in panel order" do
      assert Enum.map(Interactions.seed(), & &1.key) ==
               ~w(say toggle_class add_class remove_class toggle show hide)
    end

    test "and every one of them names a module that can answer for it" do
      for action <- Interactions.seed() do
        module = Action.module(action)

        assert not is_nil(module), "#{action.key} names no module"
        assert Code.ensure_loaded?(module)
        assert function_exported?(module, :write, 3), "#{action.key} cannot write"
      end
    end

    # SIX CLIENT, ONE SERVER. The split is the rule the whole registry exists to keep: anything the
    # browser can do alone stays in the browser, and only what the server owns takes a round trip.
    test "and only the one that needs the server asks for it" do
      keys = Enum.map(Interactions.seed(), & &1.key)

      assert Enum.filter(keys, &Interactions.server?/1) == ["say"]
    end
  end

  describe "a plugin's actions" do
    setup do
      {:ok, _} =
        Event.write(%{
          name: BuilderActionPlugin,
          event: "builder:interactions",
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile("builder:interactions", :start, false)
      on_exit(fn -> Event.unregister(:name, BuilderActionPlugin, false) end)
      :ok
    end

    test "join the list the panel draws" do
      offered = Interactions.actions() |> Enum.map(&elem(&1, 0))

      assert "acme_scroll" in offered
      assert "acme_ping" in offered
      assert "toggle_class" in offered, "core's own were replaced rather than added to"
    end

    test "bring their own boxes, so the panel needs nothing written into it" do
      assert [%{name: "offset", label: "Offset", type: :text}] = Interactions.needs("acme_scroll")
      assert [%{name: "note", label: "Note"}] = Interactions.needs("acme_ping")
    end

    test "write a real command" do
      written = Interactions.source("acme_scroll", @scope, %{"offset" => "80"})

      assert written =~ ~s|JS.dispatch("acme:scroll"|
      assert written =~ ~s|to: ".#{@scope}"|
      assert written =~ ~s|offset: "80"|
    end

    test "and read it back, so the panel reopens on what the author chose" do
      written = Interactions.source("acme_scroll", @scope, %{"offset" => "80"})

      assert Interactions.read({:expr, written}) == {:ok, "acme_scroll", %{"offset" => "80"}}
    end

    test "aimed somewhere else, exactly as a core verb is" do
      written =
        Interactions.source("acme_scroll", @scope, %{"offset" => "0", target: "pb-bbbb2222"})

      assert Interactions.target({:expr, written}) == "pb-bbbb2222"
    end

    # THE VALUES COME BACK FROM A BROWSER. An action's own boxes are posted by the panel's form, so
    # everything in them is client-sent, and they end up inside an expression a page compiles. They
    # survive it verbatim because nobody spells the expression: see `MishkaCmsCore.Builder.Command`.
    test "and an author's words cannot become code" do
      said = "80" <> <<35>> <> "{File.rm_rf!(\"/tmp/x\")}"
      written = Interactions.source("acme_scroll", @scope, %{"offset" => said})

      assert {:ok, _ast} = Code.string_to_quoted(written)
      assert Interactions.read({:expr, written}) == {:ok, "acme_scroll", %{"offset" => said}}
    end
  end

  describe "a plugin's server action" do
    setup do
      {:ok, _} =
        Event.write(%{
          name: BuilderActionPlugin,
          event: "builder:interactions",
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile("builder:interactions", :start, false)
      on_exit(fn -> Event.unregister(:name, BuilderActionPlugin, false) end)
      :ok
    end

    test "says it reaches the server, and names what answers it" do
      assert Interactions.server?("acme_ping")

      assert %{event: "acme:ping", handler: {_module, :run}} =
               Enum.find(Interactions.server_actions(), &(&1.key == "acme_ping"))
    end

    # THE WHOLE POINT, END TO END. The compiler asks the registry rather than a name it holds, so a
    # page using a package's action gets that package's handler compiled into it.
    test "compiles its own handler into a page that uses it" do
      template = clicking(Interactions.source("acme_ping", @scope, %{"note" => "hi"}))

      module = :"Elixir.ActionRegistryPage#{System.unique_integer([:positive])}"

      ast =
        LiveViewCompiler.build_module(%{
          title: "Ping",
          page_module: module,
          template: template,
          events: []
        })

      assert {:ok, ^module, _diagnostics} =
               MishkaCmsCore.Runtime.Compilers.ModuleCompiler.compile_module(ast)

      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

      assert {:noreply, answered} = module.handle_event("acme:ping", %{"note" => "hi"}, socket)
      assert answered.assigns.acme_ping == "hi"
    end

    # AND ON A PAGE WHOSE MARKUP SAYS NOTHING OF IT, because the click may come from a component the
    # page only names — see `LiveViewCompiler.build_page_messages/1`. The clause is three lines of
    # bytecode that nothing pushes; the alternative was a button that silently did nothing.
    test "and on a page whose own markup never mentions it" do
      template = clicking(Interactions.source("show", @scope, %{}))
      module = :"Elixir.ActionRegistryQuiet#{System.unique_integer([:positive])}"

      ast =
        LiveViewCompiler.build_module(%{
          title: "Quiet",
          page_module: module,
          template: template,
          events: []
        })

      assert {:ok, ^module, _diagnostics} =
               MishkaCmsCore.Runtime.Compilers.ModuleCompiler.compile_module(ast)

      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

      assert {:noreply, answered} = module.handle_event("acme:ping", %{"note" => "hi"}, socket)
      assert answered.assigns.acme_ping == "hi"
    end

    # AND AN ACTION THAT IS NOT INSTALLED IS NOT COMPILED. The list is the registry's, so uninstalling
    # a package takes its clause out of the next compile.
    test "but nothing is compiled for an action nobody registered" do
      ast =
        LiveViewCompiler.build_module(%{
          title: "Quiet",
          page_module: :"Elixir.ActionRegistryUnknown#{System.unique_integer([:positive])}",
          template: clicking(Interactions.source("show", @scope, %{})),
          events: []
        })

      refute Macro.to_string(ast) =~ "acme:never-registered"
    end
  end

  # THE ONE THAT WOULD BE INVISIBLE. An action's descriptor carries the module a PUBLISHED PAGE calls,
  # so taking a core key is not a cosmetic collision — it is a plugin's module compiled into the
  # `handle_event` of every page an author already built with core's own verb, reading params straight
  # from a visitor's browser. Neither of these needed an admin to pick anything.
  describe "a contribution reaching for something that is core's" do
    setup do
      {:ok, _} =
        Event.write(%{
          name: BuilderHijackPlugin,
          event: "builder:interactions",
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile("builder:interactions", :start, false)
      on_exit(fn -> Event.unregister(:name, BuilderHijackPlugin, false) end)
      :ok
    end

    test "cannot take a core key, however it orders its answer" do
      say = Enum.find(Interactions.registry(), &(Action.key(&1) == "say"))

      assert Action.module(say) == MishkaCmsCore.Builder.Actions.Say,
             "a plugin returning its entries ahead of the seed replaced core's Show a message"
    end

    test "and the page still calls core's handler for core's event" do
      assert %{handler: {MishkaCmsCore.Runtime.PageMessage, :say}} =
               Enum.find(Interactions.server_actions(), &(&1.event == "pb:say"))
    end

    # ONE CLAUSE PER EVENT, or the second is unreachable code in somebody's published page — and
    # which of the two is unreachable would be decided by registry order.
    test "cannot answer an event that is already answered" do
      answering = Enum.filter(Interactions.server_actions(), &(&1.event == "pb:say"))

      assert length(answering) == 1
      assert hd(answering).key == "say"
    end

    test "so nothing of the plugin's reaches a page built with core's verb" do
      template =
        clicking(Interactions.source("say", @scope, %{"kind" => "info", "message" => "hi"}))

      ast =
        LiveViewCompiler.build_module(%{
          title: "Says",
          page_module: :"Elixir.ActionRegistryHijack#{System.unique_integer([:positive])}",
          template: template,
          events: []
        })

      source = Macro.to_string(ast)

      assert source =~ "MishkaCmsCore.Runtime.PageMessage.say"
      refute source =~ "HijackAction"
    end
  end

  describe "what a contribution is not trusted with" do
    setup do
      {:ok, _} =
        Event.write(%{
          name: BuilderActionPlugin,
          event: "builder:interactions",
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile("builder:interactions", :start, false)
      on_exit(fn -> Event.unregister(:name, BuilderActionPlugin, false) end)
      :ok
    end

    # A DOCUMENT IS COMPILED. Whatever goes into `phx-click` is Elixir the TagEngine will evaluate on
    # every render, and the only names that can get there are ones `Phoenix.LiveView.JS` answers to —
    # an action asking for anything else is applied to `JS`, raises there, and writes nothing.
    test "naming a function that is not a JS command" do
      assert Interactions.source("acme_rogue", @scope, %{}) == nil
    end

    # THE EVERYDAY VERSION OF THE SAME MISTAKE, and the one a package will actually make. No list of
    # legal options is kept here: the command is asked, and its own answer is what refuses this.
    test "or asking a real command for an option it does not take" do
      assert Interactions.source("acme_mistaken", @scope, %{}) == nil
    end

    test "and the log says which action and what LiveView said about it" do
      said =
        ExUnit.CaptureLog.capture_log(fn ->
          Interactions.source("acme_mistaken", @scope, %{})
        end)

      assert said =~ "acme_mistaken"
      assert said =~ "Expected keys to be one of"
    end
  end
end
