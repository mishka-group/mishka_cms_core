# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.PageMessageCompileTest do
  @moduledoc """
  What a page gains when something on it says something.

  Checked against the AST the compiler really emits, for the same reason the form compile test is: a
  generated clause has to sit before the catch-all or it never runs, and there must be no second
  clause for a name the author already declared, or the author's clause is unreachable.

  The other half is the region. A flash nothing renders is a button that does nothing, which is the
  exact silence the region was added for — so a page that only SAYS something gets one too, not just
  one that carries a form.
  """
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.Compilers.ModuleCompiler
  alias MishkaCmsCore.Runtime.Authoring.Interactions

  @moduletag :unit

  @says ~s|<section><button class="pb-7f3a91b2" phx-click={#{Interactions.source("say", "pb-7f3a91b2", %{kind: "info", message: "Saved!"})}}>Go</button></section>|

  @silent ~s|<section><button class="pb-7f3a91b2" phx-click={JS.toggle_class("is-open", to: ".pb-7f3a91b2")}>Go</button></section>|

  defp build(template, events) do
    module = :"Elixir.PageMessageCompilePage#{System.unique_integer([:positive])}"

    ast =
      LiveViewCompiler.build_module(%{
        title: "Says",
        page_module: module,
        template: template,
        events: events
      })

    {module, ast}
  end

  defp compiled(template, events \\ []) do
    {module, ast} = build(template, events)
    {:ok, ^module, _diagnostics} = ModuleCompiler.compile_module(ast)
    {module, ast}
  end

  defp clauses(ast) do
    {_ast, names} =
      Macro.prewalk(ast, [], fn
        {:def, _meta, [{:handle_event, _head, [matched | _rest]} | _body]} = node, acc ->
          {node, [name_of(matched) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(names)
  end

  defp name_of(matched) when is_binary(matched), do: matched
  defp name_of(_variable), do: :catch_all

  defp socket, do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

  describe "the generated clause" do
    test "a page that says something answers the push" do
      {module, _ast} = compiled(@says)

      assert {:noreply, said} =
               module.handle_event("pb:say", %{"kind" => "info", "message" => "Saved!"}, socket())

      assert said.assigns.flash == %{"info" => "Saved!"}
    end

    test "and it sits before the catch-all, or it would never run" do
      {_module, ast} = build(@says, [])

      names = clauses(ast)

      assert "pb:say" in names

      assert Enum.find_index(names, &(&1 == "pb:say")) <
               Enum.find_index(names, &(&1 == :catch_all))
    end

    # THE ONE THE GATE USED TO GET WRONG. An author who puts the button inside a COMPONENT saves the
    # push in the COMPONENT's markup; the page that uses it says only `<.component …>`, so a gate
    # that looked for the event in the page's own template found nothing and compiled no clause. The
    # card rendered, the button rendered, the click was swallowed by the catch-all.
    test "a page whose own markup says nothing still answers, because the click may come from a component" do
      {module, _ast} = compiled(@silent)

      assert {:noreply, said} =
               module.handle_event(
                 "pb:say",
                 %{"kind" => "info", "message" => "From a card"},
                 socket()
               )

      assert said.assigns.flash == %{"info" => "From a card"}
    end

    # The same rule a form's generated clause follows: the author's own answer is the more specific
    # one, and a second clause for a name theirs already matches is unreachable code in a live page.
    test "an author who declares the event keeps their own clause" do
      {_module, ast} =
        build(@says, [%{name: "pb:say", handler: "{:noreply, socket}", args: "", code: ""}])

      assert Enum.count(clauses(ast), &(&1 == "pb:say")) == 1
    end
  end

  describe "somewhere to say it" do
    # A FLASH NOTHING RENDERS IS A BUTTON THAT DOES NOTHING, which is the silence this region exists
    # to end — and for the same reason the clause is now unconditional, so is the region: a message
    # can come from a button in a component, and the page's own markup shows no sign of it.
    test "every page carries the region" do
      assert LiveViewCompiler.confirmable(@says) =~ "page-form-announcements"
      assert LiveViewCompiler.confirmable(@silent) =~ "page-form-announcements"
    end

    # AND COSTS A PAGE WITH NOTHING TO SAY NOTHING AT ALL: the whole block is behind an `:if` on the
    # flash, so it renders no markup until there is a message.
    test "and renders none of it until there is something to say" do
      assert LiveViewCompiler.confirmable(@silent) =~
               ":if={MishkaCmsCore.Runtime.PageForm.announcements(@flash) != []}"
    end

    test "a page with no template has nothing to say" do
      assert LiveViewCompiler.confirmable(nil) == nil
    end

    # AND A LAYOUT THAT ALREADY SHOWS MESSAGES IS THE BETTER PLACE FOR THEM, because it is where that
    # site styled them. Watched on a real page before this: the click flashed, and the visitor was
    # told the same thing twice — once by this region and once by the layout's own flash group.
    test "but not when something above the page already shows them" do
      assert LiveViewCompiler.confirmable(@says, nil, true) == @says
      assert LiveViewCompiler.confirmable(@silent, nil, true) == @silent
    end

    # READ OFF THE PARSED LAYOUT, and every case below is one the old check got WRONG. It was
    # `String.contains?(template, "@flash")`, so a layout that only TALKED about the assign counted
    # as one that renders it — and the page then dropped its own region and the visitor was told
    # nothing at all. There is no spelling of a text check that tells these apart.
    test "and a layout only counts when an expression of its own reads the assign" do
      renders = [
        ~S|<main><.flash_group flash={@flash} />{@inner_content}</main>|,
        ~S|<main><%= if @flash != %{} do %><p>hi</p><% end %>{@inner_content}</main>|
      ]

      mentions = [
        ~S|<main><!-- add <.flash_group flash={@flash} /> here --><p>x</p></main>|,
        ~S|<main><pre phx-no-curly-interpolation>&lt;.flash_group flash={@flash} /&gt;</pre></main>|,
        ~S|<main><p>Write @flash in your layout to show messages.</p></main>|,
        ~S|<main><p title="@flash">x</p></main>|
      ]

      for template <- renders do
        assert LiveViewCompiler.shows_messages?(%{template: template}),
               "#{template} renders messages and was read as not doing so"
      end

      for template <- mentions do
        refute LiveViewCompiler.shows_messages?(%{template: template}),
               "#{template} only mentions the assign, and the page would have gone silent"
      end
    end

    # NO LAYOUT IS `Layouts.app`, which carries a flash group of its own.
    test "a page with no layout of its own is inside one that shows them" do
      assert LiveViewCompiler.shows_messages?(nil)
    end

    # AND THE SAFE ANSWER FOR SOMETHING UNREADABLE IS THAT IT SHOWS NOTHING, so the page keeps its
    # region: being told twice is a blemish, being told nothing is the bug.
    test "and anything unreadable leaves the page its own region" do
      refute LiveViewCompiler.shows_messages?(%{template: ~S|<main><div></main>|})
      refute LiveViewCompiler.shows_messages?(%{template: nil})
      refute LiveViewCompiler.shows_messages?(%{})
    end

    test "and the region leaves on its own" do
      region = LiveViewCompiler.confirmable(@says)

      assert region =~ ~s(phx-hook="FlashAutoDismiss")
      assert region =~ "data-dismiss-after"
      assert region =~ ~s(phx-click="lv:clear-flash")
    end
  end
end
