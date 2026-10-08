defmodule MishkaCmsCoreWeb.Live.Admin.Components.ContentComponentPicker do
  @moduledoc """
  The server half of the content editor `MishkaCmsCoreWeb.UIAdapters.Admin.textarea/1` draws for a
  `:textarea` field with `ui do extra %{content_editor: true} end`: the component palette, the
  settings of a component placed in the content, and the answers the editor's hook asks for. See
  `MishkaCmsCore.Runtime.ContentComponents` for the marker and how a page draws it.

  The adapter mounts it inside the editor, so a resource adds nothing else to its form.

  ## What the hook asks

  The editor's surface carries this component's DOM id as `data-components`, and the hook pushes
  these to it:

    * `"segments"`, `%{"html" => html}` — answered `%{segments: [...]}`: `html` as
      `ContentComponents.segments/1` splits it, `%{type: "html", html: html}` and
      `%{type: "component", name: name, marker: marker}`.
    * `"build"`, `%{"name" => name, "attrs" => %{}, "inner" => html}` — answered
      `%{name: name, marker: marker}` for a component the palette lists, with only the attributes
      it declares, and the palette closes off the text; or `%{error: message}`, and the palette
      stays open and says why.
    * `"edit"`, `%{"marker" => marker}` — opens the settings of the component `marker` names, filled
      in from it. Answered `%{ok: true}`, or `%{error: message}` when the palette does not list it.

  A component's preview is drawn after the answer, in the background — it runs the component's own
  code — and pushed to the page as `"mishka:content_editor"`,
  `%{id: editor_id, previews: [%{marker: marker, preview: html}]}`. A preview that cannot be drawn
  is pushed as an empty one.

  Every name is checked as a string: against the names the palette lists before a marker is
  written, and against the components the site may draw (`ContentComponents.draw/2`) before a
  preview is. No name a request carries is made into an atom.

  ## The palette and the settings

  The palette is `ContentComponents.palette/2`, read in the background as the signed-in user the
  first time it is opened. A master's record is on the site its Site field names, else the site of
  the record being edited; a site user's is on their own (`site/1`).

  Its inputs and the settings' belong to no form — their `form` attribute names none — so typing in
  them never reaches the record's own change and Enter never saves the record. The hook reads the
  settings when Apply is pressed and sends them as `"build"`.
  """
  use Phoenix.LiveComponent
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  alias MishkaCmsCore.Runtime.{ContentComponents, Translations}
  alias MishkaCmsCore.Runtime.PageBuilder.Inspector
  alias MishkaCmsCore.Runtime.States.SiteState
  alias Phoenix.LiveView.AsyncResult

  @field_class "w-full rounded-[11px] border border-[#ecebe6] bg-[#faf9f6] px-[13px] text-[12.5px] font-medium text-[#1b1a18] outline-none focus:border-[#c3c1f0] focus:bg-white focus:shadow-[0_0_0_3px_rgba(91,87,214,0.1)]"

  # A request carrying more components than this is answered with this many previews.
  @previews 100

  @event "mishka:content_editor"

  @doc """
  The site the record a Gervaz form `state` edits is on: for a master, the one its Site field names,
  else the record's own; for a site user, their own. `nil` is the global components alone.
  """
  @spec site(map() | nil) :: String.t() | nil
  def site(%{master_user?: true} = state),
    do: present(Map.get(state.field_values || %{}, :site_id)) || record_site(state.form)

  def site(%{current_user: %{site_id: site_id}}), do: site_id
  def site(_state), do: nil

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
       settings: nil,
       pending: nil,
       notice: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, Map.take(assigns, [:id, :editor, :site_id, :current_user]))

    case socket.assigns.open? do
      true -> {:ok, load(socket)}
      false -> {:ok, socket}
    end
  end

  @impl true
  def handle_event("toggle", _params, %{assigns: %{open?: true}} = socket),
    do: {:noreply, close(socket)}

  def handle_event("toggle", _params, socket),
    do: {:noreply, socket |> assign(:open?, true) |> load()}

  def handle_event("close", _params, socket), do: {:noreply, close(socket)}

  def handle_event("back", _params, socket),
    do: {:noreply, assign(socket, settings: nil, notice: nil)}

  def handle_event("search", %{"value" => query}, socket) when is_binary(query),
    do: {:noreply, assign(socket, :query, query)}

  def handle_event("search", _params, socket), do: {:noreply, socket}

  def handle_event("segments", %{"html" => html}, socket) when is_binary(html) do
    segments = Enum.map(ContentComponents.segments(html), &segment/1)

    markers =
      for %{type: "component", marker: marker} <- segments, uniq: true, do: marker

    {:reply, %{segments: segments}, previews(socket, Enum.take(markers, @previews))}
  end

  def handle_event("segments", _params, socket), do: {:reply, %{segments: []}, socket}

  def handle_event("build", %{"name" => name} = params, socket) when is_binary(name) do
    with %{} = entry <- listed(socket.assigns.components, name),
         marker when is_binary(marker) <-
           ContentComponents.marker(
             entry.name,
             declared(entry, params["attrs"]),
             text(params["inner"])
           ) do
      {:reply, %{name: entry.name, marker: marker}, socket |> close() |> previews([marker])}
    else
      _not_placeable ->
        message = refused(name)
        {:reply, %{error: message}, assign(socket, open?: true, notice: message)}
    end
  end

  def handle_event("build", _params, socket) do
    message = refused("")
    {:reply, %{error: message}, assign(socket, open?: true, notice: message)}
  end

  def handle_event("edit", %{"marker" => marker}, socket) when is_binary(marker) do
    case ContentComponents.parse(String.trim(marker)) do
      [{:component, placed}] -> edit(socket, placed)
      _not_one_marker -> {:reply, %{error: refused("")}, socket}
    end
  end

  def handle_event("edit", _params, socket), do: {:reply, %{error: refused("")}, socket}

  # The settings of a placed component, once the palette that says what it takes has been read.
  defp edit(
         %{assigns: %{components: %AsyncResult{ok?: true}, loaded_for: site, site_id: site}} =
           socket,
         placed
       ) do
    case listed(socket.assigns.components, placed.name) do
      %{} = entry ->
        {:reply, %{ok: true},
         assign(socket, open?: true, notice: nil, settings: settings(entry, placed))}

      nil ->
        message = refused(placed.name)
        {:reply, %{error: message}, assign(socket, open?: true, settings: nil, notice: message)}
    end
  end

  defp edit(socket, placed) do
    {:reply, %{ok: true}, socket |> assign(open?: true, pending: placed, notice: nil) |> load()}
  end

  defp settings(entry, placed) do
    values =
      for %{name: name} <- entry.attrs,
          Map.has_key?(placed.attrs, name),
          into: %{},
          do: {name, written(Map.fetch!(placed.attrs, name))}

    %{entry: entry, values: values, inner: placed.inner || ""}
  end

  defp written(true), do: "true"
  defp written(value), do: value

  @impl true
  def handle_async(:components, {:ok, {:ok, entries}}, socket) do
    socket = assign(socket, :components, AsyncResult.ok(entries))

    case socket.assigns.pending do
      nil -> {:noreply, socket}
      placed -> {:noreply, socket |> assign(:pending, nil) |> open_pending(placed)}
    end
  end

  def handle_async(:components, {:ok, {:error, reason}}, socket),
    do: {:noreply, failed(socket, reason)}

  def handle_async(:components, {:exit, reason}, socket), do: {:noreply, failed(socket, reason)}

  def handle_async({:previews, markers}, {:ok, previews}, socket),
    do: {:noreply, push_previews(socket, Enum.zip(markers, previews))}

  def handle_async({:previews, markers}, {:exit, _reason}, socket),
    do: {:noreply, push_previews(socket, Enum.map(markers, &{&1, ""}))}

  defp open_pending(socket, placed) do
    case listed(socket.assigns.components, placed.name) do
      %{} = entry -> assign(socket, settings: settings(entry, placed))
      nil -> assign(socket, notice: refused(placed.name))
    end
  end

  defp failed(socket, reason) do
    assign(socket,
      components: AsyncResult.failed(socket.assigns.components, reason),
      loaded_for: :nothing,
      pending: nil
    )
  end

  # Read once per site, when the palette is first opened; a master who picks another site reads
  # that site's list on the next open.
  defp load(%{assigns: %{site_id: site_id, loaded_for: site_id}} = socket), do: socket

  defp load(socket) do
    %{current_user: user, site_id: site_id} = socket.assigns

    socket
    |> assign(components: AsyncResult.loading(), loaded_for: site_id, settings: nil)
    |> MishkaGervaz.Messages.start_async(:components, fn ->
      ContentComponents.palette(user, site_id)
    end)
  end

  defp close(socket),
    do: assign(socket, open?: false, settings: nil, notice: nil, query: "", pending: nil)

  defp listed(%AsyncResult{ok?: true, result: entries}, name) when is_binary(name),
    do: Enum.find(entries, &(&1.name == name))

  defp listed(_components, _name), do: nil

  # Only the attributes the component declares, as text a marker can hold.
  defp declared(entry, %{} = attrs) do
    for %{name: name} <- entry.attrs,
        value = Map.get(attrs, name),
        is_binary(value),
        into: %{},
        do: {name, value}
  end

  defp declared(_entry, _attrs), do: %{}

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  defp refused(name),
    do: gettext("%{name} is not a component this site can place in content.", name: name)

  defp segment({:html, html}), do: %{type: "html", html: html}

  defp segment({:component, %{name: name, marker: marker}}),
    do: %{type: "component", name: name, marker: marker}

  defp previews(socket, []), do: socket

  defp previews(socket, markers) do
    %{site_id: site_id, current_user: user, editor: editor} = socket.assigns
    site = site_name(site_id)

    MishkaGervaz.Messages.start_async(socket, {:previews, markers}, fn ->
      :ok = Translations.put_site(site_id)
      Enum.map(markers, &preview(&1, site, user, editor))
    end)
  end

  # Drawn as the record's site draws it — the task answers for that site — and scrubbed after,
  # because it is shown inside the admin: no script, no event attribute and no `phx-` binding
  # reaches the editor.
  defp preview(marker, site, user, editor) do
    %{html: marker, site: site, current_user: user, id: editor <> "-preview"}
    |> ContentComponents.draw(:static)
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
    |> HtmlSanitizeEx.html5()
  end

  defp push_previews(socket, pairs) do
    push_event(socket, @event, %{
      id: socket.assigns.editor,
      previews: Enum.map(pairs, fn {marker, preview} -> %{marker: marker, preview: preview} end)
    })
  end

  defp site_name(site_id) when is_binary(site_id) do
    case SiteState.get(site_id) do
      {:ok, %{name: name}} -> name
      _unknown -> nil
    end
  end

  defp site_name(_site_id), do: nil

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

  defp configurable?(entry), do: entry.attrs != [] or entry.inner_block

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :detached, assigns.id <> "-detached")

    ~H"""
    <div id={@id} data-role="content-editor-components" class="contents">
      <div
        :if={@open?}
        id={@id <> "-panel"}
        data-role="content-editor-panel"
        class="absolute end-2 top-[46px] z-30 flex max-h-[440px] w-[310px] max-w-[calc(100%-1rem)] flex-col rounded-[14px] border border-[#ecebe6] bg-white p-3 shadow-[0_14px_34px_rgba(27,26,24,0.13)]"
      >
        <div class="mb-2.5 flex items-center gap-2">
          <button
            :if={@settings}
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
            dir={@settings && "ltr"}
          >
            {(@settings && @settings.entry.name) || gettext("Components")}
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

        <p
          :if={@notice}
          id={@id <> "-notice"}
          class="mb-2 rounded-[10px] bg-[#fbeef1] px-3 py-2 text-[11.5px] font-medium text-[#b5495f]"
        >
          {@notice}
        </p>

        <.choose
          :if={!@settings}
          id={@id}
          detached={@detached}
          query={@query}
          components={@components}
          myself={@myself}
        />

        <.fill :if={@settings} id={@id} detached={@detached} settings={@settings} />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :detached, :string, required: true
  attr :query, :string, required: true
  attr :components, AsyncResult, required: true
  attr :myself, :any, required: true

  defp choose(assigns) do
    ~H"""
    <input
      type="search"
      id={@id <> "-query"}
      form={@detached}
      value={@query}
      placeholder={gettext("Search components")}
      autocomplete="off"
      phx-keyup="search"
      phx-target={@myself}
      phx-debounce="200"
      dir="auto"
      class={["h-9", field_class()]}
    />

    <p class="mt-2 text-[10.5px] font-medium text-[#8a877f]">
      {gettext("Click a component to place it at the cursor, or drag it into the text.")}
    </p>

    <.async_result :let={entries} assign={@components}>
      <:loading>
        <p class="mt-3 text-[12px] font-medium text-[#8a877f]">{gettext("Loading components…")}</p>
      </:loading>
      <:failed>
        <p class="mt-3 text-[12px] font-medium text-[#b5495f]">
          {gettext("The components could not be read.")}
        </p>
      </:failed>

      <ul id={@id <> "-list"} class="mt-2 flex min-h-0 flex-1 flex-col gap-1 overflow-y-auto">
        <li :for={entry <- matching(entries, @query)}>
          <button
            type="button"
            id={@id <> "-pick-" <> entry.name}
            draggable="true"
            data-component-card={entry.name}
            data-configurable={to_string(configurable?(entry))}
            class="flex w-full cursor-grab flex-col items-start gap-0.5 rounded-[10px] px-3 py-2 text-start hover:bg-[#f6f5f2] active:cursor-grabbing"
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
  attr :detached, :string, required: true
  attr :settings, :map, required: true

  defp fill(assigns) do
    assigns = assign(assigns, entry: assigns.settings.entry)

    ~H"""
    <div
      id={@id <> "-settings"}
      data-content-editor-settings={@entry.name}
      class="flex min-h-0 flex-col gap-3 overflow-y-auto"
    >
      <p
        :if={@entry.attrs == [] and !@entry.inner_block}
        class="text-[12px] font-medium text-[#8a877f]"
      >
        {gettext("Takes nothing a marker can set.")}
      </p>

      <div :for={attr <- @entry.attrs} class="flex flex-col gap-1">
        <label
          for={@id <> "-attr-" <> attr.name}
          class="text-[11.5px] font-semibold text-[#3a382f]"
        >
          {Inspector.label(attr.name)}<span :if={attr.required} class="text-[#b5495f]"> *</span>
        </label>
        <.value_input
          id={@id <> "-attr-" <> attr.name}
          detached={@detached}
          attr={attr}
          value={Map.get(@settings.values, attr.name, "")}
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
          form={@detached}
          data-content-editor-inner
          rows="3"
          dir="auto"
          class={["py-2", field_class()]}
        >{@settings.inner}</textarea>
      </div>

      <div class="flex justify-end">
        <button
          type="button"
          id={@id <> "-apply"}
          data-content-editor-apply={@entry.name}
          class="h-9 rounded-[10px] bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] px-4 text-[12px] font-bold text-white"
        >
          {gettext("Apply")}
        </button>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :detached, :string, required: true
  attr :attr, :map, required: true
  attr :value, :string, required: true

  defp value_input(%{attr: %{values: [_ | _]}} = assigns) do
    ~H"""
    <select
      id={@id}
      form={@detached}
      data-content-editor-attr={@attr.name}
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
      form={@detached}
      data-content-editor-attr={@attr.name}
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
      form={@detached}
      data-content-editor-attr={@attr.name}
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
      form={@detached}
      data-content-editor-attr={@attr.name}
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
