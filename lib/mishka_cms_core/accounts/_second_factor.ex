defmodule MishkaCmsCore.Accounts.SecondFactor do
  @moduledoc """
  An authenticator app as a second step after the password, for an account that has set one up:
  AshAuthentication's `totp` strategy on `MishkaCmsCore.Accounts.User`. An account without one signs
  in with its password alone, as before.

  ## Setting one up

  On the settings page's Preferences tab (`MishkaCmsCoreWeb.Live.Admin.Components.TwoFactor`), by
  the strategy's own two steps: `setup_with_totp` hands back the `otpauth://` address and a setup
  token without storing anything, and `confirm_setup_with_totp` stores the secret once a code from
  the app matches it. Only for one's own account. `disable_totp` turns it off with a current code;
  an admin of the account's site, or a master, turns it off for someone who lost the app
  (`turn_off_totp`, the Users page), with a current code from their own (`step_up/2`).

  ## Where it is asked

  At the account actions, so the sign-in page, AshAuthentication's own routes and the API hear the
  same answer, refused with `MishkaCmsCore.Accounts.SecondFactor.Needed`:

    * signing in by password (`prepare/3` with `:code`) — after the password is checked, so only
      someone who knew it learns that a code is needed; the account's `totp_code` argument has to
      be a current code, or its `recovery_code` one of its recovery codes. The sign-in page asks
      for it as a second step and keeps the password in its process meanwhile; an API client sends
      it with the password. A code is accepted once (`last_totp_at`);
    * signing in by sign-in link (`prepare/3` with `:refuse`) — refused, since a link proves the
      mailbox and not the authenticator;
    * any other way AshAuthentication signs in in the browser — refused a session by
      `MishkaCmsCoreWeb.AuthController` (`session_refused?/2`).

  In each case the token AshAuthentication had already made is revoked, as `AuthGate` does.

  ## Plugins

  `"auth:second_factor:refused"` hears each refused sign-in (`return: false`), with
  `%{user_id:, site_id:, reason:}`; `"auth:second_factor:enabled"`,
  `"auth:second_factor:disabled"` and `"auth:recovery_codes:generated"` each account that turned it
  on or off or made recovery codes — see `MishkaCmsCore.Accounts.Changes.AnnounceSecondFactor`;
  `"auth:recovery_code:used"` each sign-in that took a recovery code, with
  `%{user_id:, site_id:, left:}`. The account is emailed on the second and the last
  (`MishkaCmsCore.Accounts.User.Notices.SecondFactorTurnedOff`,
  `MishkaCmsCore.Accounts.User.Notices.RecoveryCodeUsed`).
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Expr
  require Ash.Query

  alias MishkaCmsCore.Accounts.{AuthRateLimit, User}
  alias MishkaCmsCore.Settings
  alias MishkaCmsCore.Accounts.SecondFactor.Needed
  alias MishkaInstaller.Event.Hook

  @type reason :: :required | :invalid | :password | :own

  @codes %{
    "second_factor_required" => :required,
    "second_factor_invalid" => :invalid,
    "second_factor_password" => :password,
    "second_factor_own" => :own
  }

  @doc "Whether `user` has an authenticator set up."
  @spec enabled?(term()) :: boolean()
  def enabled?(%{totp_secret: secret}) when is_binary(secret) and secret != "", do: true
  def enabled?(_user), do: false

  @doc "Whether signing in asks `user` for a code: it has an authenticator."
  @spec asked?(map()) :: boolean()
  def asked?(user), do: enabled?(user)

  @doc """
  The `otpauth://` address `setup_with_totp` hands back, named after the account's site: its
  `site.title` setting (the global one for a master), which the authenticator app lists the code
  under. A title left empty names it after the strategy's `issuer`. Only the name changes; codes are
  checked against the secret alone.

      SecondFactor.setup_url(started.__metadata__.totp_url, user)
      #=> "otpauth://totp/Acme:ada%40example.com?secret=…&issuer=Acme&period=30"
  """
  @spec setup_url(String.t(), User.t()) :: String.t()
  def setup_url(totp_url, %{site_id: site_id, email: email}) do
    strategy = AshAuthentication.Info.strategy!(User, :totp)
    issuer = issuer(site_id, strategy.issuer)

    secret =
      totp_url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("secret")
      |> Base.decode32!(padding: false)

    NimbleTOTP.otpauth_uri("#{issuer}:#{email}", secret,
      issuer: issuer,
      period: strategy.period
    )
  end

  # An app reads the name up to the first colon, so a title keeps none.
  defp issuer(site_id, fallback) do
    title = "site.title" |> Settings.get(fallback, site_id) |> to_string()

    case title |> String.replace(":", "") |> String.trim() do
      "" -> fallback
      name -> name
    end
  end

  @doc """
  The read preparation on a sign-in action, after the one that checks the password or the token:
  `prepare &SecondFactor.prepare(&1, &2, :code)` asks a current code in `totp_code`,
  `prepare &SecondFactor.prepare(&1, &2, :refuse)` refuses every account that has an authenticator.
  """
  @spec prepare(Ash.Query.t(), map(), :code | :refuse) :: Ash.Query.t()
  def prepare(query, _context, way) do
    Ash.Query.after_action(query, fn query, users ->
      Enum.reduce_while(users, {:ok, users}, fn user, ok ->
        case passed(way, user, query) do
          :ok ->
            {:cont, ok}

          {:error, error} ->
            refused(user, error)
            {:halt, {:error, error}}
        end
      end)
    end)
  end

  defp passed(way, user, query) do
    cond do
      not asked?(user) -> :ok
      way == :refuse -> {:error, Needed.exception(reason: :password)}
      true -> second_step(user, query)
    end
  end

  defp second_step(user, query) do
    use_code(user, Ash.Query.get_argument(query, :totp_code), query.tenant)
  end

  @doc """
  Checks `code` against `user`'s authenticator with the strategy's `verify_with_totp`, counted by
  its rate limit. `:ok`, `{:error, %Needed{}}` for a missing or wrong code, or the limiter's own
  refusal.
  """
  @spec check(User.t(), String.t() | nil, String.t() | nil) :: :ok | {:error, term()}
  def check(_user, code, _tenant) when code in [nil, ""],
    do: {:error, Needed.exception(reason: :required)}

  # THE ACCOUNT AS STORED, not as the caller holds it: `verify_with_totp` reuses the secret and the
  # last accepted code's time of the record it is given, and a session's copy can be older than both.
  def check(user, code, tenant) do
    with {:ok, stored} <- Ash.get(User, user.id, tenant: tenant, authorize?: false) do
      User
      |> Ash.ActionInput.for_action(:verify_with_totp, %{user: stored, code: to_string(code)},
        tenant: tenant,
        authorize?: false
      )
      |> Ash.run_action()
      |> case do
        {:ok, true} -> :ok
        {:ok, false} -> {:error, Needed.exception(reason: :invalid)}
        {:error, error} -> {:error, error}
      end
    end
  end

  @doc """
  `check/3`, and the code is then spent: `verify_with_totp` refuses a code from before
  `last_totp_at`, and writing it here, only while it is still older than now, keeps two requests
  racing with one code from both getting through.
  """
  @spec use_code(User.t(), String.t() | nil, String.t() | nil) :: :ok | {:error, term()}
  def use_code(user, code, tenant) do
    now = DateTime.utc_now()

    with :ok <- check(user, code, tenant) do
      user
      |> Ash.Changeset.for_update(:record_totp_use, %{}, tenant: tenant, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:last_totp_at, now)
      |> Ash.Changeset.filter(Ash.Expr.expr(is_nil(last_totp_at) or last_totp_at < ^now))
      |> Ash.update()
      |> case do
        {:ok, _user} -> :ok
        {:error, _stale} -> {:error, Needed.exception(reason: :invalid)}
      end
    end
  end

  @doc """
  A current code from `actor`'s own authenticator, for an admin's action on another account
  (`turn_off_totp`): `use_code/3` on the admin's own account, or `{:error, %Needed{reason: :own}}`
  when they have not set one up.
  """
  @spec step_up(map() | nil, String.t() | nil) :: :ok | {:error, term()}
  def step_up(%{id: id, site_id: site_id}, code) do
    with {:ok, stored} <- Ash.get(User, id, tenant: site_id, authorize?: false) do
      if enabled?(stored),
        do: use_code(stored, code, site_id),
        else: {:error, Needed.exception(reason: :own)}
    end
  end

  def step_up(_no_actor, _code), do: {:error, Needed.exception(reason: :own)}

  @doc """
  The one line a person is told when a code they typed was refused — too many tries, a code that
  did not match, or none set up for their own account.
  """
  @spec explain(term()) :: String.t()
  def explain(error) do
    %{title: title, text: text} =
      case AuthRateLimit.limited(error) do
        %{} = limited -> AuthRateLimit.describe(limited)
        nil -> describe(refusal(error) || :invalid)
      end

    "#{title}. #{text}"
  end

  defp refused(user, error) do
    revoke_minted(user)

    Hook.call(
      "auth:second_factor:refused",
      %{user_id: user.id, site_id: user.site_id, reason: reason(error)},
      return: false
    )
  end

  # AshAuthentication signs — and, with `store_all_tokens?`, stores — the account's token before
  # this check runs. It is never handed out, and is revoked here so no unused one is left valid.
  defp revoke_minted(user) do
    case Ash.Resource.get_metadata(user, :token) do
      token when is_binary(token) ->
        AshAuthentication.TokenResource.revoke(MishkaCmsCore.Accounts.Token, token)

      _none ->
        :ok
    end
  end

  defp reason(%Needed{reason: reason}), do: reason
  defp reason(_limited), do: :limited

  @doc """
  Why a sign-in was refused a second factor, out of whatever error shape it reached its caller in —
  an Ash error, an AshPhoenix form's raw errors, or a JSON:API error document. `nil` for any other
  refusal.
  """
  @spec refusal(term()) :: reason() | nil
  def refusal(%Needed{reason: reason}), do: reason
  def refusal(%{"code" => code}) when is_map_key(@codes, code), do: Map.fetch!(@codes, code)
  def refusal(%{caused_by: cause}), do: refusal(cause)
  def refusal(%{errors: errors}) when is_list(errors), do: refusal(errors)
  def refusal(errors) when is_list(errors), do: Enum.find_value(errors, &refusal/1)
  def refusal(%{} = errors) when not is_struct(errors), do: errors |> Map.values() |> refusal()
  def refusal(_other), do: nil

  @doc "What a visitor is told for each refusal."
  @spec describe(reason()) :: %{title: String.t(), text: String.t()}
  def describe(:required),
    do: %{
      title: gettext("Enter your authenticator code"),
      text: gettext("This account asks for a code from its authenticator app after the password.")
    }

  def describe(:invalid),
    do: %{
      title: gettext("That code did not match"),
      text: gettext("Enter the current code from your authenticator app.")
    }

  def describe(:own),
    do: %{
      title: gettext("Set up two-step sign-in for your own account first"),
      text:
        gettext(
          "Turning it off for someone else asks a code from your own authenticator app. Set it up on Settings → Preferences."
        )
    }

  def describe(:password),
    do: %{
      title: gettext("Sign in with your password"),
      text:
        gettext("This account signs in with its password and a code from its authenticator app.")
    }
end
