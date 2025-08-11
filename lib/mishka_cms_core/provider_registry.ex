defmodule MishkaCmsCore.ProviderRegistry do
  @moduledoc """
  Providers as `mishka_installer` plugins — the half `MishkaCmsCore.Mail.Provider` and
  `MishkaCmsCore.Captcha.Provider` share.

  A provider is a module that listens on its kind's event and adds itself to the `providers` list
  the event carries. `use` makes a module that plugin:

      use MishkaCmsCore.ProviderRegistry, event: "mail:providers", priority: 10

  `all/2`, `offered/2` and `fetch/3` ask the event which providers are installed: every registered
  module that implements the kind's behaviour, the first of each id. Stopping a provider's plugin in
  the installer takes it out of the list. Nothing is cached: the event is asked each time.
  """

  alias MishkaInstaller.Event.Hook

  @doc false
  defmacro __using__(opts) do
    event = Keyword.fetch!(opts, :event)
    priority = Keyword.get(opts, :priority, 50)

    quote do
      use MishkaInstaller.Event.Hook,
        event: unquote(event),
        initial: %{priority: unquote(priority)}

      @impl true
      def call(%{providers: providers} = state) when is_list(providers),
        do: {:reply, %{state | providers: providers ++ [__MODULE__]}}

      def call(state), do: {:reply, state}
    end
  end

  @doc "Every provider registered on `event` that implements `behaviour`, the first of each id."
  @spec all(String.t(), module()) :: [module()]
  def all(event, behaviour) do
    case Hook.call(event, %{providers: []}) do
      %{providers: providers} when is_list(providers) ->
        providers |> Enum.filter(&provider?(&1, behaviour)) |> Enum.uniq_by(& &1.id())

      _unanswered ->
        []
    end
  end

  @doc "The providers of `all/2` this installation offers: every one, unless its `offered?/0` says not."
  @spec offered(String.t(), module()) :: [module()]
  def offered(event, behaviour),
    do:
      Enum.filter(
        all(event, behaviour),
        &(not function_exported?(&1, :offered?, 0) or &1.offered?())
      )

  @doc "The offered provider registered on `event` under `id`."
  @spec fetch(String.t(), module(), String.t() | nil) ::
          {:ok, module()} | {:error, :unknown_provider}
  def fetch(event, behaviour, id) when is_binary(id) do
    case Enum.find(offered(event, behaviour), &(&1.id() == id)) do
      nil -> {:error, :unknown_provider}
      provider -> {:ok, provider}
    end
  end

  def fetch(_event, _behaviour, _none), do: {:error, :unknown_provider}

  # EVERY CALLBACK THE BEHAVIOUR REQUIRES, not one picked as a sample: a module declaring the
  # behaviour without one of them would be offered and then fail when that one is called.
  defp provider?(module, behaviour) when is_atom(module) do
    Code.ensure_loaded?(module) and behaviour in behaviours(module) and
      Enum.all?(
        behaviour.behaviour_info(:callbacks) -- behaviour.behaviour_info(:optional_callbacks),
        fn {name, arity} -> function_exported?(module, name, arity) end
      )
  end

  defp provider?(_other, _behaviour), do: false

  defp behaviours(module),
    do: module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
end
