# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Components.DoctorChecks do
  @moduledoc """
  The checks extensions add to their "check and repair" window (`MishkaCmsCore.Install.DoctorChecks`),
  drawn inside `MishkaCmsCoreWeb.Live.Admin.Components.ExtensionInstallerPanel.doctor_modal/1`
  under each extension's name, with the look of the kit's standings above them.

  Nothing is asked while the window is closed: opening it with
  `ExtensionInstallerPanel.show_doctor/2` (the dashboard's wrench, `doctor_button/1`) sends `"run"`
  here, and "Check again" does the same. The plugins and the checks run in the background
  (`MishkaGervaz.Messages.start_async/4`), each check within its time limit, so a slow or broken one
  reads as such on its own row and the window stays usable. A repair button runs that repair, then
  the check again, and the row shows both answers in place.

  A repair that answers `{:started, sentence}` started its work in the background: the row shows the
  sentence, keeps its buttons busy and listens on `MishkaCmsCore.Install.DoctorChecks.topic/1` of
  the site (subscribed before the repair runs, so no word of the job is missed) for the job's
  `progress/3`, which replaces the sentence, and `finished/3`, whose sentence stays when the check
  has run again. It listens from the repair's own task, for up to
  `MishkaCmsCore.Install.DoctorChecks.follow_timeout/0`, so the page needs no `handle_info`.

  Assigns:

    * `:id` — the DOM id `show_doctor/2` sends `"run"` to;
    * `:app` — the extension whose window this is, the `app` its plugins are asked with;
    * `:site_id` — the site the window is about, or `nil` while none is chosen;
    * `:actor` — the admin, with `:permissions` loaded; without one nothing is asked or drawn;
    * `:timeout` — the limit of each step, `MishkaCmsCore.Install.DoctorChecks.timeout/0` by default.
  """
  use Phoenix.LiveComponent
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  alias MishkaCmsCore.Install.DoctorChecks
  alias MishkaGervaz.Messages

  @impl true
  def mount(socket) do
    new_socket =
      assign(socket,
        state: :idle,
        results: [],
        notes: %{},
        busy: MapSet.new(),
        app: nil,
        site_id: nil,
        actor: nil,
        timeout: nil
      )

    {:ok, new_socket}
  end

  @impl true
  def update(%{doctor_note: {key, note}}, socket) do
    new_socket = assign(socket, notes: Map.put(socket.assigns.notes, key, note))
    {:ok, new_socket}
  end

  def update(assigns, socket) do
    moved? = Map.get(assigns, :site_id, socket.assigns.site_id) != socket.assigns.site_id
    socket = assign(socket, assigns)

    new_socket =
      case {moved?, socket.assigns.state} do
        {true, :idle} -> socket
        {true, _ran} -> start(socket)
        {false, _state} -> socket
      end

    {:ok, new_socket}
  end

  @impl true
  def handle_event("run", _params, socket), do: {:noreply, start(socket)}

  def handle_event("repair", %{"check" => key} = params, socket) do
    with false <- MapSet.member?(socket.assigns.busy, key),
         %{check: check, outcome: outcome} <-
           Enum.find(socket.assigns.results, &(&1.check.key == key)),
         {:ok, problem} <- problem(outcome, params["problem"]) do
      %{site_id: site_id, actor: actor, id: id} = socket.assigns
      opts = opts(socket)
      view = self()

      new_socket =
        socket
        |> assign(busy: MapSet.put(socket.assigns.busy, key))
        |> Messages.start_async({:repair, key}, fn ->
          :ok = Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, DoctorChecks.topic(site_id))

          note =
            check
            |> DoctorChecks.repair(site_id, actor, problem, opts)
            |> followed({view, id, key})

          {note, DoctorChecks.run_one(check, site_id, actor, opts)}
        end)

      {:noreply, new_socket}
    else
      _not_now -> {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:run, {:ok, {:ok, results}}, socket),
    do: {:noreply, assign(socket, state: :done, results: results, notes: %{})}

  def handle_async(:run, _failed, socket),
    do: {:noreply, assign(socket, state: :unlisted, results: [], notes: %{})}

  def handle_async({:repair, key}, {:ok, {note, outcome}}, socket) do
    results =
      Enum.map(socket.assigns.results, fn
        %{check: %{key: ^key}} = result -> %{result | outcome: outcome}
        result -> result
      end)

    new_socket =
      assign(socket,
        results: results,
        notes: Map.put(socket.assigns.notes, key, note),
        busy: MapSet.delete(socket.assigns.busy, key)
      )

    {:noreply, new_socket}
  end

  def handle_async({:repair, key}, _failed, socket) do
    note = {:error, gettext("The repair stopped with an error. The server log has why.")}

    new_socket =
      assign(socket,
        notes: Map.put(socket.assigns.notes, key, note),
        busy: MapSet.delete(socket.assigns.busy, key)
      )

    {:noreply, new_socket}
  end

  # A repair that started work in the background is followed until it says it is done; any other
  # answer is the repair's note as it is.
  defp followed({:started, _sentence} = note, row) do
    tell(row, note)
    follow(row, System.monotonic_time(:millisecond) + DoctorChecks.follow_timeout())
  end

  defp followed(note, _row), do: note

  defp follow({_view, _id, key} = row, deadline) do
    receive do
      {:doctor_check, ^key, {:progress, sentence}} ->
        tell(row, {:started, sentence})
        follow(row, deadline)

      {:doctor_check, ^key, {:finished, note}} ->
        note
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        {:error, gettext("The repair is still running. Check again later to see what it found.")}
    end
  end

  defp tell({view, id, key}, note),
    do: Phoenix.LiveView.send_update(view, __MODULE__, id: id, doctor_note: {key, note})

  defp start(%{assigns: %{app: app, site_id: site_id, actor: %{} = actor}} = socket)
       when is_atom(app) and not is_nil(app) and is_binary(site_id) do
    opts = opts(socket)

    socket
    |> assign(state: :running)
    |> Messages.start_async(:run, fn ->
      with {:ok, checks} <- DoctorChecks.collect(app, site_id, actor, opts) do
        {:ok, DoctorChecks.run(checks, site_id, actor, opts)}
      end
    end)
  end

  defp start(socket), do: socket

  defp opts(%{assigns: %{timeout: timeout}}) when is_integer(timeout), do: [timeout: timeout]
  defp opts(_socket), do: []

  defp problem(_outcome, nil), do: {:ok, nil}
  defp problem(_outcome, ""), do: {:ok, nil}

  defp problem({:problems, problems}, id) do
    case Enum.find(problems, &(&1.id == id and is_binary(&1.repair))) do
      nil -> :none
      problem -> {:ok, problem}
    end
  end

  defp problem(_outcome, _id), do: :none

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :groups, DoctorChecks.groups(assigns.results))

    ~H"""
    <div id={@id} data-state={@state}>
      <div :if={@state != :idle and @actor} class="mt-[18px] border-t border-[#ecebe6] pt-[16px]">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div class="min-w-0 flex-1">
            <div class="text-[13px] font-bold text-[#17161a]">{gettext("Checks")}</div>
            <div class="mt-0.5 text-[12px] font-medium text-[#8a877f]">
              {gettext("What each part of this extension says about this site.")}
            </div>
          </div>

          <button
            id={"#{@id}-again"}
            type="button"
            phx-click="run"
            phx-target={@myself}
            disabled={@state == :running}
            class="flex h-[40px] items-center gap-[9px] rounded-xl border border-[#ecebe6] bg-white px-[15px] text-[12.5px] font-semibold text-[#3a382f] transition-colors hover:bg-[#f6f5f2] disabled:opacity-60"
          >
            <.icon name="hero-arrow-path" class="size-4 text-[#6d6a63]" />
            {if @state == :running, do: gettext("Checking…"), else: gettext("Check again")}
          </button>
        </div>

        <div
          :if={@state == :unlisted}
          id={"#{@id}-unlisted"}
          class="mt-[14px] rounded-xl border border-[#ecebe6] bg-[#f6f5f2] p-[15px] text-[12px] font-semibold text-[#c2410c]"
        >
          {gettext("The checks could not be listed in time. Try again in a moment.")}
        </div>

        <div
          :if={@state == :done and @groups == []}
          id={"#{@id}-none"}
          class="mt-[14px] text-[12px] font-medium text-[#8a877f]"
        >
          {gettext("There is no check for you to run here.")}
        </div>

        <div
          :for={group <- @groups}
          id={"#{@id}-group-#{group.id}"}
          data-group={group.id}
          class="mt-[14px] rounded-xl border border-[#ecebe6] bg-[#f6f5f2] p-[15px]"
        >
          <div class="text-[11px] font-semibold uppercase tracking-[0.06em] text-[#8a877f]">
            {group.label} · {length(group.results)}
          </div>

          <ul class="mt-[7px] flex flex-col gap-[11px]">
            <li
              :for={result <- group.results}
              data-check={result.check.key}
              data-outcome={outcome_name(result.outcome)}
              class="text-[12px] font-medium text-[#6d6a63]"
            >
              <div class="flex flex-wrap items-center justify-between gap-2">
                <span class="font-semibold text-[#3a382f]">{result.check.label}</span>
                <span
                  data-role="check-status"
                  class={["text-[11.5px] font-semibold", status_class(result.outcome)]}
                >
                  {status(result.outcome)}
                </span>
              </div>

              <ul :if={problems(result.outcome) != []} class="mt-[5px] flex flex-col gap-[5px]">
                <li
                  :for={problem <- problems(result.outcome)}
                  data-problem={problem.id}
                  class="flex flex-wrap items-center justify-between gap-2"
                >
                  <span>{problem.text}</span>
                  <button
                    :if={problem.repair && result.check.repair}
                    type="button"
                    data-role="problem-repair"
                    phx-click="repair"
                    phx-value-check={result.check.key}
                    phx-value-problem={problem.id}
                    phx-target={@myself}
                    disabled={MapSet.member?(@busy, result.check.key)}
                    class="flex h-[32px] items-center gap-[7px] rounded-lg border border-[#dcdbf5] bg-[#f2f1fc] px-[11px] text-[12px] font-semibold text-[#4f4bcc] transition-colors hover:bg-[#e9e7fb] disabled:opacity-60"
                  >
                    {problem.repair}
                  </button>
                </li>
              </ul>

              <button
                :if={result.check.repair}
                type="button"
                data-role="check-repair"
                phx-click="repair"
                phx-value-check={result.check.key}
                phx-target={@myself}
                disabled={MapSet.member?(@busy, result.check.key)}
                class="mt-[9px] flex h-[40px] items-center gap-[9px] rounded-xl border border-[#dcdbf5] bg-[#f2f1fc] px-[15px] text-[12.5px] font-semibold text-[#4f4bcc] transition-colors hover:bg-[#e9e7fb] disabled:opacity-60"
              >
                <.icon name="hero-wrench-screwdriver" class="size-4" />
                {if MapSet.member?(@busy, result.check.key),
                  do: gettext("Repairing…"),
                  else: result.check.repair.label}
              </button>

              <div
                :if={note_text(@notes[result.check.key])}
                data-role="repair-note"
                class={[
                  "mt-1.5 text-[12px] font-semibold",
                  note_class(@notes[result.check.key])
                ]}
              >
                {note_text(@notes[result.check.key])}
              </div>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  defp problems({:problems, problems}), do: problems
  defp problems(_outcome), do: []

  defp outcome_name(:ok), do: "ok"
  defp outcome_name({:problems, _problems}), do: "problems"
  defp outcome_name({:error, reason}), do: Atom.to_string(reason)

  defp status(:ok), do: gettext("Nothing to fix")

  defp status({:problems, problems}),
    do: ngettext("%{count} problem", "%{count} problems", length(problems))

  defp status({:error, :timeout}), do: gettext("Did not answer in time")
  defp status({:error, _crashed}), do: gettext("Stopped with an error")

  defp status_class(:ok), do: "text-[#177a53]"
  defp status_class({:problems, _problems}), do: "text-[#a5691a]"
  defp status_class({:error, _reason}), do: "text-[#c2410c]"

  defp note_text({_kind, sentence}) when is_binary(sentence), do: sentence
  defp note_text({:ok, nil}), do: gettext("Done.")
  defp note_text(_none), do: nil

  defp note_class({:ok, _sentence}), do: "text-[#177a53]"
  defp note_class({:started, _sentence}), do: "text-[#6d6a63]"
  defp note_class(_error), do: "text-[#c2410c]"
end
