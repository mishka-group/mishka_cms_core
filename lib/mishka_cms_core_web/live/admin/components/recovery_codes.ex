# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Components.RecoveryCodes do
  @moduledoc """
  The signed-in account's recovery codes, a security card on the settings page's Preferences tab
  (`SecurityCards`): one-time codes for signing in when its authenticator app is lost. Made with a
  current code from the app (`generate_recovery_codes`), shown once and replaced by the next ones;
  otherwise the card says how many are left. An account without an authenticator is told to set one
  up first. See `MishkaCmsCore.Accounts.SecondFactor`.

      <.live_component module={RecoveryCodes} id="recovery-codes" current_user={@current_user} />
  """
  use Phoenix.LiveComponent
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  alias MishkaCmsCore.Accounts.{SecondFactor, User}
  alias MishkaCmsCoreWeb.Live.Admin.Components.SecurityCards
  alias Phoenix.LiveView.AsyncResult

  @impl true
  def update(%{refresh: true}, socket),
    do: {:ok, socket |> assign(codes: nil, message: nil) |> load_status()}

  def update(assigns, socket) do
    socket = assign(socket, id: assigns.id, current_user: assigns.current_user)

    {:ok,
     if socket.assigns[:status] do
       socket
     else
       socket
       |> assign(codes: nil, message: nil)
       |> load_status()
     end}
  end

  defp load_status(socket) do
    user = socket.assigns.current_user

    MishkaGervaz.Messages.assign_async(socket, :status, fn ->
      case Ash.get(User, user.id, tenant: user.site_id, authorize?: false) do
        {:ok, stored} ->
          {:ok,
           %{
             status: %{
               enabled: SecondFactor.enabled?(stored),
               left: SecondFactor.recovery_codes_left(stored),
               policy: SecondFactor.policy(stored.site_id)
             }
           }}

        {:error, error} ->
          {:error, error}
      end
    end)
  end

  @impl true
  def handle_event("generate", %{"code" => code}, socket) do
    with {:ok, code} <- SecurityCards.six_digits(code),
         {:ok, user} <- generate(socket, code) do
      codes = user.__metadata__.recovery_codes

      {:noreply,
       assign(socket,
         codes: codes,
         message: nil,
         status:
           AsyncResult.ok(%{
             enabled: true,
             left: length(codes),
             policy: SecondFactor.policy(user.site_id)
           })
       )}
    else
      :error ->
        {:noreply,
         assign(
           socket,
           :message,
           {:error, gettext("Enter the 6-digit code your authenticator app shows.")}
         )}

      {:error, error} ->
        {:noreply, assign(socket, :message, {:error, SecondFactor.explain(error)})}
    end
  end

  def handle_event("hide", _params, socket), do: {:noreply, assign(socket, codes: nil)}

  # ON THE ACCOUNT AS STORED, as the signed-in account itself — the policies let no one else.
  defp generate(socket, code) do
    user = socket.assigns.current_user

    with {:ok, stored} <- Ash.get(User, user.id, tenant: user.site_id, authorize?: false) do
      stored
      |> Ash.Changeset.for_update(:generate_recovery_codes, %{code: code},
        actor: user,
        tenant: user.site_id
      )
      |> Ash.update()
    end
  end

  # As the codes are read out: twelve characters in three groups. Typed back, case, spaces and
  # dashes do not matter.
  defp grouped(code), do: code |> String.graphemes() |> Enum.chunk_every(4) |> Enum.join("-")

  defp download(codes),
    do: "data:text/plain;charset=utf-8," <> URI.encode(Enum.map_join(codes, "\n", &grouped/1))

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
        title={gettext("Recovery codes")}
        description={
          gettext(
            "One-time codes for signing in when you cannot use your authenticator app — a lost or new phone. Each works once."
          )
        }
        message={@message}
      >
        <:status>
          <.async_result :let={status} assign={@status}>
            <SecurityCards.chip
              :if={status.enabled and status.policy != :off}
              id="recovery-codes-status"
              on?={status.left > 0}
              on={ngettext("%{count} left", "%{count} left", status.left)}
              off={gettext("None")}
            />
          </.async_result>
        </:status>

        <.async_result :let={status} assign={@status}>
          <:loading>
            <div class="mt-4 h-[46px] w-[220px] animate-pulse rounded-xl bg-[#f4f3ef]"></div>
          </:loading>
          <:failed>
            <p class="mt-4 text-[12.5px] font-medium text-[#a5352c]">
              {gettext("Could not read your sign-in settings. Reload the page to try again.")}
            </p>
          </:failed>

          <p
            :if={!status.enabled or status.policy == :off}
            id="recovery-codes-off"
            class="mt-4 text-[12.5px] font-medium text-[#8a877f]"
          >
            {if status.policy == :off,
              do:
                gettext(
                  "Two-step sign-in is turned off for this site, so recovery codes are not asked for."
                ),
              else: gettext("They come with two-step sign-in: set up your authenticator first.")}
          </p>

          <div
            :if={status.enabled and status.policy != :off and @codes}
            id="recovery-codes-shown"
            class="mt-4"
          >
            <p class="m-0 rounded-xl border border-[#f1e2c4] bg-[#fdf8ee] px-[14px] py-[10px] text-[12.5px] font-semibold text-[#8a5a12]">
              {gettext(
                "Save these now: they are shown only once. Keep them somewhere safe, apart from your phone."
              )}
            </p>
            <ol
              id="recovery-codes-list"
              class="mt-4 grid grid-cols-2 gap-x-6 gap-y-2 max-[560px]:grid-cols-1"
            >
              <li
                :for={code <- @codes}
                dir="ltr"
                class="font-mono text-[14px] font-semibold tracking-[0.08em] text-[#1b1a18]"
              >
                {grouped(code)}
              </li>
            </ol>
            <div class="mt-4 flex flex-wrap items-center gap-2.5">
              <a
                id="recovery-codes-download"
                href={download(@codes)}
                download="recovery-codes.txt"
                class={@dark_button}
              >
                <.icon name="hero-arrow-down-tray" class="size-[15px]" /> {gettext("Download")}
              </a>
              <button
                type="button"
                id="recovery-codes-hide"
                phx-click="hide"
                phx-target={@myself}
                class={@light_button}
              >
                {gettext("I saved them")}
              </button>
            </div>
          </div>

          <form
            :if={status.enabled and status.policy != :off and is_nil(@codes)}
            id="recovery-codes-form"
            phx-submit="generate"
            phx-target={@myself}
            novalidate
            class="mt-4 flex flex-col gap-3"
          >
            <p class="m-0 text-[12.5px] font-medium text-[#3a382f]">
              {if status.left > 0,
                do:
                  gettext(
                    "Making new codes asks a current code from your authenticator app. The codes you have now stop working."
                  ),
                else: gettext("Making them asks a current code from your authenticator app.")}
            </p>
            <div class="flex flex-wrap items-center gap-2.5">
              <input
                type="text"
                id="recovery-codes-code"
                name="code"
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
                id="recovery-codes-generate"
                phx-disable-with={gettext("Checking…")}
                class={@dark_button}
              >
                <.icon name="hero-key" class="size-[15px]" />
                {if status.left > 0,
                  do: gettext("Make new codes"),
                  else: gettext("Make recovery codes")}
              </button>
            </div>
          </form>
        </.async_result>
      </SecurityCards.card>
    </div>
    """
  end
end
