defmodule MishkaCmsCore.Runtime.RuntimePreviewTest do
  use ExUnit.Case, async: true
  @moduletag :unit

  alias MishkaCmsCore.Runtime.RuntimePreview
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.PageDraft
  alias MishkaCmsCore.Runtime.ErrorPage

  # The runtime serves error pages with Phoenix.HTML.Engine (classic EEx), which allows EEx
  # interpolation inside attribute values (`content="<%= ... %>"`). The preview must render the same
  # way; HEEx would raise a Tokenizer.ParseError on the same template.
  @root_layout ~S|<!DOCTYPE html><html><head><meta name="csrf-token" content="<%= Phoenix.Controller.get_csrf_token() %>" /><title>Error <%= @status %></title></head><body><div class="root-banner">ROOT <%= @status %></div><%= @inner_content %></body></html>|

  defp error_record(opts \\ []) do
    %{
      name: "Errors",
      site: %{name: "Global"},
      root_layout_template: Keyword.get(opts, :root_layout, @root_layout),
      error_pages: [
        %{status: 404, template: "<h1>404 Not Found</h1>", layout: nil},
        %{status: 500, template: "<h1>500 Boom</h1>", layout: Keyword.get(opts, :layout_500)}
      ]
    }
  end

  describe "device_width/1" do
    test "maps device keys to widths and falls back to desktop" do
      assert RuntimePreview.device_width("desktop") == 1280
      assert RuntimePreview.device_width("tablet") == 768
      assert RuntimePreview.device_width("mobile") == 375
      assert RuntimePreview.device_width("anything-else") == 1280
    end
  end

  describe "render_document/2 for a Page" do
    test "renders a self-contained template into a full document with no note" do
      page = %{name: "Hello", template: "<h1>{@page.name}</h1>", site: %{name: "Global"}}

      {html, note} = RuntimePreview.render_document(page, Page)

      assert note == nil
      assert html =~ "<!doctype html>"
      assert html =~ "<title>Hello</title>"
      assert html =~ "<h1>Hello</h1>"
    end

    test "returns a fallback document and a note when the template needs missing assigns" do
      page = %{name: "Bad", template: "<div>{@not_provided}</div>", site: %{name: "Global"}}

      {html, note} = RuntimePreview.render_document(page, Page)

      assert is_binary(note)
      assert html =~ "Preview unavailable"
    end

    # A PUBLISHED PAGE IS HANDED ITS LANGUAGE EDITIONS, so a template or layout may draw a language
    # switcher from `@page_languages`. A preview has no published URL to offer alternates of, but the
    # assign must be there, empty, or the switcher is a preview nobody can open.
    test "hands a template an empty list of language editions" do
      page = %{
        name: "Switcher",
        template:
          ~S|<nav><a :for={edition <- @page_languages} href={edition.path}>x</a>none</nav>|,
        site: %{name: "Global"}
      }

      {html, note} = RuntimePreview.render_document(page, Page)

      assert note == nil
      assert html =~ "<nav>none</nav>"
    end

    test "html-escapes the page name in the document title" do
      page = %{name: "<script>x</script>", template: "<p>ok</p>", site: %{name: "Global"}}

      {html, _note} = RuntimePreview.render_document(page, Page)

      refute html =~ "<title><script>"
      assert html =~ "&lt;script&gt;"
    end
  end

  describe "render_document/2 for a PageDraft" do
    test "renders the draft's template like a page (for the /_preview URL)" do
      draft = %{name: "Draft Hero", template: "<h1>{@page.name}</h1>", site: %{name: "Global"}}

      {html, note} = RuntimePreview.render_document(draft, PageDraft)

      assert note == nil
      assert html =~ "<title>Draft Hero</title>"
      assert html =~ "<h1>Draft Hero</h1>"
    end
  end

  describe "render_document/2 and render_error_document/2 for an ErrorPage" do
    test "renders a chosen status wrapped in the root layout, with attribute interpolation working" do
      {html, note} = RuntimePreview.render_error_document(error_record(), 500)

      assert note == nil
      assert html =~ "<!DOCTYPE html>"
      assert html =~ ~s(name="csrf-token")
      assert html =~ "ROOT 500"
      assert html =~ "<h1>500 Boom</h1>"
      refute html =~ "500 Boom</h1></h1>"
    end

    test "render_document/2 defaults to the first status code" do
      {html, note} = RuntimePreview.render_document(error_record(), ErrorPage)

      assert note == nil
      assert html =~ "ROOT 404"
      assert html =~ "<h1>404 Not Found</h1>"
    end

    test "applies a per-status :layout around the inner template" do
      record =
        error_record(
          layout_500: %{
            template: ~S(<section class="status-wrap"><%= @inner_content %></section>)
          }
        )

      {html, note} = RuntimePreview.render_error_document(record, 500)

      assert note == nil
      assert html =~ ~s(class="status-wrap")
      assert html =~ "<h1>500 Boom</h1>"
    end

    test "wraps the inner page in a default document when no root layout is set" do
      {html, note} = RuntimePreview.render_error_document(error_record(root_layout: nil), 404)

      assert note == nil
      assert html =~ "<!doctype html>"
      assert html =~ "<h1>404 Not Found</h1>"
      refute html =~ "root-banner"
    end

    test "render_error_document returns a note (not a crash) for an unknown status" do
      {html, note} = RuntimePreview.render_error_document(error_record(), 418)

      assert is_binary(note)
      assert html =~ "No template for status 418"
    end

    test "inner_html/2 returns inner-only (no nested <html>) for the /_preview LiveView" do
      inner = RuntimePreview.inner_html(error_record(), ErrorPage)

      refute inner =~ "<html"
      refute inner =~ "root-banner"
      assert inner =~ "<h1>404 Not Found</h1>"
    end
  end

  describe "the CSP nonce on every <style> the preview writes" do
    test "the document's stylesheet is marked with the nonce it was given" do
      page = %{name: "Nonced", template: "<p>ok</p>", site: %{name: "Global"}}

      {html, note} = RuntimePreview.render_document(page, Page, "aB+/cd0=")

      assert note == nil
      assert html =~ ~s(<style nonce="aB+/cd0=">)
      refute html =~ "<style>"
    end

    test "a degraded render nonces the note's own stylesheet too" do
      page = %{name: "Bad", template: "<div>{@not_provided}</div>", site: %{name: "Global"}}

      {html, note} = RuntimePreview.render_document(page, Page, "n0nce")

      assert is_binary(note)
      assert length(String.split(html, ~s(<style nonce="n0nce">))) - 1 == 2
    end

    test "the ErrorPage fallback document carries it on both of its blocks" do
      {html, note} = RuntimePreview.render_error_document(error_record(), 418, "err-nonce")

      assert is_binary(note)
      assert length(String.split(html, ~s(<style nonce="err-nonce">))) - 1 == 2
    end

    test "an inner fragment's note carries it, for the enforced /_preview page" do
      record = %{name: "Bad", template: "<div>{@not_provided}</div>", site: %{name: "Global"}}

      inner = RuntimePreview.inner_html(record, Page, nil, "frag-nonce")

      assert inner =~ ~s(<style nonce="frag-nonce">)
      refute inner =~ "<style>"
    end

    test "no nonce emits no attribute at all — never the string \"nil\"" do
      page = %{name: "Plain", template: "<p>ok</p>", site: %{name: "Global"}}

      {html, _note} = RuntimePreview.render_document(page, Page)

      assert html =~ "<style>"
      refute html =~ "nonce="
    end

    test "a nonce carrying a quote is escaped and cannot close the attribute" do
      page = %{name: "Escaped", template: "<p>ok</p>", site: %{name: "Global"}}

      {html, _note} = RuntimePreview.render_document(page, Page, ~S|"><script>x</script>|)

      refute html =~ "<script>x</script>"
      assert html =~ "&quot;&gt;&lt;script&gt;"
    end
  end

  describe "file_size/1 and source/1" do
    test "file_size formats bytes of :template or :content" do
      assert RuntimePreview.file_size(%{template: String.duplicate("a", 2048)}) == "2.0 KB"
      assert RuntimePreview.file_size(%{content: "abc"}) == "3 B"
    end

    test "source returns the template or content string" do
      assert RuntimePreview.source(%{template: "<p>x</p>"}) == "<p>x</p>"
      assert RuntimePreview.source(%{content: "body{}"}) == "body{}"
    end
  end
end
