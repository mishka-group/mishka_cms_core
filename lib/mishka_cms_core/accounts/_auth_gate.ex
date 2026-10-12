defmodule MishkaCmsCore.Accounts.AuthGate do
  @moduledoc """
  The ways into an account a site's admin — or a master, for any site or every site — can close:
  `:sign_in`, `:register`, `:reset` (forgot password) and `:magic_link` (sign-in links). Set on the
  settings page's Security tab; see `definitions/0`.

  ## Who still gets in

  A master (`site_id` nil) always. Anyone else passes a closed scope only by its own "still
  allowed" lists: an address on `auth.allowed_emails`, or a permission on `auth.allowed_permissions`
  (`*` by default) that the account holds. The installation's switch closes every site, with the
  installation's lists; a site's switch closes that site, with the site's lists. Both are asked, so
  either can refuse.

  ## Where it is asked

  At the account actions, so the dashboard, the sign-in pages and the API all hear the same answer,
  refused with `MishkaCmsCore.Accounts.AuthGate.Closed`:

    * registering and completing a reset — policies on `MishkaCmsCore.Accounts.User` before the
      AshAuthentication bypass (`MishkaCmsCore.Accounts.Checks.AuthGateOpen`), whose
      `error_message` is `refused/3`, the way AshAuthentication's own guide asks for policies on
      its actions;
    * signing in by password, sign-in link or sign-in token — after the password or the token is
      checked (`prepare/3`), so only someone who knew it learns that sign-in is closed, and they
      read that rather than "Incorrect email or password"; the token AshAuthentication had just
      made for them is revoked;
    * asking for a reset or a sign-in link — never refused, the answer is the same for every
      address, but the email goes only to an account the gate lets through.

  ## Who is already signed in

  Closing sign-in leaves them signed in, unless the same scope also turns on
  `auth.sign_in.sign_out`: then whoever the gate would not let sign in now is signed out
  everywhere (`signs_out?/2`, `sign_out/2`) at their next request — a page
  (`MishkaCmsCore.Runtime.Plugs.SiteLookupPlug.confirm_tenant/2`), an API call or a GraphQL socket
  (`MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug.confirm_bearer_tenant/2`) — and a page already
  open reloads on its next navigation or click, or as soon as the switch is saved
  (`MishkaCmsCore.Runtime.SiteAvailability`).

  ## The site being offline

  Another question, asked on its own (`MishkaCmsCore.Runtime.SiteAvailability`): a visitor gets in
  only when neither refuses. Taking a site offline signs nobody out.

  ## Plugins

  `"auth:gate:check"` hears every decision before it is final: `%{action:, site_id:, user:, email:,
  allowed?:}`, and the `allowed?` it hands back is the answer — a captcha or an IP list can close a
  way the settings left open, or open one they closed. While its plugins cannot run
  (`MishkaCmsCore.PluginEvent.cannot_run?/1`), every way in is closed: what they would close cannot
  be told. `"auth:gate:refused"` hears each refusal
  (`return: false`), and `"auth:gate:signed_out"` each account `sign_out/2` signs out, with
  `%{site_id:, user_id:, email:}` (`return: false`).
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Accounts.AuthGate.Closed
  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.PluginEvent
  alias MishkaCmsCore.Accounts.{LiveSockets, User}
  alias MishkaCmsCore.Settings
  alias MishkaInstaller.Event.Hook

  @actions [:sign_in, :register, :reset, :magic_link]

  @type action :: :sign_in | :register | :reset | :magic_link
  @type who :: %{optional(:user) => map() | nil, optional(:email) => String.t() | nil}

  @typedoc "Values about to be saved, by scope (`nil` for Global) and key, read before the saved ones."
  @type pending :: %{optional({String.t() | nil, String.t()}) => term()}

  @doc "The ways in a gate can close."
  @spec actions() :: [action()]
  def actions, do: @actions

  @doc """
  Whether `who` — `%{user: account}` once the account is known, `%{email: address}` before — may
  take `action` on `site_id` (`nil` for a master's sign-in), with `pending` read over the saved
  settings.
  """
  @spec allowed?(action(), String.t() | nil, who(), pending()) :: boolean()
  def allowed?(action, site_id, who, pending \\ %{}) when action in @actions do
    user = Map.get(who, :user)
    email = who |> Map.get(:email) |> Kernel.||(user && Map.get(user, :email)) |> address()
    decided = decide(action, site_id, user, email, pending)

    case Hook.call("auth:gate:check", %{
           action: action,
           site_id: site_id,
           user: user,
           email: email,
           allowed?: decided
         }) do
      %{allowed?: allowed?} when is_boolean(allowed?) -> allowed?
      answer -> decided and not PluginEvent.cannot_run?(answer)
    end
  end

  @doc """
  `:ok`, or the refusal for the first of `actions` the gate keeps `who` out of — `"auth:gate:refused"`
  told about it.
  """
  @spec check([action()], String.t() | nil, who()) :: :ok | {:error, Closed.t()}
  def check(actions, site_id, who) do
    case Enum.find(actions, &(not allowed?(&1, site_id, who))) do
      nil ->
        :ok

      action ->
        Hook.call(
          "auth:gate:refused",
          %{action: action, site_id: site_id, email: address(who[:email] || email_of(who))},
          return: false
        )

        {:error, Closed.exception(action: action, site_id: site_id)}
    end
  end

  @doc """
  Whether `action` is closed on `site_id` at all — by the installation or the site — whoever asks.
  What a page says before anyone is known.
  """
  @spec closed?(action(), String.t() | nil) :: boolean()
  def closed?(action, site_id),
    do: closed_in?(action, nil, %{}) or closed_in?(action, site_id, %{})

  @doc """
  Whether `user`, signed in on `site_id`, is to be signed out: a scope that closed sign-in there also
  signs out who is in, and the gate would not let `user` sign in now. Read from the settings cache
  and the permissions `user` carries, so a cached viewer
  (`MishkaCmsCore.Runtime.States.ViewerState`) is asked as an account is. `pending` is read over the
  saved settings.
  """
  @spec signs_out?(String.t() | nil, map() | nil, pending()) :: boolean()
  def signs_out?(site_id, user, pending \\ %{})
  def signs_out?(_site_id, nil, _pending), do: false

  def signs_out?(site_id, user, pending),
    do:
      signing_out?(site_id, pending) and
        not allowed?(:sign_in, site_id, %{user: user}, pending)

  @doc """
  Whether saving `pending` would shut `user` out of `site_id` when they are not shut out now: sign
  them out, or leave them unable to sign in again. The settings page refuses such a save, so an
  admin cannot close the way in behind themselves; what someone else's switch already does to them
  is not theirs to undo, and is not asked.
  """
  @spec locks_out?(String.t() | nil, map(), pending()) :: boolean()
  def locks_out?(site_id, user, pending) do
    who = %{user: user}

    (signs_out?(site_id, user, pending) and not signs_out?(site_id, user)) or
      (allowed?(:sign_in, site_id, who) and not allowed?(:sign_in, site_id, who, pending))
  end

  @doc """
  Signs `user` out on every device with AshAuthentication's `log_out_everywhere`, which revokes every
  token it holds for them, and cuts their open pages.
  """
  @spec sign_out(Ash.Resource.record(), String.t() | nil) :: :ok
  def sign_out(user, site_id) do
    :ok =
      User
      |> AshAuthentication.Info.strategy!(:log_out_everywhere)
      |> AshAuthentication.Strategy.action(:log_out_everywhere, %{user: user}, [])

    LiveSockets.disconnect(user)

    Hook.call(
      "auth:gate:signed_out",
      %{site_id: site_id, user_id: user.id, email: address(user.email)},
      return: false
    )

    :ok
  end

  @doc """
  The read preparation that refuses a sign-in through a closed gate, once the account is found and
  its password or token checked: `prepare &AuthGate.prepare(&1, &2, [:sign_in])`.
  """
  @spec prepare(Ash.Query.t(), map(), [action()]) :: Ash.Query.t()
  def prepare(query, _context, actions) do
    Ash.Query.after_action(query, fn query, users ->
      Enum.reduce_while(users, {:ok, users}, fn user, ok ->
        case check(actions, query.tenant, %{user: user}) do
          :ok ->
            {:cont, ok}

          {:error, closed} ->
            revoke_minted(user)
            {:halt, {:error, closed}}
        end
      end)
    end)
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

  @doc """
  Who an action's changeset is for: the address being registered, or the account being reset.
  """
  @spec who(term()) :: who()
  def who(%Ash.Changeset{action_type: :create} = changeset),
    do: %{email: Ash.Changeset.get_argument(changeset, :email)}

  def who(%Ash.Changeset{data: user}), do: %{user: user}
  def who(_subject), do: %{}

  @doc """
  A gate policy's `error_message`: the refusal for `action`, told to `"auth:gate:refused"` first.

      error_message &MishkaCmsCore.Accounts.AuthGate.refused(&1, &2, :register)
  """
  @spec refused(term(), map(), action()) :: Closed.t()
  def refused(subject, context, action) do
    who = who(subject)

    Hook.call(
      "auth:gate:refused",
      %{action: action, site_id: context[:tenant], email: address(who[:email] || email_of(who))},
      return: false
    )

    Closed.exception(action: action, site_id: context[:tenant])
  end

  @doc """
  The refusal anywhere inside `reason`, or `nil`: an error or error class, a form's `raw_errors`, or
  the JSON:API errors document written for one — the shape of
  `MishkaCmsCore.Accounts.AuthRateLimit.limited/1`.
  """
  @spec refusal(term()) :: %{action: action()} | nil
  def refusal(%Closed{action: action}), do: %{action: action}

  def refusal(%{"code" => "auth_closed", "meta" => %{"action" => action}})
      when is_binary(action),
      do: Enum.find_value(@actions, &(Atom.to_string(&1) == action and %{action: &1}))

  def refusal(%{caused_by: cause}), do: refusal(cause)
  def refusal(%{errors: errors}) when is_list(errors), do: refusal(errors)
  def refusal(errors) when is_list(errors), do: Enum.find_value(errors, &refusal/1)
  def refusal(%{} = errors) when not is_struct(errors), do: errors |> Map.values() |> refusal()
  def refusal(_other), do: nil

  @doc "What to tell whoever was refused, in their language."
  @spec describe(action()) :: %{title: String.t(), text: String.t()}
  def describe(:sign_in),
    do: %{
      title: gettext("Sign-in is closed"),
      text: gettext("Signing in is switched off on this site for now.")
    }

  def describe(:register),
    do: %{
      title: gettext("Registration is closed"),
      text: gettext("This site is not taking new accounts for now.")
    }

  def describe(:reset),
    do: %{
      title: gettext("Password reset is closed"),
      text: gettext("Resetting a password is switched off on this site for now.")
    }

  def describe(:magic_link),
    do: %{
      title: gettext("Sign-in links are closed"),
      text: gettext("Signing in by email link is switched off on this site for now.")
    }

  @doc "The Security tab: what can close, and who still gets in."
  @spec definitions() :: [Settings.definition()]
  def definitions do
    [
      closed(
        :sign_in,
        gettext_noop("Close sign-in"),
        gettext_noop("Close sign-in on every site"),
        gettext_noop(
          "Nobody signs in — by password, sign-in link or the API — but the people allowed below. Masters always can. Whoever is already signed in stays, unless the next switch is on."
        )
      ),
      Settings.define("auth.sign_in.sign_out", :boolean,
        default: false,
        category: "security",
        group: gettext_noop("Closed"),
        scope: :both,
        resolve: :any,
        label: gettext_noop("Sign out who is signed in"),
        global_label: gettext_noop("Sign out who is signed in on every site"),
        description:
          gettext_noop(
            "While sign-in is closed, whoever could not sign in now is signed out on every device, at their next page, click or API call. Masters and the people allowed below stay."
          )
      ),
      closed(
        :register,
        gettext_noop("Close registration"),
        gettext_noop("Close registration on every site"),
        gettext_noop("No new accounts, except for an address on the allowed list below.")
      ),
      closed(
        :reset,
        gettext_noop("Close password reset"),
        gettext_noop("Close password reset on every site"),
        gettext_noop(
          "Reset emails go only to the people allowed below, and a reset link already sent stops working for everyone else."
        )
      ),
      closed(
        :magic_link,
        gettext_noop("Close sign-in links"),
        gettext_noop("Close sign-in links on every site"),
        gettext_noop(
          "Sign-in link emails go only to the people allowed below, and a link already sent stops working for everyone else."
        )
      ),
      Settings.define("auth.allowed_permissions", :list,
        default: ["*"],
        validate: &permission_names?/1,
        category: "security",
        group: gettext_noop("Still allowed"),
        scope: :both,
        label: gettext_noop("Permissions that still get in"),
        description:
          gettext_noop(
            "Whoever holds one of these passes whatever is closed above, separated by commas — *, admin:dashboard:*."
          )
      ),
      Settings.define("auth.allowed_emails", :list,
        default: [],
        validate: &addresses?/1,
        category: "security",
        group: gettext_noop("Still allowed"),
        scope: :both,
        label: gettext_noop("Accounts that still get in"),
        description:
          gettext_noop(
            "These addresses pass whatever is closed above, separated by commas, and may register while registration is closed."
          )
      )
    ]
  end

  defp closed(action, label, global_label, description),
    do:
      Settings.define("auth.#{action}.closed", :boolean,
        default: false,
        category: "security",
        group: gettext_noop("Closed"),
        scope: :both,
        resolve: :any,
        label: label,
        global_label: global_label,
        description: description
      )

  defp decide(_action, _site_id, %{site_id: nil, id: id}, _email, _pending) when not is_nil(id),
    do: true

  defp decide(action, site_id, user, email, pending) do
    not (refused_by?(action, nil, user, email, pending) or
           (is_binary(site_id) and refused_by?(action, site_id, user, email, pending)))
  end

  defp refused_by?(action, scope, user, email, pending),
    do: closed_in?(action, scope, pending) and not allowed_by?(scope, user, email, pending)

  defp signing_out?(site_id, pending),
    do:
      Enum.any?(
        Enum.uniq([nil, site_id]),
        &(closed_in?(:sign_in, &1, pending) and on?("auth.sign_in.sign_out", &1, pending))
      )

  defp closed_in?(action, scope, pending), do: on?("auth.#{action}.closed", scope, pending)

  defp on?(key, scope, pending) when is_nil(scope) or is_binary(scope),
    do: setting(pending, scope, key, fn -> own(key, scope) end) == true

  defp on?(_key, _none, _pending), do: false

  defp own(key, nil), do: Settings.get(key, false)
  defp own(key, site_id), do: Settings.get_own(key, false, site_id)

  defp allowed_by?(scope, user, email, pending) do
    emails = scope |> list("auth.allowed_emails", [], pending) |> Enum.map(&address/1)
    permissions = list(scope, "auth.allowed_permissions", ["*"], pending)

    (is_binary(email) and email in emails) or holds_any?(user, permissions)
  end

  defp list(nil, key, default, pending),
    do: setting(pending, nil, key, fn -> Settings.get(key, default) end)

  defp list(site_id, key, default, pending),
    do: setting(pending, site_id, key, fn -> Settings.get(key, default, site_id) end)

  defp setting(pending, scope, key, saved), do: Map.get_lazy(pending, {scope, key}, saved)

  defp holds_any?(nil, _permissions), do: false
  defp holds_any?(_user, []), do: false

  defp holds_any?(user, permissions),
    do: length(AccessPermissions.beyond(user, permissions)) < length(permissions)

  defp email_of(%{user: %{email: email}}), do: email
  defp email_of(_who), do: nil

  defp address(nil), do: nil
  defp address(email), do: email |> to_string() |> String.trim() |> String.downcase()

  defp permission_names?(names),
    do: Enum.all?(names, &Regex.match?(~r/^(\*|[a-z0-9_]+(:[a-z0-9_]+)*(:\*)?)$/, &1))

  defp addresses?(emails), do: Enum.all?(emails, &Regex.match?(~r/^[^\s@,]+@[^\s@,]+$/, &1))
end
