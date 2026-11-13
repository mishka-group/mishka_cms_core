# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.Operation do
  @moduledoc """
  An operation a receipt can be kept for, and the `mishka_installer` plugin an extension declares
  its operations with.

  The core never names an extension's operations. An extension supervises one plugin on the
  `"agent:operations"` event that lists its own, like any other plugin:

      defmodule MyExtension.Agent.Operations do
        use MishkaCmsCore.Agent.Operation

        alias MishkaCmsCore.Agent.Operation

        @operations [
          Operation.new!(%{
            name: "my_extension:article:publish",
            resource: MyExtension.Article,
            action: :publish,
            master_action: :master_publish,
            visibility: ["admin:dashboard:my_extension:article", "admin:api:my_extension:article"],
            stages: [
              :dispatched,
              :validated,
              :action_committed,
              {:db_read_back, expect: [status: :published, published_at: :present]},
              :broadcast_published,
              :ui_observed
            ],
            required: [:action_committed, :db_read_back]
          })
        ]

        @impl MishkaCmsCore.Agent.Operation
        def operations, do: @operations
      end

  Stopping the plugin in the installer takes its operations away: a receipt asked for one of them
  is then kept as undeclared, and never verified.

  ## Fields

    * `name` — required, `"<app>:<resource>:<action>"` by convention, the stem of the
      `MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook` event of the same action.
    * `resource`, `action`, `master_action` — the Ash resource and the action (and its master twin)
      the operation runs; `nil` for an operation that is not an Ash action (an installer step).
    * `visibility` — the permission names whose holders may read its receipts, the area the
      operation belongs to on each surface. Empty, only a full admin of the surface may.
    * `stages` — required: the stages checked, in order (`MishkaCmsCore.Agent.Stages`).
    * `required` — required and not empty: the names of the stages that must be verified for the
      receipt to be `:verified`. This is the operation's own definition of "it worked"; a stage left
      out of it enriches the receipt and never decides it.
    * `description` — what the operation does, for whoever reads a receipt.
  """
  use GuardedStruct

  alias MishkaCmsCore.Agent.Stages
  alias MishkaInstaller.Event.Hook

  require Logger

  @event "agent:operations"

  guardedstruct do
    field(:name, String.t(), enforce: true, derives: "sanitize(trim) validate(string, not_empty)")
    field(:resource, atom())
    field(:action, atom())
    field(:master_action, atom())
    field(:visibility, list(), default: [], derives: "validate(list)")
    field(:stages, list(), enforce: true, derives: "validate(list)")
    field(:required, list(), enforce: true, derives: "validate(list)")
    field(:description, String.t())
  end

  @doc "The operations the plugin declares, each built with `new!/1`."
  @callback operations() :: [t()]

  @doc false
  defmacro __using__(opts) do
    priority = Keyword.get(opts, :priority, 50)

    quote do
      use MishkaInstaller.Event.Hook,
        event: unquote(@event),
        initial: %{priority: unquote(priority)}

      @behaviour MishkaCmsCore.Agent.Operation

      @impl true
      def call(%{operations: operations} = state) when is_list(operations),
        do: {:reply, %{state | operations: operations ++ operations()}}

      def call(state), do: {:reply, state}
    end
  end

  @doc "The event an operations plugin listens on."
  @spec event() :: String.t()
  def event, do: @event

  @doc """
  Builds an operation, raising on an invalid declaration: a missing field, a stage that names no
  kind, an empty `required`, or a required name no stage has.

  Declarations are built in module attributes, so a malformed one fails the extension's build
  rather than a receipt.
  """
  @spec new!(map()) :: t()
  def new!(attrs) do
    case build(attrs) do
      {:ok, operation} ->
        operation

      {:error, reason} ->
        raise ArgumentError, "invalid agent operation #{inspect(attrs[:name])}: #{reason}"
    end
  end

  @doc "Builds an operation, see `new!/1`."
  @spec build(map()) :: {:ok, t()} | {:error, String.t()}
  def build(attrs) do
    with {:ok, operation} <- built(builder(attrs)),
         {:ok, specs} <- specs(operation.stages),
         :ok <- required(operation.required, specs) do
      {:ok, operation}
    end
  end

  defp built({:ok, operation}), do: {:ok, operation}
  defp built({:error, errors}), do: {:error, "the fields are not valid: #{inspect(errors)}"}

  defp required([], _specs), do: {:error, "`required` is empty"}

  defp required(required, specs) do
    names = Enum.map(specs, & &1.name)

    case Enum.reject(required, &(&1 in names)) do
      [] -> :ok
      missing -> {:error, "no stage is named #{inspect(missing)}"}
    end
  end

  @doc """
  The stage specs of `operation`, or of a list of declared stages (`MishkaCmsCore.Agent.Stages`).
  """
  @spec specs(t() | list()) :: {:ok, [Stages.spec()]} | {:error, String.t()}
  def specs(%__MODULE__{stages: stages}), do: specs(stages)

  def specs(stages) when is_list(stages) do
    stages
    |> List.flatten()
    |> Enum.reduce_while({:ok, []}, fn stage, {:ok, acc} ->
      case Stages.normalize(stage) do
        {:ok, spec} -> {:cont, {:ok, [spec | acc]}}
        :error -> {:halt, {:error, "#{inspect(stage)} is not a stage"}}
      end
    end)
    |> case do
      {:ok, specs} -> unique(Enum.reverse(specs))
      error -> error
    end
  end

  defp unique(specs) do
    case specs -- Enum.uniq_by(specs, & &1.name) do
      [] -> {:ok, specs}
      twice -> {:error, "stage names #{inspect(Enum.map(twice, & &1.name))} are used twice"}
    end
  end

  @doc """
  Every operation the installed plugins declare, the first of each name. None when the event's
  plugins cannot run, or none is installed. The event is asked each time, so a plugin stopped or
  started is seen at once.
  """
  @spec all() :: [t()]
  def all do
    case Hook.call(@event, %{operations: []}, cannot_run: :cannot_run) do
      %{operations: operations} when is_list(operations) ->
        operations |> Enum.filter(&declared?/1) |> Enum.uniq_by(& &1.name)

      _none ->
        []
    end
  end

  @doc "The installed operation named `name`, or `nil`."
  @spec lookup(String.t()) :: t() | nil
  def lookup(name) when is_binary(name), do: Enum.find(all(), &(&1.name == name))

  defp declared?(%__MODULE__{}), do: true

  defp declared?(other) do
    Logger.warning(
      "[Agent] an agent:operations plugin declared #{inspect(other, limit: 3)}, which is not an Operation"
    )

    false
  end
end
