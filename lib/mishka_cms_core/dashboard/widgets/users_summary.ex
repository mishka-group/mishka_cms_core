defmodule MishkaCmsCore.Dashboard.Widgets.UsersSummary do
  @moduledoc """
  Dashboard widget (a `dashboard:widgets` plugin): the users & access snapshot — the total user count
  with a Tenant/Master split, the permission catalogue (defined vs never-assigned) and how many users
  actually carry grants (with/without, plus the admins: holders of `*`, `admin:*` or anything under a
  surface, a single area included). It is the user area's card, `admin:dashboard:user`. Everything is counted through the
  `MishkaCmsCore.Accounts.User` and `MishkaCmsCore.Accounts.Permission` resources' tenancy-bypassing
  reads via `Ash.count!/2`. A master counts every user; a tenant admin only their own site's users.

  `Permission` has no `site_id`, so "defined" is a catalogue count — deployment configuration every
  admin needs in order to grant any of them — and stays global for both. "Unused" does not: it is
  derived from who holds a permission, which is tenant data, so for a tenant it means held by nobody
  **on this site**.

  The access bar's width is `percent/2` over the counts, a number that exists only at render time.
  Tailwind generates rules from SOURCE TEXT, so a class assembled around that number gets no rule at
  all and the bar draws with no width; it carries an inline `style` attribute instead, which is why
  the policy in `MishkaCmsCore.Runtime.Plugs.SecurityHeaders` keeps `style-src-attr` permitted — see
  `MishkaCmsWeb.InterpolatedClassTest`.
  """
  use MishkaInstaller.Event.Hook, event: "dashboard:widgets", initial: %{priority: 40}
  use Gettext, backend: MishkaCmsCore.Gettext
  import Phoenix.Component

  alias MishkaCmsCore.Accounts.{Permission, User}
  alias MishkaCmsCore.Dashboard.Widget
  alias MishkaCmsCore.Localized

  require Ash.Query

  @impl true
  def call(%{widgets: widgets} = data), do: {:reply, %{data | widgets: widgets ++ [widget()]}}

  @doc "This widget's descriptor."
  @spec widget() :: Widget.t()
  def widget do
    {:ok, widget} =
      Widget.builder(%{
        id: "users-summary",
        priority: 40,
        pubsub: [MishkaCmsCore.Accounts.User],
        title: gettext_noop("Users"),
        component: {__MODULE__, :render},
        size: 3,
        permission: "admin:dashboard:user",
        icon: "hero-users",
        link: "/admin/dashboard/account/users"
      })

    widget
  end

  @doc "Loads this widget's data off the dashboard render (in a Task), scoped to the viewer."
  def load(user) do
    scope = Widget.scope(user)
    total = count_users(scope)
    masters = count_masters(scope)
    with_perms = count_with_perms(scope)

    %{
      total: total,
      tenants: max(total - masters, 0),
      masters: masters,
      with_perms: with_perms,
      without_perms: max(total - with_perms, 0),
      admins: count_admins(scope),
      defined: count_permissions(),
      unused: count_unused_permissions(scope),
      access_pct: percent(with_perms, total)
    }
  end

  def render(assigns) do
    ~H"""
    <Widget.card_header icon="hero-users" tone={:violet} title={gettext("Users")}>
      <:right>
        <Widget.pill label={gettext("%{count} total", count: @data.total)} tone={:violet} />
      </:right>
    </Widget.card_header>

    <div class="mb-3.5 flex items-baseline gap-2">
      <span class="font-['Space_Grotesk'] text-[44px] font-semibold leading-none tracking-[-0.03em] text-[#17161a]">
        {Localized.number(@data.total)}
      </span>
      <span class="text-[12.5px] font-medium text-[#8a877f]">{gettext("users total")}</span>
    </div>

    <div class="mb-4 grid grid-cols-2 gap-2.5">
      <div class="rounded-xl border border-[#f0efea] bg-[#faf9f6] px-[13px] py-[11px]">
        <div class="flex items-center gap-1.5 text-[11px] font-semibold text-[#5c5a54]">
          <span class="size-[7px] rounded-[3px] bg-[#5b57d6]" />{gettext("Tenant")}
        </div>
        <div class="mt-1 font-['Space_Grotesk'] text-[22px] font-semibold text-[#17161a]">
          {Localized.number(@data.tenants)}
        </div>
      </div>
      <div class="rounded-xl border border-[#f0efea] bg-[#faf9f6] px-[13px] py-[11px]">
        <div class="flex items-center gap-1.5 text-[11px] font-semibold text-[#5c5a54]">
          <span class="size-[7px] rounded-[3px] bg-[#17161a]" />{gettext("Master")}
        </div>
        <div class="mt-1 font-['Space_Grotesk'] text-[22px] font-semibold text-[#17161a]">
          {Localized.number(@data.masters)}
        </div>
      </div>
    </div>

    <div class="mb-[11px] flex items-baseline justify-between">
      <span class="text-[10.5px] font-bold uppercase tracking-[0.08em] text-[#a8a5a0]">
        {gettext("Permission access")}
      </span>
      <span class="text-[11px] font-medium text-[#8a877f]">
        <span class="font-semibold text-[#3a382f]">{@data.defined}</span> {gettext("defined")}
      </span>
    </div>
    <div class="mb-3 flex h-[9px] overflow-hidden rounded-md bg-[#f0efea]">
      <div class="bg-[#5b57d6]" style={"width:#{@data.access_pct}%"} />
    </div>

    <div class="flex items-center justify-between py-[3px]">
      <span class="flex items-center gap-[7px] text-[12.5px] font-medium text-[#3a382f]">
        <span class="size-2 rounded-[3px] bg-[#5b57d6]" />{gettext("With permissions")}
      </span>
      <span class="font-['Space_Grotesk'] text-[12.5px] font-semibold text-[#17161a]">
        {Localized.number(@data.with_perms)}
      </span>
    </div>
    <div class="flex items-center justify-between py-[3px]">
      <span class="flex items-center gap-[7px] text-[12.5px] font-medium text-[#3a382f]">
        <span class="size-2 rounded-[3px] bg-[#dcdad3]" />{gettext("Without permissions")}
      </span>
      <span class="font-['Space_Grotesk'] text-[12.5px] font-semibold text-[#17161a]">
        {Localized.number(@data.without_perms)}
      </span>
    </div>

    <div class="mt-[18px] grid grid-cols-2 gap-2.5">
      <div class="rounded-xl border border-[#f3e7cf] bg-[#fbf7ef] px-[14px] py-[13px]">
        <div class="flex items-center gap-[7px]">
          <span class="grid size-5 place-items-center rounded-md bg-[#fbf1df] font-['Space_Grotesk'] text-[15px] font-extrabold leading-[0] text-[#cf8a24]">
            *
          </span>
          <span class="text-[11px] font-semibold text-[#a5691a]">{gettext("Admins")}</span>
        </div>
        <div class="mt-[9px] font-['Space_Grotesk'] text-[24px] font-semibold text-[#17161a]">
          {Localized.number(@data.admins)}
        </div>
        <div class="mt-0.5 text-[10.5px] font-medium text-[#8a877f]">
          {gettext("hold an admin permission, one area included")}
        </div>
      </div>
      <div class="rounded-xl border border-[#f0efea] bg-[#faf9f6] px-[14px] py-[13px]">
        <div class="flex items-center gap-[7px]">
          <span class="grid size-5 place-items-center rounded-md bg-[#f2f1ec] text-[#8a877f]">
            <span class="hero-minus-circle size-3" />
          </span>
          <span class="text-[11px] font-semibold text-[#6d6a63]">
            {gettext("Unused permissions")}
          </span>
        </div>
        <div class="mt-[9px] font-['Space_Grotesk'] text-[24px] font-semibold text-[#17161a]">
          {Localized.number(@data.unused)}
        </div>
        <div class="mt-0.5 text-[10.5px] font-medium text-[#8a877f]">
          {gettext("defined but never assigned")}
        </div>
      </div>
    </div>

    <Widget.card_footer link={@widget.link} label={gettext("Manage users")} border={true} />
    """
  end

  defp users_base(scope) do
    User
    |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
    |> scope_filter(scope)
  end

  defp count_users(scope), do: Ash.count!(users_base(scope), authorize?: false)

  defp count_masters(scope) do
    scope
    |> users_base()
    |> Ash.Query.filter(is_nil(site_id))
    |> Ash.count!(authorize?: false)
  end

  defp count_with_perms(scope) do
    scope
    |> users_base()
    |> Ash.Query.filter(exists(permissions, not is_nil(id)))
    |> Ash.count!(authorize?: false)
  end

  # An admin holds `*`, `admin:*`, or anything under a surface — a single area as much as a wildcard.
  defp count_admins(scope) do
    everything = "*"
    admin = "admin:*"
    dashboard = "admin:dashboard" <> ":%"
    api = "admin:api" <> ":%"

    scope
    |> users_base()
    |> Ash.Query.filter(
      exists(
        permissions,
        name == ^everything or name == ^admin or like(name, ^dashboard) or like(name, ^api)
      )
    )
    |> Ash.count!(authorize?: false)
  end

  defp count_permissions, do: Ash.count!(Permission, authorize?: false)

  defp count_unused_permissions(nil) do
    Permission
    |> Ash.Query.filter(not exists(users, not is_nil(id)))
    |> Ash.count!(authorize?: false)
  end

  defp count_unused_permissions(site_id) do
    Permission
    |> Ash.Query.filter(not exists(users, site_id == ^site_id))
    |> Ash.count!(authorize?: false)
  end

  defp scope_filter(query, nil), do: query
  defp scope_filter(query, site_id), do: Ash.Query.filter(query, site_id == ^site_id)

  defp percent(_part, 0), do: 0
  defp percent(part, total), do: round(part / total * 100)
end
