# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.OpenCommandTest do
  @moduledoc """
  A component says how it is opened, and a click aimed at it runs that.

  ## What was wrong

  "Show" pointed at a dialog compiled to `JS.show(to: ".pb-xxxxxxxx")`. That sets `display` on the
  one element carrying the class and does nothing else — and the kit's modal is `hidden` on its ROOT
  and `hidden` again on the panel a level down, with the backdrop in between carrying no `hidden` at
  all. Revealing the root therefore painted a full-page backdrop over the page and showed no dialog:
  measured on a real page, root `display: block`, backdrop 720px tall, dialog `display: none`,
  height 0.

  For most of the others it was worse than half-right — it was nothing. A drawer is fully displayed
  and held off-screen by `-translate-x-full`; a dropdown, an accordion and a collapse are opened by
  a JavaScript hook; a navbar wants a class toggled on the very element the click already points at.
  Their roots were never `display:none`, and LiveView's `show` returns early on an element that is
  already visible.

  ## The shape of the answer

  Not a longer list of special cases in the editor — the editor cannot know, and the next kit will
  be different again. The component declares its own command as an attribute on its root, and the
  click executes it:

      <div id={@id} data-pb-open={show_modal(@id)} data-pb-close={hide_modal(@id)}>

      <button phx-click={JS.exec("data-pb-open", to: ".pb-xxxxxxxx")}>

  The kit invented this before we did: `chelekom-mega-menu` already carries `phx-open-mega` on its
  root and runs it from its own trigger with `JS.exec/2`. This gives that pattern a name the builder
  knows, and leaves every component that declares nothing exactly as it was.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Authoring.Interactions

  @moduletag :unit

  describe "what the click compiles to" do
    test "a declared verb runs the component's own command" do
      opener = %{"show" => "data-pb-open", "hide" => "data-pb-close"}

      assert Interactions.source("show", "pb-aaaa1111", %{target: "pb-bbbb2222", opener: opener}) ==
               ~s|JS.exec("data-pb-open", to: ".pb-bbbb2222")|

      assert Interactions.source("hide", "pb-aaaa1111", %{target: "pb-bbbb2222", opener: opener}) ==
               ~s|JS.exec("data-pb-close", to: ".pb-bbbb2222")|
    end

    # A COMPONENT DECLARING "OPEN" HAS NOT DECLARED "TOGGLE", and the plain verb is not a safe
    # substitute: `JS.toggle` on a dialog reveals its root, which paints a `fixed inset-0` backdrop
    # over the page and leaves the dialog hidden a level down. Refused — see the describe below.
    test "a verb the component did not declare is refused, not substituted" do
      refute Interactions.source("toggle", "pb-aaaa1111", %{
               target: "pb-bbbb2222",
               opener: %{
                 "show" => "data-pb-open"
               }
             })
    end

    test "a component that declares nothing compiles exactly as it did before" do
      assert Interactions.source("show", "pb-aaaa1111", %{target: "pb-bbbb2222", opener: %{}}) ==
               ~s|JS.show(to: ".pb-bbbb2222")|

      assert Interactions.source("show", "pb-aaaa1111", %{target: "pb-bbbb2222"}) ==
               ~s|JS.show(to: ".pb-bbbb2222")|
    end

    test "an action carrying a class is class work, not opening work" do
      opener = %{"show" => "data-pb-open", "toggle" => "data-pb-toggle"}

      assert Interactions.source("toggle_class", "pb-aaaa1111", %{
               class: "is-open",
               target: "pb-bbbb2222",
               opener: opener
             }) ==
               ~s|JS.toggle_class("is-open", to: ".pb-bbbb2222")|
    end

    # THE MAP ARRIVES FROM SOMEBODY ELSE'S MARKUP and is about to be written into generated source.
    # A verb answers only with the attribute this module names for it — and a component that
    # declared SOMETHING has still said it does not open the ordinary way, so the plain verb is not
    # the answer either. Nothing is written.
    test "an attribute this editor did not name is refused" do
      refute Interactions.source("show", "pb-aaaa1111", %{
               target: "pb-bbbb2222",
               opener: %{"show" => "onclick"}
             })
    end
  end

  # THE VERB LIST IS PART OF THE CONTRACT. A verb the target cannot honour does not fail quietly — it
  # writes a command that runs and does the wrong visible thing, which is how "Show or hide" aimed at
  # a dialog put a full-page backdrop over a page with no dialog under it.
  describe "which verbs a target is offered" do
    test "a component that declares open and close is not offered a toggle" do
      offered = Interactions.actions(%{"show" => "data-pb-open", "hide" => "data-pb-close"})
      verbs = Enum.map(offered, &elem(&1, 0))

      assert "show" in verbs
      assert "hide" in verbs
      refute "toggle" in verbs
    end

    test "a component that declares only a toggle is not offered show or hide" do
      verbs =
        %{"toggle" => "data-pb-toggle"} |> Interactions.actions() |> Enum.map(&elem(&1, 0))

      assert "toggle" in verbs
      refute "show" in verbs
      refute "hide" in verbs
    end

    test "the class actions are offered whatever the target is" do
      for opener <- [%{}, %{"show" => "data-pb-open"}, %{"toggle" => "data-pb-toggle"}] do
        verbs = opener |> Interactions.actions() |> Enum.map(&elem(&1, 0))

        assert "toggle_class" in verbs
        assert "add_class" in verbs
        assert "remove_class" in verbs
      end
    end

    test "a target that declares nothing is offered every one, exactly as before" do
      assert Interactions.actions(%{}) == Interactions.actions()
      assert length(Interactions.actions()) == 7
    end

    # THE BACKSTOP. The panel does not offer the verb, but a form rendered before it knew the target
    # can still post one, and falling through to the plain command is the bug this exists to stop.
    test "and a verb it cannot honour is refused rather than guessed at" do
      opener = %{"show" => "data-pb-open", "hide" => "data-pb-close"}

      refute Interactions.source("toggle", "pb-aaaa1111", %{target: "pb-bbbb2222", opener: opener})

      assert Interactions.source("show", "pb-aaaa1111", %{target: "pb-bbbb2222", opener: opener}) ==
               ~s|JS.exec("data-pb-open", to: ".pb-bbbb2222")|
    end

    test "a target that declares nothing still gets the plain verb" do
      assert Interactions.source("toggle", "pb-aaaa1111", %{target: "pb-bbbb2222", opener: %{}}) ==
               ~s|JS.toggle(to: ".pb-bbbb2222")|
    end
  end

  describe "reading it back" do
    test "the panel sees the verb the author picked, not hand-written code" do
      written = {:expr, ~s|JS.exec("data-pb-open", to: ".pb-bbbb2222")|}

      assert Interactions.read(written) == {:ok, "show", %{}}
      assert Interactions.target(written) == "pb-bbbb2222"
    end

    test "close reads back as hide, and toggle as toggle" do
      assert Interactions.read({:expr, ~s|JS.exec("data-pb-close", to: ".pb-x")|}) ==
               {:ok, "hide", %{}}

      assert Interactions.read({:expr, ~s|JS.exec("data-pb-toggle", to: ".pb-x")|}) ==
               {:ok, "toggle", %{}}
    end

    # SOMEBODY ELSE'S `JS.exec` IS STILL SOMEBODY ELSE'S. The kit's own dialogs carry
    # `phx-click={JS.exec("data-cancel", to: "#id")}` on their close button; reading that as one of
    # these six verbs would offer to rewrite a command this editor did not write.
    test "an exec of anything else is left alone as custom" do
      assert Interactions.read({:expr, ~s|JS.exec("data-cancel", to: "#modal")|}) == :custom
      assert Interactions.read({:expr, ~s|JS.exec("phx-remove", to: ".pb-x")|}) == :custom
    end

    test "a full round trip through source and back" do
      opener = %{"show" => "data-pb-open"}

      source =
        Interactions.source("show", "pb-aaaa1111", %{target: "pb-bbbb2222", opener: opener})

      assert Interactions.read({:expr, source}) == {:ok, "show", %{}}
      assert Interactions.target({:expr, source}) == "pb-bbbb2222"
    end
  end

  # THE KIT ITSELF, because a contract nothing ships against is a contract that has never run. These
  # read the JSON the installer seeds from rather than a fixture, so a template edit that drops the
  # declaration fails here rather than in somebody's page.
  describe "the components that ship a declaration" do
    setup do
      path =
        MishkaCmsCore.Runtime.Handlers.UiKitHandler.default_bundle_path()

      kit =
        case File.read(path) do
          {:ok, raw} -> Jason.decode!(raw)
          {:error, _missing} -> %{"components" => []}
        end

      {:ok, by_name: Map.new(kit["components"] || [], &{&1["name"], &1})}
    end

    # The exporter stamps the kit's prefix onto a hook name on the way out — `Floating` in the
    # component's own source is the row `chelekom-floating`, which `format_hook_name/2` rebuilds as
    # `GlobalChelekomFloating` — so this reads the shipped name.
    test "the hooks that answer are the ones those components mount", %{by_name: by_name} do
      for name <- ~w(chelekom-dropdown chelekom-popover chelekom-tooltip) do
        assert Map.fetch!(by_name, name)["template"] =~ ~s(phx-hook="GlobalChelekomFloating")
      end

      for name <- ~w(chelekom-accordion chelekom-collapse) do
        assert Map.fetch!(by_name, name)["template"] =~ ~s(phx-hook="GlobalChelekomCollapsible")
      end
    end
  end
end
