# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.AuthController do
  @moduledoc """
  Authentication controller for MishkaCms user authentication workflows.

  Handles authentication success/failure scenarios and session management using
  the AshAuthentication framework. Provides a seamless user experience with
  intelligent redirects, contextual messaging, and secure session handling.

  ## Key Features

  - **Multi-Activity Support**: Handles various authentication activities (sign-in, password reset, email confirmation)
  - **Smart Redirects**: Returns users to their intended destination after authentication
  - **Contextual Messaging**: Activity-specific success and error messages
  - **Session Management**: Secure session storage and cleanup
  - **Error Handling**: Comprehensive error categorization with user-friendly messages
  - **Security-First**: Proper session invalidation and secure sign-out

  ## Authentication Activities

  The controller handles multiple authentication scenarios:
  - **Sign In**: Standard email/password authentication
  - **Email Confirmation**: New user email verification
  - **Password Reset**: Secure password reset workflow
  - **Sign Out**: Session termination and cleanup

  ## Success Flow

  Authentication success triggers:
  1. **Return Path Resolution**: Verifies the signed `return_to` token, or defaults to home
  2. **Session Management**: Stores user authentication state
  3. **User Assignment**: Sets current user in connection assigns
  4. **Activity Messaging**: Displays appropriate success message
  5. **Redirect**: Returns user to intended destination

  ## Failure Flow

  Authentication failures provide:
  1. **Error Categorization**: Specific error type identification
  2. **User-Friendly Messages**: Clear, actionable error descriptions
  3. **Secure Redirects**: Returns to sign-in page for retry
  4. **Context Preservation**: Maintains user workflow state

  ## Session Security

  - **Secure Storage**: Uses AshAuthentication session management
  - **Session Cleanup**: Proper session termination on sign-out
  - **Live Sockets Named**: The session carries a `live_socket_id`, so every LiveView the browser
    goes on to open can be cut the moment this account's authentication or authorization changes —
    see `MishkaCmsCore.Accounts.LiveSockets`
  - **Return Path Never Stored**: The destination travels as a `MishkaCmsCoreWeb.ReturnTo` token, so
    the session holds nothing to clean up and a sign-out always goes home
  - **Second Factor**: An account with an authenticator gets a session only from the password
    sign-in, which asked for its code (`MishkaCmsCore.Accounts.SecondFactor`); any other way in
    ends on the sign-in page with its token revoked
  - **XSS Prevention**: Secure session handling prevents cross-site attacks

  ## Error Message Examples

  ### Email Confirmation Required
  ```
  "You have already signed in another way, but have not confirmed your account.
  You can confirm your account using the link we sent to you, or by resetting your password."
  ```

  ### Invalid Credentials
  ```
  "Incorrect email or password"
  ```

  ## Success Message Examples

  - **Email Confirmation**: "Your email address has now been confirmed"
  - **Password Reset**: "Your password has successfully been reset"
  - **Sign In**: "You are now signed in"
  - **Sign Out**: "You are now signed out"

  ## Security Considerations

  - **Session Security**: Proper session invalidation prevents session hijacking
  - **CSRF Protection**: Integration with Phoenix CSRF protection
  - **Secure Redirects**: Only a path this application signed is redirected to, so a `return_to`
    anyone writes into the URL cannot open-redirect
  - **Error Information**: Limited error details prevent user enumeration
  - **Rate Limiting**: Signing in and the reset and sign-in link requests are limited per address and
    per account; a refused one is answered `429` with a page saying how long to wait — see
    `MishkaCmsCore.Accounts.AuthRateLimit`

  ## Integration with AshAuthentication

  Leverages AshAuthentication.Phoenix.Controller for:
  - **Automatic Route Generation**: Standard authentication routes
  - **Session Management**: Secure session storage and retrieval
  - **Error Handling**: Comprehensive error categorization
  - **Activity Tracking**: Different authentication activity types

  ## User Experience Features

  - **Seamless Flow**: Users return to intended destination after authentication
  - **Clear Messaging**: Activity-specific success and error messages
  - **Progressive Enhancement**: Works with and without JavaScript
  - **Accessibility**: Screen reader friendly messaging

  ## Production Considerations

  - **Monitoring**: Track authentication success/failure rates
  - **Rate Limiting**: Implement authentication attempt rate limiting
  - **Audit Logging**: Log authentication events for security analysis
  - **Session Management**: Monitor session lifecycle and cleanup
  - **Error Tracking**: Monitor authentication errors for security threats
  - **Performance**: Optimize redirect performance for user experience

  ## Customization Points

  - **Return Path Logic**: Customize redirect destination logic
  - **Message Customization**: Modify success/error messages
  - **Session Storage**: Customize session key names and storage
  - **Error Handling**: Add additional error categorization
  - **Analytics Integration**: Add authentication event tracking

  ## Multi-tenant Considerations

  - **Site Context**: Authentication respects current site context
  - **User Scoping**: Users may have different permissions per site
  - **Session Isolation**: Sessions respect tenant boundaries
  - **Redirect Handling**: Return paths respect site routing
  """
  # Phoenix.Controller directly rather than the host's `:controller`: that one also imports Inertia,
  # which is the application's dependency, not this library's.
  use Phoenix.Controller, formats: [:html, :json]
  use AshAuthentication.Phoenix.Controller
  use Gettext, backend: MishkaCmsCore.Gettext

  import Plug.Conn

  # Extensions compile before the host's router exists, so `~p` is unavailable here.
  import MishkaCmsCore.Helpers, only: [path: 2]

  alias MishkaCmsCore.Accounts.{AuthGate, AuthRateLimit, CaptchaCheck, LiveSockets, SecondFactor}
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.Plugs.{AuthRateLimitPlug, SiteLookupPlug}
  alias MishkaCmsCore.Runtime.SiteAvailability
  alias MishkaCmsCoreWeb.ReturnTo
  alias MishkaInstaller.Event.Hook

  # Whose session the sign-out clears: AshAuthentication enumerates that app's authenticated resources
  # to revoke their tokens, and they are declared under the HOST's `:ash_domains`.
  @host_app Application.compile_env!(:mishka_cms_core, :host_app)

  # NOBODY SIGNED IN: a reset or a magic link was asked for over its route, which ends here with no
  # user whether or not an account holds the address. The answer says neither, as the `/auth` forms'
  # does. `AuthController.Success.Requested` may word it, or answer with a redirect of its own.
  def success(conn, activity, nil, _token) do
    %{
      conn: conn,
      activity: activity,
      message: gettext("If an account exists for that email, a link is on its way.")
    }
    |> then(&Hook.call("AuthController.Success.Requested", &1))
    |> then(fn
      %{conn: %Plug.Conn{halted: true} = conn} ->
        conn

      data ->
        data.conn
        |> put_flash(:info, data.message)
        |> redirect(to: sign_in_page(data.conn))
    end)
  end

  def success(conn, activity, user, token) do
    cond do
      refused?(conn, user) -> refuse(conn, user)
      second_factor_skipped?(activity, user) -> second_factor_owed(conn, token)
      true -> signed_in(conn, activity, user, token)
    end
  end

  # A WAY IN THAT ASKED NO AUTHENTICATOR CODE opens no session for an account that has one: only the
  # password sign-in asks for it (`MishkaCmsCore.Accounts.SecondFactor`). A sign-in link is refused
  # before it gets here; a password reset of such an account ends on the sign-in page instead, and
  # the token it was handed is revoked.
  defp second_factor_skipped?({:password, how}, _user)
       when how in [:sign_in, :sign_in_with_token],
       do: false

  defp second_factor_skipped?(_activity, user), do: SecondFactor.asked?(user)

  defp second_factor_owed(conn, token) do
    if is_binary(token),
      do: AshAuthentication.TokenResource.revoke(MishkaCmsCore.Accounts.Token, token)

    conn
    |> put_flash(
      :info,
      gettext("Sign in with your password and the code from your authenticator app.")
    )
    |> redirect(to: sign_in_page(conn))
  end

  # THE SIGN-IN PAGE IN THE LANGUAGE THE VISITOR READS PAGES IN — the one the last page they read
  # left in the session (`MishkaCmsCore.Runtime.Plugs.LanguagePlug`), so a sign-in started on
  # `/fa/auth` comes back to `/fa/auth`.
  defp sign_in_page(conn) do
    site_id =
      case conn.assigns[:current_site] do
        %{id: id} -> id
        _no_site -> nil
      end

    path(conn, SiteLookupPlug.auth_address(get_session(conn, Languages.session()), site_id))
  end

  # AN OFFLINE SITE SIGNS IN ONLY THOSE WHO MAY SEE IT. Every way in ends here — password, magic
  # link, password reset, OAuth, `?master_user=true` — so this is the one place that has to ask. An
  # inactive site never gets this far: `SiteLookupPlug` answers its address before any route.
  defp refused?(%{assigns: %{current_site: %{id: site_id}}}, user),
    do: not SiteAvailability.allowed?(site_id, user)

  defp refused?(_no_site, _user), do: false

  # `AuthController.Success.Refused` may word the message, or answer with a redirect of its own.
  defp refuse(conn, user) do
    %{
      conn: conn,
      user: user,
      message: gettext("This site is offline. Only its administrators can sign in.")
    }
    |> then(&Hook.call("AuthController.Success.Refused", &1))
    |> then(fn
      %{conn: %Plug.Conn{halted: true} = conn} ->
        conn

      data ->
        data.conn
        |> put_flash(:error, data.message)
        |> redirect(to: sign_in_page(data.conn))
    end)
  end

  defp signed_in(conn, activity, user, _token) do
    :telemetry.span(
      [:mishka_cms, :auth, :success],
      %{activity: inspect(activity), user_id: user.id},
      fn ->
        conn =
          %{conn: conn, user: user, activity: activity}
          |> then(&Hook.call("AuthController.Success.BeforeAuth", &1))
          |> Map.get(:conn)

        # SOMEWHERE ON THIS SITE, OR NOWHERE. `return_to` is a token `MishkaCmsCoreWeb.ReturnTo`
        # signed over a path the router matched, so nothing anyone writes into the URL is followed:
        # whatever does not verify goes home.
        return_to = ReturnTo.verify(conn, conn.params["return_to"]) || path(conn, "/")

        {activity_type, message} =
          case activity do
            {:confirm_new_user, :confirm} ->
              %{
                conn: conn,
                user: user,
                message: gettext("Your email address has now been confirmed")
              }
              |> then(&Hook.call("AuthController.Success.EmailConfirmed", &1))
              |> then(&{:email_confirmation, &1.message})

            {:password, :reset} ->
              %{
                conn: conn,
                user: user,
                message: gettext("Your password has successfully been reset")
              }
              |> then(&Hook.call("AuthController.Success.PasswordReset", &1))
              |> then(&{:password_reset, &1.message})

            _ ->
              %{conn: conn, user: user, message: gettext("You are now signed in")}
              |> then(&Hook.call("AuthController.Success.SignIn", &1))
              |> then(&{:sign_in, &1.message})
          end

        :telemetry.execute(
          [:mishka_cms, :auth, :activity],
          %{count: 1},
          %{activity_type: activity_type, user_id: user.id, return_path: return_to}
        )

        result =
          %{conn: conn, user: user, activity: activity_type}
          |> then(&Hook.call("AuthController.Success.AfterAuthentication", &1))
          |> then(&%{conn: &1.conn, user: user, return_to: return_to, message: message})
          |> then(&Hook.call("AuthController.Success.BeforeRedirect", &1))
          |> then(fn data ->
            data.conn
            |> store_in_session(user)
            |> put_session(:live_socket_id, LiveSockets.live_socket_id(user))
            |> assign(:current_user, user)
            |> put_flash(:info, data.message)
            |> redirect(to: data.return_to)
          end)

        {result, %{}}
      end
    )
  end

  # A sign-in or a request refused for its rate is answered with how long to wait, not as a wrong
  # password — see `MishkaCmsCore.Accounts.AuthRateLimit`.
  def failure(conn, activity, reason) do
    case AuthRateLimit.limited(reason) do
      nil -> failed(conn, activity, reason)
      limited -> rate_limited(conn, limited)
    end
  end

  # `auth:request:rate_limited` hears it first, and a plugin that halts the conn answers instead.
  defp rate_limited(conn, limited) do
    conn =
      Hook.call("auth:request:rate_limited", conn,
        meta: Map.put(limited, :site, conn.assigns[:current_site])
      )

    if conn.halted,
      do: conn,
      else:
        conn
        |> AuthRateLimitPlug.put_refusal_headers(limited.retry_after)
        |> put_resp_content_type("text/html")
        |> send_resp(429, rate_limited_page(conn, limited))
        |> halt()
  end

  # THE NONCE COMES OFF THE CONN, as the maintenance page's does: this is a whole document written
  # here, and nothing else marks its `<style>` as ours.
  defp rate_limited_page(conn, limited) do
    %{title: title, text: text} = AuthRateLimit.describe(limited)
    title = Plug.HTML.html_escape(title)
    text = Plug.HTML.html_escape(text)
    nonce = conn.assigns[:csp_nonce]

    """
    <!DOCTYPE html>
    <html>
      <head>
        <title>#{title}</title>
        <style#{if is_binary(nonce), do: ~s( nonce="#{nonce}"), else: ""}>
          body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            text-align: center;
            padding: 50px;
            background-color: #f5f5f5;
            color: #333;
          }
          .container {
            max-width: 600px;
            margin: 0 auto;
            background: white;
            padding: 40px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
          }
          h1 { color: #c0473d; margin-bottom: 20px; }
          p { color: #666; line-height: 1.6; }
          a { color: #2980b9; }
        </style>
      </head>
      <body>
        <div class="container" id="auth-rate-limited">
          <h1>#{title}</h1>
          <p>#{text}</p>
          <p><a href="#{sign_in_page(conn)}">#{gettext("Back to sign in")}</a></p>
        </div>
      </body>
    </html>
    """
  end

  defp failed(conn, activity, reason) do
    :telemetry.span(
      [:mishka_cms, :auth, :failure],
      %{activity: inspect(activity)},
      fn ->
        conn =
          %{conn: conn, activity: activity, reason: reason}
          |> then(&Hook.call("AuthController.Failure.BeforeFailure", &1))
          |> Map.get(:conn)

        {failure_type, message} = failure_message(conn, activity, reason)

        reason_module =
          case reason do
            %{__struct__: module} -> to_string(module)
            _ -> "unknown"
          end

        :telemetry.execute(
          [:mishka_cms, :auth, :failure_reason],
          %{count: 1},
          %{failure_type: failure_type, activity: inspect(activity), reason_module: reason_module}
        )

        result =
          %{
            conn: conn,
            message: message,
            redirect_to: sign_in_page(conn),
            failure_type: failure_type
          }
          |> then(&Hook.call("AuthController.Failure.BeforeRedirect", &1))
          |> then(fn data ->
            data.conn
            |> put_flash(:error, data.message)
            |> redirect(to: data.redirect_to)
          end)

        {result, %{}}
      end
    )
  end

  # A WAY IN THE SITE HAS CLOSED, said as itself rather than as a wrong password — the refusal comes
  # only after the password or the token was right. See `MishkaCmsCore.Accounts.AuthGate`.
  #
  # AN AUTHENTICATOR CODE STILL OWED, likewise: a sign-in link to an account with one, or a password
  # posted without its code. See `MishkaCmsCore.Accounts.SecondFactor`.
  #
  # A CAPTCHA NOT PASSED, likewise, and before either: the refusal comes before the password is
  # checked. See `MishkaCmsCore.Accounts.CaptchaCheck`.
  defp failure_message(conn, activity, reason) do
    with nil <- CaptchaCheck.refusal(reason),
         nil <- AuthGate.refusal(reason),
         nil <- SecondFactor.refusal(reason) do
      credentials_failure(conn, activity, reason)
    else
      %{reason: captcha} -> {:captcha, captcha_text(captcha)}
      %{action: action} -> closed_failure(conn, activity, reason, action)
      second_factor -> {:second_factor, second_factor_text(second_factor)}
    end
  end

  defp captcha_text(reason) do
    %{title: title, text: text} = CaptchaCheck.describe(reason)
    "#{title}. #{text}"
  end

  defp second_factor_text(reason) do
    %{title: title, text: text} = SecondFactor.describe(reason)
    "#{title}. #{text}"
  end

  defp closed_failure(conn, activity, reason, action) do
    %{title: title, text: text} = AuthGate.describe(action)

    %{conn: conn, activity: activity, reason: reason, message: "#{title}. #{text}"}
    |> then(&Hook.call("AuthController.Failure.Closed", &1))
    |> then(&{:auth_closed, &1.message})
  end

  defp credentials_failure(conn, activity, reason) do
    case {activity, reason} do
      {_,
       %AshAuthentication.Errors.AuthenticationFailed{
         caused_by: %Ash.Error.Forbidden{
           errors: [%AshAuthentication.Errors.CannotConfirmUnconfirmedUser{}]
         }
       }} ->
        msg =
          gettext(
            "You have already signed in another way, but have not confirmed your account. You can confirm your account using the link we sent to you, or by resetting your password."
          )

        %{conn: conn, activity: activity, reason: reason, message: msg}
        |> then(&Hook.call("AuthController.Failure.UnconfirmedUser", &1))
        |> then(&{:unconfirmed_user, &1.message})

      _ ->
        %{
          conn: conn,
          activity: activity,
          reason: reason,
          message: gettext("Incorrect email or password")
        }
        |> then(&Hook.call("AuthController.Failure.InvalidCredentials", &1))
        |> then(&{:invalid_credentials, &1.message})
    end
  end

  def sign_out(conn, _params) do
    user_id =
      case conn.assigns[:current_user] do
        %{id: id} -> id
        _ -> "anonymous"
      end

    :telemetry.span(
      [:mishka_cms, :auth, :sign_out],
      %{user_id: user_id},
      fn ->
        conn =
          %{conn: conn, user_id: user_id}
          |> then(&Hook.call("AuthController.SignOut.BeforeSignOut", &1))
          |> Map.get(:conn)

        # HOME, AND ONLY HOME. Signing out is asked for from wherever you are, so there is nothing
        # to come back to that is not the front page; a `return_to` on this route is ignored rather
        # than honoured.
        return_to = path(conn, "/")

        :telemetry.execute(
          [:mishka_cms, :auth, :sign_out_event],
          %{count: 1},
          %{user_id: user_id, session_cleared: true}
        )

        result =
          %{
            conn: conn,
            user_id: user_id,
            return_to: return_to,
            message: gettext("You are now signed out")
          }
          |> then(&Hook.call("AuthController.SignOut.BeforeRedirect", &1))
          |> then(fn data ->
            data.conn
            |> clear_session(@host_app)
            |> delete_session(:live_socket_id)
            |> disconnect_live_sockets(data.user_id)
            |> put_flash(:info, data.message)
            |> redirect(to: data.return_to)
          end)

        {result, %{}}
      end
    )
  end

  # EVERY TAB, NOT THE ONE THAT ASKED. Clearing the session ends this request's authentication, and
  # the cookie is the browser's, so the other tabs lose it too — but a LiveView already connected
  # keeps running on the process it mounted, with the user it read then, until something ends it.
  # This is that something; see `MishkaCmsCore.Accounts.LiveSockets`.
  #
  # `sign_out/2` answers whoever asks for it, signed in or not, and the telemetry above says
  # "anonymous" for the second kind — nobody's sockets to cut.
  defp disconnect_live_sockets(conn, "anonymous"), do: conn

  defp disconnect_live_sockets(conn, user_id) do
    LiveSockets.disconnect(user_id)
    conn
  end
end
