defmodule MishkaCmsCore.Runtime.PageBuilder.BuilderAccessTest do
  @moduledoc """
  The builder's own data is held to the names that open the builder, per type.

  Snippets, review notes and history carry the section they were written in, and reading or writing
  one needs that section's runtime area or `admin:dashboard:code`. What the builder generates into a
  stylesheet — reusable classes, element CSS, design tokens — takes any name that opens a builder
  rather than the stylesheet area. A holder of an unrelated area, or of another type's area, is
  refused.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.{PageBuilderSnapshot, PageComment, Snippet, Stylesheet}
  alias MishkaCmsCore.Runtime.PageBuilder.{BuilderAccess, Classes, ElementCss, EditorSession}
  alias MishkaCmsCore.Runtime.PageBuilder.{History, Snippets, Tokens, Tree}
  alias MishkaCmsCore.Runtime.PageBuilderEvent

  require Ash.Query

  @moduletag :capture_log

  @source ~S(<section class="hero"><h1>Hello</h1></section>)

  setup do
    site = create_site!()
    {:ok, site: site, page: create_page!(site_id: site.id)}
  end

  defp holder(names, site), do: create_user_with_permissions!(List.wrap(names), site_id: site.id)

  defp forbidden?({:error, %Ash.Error.Forbidden{}}), do: true
  defp forbidden?(_result), do: false

  defp refused?({:error, _refused}), do: true
  defp refused?(_result), do: false

  defp snippet(actor, site, section) do
    Snippet
    |> Ash.Changeset.for_create(
      :create,
      %{name: "s#{System.unique_integer([:positive])}", source: @source, section: section},
      actor: actor,
      tenant: site.id
    )
    |> Ash.create()
  end

  defp snippet!(site, section) do
    Snippet
    |> Ash.Changeset.for_create(
      :create,
      %{name: "s#{System.unique_integer([:positive])}", source: @source, section: section},
      tenant: site.id,
      authorize?: false
    )
    |> Ash.create!()
  end

  describe "BuilderAccess.sections/2" do
    test "names each builder the actor may open", %{site: site} do
      assert BuilderAccess.sections(holder("admin:dashboard:runtime:page", site), %{}) == [:page]

      assert BuilderAccess.sections(holder("admin:dashboard:runtime:error_page", site), %{}) ==
               [:error_page]

      assert BuilderAccess.sections(holder("admin:dashboard:runtime:site", site), %{}) == []
      assert BuilderAccess.sections(nil, %{}) == []

      for names <- [["admin:dashboard:code"], ["admin:dashboard:runtime:*"]] do
        assert Enum.sort(BuilderAccess.sections(holder(names, site), %{})) ==
                 Enum.sort([:page, :layout, :component, :error_page]),
               inspect(names)
      end
    end
  end

  describe "snippets" do
    test "the page area saves a page snippet and not a layout one", %{site: site} do
      actor = holder("admin:dashboard:runtime:page", site)

      assert {:ok, _saved} = snippet(actor, site, :page)
      assert forbidden?(snippet(actor, site, :layout))
    end

    test "code saves a snippet in every builder", %{site: site} do
      actor = holder("admin:dashboard:code", site)

      assert {:ok, _page} = snippet(actor, site, :page)
      assert {:ok, _layout} = snippet(actor, site, :layout)
    end

    test "a holder of an unrelated area saves none", %{site: site} do
      assert forbidden?(snippet(holder("admin:dashboard:runtime:site", site), site, :page))
    end

    test "reading shows only the sections whose builder the reader opens", %{site: site} do
      page_snippet = snippet!(site, :page)
      layout_snippet = snippet!(site, :layout)
      actor = holder("admin:dashboard:runtime:layout", site)

      ids = Snippet |> Ash.read!(actor: actor, tenant: site.id, page: false) |> Enum.map(& &1.id)

      assert layout_snippet.id in ids
      refute page_snippet.id in ids
    end

    test "Snippets saves, lists, reads and deletes as the actor", %{site: site, page: page} do
      builder = holder("admin:dashboard:runtime:page", site)
      stranger = holder("admin:dashboard:runtime:layout", site)
      scope = %{site_id: site.id, section: :page, document_id: page.id}

      assert {:ok, saved} =
               Snippets.save(Map.merge(scope, %{name: "Hero", source: @source, actor: builder}))

      assert [%{id: id}] = Snippets.list(Map.put(scope, :actor, builder))
      assert id == saved.id
      assert Snippets.list(Map.put(scope, :actor, stranger)) == []

      assert Snippets.source(saved.id, builder) == @source
      assert Snippets.source(saved.id, stranger) == nil

      assert {:error, :not_found} = Snippets.delete(saved.id, stranger)
      assert :ok = Snippets.delete(saved.id, builder)
      assert {:error, :forbidden} = Snippets.save(Map.merge(scope, %{name: "x", source: @source}))
    end
  end

  describe "review notes" do
    test "the page area writes and reads a page note; the layout area neither", %{site: site} do
      note = fn actor, section ->
        PageComment
        |> Ash.Changeset.for_create(
          :create,
          %{body: "a note", type: :information, section: section},
          actor: actor,
          tenant: site.id
        )
        |> Ash.create()
      end

      page_builder = holder("admin:dashboard:runtime:page", site)
      layout_builder = holder("admin:dashboard:runtime:layout", site)

      assert {:ok, written} = note.(page_builder, :page)
      assert forbidden?(note.(layout_builder, :page))
      assert forbidden?(note.(holder("admin:dashboard:runtime:site", site), :page))

      readable = fn actor ->
        PageComment |> Ash.read!(actor: actor, tenant: site.id, page: false) |> Enum.map(& &1.id)
      end

      assert written.id in readable.(page_builder)
      refute written.id in readable.(layout_builder)
    end

    test "code writes and reads a note in every builder", %{site: site} do
      coder = holder("admin:dashboard:code", site)

      written =
        for section <- [:page, :layout, :component, :error_page] do
          PageComment
          |> Ash.Changeset.for_create(
            :create,
            %{body: "a note", type: :information, section: section},
            actor: coder,
            tenant: site.id
          )
          |> Ash.create!()
        end

      readable =
        PageComment |> Ash.read!(actor: coder, tenant: site.id, page: false) |> Enum.map(& &1.id)

      for note <- written, do: assert(note.id in readable, inspect(note.section))
    end
  end

  describe "history" do
    setup %{site: site, page: page} do
      {:ok, session} =
        EditorSession.open(%{
          section: "page",
          template: ~s(<div id="root"><h1>Contact</h1></div>),
          site_id: site.id,
          resource_id: page.id
        })

      heading = session.tree |> Tree.walk() |> Enum.find(&(&1.tag == "h1"))

      {:ok, _} =
        EditorSession.apply_op(session.token, %{kind: :set_text, node_id: heading.id, text: "Hi"})

      {:ok, token: session.token}
    end

    defp rows(page) do
      PageBuilderEvent
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(source_id == ^page.id)
      |> Ash.read!()
    end

    test "is written by the page area", %{site: site, page: page, token: token} do
      assert {:ok, 1} = History.flush(token, holder("admin:dashboard:runtime:page", site))
      assert [%{source_type: :page}] = rows(page)
    end

    test "is written by code", %{site: site, page: page, token: token} do
      assert {:ok, 1} = History.flush(token, holder("admin:dashboard:code", site))
      assert [%{source_type: :page}] = rows(page)
    end

    test "is not written by another type's area or an unrelated one", %{
      site: site,
      page: page,
      token: token
    } do
      assert {:error, {:partial, 0}} =
               History.flush(token, holder("admin:dashboard:runtime:layout", site))

      assert {:error, {:partial, 0}} =
               History.flush(token, holder("admin:dashboard:runtime:site", site))

      assert rows(page) == []
    end

    test "a snapshot is written by any name that opens a builder and by nobody else", %{
      site: site
    } do
      write = fn actor ->
        PageBuilderSnapshot
        |> Ash.Changeset.for_create(:create, %{payload: :zlib.gzip("<div></div>"), byte_size: 11},
          actor: actor
        )
        |> Ash.create()
      end

      for name <- [
            "admin:dashboard:runtime:page",
            "admin:dashboard:runtime:layout",
            "admin:dashboard:runtime:component",
            "admin:dashboard:runtime:error_page",
            "admin:dashboard:code"
          ] do
        assert {:ok, _snapshot} = write.(holder(name, site)), name
      end

      assert forbidden?(write.(holder("admin:dashboard:runtime:stylesheet", site)))
    end
  end

  # What the builder generates into a stylesheet is the builder's, not the stylesheet area's.
  describe "stylesheet rows the builder writes" do
    test "a reusable class is written by any name that opens a builder", %{site: site} do
      for name <- ["admin:dashboard:runtime:page", "admin:dashboard:code"] do
        assert {:ok, [%{name: "card-shell"} | _]} =
                 Classes.put(holder(name, site), site.id, "card-shell", "p-4"),
               name
      end
    end

    # AN UNRELATED AREA: the CSS itself would pass, so the refusal is the row's policy.
    test "and refused to a holder of an unrelated area", %{site: site} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Classes.put(
                 holder("admin:dashboard:runtime:site", site),
                 site.id,
                 "card-shell",
                 "p-4"
               )
    end

    test "an element's CSS is written by a builder and refused to anyone else", %{site: site} do
      builder = holder("admin:dashboard:runtime:layout", site)
      owner = "page-#{Ecto.UUID.generate()}"

      assert {:ok, %{"pb-abcd1234" => _}} =
               ElementCss.put(builder, site.id, owner, "pb-abcd1234", "padding: 4px;")

      assert refused?(
               ElementCss.put(
                 holder("admin:dashboard:runtime:site", site),
                 site.id,
                 "page-#{Ecto.UUID.generate()}",
                 "pb-abcd1234",
                 "padding: 4px;"
               )
             )
    end

    test "a design token is written as the actor, by a builder", %{site: site} do
      key = "tok-#{System.unique_integer([:positive])}"

      Stylesheet
      |> Ash.Changeset.for_create(
        :master_create,
        %{name: "theme-#{key}", kind: :theme, content: ":root {\n  --#{key}: #111111;\n}\n"},
        authorize?: false
      )
      |> Ash.create!()

      assert {:error, :forbidden} = Tokens.put(nil, site.id, "--" <> key, "#222222")

      assert refused?(
               Tokens.put(
                 holder("admin:dashboard:runtime:site", site),
                 site.id,
                 "--" <> key,
                 "#222222"
               )
             )

      assert {:ok, %{value: "#333333"}} =
               Tokens.put(
                 holder("admin:dashboard:runtime:page", site),
                 site.id,
                 "--" <> key,
                 "#333333"
               )
    end

    # AND THE NAME ALONE IS NOTHING: the page area writes a stylesheet row only as the builder.
    test "the page area's own stylesheet write, outside the builder, is refused", %{site: site} do
      assert forbidden?(
               Stylesheet
               |> Ash.Changeset.for_create(
                 :create,
                 %{name: "x#{System.unique_integer([:positive])}", content: ".a{}", format: :css},
                 actor: holder("admin:dashboard:runtime:page", site),
                 tenant: site.id
               )
               |> Ash.create()
             )
    end

    test "the context alone is nothing: the stylesheet area's write is still its own", %{
      site: site
    } do
      assert forbidden?(
               Stylesheet
               |> Ash.Changeset.for_create(
                 :create,
                 %{name: "x#{System.unique_integer([:positive])}", content: ".a{}", format: :css},
                 actor: holder("admin:dashboard:runtime:site", site),
                 tenant: site.id,
                 context: %{page_code: :builder}
               )
               |> Ash.create()
             )
    end
  end

  describe "design tokens" do
    test "are read by any dashboard admin and by nobody without an admin name", %{site: site} do
      token = MishkaCmsCore.Runtime.PageBuilder.DesignToken

      row =
        struct(token, %{id: "k", key: "k", label: "K", value: "#fff", category: "color"})

      read = fn actor ->
        token
        |> Ash.Query.for_read(:read, %{}, actor: actor)
        |> Ash.DataLayer.Simple.set_data([row])
        |> Ash.read!()
        |> Map.fetch!(:results)
      end

      assert [%{key: "k"}] = read.(holder("admin:dashboard:runtime:media", site))
      assert read.(holder([], site)) == []
    end
  end
end
