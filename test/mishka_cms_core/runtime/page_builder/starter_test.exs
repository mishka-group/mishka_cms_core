# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.StarterTest do
  @moduledoc """
  What a component says the moment it is dropped.

  The bug: dragging `chelekom-banner` onto the canvas placed a component with nothing inside it, so
  the author saw a blank strip and had to open the inspector to find out what they had placed. A
  page builder is supposed to answer that by showing you the thing.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.Starter

  @kits_dir MishkaCmsCore.Runtime.Handlers.UiKitHandler.kits_dir()

  setup_all do
    components =
      @kits_dir
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path |> File.read!() |> Jason.decode!() |> Map.get("components", [])
      end)

    {:ok, components: components}
  end

  defp entry(name, slots \\ [%{"name" => "inner_block", "opts" => %{}}]),
    do: %{name: name, slots: slots, attrs: []}

  describe "body/1" do
    test "a container arrives with something in it" do
      refute Starter.body(entry("chelekom-banner")) == ""
      refute Starter.body(entry("chelekom-card")) == ""
    end

    test "the copy suits the component rather than being one generic line" do
      assert Starter.body(entry("chelekom-alert")) =~ "Heads up"
      assert Starter.body(entry("chelekom-button")) == "Get started"
      assert Starter.body(entry("chelekom-badge")) == "New"
    end

    # `chelekom-card-title` must not pick up `chelekom-card-content`'s copy, and neither may claim
    # the other's — the match runs over whole words, in order.
    test "a longer name wins over a shorter one that is a prefix of it" do
      assert Starter.body(entry("chelekom-card-title")) =~ "heading"
      assert Starter.body(entry("chelekom-card-content")) =~ "sentence"
    end

    # A spinner has nothing to say, and a component with no `inner_block` has nowhere to put it —
    # Phoenix refuses a slot the component never declared.
    test "a component with no inner block is left alone" do
      assert Starter.body(entry("chelekom-alert", [])) == ""
      assert Starter.body(entry("chelekom-tel-field", [%{"name" => "start_section"}])) == ""
    end

    test "a component whose shape IS the content gets none" do
      assert Starter.body(entry("chelekom-spinner")) == ""
      assert Starter.body(entry("chelekom-progress")) == ""
    end

    # A kit this install has never seen still gets a usable line rather than an empty box.
    test "an unknown component still arrives furnished" do
      assert Starter.body(entry("acme-mystery-widget")) == "Your content here"
    end

    # The prefix is the vendor's, not the meaning: another kit shipping its own alert gets the same
    # treatment without an entry of its own.
    test "the vendor prefix is not what is matched" do
      assert Starter.body(entry("acme-alert")) == Starter.body(entry("chelekom-alert"))
    end
  end

  describe "slot_samples/1" do
    # An accordion's sections are `<:item>` entries, not text between its tags — so a component that
    # says nothing inline is still furnished, and giving it BOTH would render the line loose above the
    # sections.
    test "a component whose content is a list of things gets entries instead of a line" do
      entry = entry("chelekom-accordion", [%{"name" => "item", "opts" => %{}}])

      assert [{"item", %{"title" => _}, _body} | _rest] = Starter.slot_samples(entry)
      assert Starter.body(entry) == ""
      assert Starter.furnished?(entry)
    end

    test "a slot the component never declared is not written" do
      assert Starter.slot_samples(entry("chelekom-card")) == []
    end

    # `<:header>` means the columns on a table and the title bar on a drawer, so the sample is keyed
    # by the component rather than by the slot name alone.
    test "a table gets column headings AND rows; a drawer gets neither" do
      table = entry("chelekom-table", [%{"name" => "header"}, %{"name" => "inner_block"}])
      drawer = entry("chelekom-drawer", [%{"name" => "header"}, %{"name" => "inner_block"}])

      assert Starter.slot_samples(table) == [{"header", %{}, "Name"}, {"header", %{}, "Status"}]
      assert Starter.body(table) =~ "<tr>"

      assert Starter.slot_samples(drawer) == []
      assert Starter.body(drawer) == "Put anything in here."
    end
  end

  # The point of the whole module: this CMS does not know what a third party's components mean, so a
  # package that wants a particular drop says so instead of being guessed at. Inference is the
  # fallback, not the contract.
  describe "a component that declares its own furnishing" do
    defp declaring(name, furnishing, slots \\ [%{"name" => "inner_block", "opts" => %{}}]) do
      %{name: name, slots: slots, attrs: [], furnishing: furnishing}
    end

    test "its own copy wins over anything inferred from the name" do
      entry = declaring("chelekom-alert", %{"body" => "Your deploy finished."})

      assert Starter.body(entry) == "Your deploy finished."
    end

    # The one answer inference cannot express. Left to the name table, `acme-alert` would be given
    # "Heads up …" forever.
    test "declaring an empty body means empty" do
      assert Starter.body(declaring("acme-alert", %{"body" => "", "slots" => [%{"name" => "x"}]})) ==
               ""
    end

    test "declared slots are used verbatim, attributes and all" do
      entry =
        declaring("acme-picker", %{
          "slots" => [%{"name" => "choice", "body" => "Yes", "attrs" => %{"value" => "y"}}]
        })

      assert Starter.slot_samples(entry) == [{"choice", %{"value" => "y"}, "Yes"}]
    end

    # A furnishing arrives inside a kit's `extra`, so it is exactly as trustworthy as the bundle.
    test "a malformed declaration costs the furnishing, not the drop" do
      for junk <- [%{"slots" => "not a list"}, %{"body" => %{}}, "nonsense", []] do
        assert Starter.body(declaring("chelekom-alert", junk)) =~ "Heads up"
      end
    end

    test "one bad slot entry does not discard the good ones" do
      entry =
        declaring("acme-picker", %{
          "slots" => [%{"body" => "no name"}, %{"name" => "choice", "body" => "Yes"}]
        })

      assert Starter.slot_samples(entry) == [{"choice", %{}, "Yes"}]
    end

    test "declaring nothing at all leaves the inference alone" do
      assert Starter.body(declaring("chelekom-alert", %{})) =~ "Heads up"
      assert Starter.body(declaring("chelekom-alert", nil)) =~ "Heads up"
    end

    # DECLARED EMPTY IS NOT DECLARED NOTHING. `chelekom-gallery-media` wants to arrive with nothing
    # inside, because the editor already draws a dashed well for a picture nobody has chosen — and
    # the grey box the furnishing used to supply sat on top of that well and ate the click meant for
    # it. Read as absent, an empty body handed the inference back its starter line.
    test "declaring an empty body is a declaration, not an absence" do
      entry = declaring("chelekom-alert", %{"body" => ""})

      assert Starter.body(entry) == ""
      refute Starter.body(entry) =~ "Heads up"
    end
  end

  # A BODY SAYS WHAT GOES INSIDE; THIS SAYS WHAT THE THING IS. `chelekom-gallery` is a grid whose
  # column count and gap both default to the empty string, so a plain drag put four pictures in a
  # one-column, gapless stack — "it only add images vertically". Changing the kit's own defaults
  # would re-render every published page that already uses one.
  describe "the attributes a furnishing declares" do
    test "are read off the declaration and nowhere else" do
      assert Starter.attrs(declaring("acme-grid", %{"attrs" => %{"cols" => "three"}})) == %{
               "cols" => "three"
             }

      assert Starter.attrs(declaring("acme-grid", %{"body" => "x"})) == %{}
      assert Starter.attrs(declaring("acme-grid", %{})) == %{}
    end

    # A furnishing is a kit's content, so it is exactly as trustworthy as the bundle: the NAME is
    # written straight into HEEx and so has to be one.
    test "anything that is not a plain name is dropped" do
      declared = %{
        "attrs" => %{
          "cols" => "three",
          "Cols" => "no",
          "on click" => "no",
          "alt" => ~s(a " quote)
        }
      }

      assert Starter.attrs(declaring("acme-grid", declared)) == %{"cols" => "three"}
    end

    # AND A VALUE MAY BE A COLLECTION. `chelekom-filterable-gallery` holds its pictures in a list and
    # there is no string that means one, so a list or a map is carried through as the expression the
    # component actually takes.
    test "a list or a map is kept as an expression" do
      declared = %{
        "attrs" => %{
          "filters" => ["One", "Two"],
          "media" => [%{":src" => "/a.jpg", "alt" => "A"}]
        }
      }

      assert Starter.attrs(declaring("acme-grid", declared)) == %{
               "filters" => {:expr, ["One", "Two"]},
               # `":src"` is JSON's way of writing an atom key — the same spelling the bundle's own
               # `__atom_map__` envelope uses — because the component reads `media.src`. A plain
               # `"alt"` stays a string, because a kit may genuinely want one.
               "media" => {:expr, [%{:src => "/a.jpg", "alt" => "A"}]}
             }
    end

    # A NUMBER OR A YES/NO IS NOT A WORD: `chelekom-ring-progress` does arithmetic on its `value`, and
    # written as `value="72"` it reached the component as text.
    test "a number or a yes/no is kept as an expression" do
      declared = %{"attrs" => %{"value" => 72, "ratio" => 0.5, "open" => true}}

      assert Starter.attrs(declaring("acme-ring", declared)) == %{
               "value" => {:expr, 72},
               "ratio" => {:expr, 0.5},
               "open" => {:expr, true}
             }
    end

    # A NAME NOTHING HAS HEARD OF IS A BUNDLE FILLING THE ATOM TABLE. It costs that key its atom
    # rather than being minted from somebody else's file.
    test "an atom key for a name that does not exist stays a string" do
      declared = %{"attrs" => %{"x" => [%{":no_such_atom_anywhere_in_this_system" => "v"}]}}

      assert %{"x" => {:expr, [map]}} = Starter.attrs(declaring("acme-grid", declared))
      assert Map.keys(map) == [":no_such_atom_anywhere_in_this_system"]
    end
  end

  describe "against the installed kits" do
    # The whole point: an author drags any container out of the palette and sees a component, not an
    # outline. 100 of the kit's 136 take an inner block.
    test "every component that can hold content is furnished", %{components: components} do
      bare =
        for component <- components,
            entry = %{name: component["name"], slots: component["slots"] || [], attrs: []},
            Starter.takes_content?(entry),
            not Starter.furnished?(entry),
            # A shape that IS its own content has nothing to say.
            not String.contains?(component["name"], ["spinner", "progress", "skeleton"]),
            do: component["name"]

      assert bare == [], "these would still drop as an empty box:\n" <> Enum.join(bare, "\n")
    end

    # The other half of the same complaint: a component whose content lives ENTIRELY in named slots
    # has no inner block at all, so `takes_content?/1` is false and the check above never sees it.
    # `chelekom-native-select` with no `<:option>` is an empty dropdown.
    test "a component whose content is only slots gets those slots", %{components: components} do
      lists = ~w(option item slide tab radio checkbox control)

      bare =
        for component <- components,
            slots = component["slots"] || [],
            names = Enum.map(slots, & &1["name"]),
            "inner_block" not in names,
            Enum.any?(names, &(&1 in lists)),
            entry = %{name: component["name"], slots: slots, attrs: []},
            not Starter.furnished?(entry),
            do: component["name"]

      assert bare == [], "these drop as an empty list:\n" <> Enum.join(bare, "\n")
    end
  end
end
