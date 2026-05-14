defmodule MishkaCmsCore.Test.Activity.ActivityFeedTest do
  @moduledoc """
  The `ActivityFeed` component's own contract, driven through a host LiveView
  (`MishkaCmsCore.Test.ActivityFeedHostLive`) over a stub source, so the feed's
  composition — parent wiring, history merge, live forwarding, and the panel's
  own open/load behaviour — is asserted without a database.

  The lower-level `topics_for/3` + `first_source_entry/2` pair is covered too:
  the standalone activity log page drives those directly instead of `setup/2`.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Test.ActivityStubSource, as: Stub
  alias MishkaCmsCoreWeb.Live.Admin.Components.ActivityFeed
  alias Phoenix.LiveView.JS

  @built_in_sources [
    MishkaCmsCore.Activity.Sources.PaperTrail,
    MishkaCmsCore.Activity.Sources.EventLog,
    MishkaCmsCore.Activity.Sources.Oban,
    MishkaCmsCore.Activity.Sources.RuntimeCompile,
    MishkaCmsCore.Activity.Sources.RuntimeDraft
  ]

  @stub_opts [
    sources: [MishkaCmsCore.Test.ActivityStubSource],
    feed_id: "test-activity",
    limit: 2
  ]

  setup do
    Stub.put_entries([])
    Stub.put_topics(["stub:created"])
    Stub.block_fetch(nil)
    :ok
  end

  # The feed is read by a master unless a test says otherwise: a master is a user whose `site_id` is
  # nil, and a page with no user on it is shown no live entry at all.
  defp host(conn, opts \\ @stub_opts, on_toggle \\ %JS{}, viewer \\ :master) do
    live_isolated(conn, MishkaCmsCore.Test.ActivityFeedHostLive,
      session: %{"opts" => opts, "on_toggle" => on_toggle, "current_user" => viewer(viewer)}
    )
  end

  defp viewer(:master), do: MishkaCmsCore.Test.Factory.create_user_with_permissions!(["*"])
  defp viewer(user_or_nobody), do: user_or_nobody

  defp broadcast(entry) do
    %Phoenix.Socket.Broadcast{topic: "stub:created", event: "create", payload: %{entry: entry}}
  end

  defp config(view, key) do
    view
    |> element("#feed-config")
    |> render()
    |> then(&Regex.run(~r/data-#{key}="([^"]*)"/, &1))
    |> Enum.at(1)
  end

  describe "setup/2" do
    test "assigns the feed config with the documented defaults", %{conn: conn} do
      {:ok, view, _html} = host(conn, [])

      assert config(view, "feed-id") == "activity-feed"
      assert config(view, "limit") == "5"
      assert config(view, "resources") == "nil"
      assert config(view, "sources") == inspect(@built_in_sources)
    end

    test "honours :feed_id, :resources, :sources and :limit", %{conn: conn} do
      {:ok, view, _html} =
        host(conn,
          feed_id: "components-activity",
          resources: [MishkaCmsCore.Runtime.Component],
          sources: [Stub],
          limit: 10
        )

      assert config(view, "feed-id") == "components-activity"
      assert config(view, "limit") == "10"
      assert config(view, "resources") == inspect([MishkaCmsCore.Runtime.Component])
      assert config(view, "sources") == inspect([Stub])
    end

    test "renders the feed under the configured id", %{conn: conn} do
      {:ok, view, _html} = host(conn)

      assert has_element?(view, "#test-activity-feed")
    end
  end

  describe "opening the panel" do
    test "fetches nothing until the panel is first opened", %{conn: conn} do
      Stub.put_entries([Stub.entry(id: "a", message: "only after opening")])

      {:ok, view, html} = host(conn)

      refute html =~ "only after opening"
      refute render(view) =~ "only after opening"

      open_logs(view)

      assert render_async(view) =~ "only after opening"
    end

    test "shows skeleton rows while the fetch is in flight, then the rows", %{conn: conn} do
      Stub.put_entries([Stub.entry(id: "a", message: "loaded at last")])
      Stub.block_fetch(self())

      {:ok, view, _html} = host(conn)

      open_logs(view)
      assert_receive {:fetching, task}

      assert has_element?(view, "#test-activity-skeleton")
      refute render(view) =~ "loaded at last"

      send(task, :release)
      assert render_async(view) =~ "loaded at last"
      refute has_element?(view, "#test-activity-skeleton")
    end

    test "reopening does not refetch", %{conn: conn} do
      Stub.put_entries([Stub.entry(id: "a", message: "first fetch")])

      {:ok, view, _html} = host(conn)

      open_logs(view)
      assert render_async(view) =~ "first fetch"

      Stub.put_entries([Stub.entry(id: "b", message: "second fetch")])
      open_logs(view)
      open_logs(view)

      assert render(view) =~ "first fetch"
      refute render(view) =~ "second fetch"
    end
  end

  describe "history" do
    test "loads the source's entries and renders them once opened", %{conn: conn} do
      Stub.put_entries([Stub.entry(id: "a", message: "Workspace \"Q1\" created")])

      {:ok, view, _html} = host(conn)

      open_logs(view)

      assert render_async(view) =~ "Workspace &quot;Q1&quot; created"
    end

    test "merges, sorts newest first and caps at the limit", %{conn: conn} do
      Stub.put_entries([
        Stub.entry(id: "old", message: "oldest", inserted_at: ~U[2026-01-01 00:00:00Z]),
        Stub.entry(id: "new", message: "newest", inserted_at: ~U[2026-03-01 00:00:00Z]),
        Stub.entry(id: "mid", message: "middle", inserted_at: ~U[2026-02-01 00:00:00Z])
      ])

      {:ok, view, _html} = host(conn)

      open_logs(view)
      html = render_async(view)

      assert html =~ "newest"
      assert html =~ "middle"
      refute html =~ "oldest"
    end
  end

  describe "live forwarding" do
    test "a broadcast a source claims lands in the open feed", %{conn: conn} do
      {:ok, view, _html} = host(conn)

      open_logs(view)
      send(view.pid, broadcast(Stub.entry(id: "live-1", message: "arrived live")))

      assert render_async(view) =~ "arrived live"
    end

    test "an entry arriving before the first open survives the opening fetch", %{conn: conn} do
      Stub.put_entries([])

      {:ok, view, _html} = host(conn)

      send(view.pid, broadcast(Stub.entry(id: "ephemeral", message: "compiled live")))
      assert view |> element("#test-activity-toggle") |> render() =~ "1"

      open_logs(view)

      assert render_async(view) =~ "compiled live"
    end

    test "a page with no user on it is shown no live entry", %{conn: conn} do
      {:ok, view, _html} = host(conn, @stub_opts, %JS{}, nil)

      open_logs(view)
      send(view.pid, broadcast(Stub.entry(id: "live-nobody", message: "for nobody")))

      refute render_async(view) =~ "for nobody"
    end

    test "a broadcast no source claims is ignored without crashing the page", %{conn: conn} do
      {:ok, view, _html} = host(conn)

      send(view.pid, %Phoenix.Socket.Broadcast{
        topic: "other:created",
        event: "create",
        payload: %{}
      })

      assert render(view) =~ "Logs"
    end
  end

  describe "topics_for/3 and first_source_entry/2" do
    test "topics_for fans out over every source's topics" do
      Stub.put_topics(["stub:a", "stub:b"])

      assert ActivityFeed.topics_for(nil, [Stub], nil) == ["stub:a", "stub:b"]
    end

    # A MASTER IS A USER WHOSE `site_id` IS NIL. Every built-in source subscribes a viewer that is not
    # a user to nothing, rather than to every site's topics.
    test "the built-in sources give no viewer, and no non-user, any topic" do
      sources = [
        MishkaCmsCore.Activity.Sources.PaperTrail,
        MishkaCmsCore.Activity.Sources.EventLog,
        MishkaCmsCore.Activity.Sources.Oban,
        MishkaCmsCore.Activity.Sources.RuntimeCompile,
        MishkaCmsCore.Activity.Sources.RuntimeDraft
      ]

      for viewer <- [nil, %{}], resources <- [nil, [MishkaCmsCore.Runtime.Component]] do
        assert ActivityFeed.topics_for(viewer, sources, resources) == []
      end

      assert ActivityFeed.topics_for(%{site_id: nil}, sources, [MishkaCmsCore.Runtime.Component]) !=
               []
    end

    test "handles? is true only when a source claims the broadcast" do
      assert ActivityFeed.handles?(broadcast(Stub.entry()), [Stub])

      refute ActivityFeed.handles?(
               %Phoenix.Socket.Broadcast{topic: "other:created", event: "create", payload: %{}},
               [Stub]
             )
    end

    test "first_source_entry returns the first claiming source's entry" do
      entry = Stub.entry(id: "from-live")

      assert ActivityFeed.first_source_entry(broadcast(entry), [Stub]) == entry
    end

    test "first_source_entry returns nil when no source claims the broadcast" do
      msg = %Phoenix.Socket.Broadcast{topic: "other:created", event: "create", payload: %{}}

      assert ActivityFeed.first_source_entry(msg, [Stub]) == nil
    end
  end

  describe "fetch_recent_activity/3" do
    test "merges sources, sorts newest first and caps at the limit" do
      Stub.put_entries([
        Stub.entry(id: "old", inserted_at: ~U[2026-01-01 00:00:00Z]),
        Stub.entry(id: "new", inserted_at: ~U[2026-03-01 00:00:00Z]),
        Stub.entry(id: "mid", inserted_at: ~U[2026-02-01 00:00:00Z])
      ])

      entries = ActivityFeed.fetch_recent_activity([Stub], %{current_user: nil}, 2)

      assert Enum.map(entries, & &1.id) == ["new", "mid"]
    end

    test "returns [] when a source has no history" do
      assert ActivityFeed.fetch_recent_activity([Stub], %{current_user: nil}, 5) == []
    end
  end

  describe "pairing with a page's own panel" do
    test "close_panel/2 hides the panel and pushes at the feed's root, not the page", %{
      conn: conn
    } do
      {:ok, view, _html} = host(conn)

      assert [["hide", hide], ["push", push]] =
               ActivityFeed.close_panel(%{id: "test-activity"}).ops

      assert hide.to == "#test-activity-panel"
      assert push == %{event: "close_logs", target: "#test-activity-feed"}

      # The push is aimed by selector, so the element it names has to be the feed's own root for the
      # event to reach the component rather than the page hosting it.
      assert has_element?(view, "#test-activity-feed")
    end

    test "close_logs shuts an open panel and leaves a shut one alone", %{conn: conn} do
      {:ok, view, _html} = host(conn)

      open_logs(view)
      assert logs_open?(view)

      close_logs(view)
      refute logs_open?(view)

      # A page fires this on every open of its own panel, so a second one must not flip it back.
      close_logs(view)
      refute logs_open?(view)
    end

    test "close_logs keeps the fetched history, so reopening does not refetch", %{conn: conn} do
      Stub.put_entries([Stub.entry(id: "a", message: "first fetch")])

      {:ok, view, _html} = host(conn)

      open_logs(view)
      assert render_async(view) =~ "first fetch"

      close_logs(view)
      Stub.put_entries([Stub.entry(id: "b", message: "second fetch")])
      open_logs(view)

      assert render(view) =~ "first fetch"
      refute render(view) =~ "second fetch"
    end

    test "the toggle carries the page's on_toggle ahead of its own", %{conn: conn} do
      {:ok, view, _html} = host(conn, @stub_opts, JS.push("close_issues"))

      toggle = view |> element("#test-activity-toggle") |> render()

      assert toggle =~ "close_issues"
      assert toggle =~ "toggle_logs"
    end

    test "a page passing no on_toggle gets the bare toggle", %{conn: conn} do
      {:ok, view, _html} = host(conn)

      toggle = view |> element("#test-activity-toggle") |> render()

      refute toggle =~ "close_issues"
      assert toggle =~ "toggle_logs"
    end
  end

  # Who did something is named by the account's email, and only for accounts the viewer may see: a
  # site's admin its own site's accounts, "Master" for a master and "Unknown" for another site's
  # account, never either one's email. A master names every account. The feed loads the names of the
  # actors on its entries with `Helpers.actor_labels/2` and draws them under each entry.
  describe "who each entry names" do
    import MishkaCmsCore.Test.Factory

    alias MishkaCmsCore.Activity.Helpers

    setup do
      site = create_site!()

      accounts = %{
        master: create_user_with_permissions!(["*"], email: "the.master@example.com"),
        admin:
          create_user_with_permissions!(["*"], email: "admin.a@example.com", site_id: site.id),
        writer: create_user!(email: "writer.a@example.com", site_id: site.id),
        elsewhere: create_user!(email: "writer.b@example.com", site_id: create_site!().id)
      }

      Stub.put_entries(
        for {{who, account}, day} <- Enum.with_index(accounts, 1) do
          Stub.entry(
            id: "by-#{who}",
            user_id: account.id,
            inserted_at: DateTime.add(~U[2026-01-01 00:00:00Z], day, :day)
          )
        end ++ [Stub.entry(id: "by-nobody", user_id: nil)]
      )

      Map.put(accounts, :ids, Enum.map(accounts, fn {_who, account} -> account.id end))
    end

    test "a site's admin reads its own site's accounts, Master and Unknown", ctx do
      view = open_feed_as(ctx.conn, ctx.admin)

      assert actor(view, "by-writer") == "writer.a@example.com"
      assert actor(view, "by-admin") == "admin.a@example.com"
      assert actor(view, "by-master") == "Master"
      assert actor(view, "by-elsewhere") == "Unknown"
      assert actor(view, "by-nobody") == "System"

      html = render(view)
      refute html =~ "the.master"
      refute html =~ "writer.b"

      assert Helpers.actor_labels(ctx.ids, ctx.admin) == %{
               ctx.master.id => "Master",
               ctx.admin.id => "admin.a@example.com",
               ctx.writer.id => "writer.a@example.com",
               ctx.elsewhere.id => "Unknown"
             }
    end

    test "a master reads every account's email, masters included", ctx do
      view = open_feed_as(ctx.conn, ctx.master)

      assert actor(view, "by-master") == "the.master@example.com"
      assert actor(view, "by-admin") == "admin.a@example.com"
      assert actor(view, "by-writer") == "writer.a@example.com"
      assert actor(view, "by-elsewhere") == "writer.b@example.com"
      assert actor(view, "by-nobody") == "System"
    end
  end

  # Opening fetches off the LiveView — the entries, and the site and actor names the viewer may see —
  # so an assertion on what the fetch brought waits for it with `render_async/1`.
  defp open_logs(view) do
    view |> element("#test-activity-toggle") |> render_click()
  end

  # Aimed the way `close_panel/2` aims it: at the feed's root element by selector.
  defp close_logs(view) do
    view |> with_target("#test-activity-feed") |> render_click("close_logs", %{})
  end

  defp logs_open?(view) do
    view |> element("#test-activity-toggle") |> render() =~ ~s(aria-expanded="true")
  end

  defp open_feed_as(conn, viewer) do
    {:ok, view, _html} = host(conn, Keyword.put(@stub_opts, :limit, 5), %JS{}, viewer)
    open_logs(view)
    render_async(view)
    view
  end

  # The name drawn under an entry, beside the actor icon.
  defp actor(view, entry_id) do
    view
    |> element("#activity-#{entry_id}-actor")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end
end
