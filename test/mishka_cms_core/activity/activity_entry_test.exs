defmodule MishkaCmsCore.Activity.ActivityEntryTest do
  @moduledoc """
  The gervaz-backed activity resource: a manual read over `Ash.DataLayer.Simple`
  that merges the 3 sources, paginates through Ash, applies the gervaz filters
  carried in via `:gervaz_filters`, and scopes tenants to their own site.
  """
  use MishkaCmsCore.DataCase, async: false

  # Raw SQL here needs the same repo the resources write through.
  @repo Application.compile_env!(:mishka_cms_core, :repo)

  alias MishkaCmsCore.Activity.ActivityEntry
  alias MishkaGervaz.Table.Web.State

  defp read(filters, opts) do
    actor = Keyword.fetch!(opts, :actor)
    page = Keyword.get(opts, :page, offset: 0, limit: 25)

    ActivityEntry
    |> Ash.Query.for_read(:read, %{gervaz_filters: filters})
    |> Ash.read!(actor: actor, page: page)
  end

  # ActivityEntry is read by the admin's Activity page, so a reader holds the dashboard permission; a
  # master is such a user whose `site_id` is nil, a tenant one whose `site_id` is its site.
  defp master, do: create_user_with_permissions!(["admin:dashboard:*"])
  defp tenant(site), do: create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)

  defp archive!(record, site_id) do
    record
    |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site_id, authorize?: false)
    |> Ash.destroy!()
  end

  defp insert_oban_job!(resource, site_id) do
    sql =
      "INSERT INTO oban_jobs (state, queue, worker, args, completed_at, inserted_at, scheduled_at) " <>
        "VALUES ('completed', 'modules', $1, $2, now(), now(), now())"

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        @repo,
        sql,
        [
          "Elixir.MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker",
          %{"resource" => resource, "site_id" => site_id}
        ]
      )
  end

  describe "manual read + Ash pagination" do
    test "returns an Ash.Page.Offset of ActivityEntry records" do
      site = create_site!()
      create_component!(site_id: site.id, active: true)

      page = read(%{}, actor: master())

      assert %Ash.Page.Offset{} = page
      assert page.results != []
      assert Enum.all?(page.results, &match?(%ActivityEntry{}, &1))
      assert Enum.all?(page.results, &is_binary(&1.id))
    end

    test "offset paging advances to different rows" do
      site = create_site!()
      for i <- 1..6, do: create_component!(site_id: site.id, name: "paginate-#{i}", active: true)

      p1 = read(%{}, actor: master(), page: [offset: 0, limit: 2])
      p2 = read(%{}, actor: master(), page: [offset: 2, limit: 2])

      assert Enum.map(p1.results, & &1.id) != Enum.map(p2.results, & &1.id)
    end

    test "load_more is driven by more? (page_size+1 row), not an exact count" do
      site = create_site!()
      for i <- 1..5, do: create_component!(site_id: site.id, name: "cnt-#{i}", active: true)

      page = read(%{kind: "content"}, actor: tenant(site), page: [offset: 0, limit: 2])
      assert length(page.results) == 2
      assert page.more?

      next = read(%{kind: "content"}, actor: tenant(site), page: [offset: 2, limit: 2])
      assert Enum.map(page.results, & &1.id) != Enum.map(next.results, & &1.id)
    end
  end

  describe "filters carried in via :gervaz_filters" do
    test "kind=content keeps only content entries (versions/events, not jobs)" do
      site = create_site!()
      create_component!(site_id: site.id, active: true)

      page = read(%{kind: "content"}, actor: master())

      assert page.results != []
      assert Enum.all?(page.results, &(&1.kind == :content))
    end

    test "severity filter narrows to one severity" do
      site = create_site!()
      comp = create_component!(site_id: site.id, active: true)
      archive!(comp, site.id)

      warns = read(%{severity: "warn"}, actor: master())
      assert Enum.all?(warns.results, &(&1.severity == :warn))
      assert Enum.any?(warns.results, &(&1.action in [:destroy, :master_destroy]))
    end

    test "resource filter matches background jobs via args.resource, not the worker" do
      site = create_site!()
      comp = "Elixir.MishkaCmsCore.Runtime.Component"

      insert_oban_job!("MishkaCmsCore.Runtime.Component", site.id)

      jobs = read(%{kind: "job", resource: comp}, actor: master())
      assert Enum.any?(jobs.results, &(&1.kind == :job))

      other =
        read(%{kind: "job", resource: "Elixir.MishkaCmsCore.Runtime.Layout"},
          actor: master()
        )

      refute Enum.any?(other.results, &(&1.kind == :job))
    end

    test "out-of-enum filter values are coerced to nil (no crash) — DoS hardening" do
      site = create_site!()
      create_component!(site_id: site.id, active: true)

      # crafted URL filter values must NOT raise FunctionClauseError — they coerce
      # to nil (no filter) at the normalize_filters boundary
      assert %Ash.Page.Offset{} = read(%{severity: "evil"}, actor: master())
      assert %Ash.Page.Offset{} = read(%{kind: "evil"}, actor: master())

      assert %Ash.Page.Offset{} =
               read(%{severity: "'; DROP TABLE users; --"}, actor: master())
    end
  end

  describe "tenant scoping" do
    test "tenant sees own site + global, NEVER another tenant; master sees all" do
      site_a = create_site!(name: "scope-a", host: "scope-a.test")
      site_b = create_site!(name: "scope-b", host: "scope-b.test")
      create_component!(site_id: site_a.id, name: "a-comp", active: true)
      create_component!(site_id: site_b.id, name: "b-comp", active: true)

      tenant_a = read(%{}, actor: tenant(site_a))
      assert tenant_a.results != []
      # own site OR global (nil) only — and crucially never another tenant's site
      assert Enum.all?(tenant_a.results, &(&1.site_id == site_a.id or is_nil(&1.site_id)))
      refute Enum.any?(tenant_a.results, &(&1.site_id == site_b.id))

      master = read(%{}, actor: master())
      master_sites = master.results |> Enum.map(& &1.site_id) |> Enum.uniq()
      assert site_a.id in master_sites
      assert site_b.id in master_sites
    end
  end

  # A MASTER IS A USER WHOSE `site_id` IS NIL — never no user, never a map that names no site.
  describe "who may read the log" do
    test "no user, and a user without the dashboard permission, are refused" do
      site = create_site!()
      create_component!(site_id: site.id, active: true)
      nobody = create_user!(site_id: site.id)

      for actor <- [nil, nobody] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 ActivityEntry
                 |> Ash.Query.for_read(:read, %{gervaz_filters: %{}})
                 |> Ash.read(actor: actor, page: [offset: 0, limit: 5])
      end
    end

    test "a viewer that is not a user reads nothing, even without authorization" do
      site = create_site!()
      create_component!(site_id: site.id, active: true)

      for viewer <- [%{}, %{id: Ecto.UUID.generate()}] do
        assert %Ash.Page.Offset{results: []} =
                 ActivityEntry
                 |> Ash.Query.for_read(:read, %{gervaz_filters: %{}})
                 |> Ash.read!(actor: viewer, authorize?: false, page: [offset: 0, limit: 5])
      end

      for viewer <- [nil, %{}, %{id: Ecto.UUID.generate()}] do
        assert ActivityEntry.total(%{current_user: viewer, filter_values: %{}}) == 0
      end
    end

    # THE SYSTEM IS EXEMPT, as it is everywhere: a read with no actor and `authorize?: false` is a
    # call the code makes on its own, and it reads every site's log.
    test "the system reads every site's log" do
      site_a = create_site!()
      site_b = create_site!()
      create_component!(site_id: site_a.id, active: true)
      create_component!(site_id: site_b.id, active: true)

      sites =
        ActivityEntry
        |> Ash.Query.for_read(:read, %{gervaz_filters: %{}})
        |> Ash.read!(actor: nil, authorize?: false, page: [offset: 0, limit: 100])
        |> Map.fetch!(:results)
        |> MapSet.new(& &1.site_id)

      assert MapSet.member?(sites, site_a.id)
      assert MapSet.member?(sites, site_b.id)
    end
  end

  describe "gervaz table integration" do
    test "State.init resolves the custom template, columns and filters" do
      state = State.init("activity", ActivityEntry, %{id: "u", site_id: nil, role: :admin})

      assert state.template == MishkaCmsCoreWeb.Templates.ActivityTimeline
      assert length(state.static.columns) == 4
      assert length(state.static.filters) == 4
      assert state.master_user?
    end

    test "tenant State.init flags master_user? false" do
      site = create_site!()
      state = State.init("activity", ActivityEntry, %{id: "u", site_id: site.id, role: :user})
      refute state.master_user?
    end
  end

  describe "actor + site resolution (the render-helper lookups)" do
    test "actor_name: master sees any email; tenant sees same-site, Master for a master" do
      site = create_site!()
      other = create_site!(name: "other-actor", host: "other-actor.test")
      user = create_user!(site_id: site.id)
      master = create_user!(site_id: nil)
      email = to_string(user.email)

      # master viewer sees ANY actor's email
      assert ActivityEntry.actor_name(user.id, %{site_id: nil}) == email
      assert ActivityEntry.actor_name(master.id, %{site_id: nil}) == to_string(master.email)

      # tenant sees its own-site user's email
      assert ActivityEntry.actor_name(user.id, %{site_id: site.id}) == email

      # master edited the tenant's component → tenant sees "Master", NOT master's email
      assert ActivityEntry.actor_name(master.id, %{site_id: site.id}) == "Master"

      # tenant never sees another site's user, and nil actor is always System
      assert ActivityEntry.actor_name(user.id, %{site_id: other.id}) == "Unknown"
      assert ActivityEntry.actor_name(Ash.UUID.generate(), %{site_id: nil}) == "Unknown"
      assert ActivityEntry.actor_name(nil, %{site_id: nil}) == "System"
    end

    test "actor emails load for a master or the actor's own site, and for nobody else" do
      site = create_site!()
      user = create_user!(site_id: site.id)
      email = to_string(user.email)

      assert %{email: ^email} =
               MishkaCmsCore.Activity.Query.actor_emails([user.id], %{site_id: nil})[user.id]

      assert Map.has_key?(
               MishkaCmsCore.Activity.Query.actor_emails([user.id], %{site_id: site.id}),
               user.id
             )

      for nobody <- [nil, %{}, %{id: Ecto.UUID.generate()}] do
        assert MishkaCmsCore.Activity.Query.actor_emails([user.id], nobody) == %{}
      end
    end

    test "site_name resolves a real site and labels nil as Global" do
      site = create_site!(name: "named-site", host: "named-site.test")
      assert ActivityEntry.site_name(site.id) == "named-site"
      assert ActivityEntry.site_name(nil) == "Global"
    end
  end

  describe "global sharing per resource (Query.shares_globals?/1)" do
    alias MishkaCmsCore.Activity.Query

    test "only runtime resources that share globals with tenants are marked" do
      # These expose :for_tenant_with_globals (their admin pages show globals to tenants)
      assert Query.shares_globals?(MishkaCmsCore.Runtime.Component)
      assert Query.shares_globals?(MishkaCmsCore.Runtime.Layout)
      assert Query.shares_globals?(MishkaCmsCore.Runtime.JsHook)
      assert Query.shares_globals?(MishkaCmsCore.Runtime.Stylesheet)

      # These do NOT — tenants must never see their globals
      refute Query.shares_globals?(MishkaCmsCore.Runtime.Page)
      refute Query.shares_globals?(MishkaCmsCore.Runtime.ErrorPage)
      refute Query.shares_globals?(MishkaCmsCore.Runtime.Media)
      refute Query.shares_globals?(MishkaCmsCore.Runtime.MediaCategory)

      if Code.ensure_loaded?(MishkaBlog.BlogPost),
        do: refute(Query.shares_globals?(MishkaBlog.BlogPost))
    end
  end

  describe "realtime (the on_realtime hook + from_entry)" do
    defp rt_entry(attrs) do
      Map.merge(
        %{
          id: "pt-x-create-1",
          resource_label: "Component",
          action: :create,
          severity: :info,
          inserted_at: ~U[2026-05-31 00:00:00Z],
          source_id: "s",
          site_id: nil,
          user_id: nil,
          message: "Component created",
          badge_label: "CREATE",
          badge_tone: :emerald
        },
        attrs
      )
    end

    # The stream is named after the TABLE, not the resource — gervaz scopes the key by table id so two
    # tables on one page cannot collide, which makes this `:rt_activity_logs` for a table called "rt".
    # Read the name off the state rather than hardcoding it, or this drifts the next time it changes.
    defp mock_socket(state) do
      name = state.static.stream_name

      stream = %Phoenix.LiveView.LiveStream{
        name: name,
        dom_id: fn item -> "activity-#{item.id}" end,
        ref: make_ref(),
        inserts: [],
        deletes: [],
        reset?: false,
        consumable?: false
      }

      %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          table_state: state,
          streams: %{:__changed__ => MapSet.new(), :__ref__ => 0, name => stream}
        }
      }
    end

    defp inserts(socket, state),
      do: socket.assigns.streams |> Map.fetch!(state.static.stream_name) |> Map.fetch!(:inserts)

    defp notification(entry) do
      %Ash.Notifier.Notification{
        resource: ActivityEntry,
        action: %{name: :create, type: :create},
        data: ActivityEntry.from_entry(entry)
      }
    end

    test "from_entry/1 builds a struct and derives kind" do
      assert %ActivityEntry{kind: :content, message: "Component created"} =
               ActivityEntry.from_entry(rt_entry(%{id: "pt-1"}))

      assert %ActivityEntry{kind: :job} = ActivityEntry.from_entry(rt_entry(%{id: "oban-1"}))
    end

    test "on_realtime inserts a visible entry at the top and halts" do
      state = State.init("rt", ActivityEntry, %{id: "u", site_id: nil, role: :admin})
      hook = state.static.hooks[:on_realtime]

      assert {:halt, socket} =
               hook.(notification(rt_entry(%{site_id: "site-1"})), mock_socket(state))

      assert inserts(socket, state) != []
    end

    test "on_realtime drops another site's entry for a tenant" do
      state = State.init("rt", ActivityEntry, %{id: "u", site_id: "site-1", role: :user})
      hook = state.static.hooks[:on_realtime]

      assert {:halt, socket} =
               hook.(notification(rt_entry(%{site_id: "site-2"})), mock_socket(state))

      assert inserts(socket, state) == []
    end

    test "on_realtime drops a global entry for a tenant (live feed is own-site-scoped)" do
      state = State.init("rt", ActivityEntry, %{id: "u", site_id: "site-1", role: :user})
      hook = state.static.hooks[:on_realtime]

      assert {:halt, socket} =
               hook.(notification(rt_entry(%{site_id: nil})), mock_socket(state))

      assert inserts(socket, state) == []
    end

    test "on_realtime respects the active filter (a non-matching entry is dropped)" do
      base = State.init("rt", ActivityEntry, %{id: "u", site_id: nil, role: :admin})
      state = %{base | filter_values: %{severity: "warn"}}
      hook = state.static.hooks[:on_realtime]

      # severity=warn filter active → an :info entry must NOT be inserted
      assert {:halt, info_socket} =
               hook.(
                 notification(rt_entry(%{id: "pt-info", severity: :info})),
                 mock_socket(state)
               )

      assert inserts(info_socket, state) == []

      # ...but a matching :warn entry IS inserted
      assert {:halt, warn_socket} =
               hook.(
                 notification(rt_entry(%{id: "pt-warn", severity: :warn})),
                 mock_socket(state)
               )

      assert inserts(warn_socket, state) != []
    end
  end
end
