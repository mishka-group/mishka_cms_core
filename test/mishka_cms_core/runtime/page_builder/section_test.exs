# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.SectionTest do
  @moduledoc """
  The one owner of what the builder edits, and of the three ways each of them is spelled.

  This exists because the same fact was written in ten places in two spellings. The address says
  `error-page`, everything durable says `error_page`, and the difference was converted by hand in
  nine places across five modules — three of them a bare `String.to_existing_atom/1`, which is not a
  conversion but a crash waiting for the one section whose spellings differ. It took the builder's
  mount down for error pages, and the editor would not open there at all.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.Section

  @moduletag :unit

  describe "the four things the builder edits" do
    test "are named once" do
      assert Enum.sort(Section.names()) == ["component", "error-page", "layout", "page"]
    end

    test "and each is known by any of its spellings" do
      for name <- Section.names() do
        assert Section.known?(name)
        assert Section.known?(Section.normalize(Section.to_underscored(name)))
      end
    end

    test "anything else is not one of ours" do
      refute Section.known?("spreadsheet")
      refute Section.known?("")
    end
  end

  describe "the three spellings" do
    test "the address form is the canonical one, whatever it is given" do
      assert Section.normalize("error_page") == "error-page"
      assert Section.normalize("error-page") == "error-page"
      assert Section.normalize(:error_page) == "error-page"
      assert Section.normalize(nil) == "page"
    end

    test "the stored form is underscored, whatever it is given" do
      assert Section.to_underscored("error-page") == "error_page"
      assert Section.to_underscored("error_page") == "error_page"
      assert Section.to_underscored(:error_page) == "error_page"
      assert Section.to_underscored("page") == "page"
    end

    test "the atom form is what the log and the resources file under" do
      assert Section.to_atom("error-page") == {:ok, :error_page}
      assert Section.to_atom("error_page") == {:ok, :error_page}
      assert Section.to_atom(:error_page) == {:ok, :error_page}
      assert Section.to_atom("page") == {:ok, :page}
    end

    test "and a section that is not one of ours is refused, not invented" do
      assert Section.to_atom("spreadsheet") == :error

      assert_raise ArgumentError, ~r/spreadsheet/, fn -> Section.to_atom!("spreadsheet") end
    end

    test "every spelling round-trips through every other" do
      for name <- Section.names() do
        atom = Section.to_atom!(name)

        assert Section.normalize(atom) == name
        assert Section.to_atom!(Section.to_underscored(name)) == atom
        assert Section.to_atom!(Section.normalize(atom)) == atom
      end
    end

    test "the atoms are the set the resources constrain on" do
      assert Enum.sort(Section.atoms()) == [:component, :error_page, :layout, :page]
    end
  end

  describe "the builder's addresses" do
    test "a document's builder is addressed in the URL spelling, whatever it is given" do
      assert Section.builder_path("page", "p1") == "/admin/dashboard/runtime/builder/page/p1"

      assert Section.builder_path(:error_page, "e1") ==
               "/admin/dashboard/runtime/builder/error-page/e1"
    end

    test "and a document not saved yet is the builder that makes one" do
      assert Section.builder_path("page") == "/admin/dashboard/runtime/builder/page"

      assert Section.builder_path("error_page", nil, 500) ==
               "/admin/dashboard/runtime/builder/error-page"
    end

    test "and an error page keeps the entry it was on" do
      assert Section.builder_path("error_page", "e1", 500) ==
               "/admin/dashboard/runtime/builder/error-page/e1?status=500"
    end

    test "the back link honours another builder" do
      assert Section.back_path("component", "/admin/dashboard/runtime/builder/page/p1") ==
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
        assert Section.back_path("component", elsewhere) == "/admin/dashboard/runtime/components",
               "#{inspect(elsewhere)} was honoured"
      end
    end
  end

  describe "what the log files a section under" do
    test "agrees with what the builder calls it" do
      # The two lists were maintained separately, in different spellings, and only met when the
      # editor tried to open an error page.
      assert Enum.sort(Section.atoms()) ==
               Enum.sort(MishkaCmsCore.Runtime.PageBuilderEvent.sources())
    end
  end

  # The page an offline site shows sits in the error page beside the codes, and the builder opens,
  # switches to and saves it by the `offline` its address spells it with.
  describe "an error page's offline entry" do
    @record %{
      error_pages: [
        %{status: 404, template: "<p>Not here</p>"},
        %{status: :offline, template: "<p>Soon</p>"},
        %{status: 500, template: "<p>Broke</p>"}
      ]
    }

    test "is one of the statuses, after the codes" do
      assert Section.statuses("error-page", @record) == [404, 500, :offline]
    end

    test "opens by the status its address names" do
      assert Section.status(@record, status: "offline") == :offline
      assert Section.editing_status("error-page", @record, status: "offline") == :offline
      assert Section.template("error-page", @record, status: "offline") == "<p>Soon</p>"
    end

    test "and its address names it" do
      assert Section.builder_path("error-page", "e1", :offline) ==
               "/admin/dashboard/runtime/builder/error-page/e1?status=offline"
    end

    test "is the entry a save replaces, the others kept" do
      fields = Section.save_fields("error-page", "<p>Later</p>", status: "offline")

      assert %{"error_pages" => entries} = Section.apply_fields(fields, @record)

      assert Enum.map(entries, &{&1["status"], &1["template"]}) == [
               {404, "<p>Not here</p>"},
               {:offline, "<p>Later</p>"},
               {500, "<p>Broke</p>"}
             ]
    end

    # A STATUS IS ADDED BY OPENING IT: one the record lacks opens empty when an error page can hold
    # it, and is the one its save writes. Anything else still falls back.
    test "opens empty when the record lacks it, and is what the strip then shows" do
      record = %{error_pages: [%{status: 404, template: "<p>Not here</p>"}]}

      assert :offline in Section.offered_statuses()
      assert 503 in Section.offered_statuses()
      assert Section.status(record, status: "offline") == :offline
      assert Section.template("error-page", record, status: "offline") == ""
      assert Section.statuses("error-page", record, :offline) == [404, :offline]
      assert Section.status(record, status: "999") == 404
      assert Section.status(record, status: "teapot") == 404
    end

    test "is found when the form wrote it as text" do
      record = %{error_pages: [%{"status" => "offline", "template" => "<p>Soon</p>"}]}

      assert Section.statuses("error-page", record) == [:offline]
      assert Section.template("error-page", record, status: "offline") == "<p>Soon</p>"
    end
  end

  # EACH SECTION'S BUILDER OPENS FOR ITS OWN RUNTIME AREA OR CODE, whichever spelling asks for it.
  describe "the names a section asks for" do
    test "its runtime area or code, error-page read as error_page" do
      assert Section.permissions("page") == [
               "admin:dashboard:runtime:page",
               "admin:dashboard:code"
             ]

      for section <- ["error-page", "error_page", :error_page] do
        assert Section.permissions(section) ==
                 ["admin:dashboard:runtime:error_page", "admin:dashboard:code"]
      end

      assert Section.permissions("component") ==
               ["admin:dashboard:runtime:component", "admin:dashboard:code"]

      assert Section.permissions("layout") ==
               ["admin:dashboard:runtime:layout", "admin:dashboard:code"]
    end

    test "nobody and a section it does not know open nothing" do
      refute Section.allowed?(nil, "page")
      refute Section.allowed?(%{permissions: [%{name: "*"}]}, "spreadsheet")
      assert Section.allowed?(%{permissions: [%{name: "*"}]}, "error-page")
    end

    test "a runtime area opens its own section only" do
      holder = %{permissions: [%{name: "admin:dashboard:runtime:page"}]}

      assert Section.allowed?(holder, "page")

      for section <- ["layout", "component", "error-page"],
          do: refute(Section.allowed?(holder, section), section)
    end

    test "code opens every section" do
      holder = %{permissions: [%{name: "admin:dashboard:code"}]}

      for section <- Section.names(), do: assert(Section.allowed?(holder, section), section)
    end

    test "an API name opens no builder" do
      holder = %{permissions: [%{name: "admin:api:runtime:page"}, %{name: "admin:api:code"}]}

      for section <- Section.names(), do: refute(Section.allowed?(holder, section), section)
    end
  end
end
