# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.SectionPreviewOptionsTest do
  @moduledoc """
  The fields each section has that the others do not, and what the preview does with them.

  Three of the four editable resources carry an option the preview is documented to honour, and each
  one is the answer to "what does previewing THIS kind of document even mean":

    * a **layout** wraps a page it does not have, so `example` is the content to wrap — without it
      the preview says so rather than pretending;
    * an **error page** may wrap each status in a `layout` of its own, and the whole document in
      `root_layout_template`, mirroring what `MishkaCmsCore.Runtime.Compilers.ErrorCompiler` serves.

  These are easy to leave untested because nothing raises when they are ignored: the preview simply
  shows the placeholder or the bare inner page, which looks like a preview that works.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias MishkaCmsCore.Runtime.{ErrorPage, Layout, RuntimePreview}

  describe "a layout's example is the content it wraps" do
    test "with one, the preview renders it rather than the placeholder" do
      record = %{
        name: "wrapper",
        site: nil,
        template: ~s(<header>Site</header><main>{@inner_content}</main>),
        example: ~s(<article class="real-content">A real page</article>)
      }

      html = RuntimePreview.inner_html(record, Layout)

      assert html =~ "real-content"
      assert html =~ "A real page"
      refute html =~ "Page content appears here"
    end

    test "without one, it says what it is showing instead of pretending" do
      record = %{
        name: "wrapper",
        site: nil,
        template: ~s(<header>Site</header><main>{@inner_content}</main>),
        example: nil
      }

      html = RuntimePreview.inner_html(record, Layout)

      assert html =~ "Page content appears here"
      assert html =~ "Site", "the layout's own chrome still renders around it"
    end
  end

  describe "an error page's own wrappers" do
    defp error_record(entry, root \\ nil) do
      %{
        name: "errors",
        site: %{name: "localhost", id: "5f1f0a2e-0000-4000-8000-000000000001", host: "localhost"},
        root_layout_template: root,
        error_pages: [entry]
      }
    end

    test "a status entry's own layout wraps that status" do
      entry = %{
        status: 404,
        template: ~s(<p class="inner">Missing</p>),
        layout: %{template: ~s(<section class="status-frame">{@inner_content}</section>)}
      }

      html = RuntimePreview.inner_html(error_record(entry), ErrorPage, 404)

      assert html =~ "status-frame"
      assert html =~ "inner"

      assert :binary.match(html, "status-frame") < :binary.match(html, "inner"),
             "the entry's layout has to be OUTSIDE the entry, not beside it"
    end

    test "and an entry with no layout of its own is served as it is" do
      entry = %{status: 404, template: ~s(<p class="inner">Missing</p>), layout: %{}}

      html = RuntimePreview.inner_html(error_record(entry), ErrorPage, 404)

      assert html =~ "inner"
      refute html =~ "status-frame"
    end

    # `inner_html/5` is the FRAGMENT — what the shareable preview page embeds — so the record's
    # `root_layout_template` is the host page's job and not this one's. Pinned because "the root
    # layout is missing from the fragment" reads like a bug until you know where it is applied.
    test "the root layout belongs to the document, not to the fragment" do
      entry = %{status: 404, template: ~s(<p class="inner">Missing</p>), layout: %{}}
      root = ~s(<html><body class="root-frame">{@inner_content}</body></html>)

      html = RuntimePreview.inner_html(error_record(entry, root), ErrorPage, 404)

      assert html =~ "inner"
      refute html =~ "root-frame"
    end

    test "a status the record does not define falls back rather than raising" do
      entry = %{status: 404, template: ~s(<p class="inner">Missing</p>), layout: %{}}

      html = RuntimePreview.inner_html(error_record(entry), ErrorPage, 503)

      assert html =~ "inner", "an unknown status should show what the record does have"
    end
  end
end
