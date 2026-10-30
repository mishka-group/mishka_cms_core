# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.CodeCheckTest do
  @moduledoc """
  Telling an author their code is wrong, before a visitor finds out.

  Nothing between the page form and the BEAM reads author Elixir today, and all three ways it can be
  wrong are quiet: a page that does not precompile is not built when it is saved, a page whose module
  is loaded keeps serving the previous version when a recompile fails, and the recorded reason is
  read by nothing a human can see.

  The three classes below are the whole point, and only the first is a parse error — which is why
  parsing alone was never going to be the answer.

  ## Why this module is not async

  One test here reads `:code.all_loaded/0`, which is the whole VM's, and asserts that a check leaves
  no rehearsal module behind. Any other test that saves a page's code runs a check too, and run
  concurrently its in-flight module lands in the count — the baseline reads one, the check purges
  nothing of ours, and the test fails with `0 != 1` having found nothing wrong. A guarantee about a
  global can only be measured with the global to ourselves.
  """
  use ExUnit.Case, async: false

  @moduletag :unit

  alias MishkaCmsCore.Runtime.Authoring.CodeCheck

  defp page(attrs), do: Map.merge(%{template: "<div>hi</div>"}, Map.new(attrs))

  defp faults(attrs) do
    {:error, faults} = CodeCheck.check(page(attrs))
    faults
  end

  describe "code that is fine" do
    test "a bare template" do
      assert CodeCheck.check(page([])) == :ok
    end

    test "an event, an info and a helper together" do
      assert CodeCheck.check(
               page(
                 events: [%{name: "inc", code: "{:noreply, socket}"}],
                 infos: [%{name: ":tick", code: "{:noreply, socket}"}],
                 helpers: [%{name: "double", args: "n", code: "n * 2"}]
               )
             ) == :ok
    end

    test "a helper of two arguments, which the compiler could not build until recently" do
      assert CodeCheck.check(page(helpers: [%{name: "add", args: "a, b", code: "a + b"}])) == :ok
    end

    test "a handler may use the params and socket the compiler injects" do
      assert CodeCheck.check(
               page(events: [%{name: "save", code: ~S|{:noreply, assign(socket, :p, params)}|}])
             ) == :ok
    end

    test "a page with no code at all" do
      assert CodeCheck.check(%{}) == :ok
    end

    test "string keys are accepted, because a form sends them" do
      assert CodeCheck.check(%{
               "template" => "<div>hi</div>",
               "events" => [%{"name" => "inc", "code" => "{:noreply, socket}"}]
             }) == :ok
    end
  end

  # CLASS ONE: it does not parse. The only class a parser alone would catch.
  describe "a syntax error" do
    test "is attributed to the entry it is in, with a line" do
      assert [fault] = faults(events: [%{name: "inc", code: "{:noreply, socket"}])

      assert fault.tab == :events
      assert fault.index == 0
      assert fault.name == "inc"
      assert fault.line == 1
      assert fault.message =~ "missing terminator"
    end

    test "carries the line within the author's own box, not within a generated module" do
      code = """
      socket =
        assign(socket, :a, 1)

      {:noreply, socket
      """

      assert [fault] = faults(events: [%{name: "inc", code: code}])
      assert fault.line == 4
    end

    test "every bad entry is reported, so three typos are three messages" do
      found =
        faults(
          events: [
            %{name: "a", code: "{:noreply, socket"},
            %{name: "b", code: "{:noreply, socket}"},
            %{name: "c", code: "case do"}
          ]
        )

      assert Enum.map(found, & &1.name) == ["a", "c"]
    end

    test "an info handler is checked the same way" do
      assert [%{tab: :infos, name: ":tick"}] =
               faults(infos: [%{name: ":tick", code: "{:noreply"}])
    end

    test "a helper's argument list is checked as an argument list" do
      assert [fault] = faults(helpers: [%{name: "h", args: "a,", code: ":ok"}])

      assert fault.tab == :helpers
      assert fault.message =~ "syntax error"
    end

    test "a broken template is attributed to the template" do
      assert [fault] = faults(template: "<div><span></div>")

      assert fault.tab == :template
      assert fault.message =~ "unmatched closing tag"

      refute fault.message =~ "mishka_cms_runtime_page",
             "the fake file name the engine was handed is not the author's problem"
    end
  end

  # CLASS TWO: it parses into a perfectly good AST and is not a program.
  describe "code that parses but cannot be compiled" do
    test "an undefined function is named" do
      assert [fault] = faults(events: [%{name: "e", code: "no_such_function_here(socket)"}])

      assert fault.tab == :page
      assert fault.message =~ "undefined function no_such_function_here/1"
    end

    test "a definition where an expression belongs is refused" do
      assert [fault] = faults(events: [%{name: "e", code: "def def def"}])
      assert fault.tab == :page
    end

    # WHAT `field-no-form` REALLY COSTS. A field carries the binding the form's `:let` supplied, so
    # a field left outside every form reads a variable nothing binds — and this validation runs on
    # the page's own action, which means the page cannot be stored at all until it is back inside
    # one. The audit's words are written from this.
    test "a bound field with no form around it is an undefined variable" do
      assert [fault] = faults(template: ~s(<div><.input field={f[:email]} type="text" /></div>))

      assert fault.message =~ ~s(undefined variable "f")
    end

    test "the same field naming itself outright compiles, which is why the two read differently" do
      assert CodeCheck.check(page(template: ~s(<div><input name="email" /></div>))) == :ok
    end
  end

  describe "a page with a form" do
    @form ~s(<.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact-k7m2q-validate" phx-submit="contact-k7m2q-submit"><input name={f[:email].name} value={f[:email].value} /><button type="submit">Send</button></.form>)

    test "a handler body calling __page_forms__() passes, as the default code does" do
      alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler

      events = [
        %{
          name: "contact-k7m2q-submit",
          code: LiveViewCompiler.form_handler_sample(:submit, "contact-k7m2q-submit")
        },
        %{
          name: "contact-k7m2q-validate",
          code: LiveViewCompiler.form_handler_sample(:validate, "contact-k7m2q-validate")
        }
      ]

      assert CodeCheck.check(page(template: @form, events: events)) == :ok
    end

    test "and so does one stored under the form's name before a rename" do
      code =
        "MishkaCmsCore.Runtime.PageForm.submit(socket, __page_forms__(), \"contact-k7m2q-submit\", params)"

      renamed = String.replace(@form, "contact-k7m2q", "enquiry-k7m2q")

      assert CodeCheck.check(
               page(template: renamed, events: [%{name: "contact-k7m2q-submit", code: code}])
             ) ==
               :ok
    end

    test "the default code passes for two forms built deep, one of them a kit wrapper" do
      alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler

      template = """
      <section>
        <div class="card"><div class="grid"><div class="col">#{@form}</div></div></div>
        <.component component_name="kit-form" site="Global" :let={g} id="news-form" as={:news} for={assigns[:news_form]} phx-change="news-p3xa6-validate" phx-submit="news-p3xa6-submit">
          <div class="card"><div class="grid">
            <div class="col"><input name={g[:email].name} value={g[:email].value} /></div>
            <div class="col"><button type="submit">Join</button></div>
          </div></div>
        </.component>
      </section>
      """

      events =
        for event <- ~w(contact-k7m2q-submit news-p3xa6-validate news-p3xa6-submit) do
          kind = if String.ends_with?(event, "validate"), do: :validate, else: :submit
          %{name: event, code: LiveViewCompiler.form_handler_sample(kind, event)}
        end

      assert CodeCheck.check(page(template: template, events: events)) == :ok
    end

    test "an undefined function is still refused, with its line" do
      code = "_forms = __page_forms__()\nno_such_function_here(socket)"

      assert [fault] =
               faults(template: @form, events: [%{name: "contact-k7m2q-submit", code: code}])

      assert fault.tab == :page
      assert fault.line == 2
      assert fault.message =~ "undefined function no_such_function_here/1"
    end
  end

  # CLASS THREE: it compiles, and it is still wrong in a way the runtime reports as something else.
  describe "an empty handler" do
    test "is named, rather than left to crash on the first click" do
      assert [fault] = faults(events: [%{name: "inc", code: ""}])

      assert fault.tab == :events
      assert fault.message =~ "no code"
      assert fault.message =~ "{:noreply, socket}"
    end

    test "whitespace is empty too" do
      assert [%{message: message}] = faults(infos: [%{name: ":tick", code: "   \n  "}])
      assert message =~ "no code"
    end

    test "an empty helper body is named" do
      assert [%{tab: :helpers, message: message}] = faults(helpers: [%{name: "h", code: ""}])
      assert message =~ "no code"
    end

    test "a helper with no arguments is fine — that is a function of no arguments" do
      assert CodeCheck.check(page(helpers: [%{name: "pi", args: "", code: "3.14"}])) == :ok
    end
  end

  describe "the check leaves nothing behind" do
    # A rehearsal must never be left loaded. The name is unique per check — that is what lets checks
    # run at once without purging each other — so what matters is that none of them survives.
    #
    # The count is the VM's, which is why this module is sync; see the moduledoc.
    test "no candidate module is left loaded" do
      before = :code.all_loaded() |> Enum.count(&candidate?/1)

      for _ <- 1..5,
          do:
            assert(
              CodeCheck.check(page(events: [%{name: "e", code: "{:noreply, socket}"}])) == :ok
            )

      assert :code.all_loaded() |> Enum.count(&candidate?/1) == before
    end

    defp candidate?({module, _file}),
      do: module |> Atom.to_string() |> String.starts_with?("Elixir.#{inspect(CodeCheck)}.C")

    test "checking twice in a row is not a redefinition" do
      assert CodeCheck.check(page([])) == :ok
      assert CodeCheck.check(page([])) == :ok
    end
  end

  # THE BUDGET MUST TIME THE COMPILE, NOT THE QUEUE. Checks are serialised on one candidate module
  # name, and the deadline used to start before the lock was acquired — so it covered however long
  # every check ahead of this one took. Sixteen at once, which is exactly what this suite's
  # `max_cases` produces, and ten of them reported a timeout none of them had. Two people saving at
  # the same time would have seen the same thing.
  describe "under contention" do
    @tag timeout: 180_000
    test "sixteen at once all answer correctly" do
      good = page([])
      bad = page(events: [%{name: "e", code: "{:noreply, socket"}])

      results =
        1..16
        |> Enum.map(fn index ->
          Task.async(fn ->
            case rem(index, 2) do
              0 -> {:good, CodeCheck.check(good)}
              1 -> {:bad, CodeCheck.check(bad)}
            end
          end)
        end)
        |> Task.await_many(150_000)

      for {:good, result} <- results, do: assert(result == :ok)

      for {:bad, result} <- results do
        assert {:error, [%{message: message} | _rest]} = result
        assert message =~ "missing terminator", "got #{message}"
      end
    end
  end

  # THE TOKENIZER IS NOT THE COMPILER, and it was the only thing the editor asked. `Tree.parse/1`
  # accepts `{@a + }` happily — the expression is a token to it — and HEEx refuses it, so hand-written
  # markup went into the document, into a draft and into the live record, and the failure surfaced as
  # a site that would not compile.
  #
  # This is the SYNTAX half of `check/1` alone: no module, no handlers, no `use MishkaCmsWeb`, which
  # is why it costs milliseconds and can sit in front of every Apply rather than only a publish.
  describe "template/1" do
    test "takes HEEx the compiler takes" do
      assert CodeCheck.template("<div>hi</div>") == :ok
      assert CodeCheck.template(~s(<div class="a">{@thing}</div>)) == :ok
      assert CodeCheck.template("<div>{@inner_content}</div>") == :ok
      assert CodeCheck.template("") == :ok
    end

    test "and refuses an expression that is not Elixir" do
      assert {:error, fault} = CodeCheck.template("<div>{@a + }</div>")
      assert fault.tab == :template
      assert is_binary(fault.message)
    end

    test "an unclosed block is refused too" do
      assert {:error, _fault} = CodeCheck.template("<div>{if true do}</div>")
    end

    test "and a broken attribute expression" do
      assert {:error, _fault} = CodeCheck.template(~s|<div class={"a" <> }>x</div>|)
    end

    # An assign nothing defines is not a compile error — it is a runtime one, and a template written
    # against assigns the section supplies would be unusable if this refused it.
    test "an unknown assign is not a syntax error" do
      assert CodeCheck.template("<div>{@nobody_defines_this}</div>") == :ok
    end

    test "a message reads as prose, without the fake filename in it" do
      {:error, fault} = CodeCheck.template("<div>{@a + }</div>")

      refute CodeCheck.message(fault) =~ "mishka_cms_runtime"
    end
  end

  describe "ok?/1 and message/1" do
    test "ok?/1 answers without the reasons" do
      assert CodeCheck.ok?(page([]))
      refute CodeCheck.ok?(page(events: [%{name: "e", code: "{:noreply"}]))
    end

    test "message/1 reads as a sentence above the box it belongs to" do
      [fault] = faults(events: [%{name: "inc", code: "{:noreply, socket"}])
      assert CodeCheck.message(fault) =~ "inc, line 1:"

      [empty] = faults(events: [%{name: "inc", code: ""}])
      assert CodeCheck.message(empty) =~ "inc:"
    end
  end
end
