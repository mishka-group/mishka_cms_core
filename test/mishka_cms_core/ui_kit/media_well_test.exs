# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.UiKit.MediaWellTest do
  @moduledoc """
  A component waiting for a picture has to be visible, and clicking it has to lead somewhere.

  Nine attributes across the kit declare `editor: "media"`, and only two are REQUIRED —
  `chelekom-image.src` and `chelekom-card-media.src`. Those two draw the "needs src" placeholder and
  always did. The other seven are optional, which means the component renders perfectly and renders
  NOTHING: a gallery tile whose `<img :if={@src}>` collapses to zero height, an avatar drawing a
  src-less `<img>`, a navbar logo nested inside a `<.link :if={!is_nil(@link)}>` that is not there
  either. An author dropped one, saw an empty strip, and had nothing to aim at.

  The editor already owned every piece of the answer: a 120px dashed well (`@placeholder_style`, used
  by `el-image` since it existed), a media library with upload, and — since the last change — a
  canvas click that can carry which attribute it is about. This is those three joined up.

  What is pinned here is the part that would rot silently: WHICH attributes count. It is read off
  `Inspector.widget/3`, the same function that decides whether the Inspector draws a media row, so a
  kit calling one `poster` or `thumbnail` is covered without anything being told about it.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Authoring.Inspector

  @moduletag :unit

  defp bundle do
    MishkaCmsCore.Runtime.Handlers.UiKitHandler.default_bundle_path()
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("components")
  end

  # What `CanvasLive.media_attrs/1` computes, against the same function it computes it with.
  defp media_attrs(entry) do
    features = Inspector.features(entry)

    for attr <- Inspector.attrs(entry),
        Inspector.widget(attr, features, entry) == :media,
        do: Inspector.name(attr)
  end

  defp named(name), do: Enum.find(bundle(), &(&1["name"] == name))

  describe "which attributes are a picture" do
    # The seven the report is about — every one of them optional, so none of them was ever missing
    # anything, so none of them ever drew a placeholder.
    test "the optional ones the canvas showed nothing for" do
      for {component, attr} <- [
            {"chelekom-gallery-media", "src"},
            {"chelekom-navbar", "image"},
            {"chelekom-device-mockup", "image"},
            {"chelekom-shape", "src"},
            {"chelekom-avatar", "src"},
            {"chelekom-timeline-section", "image"},
            {"chelekom-video", "thumbnail"}
          ] do
        assert attr in media_attrs(named(component)),
               "#{component}.#{attr} is not recognised as a picture"
      end
    end

    test "and the two required ones, which already had a placeholder" do
      assert "src" in media_attrs(named("chelekom-image"))
      assert "src" in media_attrs(named("chelekom-card-media"))
    end

    # A NAME IS NOT THE TEST. `thumbnail` and `image` and `poster` are all pictures and `title` is
    # not, and the kit says which is which — this must never become a list of words.
    test "an attribute that is not a picture is not one" do
      refute "title" in media_attrs(named("chelekom-card-title"))
      refute "class" in media_attrs(named("chelekom-avatar"))
      refute "name" in media_attrs(named("chelekom-icon"))
    end

    test "and the set stays small — a well on every component would say nothing" do
      wells =
        for entry <- bundle(),
            attrs = media_attrs(entry),
            attrs != [],
            do: {entry["name"], attrs}

      assert length(wells) == 9,
             "expected the kit's nine media attributes, got #{length(wells)}: #{inspect(wells)}"
    end
  end

  # A SLOT ENTRY WANTS A PICTURE TOO, and the well never reached one. A carousel's slides are
  # `<:slide image="…">` — the attribute belongs to the slot, not to the component — so a slide
  # without a picture was a box with nothing to aim at, and the only way to the media library was
  # through the Inspector by somebody who already knew the attribute was there.
  describe "a picture inside a slot" do
    defp slot_media(entry, slot_name) do
      features = Inspector.features(entry)

      entry
      |> Map.get("slots", [])
      |> Enum.find(%{}, &(Inspector.name(&1) == slot_name))
      |> Inspector.attrs()
      |> Enum.filter(&(Inspector.widget(&1, features, entry) == :media))
      |> Enum.map(&Inspector.name/1)
    end

    test "is recognised the same way one on the component is" do
      assert slot_media(named("chelekom-carousel"), "slide") == ["image"]
      assert slot_media(named("chelekom-accordion"), "item") == ["image"]
    end

    test "and a slot with nothing to show wants nothing" do
      assert slot_media(named("chelekom-carousel"), "inner_block") == []
    end
  end

  # A CLASS IS A CLASS, WHATEVER IT IS A CLASS FOR. `image_class` is not a picture, `icon_class` is
  # not a glyph and `link_class` is not an address — and each of those drew a picker that would
  # write its answer into a CSS class. The kit spares its own top-level attributes by declaring
  # `"editor": "text"` on them and says nothing about the ones inside a slot.
  describe "an attribute that styles something" do
    test "is a text box, on a component and inside a slot alike" do
      pickers =
        for entry <- bundle(),
            features = Inspector.features(entry),
            {owner, attrs} <-
              [{entry["name"], Inspector.attrs(entry)}] ++
                for(
                  slot <- entry["slots"] || [],
                  do: {Inspector.name(slot), Inspector.attrs(slot)}
                ),
            attr <- attrs,
            name = Inspector.name(attr),
            String.split(name, ["_", "-"]) |> List.last() == "class",
            Inspector.widget(attr, features, entry) != :text,
            do: "#{entry["name"]}.#{owner}.#{name}"

      assert pickers == [], "these draw a picker for a CSS class:\n" <> Enum.join(pickers, "\n")
    end

    # And the guard must not be a way of turning every picker off.
    test "while the things it styles keep theirs" do
      icon = named("chelekom-content-item")
      features = Inspector.features(icon)

      for {name, widget} <- [{"icon", :icon}, {"link", :url}] do
        attr = Enum.find(Inspector.attrs(icon), &(Inspector.name(&1) == name))
        assert Inspector.widget(attr, features, icon) == widget
      end
    end
  end

  # A CAROUSEL SHOWS A SLIDE WITHOUT JAVASCRIPT. Every slide is `opacity-0` until the kit's own hook
  # adds `active-slide`, and the canvas frame deliberately loads no site bundle — so a dropped
  # carousel was an empty strip, reported as "we cannot add any images". The active one is marked in
  # the markup now, which the hook then takes over.
  describe "the carousel's first slide" do
    test "carries its active class before any script runs" do
      template = named("chelekom-carousel")["template"]

      assert template =~ "@activated_carousel + 1 == index && @active_slide_class",
             "the active slide is left to the hook, and the canvas has no hook"
    end

    # The indicator row is drawn by a private helper, so what the template can say is which slide it
    # is told about — the same number the active slide is chosen by.
    test "and the indicator row is told which one it is" do
      template = named("chelekom-carousel")["template"]

      assert template =~ "active={@activated_carousel + 1}"
      assert template =~ "active_class={@active_indicator_class}"
    end
  end
end
