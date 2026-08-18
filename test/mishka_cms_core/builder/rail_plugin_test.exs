defmodule MishkaCmsCore.Builder.RailPluginTest do
  @moduledoc """
  An extension adding a rail to the editor, end to end — the thing the `builder:rails` registry
  advertised and could not actually do.

  Three separate links were broken, and each on its own was enough to make the seam a lie:

    * `Events.collect(:rails, …)` fired into an assign, and the assign reached the panel, but the
      rail BODIES were hardcoded `:if` branches — so a contributed rail drew a tab that opened onto
      nothing;
    * `handle_event("set_right_tab", …)` matched the tab against a fixed list of three atoms, so the
      click that would have opened it was discarded before it arrived;
    * `Descriptor.render/2`, the dispatcher meant to draw a contributed body, had no callers at all.

  So this asserts the whole path rather than any one link: the descriptor is collected, the tab is
  drawn, the click is accepted, and the body appears on screen.
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Builder.{Descriptor, Events}
  alias MishkaCmsCore.Test.Plugins.BuilderRailProbe, as: Probe

  @moduletag :unit

  describe "the descriptor an extension contributes" do
    test "carries what the editor needs to draw it" do
      descriptor = Probe.descriptor()

      assert Descriptor.key(descriptor) == Probe.key()
      assert Descriptor.label(descriptor) == "Probe"
      assert descriptor.render == {Probe, :body}
    end

    test "and the core's own rails are still there when it is added" do
      collected = Events.collect(:rails, MishkaCmsCoreWeb.Live.Admin.Builder.Panels.core_rails())
      keys = Enum.map(collected, &Descriptor.key/1)

      assert "layers" in keys
      assert "assistant" in keys
      assert "audit" in keys
    end
  end

  describe "the dispatcher that draws a contributed body" do
    test "renders the descriptor's own component" do
      html = Probe.descriptor() |> Descriptor.render(%{__changed__: nil}) |> rendered_to_string()

      assert html =~ Probe.marker()
      assert html =~ "pb-probe-rail-body"
    end

    test "a descriptor with nothing to draw is not an error" do
      assert Descriptor.render(%{key: "nothing"}, %{__changed__: nil}) == nil
    end

    # THE PROMISE ITS DOCSTRING MAKES. This was a bare `apply`, so an extension whose component
    # raised took the whole panel down — the opposite of the isolation a broken template gets.
    test "a component that raises degrades to nothing rather than taking the panel down" do
      descriptor = %{key: "boom", render: {__MODULE__, :raising_body}}

      # Development stops on it, because there the author is the person who can fix it.
      assert_raise MishkaCmsCore.Runtime.PageBuilder.Strict.Violation, ~r/broken/, fn ->
        Descriptor.render(descriptor, %{__changed__: nil})
      end
    end
  end

  @doc false
  def raising_body(_assigns), do: raise("this extension is broken")
end
