defmodule MishkaCmsCore.Accounts.AuthRateLimit do
  @moduledoc """
  How often someone may sign in with a password, ask for a password reset, ask for a sign-in link
  and try their current password to change it: the backend and the keys
  `MishkaCmsCore.Accounts.User` gives `ash_rate_limiter` for those four actions, and what to tell
  whoever was refused.

  The first three are counted twice, per IP address and per account; a registration once, per IP
  address; a password change once, per signed-in account. Every attempt counts, right or wrong. The DSL numbers are the defaults:

  | action | per IP address | per account | setting |
  |--------|----------------|-------------|---------|
  | `sign_in_with_password` | 30 per 5 minutes | 10 per 15 minutes | `security.sign_in_per_*` |
  | `request_password_reset_token` | 10 per hour | 3 per hour | `security.reset_request_per_*` |
  | `request_magic_link` | 10 per hour | 3 per hour | `security.magic_link_per_*` |
  | `register_with_password` | 10 per hour | — | `security.register_per_ip` |
  | `change_password` | — | 10 per 15 minutes | `security.change_password_per_account` |

  A master changes the numbers on the Settings page (`MishkaCmsCore.Settings`); the windows stay.
  `hit/3` reads the setting from the settings cache on every attempt, so a change takes effect on
  the next one. `config :mishka_cms_core, #{inspect(__MODULE__)}, limit: n` holds every action to
  `n` instead, for a test suite that signs in from one address.

  Every site is counted apart, masters together as one more. An account is its email, or its id
  once signed in; the address is the one `RemoteIp` reads with `remote_ip_options/0`, from the
  `ash_authentication_request` context: AshAuthentication writes it on the browser's `/api/auth`
  routes, `MishkaCmsCore.Runtime.Plugs.AuthRateLimitPlug` on the JSON:API and the sign-in pages'
  forms from `MishkaCmsWeb.RuntimeLive`'s `@client_request`. An IPv6 client is counted by its /64,
  and an IPv4 address written as IPv6 (`::ffff:192.0.2.7`) as that IPv4 address. An action run
  without it is counted under the address `"unknown"`.
  """
  @behaviour AshRateLimiter.Backend

  use Gettext, backend: MishkaCmsCore.Gettext

  alias AshRateLimiter.LimitExceeded
  alias MishkaCmsCore.Runtime.States.RateLimitState
  alias MishkaCmsCore.Settings

  @type limited :: %{
          action: :sign_in | :reset_request | :magic_link | :register | :change_password,
          key: :ip | :account,
          retry_after: pos_integer()
        }

  @buckets %{
    sign_in_with_password: "sign_in",
    request_password_reset_token: "reset_request",
    request_magic_link: "magic_link",
    register_with_password: "register",
    change_password: "change_password"
  }

  @actions %{
    "sign_in" => :sign_in,
    "reset_request" => :reset_request,
    "magic_link" => :magic_link,
    "register" => :register,
    "change_password" => :change_password
  }

  @scopes %{"ip" => :ip, "account" => :account}

  @titles %{
    sign_in: gettext_noop("Too many sign-in attempts"),
    reset_request: gettext_noop("Too many password reset requests"),
    magic_link: gettext_noop("Too many sign-in link requests"),
    register: gettext_noop("Too many new accounts"),
    change_password: gettext_noop("Too many password change attempts")
  }

  # Cloudflare Workers' address for a request to another zone. It lies inside Cloudflare's
  # 2a06:98c0::/29, which production trusts as a proxy, so without this a Worker's own
  # `x-forwarded-for` would be believed and every one of its requests counted as a new visitor.
  @clients ["2a06:98c0:3600::103"]

  @doc """
  Counts one hit on `key` in `MishkaCmsCore.Runtime.States.RateLimitState`, held to the setting
  `"security.<action>_per_<ip|account>"` the key names, or `limit` while that holds no positive
  integer.
  """
  @impl AshRateLimiter.Backend
  def hit(key, per, limit), do: RateLimitState.hit(key, per, limit_for(key, limit))

  defp limit_for(key, written) do
    [_auth, action, scope, _site_and_id] = String.split(key, ":", parts: 4)

    case configured() || Settings.get("security.#{action}_per_#{scope}", written) do
      limit when is_integer(limit) and limit > 0 -> limit
      _not_a_limit -> written
    end
  end

  defp configured, do: Application.get_env(:mishka_cms_core, __MODULE__, [])[:limit]

  @doc """
  The key an attempt is counted under by the address it came from, within its site:
  `"auth:<action>:ip:<site id | master>:<address>"`. The address of an IPv6 client is its /64
  (`"2001:db8:1:2::/64"`), and an IPv4 address written as IPv6 is that IPv4 address.
  """
  @spec by_address(Ash.Query.t() | Ash.ActionInput.t() | Ash.Changeset.t(), map()) :: String.t()
  def by_address(subject, context), do: key(subject, "ip", client(context))

  @doc """
  The key an attempt is counted under by the account it names, within its site:
  `"auth:<action>:account:<site id | master>:<digest of the email>"`.
  """
  @spec by_account(Ash.Query.t() | Ash.ActionInput.t(), map()) :: String.t()
  def by_account(subject, _context), do: key(subject, "account", subject |> email() |> digest())

  @doc """
  The key a signed-in account's attempt on itself is counted under, within its site:
  `"auth:<action>:account:<site id | master>:<user id>"`.
  """
  @spec by_user(Ash.Changeset.t(), map()) :: String.t()
  def by_user(%Ash.Changeset{data: %{id: id}} = changeset, _context),
    do: key(changeset, "account", id)

  defp key(%{action: %{name: name}, tenant: tenant}, scope, id),
    do: "auth:#{Map.fetch!(@buckets, name)}:#{scope}:#{tenant || "master"}:#{id}"

  defp email(%Ash.Query{} = query), do: Ash.Query.get_argument(query, :email)
  defp email(%Ash.ActionInput{} = input), do: Ash.ActionInput.get_argument(input, :email)

  defp digest(nil), do: "none"

  defp digest(email) do
    :sha256
    |> :crypto.hash(email |> to_string() |> String.trim() |> String.downcase())
    |> Base.url_encode64(padding: false)
  end

  defp client(%{ash_authentication_request: %{remote_ip: peer} = request}) do
    forwarded =
      for value <- Map.get(request, :x_forwarded_for) || [], do: {"x-forwarded-for", value}

    case RemoteIp.from(forwarded, remote_ip_options()) || parse(peer) do
      nil -> peer || "unknown"
      address -> network(address)
    end
  end

  defp client(_no_request), do: "unknown"

  defp parse(peer) when is_binary(peer) do
    case :inet.parse_strict_address(String.to_charlist(peer)) do
      {:ok, address} -> address
      {:error, _not_an_address} -> nil
    end
  end

  defp parse(_none), do: nil

  # One IPv6 client holds a whole /64, so a new address in it is not a new client.
  defp network({0, 0, 0, 0, 0, 0xFFFF, _, _} = mapped),
    do: mapped |> :inet.ipv4_mapped_ipv6_address() |> network()

  defp network({a, b, c, d, _, _, _, _}), do: "#{:inet.ntoa({a, b, c, d, 0, 0, 0, 0})}/64"
  defp network(ipv4), do: ipv4 |> :inet.ntoa() |> to_string()

  @doc """
  The options `RemoteIp` reads the client's address with: `x-forwarded-for`, right to left, passing
  over private addresses and `config :mishka_cms_core, :trusted_proxies` (IPs or CIDR ranges), but
  never over Cloudflare Workers' address for a request to another zone, `2a06:98c0:3600::103`. The
  endpoint's `plug RemoteIp` and the `/auth` socket take the same ones.
  """
  @spec remote_ip_options() :: keyword()
  def remote_ip_options,
    do: [
      headers: ["x-forwarded-for"],
      proxies: {__MODULE__, :trusted_proxies, []},
      clients: @clients
    ]

  @doc false
  @spec trusted_proxies() :: [String.t()]
  def trusted_proxies, do: Application.get_env(:mishka_cms_core, :trusted_proxies, [])

  @doc """
  Reads `config :mishka_cms_core, :trusted_proxies` the way every request does, and raises
  `ArgumentError` naming the first entry that is no IP or CIDR range. Call it before the endpoint
  starts, so a mistyped `TRUSTED_PROXY_RANGES` stops the boot.
  """
  @spec validate_trusted_proxies!() :: :ok
  def validate_trusted_proxies! do
    RemoteIp.from([], remote_ip_options())
    :ok
  end

  @doc """
  The refusal anywhere inside `reason`, or `nil`: an error or error class, a form's `raw_errors`,
  an `AshAuthentication.Errors.AuthenticationFailed`, or the JSON:API errors document written for
  one.

      AuthRateLimit.limited(Form.raw_errors(form, for_path: :all))
      #=> %{action: :sign_in, key: :account, retry_after: 812}
  """
  @spec limited(term()) :: limited() | nil
  def limited(%LimitExceeded{key: key, per: per}) when is_binary(key) do
    with ["auth", action, scope, _site_and_id] <- String.split(key, ":", parts: 4),
         %{} = limited <- named(action, scope) do
      Map.put(limited, :retry_after, retry_after(key, per))
    else
      _not_ours -> nil
    end
  end

  def limited(%{"code" => "rate_limited", "meta" => meta}) do
    with %{"action" => action, "limited_by" => scope, "retry_after" => seconds} <- meta,
         %{} = limited <- named(action, scope) do
      Map.put(limited, :retry_after, seconds)
    else
      _not_ours -> nil
    end
  end

  def limited(%{caused_by: cause}), do: limited(cause)
  def limited(%{errors: errors}) when is_list(errors), do: limited(errors)
  def limited(errors) when is_list(errors), do: Enum.find_value(errors, &limited/1)
  def limited(%{} = errors) when not is_struct(errors), do: errors |> Map.values() |> limited()
  def limited(_other), do: nil

  defp named(action, scope) do
    with {:ok, action} <- Map.fetch(@actions, action),
         {:ok, scope} <- Map.fetch(@scopes, scope),
         do: %{action: action, key: scope},
         else: (:error -> nil)
  end

  defp retry_after(key, per) do
    wait = RateLimitState.expires_at(key, per) - System.system_time(:millisecond)
    max(div(wait + 999, 1000), 1)
  end

  @doc """
  What to tell whoever was refused: a title naming what they asked for too often, and how long to
  wait.

      AuthRateLimit.describe(%{action: :sign_in, key: :account, retry_after: 90})
      #=> %{title: "Too many sign-in attempts", text: "Try again in 2 minutes."}
  """
  @spec describe(limited()) :: %{title: String.t(), text: String.t()}
  def describe(%{action: action, retry_after: seconds}),
    do: %{
      title: Gettext.gettext(MishkaCmsCore.Gettext, Map.fetch!(@titles, action)),
      text: wait(seconds)
    }

  defp wait(seconds) when seconds < 60,
    do: ngettext("Try again in %{count} second.", "Try again in %{count} seconds.", seconds)

  defp wait(seconds),
    do:
      ngettext(
        "Try again in %{count} minute.",
        "Try again in %{count} minutes.",
        div(seconds + 59, 60)
      )
end
