# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Components.TwoFactor do
  @moduledoc """
  The signed-in account's authenticator app, a security card on the settings page's Preferences tab
  (`SecurityCards`): set up, or turned off. See `MishkaCmsCore.Accounts.SecondFactor` for what it
  changes at sign-in. Turning it on or off tells the other cards (`:account_security_changed`), so
  the recovery codes card follows.

  Setting one up is the `totp` strategy's two steps. `setup_with_totp` stores nothing and hands
  back the `otpauth://` address and a setup token, kept in this component while the QR code and the
  secret are shown; `confirm_setup_with_totp` stores the secret once a code from the app matches.
  Turning it off asks a current code (`disable_totp`).

      <.live_component module={TwoFactor} id="two-factor" current_user={@current_user} />
  """
  use Phoenix.LiveComponent
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  alias MishkaCmsCore.Accounts.{SecondFactor, User}
  alias MishkaCmsCoreWeb.Live.Admin.Components.SecurityCards
  alias Phoenix.LiveView.AsyncResult

  @impl true
  def update(%{refresh: true}, socket), do: {:ok, socket}

  def update(assigns, socket) do
    socket =
      assign(socket,
        id: assigns.id,
        current_user: assigns.current_user,
        policy: SecondFactor.policy(assigns.current_user.site_id)
      )

    {:ok,
     if socket.assigns[:enabled] do
       socket
     else
       socket
       |> assign(setup: nil, message: nil, code: "")
       |> load_status()
     end}
  end

  defp load_status(socket) do
    user = socket.assigns.current_user

    MishkaGervaz.Messages.assign_async(socket, :enabled, fn ->
      case Ash.get(User, user.id, tenant: user.site_id, authorize?: false) do
        {:ok, stored} -> {:ok, %{enabled: SecondFactor.enabled?(stored)}}
        {:error, error} -> {:error, error}
      end
    end)
  end

  @impl true
  def handle_event("start", _params, socket) do
    case write(socket, :setup_with_totp, %{}) do
      {:ok, started} ->
        url = SecondFactor.setup_url(started.__metadata__.totp_url, socket.assigns.current_user)

        {:noreply,
         assign(socket,
           message: nil,
           setup: %{token: started.__metadata__.setup_token, qr: qr(url), secret: secret(url)}
         )}

      {:error, error} ->
        {:noreply, assign(socket, :message, refusal(error))}
    end
  end

  def handle_event("typing", %{"code" => code}, socket) when is_binary(code),
    do: {:noreply, assign(socket, :code, code)}

  def handle_event("confirm", %{"code" => code}, %{assigns: %{setup: %{token: token}}} = socket) do
    case with_code(
           code,
           &write(socket, :confirm_setup_with_totp, %{setup_token: token, code: &1})
         ) do
      {:ok, _confirmed} ->
        send(self(), :account_security_changed)

        {:noreply,
         assign(socket,
           setup: nil,
           code: "",
           enabled: AsyncResult.ok(true),
           message:
             {:ok,
              gettext(
                "Your authenticator is set up. Sign-ins now ask for its code. Make recovery codes below, in case you lose your phone."
              )}
         )}

      {:error, error} ->
        {:noreply, assign(socket, :message, refusal(error))}
    end
  end

  def handle_event("cancel", _params, socket),
    do: {:noreply, assign(socket, setup: nil, message: nil, code: "")}

  def handle_event("disable", %{"code" => code}, socket) do
    case with_code(code, &write(socket, :disable_totp, %{code: &1})) do
      {:ok, _off} ->
        send(self(), :account_security_changed)

        {:noreply,
         assign(socket,
           code: "",
           enabled: AsyncResult.ok(false),
           message:
             {:ok,
              gettext("Your authenticator is turned off. Sign-ins ask for the password alone.")}
         )}

      {:error, error} ->
        {:noreply, assign(socket, :message, refusal(error))}
    end
  end

  # ON THE ACCOUNT AS STORED, as the signed-in account itself — the policies let no one else.
  defp write(socket, action, params) do
    user = socket.assigns.current_user

    with {:ok, stored} <- Ash.get(User, user.id, tenant: user.site_id, authorize?: false) do
      stored
      |> Ash.Changeset.for_update(action, params, actor: user, tenant: user.site_id)
      |> Ash.update()
    end
  end

  # SIX DIGITS OR NOTHING IS SENT — see `SecurityCards.six_digits/1`.
  defp with_code(code, write) do
    case SecurityCards.six_digits(code) do
      {:ok, code} -> write.(code)
      :error -> {:error, :format}
    end
  end

  # A REFUSAL IS A CODE THAT IS NOT SIX DIGITS, A RATE LIMIT OR A CODE THAT DID NOT MATCH: the
  # account is the actor's own, so the policies have nothing else to refuse.
  defp refusal(:format),
    do: {:error, gettext("Enter the 6-digit code your authenticator app shows.")}

  defp refusal(error), do: {:error, SecondFactor.explain(error)}

  defp qr(url), do: url |> EQRCode.encode() |> EQRCode.svg(width: 184)

  # The secret as people type it into an app that cannot scan: Base32, in groups of four.
  defp secret(url) do
    url
    |> URI.parse()
    |> Map.get(:query, "")
    |> URI.decode_query()
    |> Map.get("secret", "")
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join(" ", &Enum.join/1)
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        input_class: SecurityCards.input_class(),
        dark_button: SecurityCards.dark_button(),
        light_button: SecurityCards.light_button()
      )

    ~H"""
    <div>
      <SecurityCards.card
        id={@id}
        title={gettext("Two-step sign-in")}
        description={
          gettext(
            "After your password, sign-in asks for a code from an authenticator app on your phone, such as Google Authenticator, 1Password or Authy."
          )
        }
        message={@message}
      >
        <:status>
          <.async_result :let={enabled} assign={@enabled}>
            <SecurityCards.chip
              id="two-factor-status"
              on?={enabled}
              on={gettext("On")}
              off={gettext("Off")}
            />
          </.async_result>
        </:status>

        <p
          :if={@policy == :off}
          id="two-factor-policy-off"
          class="mt-4 text-[12.5px] font-medium text-[#8a877f]"
        >
          {gettext(
            "Two-step sign-in is turned off for this site: signing in asks for the password alone."
          )}
        </p>

        <.async_result :let={enabled} :if={@policy != :off} assign={@enabled}>
          <:loading>
            <div class="mt-4 h-[46px] w-[220px] animate-pulse rounded-xl bg-[#f4f3ef]"></div>
          </:loading>
          <:failed>
            <p class="mt-4 text-[12.5px] font-medium text-[#a5352c]">
              {gettext("Could not read your sign-in settings. Reload the page to try again.")}
            </p>
          </:failed>

          <p
            :if={!enabled and @policy in [:required, :recommended]}
            id="two-factor-policy"
            class="mt-4 text-[12.5px] font-semibold text-[#8a5514]"
          >
            {if @policy == :required,
              do: gettext("This site requires it: set it up to use the dashboard."),
              else: gettext("This site recommends it for every admin.")}
          </p>

          <div :if={!enabled and is_nil(@setup)} class="mt-4">
            <button
              type="button"
              id="two-factor-start"
              phx-click="start"
              phx-target={@myself}
              class={@dark_button}
            >
              <.icon name="hero-device-phone-mobile" class="size-[15px]" />
              {gettext("Set up authenticator")}
            </button>
          </div>

          <div :if={!enabled and @setup} id="two-factor-setup" class="mt-5 flex flex-wrap gap-6">
            <div class="shrink-0 rounded-[14px] border border-[#ecebe6] bg-white p-2.5">
              {Phoenix.HTML.raw(@setup.qr)}
            </div>
            <form
              id="two-factor-confirm"
              phx-change="typing"
              phx-submit="confirm"
              phx-target={@myself}
              novalidate
              class="flex min-w-[240px] flex-1 flex-col gap-3"
            >
              <p class="m-0 text-[12.5px] font-medium text-[#3a382f]">
                {gettext(
                  "Scan the code with your authenticator app, then enter the 6-digit code it shows."
                )}
              </p>
              <div>
                <div class="text-[10.5px] font-bold uppercase tracking-[0.1em] text-[#a8a5a0]">
                  {gettext("Or type this key")}
                </div>
                <code
                  id="two-factor-secret"
                  dir="ltr"
                  class="mt-1 block break-all font-mono text-[12.5px] font-semibold text-[#3a382f]"
                >
                  {@setup.secret}
                </code>
              </div>
              <input
                type="text"
                id="two-factor-code"
                name="code"
                value={@code}
                dir="ltr"
                inputmode="numeric"
                autocomplete="one-time-code"
                maxlength="7"
                placeholder="123456"
                class={@input_class}
              />
              <div class="flex flex-wrap items-center gap-2.5">
                <button
                  type="submit"
                  id="two-factor-confirm-submit"
                  phx-disable-with={gettext("Checking…")}
                  class={@dark_button}
                >
                  <.icon name="hero-check" class="size-[15px]" /> {gettext("Turn on")}
                </button>
                <button
                  type="button"
                  id="two-factor-cancel"
                  phx-click="cancel"
                  phx-target={@myself}
                  class={@light_button}
                >
                  {gettext("Cancel")}
                </button>
              </div>
            </form>
          </div>

          <form
            :if={enabled}
            id="two-factor-disable"
            phx-change="typing"
            phx-submit="disable"
            phx-target={@myself}
            novalidate
            class="mt-4 flex flex-wrap items-center gap-2.5"
          >
            <input
              type="text"
              id="two-factor-disable-code"
              name="code"
              value={@code}
              dir="ltr"
              inputmode="numeric"
              autocomplete="one-time-code"
              maxlength="7"
              placeholder="123456"
              aria-label={gettext("Current code from your authenticator app")}
              class={@input_class}
            />
            <button
              type="submit"
              id="two-factor-disable-submit"
              phx-disable-with={gettext("Checking…")}
              class={@light_button}
            >
              <.icon name="hero-shield-exclamation" class="size-[15px]" /> {gettext("Turn off")}
            </button>
          </form>
        </.async_result>
      </SecurityCards.card>
    </div>
    """
  end
end
