# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.BuilderLive.CanvasCssRefreshTest do
  @moduledoc """
  The canvas after the CSS it was opened with is rebuilt.

  The frame links its bundle from the root layout's `<head>`, which a LiveView never patches, so a
  frame used to keep the colours it was opened with: a token set in the Studio reached the published
  page and showed nowhere in the editor until it was opened again. A rebuild is announced on the
  bundle's topic, and the frame answers with the live page's own swap, `mishka:css-updated` (the
  host's `css_swap.js`), which keeps the old sheet until the newer one has loaded and keeps it for
  good if the newer one fails. Nothing else in the frame changes.

  The test endpoint renders a bare layout, so the link and the script are not observable here; the
  event the frame pushes is.
  """
  use MishkaCmsCore.BuilderLiveCase

  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use Oban.Testing, repo: @repo

  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler
  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.States.AssetsState
  alias MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker

  @shared "__shared_base__"
  @a String.duplicate("a", 32)
  @b String.duplicate("b", 32)
  @c String.duplicate("c", 32)

  setup %{site: site} do
    on_exit(fn ->
      for id <- [@shared, site.name],
          type <- ~w(css brotli_css gzip_css),
          do: AssetsState.delete(id, type)
    end)
  end

  defp bundle!(id, hash, value \\ ".x{}") do
    :ok =
      AssetsState.save(%{
        id: id,
        type: "css",
        value: value,
        hash: hash,
        updated_at: DateTime.utc_now()
      })
  end

  defp rebuilt(id),
    do: Phoenix.PubSub.broadcast(MishkaCmsCore.PubSub, "site:#{id}:assets", {:css_updated, "new"})

  defp canvas(conn, view) do
    {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
    {canvas, html}
  end

  defp href(id, hash), do: "/assets/css/#{id}/#{hash}.css"

  describe "a frame that links its bundle" do
    setup %{conn: conn, page: page} do
      bundle!(@shared, @a)
      {:ok, view, _html} = open_builder(conn, page)
      {canvas, html} = canvas(conn, view)
      %{canvas: canvas, html: html}
    end

    # The bundle can be rebuilt between the first render and the socket, and a socket can reconnect
    # after a rebuild it missed; the swap ignores an address it already links.
    test "points the link at its bundle when it connects", %{canvas: canvas} do
      assert_push_event(canvas, "mishka:css-updated", %{href: href})
      assert href == href(@shared, @a)
      assert css_hrefs(canvas) == [href(@shared, @a)]
    end

    test "moves the link to the rebuilt bundle", %{canvas: canvas, site: site} do
      assert_push_event(canvas, "mishka:css-updated", _connect)

      bundle!(@shared, @b)
      rebuilt(site.name)

      assert_push_event(canvas, "mishka:css-updated", %{href: href})
      assert href == href(@shared, @b)
    end

    # Undoing a change gives the same bytes and the same address back.
    test "follows every rebuild, back to an address it had before", %{
      canvas: canvas,
      site: site
    } do
      assert_push_event(canvas, "mishka:css-updated", _connect)

      for hash <- [@b, @a] do
        bundle!(@shared, hash)
        rebuilt(site.name)
        expected = href(@shared, hash)
        assert_push_event(canvas, "mishka:css-updated", %{href: ^expected})
      end
    end

    test "moves to the site's own bundle once the site has one", %{canvas: canvas, site: site} do
      assert_push_event(canvas, "mishka:css-updated", _connect)

      bundle!(site.name, @c)
      rebuilt(site.name)

      expected = href(site.name, @c)
      assert_push_event(canvas, "mishka:css-updated", %{href: ^expected})
    end

    # A site that has never compiled — or is switched off, so its own builds are skipped — is drawn
    # with the shared base, and only the base's rebuild can move it.
    test "follows the shared base while the site has no bundle", %{canvas: canvas} do
      assert_push_event(canvas, "mishka:css-updated", _connect)

      bundle!(@shared, @b)
      rebuilt(@shared)

      expected = href(@shared, @b)
      assert_push_event(canvas, "mishka:css-updated", %{href: ^expected})
    end

    test "pushes nothing when the address did not change", %{canvas: canvas, site: site} do
      assert_push_event(canvas, "mishka:css-updated", _connect)

      rebuilt(site.name)
      rebuilt(@shared)

      refute_push_event(canvas, "mishka:css-updated", _any, 50)
    end

    test "ignores another site's rebuild", %{canvas: canvas} do
      assert_push_event(canvas, "mishka:css-updated", _connect)

      bundle!(@shared, @b)
      rebuilt("another-site")

      refute_push_event(canvas, "mishka:css-updated", _any, 50)
    end

    # The generator resolves a typed class through the kit's `@theme`, and the variables it already
    # emitted would beat the new bundle's, so a theme saved since the frame opened has to reach it.
    test "reads the kit's @theme again", %{canvas: canvas, html: html, site: site} do
      refute html =~ "--color-natural-refresh"

      MishkaCmsCore.Runtime.Stylesheet
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "refresh-theme",
          content: "@theme { --color-natural-refresh: #abcdef; }",
          kind: :theme,
          active: true
        },
        tenant: site.id,
        authorize?: false
      )
      |> Ash.create!()

      rebuilt(site.name)

      assert render(canvas) =~ "--color-natural-refresh: #abcdef;"
    end

    # THE AUTHOR'S WORK STAYS PUT. Only the stylesheet moves: no remount, no reload of the frame, the
    # document and the selection exactly as they were.
    test "touches nothing but the CSS", %{canvas: canvas, site: site} do
      before = :sys.get_state(canvas.pid).socket.assigns

      bundle!(@shared, @b)
      rebuilt(site.name)
      _ = render(canvas)

      now = :sys.get_state(canvas.pid).socket.assigns

      for key <- [:tree, :selection, :locked, :hidden, :pinned, :revision, :element_css],
          do: assert(Map.get(now, key) == Map.get(before, key), "#{key} changed")

      assert Process.alive?(canvas.pid)
    end

    test "a frame whose session is gone ignores the rebuild", %{canvas: canvas, site: site} do
      assert_push_event(canvas, "mishka:css-updated", _connect)
      EditorSession.close(:sys.get_state(canvas.pid).socket.assigns.token)

      bundle!(@shared, @b)
      rebuilt(site.name)

      refute_push_event(canvas, "mishka:css-updated", _any, 50)
      assert Process.alive?(canvas.pid)
    end
  end

  # A site that has never compiled has bytes and no hash, so its frame inlines them: there is no link
  # to move, and the bytes are read again in place.
  test "a frame that inlines its bundle reads it again", %{conn: conn, page: page, site: site} do
    bundle!(@shared, nil, ".before-rebuild{color:#111111}")
    {:ok, view, _html} = open_builder(conn, page)
    {canvas, html} = canvas(conn, view)
    assert html =~ ".before-rebuild"

    bundle!(@shared, nil, ".after-rebuild{color:#222222}")
    rebuilt(site.name)

    html = render(canvas)
    assert html =~ ".after-rebuild{color:#222222}"
    refute html =~ ".before-rebuild"
    refute_push_event(canvas, "mishka:css-updated", _any, 50)
  end

  # A FRAME DRAWN BEFORE ANYTHING COMPILED takes the link once a bundle has an address — the root
  # layout keeps an empty one in place for it — and drops the inlined copy, which sits in `<body>`
  # after the generator and would overrule what the author types.
  test "an inlined frame takes the link once a bundle has an address", %{
    conn: conn,
    page: page,
    site: site
  } do
    bundle!(@shared, nil, ".before-compile{color:#111111}")
    {:ok, view, _html} = open_builder(conn, page)
    {canvas, html} = canvas(conn, view)
    assert html =~ ".before-compile"

    bundle!(@shared, @a)
    rebuilt(site.name)

    expected = href(@shared, @a)
    assert_push_event(canvas, "mishka:css-updated", %{href: ^expected})
    refute render(canvas) =~ ".before-compile", "the inlined copy stayed in the body"
  end

  # A global layout belongs to no site, so its frame is drawn with the shared base alone.
  test "a document no site owns follows the shared base", %{conn: conn} do
    bundle!(@shared, @a)

    layout =
      create_layout!(site_id: nil, template: ~s(<main id="shared-layout">{@inner_content}</main>))

    {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")
    {canvas, _html} = canvas(conn, view)
    assert_push_event(canvas, "mishka:css-updated", _connect)

    bundle!(@shared, @b)
    rebuilt(@shared)

    expected = href(@shared, @b)
    assert_push_event(canvas, "mishka:css-updated", %{href: ^expected})
  end

  # The wizard's preview is the same canvas over a composed component, so it follows the bundle too.
  test "the wizard's preview follows its bundle", %{conn: conn, page: page, site: site} do
    bundle!(@shared, @a)
    define_component!("refreshing", site, "<div>refreshing</div>")
    create_component!(site_id: site.id, name: "refreshing", template: "<div>refreshing</div>")

    {:ok, view, _html} = open_builder(conn, page)

    {:ok, preview, _html} =
      live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}/wizard/refreshing")

    assert_push_event(preview, "mishka:css-updated", _connect)

    bundle!(@shared, @b)
    rebuilt(site.name)

    expected = href(@shared, @b)
    assert_push_event(preview, "mishka:css-updated", %{href: ^expected})
  end

  # THE WHOLE PATH, with nothing stood in for: a token set in the Studio, the row's job, the site's
  # bundle job building with the real Tailwind binary, and the open frame pointed at what it built.
  @tag :integration
  test "a token set in the Studio reaches the open frame", %{conn: conn, page: page, site: site} do
    Application.put_env(:mishka_cms_core, :env_test?, false)
    on_exit(fn -> Application.put_env(:mishka_cms_core, :env_test?, true) end)

    MishkaCmsCore.Runtime.Stylesheet
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "refresh-tokens",
        content: ":root {\n  --refresh-ink: #111111;\n}\n",
        kind: :theme,
        active: true
      },
      tenant: site.id,
      authorize?: false
    )
    |> Ash.create!()

    TailwindCompiler.ensure_installed()
    {:ok, _css} = TailwindCompiler.compile_and_store(site.name)
    @repo.delete_all(Oban.Job)

    view = open_studio(conn, page)
    {canvas, _html} = canvas(conn, view)
    assert_push_event(canvas, "mishka:css-updated", %{href: before})

    render_click(view, "set_token", %{"key" => "refresh-ink", "value" => "#13579b"})

    for %{args: %{"resource" => "MishkaCmsCore.Runtime.Stylesheet"} = args} <-
          all_enqueued(worker: RuntimeCompilerWorker),
        do: assert(:ok = perform_job(RuntimeCompilerWorker, args))

    assert [bundle] =
             for(
               %{args: %{"data" => %{"site_name" => "localhost", "type" => "css"}} = args} <-
                 all_enqueued(worker: RuntimeCompilerWorker),
               do: args
             )

    assert {:ok, css} = perform_job(RuntimeCompilerWorker, bundle)
    assert css =~ ~r/--refresh-ink:\s*#13579b/

    assert_push_event(canvas, "mishka:css-updated", %{href: now})
    assert now != before
    assert now =~ ~r|^/assets/css/localhost/[0-9a-f]{32}\.css$|, "css_swap.js would refuse it"
    assert now == href(site.name, AssetsState.hash(site.name, "css"))
  end
end
