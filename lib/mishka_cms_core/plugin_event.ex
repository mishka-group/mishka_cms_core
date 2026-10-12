defmodule MishkaCmsCore.PluginEvent do
  @moduledoc """
  Fires a mishka_installer event for a caller that needs its answer, and says what that caller does
  when the event cannot run.

  An event one of whose registered plugins is not loaded — its extension failed to load, or is not
  in yet — cannot run any of them: `MishkaInstaller.Event.Hook.call/3` answers it with
  `{:error, [%{action: :call, field: :event, plugins: [...]}]}` instead of the state, and
  mishka_installer logs the plugins it waits for each time it compiles the event.

    * `call/3` — the plugins' answer, or the state it was handed when the event cannot run, so the
      request goes on with core's own answer, without the plugins. For every event whose plugins
      add to what core does, or are told about it.
    * `cannot_run?/1` — whether an answer is that one, for a security decision a plugin takes part
      in (a captcha, a record's lock, the auth gate, a builder veto), which refuses instead.

  An event fired for its side effects alone (`return: false`) needs neither: its answer is not read.

  ## Example

      conn = PluginEvent.call("web:request:after_site_resolve", conn, meta: %{host: host})
  """

  alias MishkaInstaller.Event.Hook

  @doc """
  The answer of the plugins on `event` to `state` — `MishkaInstaller.Event.Hook.call/3` with `args`
  — or `state` itself when the event cannot run (`cannot_run?/1`).
  """
  @spec call(String.t(), state, keyword()) :: state | term() when state: term()
  def call(event, state, args \\ []) do
    answer = Hook.call(event, state, args)
    if cannot_run?(answer), do: state, else: answer
  end

  @doc """
  Whether `answer` is what `MishkaInstaller.Event.Hook.call/3` answers for an event that cannot
  run, as opposed to the state its plugins returned.

      cannot_run?({:error, [%{action: :call, field: :event, plugins: [MyPlugin]}]}) #=> true
      cannot_run?(%{providers: []})                                                #=> false
  """
  @spec cannot_run?(term()) :: boolean()
  def cannot_run?({:error, [%{action: :call, field: :event} | _]}), do: true
  def cannot_run?(_answer), do: false
end
