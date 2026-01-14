defmodule MishkaCmsCore.Runtime.PageBuilder.Interactions do
  @moduledoc """
  What an element does when it is clicked — the registry the panel reads and a package appends to.

  ## Why not a script

  Under LiveView the server owns the DOM: it sends a diff, and the client patches to match. A script
  that reaches in and changes a class is undone by the next patch that touches that element, which
  makes "add some JS to this button" the wrong shape of answer here even though it is the answer
  every WordPress builder gives.

  `Phoenix.LiveView.JS` is the shape that fits. A command is *declared in the markup*, runs on the
  client with no round trip, and survives patches because it is part of what the server rendered.
  What the browser cannot do alone — a flash, which lives on the socket — takes the ordinary
  `JS.push/2` route instead, and says which it is: see `MishkaCmsCore.Builder.Action`.

  ## What is here, and what is not

  This module owns the *list* and the *rules everything on it must follow*. It owns no verb. Each
  action is a module implementing `MishkaCmsCore.Builder.Action`, and core's seven arrive as the seed
  of the `builder:interactions` registry — the same ADR-14 event a plugin appends to, so a package's
  action reaches the panel through the door core already uses for its own.

  That door was open for the list and shut for everything else: `source/3` answered `nil` for any
  action outside a private table, so a package's entry appeared in the dropdown and then did nothing.

  ## What it compiles to

  Nothing invented — plain HEEx a developer could have written:

      <button class="pb-7f3a91b2" phx-click={JS.toggle_class("is-open", to: ".pb-7f3a91b2")}>

  ## What is checked

  An action hands over terms rather than source — `MishkaCmsCore.Builder.Command` prints them — so
  what reaches a document is a `JS` call carrying data by construction, and there is no text of a
  package's to take on trust. What is still checked is that the command exists and that
  `Phoenix.LiveView.JS` accepts the options it was given; a contribution that fails either writes
  nothing and says why in the log.

  ## Reading it back

  By parsing the expression and asking each action whether it wrote it, never by matching text. An
  expression nothing claims — anything hand-written, anything piped into something else — is reported
  as `:custom` and left exactly as it is. The panel then shows it read-only rather than offering to
  rewrite something it does not understand, which is the contract `Tree.Styles` already keeps for a
  class attribute it cannot read.
  """

  require Logger

  alias MishkaCmsCore.Builder.Action
  alias MishkaCmsCore.Builder.Actions
  alias MishkaCmsCore.Builder.Command
  alias MishkaCmsCore.Builder.Events

  @doc """
  Every action the editor offers, core's first and a plugin's after them.

  Collected through `builder:interactions`, which de-duplicates by key so a plugin can add but never
  silently redefine a core verb. The call is a read of compiled plugin state, which is what the
  Inspector has always paid for this list.
  """
  @spec registry() :: [map()]
  def registry, do: Events.collect_appended(:interactions, seed())

  @doc "Core's own actions, in panel order — the seed every plugin appends to."
  @spec seed() :: [map()]
  def seed do
    [Actions.Say.descriptor()]
    |> Enum.concat(Actions.ClassVerb.descriptors())
    |> Enum.concat(Actions.OpenVerb.descriptors())
    |> Enum.sort_by(&Map.get(&1, :priority, 50))
  end

  @doc "The attribute each open verb looks for on a component that declares its own open command."
  @spec openers() :: %{String.t() => String.t()}
  defdelegate openers(), to: Actions.OpenVerb

  @doc """
  The actions offered for a target, as `{key, label}` in panel order.

  ## Why the list depends on what is being aimed at

  A verb the target cannot honour is worse than a missing verb: it writes a command that runs, does
  something visible, and is not what the author asked for. Each action answers for itself through
  `offer?/2` — a modal declaring open and close is offered Show and Hide, a navbar declaring only a
  toggle is offered only "Show or hide", and a component that declares nothing is offered everything,
  because there is no better guess to make.
  """
  @spec actions(map()) :: [{String.t(), String.t()}]
  def actions(opener \\ %{}) do
    context = %{scope: nil, target: nil, opener: opener || %{}}

    for action <- registry(),
        module = Action.module(action),
        offered?(module, action, context),
        do: {Action.key(action), label_of(action)}
  end

  defp label_of(action) do
    case Map.get(action, :label) do
      "" -> ""
      label when is_binary(label) -> Gettext.gettext(MishkaCmsCore.Gettext, label)
      other -> other || Action.key(action)
    end
  end

  @doc """
  The boxes the panel draws for one action, in order — see `MishkaCmsCore.Builder.Action`.

  This is what keeps a package out of panel code: it says it wants a line of text called `message`,
  and the Inspector renders a labelled input, remembers it and reads it back.
  """
  @spec needs(String.t()) :: [map()]
  def needs(key) do
    case found(key) do
      {module, action} -> safely(module, :needs, [action], [])
      nil -> []
    end
  end

  @doc "Whether this action takes a class name — the one field the audit and the tests still name."
  @spec class?(String.t()) :: boolean()
  def class?(key), do: Enum.any?(needs(key), &(&1.name == "class"))

  @doc """
  Whether this action reaches the server.

  `false` is a `Phoenix.LiveView.JS` command and no round trip, which is six of core's seven. `true`
  is a push and a handler, and a page carrying one gets a `handle_event/3` compiled into it.
  """
  @spec server?(String.t()) :: boolean()
  def server?(key) do
    case found(key) do
      {module, action} -> safely(module, :where, [action], :client) == :server
      nil -> false
    end
  end

  @doc """
  Every server action, as `%{key:, event:, handler:}` — what the page compiler needs and nothing else.

  An action missing either half is left out rather than half-compiled into somebody's page, and the
  handler is checked to be a function that exists: its module name is written into every published
  page using the action, so a typo would otherwise be a page that crashes on a click.

  ONE ACTION PER EVENT. The compiler writes one `handle_event/3` clause per event and a second for a
  name the first already matches is unreachable code in a published page, so the first wins — which,
  because `MishkaCmsCore.Builder.Events` keeps the core seed ahead of every contribution, means
  core's. A plugin answering to `pb:say` would be a plugin reading the messages every page on the
  site sends.
  """
  @spec server_actions() :: [%{key: String.t(), event: String.t(), handler: {module(), atom()}}]
  def server_actions do
    answering =
      for action <- registry(),
          module = Action.module(action),
          safely(module, :where, [action], :client) == :server,
          event = safely(module, :event, [action], nil),
          named?(event),
          handler = safely(module, :handler, [action], nil),
          callable?(handler),
          do: %{key: Action.key(action), event: event, handler: handler}

    Enum.uniq_by(answering, & &1.event)
  end

  @doc """
  The expression source for one interaction, or `nil` when there is nothing to write.

  `opts` carries what the click already knows and what the author typed: `:target` is another
  element's scope class (`nil` aims at the clicked element itself), `:opener` is what that target
  says about being opened, and every other key is a value from one of the action's own boxes.

  ## Why a target at all

  Because the commonest thing anyone wants from a button is to open something ELSE. A modal, a drawer
  and twelve more render their own content closed, and with `to:` pinned to the element being
  clicked, "open that dialog" was not a thing an author could ask for. `target` is another element's
  scope class and it is still a scope: the panel offers the nodes it knows about rather than a
  free-text selector, so an interaction can no more reach outside the document than it could before.
  """
  @spec source(String.t(), String.t(), map()) :: String.t() | nil
  def source(key, scope, opts \\ %{})

  # A SCOPE IS WHAT THE COMMAND POINTS AT, so an empty one is nothing to point at — `to: "."` is a
  # selector that matches nothing and would be written into somebody's document all the same.
  def source(key, scope, opts) when is_binary(scope) and scope != "" and is_map(opts) do
    case found(key) do
      {module, action} -> written(module, action, context(scope, opts), values(opts))
      nil -> nil
    end
  end

  def source(_key, _scope, _opts), do: nil

  # AN ACTION IS ASKED FOR TERMS AND THE SOURCE IS BUILT HERE, so the failure this guards against is
  # no longer a package putting `File.rm_rf!/1` into a document — that has nowhere to enter. It is a
  # package naming a command that does not exist, or an option the command does not take, which
  # `MishkaCmsCore.Builder.Command` hears from `Phoenix.LiveView.JS` itself. Either way the author
  # gets nothing written rather than a page that stopped rendering.
  defp written(module, action, context, values) do
    case safely(module, :write, [action, context, values], nil) do
      nil -> nil
      command -> vetted(Command.write(command), action)
    end
  end

  defp vetted({:ok, source}, _action), do: source
  defp vetted({:error, why}, action), do: refuse(action, why)

  defp refuse(action, why) do
    Logger.warning("[Builder] the #{Action.key(action)} action #{why} — nothing was written")
    nil
  end

  @doc """
  Reads an attribute value back into `{:ok, key, values}`, `:none`, or `:custom`.

  `:custom` is the important one: nothing in the registry claims the expression, so the panel must
  show it rather than replace it.
  """
  @spec read(term()) :: {:ok, String.t(), map()} | :none | :custom
  def read(nil), do: :none
  def read({:string, _value}), do: :custom

  # A PIPE BELONGS TO WHOEVER WROTE IT. No action writes one today, and an expression made of two
  # commands is not the one thing a panel of boxes can describe — so it reads as hand-written and is
  # shown rather than replaced.
  def read({:expr, source}) do
    case Command.read(source) do
      {:ok, [command]} -> claimed(command)
      {:ok, _a_pipe} -> :custom
      :no -> :custom
    end
  end

  def read(_other), do: :custom

  defp claimed(command) do
    Enum.find_value(registry(), :custom, fn action ->
      with module when not is_nil(module) <- Action.module(action),
           {:ok, values} <- safely(module, :read, [action, command], :no) do
        {:ok, Action.key(action), values}
      else
        _not_this_one -> nil
      end
    end)
  end

  @doc """
  The scope class an interaction points AT, or `nil` when it points at nothing named that way.

  Read apart from `read/1` rather than widened into it, because `read/1`'s answer is what the panel
  and its tests are written against and the target is a different thing about the same expression.

  The dot is dropped: everything else in the editor speaks in bare scope classes —
  `Tree.ensure_scope/2` answers one, `ElementCss` keys on one — and a selector is this module's own
  spelling.
  """
  @spec target(term()) :: String.t() | nil
  # THE FIRST COMMAND IS THE ONE THE PANEL AIMED. A pipe is read rather than refused here because
  # the aim is a different question from which action wrote it: an expression the panel shows as
  # hand-written is still an expression whose target the tree needs to know about.
  def target({:expr, source}) do
    case Command.read(source) do
      {:ok, [{_name, _args, opts} | _rest]} -> opts |> Keyword.get(:to) |> scope_of()
      :no -> nil
    end
  end

  def target(_other), do: nil

  defp scope_of("." <> scope), do: scope
  defp scope_of(_other), do: nil

  # `false` IS AN ATOM. Written as `key == wanted and Action.module(action)`, a key that did not match
  # answered `false`, which passed `is_atom(module) and not is_nil(module)` and was then called —
  # `function false.write/3 is undefined`, swallowed by `safely/4`, and every action wrote nothing.
  defp found(key) when is_binary(key) do
    Enum.find_value(registry(), fn action ->
      with true <- Action.key(action) == key,
           module when is_atom(module) and not is_nil(module) <- Action.module(action) do
        {module, action}
      else
        _not_this_one -> nil
      end
    end)
  end

  defp found(_key), do: nil

  defp context(scope, opts),
    do: %{scope: scope, target: opts[:target], opener: opts[:opener] || %{}}

  # THE AUTHOR'S OWN WORDS, KEYED THE WAY THE PANEL POSTED THEM. Everything that is not part of the
  # click's context is a value from one of the action's boxes, and the form names those boxes, so the
  # two meet here without either side holding a list of the other's field names.
  # A value longer than this is not a message, a class or a URL — it is a paste accident or a mistake,
  # and it would be stored in an attribute and rendered into every copy of the page.
  @longest 1_000

  defp values(opts) do
    for {name, value} <- opts,
        name not in [:target, :opener],
        is_binary(value),
        into: %{},
        do: {to_string(name), String.slice(value, 0, @longest)}
  end

  defp offered?(nil, _action, _context), do: false
  defp offered?(module, action, context), do: safely(module, :offer?, [action, context], false)

  # A NAME A TEMPLATE CANNOT CONTAIN BY ACCIDENT. The compiler decides whether a page needs an
  # action's handler by looking for its event name in the markup, so an action calling itself `a`
  # would match nearly every page ever written and have its handler compiled into all of them. Four
  # characters and no whitespace is the whole of the rule: enough that a name has to be chosen, and
  # not so much that it dictates a spelling. Core's own is `pb:say`.
  defp named?(event) when is_binary(event),
    do: String.length(event) >= 4 and not String.contains?(event, [" ", "\t", "\n"])

  defp named?(_event), do: false

  defp callable?({module, function}) when is_atom(module) and is_atom(function),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, 2)

  defp callable?(_handler), do: false

  # A PLUGIN'S ACTION MUST NOT BE ABLE TO TAKE THE EDITOR DOWN. The same bargain every other registry
  # in `MishkaCmsCore.Builder.Events` makes: a contribution that misbehaves is inert and says so in
  # the log, and the author keeps their session.
  defp safely(module, function, args, fallback) do
    apply(module, function, args)
  rescue
    error ->
      Logger.warning(
        "[Builder] #{inspect(module)}.#{function}/#{length(args)} raised: #{Exception.message(error)}"
      )

      fallback
  catch
    :exit, reason ->
      Logger.warning(
        "[Builder] #{inspect(module)}.#{function}/#{length(args)} exited: #{inspect(reason)}"
      )

      fallback
  end
end
