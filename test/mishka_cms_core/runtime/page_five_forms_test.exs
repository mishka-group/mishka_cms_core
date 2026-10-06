defmodule MishkaCmsCore.Runtime.PageFiveFormsTest do
  @moduledoc """
  Five unrelated forms on one page, each minding its own business.

  This is the acceptance case for the whole feature, and it is written against a page the real
  compiler built: the template goes through `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler` and
  `MishkaCmsCore.Runtime.Compilers.ModuleCompiler`, and the module that comes out is handed the
  params a keystroke and a press of the button really send, then asked to render itself.

  ## Why this drives the module rather than `Phoenix.LiveViewTest.live/2`

  A published page is routed per site by the dynamic router, so `live/2` needs a site, a host and a
  compiled route before it can reach the page at all — machinery that has nothing to do with forms
  and would be the thing under test if it broke. Calling `handle_event/3` and `render/1` on the
  compiled module exercises exactly the code a socket would, and it can hold five forms' worth of
  state side by side, which is what isolation means here.

  ## What isolation has to mean

  Each form owns one page assign. A keystroke in one writes one assign, so the other four cannot
  move; a successful submit resets one assign, so the other four keep what was typed. Both halves
  are asserted by rendering the whole page after each event and reading every form out of that one
  document, because a page is what the visitor sees rather than a socket map.

  ## Where the error text comes from

  Nothing in the CMS renders an error. The messages read here are written by the site's own
  `input/1` — it asks `Phoenix.Component.used_input?/1` first, which is why an untouched field of a
  form the visitor has already typed in stays silent.

  That reading is about which params arrived, not about the action, so the params here are the ones a
  browser really sends. LiveView's own client marks every input of a form as submitted before it
  serialises, so a press of the button carries a key for each of them, blank ones included, and every
  error becomes visible at once. A submit built by hand with an empty map would report nothing, and
  that is the client's contract rather than a rule this page could relax.
  """
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.Compilers.ModuleCompiler

  @moduletag :integration

  @template """
  <main>
    <.form :let={f} for={assigns[:contact_form]} as={:contact} id="contact-form" phx-change="contact_validate" phx-submit="contact_submit" data-success="Thanks for writing.">
      <.input field={f[:name]} type="text" label="Your name" required />
      <.input field={f[:email]} type="email" label="Email" required data-format="email" />
      <.input field={f[:message]} type="textarea" label="Message" required />
      <button type="submit">Send</button>
    </.form>

    <.form :let={f} for={assigns[:newsletter_form]} as={:newsletter} id="newsletter-form" phx-change="newsletter_validate" phx-submit="newsletter_submit" data-success="You are on the list.">
      <.input field={f[:email]} type="email" label="Email" required data-format="email" />
      <button type="submit">Subscribe</button>
    </.form>

    <.form :let={f} for={assigns[:quote_form]} as={:quote} id="quote-form" phx-change="quote_validate" phx-submit="quote_submit" data-success="We will price it up.">
      <.input field={f[:postcode]} type="text" label="Postcode" required pattern="[A-Z]{2}[0-9]{2}" />
      <.input field={f[:email]} type="email" label="Email" data-format="email" />
      <button type="submit">Ask</button>
    </.form>

    <.form :let={f} for={assigns[:feedback_form]} as={:feedback} id="feedback-form" phx-change="feedback_validate" phx-submit="feedback_submit" data-success="Noted, thank you.">
      <.input field={f[:score]} type="number" label="Score" data-cast="integer" required min="1" max="5" />
      <.input field={f[:comment]} type="text" label="Comment" maxlength="20" />
      <button type="submit">Rate</button>
    </.form>

    <.form :let={f} for={assigns[:signup_form]} as={:signup} id="signup-form" phx-change="signup_validate" phx-submit="signup_submit" data-success="Welcome aboard.">
      <.input field={f[:email]} type="email" label="Email" required data-format="email" />
      <.input field={f[:password]} type="password" label="Password" required minlength="8" />
      <.input field={f[:password_confirmation]} type="password" label="Repeat it" required data-confirms="password" />
      <button type="submit">Join</button>
    </.form>
  </main>
  """

  @seeds ~w(contact newsletter quote feedback signup)

  # One token per form, as the editor writes them now.
  @tokens %{
    "contact" => "k7m2q",
    "newsletter" => "p3xa6",
    "quote" => "aaaa2",
    "feedback" => "bbbb3",
    "signup" => "cccc4"
  }

  setup_all do
    %{page: page!(@template), tagged: page!(tagged_template())}
  end

  defp page!(template) do
    module = :"Elixir.PageFiveFormsPage#{System.unique_integer([:positive])}"

    ast =
      LiveViewCompiler.build_module(%{
        title: "Five forms",
        page_module: module,
        template: template,
        events: []
      })

    {:ok, ^module, diagnostics} = ModuleCompiler.compile_module(ast)

    refute Enum.any?(diagnostics, &(&1.message =~ "handle_event")),
           "the compiler complained about the generated clauses: #{inspect(diagnostics)}"

    module
  end

  defp tagged_template do
    Enum.reduce(@tokens, @template, fn {seed, token}, template ->
      template
      |> String.replace(~s("#{seed}_validate"), ~s("#{seed}-#{token}-validate"))
      |> String.replace(~s("#{seed}_submit"), ~s("#{seed}-#{token}-submit"))
    end)
  end

  defp tagged_event(seed, kind), do: "#{seed}-#{@tokens[seed]}-#{kind}"

  defp socket, do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

  defp change(module, socket, seed, values) do
    {:noreply, socket} = module.handle_event("#{seed}_validate", %{seed => values}, socket)
    socket
  end

  defp send_it(module, socket, seed, values) do
    {:noreply, socket} = module.handle_event("#{seed}_submit", %{seed => values}, socket)
    socket
  end

  defp html(module, socket) do
    socket.assigns
    |> Map.put(:__changed__, nil)
    |> module.render()
    |> Phoenix.LiveViewTest.rendered_to_string()
  end

  defp found(module, socket, selector),
    do: module |> html(socket) |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp errors(module, socket, seed) do
    module
    |> found(socket, "##{seed}-form p")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp quiet?(module, socket, seed), do: errors(module, socket, seed) == []

  defp value_of(module, socket, seed, name) do
    module
    |> found(socket, ~s(##{seed}-form [name="#{seed}[#{name}]"]))
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  defp blank(names), do: Map.new(names, &{&1, ""})

  defp bad_value("contact"), do: %{"email" => "nope"}
  defp bad_value("newsletter"), do: %{"email" => "nope"}
  defp bad_value("quote"), do: %{"postcode" => "nope"}
  defp bad_value("feedback"), do: %{"score" => "99"}
  defp bad_value("signup"), do: %{"password" => "short"}

  describe "structure" do
    test "each form is its own element, with its own id, params and pair of events", %{
      page: module
    } do
      html = html(module, socket())

      for seed <- @seeds do
        assert html =~ ~s(id="#{seed}-form")
        assert html =~ ~s(phx-change="#{seed}_validate")
        assert html =~ ~s(phx-submit="#{seed}_submit")
      end

      assert html =~ ~s(name="contact[email]")
      assert html =~ ~s(name="newsletter[email]")
      assert html =~ ~s(name="signup[password_confirmation]")
    end

    test "the compiler read all five out of the one template", %{page: module} do
      specs = module.__page_forms__()

      assert Enum.map(specs, & &1.as) == @seeds
      assert Enum.map(specs, & &1.assign) == Enum.map(@seeds, &:"#{&1}_form")
      assert Enum.all?(specs, &(&1.success != nil))
    end

    test "and generated a working handler for every one of them", %{page: module} do
      for seed <- @seeds do
        socket = change(module, socket(), seed, %{})
        assert %Phoenix.HTML.Form{} = socket.assigns[:"#{seed}_form"]
      end
    end
  end

  describe "first paint" do
    test "says nothing about anything, because nobody has typed", %{page: module} do
      socket = socket()

      for seed <- @seeds do
        assert quiet?(module, socket, seed), "#{seed} complained before it was touched"
      end
    end
  end

  describe "per-form validation" do
    test "a bad value shows an error in its own form and in no other", %{page: module} do
      for seed <- @seeds do
        socket = change(module, socket(), seed, bad_value(seed))

        refute quiet?(module, socket, seed), "#{seed} accepted a value it should refuse"

        for other <- @seeds, other != seed do
          assert quiet?(module, socket, other),
                 "typing in #{seed} put #{inspect(errors(module, socket, other))} on #{other}"
        end
      end
    end

    test "an untouched field of the same form stays quiet too", %{page: module} do
      socket = change(module, socket(), "contact", %{"email" => "nope"})

      assert errors(module, socket, "contact") == ["must have the @ sign and no spaces"]
    end

    test "a number outside its range is refused and inside it is not", %{page: module} do
      assert errors(module, change(module, socket(), "feedback", %{"score" => "9"}), "feedback") ==
               ["must be less than or equal to 5"]

      assert quiet?(module, change(module, socket(), "feedback", %{"score" => "3"}), "feedback")
    end

    test "a pattern is enforced against what the visitor typed", %{page: module} do
      refute quiet?(module, change(module, socket(), "quote", %{"postcode" => "nope"}), "quote")
      assert quiet?(module, change(module, socket(), "quote", %{"postcode" => "AB12"}), "quote")
    end

    test "a confirmation only complains when the two differ", %{page: module} do
      mismatched = %{"password" => "hunter2hunter2", "password_confirmation" => "different"}

      assert "does not match confirmation" in errors(
               module,
               change(module, socket(), "signup", mismatched),
               "signup"
             )

      matched = %{"password" => "hunter2hunter2", "password_confirmation" => "hunter2hunter2"}

      assert quiet?(module, change(module, socket(), "signup", matched), "signup")
    end
  end

  describe "independent state" do
    test "two forms hold two different values for the same field name", %{page: module} do
      socket =
        socket()
        |> then(&change(module, &1, "contact", %{"email" => "a@b.co"}))
        |> then(&change(module, &1, "newsletter", %{"email" => "c@d.co"}))

      assert value_of(module, socket, "contact", "email") == "a@b.co"
      assert value_of(module, socket, "newsletter", "email") == "c@d.co"
    end

    test "params arriving under another form's seed are ignored, not merged", %{page: module} do
      socket =
        change(module, socket(), "contact", %{})
        |> then(fn socket ->
          {:noreply, socket} =
            module.handle_event(
              "contact_validate",
              %{"newsletter" => %{"email" => "a@b.co"}},
              socket
            )

          socket
        end)

      assert value_of(module, socket, "contact", "email") in [nil, ""]
    end
  end

  describe "submit" do
    test "an invalid form shows every one of its errors at once", %{page: module} do
      socket =
        send_it(module, socket(), "signup", blank(~w(email password password_confirmation)))

      assert errors(module, socket, "signup") == List.duplicate("can't be blank", 3)

      for other <- @seeds, other != "signup" do
        assert quiet?(module, socket, other)
      end
    end

    test "a field the browser did not send is not reported, so nothing is invented", %{
      page: module
    } do
      socket = send_it(module, socket(), "signup", blank(["email"]))

      assert errors(module, socket, "signup") == ["can't be blank"]
    end

    test "a valid one clears itself and flashes its own success message", %{page: module} do
      socket =
        socket()
        |> then(&change(module, &1, "contact", %{"email" => "a@b.co"}))
        |> then(&send_it(module, &1, "feedback", %{"score" => "4", "comment" => "good"}))

      assert socket.assigns.flash == %{"info" => "Noted, thank you."}
      assert value_of(module, socket, "feedback", "score") in [nil, ""]
      assert value_of(module, socket, "contact", "email") == "a@b.co"
    end

    test "an invalid one keeps what was typed so nobody retypes it", %{page: module} do
      socket = send_it(module, socket(), "quote", %{"postcode" => "nope", "email" => "a@b.co"})

      assert value_of(module, socket, "quote", "postcode") == "nope"
      assert value_of(module, socket, "quote", "email") == "a@b.co"
      assert socket.assigns.flash == %{}
    end
  end

  describe "five forms whose event names carry a token" do
    test "a bad value shows an error in its own form and in no other", %{tagged: module} do
      for seed <- @seeds do
        {:noreply, socket} =
          module.handle_event(
            tagged_event(seed, "validate"),
            %{seed => bad_value(seed)},
            socket()
          )

        refute quiet?(module, socket, seed), "#{seed} accepted a value it should refuse"

        for other <- @seeds, other != seed do
          assert quiet?(module, socket, other), "typing in #{seed} put an error on #{other}"
        end
      end
    end

    test "a valid submit clears its own form and flashes its own message", %{tagged: module} do
      {:noreply, socket} =
        module.handle_event(
          tagged_event("contact", "validate"),
          %{"contact" => %{"email" => "a@b.co"}},
          socket()
        )

      {:noreply, socket} =
        module.handle_event(
          tagged_event("feedback", "submit"),
          %{"feedback" => %{"score" => "4", "comment" => "good"}},
          socket
        )

      assert socket.assigns.flash == %{"info" => "Noted, thank you."}
      assert value_of(module, socket, "contact", "email") == "a@b.co"
    end
  end

  describe "the catch-all" do
    test "still answers an event no form on the page names", %{page: module} do
      given = socket()
      assert {:noreply, ^given} = module.handle_event("nothing_names_this", %{}, given)
    end
  end
end
