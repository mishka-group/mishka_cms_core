# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.BuilderLive.RoadmapNoticeTest do
  @moduledoc """
  The Assistant and Audit tabs say, in a roadmap notice, when what they show is sample content or
  when the part behind them is not connected yet.
  """
  use MishkaCmsCore.BuilderLiveCase

  alias MishkaCmsCore.Test.AiBackendStub

  @assistant_title "The AI Assistant is not available yet"
  @assistant_sample "The conversation below is a sample of how it will work."
  @audit_title "Some checks are not available yet"
  @audit_title_no_assistant "Some checks and automatic fixes are not available yet"
  @audit_fix_sentence "Fix hands a finding to the AI Assistant, which is on our roadmap."
  @audit_sample_sentence "Findings marked Sample show how they will look; they are on our roadmap."
  @fix_hint "Needs the AI Assistant, which is on our roadmap"

  @unlabelled_link ~s(<div id="root"><h1>T</h1><a href="/x"></a></div>)

  @bare_form ~s(<div id="root"><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact_validate" phx-submit="contact_submit"><input name={f[:email].name} /></.form></div>)

  defp demo_data(enabled?) do
    Application.put_env(:mishka_cms_core, :builder_demo_data, enabled?)
    on_exit(fn -> Application.delete_env(:mishka_cms_core, :builder_demo_data) end)
  end

  defp real_backend do
    Application.put_env(:mishka_cms_core, :builder_ai_backend, AiBackendStub)
    AiBackendStub.answer([])

    on_exit(fn ->
      Application.delete_env(:mishka_cms_core, :builder_ai_backend)
      Application.delete_env(:mishka_cms_core, :test_ai_answer)
    end)
  end

  defp open_assistant(conn, page) do
    {:ok, view, _html} = open_builder(conn, page)
    view |> element("#pb-rail-assistant") |> render_click()
    view
  end

  defp notice_text(view, id), do: view |> element("##{id}") |> render() |> text_of()

  defp text_of(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text()

  describe "the Assistant tab" do
    test "sample messages bring the notice, with the sentence about the sample", %{
      conn: conn,
      page: page
    } do
      demo_data(true)
      view = open_assistant(conn, page)

      assert has_element?(view, "#pb-ai-roadmap[role=note]")
      assert has_element?(view, "#pb-ai-roadmap", @assistant_title)
      assert notice_text(view, "pb-ai-roadmap") =~ "This part of the editor is on our roadmap."
      assert notice_text(view, "pb-ai-roadmap") =~ @assistant_sample
    end

    test "the sample thread names Shahryar Tavakkoli, with ST on the avatar", %{
      conn: conn,
      page: page
    } do
      demo_data(true)
      view = open_assistant(conn, page)

      assert has_element?(view, "#pb-ai-msg-1", "Shahryar Tavakkoli")
      assert has_element?(view, "#pb-ai-msg-3", "Shahryar Tavakkoli")
      assert view |> element("#pb-ai-msg-1 > span") |> render() |> text_of() =~ "ST"

      refute render(view) =~ "Sara"
      refute render(view) =~ "Hadid"
    end

    test "the Echo stub with no sample brings the notice, ending after the roadmap sentence", %{
      conn: conn,
      page: page
    } do
      demo_data(false)
      view = open_assistant(conn, page)

      assert has_element?(view, "#pb-ai-roadmap", @assistant_title)
      assert notice_text(view, "pb-ai-roadmap") =~ "This part of the editor is on our roadmap."
      refute notice_text(view, "pb-ai-roadmap") =~ "sample"
      refute has_element?(view, "#pb-ai-msg-0")
    end

    test "a real backend and no sample leave no notice", %{conn: conn, page: page} do
      demo_data(false)
      real_backend()
      view = open_assistant(conn, page)

      refute has_element?(view, "#pb-ai-roadmap")
      refute render(view) =~ @assistant_title
    end

    test "a real backend still shows the notice while the sample thread does", %{
      conn: conn,
      page: page
    } do
      demo_data(true)
      real_backend()
      view = open_assistant(conn, page)

      assert notice_text(view, "pb-ai-roadmap") =~ @assistant_sample
    end

    test "a real conversation takes the sample and its sentence away, and the notice goes with a real backend",
         %{conn: conn, page: page} do
      demo_data(true)
      real_backend()
      view = open_assistant(conn, page)
      assert has_element?(view, "#pb-ai-roadmap")

      view |> form("#pb-ai-form", %{"prompt" => "tighten the spacing"}) |> render_submit()

      refute has_element?(view, "#pb-ai-roadmap")
    end

    test "a real conversation on the Echo stub keeps the notice, without the sample sentence", %{
      conn: conn,
      page: page
    } do
      demo_data(true)
      view = open_assistant(conn, page)
      assert notice_text(view, "pb-ai-roadmap") =~ @assistant_sample

      view |> form("#pb-ai-form", %{"prompt" => "tighten the spacing"}) |> render_submit()

      assert has_element?(view, "#pb-ai-roadmap", @assistant_title)
      refute notice_text(view, "pb-ai-roadmap") =~ "sample"
    end

    test "the sample is still there: the flag and the entries are untouched", %{
      conn: conn,
      page: page
    } do
      demo_data(true)
      view = open_assistant(conn, page)

      assert has_element?(view, "#pb-ai-msg-0")
      assert has_element?(view, "#pb-ai-msg-4")
      assert render(view) =~ "Make the header sticky and reduce its height a bit"
      assert Enum.all?(MishkaCmsCore.Runtime.PageBuilder.Demo.messages(), & &1.demo?)
    end
  end

  describe "the Audit tab" do
    test "sample findings and no backend bring the notice with both sentences", %{
      conn: conn,
      page: page
    } do
      demo_data(true)
      {:ok, view, _html} = open_builder(conn, page)
      open_audit(view)

      assert has_element?(view, "#pb-audit-roadmap[role=note]")
      assert has_element?(view, "#pb-audit-roadmap", @audit_title_no_assistant)
      assert notice_text(view, "pb-audit-roadmap") =~ @audit_fix_sentence
      assert notice_text(view, "pb-audit-roadmap") =~ @audit_sample_sentence
    end

    test "no backend and no sample bring the notice with the Fix sentence only", %{
      conn: conn,
      page: page
    } do
      demo_data(false)
      {:ok, view, _html} = open_builder(conn, page)
      open_audit(view)

      assert has_element?(view, "#pb-audit-roadmap", @audit_title_no_assistant)
      assert notice_text(view, "pb-audit-roadmap") =~ @audit_fix_sentence
      refute notice_text(view, "pb-audit-roadmap") =~ "Sample"
      refute has_element?(view, "[data-role=pb-sample-badge]")
    end

    test "a real backend with sample findings brings the notice about the samples only", %{
      conn: conn,
      page: page
    } do
      demo_data(true)
      real_backend()
      {:ok, view, _html} = open_builder(conn, page)
      open_audit(view)

      assert has_element?(view, "#pb-audit-roadmap", @audit_title)
      refute has_element?(view, "#pb-audit-roadmap", "automatic fixes")
      assert notice_text(view, "pb-audit-roadmap") =~ @audit_sample_sentence
      refute notice_text(view, "pb-audit-roadmap") =~ @audit_fix_sentence
    end

    test "a real backend and no sample leave no notice", %{conn: conn, page: page} do
      demo_data(false)
      real_backend()
      {:ok, view, _html} = open_builder(conn, page)
      open_audit(view)

      refute has_element?(view, "#pb-audit-roadmap")
      refute render(view) =~ @audit_title
    end

    test "the sample finding wears a Sample badge and its Fix is disabled", %{
      conn: conn,
      page: page
    } do
      demo_data(true)
      real_backend()
      {:ok, view, _html} = open_builder(conn, page)
      open_audit(view)

      assert has_element?(view, "#pb-audit-sample-contrast", "Sample")
      assert has_element?(view, "#pb-audit-fix-contrast[disabled]")
      refute has_element?(view, "#pb-audit-fix-contrast[phx-click]")

      assert_raise ArgumentError, ~r/because it is disabled/, fn ->
        view |> element("#pb-audit-fix-contrast") |> render_click()
      end

      assert render(view) =~ "Low contrast on muted text"
    end

    test "with no backend a Fix that would reach the assistant is disabled and says why", %{
      conn: conn,
      site: site
    } do
      demo_data(false)
      page = create_page!(site_id: site.id, template: @unlabelled_link)
      {:ok, view, _html} = open_builder(conn, page)
      open_audit(view)

      fix = ~s|button[data-rule="link-text"]|

      assert render(view) =~ "Link has no visible text"
      assert has_element?(view, "#{fix}[disabled][title=\"#{@fix_hint}\"]")
      refute has_element?(view, "#{fix}[phx-click]")

      assert_raise ArgumentError, ~r/because it is disabled/, fn ->
        view |> element(fix) |> render_click()
      end
    end

    test "with a backend the same Fix is enabled and hands the finding to the assistant", %{
      conn: conn,
      site: site
    } do
      demo_data(false)
      real_backend()
      page = create_page!(site_id: site.id, template: @unlabelled_link)
      {:ok, view, _html} = open_builder(conn, page)
      open_audit(view)

      fix = ~s|button[data-rule="link-text"]|

      assert has_element?(view, "#{fix}[phx-click=audit_fix]:not([disabled])")
      refute has_element?(view, "#{fix}[title]")

      view |> element(fix) |> render_click()

      assert has_element?(view, "#pb-ai-form")
      assert_receive {:asked, _prompt, _opts}
    end

    test "a Forms finding is mended by the editor itself, so its Fix needs no backend", %{
      conn: conn,
      site: site
    } do
      demo_data(false)
      page = create_page!(site_id: site.id, template: @bare_form)
      {:ok, view, _html} = open_builder(conn, page)
      open_audit(view)

      fix = ~s|button[data-rule="form-no-submit"]|

      assert has_element?(view, "#{fix}[phx-click=audit_fix]:not([disabled])")
      refute has_element?(view, "#{fix}[title]")
      refute node_with_tag(view, "button")

      view |> element(fix) |> render_click()

      assert node_with_tag(view, "button")
      refute has_element?(view, "#pb-ai-form")
    end

    test "a real finding has no badge, and the one sample finding has", %{conn: conn, site: site} do
      demo_data(true)
      real_backend()
      page = create_page!(site_id: site.id, template: @unlabelled_link)
      {:ok, view, _html} = open_builder(conn, page)
      open_audit(view)

      assert render(view) =~ "Link has no visible text"
      assert has_element?(view, ~s|button[data-rule="link-text"]:not([disabled])|)

      badges =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-role=pb-sample-badge]")

      assert Enum.count(badges) == 1
      assert has_element?(view, "#pb-audit-sample-contrast")
    end
  end
end
