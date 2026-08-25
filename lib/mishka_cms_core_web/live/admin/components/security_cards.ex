defmodule MishkaCmsCoreWeb.Live.Admin.Components.SecurityCards do
  @moduledoc """
  The cards of an account's own sign-in security, drawn on the settings page's Preferences tab: the
  core's — its authenticator app (`TwoFactor`) and its recovery codes (`RecoveryCodes`) — and any an
  extension adds on the `"account:security:cards"` mishka_installer event, as a widget is added on
  `"dashboard:widgets"`.

  A card is `%{id: String.t(), priority: integer(), module: module()}`: a LiveComponent drawn with
  `id` and `current_user`, low priority first. A plugin is handed `%{cards: cards}` and answers
  `{:reply, %{cards: cards}}` with its own added; a core card it drops or redefines comes back as
  the core made it. A card that changes what the others show sends `:account_security_changed` to
  its LiveView, which redraws every card with `refresh: true` (`refresh/1`).

      use MishkaInstaller.Event.Hook, event: "account:security:cards"

      def call(%{cards: cards} = data),
        do: {:reply, %{data | cards: cards ++ [%{id: "passkeys", priority: 30, module: MyApp.Passkeys}]}}

  A card draws itself in `card/1`, with `input_class/0`, `dark_button/0` and `light_button/0`, so
  every card on the tab looks alike.
  """
  use Phoenix.Component

  alias MishkaCmsCoreWeb.Live.Admin.Components.{RecoveryCodes, TwoFactor}

  @type card :: %{id: String.t(), priority: integer(), module: module()}

  @event "account:security:cards"

  @core [
    %{id: "two-factor", priority: 10, module: TwoFactor},
    %{id: "recovery-codes", priority: 20, module: RecoveryCodes}
  ]

  @doc "The cards to draw, the core's first among equals, low priority first."
  @spec collect() :: [card()]
  def collect do
    added =
      case MishkaInstaller.Event.Hook.call(@event, %{cards: @core}) do
        %{cards: cards} when is_list(cards) -> Enum.filter(cards, &card?/1)
        _nothing -> []
      end

    (@core ++ added)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&{&1.priority, &1.id})
  end

  @doc "Redraws every card in `cards` with `refresh: true`, from the LiveView that holds them."
  @spec refresh([card()]) :: :ok
  def refresh(cards),
    do: Enum.each(cards, &Phoenix.LiveView.send_update(&1.module, id: &1.id, refresh: true))

  @doc """
  A code typed into a card, as an authenticator app shows it: `{:ok, six_digits}` with spaces
  dropped, or `:error` for anything else — answered in the card, never sent, so it spends none of
  the account's tries.
  """
  @spec six_digits(String.t() | nil) :: {:ok, String.t()} | :error
  def six_digits(code) when is_binary(code) do
    code = String.replace(code, ~r/\s/u, "")
    if Regex.match?(~r/\A\d{6}\z/, code), do: {:ok, code}, else: :error
  end

  def six_digits(_code), do: :error

  @doc "The text field of a card's code form."
  @spec input_class() :: String.t()
  def input_class,
    do:
      "h-[46px] w-full max-w-[220px] rounded-xl border border-[#ecebe6] bg-[#faf9f6] px-[15px] text-[15px] font-semibold tracking-[0.3em] text-[#1b1a18] outline-none transition focus:border-[#c3c1f0] focus:bg-white focus:shadow-[0_0_0_3px_rgba(91,87,214,0.1)]"

  @doc "A card's main button."
  @spec dark_button() :: String.t()
  def dark_button,
    do:
      "flex h-[46px] items-center gap-2 rounded-xl bg-[#17161a] px-[17px] text-[12.5px] font-bold text-white hover:opacity-90"

  @doc "A card's second button."
  @spec light_button() :: String.t()
  def light_button,
    do:
      "flex h-[46px] items-center gap-2 rounded-xl border border-[#ecebe6] bg-white px-[17px] text-[12.5px] font-bold text-[#3a382f] hover:bg-[#f7f6f3]"

  @doc """
  A security card: its title and what it is for, a status chip beside them, and a message —
  `{:ok, text}` in green or `{:error, text}` in red — above what the card holds.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :message, :any, default: nil
  slot :status
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div
      id={@id}
      class="rounded-[18px] border border-[#ecebe6] bg-white px-[26px] py-[22px] shadow-[0_1px_2px_rgba(30,28,24,0.04)]"
    >
      <div class="flex flex-wrap items-start gap-3">
        <div class="min-w-0 flex-1">
          <h2 class="m-0 font-['Space_Grotesk'] text-[16px] font-bold text-[#17161a]">{@title}</h2>
          <p class="mt-1 text-[12.5px] font-medium text-[#8a877f]">{@description}</p>
        </div>
        {render_slot(@status)}
      </div>

      <div
        :if={@message}
        id={"#{@id}-message"}
        class={[
          "mt-4 rounded-xl border px-[14px] py-[10px] text-[12.5px] font-semibold",
          (match?({:ok, _}, @message) && "border-[#cfe9db] bg-[#eef8f2] text-[#177a53]") ||
            "border-[#f3d5d0] bg-[#fdf3f1] text-[#a5352c]"
        ]}
      >
        {elem(@message, 1)}
      </div>

      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "A card's status chip: green and labelled `on` when `on?`, grey and labelled `off` otherwise."
  attr :id, :string, required: true
  attr :on?, :boolean, required: true
  attr :on, :string, required: true
  attr :off, :string, required: true

  def chip(assigns) do
    ~H"""
    <span
      id={@id}
      data-enabled={to_string(@on?)}
      class={[
        "inline-flex items-center gap-1.5 rounded-full px-[10px] py-[3px] text-[11px] font-bold",
        (@on? && "bg-[#e6f6ee] text-[#177a53]") || "bg-[#f4f3ef] text-[#8a877f]"
      ]}
    >
      <span class={["size-1.5 rounded-full", (@on? && "bg-[#1f9d6b]") || "bg-[#b5b2aa]"]}></span>
      {(@on? && @on) || @off}
    </span>
    """
  end

  defp card?(%{id: id, priority: priority, module: module})
       when is_binary(id) and is_integer(priority) and is_atom(module),
       do: true

  defp card?(_other), do: false
end
