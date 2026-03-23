defmodule MishkaCmsCore.Runtime.PageBuilder.CodeCheck do
  @moduledoc """
  Compiles a page's code without loading it, so an author is told about a mistake instead of a
  visitor being shown one.

  ## Why this has to exist

  A page's `template`, `events`, `infos` and `helpers` are all Elixir by the time
  `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler` is done with them, and nothing between the form
  and the BEAM reads them first. The failure that follows is quiet in three different ways:

    * a page whose `precompile` is false — the default — is not compiled when it is saved, so the
      save reports success and `MishkaCmsCore.Runtime.RuntimeStatus` reports `Ready`;
    * a page whose module IS loaded and then fails to recompile keeps serving the previous version,
      because the old code is only purged on the success branch;
    * the reason is recorded in `MishkaCmsCore.Runtime.States.CompileFailureState` and read by
      nothing that a human can see.

  So the author saves, is told nothing, and the page either does not change or 500s for the first
  visitor. This module is the missing answer to "did that work?".

  ## Three classes of wrong, and which of them a check can catch

  Measured against the real compiler:

      {:noreply, socket}     parses, compiles, works
      {:noreply, socket      raises TokenMissingError — caught here, with a line
      def def def            parses fine, fails when the module is compiled — caught here
      ""                     parses to nothing, compiles to nil, crashes on the first click —
                             caught here by name, because the message a reader needs is not the
                             one the runtime would eventually give them

  ## The budget

  Compiling a page means expanding `use MishkaCmsWeb, :live_view`, which is about a second of work,
  so the budget is generous: it is here to catch a macro that never returns, not to police a busy
  machine. Checks do not wait for each other — each compiles under a name of its own — so the
  deadline only ever covers one compile.

  ## Fidelity

  The stages are `LiveViewCompiler`'s own — `build_assigns/1`, `build_page_forms/1`,
  `build_event_handlers/1`, `build_info_handlers/1`, `build_renders/1`, `build_helpers/1`,
  `create_module_ast/1` — called directly rather than through `build_module/1`, which differs only
  in firing the `runtime:compile:before_page` hook and a telemetry span. A check must not fire either, and a check
  that reimplemented the stages would eventually pass code the real compile rejects.

  Running them one at a time is also what makes the error attributable: each stage owns one group of
  fragments, so a raise identifies the tab without parsing the message.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler

  # GENEROUS ON PURPOSE. Compiling a page means expanding `use MishkaCmsWeb, :live_view`, which is
  # about a second of work on a warm machine and more on a cold or busy one. The budget is here to
  # catch a macro that never returns, not to police a slow box, and a check that spuriously reports
  # "this took too long" is worse than no budget at all.
  @compile_budget 30_000

  # Named the way the runtime's own compilers name theirs, so `trim_file/1` strips it from a message
  # by the same rule.
  @template_file "mishka_cms_runtime_template_check"

  @typedoc """
  One thing wrong. `tab` is the group it belongs to, `index` and `name` locate it within that group,
  and `line` is a line in the author's own box — each fragment is authored standalone, so there is no
  offset to apply.
  """
  @type fault :: %{
          tab: :template | :events | :infos | :helpers | :page,
          index: non_neg_integer() | nil,
          name: String.t() | nil,
          line: pos_integer() | nil,
          message: String.t()
        }

  @doc """
  Checks one page's code.

  Takes the same shape `LiveViewCompiler` takes — `:template`, `:events`, `:infos`, `:helpers` — and
  fills in the rest, because none of it affects whether the code compiles.

  Returns `:ok`, or every fault it can attribute. Fragment faults are reported together so an author
  fixing three typos is told about three typos; a module-level fault is reported alone, because
  everything after the first one is noise.
  """
  @spec check(map()) :: :ok | {:error, [fault()]}
  def check(page) when is_map(page) do
    params = params(page)

    case fragment_faults(params) do
      [] -> module_faults(params)
      faults -> {:error, faults}
    end
  end

  @doc """
  Whether a TEMPLATE is HEEx the compiler will take.

  THE TOKENIZER IS NOT THE COMPILER, and until this existed the tokenizer was the only thing the
  editor asked. `MishkaCmsCore.Runtime.PageBuilder.Tree.parse/1` accepts `{@a + }` — the braces
  delimit an expression and the expression is a token to it — and HEEx refuses it. So hand-written
  markup went into the document, into a draft and into the live record, and the failure surfaced
  later as a site that would not compile, in a log nobody was looking at.

  This is `check/1`'s syntax half on its own: `Phoenix.LiveView.TagEngine.compile/2`, which is the
  call every one of this runtime's compilers makes, with no module built around it. It costs
  milliseconds rather than the second a full page compile does, which is what lets it sit in front of
  every Apply in the code drawer rather than only in front of a publish.

  What it CANNOT catch is anything semantic — an undefined function, a component called with the
  wrong attrs — because none of that is decided until the module is compiled. `check/1` is where
  those are caught, for a page; the class this catches is the class the tokenizer lets through.
  """
  @spec template(String.t() | nil) :: :ok | {:error, fault()}
  def template(nil), do: :ok

  def template(heex) when is_binary(heex) do
    _ast =
      Phoenix.LiveView.TagEngine.compile(heex,
        line: 1,
        indentation: 0,
        file: @template_file,
        caller: template_env(),
        trim: true,
        tag_handler: Phoenix.LiveView.HTMLEngine
      )

    :ok
  rescue
    error ->
      {:error, fault(:template, nil, nil, error_line(error), trim_file(Exception.message(error)))}
  end

  def template(_heex), do: :ok

  # `Phoenix.Component` imported, because a template may call `render_slot/1` or one of the function
  # components the runtime's own modules import — the engine resolves `<.foo>` against the caller.
  defp template_env do
    import Phoenix.Component, warn: false
    __ENV__
  end

  @doc "Whether the page's code compiles. For a caller that does not want to render the reasons."
  @spec ok?(map()) :: boolean()
  def ok?(page), do: check(page) == :ok

  @doc """
  One line of prose for a fault, the way it should read above the box it belongs to.
  """
  @spec message(fault()) :: String.t()
  def message(%{name: name, line: line, message: message})
      when is_binary(name) and is_integer(line),
      do: gettext("%{name}, line %{line}: %{message}", name: name, line: line, message: message)

  def message(%{name: name, message: message}) when is_binary(name),
    do: gettext("%{name}: %{message}", name: name, message: message)

  def message(%{line: line, message: message}) when is_integer(line),
    do: gettext("Line %{line}: %{message}", line: line, message: message)

  def message(%{message: message}), do: message

  defp params(page) do
    %{
      title: "code_check",
      page_module: candidate(),
      template: Map.get(page, :template) || "",
      events: listed(page, :events),
      infos: listed(page, :infos),
      helpers: listed(page, :helpers)
    }
  end

  defp listed(page, key) do
    page
    |> Map.get(key)
    |> case do
      list when is_list(list) -> Enum.map(list, &normalize/1)
      _other -> []
    end
  end

  defp normalize(%{} = entry) do
    %{
      name: field(entry, :name) || "",
      args: field(entry, :args) || "",
      code: field(entry, :code) || ""
    }
  end

  defp field(entry, key), do: Map.get(entry, key) || Map.get(entry, Atom.to_string(key))

  # THE PRECISE PASS. Each fragment is parsed on its own, so a fault carries the tab, which entry it
  # is and a line the author can find — none of which survives being spliced into a module.
  defp fragment_faults(params) do
    Enum.flat_map([{:events, params.events}, {:infos, params.infos}], fn {tab, entries} ->
      entries |> Enum.with_index() |> Enum.flat_map(&body_fault(tab, &1))
    end) ++
      (params.helpers |> Enum.with_index() |> Enum.flat_map(&helper_fault/1))
  end

  # AN EMPTY BODY IS NOT AN EMPTY HANDLER. It parses, it compiles, and the clause returns `nil` —
  # which LiveView answers with a crash on the first click, naming a return value the author never
  # wrote. Saying so here is the only place the sentence can be useful.
  defp body_fault(tab, {entry, index}) do
    cond do
      blank?(entry.code) ->
        [
          fault(
            tab,
            index,
            entry.name,
            nil,
            gettext("This handler has no code. It must end in {:noreply, socket}.")
          )
        ]

      true ->
        parse_fault(tab, index, entry.name, entry.code)
    end
  end

  defp helper_fault({helper, index}) do
    args_fault =
      case blank?(helper.args) do
        true -> []
        false -> parse_fault(:helpers, index, helper.name, "helper(#{helper.args})")
      end

    body_fault =
      case blank?(helper.code) do
        true ->
          [
            fault(:helpers, index, helper.name, nil, gettext("This helper has no code."))
          ]

        false ->
          parse_fault(:helpers, index, helper.name, helper.code)
      end

    args_fault ++ body_fault
  end

  defp parse_fault(tab, index, name, source) do
    case Code.string_to_quoted(source, file: "#{tab}") do
      {:ok, _ast} ->
        []

      {:error, {meta, message, token}} ->
        [fault(tab, index, name, line(meta), text(message, token))]

      {:error, other} ->
        [fault(tab, index, name, nil, inspect(other))]
    end
  end

  # THE BACKSTOP. Everything the parser cannot know — an undefined function, a bad arity, a helper
  # that shadows a callback — only shows up when the module is really compiled, so it is really
  # compiled, under a name of its own and with a budget, then thrown away.
  # A NAME OF ITS OWN, SO NOTHING HAS TO WAIT. Two earlier attempts got this wrong and both are worth
  # remembering. One shared name meant two concurrent checks purged each other's module out from
  # under the compile, reported as a syntax error nobody wrote. Serialising them on a lock fixed that
  # and replaced it with something worse: every page save in the system queued behind every other
  # one, and a suite that creates pages in sixteen parallel cases took twice as long and failed
  # fourteen tests on ExUnit's own timeout.
  #
  # A unique name has neither problem and costs one atom per check. Atoms are never collected, so
  # that is a real cost and worth stating: a site saving a hundred pages a day would take about
  # thirty years to reach the default limit, and a restart clears it. This runtime already mints a
  # module atom for every page, component and layout it compiles.
  defp candidate,
    do: Module.concat(__MODULE__, "C#{System.unique_integer([:positive])}")

  defp module_faults(params) do
    task = Task.async(MishkaGervaz.Messages.in_caller_locale(fn -> compile(params) end))

    case Task.yield(task, @compile_budget) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, fault}} ->
        {:error, [fault]}

      _timeout ->
        {:error,
         [
           fault(
             :page,
             nil,
             nil,
             nil,
             gettext("This page took too long to compile. Something in it is probably looping.")
           )
         ]}
    end
  end

  defp compile(params) do
    params
    |> stage(:page, &LiveViewCompiler.build_assigns/1)
    |> stage(:template, &LiveViewCompiler.build_page_forms/1)
    |> stage(:events, &LiveViewCompiler.build_event_handlers/1)
    |> stage(:infos, &LiveViewCompiler.build_info_handlers/1)
    |> stage(:template, &LiveViewCompiler.build_renders/1)
    |> stage(:helpers, &LiveViewCompiler.build_helpers/1)
    |> load(params.page_module)
  end

  defp stage({:error, _fault} = error, _tab, _fun), do: error

  defp stage(input, tab, fun) do
    fun.(input)
  rescue
    error ->
      {:error, fault(tab, nil, nil, error_line(error), trim_file(Exception.message(error)))}
  end

  # The HEEx engine names the fake file it was handed, which is a compiler implementation detail
  # standing between the author and "unmatched closing tag". It appears leading — which is noise and
  # goes — and again inside the sentence, where it is doing the work of a noun and is given one.
  defp trim_file(message) do
    message
    |> String.replace(~r/^mishka_cms_runtime_[a-z_]*[^:]*:\d+:\d+:\s*/, "")
    |> String.replace(@template_file, gettext("the template"))
  end

  defp load({:error, _fault} = error, _module), do: error

  # `Code.compile_quoted/2` reports a semantic error as "cannot compile module … (errors have been
  # logged)" and puts the sentence the author needs on the logger instead. `with_diagnostics/1` hands
  # it back, so "undefined function no_such_fn/1" reaches the box that has the call in it rather than
  # the server console.
  defp load(built, module) do
    ast = LiveViewCompiler.create_module_ast(built)
    purge(module)

    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          Code.compile_quoted(ast, "code_check")
          :ok
        rescue
          error -> {:raised, error}
        end
      end)

    outcome(result, diagnostics, module)
  after
    purge(module)
  end

  defp outcome(:ok, _diagnostics, _module), do: :ok

  defp outcome({:raised, error}, diagnostics, module) do
    case Enum.find(diagnostics, &(&1.severity == :error)) do
      %{message: message} = diagnostic ->
        {:error, fault(:page, nil, nil, diagnostic_line(diagnostic), unname(message, module))}

      nil ->
        {:error,
         fault(:page, nil, nil, error_line(error), unname(Exception.message(error), module))}
    end
  end

  # The rehearsal module's name is `C80201` and nothing else in the world calls the page that. It
  # turns up in the middle of otherwise readable sentences — "expected …CodeCheck.C80201 to define
  # such a function" — so it is spelled the way the author thinks of it.
  defp unname(message, module) when is_binary(message),
    do: String.replace(message, inspect(module), gettext("this page"))

  defp unname(message, _module), do: message

  defp diagnostic_line(%{position: {line, _column}}), do: line
  defp diagnostic_line(%{position: line}) when is_integer(line) and line > 0, do: line
  defp diagnostic_line(_diagnostic), do: nil

  # A CHECK MUST LEAVE NOTHING BEHIND — the code, at least; the name is an atom and stays. Purged on
  # both sides of the compile: before, in case an earlier check under this name was killed by the
  # budget, and after, so nothing that was only ever a rehearsal is left loaded.
  defp purge(module) do
    :code.purge(module)
    :code.delete(module)
    :ok
  end

  defp error_line(%{line: line}) when is_integer(line), do: line
  defp error_line(%{meta: meta}) when is_list(meta), do: line(meta)
  defp error_line(_error), do: nil

  defp line(meta) when is_list(meta), do: Keyword.get(meta, :line)
  defp line(_meta), do: nil

  defp text(message, token) when is_binary(message) and is_binary(token),
    do: String.trim(message <> token)

  defp text(message, _token) when is_binary(message), do: String.trim(message)
  defp text(message, _token), do: inspect(message)

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""

  defp fault(tab, index, name, line, message) do
    %{
      tab: tab,
      index: index,
      name: presence(name),
      line: line,
      message: message
    }
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(name), do: name
end
