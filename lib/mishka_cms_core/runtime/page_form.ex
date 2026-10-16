# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageForm do
  @moduledoc """
  What a compiled page does when a visitor types in, or submits, a form its author drew.

  ## Using it

  A page carries one spec per form in `__page_forms__/0`, and the compiler generates one pair of
  handlers per form, both of which come straight back here:

      def handle_event("contact-k7m2q-validate", params, socket) do
        {:noreply, PageForm.validate(socket, __page_forms__(), "contact-k7m2q-validate", params)}
      end

      def handle_event("contact-k7m2q-submit", params, socket) do
        PageForm.submit(socket, __page_forms__(), "contact-k7m2q-submit", params)
      end

  The form is named by an event name (`"contact-k7m2q-submit"`) or by its page assign
  (`:contact_form`, what pages compiled before tokens pass). An event name finds the form carrying it,
  and failing that the form carrying its token, so a handler written before its form was renamed
  still finds it.

  Nothing seeds the assign, and there is no `mount/3`: `Phoenix.Component.form/1` coerces a missing
  `for=` to `%{}`, so the first render of a page nobody has typed in draws an empty form on its own.
  A reader debugging first-paint behaviour used to be sent here to a `mount/3` that
  `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler` does not generate and a `seed/1` call that does
  not exist. `seed/1` is real, but it is what a SUCCESSFUL submission resets the form to.

  An author who holds `admin:dashboard:code` may write the submit handler by hand and pass a function as
  the fifth argument. It receives the cast values, keyed by the fields the form declares, and its
  return decides what the visitor sees: `{:error, _}` re-renders the form with everything still
  typed in it, anything else is a success, which resets the form and flashes.

      PageForm.submit(socket, __page_forms__(), "contact-k7m2q-submit", params, fn values ->
        MishkaBlog.Comment
        |> Ash.Changeset.for_create(:create, values)
        |> Ash.create()
      end)

  A refusal may say why. `{:error, "We already have that address."}` is text somebody wrote for a
  visitor and is shown as it stands; `{:error, %Ash.Error.Invalid{}}` or `{:error, :db_down}` is a
  programmer's reason, which would put the shape of the system on a public page, so it is written to
  the log and the visitor reads the plain refusal.

  ## What the page says back

  Both outcomes are announced with `put_flash/3`, and `announcements/1` is how they are read back
  out. A compiled page carrying a form renders its own region from it (see
  `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler`) because a layout's flash region is content
  somebody wrote and, measured across a stock install, no layout had one. Both writers and the one
  reader live here, so a region cannot go on knowing about the success and not the refusal — which
  is what left a refused submission looking like a button press that did nothing.

  ## The rules are Ecto's, the declaration is the author's

  A form's rules arrive as the constraint attributes on its field nodes, lifted at compile time into
  `__page_forms__/0` and run through a schemaless `Ecto.Changeset` by
  `MishkaCmsCore.Runtime.PageForm.Rules`. That buys three things a hand-rolled checker does not:
  errors already shaped `{message, opts}`, which is the only shape a `translate_error/1` matches, in
  this project's `MishkaCmsWeb.CoreComponents` and in a kit's own field alike; `opts[:count]` and
  `opts[:number]` where Gettext's plural rules can read them; and coercion, so a combobox that posts
  a list or a date field that posts a nested map produces an error rather than an exception in the
  middle of a keystroke.

  The form itself is built over the changeset's params and its errors rather than over the changeset,
  because `Phoenix.HTML.FormData` gains a clause for `Ecto.Changeset` from `phoenix_ecto`, which this
  library does not depend on and must not start requiring of a host. The two forms are the same form:
  the params are the ones Ecto converted, so the `_unused_<field>` markers are all still there for
  `Phoenix.Component.used_input?/1`, the values are the ones the visitor typed, and the errors are
  Ecto's own tuples. `action` decides whether they are visible at all — `nil` on a form nobody has
  typed in, so a page that has just loaded carries no errors to show.

  ## Why the params are scoped first

  The form's tag carries `as={:contact}`, so its inputs are named `contact[email]` and the event
  arrives as `%{"contact" => %{...}, "_target" => [...]}`. Everything here reads `params["contact"]`,
  which is what makes two forms on one page independent for free: the `_unused_<field>` markers the
  client sends are nested too, so `Phoenix.Component.used_input?/1` reads one form's own map and can
  never see a sibling's keys.

  Handing `to_form/2` the OUTER map instead is silent and total: `value` reads `nil` on every field
  so the visitor cannot type, `used_input?` is false forever so no error is ever shown, and
  `required` fails on a filled field so submit never succeeds.

  ## Why nothing here renders an error

  The field does. A kit's field opens with
  `errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []` and puts the rest
  through its own `translate_error/1`, so a form nobody has touched shows nothing and a submitted one
  shows everything at once. `form_errors/1` exists only for markup that carries `errors=` explicitly
  because its kit takes no `Phoenix.HTML.FormField`.

  ## Where a submission goes

  Nowhere in core. A valid submission is handed to `MishkaCmsCore.Builder.Events.form_submitted/1`,
  the `page:form:submitted` seam. A plugin that stores or forwards submissions registers on that
  event; none ships with the CMS. A developer can also pass the fifth argument from the form's
  On submit handler. With neither, the visitor still sees the success message, the log gets the
  form's name and field names but never the values typed, and the editor shows a
  `form-no-destination` note, which is what `destination?/0` answers for plugins.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  require Logger

  alias MishkaCmsCore.Builder.Events
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.Naming
  alias MishkaCmsCore.Runtime.PageForm.Rules
  alias MishkaCmsCore.Runtime.PageUpload

  @kinds [:info, :error]

  @doc """
  A pristine form for one spec — what an accepted submission leaves behind. Carries no errors,
  because nothing has been typed into it.
  """
  @spec seed(map()) :: Phoenix.HTML.Form.t()
  def seed(spec), do: build(spec, %{}, nil)

  @doc """
  Re-assigns one form from what the visitor has typed so far.

  Only the named form's assign is written, so a page with several forms keeps the others exactly as
  they were.
  """
  @spec validate(Phoenix.LiveView.Socket.t(), [map()], atom() | String.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def validate(socket, specs, form, params) do
    spec = fetch!(specs, form)

    Phoenix.Component.assign(socket, spec.assign, build(spec, scoped(spec, params), :validate))
  end

  @doc """
  Handles one form's submit: validates, then either re-renders it or accepts it.

  Rejected values stay in the form so the visitor does not retype them. Accepted values reset the
  form and flash the spec's success message, except on a form that sends to another address (its
  spec names a `trigger` assign): there the values stay and the trigger is set to `true`, so the
  form's `phx-trigger-action` posts them to its `action`.
  """
  @spec submit(
          Phoenix.LiveView.Socket.t(),
          [map()],
          atom() | String.t(),
          map(),
          (map() -> term()) | nil
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def submit(socket, specs, form, params, run \\ nil) do
    spec = fetch!(specs, form)

    # BEFORE THE RULES RUN, so a form can require the file the visitor attached and an author's own
    # `run` function receives its descriptors beside everything else they typed. Answers the socket
    # and the params unchanged on every page that declares no uploads, which is most of them.
    {socket, values} = PageUpload.consume(socket, scoped(spec, params))

    changeset = Rules.changeset(spec, values)

    finish(changeset.valid?, socket, spec, drawn(changeset, spec, :submit), values, run)
  end

  @doc """
  A field's errors, or none while the visitor has not touched it.

  For markup that passes `errors=` rather than a form field — a kit that binds fields some other
  way, or a hand-written `<input>`. Imported into every compiled page.
  """
  @spec form_errors(Phoenix.HTML.FormField.t() | term()) :: list()
  def form_errors(%Phoenix.HTML.FormField{} = field), do: touched(field, field.errors)
  def form_errors(_other), do: []

  @doc """
  One form, built from one params map.

  `action` is what decides whether errors are visible at all: `nil` is a form nobody has typed in,
  `:validate` a keystroke, `:submit` a press of the button.
  """
  @spec build(map(), map(), atom() | nil) :: Phoenix.HTML.Form.t()
  def build(spec, values, action), do: spec |> Rules.changeset(values) |> drawn(spec, action)

  @doc "Whether anything is registered to receive submissions — read by the audit rail."
  @spec destination?() :: boolean()
  def destination?, do: Events.form_destination?()

  @doc """
  What a page has to say about the forms on it: `[{kind, message}]`, in `:info`, `:error` order.

  `[]` while nothing has been submitted, one entry after a submission, and two where a page carries
  several forms and one was accepted while another was refused. Read by the region a compiled page
  renders for itself, which is the only reader that has to agree with both `put_flash/3` calls here.
  """
  @spec announcements(map()) :: [{:info | :error, String.t()}]
  def announcements(flash),
    do: Enum.flat_map(@kinds, &announcement(&1, Phoenix.Flash.get(flash, &1)))

  defp announcement(_kind, nil), do: []
  defp announcement(kind, message), do: [{kind, message}]

  defp drawn(changeset, spec, action) do
    Phoenix.Component.to_form(changeset.params,
      as: spec.as,
      id: spec.id,
      action: action,
      errors: reportable(changeset.errors, action)
    )
  end

  defp reportable(_errors, nil), do: []
  defp reportable(errors, _action), do: errors

  defp touched(field, errors) do
    case Phoenix.Component.used_input?(field) do
      true -> errors
      false -> []
    end
  end

  defp finish(false, socket, spec, form, _values, _run),
    do: {:noreply, Phoenix.Component.assign(socket, spec.assign, form)}

  defp finish(true, socket, spec, form, values, run) do
    spec
    |> Rules.apply_changes(values)
    |> accept(run, spec, socket)
    |> settled(socket, spec, form)
  end

  defp settled(:ok, socket, spec, form),
    do: {:noreply, sent(Map.get(spec, :trigger), socket, spec, form)}

  defp settled({:error, message}, socket, spec, form),
    do: {:noreply, refused(socket, spec, form, message)}

  defp sent(nil, socket, spec, _form), do: cleared(socket, spec)

  # A form that sends to another address keeps what was typed, and its trigger set to true makes the
  # browser post it to the form's `action` on the next render.
  defp sent(trigger, socket, spec, form) do
    socket
    |> Phoenix.Component.assign(spec.assign, form)
    |> Phoenix.Component.assign(trigger, true)
  end

  defp cleared(socket, spec) do
    socket
    |> Phoenix.Component.assign(spec.assign, seed(spec))
    |> Phoenix.LiveView.put_flash(:info, Gettext.gettext(MishkaCmsCore.Gettext, spec.success))
  end

  defp refused(socket, spec, form, message) do
    socket
    |> Phoenix.Component.assign(spec.assign, form)
    |> Phoenix.LiveView.put_flash(:error, message)
  end

  defp accept(clean, nil, spec, socket),
    do: spec |> payload(clean, socket) |> deliver(spec, clean)

  # AN AUTHOR'S FUNCTION MAY RETURN ANYTHING, INCLUDING `nil`. Threading the socket through its
  # return value would hand `assign/3` a boolean on the next line, which is a 500 on the visitor's
  # submit from a page that behaved perfectly in the editor. So the return is read for a refusal and
  # otherwise discarded.
  defp accept(clean, run, _spec, _socket) when is_function(run, 1), do: refusal(run.(clean))

  # A refusal the author wrote as a sentence is shown to the visitor as written. Any other refusal
  # shows the generic message, and its reason goes only to the log.
  defp refusal({:error, message}) when is_binary(message), do: {:error, message}

  defp refusal({:error, reason}) do
    Logger.warning("page form submission refused: #{inspect(reason)}")
    {:error, gettext("Could not send that.")}
  end

  defp refusal(_accepted), do: :ok

  defp deliver(payload, spec, clean),
    do: payload |> Events.form_submitted() |> received(spec, clean)

  defp received(:handled, _spec, _clean), do: :ok

  # A form that sends to another address is received there.
  defp received(:unhandled, %{trigger: trigger}, _clean) when not is_nil(trigger), do: :ok

  # Nothing received it: the visitor is still thanked, and the log names the form and its fields,
  # never the values typed.
  defp received(:unhandled, spec, _clean) do
    Logger.warning(
      "page form #{spec.as} was sent, and nothing receives it; fields: #{field_names(spec)}"
    )

    :ok
  end

  defp field_names(spec), do: Enum.map_join(spec.fields, ", ", &to_string(&1.key))

  defp payload(spec, clean, socket) do
    private = page_private(socket.view)

    %{
      form: spec.as,
      values: clean,
      page: private[:id],
      site_id: private[:site_id],
      handled: false
    }
  end

  # A form can be exercised from something that is not a compiled page — a test, a preview, a
  # hand-written LiveView — and a submission from one of those must still reach the seam rather than
  # end in an UndefinedFunctionError.
  defp page_private(view) do
    case MishkaGervaz.Helpers.exports?(view, :__page_information__, 1) do
      true -> view.__page_information__([:private]) || %{}
      false -> %{}
    end
  end

  defp scoped(%{as: as}, params) do
    case Map.get(params, as) do
      inner when is_map(inner) -> inner
      _absent -> %{}
    end
  end

  defp fetch!(specs, event) when is_binary(event) do
    Enum.find(specs, &(event in [&1.change, &1.submit])) ||
      Enum.find(
        specs,
        &(Naming.same_form?(&1.change, event) or Naming.same_form?(&1.submit, event))
      ) ||
      raise ArgumentError, "no form on this page answers the event #{inspect(event)}"
  end

  defp fetch!(specs, assign) do
    Enum.find(specs, &(&1.assign == assign)) ||
      raise ArgumentError, "no form assigned to #{inspect(assign)} on this page"
  end
end
