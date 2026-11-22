# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.ErrorDefaultEntryTest do
  @moduledoc """
  The `:default` entry of a site's Error Page as a failed request meets it: the entry of the status,
  then the default entry, then the plain status phrase.
  """
  use MishkaCmsCore.DataCase, async: false

  import ExUnit.CaptureLog
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.{ErrorAddress, ErrorPage}
  alias MishkaCmsCore.Runtime.Compilers.{ErrorCompiler, Helpers, ModuleCompiler}
  alias MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler
  alias MishkaCmsCore.Runtime.States.CompileFailureState

  @default ~S|<p id="default">{@status + 0}: {Plug.Conn.Status.reason_phrase(@status)}</p>|
  @compiled [:mishka_cms, :runtime, :compilers, :error, :stop]
  @query [:mishka_cms_core, :repo, :query]

  def heard(event, _measurements, _metadata, test), do: send(test, {:heard, event})

  describe "a status" do
    test "with an entry of its own is answered by it, wherever the default entry sits" do
      for entries <- [
            [entry(:default, @default), entry(404, "<p>Not here</p>")],
            [entry(404, "<p>Not here</p>"), entry(:default, @default)]
          ] do
        page = page!(entries)

        assert draw(page, 404) =~ "Not here"
        assert draw(page, 403) =~ ~s(<p id="default">403: Forbidden</p>)
      end
    end

    test "without one is drawn by the default entry with the status it has, and nothing is logged" do
      page = page!([entry(404, "<p>Not here</p>"), entry("default", @default)])

      log =
        capture_log(fn ->
          for status <- [400, 403, 406, 500, 503] do
            html = draw(page, status)

            assert html =~
                     ~s(<p id="default">#{status}: #{Plug.Conn.Status.reason_phrase(status)}</p>)

            assert html =~ "Error #{status}"
          end
        end)

      refute log =~ "missing error page"
    end

    test "without one or a default entry is answered by its phrase, with one warning" do
      page = page!([entry(404, "<p>Not here</p>")])

      log = capture_log(fn -> assert draw(page, 403) == "Forbidden" end)

      assert log =~ "missing error page for #{page.site.name} status 403"
    end

    test "is drawn in the default entry's own layout, with the status it has" do
      layout = %{
        "template" => ~S|<main id="wrap-default" data-status={@status}>{@inner_content}</main>|
      }

      page = page!([Map.put(entry(:default, @default), :layout, layout)])

      html = draw(page, 406)

      assert html =~ ~s(<main id="wrap-default" data-status="406">)
      assert html =~ "406: Not Acceptable"
    end

    test "reaches the root layout as it is" do
      page =
        page!([entry(:default, @default)],
          root_layout_template:
            "<html><title>E<%= @status + 1 %></title><%= @inner_content %></html>"
        )

      assert draw(page, 403) =~ "<title>E404</title>"
    end
  end

  test "an Error Page with only a default entry compiles and answers every code" do
    page = page!([entry(:default, @default)])

    for status <- [404, 418, 500], do: assert(draw(page, status) =~ "#{status}: ")
  end

  test "the default entry never stands in for the offline one" do
    page = page!([entry(:default, @default)])

    refute ErrorCompiler.offline_entry?(page.module)
    refute CompileFailureState.failed?({page.module, :offline})

    assert_raise ArgumentError, fn ->
      capture_log(fn -> page.module.render(conn(page), :offline) end)
    end
  end

  # A write refuses the second, so they are stored as a row written before that holds them.
  test "of two default entries the first answers, as of two 404 entries" do
    page = uncompiled!([entry(404, "<p>ok</p>")])

    Ash.Seed.update!(page.record, %{
      error_pages: [
        entry(404, "<p>first 404</p>"),
        entry(404, "<p>second 404</p>"),
        entry(:default, "<p>first default</p>"),
        entry(:default, "<p>second default</p>")
      ]
    })

    assert {:ok, _module} = compile(page)
    assert draw(page, 404) =~ "first 404"
    assert draw(page, 403) =~ "first default"
  end

  test "a page compiled again has forgotten the draws of it that failed" do
    page = page!([entry(404, "<p>ok</p>")])
    CompileFailureState.record({page.module, 404}, "boom")
    CompileFailureState.record({page.module, :offline}, "boom")

    update!(page, [entry(404, "<p>ok again</p>")])

    assert CompileFailureState.matching({page.module, :_}) == []
  end

  # The template is drawn by the process that compiled it, and tells it what is known meanwhile.
  test "an offline entry that fails is known to fail all through its next compile" do
    failing =
      ~S|<% send(self(), {:known, MishkaCmsCore.Runtime.States.CompileFailureState.failed?({@conn.assigns.page_module, :offline})}) %>{raise "cannot draw"}|

    page = page!([entry(:offline, failing)])
    assert_received {:known, false}

    on_exit(fn -> CompileFailureState.clear({page.module, :offline}) end)
    assert CompileFailureState.reason({page.module, :offline}) =~ "cannot draw"

    assert {:ok, _module} = compile(page, :update)
    assert_received {:known, true}
    assert CompileFailureState.failed?({page.module, :offline})

    update!(page, [entry(:offline, "<p>fine</p>")])
    refute CompileFailureState.failed?({page.module, :offline})
  end

  test "site A's default entry never answers on site B" do
    a = page!([entry(:default, "<p>site A</p>")])
    b = page!([entry(404, "<p>site B</p>")])

    assert draw(a, 403) =~ "site A"
    assert capture_log(fn -> assert draw(b, 403) == "Forbidden" end) =~ b.site.name
    assert draw(b, 404) =~ "site B"
  end

  # Both are one failure of the page, as for a code: its whole module does not compile, or the draw
  # raises to the host, which answers its plain message.
  describe "a default entry that cannot be drawn" do
    test "leaves the Error Page uncompiled when it does not compile, as a 404 entry does" do
      for status <- [404, :default] do
        page = uncompiled!([entry(status, "<p>ok</p>")])
        break!(page, status, "<div :foo={@a}>x</div>")

        assert {:error, {:compilation_error, _reason}} = compile(page)
        assert CompileFailureState.failed?(page.module)
      end
    end

    test "raises to the caller when it raises, as a 404 entry does, the other entries drawn" do
      page =
        page!([
          entry(404, "<p>{@nothing_such}</p>"),
          entry(500, "<p>Broke</p>"),
          entry(:default, "<p>{@nothing_such}</p>")
        ])

      for status <- [404, 403], do: assert_raise(KeyError, fn -> draw(page, status) end)
      assert draw(page, 500) =~ "Broke"
    end
  end

  test "once it is compiled, a request the default entry answers reads and compiles nothing" do
    page = page!([entry(404, "<p>Not here</p>"), entry(:default, @default)])
    watch([@query, @compiled])

    assert {:ok, _module} = compile(page)
    assert draw(page, 403) =~ "403: Forbidden"
    assert draw(page, 406) =~ "406: Not Acceptable"

    refute_received {:heard, _event}
  end

  test "added to a compiled Error Page it answers, and removed it is gone, at the next compile" do
    page = page!([entry(404, "<p>Not here</p>")])
    capture_log(fn -> assert draw(page, 403) == "Forbidden" end)

    page = update!(page, [entry(404, "<p>Not here</p>"), entry(:default, @default)])
    assert draw(page, 403) =~ "403: Forbidden"

    page = update!(page, [entry(404, "<p>Not here</p>")])
    assert capture_log(fn -> assert draw(page, 403) == "Forbidden" end) =~ "missing error page"
    assert draw(page, 404) =~ "Not here"
  end

  defp entry(status, template), do: %{status: status, template: template}

  defp page!(entries, attrs \\ []) do
    page = uncompiled!(entries, attrs)
    assert {:ok, _module} = compile(page)
    page
  end

  defp uncompiled!(entries, attrs \\ []) do
    site = create_site!()

    record =
      ErrorPage
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(
          %{
            name: "#{site.name} errors",
            path: ErrorAddress.path(site.name),
            error_pages: entries
          },
          Map.new(attrs)
        ),
        tenant: site.id,
        authorize?: false
      )
      |> Ash.create!()

    module = Helpers.module_name(record.id, site.name, "ErrorPage")

    on_exit(fn ->
      ModuleCompiler.unload(module)
      CompileFailureState.clear(module)
    end)

    %{module: module, record: record, site: site}
  end

  defp update!(page, entries) do
    record =
      page.record
      |> Ash.Changeset.for_update(:update, %{error_pages: entries},
        tenant: page.site.id,
        authorize?: false
      )
      |> Ash.update!()

    assert {:ok, _module} = compile(page, :update)
    %{page | record: record}
  end

  # A template the write would refuse, as a row stored before it was checked holds it.
  defp break!(page, status, template) do
    repo = Application.fetch_env!(:mishka_cms_core, :repo)

    repo.query!("UPDATE error_pages SET error_pages = $1 WHERE id = $2", [
      [%{"status" => status, "template" => template}],
      Ecto.UUID.dump!(page.record.id)
    ])
  end

  defp compile(page, type \\ :new) do
    ModuleCompilerHandler.compile_or_return_module(
      page.module,
      page.record.path,
      page.site.name,
      page.site.id,
      type
    )
  end

  # As `ErrorHTML` draws the page of a failed request.
  defp draw(page, status) do
    page.module |> ErrorCompiler.render_page(conn(page), status) |> IO.iodata_to_binary()
  end

  defp conn(page),
    do: Plug.Conn.assign(Phoenix.ConnTest.build_conn(), :current_site, page.site)

  defp watch(events) do
    id = "error-default-entry-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach_many(id, events, &__MODULE__.heard/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end
end
