defmodule MishkaCmsCore.Accounts.Helper do
  @moduledoc """
  Helper functions for account management including user role checks
  and email domain configuration for multi-tenant environments.
  """

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions

  require Ash.Query

  @doc """
  Whether `user` is a master: a user whose `site_id` is nil.

  False for `nil` and for anything that does not carry a `site_id`. Permissions play no part: a site
  user holding `*` is not a master.
  """
  @spec master_user?(map() | nil) :: boolean()
  def master_user?(%{site_id: nil}), do: true
  def master_user?(_user), do: false

  @doc """
  The ids of the permissions the account `user_id` holds now, as a `MapSet` of strings, read with no
  authorization: what an account holds is not a question of who asks. Empty for no account.
  """
  @spec permission_ids(String.t() | nil) :: MapSet.t(String.t())
  def permission_ids(user_id) when is_binary(user_id) do
    MishkaCmsCore.Accounts.UserPermission
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.Query.select([:permission_id])
    |> Ash.read!(authorize?: false)
    |> MapSet.new(&to_string(&1.permission_id))
  end

  def permission_ids(_no_account), do: MapSet.new()

  @doc """
  The names of the permissions the account `user_id` holds now, read with no authorization, as
  `permission_ids/1` reads their ids. Empty for no account.
  """
  @spec permission_names(String.t() | nil) :: [String.t()]
  def permission_names(user_id), do: user_id |> permission_ids() |> MapSet.to_list() |> names_of()

  @doc """
  The names of the catalogue rows whose ids are `permission_ids`, read with no authorization. An id
  that names no row names nothing.
  """
  @spec names_of([String.t()]) :: [String.t()]
  def names_of([]), do: []

  def names_of(permission_ids) when is_list(permission_ids) do
    MishkaCmsCore.Accounts.Permission
    |> Ash.Query.filter(id in ^permission_ids)
    |> Ash.Query.select([:name])
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.name)
  end

  @typedoc "A surface, or `:any` for either one."
  @type admin_surface :: :dashboard | :api | :any

  @doc """
  A dashboard admin: holds anything under `admin:dashboard`, whatever their site.

  Every predicate below reads the permissions the user was loaded with, so a signed-in user costs no
  query, and also takes the viewer `MishkaCmsCore.Runtime.States.ViewerState` caches for a user.
  """
  @spec dashboard_admin?(map() | nil) :: boolean()
  def dashboard_admin?(%{dashboard_admin?: cached}) when is_boolean(cached), do: cached
  def dashboard_admin?(user), do: AccessPermissions.holds_under?(user, "admin:dashboard")

  @doc "An API admin: holds anything under `admin:api`, whatever their site."
  @spec api_admin?(map() | nil) :: boolean()
  def api_admin?(%{api_admin?: cached}) when is_boolean(cached), do: cached
  def api_admin?(user), do: AccessPermissions.holds_under?(user, "admin:api")

  @doc """
  An admin of `surface` — `:dashboard`, `:api`, or `:any` (the default) for either one.
  """
  @spec admin?(map() | nil, admin_surface()) :: boolean()
  def admin?(user, surface \\ :any)
  def admin?(user, :dashboard), do: dashboard_admin?(user)
  def admin?(user, :api), do: api_admin?(user)

  def admin?(user, :any) do
    user = AccessPermissions.with_permissions(user)
    dashboard_admin?(user) or api_admin?(user)
  end

  @doc """
  An admin of `site_id`: a user of that site who is an admin of `surface` (`admin?/2`), for that
  site only. `surface` defaults to `:dashboard`; pass `:api` for a request to the admin API, or
  `:any` for either.
  """
  @spec site_admin?(map() | nil, String.t() | nil, admin_surface()) :: boolean()
  def site_admin?(user, site_id, surface \\ :dashboard)

  def site_admin?(%{site_id: site_id} = user, site_id, surface) when is_binary(site_id),
    do: admin?(user, surface)

  def site_admin?(_user, _site_id, _surface), do: false

  @doc """
  A full admin of `surface`: holds `admin:<surface>:*` or a wildcard covering it — never a set of
  narrower names.
  """
  @spec full_admin?(map() | nil, :dashboard | :api) :: boolean()
  def full_admin?(user, :dashboard),
    do: AccessPermissions.match?(user, %{}, permissions: ["admin:dashboard:*"])

  def full_admin?(user, :api),
    do:
      AccessPermissions.match?(user, %{shared: %{admin_surface: :api}},
        permissions: ["admin:api:*"]
      )
end
