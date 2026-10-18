# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.BuilderLive.FormRecoveryTest do
  @moduledoc """
  A panel form that was being filled in when the page reconnected.

  LiveView sends every form that has an `id` and a `phx-change` back through that event after a
  reconnect, and draws the page again from what the server then holds. These tests send the event
  the way the browser does (`render_change/1` on the form) and assert that the input still holds
  what was typed, and that a form which lets go of its text (a submit) is drawn empty again.
  """
  use MishkaCmsCore.BuilderLiveCase

  @template ~s(<section><h1>Hi</h1></section>)

  setup %{conn: conn, site: site} do
    page = create_page!(site_id: site.id, template: @template)
    {:ok, view, _html} = open_builder(conn, page)
    section = node_with_tag(view, "section")
    render_click(view, "select", %{"id" => section.id})
    view |> element("#pb-lefttab-inspector") |> render_click()
    view |> element("#pb-section-attributes") |> render_click()

    %{view: view, node: section, page: page}
  end

  defp value_of(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  defp forms_in(html) do
    ~r/<form\b[^>]*>/s |> Regex.scan(html) |> List.flatten()
  end

  describe "every form a panel draws that takes a submit" do
    test "has an id, and a phx-change or a recovery of its own", %{view: view} do
      view |> element("#pb-attr-add") |> render_click()

      forms = forms_in(render(view))

      assert forms != []

      for form <- forms, form =~ "phx-submit" do
        assert form =~ ~r/\sid="/, "a form with no id: #{form}"

        assert form =~ "phx-change" or form =~ ~s(phx-auto-recover="ignore"),
               "a form that comes back empty after a reconnect: #{form}"
      end
    end

    test "in the assistant, the classes and the drafts sheets too", %{view: view} do
      view |> element("#pb-rail-assistant") |> render_click()
      html = render(view)
      assert html =~ "pb-ai-form"

      for form <- forms_in(html), form =~ "phx-submit" do
        assert form =~ ~r/\sid="/, "a form with no id: #{form}"
        assert form =~ "phx-change" or form =~ ~s(phx-auto-recover="ignore")
      end
    end
  end

  describe "the Add attribute form" do
    test "holds what was typed when the page comes back", %{view: view} do
      view |> element("#pb-attr-add") |> render_click()

      view
      |> form("#pb-attr-form", %{"attr" => %{"name" => "aria-label", "value" => "Hero"}})
      |> render_change()

      assert value_of(view, "#pb-attr-form input[name='attr[name]']") == "aria-label"
      assert value_of(view, "#pb-attr-form input[name='attr[value]']") == "Hero"
    end

    test "is drawn empty again once the attribute is added", %{view: view, node: node} do
      view |> element("#pb-attr-add") |> render_click()

      view
      |> form("#pb-attr-form", %{"attr" => %{"name" => "aria-label", "value" => "Hero"}})
      |> render_change()

      view
      |> form("#pb-attr-form", %{"attr" => %{"name" => "aria-label", "value" => "Hero"}})
      |> render_submit()

      assert attr_of(view, node.id, "aria-label") == {:string, "Hero"}

      view |> element("#pb-attr-add") |> render_click()

      assert value_of(view, "#pb-attr-form input[name='attr[name]']") in [nil, ""]
      assert value_of(view, "#pb-attr-form input[name='attr[value]']") in [nil, ""]
    end
  end

  describe "the Custom CSS form" do
    test "holds the text typed over the stored CSS", %{view: view, node: node} do
      view
      |> form("#pb-css-form-#{node.id}", %{"css" => "gap: 7px;", "base" => ""})
      |> render_change()

      assert view |> element("#pb-css-text") |> render() =~ "gap: 7px"
    end

    test "is not held over CSS that changed in the meantime", %{view: view, node: node} do
      view
      |> form("#pb-css-form-#{node.id}", %{"css" => "gap: 7px;", "base" => ""})
      |> render_change()

      render_click(view, "save_element_css", %{"node_id" => node.id, "css" => "gap: 9px;"})

      html = view |> element("#pb-css-text") |> render()
      assert html =~ "gap: 9px"
      refute html =~ "gap: 7px"
    end

    test "answers a refused rule with the text that was typed", %{view: view, node: node} do
      view
      |> form("#pb-css-form-#{node.id}", %{"css" => "gap: {{{", "base" => ""})
      |> render_change()

      view
      |> form("#pb-css-form-#{node.id}", %{"css" => "gap: {{{", "base" => ""})
      |> render_submit()

      assert has_element?(view, "#pb-css-error")
      assert view |> element("#pb-css-text") |> render() =~ "gap: {{{"
    end
  end

  describe "the assistant's prompt" do
    test "keeps what was typed", %{view: view} do
      view |> element("#pb-rail-assistant") |> render_click()

      view |> form("#pb-ai-form", %{"prompt" => "add a hero"}) |> render_change()

      assert view |> element("#pb-ai-prompt") |> render() =~ "add a hero"
    end
  end

  describe "the Review note composer" do
    test "keeps the note that was being written", %{view: view} do
      render_click(view, "open_sheet", %{"sheet" => "review"})
      render_async(view)

      view
      |> element("#pb-comment-form")
      |> render_change(%{
        "_target" => ["form", "body"],
        "form" => %{"body" => "Tighten this heading", "type" => "bug"}
      })

      assert view |> element("#pb-comment-body") |> render() =~ "Tighten this heading"
    end
  end

  describe "the snippet form" do
    test "keeps the name that was being typed", %{view: view} do
      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)
      view |> element("#pb-studio-snippets") |> render_click()

      view
      |> element("#pb-snippet-form")
      |> render_change(%{
        "_target" => ["form", "name"],
        "form" => %{"name" => "Kept heading", "visibility" => "shared"}
      })

      assert value_of(view, "#pb-snippet-name") == "Kept heading"
    end
  end

  describe "the class form" do
    test "keeps the name and the utilities that were typed", %{view: view} do
      render_click(view, "open_sheet", %{"sheet" => "studio"})
      _studio = render_async(view, 5_000)
      render_click(view, "studio_tab", %{"tab" => "classes"})

      view
      |> form("#pb-class-form", %{"name" => "card-shell", "utilities" => "p-6 rounded-xl"})
      |> render_change()

      assert value_of(view, "#pb-class-name") == "card-shell"
      assert value_of(view, "#pb-class-utilities") == "p-6 rounded-xl"
    end
  end
end
