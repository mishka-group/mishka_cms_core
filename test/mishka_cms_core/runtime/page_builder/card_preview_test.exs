# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.CardPreviewTest do
  @moduledoc """
  The preview shown while the pointer rests on a palette card.

  Two things are asserted harder than the rest, because both are the difference between a feature
  worth having and one that makes the editor worse:

    * the document LINKS the site's compiled bundle rather than inlining it. That bundle is 194 KB
      and served `immutable`; the canvas has already downloaded it before anyone hovers, so linking
      costs nothing and inlining would cost 194 KB per card;
    * the cache holds the rendered BODY, never the document. A cached document carries the
      stylesheet's content hash with it, and after a recompile that URL is gone — the preview would
      draw unstyled and read as a broken component rather than a stale cache.
  """
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Runtime.PageBuilder.CardPreview
  alias MishkaCmsCore.Runtime.States.AssetsState
  alias MishkaCmsCore.Runtime.States.CardPreviewState

  @moduletag :unit

  setup do
    CardPreviewState.drop_all()
    on_exit(&CardPreviewState.drop_all/0)
    :ok
  end

  defp bundle(hash) do
    AssetsState.save(%{
      id: "__shared_base__",
      type: "css",
      value: ".from-the-bundle{color:#123456}",
      hash: hash,
      updated_at: DateTime.utc_now()
    })
  end

  describe "the document it builds" do
    test "renders the template the card would drop" do
      assert {:ok, html} = CardPreview.document("<p>a paragraph</p>", nil)

      assert html =~ "<p>a paragraph</p>"
      assert html =~ "<!doctype html>"
    end

    test "and it is a whole document, so an iframe can take it as it is" do
      {:ok, html} = CardPreview.document("<p>hi</p>", nil)

      assert html =~ "<html lang=\"en\">"
      assert html =~ "<body>"
    end
  end

  describe "the stylesheet" do
    # THE WHOLE REASON THIS IS CHEAP. 194 KB, `immutable`, and already in the browser's cache.
    test "is linked by content hash, not inlined" do
      bundle("abc123")

      {:ok, html} = CardPreview.document("<p>hi</p>", nil)

      assert html =~ "/assets/css/__shared_base__/abc123"
      refute html =~ ".from-the-bundle{color:#123456}"
    end

    # The same fallback the canvas has, for the same site: one that has bytes but has never been
    # compiled, so there is no hash to address them by.
    test "is inlined when there is no hash to address it by" do
      bundle(nil)

      {:ok, html} = CardPreview.document("<p>hi</p>", nil)

      assert html =~ ".from-the-bundle{color:#123456}"
      refute html =~ "/assets/css/__shared_base__/"
    end
  end

  # THE SILENT FAILURE. A srcdoc document inherits the admin page's policy, which enforces
  # `style-src-elem 'self' 'nonce-<n>'` with no `'unsafe-inline'`. A `<style>` without the nonce is
  # not an error anyone sees — the preview simply draws unstyled, and an unstyled component looks
  # exactly like a broken one. Nothing but a test catches that.
  describe "the Content-Security-Policy the frame inherits" do
    test "every style element it writes carries the page's nonce" do
      bundle("abc123")

      {:ok, html} = CardPreview.document("<p>hi</p>", nil, "nonce-from-the-page")

      for style <- Regex.scan(~r/<style[^>]*>/, html) do
        assert hd(style) =~ ~s|nonce="nonce-from-the-page"|
      end
    end

    test "including the inlined bundle, on a site that has never compiled" do
      bundle(nil)

      {:ok, html} = CardPreview.document("<p>hi</p>", nil, "nonce-from-the-page")

      assert html =~ ~s|<style nonce="nonce-from-the-page">.from-the-bundle|
    end

    # A page that somehow never ran the nonce plug gets a plain `<style>` rather than a crash — the
    # same choice the preview modal makes for the same reason.
    test "and no nonce is a bare style rather than a broken one" do
      {:ok, html} = CardPreview.document("<p>hi</p>", nil, nil)

      assert html =~ "<style>"
      refute html =~ "nonce="
    end
  end

  describe "a template that will not render" do
    test "says what is wrong instead of drawing a blank box" do
      assert {:error, message} = CardPreview.document("<p>{@missing_assign_here}</p>", nil)

      assert is_binary(message)
      assert message != ""
    end

    test "and the message is a sentence, not an exception struct" do
      {:error, message} = CardPreview.document("<p>{@missing_assign_here}</p>", nil)

      refute message =~ "** ("
      refute message =~ "\n"
    end

    test "nothing at all is refused rather than rendered" do
      assert {:error, _message} = CardPreview.document(nil, nil)
    end
  end

  describe "the cache" do
    test "a second ask does not render again" do
      CardPreview.document("<p>counted</p>", nil)

      assert CardPreviewState.size() == 1

      CardPreview.document("<p>counted</p>", nil)

      assert CardPreviewState.size() == 1
    end

    # THE BUG THIS SHAPE EXISTS TO PREVENT. Cache the document and it carries the old hash with it;
    # the URL is immutable, so after a recompile it is simply gone and the preview draws unstyled.
    test "holds the body, so a recompiled bundle is picked up without invalidating anything" do
      bundle("hash-one")
      {:ok, first} = CardPreview.document("<p>same markup</p>", nil)
      assert first =~ "/assets/css/__shared_base__/hash-one"

      bundle("hash-two")
      {:ok, second} = CardPreview.document("<p>same markup</p>", nil)

      assert second =~ "/assets/css/__shared_base__/hash-two"
      refute second =~ "hash-one"
    end

    test "a refusal is remembered too — working it out twice costs what it cost once" do
      CardPreview.document("<p>{@nope}</p>", nil)

      assert CardPreviewState.size() == 1
      assert {:error, _message} = CardPreview.document("<p>{@nope}</p>", nil)
    end

    test "two presets of one component are two previews" do
      CardPreview.document(~s|<p class="a">x</p>|, nil)
      CardPreview.document(~s|<p class="b">x</p>|, nil)

      assert CardPreviewState.size() == 2
    end

    test "and one template under two sites is two previews" do
      CardPreview.document("<p>x</p>", nil)
      CardPreview.document("<p>x</p>", "some-site")

      assert CardPreviewState.size() == 2
    end
  end
end
