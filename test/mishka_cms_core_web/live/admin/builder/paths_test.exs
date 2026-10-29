# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Builder.PathsTest do
  @moduledoc """
  The editor's own addresses, written in one place, and the answer it gives the rest of the admin
  when asked for one (`runtime:document:editor_url`).
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.Section
  alias MishkaCmsCoreWeb.Live.Admin.Builder.Paths

  @moduletag :unit

  describe "the builder's addresses" do
    test "a document's builder is addressed in the URL spelling, whatever it is given" do
      assert Paths.builder_path("page", "p1") == "/admin/dashboard/runtime/builder/page/p1"

      assert Paths.builder_path(:error_page, "e1") ==
               "/admin/dashboard/runtime/builder/error-page/e1"
    end

    test "and a document not saved yet is the builder that makes one" do
      assert Paths.builder_path("page") == "/admin/dashboard/runtime/builder/page"

      assert Paths.builder_path("error_page", nil, 500) ==
               "/admin/dashboard/runtime/builder/error-page"
    end

    test "and an error page keeps the entry it was on" do
      assert Paths.builder_path("error_page", "e1", 500) ==
               "/admin/dashboard/runtime/builder/error-page/e1?status=500"
    end

    # The page an offline site shows sits in the error page beside the codes, and the builder opens
    # it by the `offline` its address spells it with.
    test "and an error page's offline entry is named by its address" do
      assert Paths.builder_path("error-page", "e1", :offline) ==
               "/admin/dashboard/runtime/builder/error-page/e1?status=offline"
    end

    test "the back link honours another builder" do
      assert Paths.back_path("component", "/admin/dashboard/runtime/builder/page/p1") ==
               "/admin/dashboard/runtime/builder/page/p1"
    end

    # AN OPEN REDIRECT WITH THE ADMIN'S SESSION BEHIND IT. `return_to` is something a URL supplied.
    test "and nothing else, falling back to the section's list" do
      for elsewhere <- [
            nil,
            "",
            "//evil.example/admin/dashboard/runtime/builder/page/p1",
            "https://evil.example/admin/dashboard/runtime/builder/page/p1",
            "javascript:alert(1)",
            "/admin/dashboard/runtime/builder",
            "/admin/dashboard/runtime/pages"
          ] do
        assert Paths.back_path("component", elsewhere) == "/admin/dashboard/runtime/components",
               "#{inspect(elsewhere)} was honoured"
      end
    end
  end

  # WHAT THE ADMIN IS TOLD when it asks: the lists' create menus and the inspector's Visual Editor
  # ask `runtime:document:editor_url`, and the editor's plugin answers in this same spelling.
  describe "the editor's answer to runtime:document:editor_url" do
    test "is its own address, for a new document and a saved one, in every spelling" do
      for section <- Section.names() do
        assert Section.editor_url(section) == Paths.builder_path(section)
        assert Section.editor_url(section, "d1") == Paths.builder_path(section, "d1")
      end

      assert Section.editor_url(:error_page, "e1", 500) ==
               "/admin/dashboard/runtime/builder/error-page/e1?status=500"
    end
  end
end
