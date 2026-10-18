# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Notify.DeliveryTest do
  @moduledoc """
  Phase 1 — core delivery, tenancy, per-user privacy, and real-time.

  Deterministic and synchronous: `config :mishka_cms, :env_test?, true` runs the fan-out inline,
  so unbounded audiences exercise the real streaming/batching path without Oban draining.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Notify
  alias MishkaCmsCore.Notify.Notification

  @content %{type: "test:event:created", title: "Something happened", severity: :info}

  # ── helpers ────────────────────────────────────────────────────────────────

  defp with_permission(user, permission) do
    user
    |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [permission.id]},
      authorize?: false
    )
    |> Ash.update!()
  end

  defp feed(user) do
    Notification
    |> Ash.Query.for_read(:feed)
    |> Ash.read!(actor: user, tenant: user.site_id, page: false)
  end

  defp unseen_count(user) do
    Notification
    |> Ash.Query.for_read(:unseen_count)
    |> Ash.count!(actor: user, tenant: user.site_id)
  end

  describe "fan_out/4 — content that comes back from Oban's args" do
    test "is read by the keys a notification has, and no atom is made of any other" do
      site = create_site!()
      user = create_user!(site_id: site.id)
      stray = "stray_key_nobody_declared_#{System.unique_integer([:positive])}"

      MishkaCmsCore.Notify.Delivery.fan_out(
        {:user, user.id},
        %{"type" => "test:event:created", "title" => "From a job", stray => "x"},
        site.id
      )

      assert [%{title: "From a job", type: "test:event:created"}] = feed(user)
      assert_raise ArgumentError, fn -> String.to_existing_atom(stray) end
    end
  end

  # ── audiences ──────────────────────────────────────────────────────────────

  describe "deliver/3 — audiences" do
    test "a single user gets exactly one row with the given content" do
      site = create_site!()
      user = create_user!(site_id: site.id)

      assert {:ok, %{delivered: 1}} =
               Notify.deliver({:user, user.id}, %{
                 type: "blog:comment:created",
                 title: "New comment",
                 body: "Nice post",
                 link: "/admin/dashboard/blog/comments",
                 source: "mishka_blog",
                 severity: :info,
                 metadata: %{"author" => "Sara"}
               })

      assert [n] = feed(user)
      assert n.type == "blog:comment:created"
      assert n.title == "New comment"
      assert n.link == "/admin/dashboard/blog/comments"
      assert n.metadata["author"] == "Sara"
      assert n.user_id == user.id
      assert n.site_id == site.id
      assert is_nil(n.seen_at) and is_nil(n.read_at)
    end

    test "an explicit list delivers one row per recipient" do
      site = create_site!()
      users = for _ <- 1..5, do: create_user!(site_id: site.id)

      assert {:ok, %{delivered: 5}} =
               Notify.deliver({:users, Enum.map(users, & &1.id)}, @content)

      for u <- users, do: assert(length(feed(u)) == 1)
    end

    test "a permission audience streams and reaches only permission-holders" do
      site = create_site!()
      perm = create_permission!(name: "admin:dashboard:blog:comment")

      holders = for _ <- 1..3, do: with_permission(create_user!(site_id: site.id), perm)
      others = for _ <- 1..2, do: create_user!(site_id: site.id)

      assert {:ok, %{delivered: 3}} =
               Notify.deliver({:permission, "admin:dashboard:blog:comment", site.id}, @content,
                 site_id: site.id
               )

      for u <- holders, do: assert(length(feed(u)) == 1)
      for u <- others, do: assert(feed(u) == [])
    end

    test "except: drops a matching recipient (the actor) so they aren't notified of their own action" do
      site = create_site!()
      perm = create_permission!(name: "admin:dashboard:blog:comment")

      actor = with_permission(create_user!(site_id: site.id), perm)
      other = with_permission(create_user!(site_id: site.id), perm)

      assert {:ok, %{delivered: 1}} =
               Notify.deliver({:permission, "admin:dashboard:blog:comment", site.id}, @content,
                 site_id: site.id,
                 except: actor.id
               )

      assert feed(actor) == []
      assert length(feed(other)) == 1
    end

    test ":masters reaches only master users, tagged with the originating site" do
      site = create_site!()
      master = create_user!()
      tenant_user = create_user!(site_id: site.id)

      assert {:ok, %{delivered: 1}} =
               Notify.deliver(:masters, %{type: "runtime:compile:failed", title: "Build failed"},
                 site_id: site.id
               )

      assert [n] = feed(master)
      # A master's row carries the ORIGINATING site so they can see/filter across all sites.
      assert n.site_id == site.id
      assert feed(tenant_user) == []
    end

    test "a combined [site_admins, masters] audience reaches both" do
      site = create_site!()
      perm = create_permission!(name: "admin:dashboard:*")
      admin = with_permission(create_user!(site_id: site.id), perm)
      master = create_user!()

      assert {:ok, %{delivered: d}} =
               Notify.deliver([{:site_admins, site.id}, :masters], @content, site_id: site.id)

      assert d == 2
      assert length(feed(admin)) == 1
      assert length(feed(master)) == 1
    end

    test "a site's admins are whoever holds anything on its dashboard, and not its API-only admins" do
      site = create_site!()

      area_admin =
        with_permission(
          create_user!(site_id: site.id),
          create_permission!(name: "admin:dashboard:runtime:media")
        )

      api_admin =
        with_permission(create_user!(site_id: site.id), create_permission!(name: "admin:api:*"))

      plain = create_user!(site_id: site.id)

      assert {:ok, %{delivered: 1}} =
               Notify.deliver({:site_admins, site.id}, @content, site_id: site.id)

      assert length(feed(area_admin)) == 1
      assert feed(api_admin) == []
      assert feed(plain) == []
    end

    test "a site's admins travel to a queued fan-out as anyone under the dashboard" do
      site_id = Ecto.UUID.generate()

      assert %{
               "kind" => "permission",
               "perms" => [%{"under" => "admin:dashboard"}],
               "site_id" => ^site_id
             } =
               MishkaCmsCore.Notify.Delivery.serialize({:site_admins, site_id})
    end

    test "the plugin-friendly form (attrs first, named audience opts) reaches the same recipients" do
      site = create_site!()
      perm = create_permission!(name: "admin:dashboard:*")
      tenant_admin = with_permission(create_user!(site_id: site.id), perm)
      master_admin = with_permission(create_user!(), create_permission!(name: "*"))
      plain = create_user!(site_id: site.id)

      assert {:ok, %{delivered: 2}} =
               Notify.deliver(
                 @content,
                 tenant_permissions: "admin:dashboard:*",
                 master_permissions: "admin:dashboard:*",
                 site_id: site.id
               )

      assert length(feed(tenant_admin)) == 1
      assert length(feed(master_admin)) == 1
      assert feed(plain) == []
    end

    test "missing type or title is rejected before any write" do
      site = create_site!()
      user = create_user!(site_id: site.id)

      assert {:error, :missing_type} = Notify.deliver({:user, user.id}, %{title: "x"})
      assert {:error, :missing_title} = Notify.deliver({:user, user.id}, %{type: "a:b"})
      assert feed(user) == []
    end
  end

  # ── tenancy: master cross-site vs tenant scoped ─────────────────────────────

  describe "tenancy" do
    test "a master sees notifications from every site; a tenant user only their own" do
      site_a = create_site!()
      site_b = create_site!()
      master = create_user!()
      user_a = create_user!(site_id: site_a.id)

      Notify.deliver(:masters, %{type: "site:a:event", title: "A"}, site_id: site_a.id)
      Notify.deliver(:masters, %{type: "site:b:event", title: "B"}, site_id: site_b.id)
      Notify.deliver({:user, user_a.id}, %{type: "site:a:event", title: "for A"})

      # Master reads UNSCOPED (tenant nil) → both sites.
      master_types = master |> feed() |> Enum.map(& &1.type) |> Enum.sort()
      assert master_types == ["site:a:event", "site:b:event"]

      # Tenant user reads SCOPED → only their site's row.
      assert [%{title: "for A"}] = feed(user_a)
    end
  end

  # ── per-user privacy policy ─────────────────────────────────────────────────

  describe "privacy policy (user_id == actor(:id))" do
    test "a user cannot read another user's notifications" do
      site = create_site!()
      alice = create_user!(site_id: site.id)
      bob = create_user!(site_id: site.id)

      Notify.deliver({:user, alice.id}, @content)

      assert length(feed(alice)) == 1
      assert feed(bob) == []
    end

    test "a user cannot mark another user's notification read" do
      site = create_site!()
      alice = create_user!(site_id: site.id)
      bob = create_user!(site_id: site.id)
      Notify.deliver({:user, alice.id}, @content)
      [n] = feed(alice)

      assert_raise Ash.Error.Forbidden, fn ->
        n
        |> Ash.Changeset.for_update(:mark_read, %{}, actor: bob, tenant: bob.site_id)
        |> Ash.update!()
      end
    end
  end

  # ── seen / read state + counts ──────────────────────────────────────────────

  describe "seen / read state" do
    test "unseen_count drops as rows are marked seen; mark_read sets read_at" do
      site = create_site!()
      user = create_user!(site_id: site.id)
      for _ <- 1..3, do: Notify.deliver({:user, user.id}, @content)

      assert unseen_count(user) == 3

      [first | _] = feed(user)

      updated =
        first
        |> Ash.Changeset.for_update(:mark_seen, %{}, actor: user, tenant: user.site_id)
        |> Ash.update!()

      assert not is_nil(updated.seen_at)
      assert unseen_count(user) == 2

      read =
        first
        |> Ash.Changeset.for_update(:mark_read, %{}, actor: user, tenant: user.site_id)
        |> Ash.update!()

      assert not is_nil(read.read_at)
    end
  end

  # ── real-time: per-user PubSub topic ────────────────────────────────────────

  describe "real-time" do
    test "delivery broadcasts on the recipient's own topic only" do
      site = create_site!()
      alice = create_user!(site_id: site.id)
      bob = create_user!(site_id: site.id)

      alice_topic = "notification:#{alice.id}:created"
      bob_topic = "notification:#{bob.id}:created"
      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, alice_topic)
      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, bob_topic)

      Notify.deliver({:user, alice.id}, @content)

      assert_receive %Phoenix.Socket.Broadcast{topic: ^alice_topic}
      refute_receive %Phoenix.Socket.Broadcast{topic: ^bob_topic}, 200
    end
  end

  describe "the notify:before_deliver hook" do
    defmodule Suppress do
      @moduledoc false
      use MishkaInstaller.Event.Hook, event: "notify:before_deliver"

      @impl true
      def call(data), do: {:reply, :halt, Map.put(data, :suppress, true)}
    end

    defmodule Retitle do
      @moduledoc false
      use MishkaInstaller.Event.Hook, event: "notify:before_deliver"

      @impl true
      def call(%{attrs: attrs} = data),
        do: {:reply, %{data | attrs: Map.put(attrs, :title, "Retitled")}}
    end

    defp register(module) do
      {:ok, _} =
        MishkaInstaller.Event.Event.write(%{
          name: module,
          event: "notify:before_deliver",
          extension: :mishka_installer,
          status: :started
        })

      :ok = MishkaInstaller.Event.EventHandler.do_compile("notify:before_deliver", :start, false)

      on_exit(fn ->
        MishkaInstaller.Event.Event.unregister(:name, module, false)
        MishkaInstaller.Event.EventHandler.do_compile("notify:before_deliver", :start, false)
      end)
    end

    test "a plugin that halts with the data marked suppress stops the delivery" do
      register(Suppress)
      user = create_user!(site_id: create_site!().id)

      assert {:error, :suppressed} = Notify.deliver({:user, user.id}, @content)
      assert feed(user) == []
    end

    test "a plugin that changes the attrs is delivered what it changed" do
      register(Retitle)
      user = create_user!(site_id: create_site!().id)

      assert {:ok, %{delivered: 1}} = Notify.deliver({:user, user.id}, @content)
      assert [%{title: "Retitled"}] = feed(user)
    end
  end
end
