defmodule MishkaCmsCore.Runtime.Compilers.PageFormCompileTest do
  @moduledoc """
  What a page gains, and what it must not lose, when its template declares a form.

  The whole feature rests on one ordering fact, so it is checked against the AST the compiler really
  emits rather than against a belief about it: a generated clause has to sit before the catch-all,
  or it never runs, and there must be no second clause for a name the author already declared, or
  the author's clause is unreachable and their page silently stops responding.

  The rest is the round trip. A template is compiled into a real module, and the module is handed
  the params a keystroke and a submit actually send.
  """
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.Compilers.ModuleCompiler
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms

  @moduletag :unit

  @template """
  <section>
    <.form for={assigns[:contact_form]} as={:contact} id="contact-form" phx-change="contact_validate" phx-submit="contact_submit" data-success="Sent.">
      <input type="text" name="name" required minlength="2" />
      <input type="email" name="email" required data-format="email" />
      <button type="submit">Send</button>
    </.form>
  </section>
  """

  defp build(events, template \\ @template) do
    module = :"Elixir.PageFormCompilePage#{System.unique_integer([:positive])}"

    ast =
      LiveViewCompiler.build_module(%{
        title: "Contact",
        page_module: module,
        template: template,
        events: events
      })

    {module, ast}
  end

  defp compiled(events, template \\ @template) do
    {module, ast} = build(events, template)
    {:ok, ^module, diagnostics} = ModuleCompiler.compile_module(ast)

    refute Enum.any?(diagnostics, &(&1.message =~ "handle_event")),
           "the compiler complained about the generated clauses: #{inspect(diagnostics)}"

    {module, ast}
  end

  defp socket, do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

  defp clauses(ast) do
    {_ast, names} =
      Macro.prewalk(ast, [], fn
        {:def, _meta, [{:handle_event, _head, [matched | _rest]} | _body]} = node, acc ->
          {node, [name_of(matched) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(names)
  end

  defp name_of(matched) when is_binary(matched), do: matched
  defp name_of(_variable), do: :catch_all

  defp event_names(ast), do: ast |> clauses() |> Enum.reject(&(&1 == :catch_all))

  describe "__page_forms__/0" do
    test "carries the template's own form, its events and its fields" do
      {module, _ast} = compiled([])

      assert [spec] = module.__page_forms__()
      assert spec.assign == :contact_form
      assert spec.as == "contact"
      assert spec.id == "contact-form"
      assert spec.change == "contact_validate"
      assert spec.submit == "contact_submit"
      assert spec.success == "Sent."
      assert Enum.map(spec.fields, & &1.key) == [:name, :email]
      assert [:required, {:min_length, 2}] = Enum.find(spec.fields, &(&1.key == :name)).rules
      assert {:format, :email} in Enum.find(spec.fields, &(&1.key == :email)).rules
    end

    test "a page whose template declares no form still answers, with nothing" do
      module = :"Elixir.PageFormCompilePage#{System.unique_integer([:positive])}"

      ast =
        LiveViewCompiler.build_module(%{
          title: "Plain",
          page_module: module,
          template: "<div>nothing here</div>",
          events: []
        })

      {:ok, ^module, _diagnostics} = ModuleCompiler.compile_module(ast)

      assert module.__page_forms__() == []

      assert clauses(ast) == ["pb:say", :catch_all],
             "no form means no form clause; the message clause is on every page"
    end
  end

  describe "the generated handlers" do
    test "both are emitted, once each, and before the catch-all" do
      {_module, ast} = build([])

      assert clauses(ast) == ["contact_validate", "contact_submit", "pb:say", :catch_all]
    end

    test "change puts a form on the socket under the assign the template named" do
      {module, _ast} = compiled([])

      params = %{"contact" => %{"name" => "Ada", "_unused_email" => ""}}

      assert {:noreply, socket} = module.handle_event("contact_validate", params, socket())
      assert %Phoenix.HTML.Form{} = form = socket.assigns.contact_form
      assert form.name == "contact"
      assert form.id == "contact-form"
      assert form.params["name"] == "Ada"
    end

    test "submit re-renders a form the visitor has not filled in, with its errors" do
      {module, _ast} = compiled([])

      assert {:noreply, socket} =
               module.handle_event("contact_submit", %{"contact" => %{}}, socket())

      assert %Phoenix.HTML.Form{} = form = socket.assigns.contact_form
      assert form.action == :submit
      assert Keyword.has_key?(form.errors, :name)
      assert Keyword.has_key?(form.errors, :email)
    end
  end

  describe "an author who declares the event themselves" do
    test "wins the name outright, and no second clause is emitted for it" do
      author = %{
        name: "contact_validate",
        code: "{:noreply, Phoenix.Component.assign(socket, :author_ran, true)}",
        signature: nil
      }

      {module, ast} = compiled([author])

      assert clauses(ast) == ["contact_submit", "pb:say", "contact_validate", :catch_all]

      assert Enum.count(clauses(ast), &(&1 == "contact_submit")) == 1,
             "a second clause for a name the author declared is unreachable code in their page"

      assert Enum.count(event_names(ast), &(&1 == "contact_validate")) == 1

      params = %{"contact" => %{"name" => "Ada"}}

      assert {:noreply, socket} = module.handle_event("contact_validate", params, socket())
      assert socket.assigns.author_ran == true
      assert socket.assigns[:contact_form] == nil
    end

    test "and the form's other event is still generated for them" do
      author = %{
        name: "contact_validate",
        code: "{:noreply, socket}",
        signature: nil
      }

      {module, _ast} = compiled([author])

      assert {:noreply, socket} =
               module.handle_event("contact_submit", %{"contact" => %{}}, socket())

      assert %Phoenix.HTML.Form{} = socket.assigns.contact_form
    end
  end

  # The same form with a token in its event names, as the editor now writes it. `seed` stands for the
  # form's name after a rename; the token stays.
  defp tagged(seed, token) do
    String.replace(
      @template,
      ~s(as={:contact} id="contact-form" phx-change="contact_validate" phx-submit="contact_submit"),
      ~s(as={:contact} id="contact-form" phx-change="#{seed}-#{token}-validate" phx-submit="#{seed}-#{token}-submit")
    )
  end

  defp author(name, code), do: %{name: name, code: code, signature: nil}

  # What each `PageForm.validate`/`PageForm.submit` call in the page names its form by.
  defp form_calls(ast) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:MishkaCmsCore, :Runtime, :PageForm]}, kind]}, _, args} =
            node,
        acc
        when kind in [:validate, :submit] ->
          {node, [{kind, Enum.at(args, 2)} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(calls)
  end

  @ran "{:noreply, Phoenix.Component.assign(socket, :author_ran, true)}"

  describe "a form whose event names carry a token" do
    test "the generated clause passes the event string, not the assign" do
      {_module, ast} = build([], tagged("contact", "k7m2q"))

      assert form_calls(ast) == [
               {:validate, "contact-k7m2q-validate"},
               {:submit, "contact-k7m2q-submit"}
             ]
    end

    test "and both clauses work" do
      {module, _ast} = compiled([], tagged("contact", "k7m2q"))

      assert {:noreply, socket} =
               module.handle_event(
                 "contact-k7m2q-validate",
                 %{"contact" => %{"name" => "Ada"}},
                 socket()
               )

      assert socket.assigns.contact_form.params["name"] == "Ada"

      assert {:noreply, socket} =
               module.handle_event("contact-k7m2q-submit", %{"contact" => %{}}, socket())

      assert socket.assigns.contact_form.action == :submit
    end

    test "an entry stored under the old tagged name still runs after the form is renamed" do
      {module, ast} =
        compiled([author("contact-k7m2q-submit", @ran)], tagged("enquiry", "k7m2q"))

      assert clauses(ast) == [
               "enquiry-k7m2q-validate",
               "pb:say",
               "enquiry-k7m2q-submit",
               :catch_all
             ]

      assert {:noreply, socket} =
               module.handle_event("enquiry-k7m2q-submit", %{"contact" => %{}}, socket())

      assert socket.assigns.author_ran == true
    end

    test "an untouched default body stored under the old name still finds its form" do
      sample = LiveViewCompiler.form_handler_sample(:submit, "contact-k7m2q-submit")

      {module, _ast} =
        compiled([author("contact-k7m2q-submit", sample)], tagged("enquiry", "k7m2q"))

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:noreply, socket} =
                 module.handle_event("enquiry-k7m2q-submit", %{"contact" => %{}}, socket())

        assert socket.assigns.contact_form.action == :submit
      end)
    end

    test "a new form never runs a deleted form's handler because its seed was reused" do
      {module, ast} =
        compiled([author("contact-k7m2q-submit", @ran)], tagged("contact", "p3xa6"))

      assert "contact-p3xa6-submit" in clauses(ast)

      assert {:noreply, socket} =
               module.handle_event("contact-p3xa6-submit", %{"contact" => %{}}, socket())

      refute Map.has_key?(socket.assigns, :author_ran)
      assert socket.assigns.contact_form.action == :submit
    end

    test "a legacy body naming the form by its assign still works" do
      body =
        "MishkaCmsCore.Runtime.PageForm.submit(socket, __page_forms__(), :contact_form, params)"

      {module, _ast} = compiled([author("contact_submit", body)])

      assert {:noreply, socket} =
               module.handle_event("contact_submit", %{"contact" => %{}}, socket())

      assert socket.assigns.contact_form.action == :submit
    end
  end

  # Two forms on one page, a core `<.form>` and a kit wrapper lending its form through `:let`, each
  # with its field and its Send button three levels down: card > grid > column.
  defp deep(contact_seed, news_seed) do
    """
    <section>
      <.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="#{contact_seed}-k7m2q-validate" phx-submit="#{contact_seed}-k7m2q-submit">
        <div class="card"><div class="grid">
          <div class="col"><input type="text" name={f[:name].name} value={f[:name].value} required minlength="2" /></div>
          <div class="col"><button type="submit">Send</button></div>
        </div></div>
      </.form>
      <.component component_name="kit-form" site="Global" :let={g} id="news-form" as={:news} for={assigns[:news_form]} phx-change="#{news_seed}-p3xa6-validate" phx-submit="#{news_seed}-p3xa6-submit">
        <div class="card"><div class="grid">
          <div class="col"><input type="email" name={g[:email].name} value={g[:email].value} required data-format="email" /></div>
          <div class="col"><button type="submit">Join</button></div>
        </div></div>
      </.component>
    </section>
    """
  end

  describe "two forms built deep, one of them a kit wrapper" do
    test "each reads its own deep field and answers its own tagged events" do
      {module, _ast} = compiled([], deep("contact", "news"))

      assert [contact, news] = module.__page_forms__()
      assert Enum.map(contact.fields, & &1.key) == [:name]
      assert Enum.map(news.fields, & &1.key) == [:email]

      {:noreply, socket} =
        module.handle_event("news-p3xa6-submit", %{"news" => %{"email" => "nope"}}, socket())

      assert Keyword.has_key?(socket.assigns.news_form.errors, :email)
      refute Map.has_key?(socket.assigns, :contact_form)

      {:noreply, socket} =
        module.handle_event("contact-k7m2q-validate", %{"contact" => %{"name" => "Ada"}}, socket)

      assert socket.assigns.contact_form.params["name"] == "Ada"
      assert socket.assigns.news_form.params["email"] == "nope"
    end

    test "a handler stored for the kit form follows it through a rename and never answers the other" do
      {module, ast} =
        compiled([author("news-p3xa6-submit", @ran)], deep("enquiry", "letters"))

      assert "letters-p3xa6-submit" in clauses(ast)
      refute "news-p3xa6-submit" in clauses(ast)

      {:noreply, socket} =
        module.handle_event("letters-p3xa6-submit", %{"news" => %{}}, socket())

      assert socket.assigns.author_ran == true

      {:noreply, socket} =
        module.handle_event("enquiry-k7m2q-submit", %{"contact" => %{}}, socket())

      refute Map.has_key?(socket.assigns, :author_ran)
      assert socket.assigns.contact_form.action == :submit
    end
  end

  # A pre-token form a code author renamed: its handler moves to the tagged name, and the code
  # Customize wrote for it, which quotes the old name, still reaches its own form and not the other.
  describe "a pre-token handler moved by a rename, deep beside a kit wrapper" do
    test "reaches its own form under the new name" do
      stores =
        ~s|MishkaCmsCore.Runtime.PageForm.submit(socket, __page_forms__(), "contact_submit", params, fn values -> send(self(), {:stored, values}) end)|

      template = deep("enquiry", "news")
      current = template |> PageForms.declared() |> Enum.flat_map(&[&1.change, &1.submit])

      events =
        PageForms.follow([author("contact_submit", stores)], current, %{
          "contact_submit" => "contact-k7m2q-submit"
        })

      {module, ast} = compiled(events, template)
      assert "enquiry-k7m2q-submit" in clauses(ast)

      {:noreply, socket} =
        module.handle_event(
          "enquiry-k7m2q-submit",
          %{"contact" => %{"name" => "Ada"}},
          %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
        )

      assert_received {:stored, %{name: "Ada"}}
      assert socket.assigns.flash["info"] == "Sent. Thank you."
      refute Map.has_key?(socket.assigns, :news_form)
    end
  end

  # Nothing receives either form: the visitor is still thanked, and neither the automatic clause nor
  # the log carries what they typed (spec 0.9). A customized sample prints, because a developer
  # asked it to.
  describe "two deep forms with nothing receiving them" do
    defp flashing, do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

    test "the automatic submit thanks the visitor, prints nothing and logs names only" do
      {module, _ast} = compiled([], deep("contact", "news"))

      for {event, params} <- [
            {"news-p3xa6-submit", %{"news" => %{"email" => "private@example.com"}}},
            {"contact-k7m2q-submit", %{"contact" => %{"name" => "Private Person"}}}
          ] do
        logged =
          ExUnit.CaptureLog.capture_log(fn ->
            printed =
              ExUnit.CaptureIO.capture_io(fn ->
                assert {:noreply, socket} = module.handle_event(event, params, flashing())
                assert socket.assigns.flash["info"] == "Sent. Thank you."
              end)

            assert printed == ""
          end)

        assert logged =~ "nothing receives it"
        refute logged =~ "private@example.com"
        refute logged =~ "Private Person"
      end
    end

    test "the customized sample prints the params under its event, then still thanks the visitor" do
      sample = LiveViewCompiler.form_handler_sample(:submit, "news-p3xa6-submit")
      {module, _ast} = compiled([author("news-p3xa6-submit", sample)], deep("contact", "news"))

      printed =
        ExUnit.CaptureIO.capture_io(fn ->
          ExUnit.CaptureLog.capture_log(fn ->
            assert {:noreply, socket} =
                     module.handle_event(
                       "news-p3xa6-submit",
                       %{"news" => %{"email" => "ada@example.com"}},
                       flashing()
                     )

            assert socket.assigns.flash["info"] == "Sent. Thank you."
          end)
        end)

      assert printed =~ "news-p3xa6-submit"
      assert printed =~ "ada@example.com"
    end
  end

  describe "form_handler_source/2, form_handler_sample/2 and untouched_handler?/3" do
    test "the sample prints the params under the event's name, then runs the source" do
      sample = LiveViewCompiler.form_handler_sample(:validate, "contact-k7m2q-validate")

      assert sample ==
               ~s|IO.inspect(params, label: "contact-k7m2q-validate")\n| <>
                 LiveViewCompiler.form_handler_source(:validate, "contact-k7m2q-validate")

      assert {:ok, _ast} = Code.string_to_quoted(sample)
    end

    test "both defaults, as written, are untouched" do
      for kind <- [:validate, :submit],
          code <- [
            LiveViewCompiler.form_handler_source(kind, "contact-k7m2q-#{kind}"),
            LiveViewCompiler.form_handler_sample(kind, "contact-k7m2q-#{kind}")
          ] do
        assert LiveViewCompiler.untouched_handler?(kind, code, "contact-k7m2q-#{kind}")

        assert LiveViewCompiler.untouched_handler?(
                 kind,
                 "  " <> code <> "\n\n",
                 "contact-k7m2q-#{kind}"
               )
      end
    end

    test "a default written before the form was renamed is still untouched" do
      code = LiveViewCompiler.form_handler_sample(:submit, "contact-k7m2q-submit")

      assert LiveViewCompiler.untouched_handler?(:submit, code, "enquiry-k7m2q-submit")
      refute LiveViewCompiler.untouched_handler?(:submit, code, "enquiry-p3xa6-submit")
    end

    test "an edited body is not" do
      code = LiveViewCompiler.form_handler_sample(:submit, "contact-k7m2q-submit")

      refute LiveViewCompiler.untouched_handler?(
               :submit,
               code <> "\n:sent",
               "contact-k7m2q-submit"
             )

      refute LiveViewCompiler.untouched_handler?(:validate, code, "contact-k7m2q-submit")
      refute LiveViewCompiler.untouched_handler?(:submit, nil, "contact-k7m2q-submit")
    end
  end

  describe "the catch-all" do
    test "still answers an event nobody declared" do
      {module, _ast} = compiled([])

      given = socket()

      assert {:noreply, ^given} =
               module.handle_event("nothing_declares_this", %{"a" => "b"}, given)
    end
  end

  # A layout is content somebody wrote, and `data-success` on a form node promises the visitor a
  # message. Measured across a stock install, not one layout rendered a flash region — so the promise
  # was kept nowhere and sending an enquiry answered with nothing at all. The page carries the region
  # itself now, and only when it has a form to need one. Both halves of it: a submission the author's
  # own handler refuses is announced under `:error`, and a region that reads only `:info` leaves the
  # visitor with a button press that did nothing.
  describe "the confirmation a page shows for its own forms" do
    defp rendered(module, flash) do
      module.render(%{__changed__: nil, flash: flash})
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()
    end

    test "carries the region when the page has a form" do
      {module, _ast} = compiled([])

      refute rendered(module, %{}) =~ ~s(id="page-form-info")
      assert rendered(module, %{"info" => "Sent."}) =~ ~s(id="page-form-info")
      assert rendered(module, %{"info" => "Sent."}) =~ "Sent."
      assert rendered(module, %{"info" => "Sent."}) =~ "bg-emerald-50"
    end

    test "and shows a refusal, which is the half no layout renders either" do
      {module, _ast} = compiled([])

      shown = rendered(module, %{"error" => "Could not send that."})

      assert shown =~ ~s(id="page-form-error")
      assert shown =~ "Could not send that."
      assert shown =~ ~s(role="alert")
      assert shown =~ "bg-rose-50"
      refute shown =~ "bg-emerald-50"
    end

    test "each under its own id, so two forms can have said one of each" do
      {module, _ast} = compiled([])

      shown = rendered(module, %{"info" => "Sent.", "error" => "Not sent."})

      assert shown =~ ~s(id="page-form-info")
      assert shown =~ ~s(id="page-form-error")
      assert shown =~ "Sent."
      assert shown =~ "Not sent."
    end

    test "and says nothing until there is something to say" do
      {module, _ast} = compiled([])

      refute rendered(module, %{}) =~ "page-form-"
    end

    # A page with no form compiles to exactly what it did before, region and all.
    test "a page with no form is left alone" do
      module = :"Elixir.PageFormNoFormsPage#{System.unique_integer([:positive])}"

      ast =
        LiveViewCompiler.build_module(%{
          title: "Plain",
          page_module: module,
          template: ~s(<section><p>Nothing to submit here.</p></section>),
          events: []
        })

      {:ok, ^module, _diagnostics} = ModuleCompiler.compile_module(ast)

      # EVERY PAGE CARRIES THE REGION NOW, because a message can come from a button in a component
      # and the page's own markup shows no sign of it — see `LiveViewCompiler.confirmable/3`. What a
      # page with nothing to say renders is still nothing; this one is given a flash on purpose.
      assert rendered(module, %{"info" => "Sent.", "error" => "Not sent."}) =~ "page-form-info"
      refute rendered(module, %{}) =~ "page-form-"
    end

    # `put_flash/3` KEEPS A MESSAGE FOR THE LIFE OF THE LIVEVIEW. With no way to clear it, "You are
    # on the list." stayed pinned over the contact form the visitor filled in next, for the rest of
    # the session — and only a full navigation away took it down. `lv:clear-flash` is LiveView's own
    # event, handled in `Phoenix.LiveView.Channel`, so the compiled page needs no handler for it.
    test "can be dismissed, so a success does not sit there for the rest of the session" do
      {module, _ast} = compiled([])

      shown = rendered(module, %{"info" => "Sent."})

      assert shown =~ ~s(phx-click="lv:clear-flash")
      assert shown =~ ~s(phx-value-key="info")
    end

    test "and the refusal carries its own key, so dismissing one leaves the other" do
      {module, _ast} = compiled([])

      assert rendered(module, %{"error" => "Not sent."}) =~ ~s(phx-value-key="error")
    end

    # PREPENDED TO THE DOCUMENT IT WAS A BLOCK AT THE VERY TOP OF THE PAGE. Subscribe to a newsletter
    # in the footer and the answer landed a screenful and a half above the form that asked, which
    # reads as the same nothing-happened this region exists to end.
    test "floats where the visitor is rather than at the top of the document" do
      {module, _ast} = compiled([])

      assert rendered(module, %{"info" => "Sent."}) =~ "fixed"
    end

    # ONE PLACEMENT, TWO MESSAGES. With `fixed inset-x-4 top-4` on each `<p>`, an accepted form and a
    # refused one on the same page rendered at identical coordinates — measured in the browser at
    # x 459, y 16, width 768 for both — so the success sat exactly on top of the refusal and the
    # visitor was told one thing and never shown the other.
    test "and the two stack rather than land on each other" do
      {module, _ast} = compiled([])

      shown = rendered(module, %{"info" => "Sent.", "error" => "Not sent."})

      assert shown =~ ~s(id="page-form-announcements")
      assert shown =~ ~s(id="page-form-info")
      assert shown =~ ~s(id="page-form-error")

      assert shown |> String.split("fixed") |> length() == 2,
             "the placement belongs to the region once, not to each message"
    end
  end

  # TAILWIND MATCHES CLASS-SHAPED TEXT IN THE `.template` FILE, and that file was written from the
  # STORED template while the region was prepended on the way into the compiler — so no rule was
  # generated for any of its utilities and the message rendered as bare unstyled body text.
  # `MishkaCmsCore.Runtime.Handlers.BootHandler.build_resource_class_content/1` writes what this
  # answers, which is the only way the scanner and the compiler can agree.
  describe "confirmable/2, the string the class scanner reads" do
    test "carries the region's own utilities for a page with a form" do
      scanned = LiveViewCompiler.confirmable(@template)

      for utility <- ~w(bg-emerald-50 text-emerald-800 bg-rose-50 max-w-3xl shadow-lg fixed) do
        assert scanned =~ utility, "#{utility} would get no rule in the site's stylesheet"
      end
    end

    test "and leaves a page with no form exactly as it was stored" do
      plain = ~s(<section><p>Nothing to submit here.</p></section>)

      assert LiveViewCompiler.confirmable(plain) =~ "page-form-announcements"
      assert LiveViewCompiler.confirmable(plain) =~ plain
    end

    test "takes the specs the compile already read rather than parsing the page again" do
      assert LiveViewCompiler.confirmable(@template, []) =~ "page-form-announcements",
             "every page carries the region now — see LiveViewCompiler.confirmable/3"

      assert LiveViewCompiler.confirmable(@template, [%{as: "contact"}]) =~ "page-form-"
    end
  end

  # "Send to another address": the form is checked by LiveView first, and only a valid submit sets
  # the trigger, which is what makes the browser post the form to its action.
  describe "a form that sends to another address" do
    @elsewhere """
    <section>
      <div class="card"><div class="grid"><div class="col">
        <.form :let={f} for={assigns[:contact_form]} as={:contact} id="contact-form" phx-change="contact-k7m2q-validate" phx-submit="contact-k7m2q-submit" action="https://pay.example.com/checkout" method="post" csrf_token={false} phx-trigger-action={assigns[:contact_send]}>
          <div class="card"><div class="grid"><div class="col">
            <input type="email" name={f[:email].name} value={f[:email].value} required data-format="email" />
          </div></div></div>
          <button type="submit">Pay</button>
        </.form>
      </div></div></div>
    </section>
    """

    defp page(socket, module) do
      socket.assigns
      |> Map.put(:__changed__, nil)
      |> module.render()
      |> Phoenix.LiveViewTest.rendered_to_string()
      |> LazyHTML.from_fragment()
    end

    defp flashed, do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

    test "names its trigger in the spec" do
      {module, _ast} = compiled([], @elsewhere)

      assert [%{trigger: :contact_send, as: "contact"}] = module.__page_forms__()
    end

    test "sets the trigger on a valid submit only, and keeps what was typed" do
      {module, _ast} = compiled([], @elsewhere)

      {:noreply, refused} =
        module.handle_event(
          "contact-k7m2q-submit",
          %{"contact" => %{"email" => "sara@"}},
          flashed()
        )

      assert refused.assigns[:contact_send] == nil

      {:noreply, sent} =
        module.handle_event(
          "contact-k7m2q-submit",
          %{"contact" => %{"email" => "sara@example.com"}},
          flashed()
        )

      assert sent.assigns.contact_send == true
      assert sent.assigns.contact_form.params["email"] == "sara@example.com"
      refute Phoenix.Flash.get(sent.assigns.flash, :info)
    end

    test "renders its address, post and no token, and the trigger only once it is set" do
      {module, _ast} = compiled([], @elsewhere)

      {:noreply, refused} =
        module.handle_event("contact-k7m2q-submit", %{"contact" => %{}}, flashed())

      {:noreply, sent} =
        module.handle_event(
          "contact-k7m2q-submit",
          %{"contact" => %{"email" => "sara@example.com"}},
          flashed()
        )

      before = page(refused, module)

      assert [_form] =
               LazyHTML.query(
                 before,
                 ~s(#contact-form[action="https://pay.example.com/checkout"][method="post"])
               )
               |> Enum.to_list()

      assert before
             |> LazyHTML.query(~s(#contact-form input[name="_csrf_token"]))
             |> Enum.to_list() == []

      assert before |> LazyHTML.query("#contact-form[phx-trigger-action]") |> Enum.to_list() == []

      assert [_triggered] =
               sent
               |> page(module)
               |> LazyHTML.query("#contact-form[phx-trigger-action]")
               |> Enum.to_list()
    end

    test "a trigger left behind with no address is never set, and the form is thanked and cleared" do
      stray = String.replace(@elsewhere, ~s( action="https://pay.example.com/checkout"), "")
      {module, _ast} = compiled([], stray)

      assert [%{trigger: nil, as: "contact"}] = module.__page_forms__()

      {:noreply, sent} =
        module.handle_event(
          "contact-k7m2q-submit",
          %{"contact" => %{"email" => "sara@example.com"}},
          %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
        )

      refute sent.assigns[:contact_send]
      assert sent.assigns.contact_form.params == %{}
      assert Phoenix.Flash.get(sent.assigns.flash, :info)
    end

    test "a form that does not send elsewhere is thanked and cleared as before" do
      {module, _ast} = compiled([])

      {:noreply, sent} =
        module.handle_event(
          "contact_submit",
          %{"contact" => %{"name" => "Ada", "email" => "ada@example.com"}},
          flashed()
        )

      assert [%{trigger: nil}] = module.__page_forms__()
      refute Map.has_key?(sent.assigns, :contact_send)
      assert sent.assigns.contact_form.params == %{}
    end
  end
end
