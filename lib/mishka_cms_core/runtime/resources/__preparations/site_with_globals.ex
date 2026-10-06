defmodule MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals do
  @moduledoc """
  Scopes a read to one site plus the shared rows, deciding whose site from WHO IS ASKING.

  For the `multitenancy :bypass` reads that answer "this site's rows and the global ones" —
  `:for_tenant_with_globals` and its single-row twin, the builder's `:for_editor` reads, a
  stylesheet's `:for_compiler`. A missing tenant is never a master:

    * a master (`MishkaCmsCore.Accounts.Helper.master_user?/1`, `site_id` nil) reads the tenant's
      site when one is passed, else the site named in the `:site_id` argument, else every site;
    * a site user, whatever it holds, reads its own site. Passing another site's tenant or naming
      another site in `:site_id` reads nothing;
    * a call made as the system — no actor, `authorize?: false` — reads as a master does;
    * a call with no actor made as a user reads the tenant's site when one is passed, else nothing.
      A query built without `authorize?` is such a call: Ash hands the preparation the domain's
      default, `true`;
    * any other actor reads nothing.

  The actor is the one the query was built with. What holds the actor that runs the read is the
  policy on the same actions — see `MishkaCmsCore.Runtime.Layout` — and a test holds every action
  that uses this preparation to that policy.

  ## Options

    * `:shape` — `:with_globals` (the default) adds the shared rows to the site's own; `:exact`
      reads the site's rows alone, and the shared rows alone when the reach is every site.
    * `:fallback` — what a master or the system reads with neither a tenant nor a `:site_id`:
      `:everything` (the default) or `:globals`.

  ## Usage

      read :for_tenant_with_globals do
        multitenancy :bypass
        argument :site_id, :uuid, allow_nil?: true

        prepare MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals
      end
  """
  use Ash.Resource.Preparation

  require Ash.Query

  alias MishkaCmsCore.Accounts.Helper

  @impl true
  def init(opts) do
    shape = Keyword.get(opts, :shape, :with_globals)
    fallback = Keyword.get(opts, :fallback, :everything)

    if shape in [:with_globals, :exact] and fallback in [:everything, :globals] do
      {:ok, [shape: shape, fallback: fallback]}
    else
      {:error,
       "SiteWithGlobals takes shape: :with_globals | :exact and fallback: :everything | :globals"}
    end
  end

  @impl true
  def prepare(query, opts, context) do
    site_argument = site_argument(query)

    context.actor
    |> reach(context.tenant, site_argument, context.authorize?)
    |> apply_reach(query, opts[:shape], opts[:fallback])
  end

  @doc """
  Which site `actor` reaches for a read made with `tenant` and naming `site_argument`: `{:site, id}`,
  `:everything` or `:nothing`. `authorize?` is whether the call is made as a user.
  """
  @spec reach(map() | nil, String.t() | nil, String.t() | nil, boolean()) ::
          {:site, String.t()} | :everything | :nothing
  def reach(nil, tenant, site_argument, false), do: master_reach(tenant, site_argument)
  def reach(nil, tenant, _site_argument, _as_user) when is_binary(tenant), do: {:site, tenant}
  def reach(nil, _tenant, _site_argument, _as_user), do: :nothing

  def reach(actor, tenant, site_argument, _authorize?)
      when is_map(actor) and is_map_key(actor, :site_id) do
    case Helper.master_user?(actor) do
      true -> master_reach(tenant, site_argument)
      false -> own_reach(actor.site_id, tenant, site_argument)
    end
  end

  def reach(_unknown, _tenant, _site_argument, _authorize?), do: :nothing

  @doc """
  The site a call acts on: its tenant, when whoever makes the call may act for that site — a master,
  the system (no actor, `authorize?: false`), or a site user whose own site it is. Anyone else, a
  site user naming another site and a missing actor included, acts on none: `nil`.

  For the actions that read or write as the system once they know whose record it is — the version
  wrappers — so that knowing comes from the actor and not from the tenant alone.
  """
  @spec acting_site(map()) :: String.t() | nil
  def acting_site(%{tenant: tenant, actor: nil, authorize?: false}) when is_binary(tenant),
    do: tenant

  def acting_site(%{tenant: tenant, actor: actor} = context)
      when is_binary(tenant) and is_map(actor) do
    case reach(actor, tenant, nil, Map.get(context, :authorize?) != false) do
      {:site, ^tenant} -> tenant
      _elsewhere -> nil
    end
  end

  def acting_site(_context), do: nil

  @doc """
  The site a read made with `context` reads: its tenant, for a master, the system, a call with no
  actor, and a site user whose own site it is — the reach `reach/4` gives a read. A site user naming
  another site, and anything that is not a user, reads none: `nil`. What the read then shows the
  actor that runs it is the resource's read policy.
  """
  @spec reading_site(map()) :: String.t() | nil
  def reading_site(%{tenant: tenant} = context) when is_binary(tenant) do
    case reach(Map.get(context, :actor), tenant, nil, Map.get(context, :authorize?) != false) do
      {:site, ^tenant} -> tenant
      _elsewhere -> nil
    end
  end

  def reading_site(_context), do: nil

  @doc """
  Whether a call made with `context` may write a record of `site_id` — a record of no site when
  `site_id` is nil. With no tenant, only a master or the system does; with one, whoever acts on the
  tenant (`acting_site/1`), and only on that site's record.
  """
  @spec acts_on?(map(), String.t() | nil) :: boolean()
  def acts_on?(%{tenant: nil} = context, _site_id),
    do:
      reach(Map.get(context, :actor), nil, nil, Map.get(context, :authorize?) != false) ==
        :everything

  def acts_on?(%{tenant: tenant} = context, site_id) when is_binary(tenant),
    do: site_id == tenant and acting_site(context) == tenant

  def acts_on?(_context, _site_id), do: false

  defp master_reach(tenant, _site_argument) when is_binary(tenant), do: {:site, tenant}

  defp master_reach(_tenant, site_argument) when is_binary(site_argument),
    do: {:site, site_argument}

  defp master_reach(_tenant, _site_argument), do: :everything

  defp own_reach(own, tenant, site_argument)
       when is_binary(own) and tenant in [nil, own] and site_argument in [nil, own],
       do: {:site, own}

  defp own_reach(_own, _tenant, _site_argument), do: :nothing

  defp apply_reach(:nothing, query, _shape, _fallback), do: Ash.Query.filter(query, false)

  defp apply_reach({:site, site_id}, query, :with_globals, _fallback),
    do: Ash.Query.filter(query, site_id == ^site_id or is_nil(site_id))

  defp apply_reach({:site, site_id}, query, :exact, _fallback),
    do: Ash.Query.filter(query, site_id == ^site_id)

  defp apply_reach(:everything, query, :exact, _fallback),
    do: Ash.Query.filter(query, is_nil(site_id))

  defp apply_reach(:everything, query, _shape, :globals),
    do: Ash.Query.filter(query, is_nil(site_id))

  defp apply_reach(:everything, query, _shape, :everything), do: query

  defp site_argument(%{action: %{arguments: arguments}} = query) do
    case Enum.any?(arguments, &(&1.name == :site_id)) do
      true -> Ash.Query.get_argument(query, :site_id)
      false -> nil
    end
  end

  defp site_argument(_query), do: nil
end
