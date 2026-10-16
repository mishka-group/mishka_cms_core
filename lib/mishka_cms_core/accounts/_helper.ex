# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.Helper do
  @moduledoc """
  Helper functions for account management including user role checks
  and email domain configuration for multi-tenant environments.
  """

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.States.SiteState

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
  The ids among `user_ids` that belong to a master, as a `MapSet`, in one read.

  Reads with no tenant and selects only `:id`, so it answers for a site user's screen too, where a
  master's account does not load. `nil` ids are ignored, and a list with nothing left in it reads
  nothing.
  """
  @spec master_ids([Ash.UUID.t() | nil]) :: {:ok, MapSet.t()} | {:error, term()}
  def master_ids(user_ids) do
    case user_ids |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        {:ok, MapSet.new()}

      ids ->
        with {:ok, users} <-
               MishkaCmsCore.Accounts.User
               |> Ash.Query.filter(id in ^ids and is_nil(site_id))
               |> Ash.Query.select([:id])
               |> Ash.read(authorize?: false) do
          {:ok, MapSet.new(users, & &1.id)}
        end
    end
  end

  @doc """
  What a screen calls whoever did something.

    * `user` is the account as the reader's own read returned it: a user, `nil`,
      `%Ash.NotLoaded{}` or `%Ash.ForbiddenField{}`.
    * `master?` says whether the account's id is a master's (see `master_ids/1`).
    * `no_account` is what to call a record with no readable account: `:guest`, `:system` or
      `:unknown` (see `label/1`), or the words themselves.
    * `master_name` replaces `label(:master)`, such as a master's blogger name on a comment.

  Returns the email when `user` carries a readable one, else `master_name` or `label(:master)` for
  a master, else `no_account`. Never returns any part of an unreadable email.
  """
  @spec who(term(), boolean(), :guest | :system | :unknown | String.t(), String.t() | nil) ::
          String.t()
  def who(user, master?, no_account, master_name \\ nil)
  def who(%{email: %Ash.CiString{} = email}, _master?, _no_account, _name), do: to_string(email)

  def who(%{email: email}, _master?, _no_account, _name) when is_binary(email) and email != "",
    do: email

  def who(_user, true, _no_account, name) when is_binary(name) and name != "", do: name
  def who(_user, true, _no_account, _name), do: label(:master)
  def who(_user, _master?, no_account, _name) when is_atom(no_account), do: label(no_account)
  def who(_user, _master?, no_account, _name), do: no_account

  @doc """
  The word a screen shows for an account it does not name, in the `mishka_gervaz` Gettext domain:
  `:master` "Master", `:guest` "Guest" (written signed out), `:system` "System" (no user did it) and
  `:unknown` "Unknown" (an account the reader's read did not return).
  """
  @spec label(:master | :guest | :system | :unknown) :: String.t()
  def label(:master), do: dpgettext("mishka_gervaz", "account", "Master")
  def label(:guest), do: dgettext("mishka_gervaz", "Guest")
  def label(:system), do: dgettext("mishka_gervaz", "System")
  def label(:unknown), do: dgettext("mishka_gervaz", "Unknown")

  @doc """
  `user` when `reader` may see its email, else `nil`.

  A master (`site_id` nil) reads everyone's; a site user reads its own site's. Pass the result to
  `who/4` on a screen that draws an account it did not read as the reader.
  """
  @spec visible_to(term(), map() | nil) :: map() | nil
  def visible_to(%{} = user, %{site_id: nil}), do: user

  def visible_to(%{site_id: site_id} = user, %{site_id: site_id}) when is_binary(site_id),
    do: user

  def visible_to(_user, _reader), do: nil

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
  A master admin: a user whose `site_id` is nil and who is an admin of `surface` (`admin?/2`),
  either surface by default. A permission never makes a master.
  """
  @spec master_admin?(map() | nil, admin_surface()) :: boolean()
  def master_admin?(user, surface \\ :any)
  def master_admin?(%{site_id: nil} = user, surface), do: admin?(user, surface)
  def master_admin?(_user, _surface), do: false

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

  @doc """
  Who may see every site's jobs — Oban Web and the Sites screen's job panel: a master
  (`master_user?/1`) who is a full dashboard admin (`full_admin?/2`). A site's full admin never is.
  """
  @spec oban_admin?(map() | nil) :: boolean()
  def oban_admin?(user), do: master_user?(user) and full_admin?(user, :dashboard)

  @doc """
  Whether a sign-in email — a magic link, a password reset, a confirmation — may go to
  `user_or_email` for the tenant in `context`.

  A site that is up sends to anyone; an offline site to its own admins and the masters only, of
  either surface, since a link can be followed on the screens or its token used over the API; an
  inactive site to nobody. Without a tenant, as when a master signs in, it may. An email held back is
  announced on `auth:email:held` with `%{to: user_or_email, tenant: tenant}`.
  """
  @spec may_email?(map() | String.t(), map() | keyword()) :: boolean()
  def may_email?(user_or_email, context) do
    case context[:tenant] do
      nil -> true
      tenant -> allowed_or_held(tenant, user_or_email)
    end
  end

  defp allowed_or_held(tenant, user_or_email) do
    allowed? =
      MishkaCmsCore.Runtime.SiteAvailability.allowed?(tenant, known_user(user_or_email), :any)

    if not allowed? do
      MishkaInstaller.Event.Hook.call("auth:email:held", %{to: user_or_email, tenant: tenant},
        return: false
      )
    end

    allowed?
  end

  defp known_user(%{id: _id} = user), do: user
  defp known_user(_email), do: nil

  @doc """
  Determines the appropriate email sender domain based on user/email
  and tenant context for multi-site email delivery.
  Uses frontend_domain if available, otherwise falls back to host.
  """
  def get_email_sender_domain(user_or_email, context) do
    case {user_or_email, context[:tenant]} do
      {%{site_id: nil}, nil} ->
        site = SiteState.get_by_master!()
        site[:frontend_domain] || site[:host]

      {%{site_id: site_id}, tenant} when not is_nil(tenant) and site_id == tenant ->
        site = SiteState.get!(site_id)
        site[:frontend_domain] || site[:host]

      {email, tenant} when not is_nil(tenant) and is_binary(email) ->
        site = SiteState.get!(tenant)
        site[:frontend_domain] || site[:host]

      _ ->
        nil
    end
  end

  @doc """
  Builds a complete URL structure with schema, domain, and port
  for email link generation, handling localhost development environments.
  """
  def create_sender_email_link_domain(domain) do
    local? = local_domain?(domain)
    schema = if local?, do: "http://", else: "https://"

    domain_port =
      if(local?,
        do: ":#{String.to_integer(System.get_env("PORT") || "4000")}",
        else: ""
      )

    url = "#{schema <> domain <> domain_port}"
    %{schema: schema, domain: domain, port: domain_port, url: url}
  end

  # `localhost` and every `*.localhost` name, which resolve to this machine.
  defp local_domain?("localhost"), do: true
  defp local_domain?(domain) when is_binary(domain), do: String.ends_with?(domain, ".localhost")
  defp local_domain?(_none), do: false

  @doc """
  The link a sign-in email carries: `<site>/auth/<path>/<token>/`, marked for the sign-in pool the
  token belongs to — a master's when there is no tenant.
  """
  @spec auth_link(String.t(), String.t(), String.t(), term()) :: String.t()
  def auth_link(domain, path, token, tenant),
    do:
      "#{create_sender_email_link_domain(domain).url}/auth/#{path}/#{token}/?master_user=#{is_nil(tenant)}"

  @doc """
  Sends one of the sign-in emails through `MishkaCmsCore.Mail`, from the scope the tenant names —
  the installation's for a master — with that scope's provider and sender. `email` holds `:purpose`,
  `:token`, `:subject`, `:html` and `:text`. The token names the delivery, hashed, so a retry is
  never sent twice and the token itself goes nowhere but the body. Always `:ok`:
  AshAuthentication ignores a sender's answer, and an email is never worth failing the sign-in.
  """
  @spec send_auth_email(map() | String.t(), keyword() | map(), keyword()) :: :ok
  def send_auth_email(user_or_email, context, email) do
    site_id = context[:tenant]
    purpose = Keyword.fetch!(email, :purpose)

    case MishkaCmsCore.Accounts.AuthGate.check(gated_by(purpose), site_id, who(user_or_email)) do
      :ok -> deliver_auth_email(user_or_email, site_id, purpose, email)
      {:error, _closed} -> :ok
    end
  end

  # A reset or a sign-in link asked for while that way in is closed goes only to an account the
  # gate still lets through — the page answers the same either way. See `AuthGate`.
  defp gated_by("password_reset"), do: [:reset]
  defp gated_by("magic_link"), do: [:sign_in, :magic_link]
  defp gated_by(_purpose), do: []

  defp who(%{email: _} = user), do: %{user: user}
  defp who(email), do: %{email: to_string(email)}

  defp deliver_auth_email(user_or_email, site_id, purpose, email) do
    site_id
    |> MishkaCmsCore.Mail.email(
      to: recipient(user_or_email),
      subject: Keyword.fetch!(email, :subject),
      html: Keyword.fetch!(email, :html),
      text: Keyword.fetch!(email, :text)
    )
    |> MishkaCmsCore.Mail.deliver(
      site_id: site_id,
      purpose: purpose,
      idempotency_key: "#{purpose}/#{token_digest(Keyword.fetch!(email, :token))}"
    )

    :ok
  end

  defp recipient(%{email: email}), do: to_string(email)
  defp recipient(email), do: to_string(email)

  defp token_digest(token),
    do: :sha256 |> :crypto.hash(token) |> Base.url_encode64(padding: false) |> binary_part(0, 32)
end
