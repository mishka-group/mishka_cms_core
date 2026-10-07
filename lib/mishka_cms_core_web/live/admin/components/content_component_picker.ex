defmodule MishkaCmsCoreWeb.Live.Admin.Components.ContentComponentPicker do
  @moduledoc """
  "Insert component" beside a Gervaz form's content field: find a component the record's site may
  draw, fill the attributes it declares, and its marker is written at the end of the field. See
  `MishkaCmsCore.Runtime.ContentComponents` for the marker and how a page draws it.

  ## Wiring

  Two notices and the form's events, all in the resource's Gervaz form:

      form do
        events MishkaCmsCoreWeb.Forms.ContentComponentEvents

        layout do
          notice :content_components do
            position {:before_group, :content}
            render fn assigns, state -> ContentComponentPicker.picker(assigns, state, :content) end
          end

          notice :content_components_form do
            position :form_footer
            render fn assigns, state -> ContentComponentPicker.form_owner(assigns, state, :content) end
          end
        end
      end

  `picker/3` draws the control. Its inputs belong to the empty `<form>` `form_owner/3` draws after
  the record's form, through their `form` attribute: typing in them never reaches the record's own
  change, and Enter never saves the record. Insert submits that form to the record's form, whose
  events (`MishkaCmsCoreWeb.Forms.ContentComponentEvents`) write the marker into the field and
  close this.

  The list is read when the control is first opened, in the background, as the signed-in user —
  `ContentComponents.embeddable/2`. A master's record is on the site its Site field names, else the
  site of the record being edited; a site user's is on their own.
  """
  use Phoenix.LiveComponent
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  alias MishkaCmsCore.Runtime.ContentComponents
  alias MishkaCmsCore.Runtime.PageBuilder.Inspector
  alias Phoenix.LiveView.{AsyncResult, JS}

  @field_class "w-full rounded-[11px] border border-[#ecebe6] bg-[#faf9f6] px-[13px] text-[12.5px] font-medium text-[#1b1a18] outline-none focus:border-[#c3c1f0] focus:bg-white focus:shadow-[0_0_0_3px_rgba(91,87,214,0.1)]"

  @doc """
  The control, drawn by a Gervaz notice:
  `render fn assigns, state -> picker(assigns, state, :content) end`.
  """
  @spec picker(map(), map(), atom()) :: Phoenix.LiveView.Rendered.t()
  def picker(assigns, state, field) do
    assigns =
      assign(assigns,
        picker_id: id(state.static.id, field),
        picker_field: to_string(field),
        picker_site: site(state),
        picker_user: state.current_user
      )

    ~H"""
    <.live_component
      module={__MODULE__}
      id={@picker_id}
      field={@picker_field}
      site_id={@picker_site}
      current_user={@picker_user}
    />
    """
  end

  @doc """
  The `<form>` the control's inputs belong to, drawn after the record's form by a `:form_footer`
  notice: `render fn assigns, state -> form_owner(assigns, state, :content) end`. Its change goes to
  the control; its submit to the record's form.
  """
  @spec form_owner(map(), map(), atom()) :: Phoenix.LiveView.Rendered.t()
  def form_owner(assigns, state, field) do
    picker_id = id(state.static.id, field)
    assigns = assign(assigns, owner_id: picker_id <> "-form", owner_picker: "#" <> picker_id)

    ~H"""
    <form
      id={@owner_id}
      phx-change={JS.push("change", target: @owner_picker)}
      phx-submit={JS.push("insert_content_component", target: @myself)}
      class="hidden"
    >
    </form>
    """
  end

  @doc """
  The control's DOM id for `field` on the Gervaz form `form_id` — what its two halves and the event
  that closes it agree on.
  """
  @spec id(String.t(), atom() | String.t()) :: String.t()
  def id(form_id, field), do: "#{form_id}-#{field}-components"

  defp site(%{master_user?: true} = state),
    do: present(Map.get(state.field_values, :site_id)) || record_site(state.form)

  defp site(%{current_user: %{site_id: site_id}}), do: site_id
  defp site(_state), do: nil

  defp record_site(%Phoenix.HTML.Form{source: %{data: %{site_id: site_id}}}), do: site_id
  defp record_site(_form), do: nil

  defp present(value) when value in [nil, ""], do: nil
  defp present(value), do: value

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       open?: false,
       components: AsyncResult.loading(),
       loaded_for: :nothing,
       query: "",
       picked: nil,
       values: %{},
       inner: ""
     )}
  end

  @impl true
  def update(%{inserted: true}, socket), do: {:ok, close(socket)}

  def update(assigns, socket),
    do: {:ok, assign(socket, Map.take(assigns, [:id, :field, :site_id, :current_user]))}

  @impl true
  def handle_event("open", _params, socket),
    do: {:noreply, socket |> assign(:open?, true) |> load()}

  def handle_event("close", _params, socket), do: {:noreply, close(socket)}

  def handle_event("pick", %{"name" => name}, socket),
    do:
      {:noreply,
       assign(socket, picked: find(socket.assigns.components, name), values: %{}, inner: "")}

  def handle_event("back", _params, socket),
    do: {:noreply, assign(socket, picked: nil, values: %{}, inner: "")}

  def handle_event("change", %{"content_component" => %{} = params}, socket) do
    {:noreply,
     assign(socket,
       query: text(params["q"], socket.assigns.query),
       values: attr_values(params["attrs"]),
       inner: text(params["inner"], "")
     )}
  end

  def handle_event("change", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:components, {:ok, {:ok, entries}}, socket),
    do: {:noreply, assign(socket, :components, AsyncResult.ok(entries))}

  def handle_async(:components, {:ok, {:error, reason}}, socket),
    do: {:noreply, failed(socket, reason)}

  def handle_async(:components, {:exit, reason}, socket), do: {:noreply, failed(socket, reason)}

  defp failed(socket, reason) do
    assign(socket,
      components: AsyncResult.failed(socket.assigns.components, reason),
      loaded_for: :nothing
    )
  end

  # Read once per site, when the control is first opened; a master who picks another site reads
  # that site's list on the next open.
  defp load(%{assigns: %{site_id: site_id, loaded_for: site_id}} = socket), do: socket

  defp load(socket) do
    %{current_user: user, site_id: site_id} = socket.assigns

    socket
    |> assign(components: AsyncResult.loading(), loaded_for: site_id, picked: nil)
    |> MishkaGervaz.Messages.start_async(:components, fn ->
      ContentComponents.embeddable(user, site_id)
    end)
  end

  defp close(socket),
    do: assign(socket, open?: false, picked: nil, values: %{}, inner: "", query: "")

  defp find(%AsyncResult{ok?: true, result: entries}, name),
    do: Enum.find(entries, &(&1.name == name))

  defp find(_components, _name), do: nil

  defp attr_values(%{} = values),
    do: Map.filter(values, fn {name, value} -> is_binary(name) and is_binary(value) end)

  defp attr_values(_values), do: %{}

  defp text(value, _fallback) when is_binary(value), do: value
  defp text(_value, fallback), do: fallback

  defp matching(entries, query) do
    case query |> String.trim() |> String.downcase() do
      "" ->
        entries

      words ->
        Enum.filter(
          entries,
          &(String.contains?(String.downcase(&1.name), words) or described?(&1, words))
        )
    end
  end

  defp described?(%{description: description}, words) when is_binary(description),
    do: String.contains?(String.downcase(description), words)

  defp described?(_entry, _words), do: false

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :owner, assigns.id <> "-form")

    ~H"""
    <div id={@id} data-role="content-components" class="mb-4">
      <div :if={!@open?} class="flex flex-wrap items-center gap-2.5">
        <button
          type="button"
          id={@id <> "-open"}
          phx-click="open"
          phx-target={@myself}
          class="inline-flex h-9 items-center gap-1.5 rounded-[10px] border border-[#ecebe6] bg-white px-3 text-[12px] font-semibold text-[#3a382f] hover:bg-[#f7f6f3]"
        >
          <.icon name="hero-squares-plus" class="size-[15px]" />
          {gettext("Insert component")}
        </button>
        <span class="text-[11px] font-medium text-[#8a877f]">
          {gettext(
            "Writes a component's marker into the content; the page draws the component there."
          )}
        </span>
      </div>

      <div
        :if={@open?}
        id={@id <> "-panel"}
        class="rounded-[14px] border border-[#ecebe6] bg-white p-4"
      >
        <div class="mb-3 flex items-center gap-2">
          <button
            :if={@picked}
            type="button"
            id={@id <> "-back"}
            phx-click="back"
            phx-target={@myself}
            aria-label={gettext("Back")}
            class="flex size-7 items-center justify-center rounded-[8px] text-[#5c5a54] hover:bg-[#f6f5f2]"
          >
            <.icon name="hero-chevron-left" class="size-4 rtl:rotate-180" />
          </button>
          <span
            class="min-w-0 flex-1 truncate text-[13px] font-bold text-[#1b1a18]"
            dir={@picked && "ltr"}
          >
            {(@picked && @picked.name) || gettext("Insert component")}
          </span>
          <button
            type="button"
            id={@id <> "-close"}
            phx-click="close"
            phx-target={@myself}
            aria-label={gettext("Close")}
            class="flex size-7 items-center justify-center rounded-[8px] text-[#5c5a54] hover:bg-[#f6f5f2]"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <.choose
          :if={!@picked}
          id={@id}
          owner={@owner}
          query={@query}
          components={@components}
          myself={@myself}
        />

        <.fill
          :if={@picked}
          id={@id}
          owner={@owner}
          field={@field}
          entry={@picked}
          values={@values}
          inner={@inner}
        />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :owner, :string, required: true
  attr :query, :string, required: true
  attr :components, AsyncResult, required: true
  attr :myself, :any, required: true

  defp choose(assigns) do
    ~H"""
    <input
      type="search"
      id={@id <> "-query"}
      form={@owner}
      name="content_component[q]"
      value={@query}
      placeholder={gettext("Search components")}
      autocomplete="off"
      phx-debounce="200"
      dir="auto"
      class={["h-10", field_class()]}
    />

    <.async_result :let={entries} assign={@components}>
      <:loading>
        <p class="mt-3 text-[12px] font-medium text-[#8a877f]">{gettext("Loading components…")}</p>
      </:loading>
      <:failed>
        <p class="mt-3 text-[12px] font-medium text-[#b5495f]">
          {gettext("The components could not be read.")}
        </p>
      </:failed>

      <ul id={@id <> "-list"} class="mt-3 flex max-h-72 flex-col gap-1 overflow-y-auto">
        <li :for={entry <- matching(entries, @query)}>
          <button
            type="button"
            id={@id <> "-pick-" <> entry.name}
            phx-click="pick"
            phx-value-name={entry.name}
            phx-target={@myself}
            class="flex w-full flex-col items-start gap-0.5 rounded-[10px] px-3 py-2 text-start hover:bg-[#f6f5f2]"
          >
            <span class="flex items-center gap-1.5">
              <span dir="ltr" class="text-[12.5px] font-semibold text-[#1b1a18]">{entry.name}</span>
              <span
                :if={entry.stateful}
                class="rounded-full bg-[#eef1fc] px-1.5 text-[10px] font-bold text-[#4f4bcc]"
              >
                {gettext("Keeps state")}
              </span>
              <span
                :if={entry.global}
                class="rounded-full bg-[#f2f1ec] px-1.5 text-[10px] font-bold text-[#8a877f]"
              >
                {gettext("Shared")}
              </span>
            </span>
            <span
              :if={entry.description}
              dir="auto"
              class="line-clamp-2 text-[11px] font-medium text-[#8a877f]"
            >
              {entry.description}
            </span>
          </button>
        </li>
      </ul>

      <p
        :if={matching(entries, @query) == []}
        class="mt-3 text-[12px] font-medium text-[#8a877f]"
      >
        {gettext("No component matches.")}
      </p>
    </.async_result>
    """
  end

  attr :id, :string, required: true
  attr :owner, :string, required: true
  attr :field, :string, required: true
  attr :entry, :map, required: true
  attr :values, :map, required: true
  attr :inner, :string, required: true

  defp fill(assigns) do
    assigns =
      assign(assigns,
        marker: ContentComponents.marker(assigns.entry.name, assigns.values, assigns.inner)
      )

    ~H"""
    <input type="hidden" form={@owner} name="content_component[name]" value={@entry.name} />
    <input type="hidden" form={@owner} name="content_component[field]" value={@field} />

    <p :if={@entry.attrs == []} class="text-[12px] font-medium text-[#8a877f]">
      {gettext("Takes nothing a marker can set.")}
    </p>

    <div class="flex flex-col gap-3">
      <div :for={attr <- @entry.attrs} class="flex flex-col gap-1">
        <label
          for={@id <> "-attr-" <> attr.name}
          class="text-[11.5px] font-semibold text-[#3a382f]"
        >
          {Inspector.label(attr.name)}<span :if={attr.required} class="text-[#b5495f]"> *</span>
        </label>
        <.value_input
          id={@id <> "-attr-" <> attr.name}
          owner={@owner}
          attr={attr}
          value={Map.get(@values, attr.name, "")}
        />
        <span :if={attr.doc} dir="auto" class="text-[10.5px] font-medium text-[#8a877f]">
          {attr.doc}
        </span>
      </div>

      <div :if={@entry.inner_block} class="flex flex-col gap-1">
        <label for={@id <> "-inner"} class="text-[11.5px] font-semibold text-[#3a382f]">
          {gettext("Inner content")}
        </label>
        <textarea
          id={@id <> "-inner"}
          form={@owner}
          name="content_component[inner]"
          rows="3"
          dir="auto"
          class={["py-2", field_class()]}
        >{@inner}</textarea>
      </div>

      <code
        :if={@marker}
        id={@id <> "-marker"}
        dir="ltr"
        class="block break-all rounded-[10px] bg-[#f7f6f3] px-3 py-2 text-[11px] text-[#3a382f]"
      >
        {@marker}
      </code>

      <div class="flex justify-end">
        <button
          type="submit"
          id={@id <> "-insert"}
          form={@owner}
          class="h-9 rounded-[10px] bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] px-4 text-[12px] font-bold text-white"
        >
          {gettext("Insert")}
        </button>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :owner, :string, required: true
  attr :attr, :map, required: true
  attr :value, :string, required: true

  defp value_input(%{attr: %{values: [_ | _]}} = assigns) do
    ~H"""
    <select
      id={@id}
      form={@owner}
      name={"content_component[attrs][#{@attr.name}]"}
      class={["h-10", field_class()]}
    >
      <option value="">{default_label(@attr)}</option>
      <option :for={value <- @attr.values} value={value} selected={to_string(value) == @value}>
        {value}
      </option>
    </select>
    """
  end

  defp value_input(%{attr: %{type: "boolean"}} = assigns) do
    ~H"""
    <select
      id={@id}
      form={@owner}
      name={"content_component[attrs][#{@attr.name}]"}
      class={["h-10", field_class()]}
    >
      <option value="">{default_label(@attr)}</option>
      <option value="true" selected={@value == "true"}>{gettext("Yes")}</option>
      <option value="false" selected={@value == "false"}>{gettext("No")}</option>
    </select>
    """
  end

  defp value_input(%{attr: %{type: type}} = assigns) when type in ["integer", "float"] do
    assigns = assign(assigns, :step, (type == "integer" && "1") || "any")

    ~H"""
    <input
      type="number"
      id={@id}
      form={@owner}
      name={"content_component[attrs][#{@attr.name}]"}
      value={@value}
      step={@step}
      placeholder={placeholder(@attr)}
      dir="ltr"
      class={["h-10", field_class()]}
    />
    """
  end

  defp value_input(assigns) do
    ~H"""
    <input
      type="text"
      id={@id}
      form={@owner}
      name={"content_component[attrs][#{@attr.name}]"}
      value={@value}
      placeholder={placeholder(@attr)}
      autocomplete="off"
      dir="auto"
      class={["h-10", field_class()]}
    />
    """
  end

  defp default_label(%{default: default})
       when (is_binary(default) and default != "") or is_number(default) or is_boolean(default),
       do: gettext("Default: %{value}", value: to_string(default))

  defp default_label(_attr), do: gettext("Default")

  defp placeholder(%{default: default}) when is_binary(default) or is_number(default),
    do: to_string(default)

  defp placeholder(_attr), do: nil

  defp field_class, do: @field_class
end
