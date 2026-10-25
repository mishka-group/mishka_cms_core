# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Builder.Action do
  @moduledoc """
  What an element can be made to do when it is clicked — one declared thing, so a package can add one.

  ## The contract

  An action is a descriptor in the `builder:interactions` registry (ADR-14, see
  `MishkaCmsCore.Builder.Events`) whose `run` names a module implementing this behaviour. Core seeds
  seven; a plugin appends its own the way it appends an audit check:

      use MishkaInstaller.Event.Hook, event: "builder:interactions", initial: %{priority: 50}

      def call(%{actions: actions} = payload) do
        {:reply, %{payload | actions: actions ++ [MyPkg.Actions.Toast.descriptor()]}}
      end

  The descriptor is a plain map because it travels through a hook payload, and `run` is a module
  rather than a closure for the same reason — the rule `MishkaCmsCore.Builder.Descriptor` already
  keeps for every other registry.

  ## Client or server, and nothing in between

  An action says where it runs, and the two are not alike:

    * `:client` writes a `Phoenix.LiveView.JS` command. It runs in the browser with no round trip and
      survives patches because it is part of what the server rendered. Six of core's seven are this,
      and anything that only moves classes or visibility around belongs here.
    * `:server` writes `JS.push/2` and names a handler. Use it only when something the server owns
      has to change — a flash lives on the socket, so "Show a message" has no client-side answer.

  A server action also names the module the compiled page calls, as `{module, function}`. That module
  must be runtime code: it is named inside every published page that uses the action, and a visitor's
  page has no business naming anything under `MishkaCmsCore.Builder.*` or
  `MishkaCmsCore.Runtime.PageBuilder.*`. Core's own points at
  `MishkaCmsCore.Runtime.PageMessage`.

  ## What the panel draws

  `needs/1` returns the boxes this action wants, and the Inspector renders them. A package never
  touches panel code and never ships markup for a form: it says it wants a line of text called
  `message` and gets a labelled input, remembered and read back.

  ## Both directions are terms

  `write/3` answers a `t:MishkaCmsCore.Builder.Command.t/0` — the command's name, its arguments and its
  options — and `read/2` is handed one back. Neither side spells Elixir. What is written is escaped
  and printed by the code formatter, and what is read was parsed and unwrapped, so a class name
  containing a double quote is a class name containing a double quote in both directions and there is
  no place for a quoting mistake to live.

  It is also what makes an option free: `Phoenix.LiveView.JS` validates the keys of whatever it is
  given, so `transition:`, `time:`, `display:` and `blocking:` work on the commands that take them
  without core holding a list of which those are.

  ## Reading it back

  `read/2` is what lets the panel re-open an action the author already saved, with its boxes filled.
  The default answers `:no`, which is honest rather than clever: the panel then shows the expression
  as hand-written and refuses to rewrite something it does not understand. Implement it — a function
  head is usually enough — if you want yours to round-trip.

  ## A whole action

      defmodule MyPkg.Actions.Scroll do
        use MishkaCmsCore.Builder.Action

        alias MishkaCmsCore.Builder.Action

        def descriptor,
          do: action(key: "scroll", label: "Scroll to it", priority: 60)

        @impl true
        def needs(_action), do: [text("offset", "Offset", placeholder: "80")]

        @impl true
        def write(_action, context, values),
          do: {:dispatch, ["scroll-to"], [to: Action.aim(context), detail: values]}

        @impl true
        def read(_action, {:dispatch, ["scroll-to"], opts}), do: {:ok, opts[:detail]}
        def read(_action, _other), do: :no
      end
  """

  alias MishkaCmsCore.Builder.Command
  alias MishkaCmsCore.Builder.Descriptor

  @typedoc "What the author typed, keyed by field name."
  @type values :: %{optional(String.t()) => String.t()}

  @typedoc """
  What the click already knows: the clicked element's own scope class, the scope it is aimed at (or
  `nil` for itself), and what the target says about being opened — see
  `MishkaCmsCore.Builder.PaletteEntry.opens/1`.
  """
  @type context :: %{scope: String.t(), target: String.t() | nil, opener: map()}

  @typedoc "One box in the panel. `:text` is a line of text, `:select` a list of `{value, label}`."
  @type field :: %{
          name: String.t(),
          label: String.t(),
          type: :text | :select,
          placeholder: String.t(),
          options: [{String.t(), String.t()}]
        }

  @doc "Where this action runs. `:client` is a `JS` command; `:server` is a push and a handler."
  @callback where(action :: map()) :: :client | :server

  @doc """
  The boxes the panel draws for this action, in order.

  A field's `name` is how its value reaches `write/3` and how `read/2`'s answer is matched back to
  the box, so `target`, `action` and `node_id` are reserved — the panel's form already posts those
  three as the click's own context and one of your own by those names would be dropped.
  """
  @callback needs(action :: map()) :: [field()]

  @doc "Whether to offer this action at all, given what the click is aimed at."
  @callback offer?(action :: map(), context()) :: boolean()

  @doc """
  The command to write, a list of them to pipe, or `nil` when there is nothing to write yet.

  Terms, never source. Whatever is in the arguments and the options is escaped and printed for you,
  and `Phoenix.LiveView.JS` is asked whether the options are ones it takes before anything is stored.
  """
  @callback write(action :: map(), context(), values()) :: Command.t() | [Command.t()] | nil

  @doc "Reads a command back into the values that wrote it, or `:no` if it is not this one's."
  @callback read(action :: map(), Command.t()) :: {:ok, values()} | :no

  @doc "A server action's event name — what `JS.push/2` sends and the compiled page answers."
  @callback event(action :: map()) :: String.t() | nil

  @doc """
  A server action's handler as `{module, function}`, called with `(socket, params)` and returning a
  socket. Runtime code only: it is named inside every published page using the action.
  """
  @callback handler(action :: map()) :: {module(), atom()} | nil

  defmacro __using__(_opts) do
    quote do
      @behaviour MishkaCmsCore.Builder.Action

      import MishkaCmsCore.Builder.Action, only: [action: 1, text: 2, text: 3, select: 3]

      @impl true
      def where(_action), do: :client

      @impl true
      def needs(_action), do: []

      @impl true
      def offer?(_action, _context), do: true

      @impl true
      def read(_action, _command), do: :no

      @impl true
      def event(_action), do: nil

      @impl true
      def handler(_action), do: nil

      defoverridable where: 1, needs: 1, offer?: 2, read: 2, event: 1, handler: 1
    end
  end

  @doc """
  A descriptor for this module's action. `key` is what the document stores and the select posts;
  `label` is what a reader sees; `priority` decides where it sits in the list.
  """
  defmacro action(opts) do
    quote do
      %{
        key: Keyword.fetch!(unquote(opts), :key),
        kind: :interaction,
        label: Keyword.fetch!(unquote(opts), :label),
        description: Keyword.get(unquote(opts), :description),
        priority: Keyword.get(unquote(opts), :priority, 50),
        run: __MODULE__,
        config: Keyword.get(unquote(opts), :config, %{})
      }
    end
  end

  @doc "A line of text. `placeholder` is the example a non-technical author reads instead of a spec."
  @spec text(String.t(), String.t(), keyword()) :: field()
  def text(name, label, opts \\ []) do
    %{
      name: name,
      label: label,
      type: :text,
      placeholder: Keyword.get(opts, :placeholder, ""),
      options: []
    }
  end

  @doc "A list to pick from, as `{value, label}`. The first is what a fresh action starts on."
  @spec select(String.t(), String.t(), [{String.t(), String.t()}]) :: field()
  def select(name, label, options),
    do: %{name: name, label: label, type: :select, placeholder: "", options: options}

  @doc """
  The selector an action lands on: the target's scope when the click is aimed at one, and the
  clicked element's own otherwise.

  Sanitised down to what a class name can hold. Both scopes are minted by `Tree.ensure_scope/2` and
  neither is an author's own word, so this changes nothing today — it is here so that a package
  reaching for the selector cannot be the first place a stray character lands in a generated
  selector.
  """
  @spec aim(context()) :: String.t()
  def aim(context) when is_map(context) do
    "." <> (identifier(context[:target]) || identifier(context[:scope]) || "")
  end

  defp identifier(value) when is_binary(value) do
    case String.replace(value, ~r/[^A-Za-z0-9_-]/, "") do
      "" -> nil
      name -> name
    end
  end

  defp identifier(_value), do: nil

  @doc "This action's key, the string the document stores."
  @spec key(map()) :: String.t()
  def key(action), do: Descriptor.key(action)

  @doc "The module implementing this action, or `nil` for a descriptor that names none."
  @spec module(map()) :: module() | nil
  def module(%{run: run}) when is_atom(run) and not is_nil(run), do: run
  def module(_action), do: nil
end
