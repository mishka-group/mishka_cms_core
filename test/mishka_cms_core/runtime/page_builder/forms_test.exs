# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.FormsTest do
  @moduledoc """
  A form built in the editor, from the palette to the page's own `handle_event/3`.

  A runtime page IS a LiveView — the compiler already turns `page.events` into real `handle_event/3`
  clauses — so a form needs nothing invented: `Phoenix.Component.form/1` calls `to_form/2` on
  whatever `for` it is given and defaults that to `%{}`, which means no assign and no mount. A field
  binds with `field={f[:key]}` and the form derives the input's real name from it, so the params
  arrive at the page scoped under the form's own `as`.

  What was missing was the wiring, and one thing that made `<.form>` impossible to use at all.

  ## The import that was skipped

  `make_env/1` guarded every import with `:erlang.module_loaded/1`, which answers whether a module is
  in memory ALREADY. On a cold VM that is false for all of them — the BEAM loads on first use — so
  the import was silently skipped and `<.form>` raised "there is no such import". Whether a template
  rendered depended on whether some unrelated request had loaded `Phoenix.Component` first, which is
  a template that works in production and not in a fresh release, for no reason an author can see.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.Compilers.ModuleCompiler
  alias MishkaCmsCore.Runtime.PageBuilder.Blocks
  alias MishkaCmsCore.Runtime.PageBuilder.Elements
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms

  @moduletag :integration

  defp render(template), do: LiveViewCompiler.render_template(template, %{})

  defp rendered!(template) do
    case render(template) do
      html when is_binary(html) -> String.replace(html, ~r/<!--.*?-->/s, "")
      {:error, message} -> flunk("template did not render: #{message}")
    end
  end

  describe "the imports a runtime template renders with" do
    # THE ONE THAT MADE FORMS IMPOSSIBLE. Not a form test as such — every `Phoenix.Component`
    # function component was undefined for the same reason.
    test "Phoenix.Component is imported, so <.form> resolves" do
      html = rendered!(~s(<.form phx-submit="save"><input type="text" name="a" /></.form>))

      assert html =~ "<form"
      assert html =~ ~s(phx-submit="save")
    end

    test "and so does <.link>" do
      assert rendered!(~s(<.link navigate="/x">Go</.link>)) =~ "<a"
    end

    # `for` is optional: `form/1` turns `nil` into `%{}` and calls `to_form/2` itself, which is what
    # lets a page carry a form without a mount or an assign.
    test "a form with no `for` still renders" do
      assert rendered!(~s(<.form phx-submit="save"></.form>)) =~ "<form"
    end
  end

  describe "the form elements" do
    test "every one of them is in the Forms category" do
      forms = Enum.filter(Elements.all(), &(&1.category == "Forms"))

      ids = Enum.map(forms, & &1.id)

      assert "el-form" in ids
      assert "el-fieldset" in ids
      assert "el-input" in ids
      assert "el-textarea" in ids
      assert "el-select" in ids
      assert "el-label" in ids
      assert "el-checkbox" in ids
      assert "el-radio-group" in ids
      assert "el-submit" in ids
    end

    test "and every one of them renders" do
      for element <- Enum.filter(Elements.all(), &(&1.category == "Forms")) do
        assert is_binary(render(element.template)),
               "#{element.id} did not render"
      end
    end

    test "the form element carries a submit binding, or it is not a LiveView form" do
      assert Elements.get("el-form").template =~ "phx-submit"
    end
  end

  describe "the form blocks" do
    # THE FIELD KEYS ARE READ OFF THE TEMPLATE, not off the rendered output, and read by the parser
    # rather than matched as text: a field is bound with `field={f[:email]}`, so `name="email"` is
    # nowhere in the markup and the input's real name is derived by the form at render time.
    test "the contact form is a LiveView form with all three fields bound" do
      [spec] = PageForms.declared(Blocks.fetch("form-contact").template)

      assert spec.submit == "contact_submit"
      assert Enum.map(spec.fields, & &1.key) == [:name, :email, :message]
      assert Blocks.fetch("form-contact").template =~ "Send message"
    end

    test "and it renders — the form, its wrapper and its button, kit or no kit" do
      html = rendered!(Blocks.fetch("form-contact").template)

      assert html =~ "<form"
      assert html =~ ~s(phx-change="contact_validate")
      assert html =~ ~s(phx-submit="contact_submit")
      assert html =~ "Send message"
      assert html =~ "Get in touch"
    end

    # THE PARAM NAME IS WHAT KEEPS TWO FORMS APART. `as={:contact}` is what turns the bound key
    # `email` into `contact[email]` on the wire, so it is the difference between one page's forms
    # having separate state and all of them writing into the same params map.
    test "and every input it renders is scoped to its own form" do
      html = rendered!(Blocks.fetch("form-contact").template)

      assert html =~ ~s(name="contact[name]")
      assert html =~ ~s(name="contact[email]")
      assert html =~ ~s(name="contact[message]")
    end

    test "the fieldset group groups its fields under a legend" do
      template = Blocks.fetch("form-fieldset").template
      [spec] = PageForms.declared(template)

      assert template =~ "<fieldset"
      assert template =~ "Your details"
      assert Enum.map(spec.fields, & &1.key) == [:first_name, :last_name]
    end

    test "and it renders its fieldset and legend" do
      html = rendered!(Blocks.fetch("form-fieldset").template)

      assert html =~ "<fieldset"
      assert html =~ "Your details"
    end

    test "and they are offered under Forms" do
      ids = Blocks.all() |> Enum.filter(&(&1.category == "Forms")) |> Enum.map(& &1.id)

      assert "form-contact" in ids
      assert "form-fieldset" in ids
    end
  end

  describe "every form component the kit ships" do
    # A field that raises when it is dropped is a card that cannot be used. `PaletteEntry.template/2`
    # seeds the attributes a component declares as required — for these that is `name` and `value` —
    # and this is what says it really does. Skipped where the kit is not installed, because then
    # there is nothing to answer for.
    test "renders from the template the palette would drop" do
      case installed_form_components() do
        [] ->
          :no_kit_in_this_database

        components ->
          failures =
            for component <- components,
                template =
                  MishkaCmsCore.Builder.PaletteEntry.template(palette_entry(component), "Global"),
                match?({:error, _}, render(template)),
                do: component.name

          assert failures == [], "these form components do not render: #{inspect(failures)}"
      end
    end

    defp installed_form_components do
      require Ash.Query

      MishkaCmsCore.Runtime.Component
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(type == "forms")
      |> Ash.read(page: [limit: 100])
      |> case do
        {:ok, page} -> Map.get(page, :results, page)
        _unavailable -> []
      end
    end

    defp palette_entry(component) do
      %{
        name: component.name,
        template: component.template,
        attrs: component.attrs || [],
        slots: component.slots || [],
        helpers: [],
        global?: is_nil(component.site_id)
      }
    end
  end

  # THE SEEDER DECIDES WHETHER A DROPPED CARD RENDERS OR RAISES. An attribute with no default gets no
  # assign at all, so the component's own `@label` is a `KeyError` and the render dies — which is why
  # five of the kit's form components crashed on being dropped.
  describe "what the palette seeds into a dropped card" do
    alias MishkaCmsCore.Builder.PaletteEntry

    defp entry(attrs, template) do
      %{name: "probe", template: template, attrs: attrs, slots: [], helpers: []}
    end

    defp attr(name, type, opts), do: %{"name" => name, "type" => type, "opts" => opts}

    test "an attribute the template reads with no default is seeded, whatever it is called" do
      seeded =
        [attr("label", "string", %{"doc" => "the label"})]
        |> entry(~s(<div>{@label}</div>))
        |> PaletteEntry.seeded()

      assert seeded =~ ~s(label=)
    end

    # The rule used to be a list of two names, so this was the crash: `chelekom-date-time-field`
    # reads `@label`, declares no default for it, and was left unseeded.
    test "and one it never reads is left alone" do
      seeded =
        [attr("tooltip", "string", %{"doc" => "unused"})]
        |> entry(~s(<div>nothing</div>))
        |> PaletteEntry.seeded()

      refute seeded =~ "tooltip"
    end

    # A component that splats its assigns into children reads nothing itself, so the scan cannot see
    # what the delegate needs. An element rendering a form control needs the two every control has.
    test "a form control is given a name and a value even when it reads neither" do
      seeded =
        [attr("name", "any", %{}), attr("value", "any", %{})]
        |> entry(~s(<div><input type="text" /></div>))
        |> PaletteEntry.seeded()

      assert seeded =~ ~s(name=)
      assert seeded =~ ~s(value=)
    end

    test "and an element with no control is not" do
      seeded =
        [attr("name", "any", %{}), attr("value", "any", %{})]
        |> entry(~s(<div>just text</div>))
        |> PaletteEntry.seeded()

      refute seeded =~ ~s(name=)
    end

    # `to_form/2` has no `FormData` implementation for a string, so the one attribute that cannot be
    # seeded as text is a form's own data structure.
    test "a form's `for` is seeded as an empty map, not a string" do
      required =
        [attr("for", "any", %{"required" => true})]
        |> entry(~s(<div>delegates through a splat</div>))
        |> PaletteEntry.seeded()

      wrapping =
        [attr("for", "any", %{})]
        |> entry(~s(<.form for={@for}></.form>))
        |> PaletteEntry.seeded()

      assert required =~ "for={%{}}"
      assert wrapping =~ "for={%{}}"
    end

    # And `for` on a label is an element id: a map there is simply a different crash.
    test "but a label's `for` stays a string" do
      seeded =
        [attr("for", "string", %{})]
        |> entry(~s(<label for={@for}>text</label>))
        |> PaletteEntry.seeded()

      assert seeded =~ ~s(for=")
      refute seeded =~ "for={%{}}"
    end
  end

  describe "a submitted form reaching the page's own handler" do
    # THE WHOLE POINT. A page is a LiveView and `page.events` becomes `handle_event/3`, so this walks
    # the real path: compile a page whose template is the form block and whose event is the handler,
    # then hand it the params a submit would send.
    test "the handler receives every field by name" do
      module = :"Elixir.FormsTestPage#{System.unique_integer([:positive])}"

      handler = """
      {:noreply, Phoenix.Component.assign(socket, :submitted, params)}
      """

      ast =
        LiveViewCompiler.build_module(%{
          title: "Contact",
          page_module: module,
          template: Blocks.fetch("form-contact").template,
          events: [%{name: "contact_submit", code: handler, signature: nil}]
        })

      {:ok, ^module, _warnings} = ModuleCompiler.compile_module(ast)
      assert function_exported?(module, :handle_event, 3)

      params = %{"name" => "Ada", "email" => "ada@example.com", "message" => "Hello"}

      {:noreply, socket} =
        module.handle_event("contact_submit", params, %Phoenix.LiveView.Socket{
          assigns: %{__changed__: %{}}
        })

      assert socket.assigns.submitted == params
    end

    # An event nobody named — neither the author on the Events tab nor a form in the markup — is
    # answered by the compiler's catch-all rather than crashing the page a visitor is on. The form's
    # own two names are NOT in that group: the compiler generates a clause for each of them, which is
    # what makes a dropped form work with no Elixir written anywhere.
    test "and an event nothing on the page names changes nothing" do
      module = :"Elixir.FormsTestPage#{System.unique_integer([:positive])}"

      ast =
        LiveViewCompiler.build_module(%{
          title: "Contact",
          page_module: module,
          template: Blocks.fetch("form-contact").template,
          events: []
        })

      {:ok, ^module, _warnings} = ModuleCompiler.compile_module(ast)

      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

      assert {:noreply, ^socket} =
               module.handle_event("nothing_names_this", %{"a" => "b"}, socket)
    end
  end
end
