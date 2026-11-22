# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Layouts.TopbarStatus do
  @moduledoc """
  The status lines extensions tell the admin about in the top bar, on the `"topbar:status"`
  mishka_installer event: "Sandbox: nothing is charged", "Backups have not run for two days". The
  top bar draws them as one chip, its dot in the colour of the worst line's `level`, that opens a
  small panel listing every line, so a state of the site never needs a pill of its own and the bar
  still fits a phone. The core adds no line itself, and draws no chip while no plugin answers.

  A line is a map:

    * `id` — a string, unique and stable;
    * `level` — `:ok`, `:warn` or `:error`;
    * `label` — the line's few words, already translated: "Sandbox";
    * `detail` — optional, the sentence under it: "Nothing is charged. Switch to Live in Payment
      providers.";
    * `link` — optional, a path of this app the line opens
      (`MishkaCmsCore.Layouts.TopbarNeeds.local_path/1`); anything else is dropped;
    * `permission` — optional, one name or a list where holding ANY is enough
      (`MishkaCmsCore.Settings.permitted?/2`).

  A line with no `id`, no `label`, an unknown `level` or an `id` already taken is dropped.

  ## What a plugin is handed

      %{
        lines: [line],
        current_user: user,      # with :permissions loaded; a master has no site_id
        current_site: site,      # the site the request resolved to, or nil
        current_path: "/admin/dashboard/...",
        view: module()
      }

  It answers `{:reply, %{data | lines: lines ++ mine}}`, or the map as it came when it has nothing
  to say for this user, site or page.

      defmodule MyShop.TestMode do
        use MishkaInstaller.Event.Hook, event: "topbar:status"

        @impl true
        def call(%{lines: lines, current_site: %{id: site_id}} = data) do
          case MyShop.test_mode?(site_id) do
            true ->
              line = %{id: "shop-test-mode", level: :warn, label: "Test mode",
                       detail: "Nothing is charged.", link: "/admin/dashboard/shop/providers"}

              {:reply, %{data | lines: lines ++ [line]}}

            false ->
              {:reply, data}
          end
        end

        def call(data), do: {:reply, data}
      end

  ## When it is called

  `MishkaCmsCore.Layouts.Nav` asks when an admin page opens and when its path changes, never on a
  render. A plugin that raises is logged by mishka_installer and the bar is drawn with no chip. An
  extension whose state changed while a page is open (it heard the change on its own topic) asks
  again with `refresh/1` from that page's process, so the chip follows without a reload.
  """

  alias MishkaCmsCore.Layouts.TopbarNeeds
  alias MishkaCmsCore.Settings

  @event "topbar:status"
  @levels [:ok, :warn, :error]

  @type line :: %{
          required(:id) => String.t(),
          required(:level) => :ok | :warn | :error,
          required(:label) => String.t(),
          optional(:detail) => String.t() | nil,
          optional(:link) => String.t() | nil,
          optional(:permission) => String.t() | [String.t()]
        }

  @doc "The mishka_installer event extensions add their status lines on."
  @spec event() :: String.t()
  def event, do: @event

  @doc """
  The lines to show for `context`, the worst first (`:error`, then `:warn`, then `:ok`), `id`
  breaking a tie; each one the context's `current_user` may see. `[]` when no plugin answers or
  one raised.
  """
  @spec collect(map()) :: [line()]
  def collect(%{current_user: user} = context) do
    case MishkaInstaller.Event.Hook.call(@event, Map.put(context, :lines, [])) do
      %{lines: lines} when is_list(lines) ->
        lines
        |> Enum.filter(&(line?(&1) and Settings.permitted?(&1, user)))
        |> Enum.map(&clean/1)
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(&{-rank(&1.level), &1.id})

      _nothing ->
        []
    end
  end

  @doc """
  Asks the plugins again for the open page of `socket` and puts the answer where the top bar reads
  it (`@topbar_status`); a socket the admin layout did not set up is returned as it is.
  """
  @spec refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh(%{assigns: %{current_path: path} = assigns} = socket) when is_binary(path) do
    context = %{
      current_user: assigns[:current_user],
      current_site: assigns[:topbar_site],
      current_path: path,
      view: socket.view
    }

    Phoenix.Component.assign(socket, :topbar_status, collect(context))
  end

  def refresh(socket), do: socket

  @doc "The worst level of `lines`: `:error`, `:warn` or `:ok`, or `nil` for none."
  @spec level([line()]) :: :ok | :warn | :error | nil
  def level([]), do: nil
  def level(lines), do: lines |> Enum.max_by(&rank(&1.level)) |> Map.fetch!(:level)

  defp rank(:error), do: 2
  defp rank(:warn), do: 1
  defp rank(:ok), do: 0

  defp line?(%{id: id, level: level, label: label})
       when is_binary(id) and id != "" and level in @levels and is_binary(label) and label != "",
       do: true

  defp line?(_other), do: false

  defp clean(line) do
    line
    |> Map.put(:detail, text(line[:detail]))
    |> Map.put(:link, line[:link] |> TopbarNeeds.local_path())
  end

  defp text(text) when is_binary(text) and text != "", do: text
  defp text(_none), do: nil
end
