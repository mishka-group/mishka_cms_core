# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Notify.Delivery do
  @moduledoc """
  Turns one `deliver/3` call into many per-recipient rows, fast and at scale.

  ## Tenancy — who sees what

  A notification's `site_id` is **the site the event concerns** (the originating site), passed as
  `opts[:site_id]` (or derived from a `:permission`/`:site_admins` audience). It is `nil` only for
  platform-level events. Consequences:

    * A **tenant** user (bound to one site) reads scoped to their site and therefore sees only that
      site's notifications.
    * A **master** user (`site_id == nil`, cross-site) reads *unscoped* (`global? true` + no tenant →
      all rows), narrowed to their own by the `user_id == actor(:id)` policy — so a master receives
      notifications **from every site**, each row carrying its originating `site_id` for filtering.

  So every recipient row of one `deliver` call gets the same originating `site_id` (via
  `tenant: site_id` → the `:deliver` change), regardless of whether the recipient is a tenant user
  or a master.

  ## Never blocks the caller's request

  Delivery ALWAYS hands off — it never fans out on the request path. In prod that's a single fast
  `Oban.insert` (queue `:notify`); the actual per-recipient writes happen in
  `MishkaCmsCore.Notify.Workers.FanoutWorker`, which STREAMS the audience in batches so a 100k-user
  site is written in constant memory, off-request. So a producer reacting to (say) a comment can
  call `deliver/3` and return immediately. Under test the same `fan_out/4` runs inline (Oban isn't
  draining) so assertions still see the rows.

  ## Audiences (who)

  An audience is resolved here, built to scale — `stream/2` pages recipients in batches via
  `Ash.stream!` (constant memory even for a 100k-user site) and filters permission audiences in
  Elixir (wildcards can't be matched in SQL). Shapes: `%User{}` / `{:user, id}` / `{:users, ids}` /
  `{:permission, perm|[perm], site_id}` / `{:permission_masters, perm|[perm]}` / `:masters` /
  `{:site_admins, site_id}` (or a list to combine). A `perm` is a name or `{:under, prefix}` (see
  `MishkaCmsCore.Accounts.Checks.AccessPermissions`). `serialize/1`+`deserialize/1` round-trip an
  audience through the Oban job args, an `{:under, prefix}` as `%{"under" => prefix}`, and
  `{:under, :surface}` as the dashboard's, where notifications are read.

  See `MishkaCmsCore.Notify` (the public facade).
  """

  require Logger
  require Ash.Query

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Notify
  alias MishkaCmsCore.Notify.Notification
  alias MishkaCmsCore.Notify.Workers.FanoutWorker
  alias MishkaCmsCore.Settings

  @bulk_batch 500
  @stream_batch 500
  @content_keys [:type, :title, :body, :icon, :severity, :link, :source, :metadata]

  @doc """
  Deliver a notification. Two forms:

      # Plugin-friendly — attrs first, audience as named opts (recommended for producers):
      deliver(%{type: ..., title: ...},
        tenant_permissions: "admin:dashboard:blog:comment",   # tenant admins on `site_id` holding this
        master_permissions: "admin:dashboard:blog:comment",   # every master admin holding this
        site_id: site_id, actor: actor, except: [actor_id])

      # Core — an explicit audience (or list of audiences) first:
      deliver({:user, id}, %{type: ..., title: ...})

  Audience opts (any combination; recipients de-duplicated by id): `:user` (id / `%User{}`),
  `:users` (ids), `:tenant_permissions` (perm | [perm] → tenant admins on `:site_id`),
  `:master_permissions` (perm | [perm] → master admins), `:masters` (`true` → every master),
  `:site_admins` (a site id → whoever holds anything under its `admin:dashboard`). `attrs` needs at
  least `:type` and `:title`.
  Other opts: `:site_id` (the originating site; `nil` = platform-level), `:actor` (`%User{}` / id →
  `actor_id`), `:except` (user id / [ids] to drop — pass the actor so they aren't notified of their
  own action), `:dedup_key` (Oban `unique`).

  Returns `{:ok, %{delivered: n}}` (inline) / `{:ok, :queued}` (deferred) / `{:error, reason}`.
  """
  def deliver(attrs, opts) when is_map(attrs) and not is_struct(attrs) and is_list(opts) do
    deliver(build_audience(opts), attrs, opts)
  end

  def deliver(audience, attrs), do: deliver(audience, attrs, [])

  def deliver(audience, attrs, opts) do
    with {:ok, attrs} <- normalize(attrs, opts),
         {:ok, attrs} <- before_deliver(attrs, audience) do
      do_deliver(audience, attrs, opts)
    end
  end

  @audience_opts [:user, :users, :tenant_permissions, :master_permissions, :masters, :site_admins]

  # Turn the plugin-friendly form's named audience opts into audience specs (a single spec, or a
  # list when several are given — `do_deliver` de-duplicates recipients across them).
  defp build_audience(opts) do
    @audience_opts
    |> Enum.flat_map(fn key -> List.wrap(audience_for(key, opts[key], opts)) end)
    |> case do
      [single] -> single
      list -> list
    end
  end

  defp audience_for(_key, nil, _opts), do: nil
  defp audience_for(:user, id, _opts), do: {:user, id}
  defp audience_for(:users, ids, _opts), do: {:users, ids}
  defp audience_for(:tenant_permissions, perms, opts), do: {:permission, perms, opts[:site_id]}
  defp audience_for(:master_permissions, perms, _opts), do: {:permission_masters, perms}
  defp audience_for(:masters, true, _opts), do: :masters
  defp audience_for(:masters, _other, _opts), do: nil
  defp audience_for(:site_admins, site_id, _opts), do: {:site_admins, site_id}

  defp do_deliver(audiences, attrs, opts) when is_list(audiences) do
    Enum.reduce_while(audiences, {:ok, %{delivered: 0}}, fn audience, {:ok, acc} ->
      case dispatch_one(audience, attrs, opts) do
        {:ok, %{delivered: n}} -> {:cont, {:ok, %{acc | delivered: acc.delivered + n}}}
        {:ok, :queued} -> {:cont, {:ok, acc}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp do_deliver(audience, attrs, opts), do: dispatch_one(audience, attrs, opts)

  # A plugin on `notify:before_deliver` may enrich attrs — `{:reply, %{data | attrs: new_attrs}}` —
  # or suppress the whole delivery by halting with the data marked:
  # `{:reply, :halt, Map.put(data, :suppress, true)}`. A halt must hand back a map: mishka_installer
  # drops anything else and continues with the original data. Absent hook → attrs unchanged.
  defp before_deliver(attrs, audience) do
    case MishkaInstaller.Event.Hook.call("notify:before_deliver", %{
           attrs: attrs,
           audience: audience
         }) do
      %{suppress: true} -> {:error, :suppressed}
      %{attrs: attrs} when is_map(attrs) -> {:ok, attrs}
      _ -> {:ok, attrs}
    end
  end

  @doc """
  The scalable fan-out: stream recipients for `spec`, bulk-create with `tenant: site_id` in
  `@bulk_batch` chunks. Called inline under test and by `FanoutWorker.perform/1` in prod. `attrs`
  may have string or atom keys (round-tripped through Oban args). Returns recipients written.
  """
  def fan_out(audience, attrs, site_id, opts \\ []) do
    attrs = atomize_content(attrs)
    except = MapSet.new(List.wrap(opts[:except]))
    pref_key = Notify.user_setting_key(attrs[:type])

    audience
    |> stream(opts)
    |> Stream.reject(&MapSet.member?(except, &1.id))
    # Per-recipient opt-out: a user who turned this type off in Settings → Preferences is skipped
    # (default on). One ETS read per recipient — the site-level toggle was already checked once.
    |> Stream.filter(&Settings.get_user(pref_key, &1.id, true))
    |> Stream.chunk_every(@bulk_batch)
    |> Enum.reduce(0, fn batch, acc -> acc + insert_for(batch, attrs, site_id) end)
  end

  # ── internal ───────────────────────────────────────────────────────────────

  # Always hand off — never fan out on the caller's request path. In prod that's a single
  # Oban.insert; under test the fan-out runs inline so assertions see the rows.
  defp dispatch_one(audience, attrs, opts) do
    site_id = notification_site(audience, opts)

    cond do
      # Site-level, admin-managed toggle (a normal Setting, default on). Off → deliver to no one.
      !Settings.get(Notify.setting_key(attrs[:type]), true, site_id) ->
        {:ok, %{delivered: 0}}

      Application.get_env(:mishka_cms_core, :env_test?, false) ->
        {:ok, %{delivered: fan_out(audience, attrs, site_id, opts)}}

      true ->
        enqueue(audience, attrs, site_id, opts)
    end
  end

  defp enqueue(audience, attrs, site_id, opts) do
    job_opts =
      case opts[:dedup_key] do
        nil -> []
        _key -> [unique: [keys: [:dedup_key], states: [:available, :scheduled], period: 60]]
      end

    %{
      "audience" => serialize(audience),
      "attrs" => stringify_content(attrs),
      "site_id" => site_id,
      "except" => Enum.map(List.wrap(opts[:except]), &to_string/1),
      "dedup_key" => opts[:dedup_key] && to_string(opts[:dedup_key])
    }
    |> FanoutWorker.new(job_opts)
    |> Oban.insert()
    |> case do
      {:ok, _job} -> {:ok, :queued}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_for([], _attrs, _originating_site), do: 0

  # Each row's site is the recipient's own site (so a tenant user's scoped read finds it), falling
  # back to the originating site for master recipients (who read unscoped). Group by that effective
  # site because one bulk_create shares a single tenant.
  defp insert_for(users, attrs, originating_site) do
    users
    |> Enum.group_by(fn user -> user.site_id || originating_site end)
    |> Enum.reduce(0, fn {site_id, group}, acc ->
      rows = Enum.map(group, fn user -> Map.put(attrs, :user_id, user.id) end)

      Ash.bulk_create(rows, Notification, :deliver,
        tenant: site_id,
        authorize?: false,
        return_records?: false,
        return_errors?: true,
        batch_size: @bulk_batch,
        transaction: :batch,
        notify?: true
      )
      |> case do
        %Ash.BulkResult{status: :success} ->
          acc + length(rows)

        %Ash.BulkResult{status: status, errors: errors} ->
          Logger.warning(
            "[Notify] fan-out batch #{status} for site #{inspect(site_id)}: #{inspect(errors)}"
          )

          acc + length(rows)
      end
    end)
  end

  # The notification's site = the event's site. Explicit opts wins (may be nil = platform-level);
  # otherwise derive it from a site-scoped audience.
  defp notification_site(audience, opts) do
    if Keyword.has_key?(opts, :site_id), do: opts[:site_id], else: audience_site(audience)
  end

  defp audience_site({:permission, _perms, site_id}), do: site_id
  defp audience_site({:site_admins, site_id}), do: site_id
  defp audience_site(_), do: nil

  defp normalize(attrs, opts) do
    attrs = Map.new(attrs)

    cond do
      blank?(attrs[:type]) -> {:error, :missing_type}
      blank?(attrs[:title]) -> {:error, :missing_title}
      true -> {:ok, attrs |> Map.put_new(:severity, :info) |> put_actor(opts[:actor])}
    end
  end

  defp put_actor(attrs, nil), do: attrs
  defp put_actor(attrs, %{id: id}), do: Map.put(attrs, :actor_id, id)
  defp put_actor(attrs, id) when is_binary(id), do: Map.put(attrs, :actor_id, id)

  defp stringify_content(attrs) do
    for {k, v} <- Map.take(attrs, [:actor_id | @content_keys]), into: %{}, do: {to_string(k), v}
  end

  defp atomize_content(attrs) when is_map(attrs) do
    for {k, v} <- attrs, into: %{} do
      key = if is_atom(k), do: k, else: String.to_existing_atom(k)
      {key, v}
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # ── audience resolution (who) ────────────────────────────────────────────────

  @doc "A back-pressured stream of recipient users for `audience` — never materializes a whole site."
  def stream(%User{} = user, _opts), do: [user]
  def stream({:user, id}, _opts), do: load_by_ids([id])
  def stream({:users, ids}, _opts) when is_list(ids), do: load_by_ids(ids)

  def stream(:masters, _opts) do
    User
    |> Ash.Query.filter(is_nil(site_id))
    |> Ash.Query.load(permissions: [:name])
    |> Ash.stream!(batch_size: @stream_batch, authorize?: false)
  end

  def stream({:site_admins, site_id}, opts),
    do: stream({:permission, site_admins(), site_id}, opts)

  # A tenant-permission audience needs a site; without one there are no tenant admins to match
  # (masters are reached via `{:permission_masters, ...}`), so skip the query entirely.
  def stream({:permission, _perms, nil}, _opts), do: []

  def stream({:permission, perms, site_id}, _opts) do
    perms = List.wrap(perms)

    User
    |> Ash.Query.filter(site_id == ^site_id)
    |> Ash.Query.load(permissions: [:name])
    |> Ash.stream!(batch_size: @stream_batch, authorize?: false)
    |> Stream.filter(&AccessPermissions.match?(&1, %{}, permissions: perms))
  end

  def stream({:permission_masters, perms}, _opts) do
    perms = List.wrap(perms)

    User
    |> Ash.Query.filter(is_nil(site_id))
    |> Ash.Query.load(permissions: [:name])
    |> Ash.stream!(batch_size: @stream_batch, authorize?: false)
    |> Stream.filter(&AccessPermissions.match?(&1, %{}, permissions: perms))
  end

  @doc "Serialize an audience into JSON-safe Oban job args. A `%User{}` collapses to its id."
  def serialize(%User{} = user), do: %{"kind" => "users", "ids" => [user.id]}
  def serialize({:user, id}), do: %{"kind" => "users", "ids" => [id]}
  def serialize({:users, ids}), do: %{"kind" => "users", "ids" => ids}
  def serialize(:masters), do: %{"kind" => "masters"}

  def serialize({:site_admins, site_id}),
    do: serialize({:permission, site_admins(), site_id})

  def serialize({:permission, perms, site_id}),
    do: %{"kind" => "permission", "perms" => serialize_perms(perms), "site_id" => site_id}

  def serialize({:permission_masters, perms}),
    do: %{"kind" => "permission_masters", "perms" => serialize_perms(perms)}

  @doc "Inverse of `serialize/1` — used by the fan-out worker."
  def deserialize(%{"kind" => "users", "ids" => ids}), do: {:users, ids}
  def deserialize(%{"kind" => "masters"}), do: :masters

  def deserialize(%{"kind" => "permission", "perms" => perms, "site_id" => site_id}),
    do: {:permission, deserialize_perms(perms), site_id}

  def deserialize(%{"kind" => "permission_masters", "perms" => perms}),
    do: {:permission_masters, deserialize_perms(perms)}

  # A site's admins: whoever holds anything on its dashboard.
  defp site_admins, do: {:under, "admin:dashboard"}

  # A name stays a string; `{:under, prefix}` travels as `%{"under" => prefix}`, and the request's
  # surface as the dashboard's, where notifications are read.
  defp serialize_perms(perms), do: perms |> List.wrap() |> Enum.map(&serialize_perm/1)

  defp serialize_perm({:under, :surface}), do: %{"under" => "admin:dashboard"}
  defp serialize_perm({:under, prefix}), do: %{"under" => prefix}
  defp serialize_perm(name), do: name

  defp deserialize_perms(perms), do: perms |> List.wrap() |> Enum.map(&deserialize_perm/1)

  defp deserialize_perm(%{"under" => prefix}), do: {:under, prefix}
  defp deserialize_perm(name), do: name

  # Explicit-id lookups: global? true means a tenant-less read spans all sites, so a plain id filter
  # finds tenant users and masters alike. Permissions pre-loaded to avoid a per-user Ash.load!.
  defp load_by_ids(ids) do
    User
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.load(permissions: [:name])
    |> Ash.read!(authorize?: false)
  end
end
