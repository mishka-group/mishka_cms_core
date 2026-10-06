defmodule MishkaCmsCore.Runtime.PageFormTest do
  @moduledoc """
  What a visitor experiences on a published page's form, driven through the same two entry points
  the compiler generates handlers for.

  Three things here are worth more than the rest. The first is that a form nobody has typed in shows
  no errors: "can't be blank" under every field the moment the page loads is the single most common
  way a generated form looks broken, and the only thing standing between that and a clean page is
  the `_unused_<field>` markers surviving all the way into `Phoenix.Component.used_input?/1`.

  The second is that two forms on one page do not touch each other. They share a socket, a params
  map and an event name space, and the only thing keeping them apart is that each reads its own
  scope out of the params before anything else happens.

  The third is that a submission survives whatever the plugin receiving it does. A plugin that
  raises belongs to somebody else, and the visitor pressing Send must not be shown a 500 because of
  it.
  """
  use MishkaCmsCore.DataCase, async: false

  import ExUnit.CaptureLog

  alias MishkaCmsCore.Builder.Events
  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.PageBuilder.Inspector
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.FormChecks
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageForm

  alias MishkaCmsCore.Test.Plugins.{PageFormBrokenDestination, PageFormDestination}

  alias MishkaInstaller.Event.{Event, EventHandler}

  @contact %{
    assign: :contact_form,
    as: "contact",
    id: "contact-form",
    change: "contact_validate",
    submit: "contact_submit",
    success: "Thanks, we will be in touch.",
    fields: [
      %{key: :name, type: :string, rules: [:required, {:min_length, 2}]},
      %{key: :email, type: :string, rules: [:required, {:format, :email}]}
    ]
  }

  @newsletter %{
    assign: :newsletter_form,
    as: "newsletter",
    id: "newsletter-form",
    change: "newsletter_validate",
    submit: "newsletter_submit",
    success: "You are on the list.",
    fields: [%{key: :email, type: :string, rules: [:required, {:format, :email}]}]
  }

  @specs [@contact, @newsletter]

  defp register(module) do
    {:ok, _} =
      Event.write(%{
        name: module,
        event: "page:form:submitted",
        extension: :mishka_installer,
        status: :started
      })

    :ok = EventHandler.do_compile("page:form:submitted", :start, false)
    on_exit(fn -> Event.unregister(:name, module, false) end)
    :ok
  end

  defp socket(specs \\ @specs) do
    Enum.reduce(
      specs,
      %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}},
      &Phoenix.Component.assign(&2, &1.assign, PageForm.seed(&1))
    )
  end

  defp form(socket, assign), do: socket.assigns[assign]

  defp flash(socket, kind), do: socket.assigns.flash[to_string(kind)]

  describe "seed/1" do
    test "names the form after the spec so its inputs post under their own scope" do
      seeded = PageForm.seed(@contact)

      assert seeded.name == "contact"
      assert seeded.id == "contact-form"
    end

    test "carries no errors, because nothing has been typed" do
      seeded = PageForm.seed(@contact)

      assert seeded.errors == []
      assert seeded[:email].errors == []
    end
  end

  describe "validate/4" do
    test "puts a form carrying the visitor's errors on the socket" do
      updated =
        PageForm.validate(socket(), @specs, :contact_form, %{
          "contact" => %{"name" => "S", "email" => "nope"}
        })

      contact = form(updated, :contact_form)

      assert contact[:email].errors != []
      assert contact[:name].errors != []
    end

    test "keeps what the visitor typed, so the field does not empty itself under them" do
      updated =
        PageForm.validate(socket(), @specs, :contact_form, %{
          "contact" => %{"name" => "Shahryar", "email" => "nope"}
        })

      assert form(updated, :contact_form)[:email].value == "nope"
    end

    test "reads its own scope, so a sibling's params are not its values" do
      updated =
        PageForm.validate(socket(), @specs, :contact_form, %{
          "contact" => %{"name" => "Shahryar"},
          "newsletter" => %{"email" => "someone@example.com"}
        })

      assert form(updated, :contact_form)[:email].value == nil
    end

    test "an unknown assign says which one, rather than validating the wrong form" do
      assert_raise ArgumentError, ~r/:nothing_form/, fn ->
        PageForm.validate(socket(), @specs, :nothing_form, %{})
      end
    end
  end

  describe "a form named by its event" do
    @tagged [
      %{@contact | change: "contact-k7m2q-validate", submit: "contact-k7m2q-submit"},
      %{@newsletter | change: "newsletter-p3xa6-validate", submit: "newsletter-p3xa6-submit"}
    ]

    test "finds the form carrying that exact event, either kind" do
      params = %{"newsletter" => %{"email" => "nope"}}

      for event <- ["newsletter-p3xa6-validate", "newsletter-p3xa6-submit"] do
        updated = PageForm.validate(socket(@tagged), @tagged, event, params)

        assert form(updated, :newsletter_form)[:email].errors != []
        assert form(updated, :contact_form)[:email].errors == []
      end
    end

    test "and a legacy untagged event too" do
      updated =
        PageForm.validate(socket(), @specs, "contact_validate", %{"contact" => %{"name" => "S"}})

      assert form(updated, :contact_form)[:name].errors != []
    end

    test "falls back to the form carrying its token, as a handler written before a rename does" do
      assert {:noreply, updated} =
               PageForm.submit(socket(@tagged), @tagged, "contact-k7m2q-submit", %{
                 "contact" => %{"name" => "S"}
               })

      renamed = [
        %{hd(@tagged) | change: "enquiry-k7m2q-validate", submit: "enquiry-k7m2q-submit"}
      ]

      assert {:noreply, after_rename} =
               PageForm.submit(socket(renamed), renamed, "contact-k7m2q-submit", %{
                 "contact" => %{"name" => "S"}
               })

      assert form(after_rename, :contact_form).errors == form(updated, :contact_form).errors
      assert form(after_rename, :contact_form).action == :submit
    end

    test "an event no form answers raises and names it" do
      assert_raise ArgumentError, ~r/"gone-zzzzz-submit"/, fn ->
        PageForm.submit(socket(@tagged), @tagged, "gone-zzzzz-submit", %{})
      end

      assert_raise ArgumentError, ~r/"contact_submit"/, fn ->
        PageForm.validate(socket(@tagged), @tagged, "contact_submit", %{})
      end
    end
  end

  describe "errors the visitor has not earned yet" do
    setup do
      updated =
        PageForm.validate(socket(), @specs, :contact_form, %{
          "contact" => %{"name" => "Shahryar", "email" => "", "_unused_email" => ""}
        })

      %{contact: form(updated, :contact_form)}
    end

    test "are on the field, because submit has to be able to show them all at once", %{
      contact: contact
    } do
      assert contact[:email].errors != []
    end

    test "and are hidden while the field is untouched", %{contact: contact} do
      assert PageForm.form_errors(contact[:email]) == []
    end

    test "while a field they have used shows its own", %{contact: contact} do
      assert PageForm.form_errors(contact[:name]) == []

      touched =
        PageForm.validate(socket(), @specs, :contact_form, %{
          "contact" => %{"name" => "S", "email" => "", "_unused_email" => ""}
        })

      assert PageForm.form_errors(form(touched, :contact_form)[:name]) != []
    end

    test "and anything that is not a form field has none" do
      assert PageForm.form_errors(nil) == []
      assert PageForm.form_errors("email") == []
    end
  end

  describe "two forms on one socket" do
    test "validating one leaves the other exactly as it was" do
      before = socket()

      updated =
        PageForm.validate(before, @specs, :contact_form, %{
          "contact" => %{"email" => "nope"},
          "newsletter" => %{"email" => "also-nope"}
        })

      assert form(updated, :newsletter_form) == form(before, :newsletter_form)
      assert form(updated, :newsletter_form)[:email].errors == []
    end

    test "and one form's unused markers never reach the other" do
      updated =
        PageForm.validate(socket(), @specs, :newsletter_form, %{
          "contact" => %{"email" => "", "_unused_email" => ""},
          "newsletter" => %{"email" => ""}
        })

      assert PageForm.form_errors(form(updated, :newsletter_form)[:email]) != []
    end

    test "submitting one resets only its own" do
      typed =
        PageForm.validate(socket(), @specs, :newsletter_form, %{
          "newsletter" => %{"email" => "nope"}
        })

      {:noreply, updated} =
        PageForm.submit(typed, @specs, :contact_form, %{
          "contact" => %{"name" => "Shahryar", "email" => "a@b.co"}
        })

      assert form(updated, :newsletter_form)[:email].value == "nope"
      assert form(updated, :contact_form)[:email].value == nil
    end
  end

  describe "submit/4 with values the rules refuse" do
    setup do
      {:noreply, updated} =
        PageForm.submit(socket(), @specs, :contact_form, %{
          "contact" => %{"name" => "", "email" => "nope"}
        })

      %{updated: updated}
    end

    test "re-renders the form with every error at once", %{updated: updated} do
      contact = form(updated, :contact_form)

      assert PageForm.form_errors(contact[:name]) != []
      assert PageForm.form_errors(contact[:email]) != []
    end

    test "keeps what was typed", %{updated: updated} do
      assert form(updated, :contact_form)[:email].value == "nope"
    end

    test "and says nothing was sent", %{updated: updated} do
      assert updated.assigns.flash == %{}
    end
  end

  describe "submit/4 with nothing registered to receive it" do
    test "still tells the visitor it went, and logs the form and its field names only" do
      logged =
        capture_log(fn ->
          {:noreply, updated} =
            PageForm.submit(socket(), @specs, "contact_submit", %{
              "contact" => %{"name" => "Shahryar", "email" => "a@b.co"}
            })

          send(self(), {:updated, updated})
        end)

      assert_received {:updated, updated}
      assert flash(updated, :info) == @contact.success
      assert logged =~ "page form contact was sent, and nothing receives it"
      assert logged =~ "fields: name, email"
      refute logged =~ "a@b.co"
      refute logged =~ "Shahryar"
    end

    test "and the audit rail is told there is no destination" do
      refute PageForm.destination?()
    end
  end

  describe "submit/4 with a plugin receiving it" do
    setup do: register(PageFormDestination)

    test "hands the seam the cast values, keyed by the fields the form declares" do
      {:noreply, _updated} =
        PageForm.submit(socket(), @specs, :contact_form, %{
          "contact" => %{"name" => "Shahryar", "email" => "a@b.co", "spoofed" => "x"}
        })

      assert_received {:page_form_submitted, payload}
      assert payload.form == "contact"
      assert payload.values == %{name: "Shahryar", email: "a@b.co"}
    end

    test "flashes the spec's own success message" do
      {:noreply, updated} =
        PageForm.submit(socket(), @specs, :contact_form, %{
          "contact" => %{"name" => "Shahryar", "email" => "a@b.co"}
        })

      assert flash(updated, :info) == @contact.success
      refute flash(updated, :error)
    end

    test "resets the form, so the next visitor to that page starts clean" do
      {:noreply, updated} =
        PageForm.submit(socket(), @specs, :contact_form, %{
          "contact" => %{"name" => "Shahryar", "email" => "a@b.co"}
        })

      contact = form(updated, :contact_form)

      assert contact[:email].value == nil
      assert contact.errors == []
    end

    test "and the audit rail is told there is one" do
      assert PageForm.destination?()
      assert Events.form_destination?()
    end
  end

  # The core form and Chelekom's Form Wrapper, each with its field and Send button in a column of a
  # grid in a card, on one page. Code that answers a form's submit decides what receives it, so the
  # editor names the code before the plugin.
  describe "what the editor says receives a form, with a plugin installed" do
    setup do: register(PageFormDestination)

    @deep_page ~s(<div><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact-k7m2q-validate" phx-submit="contact-k7m2q-submit"><div class="card"><div class="grid"><div class="col"><input name={f[:email].name} /></div><div class="col"><button type="submit">Send</button></div></div></div></.form>) <>
                 ~s(<.component component_name="chelekom-form-wrapper" site="Global" :let={w} id="news-form" as={:news} for={assigns[:news_form]} phx-change="news-p3xa6-validate" phx-submit="news-p3xa6-submit"><div class="card"><div class="grid"><div class="col"><input name={w[:email].name} /></div><div class="col"><button type="submit">Join</button></div></div></div></.component></div>)

    defp deep_forms do
      {:ok, tree} = Tree.parse(@deep_page)
      tree |> Tree.walk() |> Enum.filter(&PageForms.form?/1)
    end

    defp stores(event),
      do: %{
        name: event,
        code:
          ~s|MishkaCmsCore.Runtime.PageForm.submit(socket, __page_forms__(), "#{event}", params, &MyApp.store/1)|
      }

    test "a form whose own code takes the answers is received by that code" do
      [contact, news] = deep_forms()
      record = %{events: [stores("contact-k7m2q-submit"), stores("news-p3xa6-submit")]}

      for form <- [contact, news] do
        assert FormChecks.receiver(form, record) == :code

        assert elem(Inspector.form_story(form, record), 1) ==
                 "When they press Send: your own code receives it."
      end
    end

    test "a form with no code, or only the default nobody edited, is received by the plugin" do
      [contact, news] = deep_forms()

      sample = %{
        name: "news-p3xa6-submit",
        code: LiveViewCompiler.form_handler_sample(:submit, "news-p3xa6-submit")
      }

      for {form, record} <- [{contact, %{events: []}}, {news, %{events: [sample]}}] do
        assert FormChecks.receiver(form, record) == :plugin

        assert elem(Inspector.form_story(form, record), 1) ==
                 "When they press Send: an installed plugin receives it."
      end
    end
  end

  describe "submit/4 with a plugin that raises" do
    setup do: register(PageFormBrokenDestination)

    test "does not take the page down with it" do
      logged =
        capture_log(fn ->
          {:noreply, updated} =
            PageForm.submit(socket(), @specs, :contact_form, %{
              "contact" => %{"name" => "Shahryar", "email" => "a@b.co"}
            })

          send(self(), {:updated, updated})
        end)

      assert_received {:updated, updated}
      assert flash(updated, :info) == @contact.success
      assert logged =~ "this plugin is broken"
    end

    test "and the page keeps working afterwards" do
      capture_log(fn ->
        {:noreply, _first} =
          PageForm.submit(socket(), @specs, :contact_form, %{
            "contact" => %{"name" => "Shahryar", "email" => "a@b.co"}
          })
      end)

      updated =
        PageForm.validate(socket(), @specs, :contact_form, %{"contact" => %{"email" => "nope"}})

      assert PageForm.form_errors(form(updated, :contact_form)[:email]) != []
    end
  end

  describe "submit/5, where the author stores the submission" do
    test "hands the function the cast values and accepts what it returns" do
      {:noreply, updated} =
        PageForm.submit(
          socket(),
          @specs,
          :contact_form,
          %{"contact" => %{"name" => "Shahryar", "email" => "a@b.co"}},
          fn values ->
            send(self(), {:stored, values})
            {:ok, :written}
          end
        )

      assert_received {:stored, %{name: "Shahryar", email: "a@b.co"}}
      assert flash(updated, :info) == @contact.success
    end

    test "a function returning nil is still a success, rather than a 500 on the next line" do
      {:noreply, updated} =
        PageForm.submit(
          socket(),
          @specs,
          :contact_form,
          %{"contact" => %{"name" => "Shahryar", "email" => "a@b.co"}},
          fn _values -> nil end
        )

      assert flash(updated, :info) == @contact.success
      assert form(updated, :contact_form)[:email].value == nil
    end

    test "an {:error, _} return re-renders instead of flashing success" do
      {:noreply, updated} =
        PageForm.submit(
          socket(),
          @specs,
          :contact_form,
          %{"contact" => %{"name" => "Shahryar", "email" => "a@b.co"}},
          fn _values -> {:error, :database_is_on_fire} end
        )

      refute flash(updated, :info)
      assert flash(updated, :error)
      assert form(updated, :contact_form)[:email].value == "a@b.co"
    end

    test "a sentence the author returns is the one the visitor reads" do
      {:noreply, updated} =
        PageForm.submit(
          socket(),
          @specs,
          :contact_form,
          %{"contact" => %{"name" => "Shahryar", "email" => "a@b.co"}},
          fn _values -> {:error, "We already have that address on the list."} end
        )

      assert flash(updated, :error) == "We already have that address on the list."
    end

    test "a reason only a programmer can read is logged, not shown" do
      logged =
        capture_log(fn ->
          {:noreply, updated} =
            PageForm.submit(
              socket(),
              @specs,
              :contact_form,
              %{"contact" => %{"name" => "Shahryar", "email" => "a@b.co"}},
              fn _values -> {:error, :database_is_on_fire} end
            )

          send(self(), {:updated, updated})
        end)

      assert_received {:updated, updated}
      assert flash(updated, :error) == "Could not send that."
      assert logged =~ "database_is_on_fire"
    end

    test "and it is never called for values the rules already refused" do
      {:noreply, updated} =
        PageForm.submit(
          socket(),
          @specs,
          :contact_form,
          %{"contact" => %{"name" => "", "email" => "nope"}},
          fn values -> send(self(), {:stored, values}) end
        )

      refute_received {:stored, _values}
      assert updated.assigns.flash == %{}
    end
  end

  describe "announcements/1, which is what the page's own region renders" do
    test "says nothing until something has been said" do
      assert PageForm.announcements(%{}) == []
    end

    test "carries the success a submission flashed" do
      {:noreply, updated} =
        PageForm.submit(
          socket(),
          @specs,
          :contact_form,
          %{"contact" => %{"name" => "Shahryar", "email" => "a@b.co"}},
          fn _values -> :ok end
        )

      assert PageForm.announcements(updated.assigns.flash) == [{:info, @contact.success}]
    end

    test "and the refusal, which is the half the region had no way to show" do
      {:noreply, updated} =
        PageForm.submit(
          socket(),
          @specs,
          :contact_form,
          %{"contact" => %{"name" => "Shahryar", "email" => "a@b.co"}},
          fn _values -> {:error, "Nothing was sent."} end
        )

      assert PageForm.announcements(updated.assigns.flash) == [{:error, "Nothing was sent."}]
    end

    test "two forms on one page can have said one of each" do
      assert PageForm.announcements(%{"info" => "Sent.", "error" => "Not sent."}) ==
               [{:info, "Sent."}, {:error, "Not sent."}]
    end
  end
end
