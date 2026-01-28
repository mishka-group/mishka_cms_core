defmodule MishkaCmsCore.Runtime.PageBuilder.ExamplesTest do
  @moduledoc """
  Curating a component's examples out of the two sets a kit bundle ships.

  The kit's own catalogue is exhaustive and shows nothing: twelve alerts whose body is the name of
  the option being demonstrated. The documentation site's usages are the same components with real
  content, and 3,084 of them sat in the bundle unread. Merging them is only useful if the result is
  deduped and says what each entry demonstrates — otherwise it is a longer list of the same problem.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.Examples

  defp component(examples, demo_examples \\ []) do
    %{"extra" => %{"examples" => examples, "demo_examples" => demo_examples}}
  end

  defp alert(attrs, body) do
    %{
      "source" =>
        ~s(<.component component_name="chelekom-alert" site="Global"#{attrs}>#{body}</.component>)
    }
  end

  describe "for_component/1" do
    test "a component with no examples offers none" do
      assert Examples.for_component(%{}) == []
      assert Examples.for_component(component([])) == []
    end

    test "an example says what it demonstrates, read off the markup" do
      [example] = Examples.for_component(component([alert(~s( variant="outline"), "Base")]))

      assert example.description == "variant outline"
    end

    # `kind={:danger}` travels as an atom because that is what the component matches on. A
    # description is prose.
    test "an atom attribute is described without its colon" do
      [example] = Examples.for_component(component([alert(" kind={:danger}", "Base")]))

      assert example.description == "kind danger"
    end

    test "an attribute set to nothing is not something to describe" do
      [example] = Examples.for_component(component([alert(" icon={nil} variant=\"base\"", "Hi")]))

      assert example.description == "variant base"
    end

    test "structural attributes are not a variation" do
      [example] = Examples.for_component(component([Map.put(alert("", "Hi"), "base", true)]))

      assert example.description == "The component with nothing set"
    end

    # The whole point of reading the demo set: a preview whose body reads "Base" shows the author
    # nothing about the component in a page.
    test "where both sets show the same options, the documentation one wins" do
      curated = [Map.put(alert(~s( variant="outline"), "Base"), "label", "Outline Variant")]
      composed = [alert(~s( variant="outline"), "Your changes have been saved.")]

      [example] = Examples.for_component(component(curated, composed))

      assert example.source =~ "Your changes have been saved."
      # …keeping the curated label, which is the better name of the two.
      assert example.title == "Outline Variant"
      assert example.composed?
    end

    test "the same example twice is one example" do
      same = alert(~s( variant="outline"), "Base")

      assert [_one] = Examples.for_component(component([same, same]))
    end

    # There are usually several documentation examples per option set, and handing the curated label
    # to all of them made a list of distinct previews read as duplicates of one entry.
    test "only the first documentation example takes the curated label" do
      curated = [Map.put(alert(~s( variant="base"), "Base"), "label", "Base Variant")]
      composed = [alert(~s( variant="base"), "Saved"), alert(~s( variant="base"), "Deleted")]

      titles = component(curated, composed) |> Examples.for_component() |> Enum.map(& &1.title)

      assert "Base Variant" in titles
      assert length(Enum.uniq(titles)) == 2
    end

    test "the same options with different content are two examples" do
      first = alert(~s( variant="outline"), "Saved")
      second = alert(~s( variant="outline"), "Deleted")

      assert length(Examples.for_component(component([], [first, second]))) == 2
    end

    test "the unmodified component comes first" do
      base = Map.put(alert("", "Base"), "base", true)
      variant = alert(~s( variant="outline"), "Outline")

      assert [first, _second] = Examples.for_component(component([variant, base]))
      assert first.base?
    end

    test "every example carries a stable id" do
      examples =
        Examples.for_component(
          component([
            Map.put(alert(~s( variant="outline"), "A"), "section", "outline-alert"),
            Map.put(alert(~s( variant="shadow"), "B"), "section", "shadow-alert")
          ])
        )

      ids = Enum.map(examples, & &1.id)

      assert ids == Enum.uniq(ids)
      assert Enum.all?(ids, &String.match?(&1, ~r/^[a-z0-9-]+$/))
    end

    # The Wizard answers "what does this look like in amber, bordered, large" — so the modal is left
    # with "what does a finished one look like", and a short list of complete ones answers that
    # better than a catalogue of near-identical cards.
    test "the list is capped short" do
      many = for i <- 1..80, do: alert(~s( variant="outline"), "Body number #{i}")

      assert length(Examples.for_component(component([], many))) == 6
    end

    # An empty-bodied example demonstrates the outline and nothing else. 334 of the kit's own demo
    # entries are exactly that, and they are why dropping a banner showed a blank strip.
    test "an example with content outranks an empty one" do
      furnished = alert(~s( variant="outline"), "A gentle confirmation that it worked.")
      bare = alert(~s( variant="bordered"), "")

      [first | _rest] = Examples.for_component(component([], [bare, furnished]))

      assert first.source =~ "gentle confirmation"
    end

    # Seven components in the kit have nothing but empty entries. An outline beats nothing.
    test "empty examples survive when the component has nothing better" do
      bare = alert(~s( variant="bordered"), "")

      assert [_only] = Examples.for_component(component([], [bare]))
    end

    test "an unparseable example is described rather than dropped" do
      [example] = Examples.for_component(component([%{"source" => "<div><span></div>"}]))

      assert example.description == "The component as it ships"
    end

    test "a blank source is not an example" do
      assert Examples.for_component(component([%{"source" => "   "}, %{"label" => "no source"}])) ==
               []
    end
  end

  # CONTENT IS NOT ALWAYS WORDS. An example was read as empty unless something survived stripping
  # every tag, so a gallery of six image tiles and a carousel of three slides scored zero — and one
  # example with a sentence in it was enough to drop the rest. `chelekom-gallery` shipped four and
  # offered one: not the three-column grid, not the masonry one, which is the whole of "there is no
  # option to choose style".
  describe "an example whose content is components" do
    test "counts as furnished, so it is not dropped for one with prose" do
      component = %{
        "extra" => %{
          "examples" => [
            %{
              "label" => "A grid of tiles",
              "source" =>
                ~S|<.component component_name="acme-grid" cols="three"><.component component_name="acme-tile" /></.component>|
            },
            %{
              "label" => "One with words in it",
              "source" => ~S|<.component component_name="acme-grid" cols="two">Hello</.component>|
            }
          ]
        }
      }

      titles = component |> Examples.for_component() |> Enum.map(& &1.title)

      assert "A grid of tiles" in titles
      assert "One with words in it" in titles
    end

    # And the bare shell it was written to drop is still bare: one self-closing tag, nothing in it.
    test "a component with nothing inside it is still not furnished" do
      component = %{
        "extra" => %{
          "examples" => [
            %{"label" => "Empty", "source" => ~S|<.component component_name="acme-grid" />|},
            %{
              "label" => "Real",
              "source" => ~S|<.component component_name="acme-grid">Hello</.component>|
            }
          ]
        }
      }

      assert component |> Examples.for_component() |> Enum.map(& &1.title) == ["Real"]
    end
  end

  describe "count/1" do
    test "counts what the modal would show, not what the bundle holds" do
      same = alert(~s( variant="outline"), "Base")

      assert Examples.count(component([same, same, same])) == 1
    end
  end
end
