defmodule MishkaCmsCore.Accounts.Checks.AccessPermissions do
  @moduledoc """
  Whether an actor holds what a gate requires — the one matcher every policy, plug, page guard,
  sidebar entry, widget, setting and notification audience asks.

  ## Names

  A permission name is a plain string of colon-separated, lower snake_case segments, written where
  it is used:

    * `admin:dashboard:<area>[:<sub>]` — the admin screens and the data they read and write, such as
      `admin:dashboard:runtime:page`, `admin:dashboard:blog:post` or `admin:dashboard:code`.
    * `admin:api:<area>[:<sub>]` — the admin JSON:API and GraphQL, such as `admin:api:runtime:page`.
    * `*` only as the whole last segment: `admin:dashboard:*` is the whole dashboard and nothing on
      the API, `admin:api:*` the whole API and nothing on the dashboard, `admin:dashboard:runtime:*`
      every runtime section. `admin:*` and `*` are both surfaces.

  A held name ending in `*` covers every name below it, and a leaf covers only itself:
  `admin:dashboard:code` does not cover `admin:dashboard:code:x`. A narrow name never meets a
  required wildcard: a required `admin:dashboard:*` is met only by `admin:dashboard:*`, `admin:*`
  or `*`.

  ## What may be required

  A list where holding ANY entry is enough. An entry is:

    * a name — held when a held name covers it. A required `admin:dashboard:…` name counts only
      when the request came from the dashboard, and a required `admin:api:…` name only when it came
      from the API (`surface/1`). Any other name counts on both.
    * `{:under, prefix}` — held when the actor holds anything at or under `prefix`: a name starting
      with `prefix <> ":"`, or a wildcard covering `prefix <> ":*"`. `*`, `admin:*`,
      `admin:dashboard:*` and `admin:dashboard:blog:post` are all under `"admin:dashboard"`. It
      counts wherever the request came from.
    * `{:under, :surface}` — `{:under, "admin:dashboard"}` or `{:under, "admin:api"}`, for the
      surface the request came from.

  Anything else grants nothing.

  As a policy check it takes `:permissions` and `:under`, and the entries they name are added
  together. A policy lists the name of each surface it answers on:

      authorize_if {AccessPermissions, permissions: ["admin:dashboard:runtime:page", "admin:api:runtime:page"]}
      authorize_if {AccessPermissions, permissions: [{:under, "admin:dashboard"}]}
      authorize_if {AccessPermissions, under: "admin:dashboard"}

  The admin JSON:API, GraphQL and the GraphQL socket put `admin_surface: :api` in the shared context
  (`MishkaCmsCore.Runtime.Plugs.AdminSurfacePlug`); every other request is the dashboard's. Called
  directly, pass a context carrying that surface to ask about the API:

      AccessPermissions.match?(user, %{shared: %{admin_surface: :api}}, permissions: ["admin:api:*"])

  ## Sites

  `*` is not master status. A master is a user whose `site_id` is nil
  (`MishkaCmsCore.Accounts.Helper.master_user?/1`); a site user holding `*` holds every permission
  within its own site and nothing beyond it.

  As a policy check it asks about the action the policy is authorizing, with the actor and tenant it
  RUNS with. A site user holds none of its permissions under another site's tenant, nor for a
  master's action (one that declares `TenantContext` with `require_master: true`). A master holds
  its permissions under any tenant and for any action. Called directly, with no action to ask about,
  it answers for the permissions alone.

  ## Loading

  An actor whose `:permissions` are not loaded has them read with no tenant and no authorization:
  which names a user holds is not a question of the site a request runs under.

  ## Attribution
  Originally developed based on the core implementation by Mr. Toomaj Boloorian
  (https://github.com/toomaj). Original source available at:
  https://github.com/mishka-group/mishka_developer_tools/blob/master/lib/modules/permission_access.ex
  """
  use Ash.Policy.SimpleCheck

  alias MishkaCmsCore.Runtime.Resources.Validations.TenantContext

  @separator ":"

  @typedoc "Where an admin works: the screens, or the admin JSON:API and GraphQL."
  @type surface :: :dashboard | :api

  @typedoc "One entry of a required list: a name, or anything under a prefix."
  @type requirement :: String.t() | {:under, String.t() | :surface}

  @doc """
  What the check asks, in words, for a policy breakdown.
  """
  @impl Ash.Policy.Check
  def describe(opts) do
    parts =
      Enum.map(List.wrap(opts[:permissions]), &describe_entry/1) ++
        Enum.map(List.wrap(opts[:under]), &describe_entry({:under, &1}))

    case parts do
      [] -> "Checking permissions"
      [single] -> "User holds #{single}"
      many -> "User holds any of: #{Enum.join(many, ", ")}"
    end
  end

  defp describe_entry({:under, :surface}), do: "anything under the request's surface"
  defp describe_entry({:under, prefix}), do: "anything under #{prefix}"
  defp describe_entry(name), do: to_string(name)

  @doc """
  Whether `actor` holds any of what `opts` requires (`:permissions`, `:under`) on the request's
  surface, within its own site when `context` carries the policy's subject. `false` for no actor or
  nothing required.
  """
  @impl Ash.Policy.SimpleCheck
  def match?(nil, _context, _opts), do: false

  def match?(actor, context, opts),
    do: not outside_own_site?(actor, context) and holds_any?(actor, required(opts, context))

  @doc """
  Whether `actor` holds anything at or under `prefix`, such as `"admin:dashboard"`. See
  `{:under, prefix}` above.
  """
  @spec holds_under?(map() | nil, String.t()) :: boolean()
  def holds_under?(nil, _prefix), do: false

  def holds_under?(actor, prefix) when is_binary(prefix),
    do: actor |> held() |> Enum.any?(&under?(&1, prefix))

  @doc """
  The surface a request came from: `:api` when the shared context says `admin_surface: :api`,
  otherwise `:dashboard`. Takes a policy context (with its `:subject`), a query, changeset or action
  input, or a context map.
  """
  @spec surface(map() | nil) :: surface()
  def surface(%{subject: %{} = subject}), do: surface(subject)
  def surface(%{context: context}) when is_map(context), do: surface(context)
  def surface(%{shared: %{admin_surface: :api}}), do: :api
  def surface(_context), do: :dashboard

  @doc """
  `actor` with its `:permissions` loaded — read with no tenant and no authorization when they are
  not. A map that is not a resource is returned as it is.
  """
  @spec with_permissions(map() | nil) :: map() | nil
  def with_permissions(nil), do: nil

  def with_permissions(%resource{} = actor) do
    case Ash.Resource.Info.resource?(resource) and not Ash.Resource.loaded?(actor, :permissions) do
      true -> Ash.load!(actor, [permissions: [:name]], tenant: nil, authorize?: false)
      false -> actor
    end
  end

  def with_permissions(actor), do: actor

  @doc """
  Whether holding `permission` grants `action`, with the same wildcard semantics every gate uses:
  `admin:dashboard:*` covers `admin:dashboard:blog:post`, `*` covers everything, and a narrower
  `admin:dashboard:runtime:page` does NOT cover `admin:dashboard:*`. The surface plays no part.

  Public because granting permissions asks the same question in the other direction — "may this
  actor hand out that permission" is "does what they hold cover it".
  """
  @spec covers?(String.t(), String.t()) :: boolean()
  def covers?(permission, action), do: is_permitted?(action: action, permission: permission)

  @doc """
  The names among `names` that nothing `actor` holds covers (`covers?/2`): what the actor would
  gain by granting them, or by taking over an account that holds them. Every name for no actor.

      AccessPermissions.beyond(actor, ["admin:dashboard:runtime:page", "*"])
      #=> ["*"]
  """
  @spec beyond(map() | nil, [String.t()]) :: [String.t()]
  def beyond(_actor, []), do: []
  def beyond(nil, names), do: names

  def beyond(actor, names) do
    held = held(actor)
    Enum.reject(names, fn name -> Enum.any?(held, &covers?(&1, name)) end)
  end

  defp outside_own_site?(%{site_id: site_id}, %{subject: subject}) when is_binary(site_id),
    do:
      another_sites_tenant?(subject, site_id) or
        TenantContext.requires_master?(subject.resource, subject.action)

  defp outside_own_site?(_actor, _context), do: false

  defp another_sites_tenant?(%{tenant: tenant}, site_id) when is_binary(tenant),
    do: tenant != site_id

  defp another_sites_tenant?(_subject, _site_id), do: false

  defp required(opts, context) do
    surface = surface(context)

    (List.wrap(opts[:permissions]) ++ Enum.map(List.wrap(opts[:under]), &{:under, &1}))
    |> Enum.map(&on_surface(&1, surface))
    |> Enum.filter(&counts_on?(&1, surface))
  end

  defp on_surface({:under, :surface}, :dashboard), do: {:under, "admin:dashboard"}
  defp on_surface({:under, :surface}, :api), do: {:under, "admin:api"}
  defp on_surface(entry, _surface), do: entry

  defp counts_on?(name, surface) when is_binary(name) do
    case String.split(name, @separator, parts: 3) do
      ["admin", "dashboard", _area] -> surface == :dashboard
      ["admin", "api", _area] -> surface == :api
      _other -> true
    end
  end

  defp counts_on?(_entry, _surface), do: true

  defp holds_any?(_actor, []), do: false

  defp holds_any?(actor, required) do
    held = held(actor)
    Enum.any?(required, fn entry -> Enum.any?(held, &grants?(&1, entry)) end)
  end

  defp held(actor) do
    actor
    |> with_permissions()
    |> Map.get(:permissions)
    |> List.wrap()
    |> Enum.flat_map(fn
      %{name: name} when is_binary(name) -> [name]
      _other -> []
    end)
  end

  defp grants?(held, required) when is_binary(required), do: covers?(held, required)
  defp grants?(held, {:under, prefix}) when is_binary(prefix), do: under?(held, prefix)
  defp grants?(_held, _required), do: false

  defp under?(held, prefix),
    do: String.starts_with?(held, prefix <> @separator) or covers?(held, prefix <> ":*")

  # Validates if a specific permission grants access to an action.
  # Splits both into segments and compares hierarchically.
  defp is_permitted?(action: action, permission: permission) do
    permission_chunks = String.split(permission, @separator)

    String.split(action, @separator, parts: length(permission_chunks))
    |> check_permission(permission_chunks)
  end

  # Compares permission segments with action segments.
  # Returns false if segment counts don't match.
  # Wildcards (*) in permissions match any action segment.
  defp check_permission(action_chunks, permission_chunks)
       when length(permission_chunks) != length(action_chunks),
       do: false

  defp check_permission(action_chunks, permission_chunks) do
    Enum.zip(permission_chunks, action_chunks)
    |> Enum.find(fn {left, right} ->
      cond do
        left == "*" -> false
        left != right -> true
        true -> false
      end
    end)
    |> is_nil()
  end
end
