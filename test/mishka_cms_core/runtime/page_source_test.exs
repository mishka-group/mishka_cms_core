# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageSourceTest do
  @moduledoc """
  `MishkaCmsCore.Runtime.PageSource`: the rows a page shows, read once through the
  `runtime:page:source` event and handed, unchanged, to the head, the frame and the page's blocks.

  What an extension reads into it, and that a page then asks the database for each row once, is
  the extension's own suite and the host's `PageQueriesTest`.

  `async: false` — the event registry and `SiteState` are process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.{LiveViewHelpers, PageSource, Seo, SiteLayout, Translations}
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.EventCannotRun

  # A PLUGIN AS AN EXTENSION WRITES ONE: it answers for the kind of record it owns, with the rows it
  # read for the visitor it was handed and whom it read them for, and hands every other page back
  # untouched.
  defmodule ProbeSource do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "runtime:page:source"

    @impl true
    def call(%{record: "probe:post", params: %{"slug" => slug}} = given) do
      source = %{
        slug: slug,
        visitor: PageSource.visitor_id(given.current_user),
        held: given.held
      }

      {:reply, :halt, %{given | source: source}}
    end

    def call(given), do: {:reply, given}
  end

  # A FRAME PLUGIN THAT SAYS WHAT IT WAS HANDED, in the bar's title.
  defmodule SourceFrame do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "runtime:page:frame"

    @impl true
    def call(%{record: "probe:post"} = frame),
      do: {:reply, :halt, %{frame | section_bar: %{title: inspect(frame.source)}}}

    def call(frame), do: {:reply, frame}
  end

  defmodule RaisingSource do
    @moduledoc false
    def call(_given), do: raise("broken extension")
  end

  defp plugin!(module, event \\ PageSource.event()) do
    {:ok, _} =
      MishkaInstaller.Event.Event.write(%{
        name: module,
        event: event,
        extension: :mishka_installer,
        status: :started
      })

    :ok = MishkaInstaller.Event.EventHandler.do_compile(event, :start, false)

    on_exit(fn ->
      MishkaInstaller.Event.Event.unregister(:name, module, false)
      MishkaInstaller.Event.EventHandler.do_compile(event, :start, false)
    end)
  end

  defp page(path, opts \\ []) do
    %{
      title: "Probe",
      path: path,
      section: Keyword.get(opts, :section, "probe"),
      language: Keyword.get(opts, :language, "en")
    }
  end

  # The socket as `RuntimeLive` holds it when it reads the page's rows.
  defp socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            page: page("/:lang/probe/:slug"),
            private: %{site_id: "site"},
            extra: %{"record" => "probe:post"},
            query_params: %{"slug" => "hello"},
            current_user: nil
          },
          assigns
        )
    }
  end

  # What `assign_source/1` left as `@page_source`.
  defp assigned(%Phoenix.LiveView.Socket{assigns: %{page_source: source}}), do: source

  describe "the map a plugin is handed" do
    test "names the page, its record, its captures, its language and the visitor" do
      visitor = %{id: "visitor"}

      given =
        PageSource.given(page("/:lang/probe/:slug", language: "fa"),
          site_id: "site",
          current_user: visitor,
          extra: %{"record" => "probe:post"},
          params: %{"slug" => "hello"},
          held: :before
        )

      assert given.section == "probe"
      assert given.record == "probe:post"
      assert given.params == %{"slug" => "hello"}
      assert given.language == "fa"
      assert given.site_id == "site"
      assert given.current_user == visitor
      assert given.held == :before
      assert given.source == nil
    end
  end

  describe "the source" do
    setup do: plugin!(ProbeSource)

    test "is what the plugin that owns the page read" do
      source =
        PageSource.source(page("/:lang/probe/:slug"),
          extra: %{"record" => "probe:post"},
          params: %{"slug" => "hello"}
        )

      assert source == %{slug: "hello", visitor: nil, held: nil}
    end

    test "is none for a page no plugin answers for" do
      assert PageSource.source(page("/:lang/about"), extra: %{}) == nil
    end
  end

  describe "a plugin that cannot answer" do
    test "leaves the page with no source when it raises" do
      plugin!(RaisingSource)

      ExUnit.CaptureLog.capture_log(fn ->
        assert PageSource.source(page("/x"), extra: %{"record" => "probe:post"}) == nil
      end)
    end

    test "leaves the page with no source while the event cannot run" do
      EventCannotRun.stub!(PageSource.event())

      assert PageSource.source(page("/x"), extra: %{"record" => "probe:post"}) == nil
    end

    test "is read as nothing when it answers with what is not a map" do
      assert PageSource.accept(:nonsense) == nil
      assert PageSource.accept(%{other: 1}) == nil
    end
  end

  describe "assign_source/1" do
    setup do: plugin!(ProbeSource)

    test "assigns the source as @page_source, read for the visitor" do
      socket = PageSource.assign_source(socket(%{current_user: %{id: "u1"}}))

      assert assigned(socket) == %{slug: "hello", visitor: "u1", held: nil}
    end

    # A PATCH ON THE SAME LIVEVIEW hands the plugin what the address before it read, so the rows the
    # new address did not change are not read again — and only to the visitor it was read for.
    test "hands back what the address before read, for the same visitor only" do
      first = PageSource.assign_source(socket(%{current_user: %{id: "u1"}}))

      second =
        first
        |> Phoenix.Component.assign(:query_params, %{"slug" => "next"})
        |> PageSource.assign_source()

      assert %{slug: "next", held: held} = assigned(second)
      assert held == assigned(first)

      third =
        second
        |> Phoenix.Component.assign(:current_user, %{id: "u2"})
        |> PageSource.assign_source()

      assert %{held: nil, visitor: "u2"} = assigned(third)
    end

    test "assigns none for a page no plugin answers for" do
      socket = socket(%{extra: %{}, page: page("/:lang/about")})

      assert socket |> PageSource.assign_source() |> assigned() == nil
    end
  end

  # THE SAME ROWS REACH THE OTHER TWO READERS, as they were read.
  describe "the head and the frame" do
    test "are handed the source in the map their plugins are given" do
      source = %{slug: "hello"}

      assert SiteLayout.given(page("/x"), source: source).source == source
      assert SiteLayout.given(page("/x"), []).source == nil
      assert Seo.given(page("/x"), source: source).source == source
      assert Seo.given(page("/x"), []).source == nil
    end

    test "keep the source a plugin hands back as it was given" do
      given = Seo.given(page("/x"), source: :read)

      assert Seo.accept(%{given | source: :changed}, given).source == :read
    end

    test "take it from @page_source when the frame is assigned" do
      plugin!(SourceFrame, SiteLayout.event())

      socket = socket(%{page_languages: [], page_source: %{slug: "read once"}})

      assert %{assigns: %{page_section_bar: %{title: title}}} = SiteLayout.assign_frame(socket)
      assert title == ~s(%{slug: "read once"})
    end
  end

  # ONE THAT DECLARES THE ATTRIBUTE IS HANDED THE ROWS; ONE THAT DOES NOT — a component an admin keeps
  # on an older kit — is drawn as though the template had not named them, not with them in its
  # global attributes.
  describe "a block" do
    setup do
      SiteState.clear()
      n = System.unique_integer([:positive])
      site = create_site!(name: "source#{n}", host: "source#{n}.test", active: true)

      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active,
        master: site.master
      })

      on_exit(fn -> SiteState.clear() end)

      for {name, attrs, shown} <- [
            {"source-taker", [%{"name" => "page_source", "type" => "any", "opts" => %{}}],
             "{inspect(@page_source)}"},
            {"source-older", [], "older"}
          ] do
        create_component!(
          name: name,
          site_id: site.id,
          stateful: true,
          template: ~s(<div id={@id} {@rest} data-role="#{name}">#{shown}</div>),
          attrs: attrs ++ [%{"name" => "rest", "type" => "global", "opts" => %{}}]
        )

        assert LiveViewHelpers.ensure_component_loaded(name, site.name)
      end

      :ok = Translations.put_site(site.id)

      %{site: site}
    end

    test "that declares page_source is handed it", %{site: site} do
      html =
        LiveViewCompiler.render_template(
          ~s(<.component component_name="source-taker" site="#{site.name}" id="t" page_source={%{rows: 7}} />),
          %{}
        )

      assert html =~ "rows: 7"
    end

    test "that does not declare it never draws it", %{site: site} do
      html =
        LiveViewCompiler.render_template(
          ~s(<.component component_name="source-older" site="#{site.name}" id="o" page_source={%{rows: 7}} />),
          %{}
        )

      assert html =~ ~s(data-role="source-older")
      refute html =~ "page_source"
      refute html =~ "rows"
    end
  end
end
