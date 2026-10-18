# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Components.ContentComponentPicker do
  @moduledoc """
  The server half of the content editor `MishkaCmsCoreWeb.UIAdapters.Admin.textarea/1` draws for a
  `:textarea` field with `ui do extra %{content_editor: true} end`: the palette an author places
  from, the settings of a placed component, and the answers the editor's hook asks for. See
  `MishkaCmsCore.Runtime.ContentComponents` for the marker and how a page draws it.

  The adapter mounts it inside the editor, so a resource adds nothing else to its form.

  ## The palette

  Two tabs: **Blocks** — whole ready-made pieces, `MishkaCmsCore.Runtime.ContentBlocks.available/3`
  — and **Components**, every component the site may place (`ContentComponents.palette/2`) under
  its heading, text first (`ContentComponents.category/2`). One search box searches the tab that
  is open; the headings filter the components. It is read in the background as the signed-in user
  the first time it is opened. A master's record is on the site its Site field names, else the
  site of the record being edited; a site user's is on their own (`site/1`).

  ## The settings

  A component being placed or edited opens its settings in a drawer at the side of the page — its
  attributes, the text and components inside it, and its slot entries, each of those with its own,
  put in another order with their arrows or dragged there by their grips — through a portal, so the
  drawer's form is a form of its own and not part of the record's. Every change is written straight
  back into the component in the content, as the author types, and the drawer is closed with Done, a
  click outside it, or Escape. A picture or a video is chosen from the site's media library, or
  uploaded to it, in `MishkaCmsCoreWeb.Live.Admin.Components.ContentMediaChooser`, which opens over
  the settings and leaves them as they were — scrolled to the field it was opened for, with the same
  parts open.

  ## What the hook asks

  The editor's surface carries this component's DOM id as `data-components`, and the hook pushes
  these to it:

    * `"segments"`, `%{"html" => html}` — answered `%{segments: [...], styles: href | nil}`: `html` as
      `ContentComponents.segments/1` splits it, `%{type: "html", html: html}` and
      `%{type: "component", name: name, marker: marker}`.
    * `"build"`, `%{"name" => name, "attrs" => %{}, "inner" => html}` — answered
      `%{name: name, marker: marker}` for a component the palette lists, with only the attributes
      it declares and an empty entry for each slot it requires, and the palette closes; or
      `%{error: message}`, and the palette stays open and says why.
    * `"block"`, `%{"id" => id}` — a ready-made block's marker, answered as `"build"` is.
    * `"nest"`, `%{"marker" => marker, "name" => name}` or `%{"marker" => marker, "block" => id}`
      — the component `marker` names with the component `name`, or the ready-made block `id`,
      put inside it: beside its part `"beside"` (`"r-2"`), after it when `"after"` is `true`, or
      at the end of what it holds. Answered as `"build"` is; `%{error: message}` when `marker`
      holds nothing or either is not listed.
    * `"reorder"`, `%{"marker" => marker, "path" => path, "beside" => path, "after" => boolean}` —
      the component `marker` names with its part at `path` moved before, or after, its sibling at
      `beside`, answered as `"build"` is.
    * `"edit"`, `%{"marker" => marker, "serial" => n}` — opens the settings of the component
      `marker` names, filled in from it. Answered `%{ok: true}`, or `%{error: message}` when the
      palette does not list it. `n` comes back on what those settings write.
    * `"close"` — closes the palette, and `"settings_done"` the settings.

  `"nest"` and `"reorder"` carry the `"serial"` of the settings open on that component, if they are:
  the settings then take the change, answer `%{ok: true}` and write it back as `applied`.

  And this pushes `"mishka:content_editor"` to the page, `%{id: editor_id, ...}` with:

    * `styles: href` — the stylesheet previews are drawn with, once it is built
      (`MishkaCmsCore.Runtime.ContentEditorStyles`); `"segments"` answers it too, when known.
    * `holders: [name]` — the components the palette lists that take others inside them, once the
      palette is read.
    * `previews: [%{marker: marker, preview: html}]` — a component's preview, drawn in the
      background after a marker is answered or written, each in a task of its own; it runs the
      component's own code. A component that raises as it is drawn is pushed as a notice saying
      so — the page would fail on it too. The parts it holds are marked in it (`marked/1`).
    * `applied: %{name: name, marker: marker}, serial: n` — the component being edited, as the
      settings now write it.
    * `done: true, serial: n` — the settings closed.

  Every name is checked as a string: against the names the palette lists before a marker is
  written, and against the components the site may draw (`ContentComponents.draw/2`) before a
  preview is. No name a request carries is made into an atom.
  """
  use Phoenix.LiveComponent
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [icon: 1, select_chevron: 1]

  alias MishkaCmsCore.Runtime.{
    ContentBlocks,
    ContentComponents,
    ContentEditorStyles,
    ContentPreviewScrubber,
    Translations
  }

  alias MishkaCmsCore.Runtime.PageBuilder.Inspector
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCoreWeb.Live.Admin.Components.ContentMediaChooser
  alias Phoenix.LiveView.{AsyncResult, JS}

  @field_class "w-full rounded-[11px] border border-[#ecebe6] bg-[#faf9f6] px-[13px] text-[13px] font-medium text-[#1b1a18] outline-none focus:border-[#c3c1f0] focus:bg-white focus:shadow-[0_0_0_3px_rgba(91,87,214,0.1)]"

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
       tab: nil,
       category: "all",
       query: "",
       components: AsyncResult.loading(),
       blocks: [],
       loaded_for: :nothing,
       settings: nil,
       pending: nil,
       notice: nil,
       styles: nil,
       styles_for: :nothing
     )}
  end

  @impl true
  def update(%{media: %{url: url}}, %{assigns: %{settings: %{media: %{} = target}}} = socket)
      when is_binary(url) do
    tree = socket.assigns.settings.tree
    entries = entries(socket.assigns.components)
    values = Map.merge(%{target.attr => url}, kind_of(tree, target, url, entries))

    {:ok, socket |> close_media() |> settle(put_attrs(tree, target.path, values))}
  end

  def update(%{media: _closed_or_late}, socket), do: {:ok, close_media(socket)}

  def update(assigns, socket) do
    socket = assign(socket, Map.take(assigns, [:id, :editor, :site_id, :current_user]))

    case socket.assigns.open? or not is_nil(socket.assigns.settings) do
      true -> {:ok, load(socket)}
      false -> {:ok, socket}
    end
  end

  ####################################################################################
  ############################ (▰˘◡˘▰) The palette (▰˘◡˘▰) ##########################
  ####################################################################################

  @impl true
  def handle_event("toggle", _params, %{assigns: %{open?: true}} = socket),
    do: {:noreply, close(socket)}

  def handle_event("toggle", _params, socket),
    do: {:noreply, socket |> assign(:open?, true) |> load()}

  def handle_event("close", _params, socket), do: {:noreply, close(socket)}

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["blocks", "components"],
    do: {:noreply, assign(socket, tab: tab, query: "")}

  def handle_event("category", %{"category" => category}, socket) when is_binary(category),
    do: {:noreply, assign(socket, :category, category)}

  def handle_event("search", %{"value" => query}, socket) when is_binary(query),
    do: {:noreply, assign(socket, :query, query)}

  def handle_event("search", _params, socket), do: {:noreply, socket}

  def handle_event("segments", %{"html" => html}, socket) when is_binary(html) do
    segments = Enum.map(ContentComponents.segments(html), &segment/1)

    markers =
      for %{type: "component", marker: marker} <- segments, uniq: true, do: marker

    socket = socket |> previews(Enum.take(markers, @previews)) |> styles()

    {:reply, %{segments: segments, styles: socket.assigns.styles}, socket}
  end

  def handle_event("segments", _params, socket), do: {:reply, %{segments: []}, socket}

  def handle_event("build", %{"name" => name} = params, socket) when is_binary(name) do
    with %{} = entry <- listed(socket.assigns.components, name),
         marker when is_binary(marker) <-
           built(entry, params["attrs"], params["inner"], entries(socket.assigns.components)) do
      {:reply, %{name: entry.name, marker: marker}, socket |> close() |> previews([marker])}
    else
      _not_placeable -> refuse(socket, name)
    end
  end

  def handle_event("build", _params, socket), do: refuse(socket, "")

  def handle_event("block", %{"id" => id}, socket) when is_binary(id) do
    case Enum.find(socket.assigns.blocks, &(&1.id == id)) do
      %{tree: tree, marker: marker} ->
        {:reply, %{name: tree.name, marker: marker}, socket |> close() |> previews([marker])}

      nil ->
        refuse(socket, id)
    end
  end

  def handle_event("block", _params, socket), do: refuse(socket, "")

  def handle_event("nest", %{"marker" => marker} = params, socket) when is_binary(marker) do
    components = socket.assigns.components

    with %{} = child <- arriving_child(params, socket),
         {:reply, %{error: _}, _socket} = refused <-
           reshape(socket, marker, params["serial"], fn tree ->
             case listed(components, tree.name) do
               %{inner_block: true} -> put_inside(tree, child, params["beside"], params["after"])
               _holds_nothing -> nil
             end
           end) do
      refused
    else
      nil -> {:reply, %{error: refused(params["name"] || "")}, socket}
      {:reply, answer, socket} -> {:reply, answer, close(socket)}
    end
  end

  def handle_event("nest", _params, socket), do: {:reply, %{error: refused("")}, socket}

  def handle_event(
        "reorder",
        %{"marker" => marker, "path" => path, "beside" => beside} = params,
        socket
      )
      when is_binary(marker) and is_binary(path) and is_binary(beside) do
    at = decode(path)

    reshape(socket, marker, params["serial"], fn tree ->
      case {Enum.split(at, -1), Enum.split(decode(beside), -1)} do
        {{parent, [i]}, {parent, [s]}} when i != s and i >= 0 and s >= 0 ->
          move_part(tree, at, placed(i, s, params["after"] == true))

        _not_siblings ->
          nil
      end
    end)
  end

  def handle_event("reorder", _params, socket), do: {:reply, %{error: refused("")}, socket}

  def handle_event("edit", %{"marker" => marker} = params, socket) when is_binary(marker) do
    case ContentComponents.read(marker) do
      {:ok, tree} -> edit(socket, tree, serial(params["serial"]))
      :error -> {:reply, %{error: refused("")}, socket}
    end
  end

  def handle_event("edit", _params, socket), do: {:reply, %{error: refused("")}, socket}

  ####################################################################################
  ############################ (▰˘◡˘▰) The settings (▰˘◡˘▰) #########################
  ####################################################################################

  def handle_event(_event, _params, %{assigns: %{settings: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("settings_change", params, socket) do
    entries = entries(socket.assigns.components)
    before = socket.assigns.settings.tree

    tree =
      params
      |> Map.get("a", %{})
      |> Enum.reduce(before, fn {path, values}, tree ->
        put_attrs(tree, decode(path), declared_values(tree, decode(path), values, entries))
      end)

    socket = update(socket, :settings, &%{&1 | changed: changed(before, tree), unchanged: []})

    tree =
      params
      |> Map.get("t", %{})
      |> Enum.reduce(tree, fn {path, text}, tree -> put_text(tree, decode(path), text) end)

    {:noreply, settle(socket, tree)}
  end

  def handle_event("settings_done", _params, socket), do: {:noreply, close_settings(socket)}

  def handle_event("part_add", %{"path" => path, "kind" => "text"}, socket) do
    tree = socket.assigns.settings.tree
    at = decode(path)

    case takes_content?(tree, at, entries(socket.assigns.components)) do
      true -> {:noreply, settle(socket, add_part(tree, at, {:text, ""}))}
      false -> {:noreply, socket}
    end
  end

  def handle_event("part_add", %{"path" => path, "kind" => "slot", "name" => name}, socket) do
    tree = socket.assigns.settings.tree
    at = decode(path)

    case slot_of(tree, at, name, entries(socket.assigns.components)) do
      %{} = slot ->
        part = {:slot, %{fresh_slot(slot) | parts: with_text([], slot.inner)}}
        {:noreply, settle(socket, add_part(tree, at, part))}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("part_add", %{"path" => path, "kind" => "component", "name" => name}, socket) do
    tree = socket.assigns.settings.tree
    at = decode(path)
    entries = entries(socket.assigns.components)

    with %{} = entry <- listed(socket.assigns.components, name),
         true <- takes_content?(tree, at, entries) do
      tree = add_part(tree, at, {:component, writable(arriving(entry, entries), entries)})

      {:noreply, socket |> update(:settings, &%{&1 | adding: nil}) |> settle(tree)}
    else
      _not_here -> {:noreply, socket}
    end
  end

  def handle_event("part_remove", %{"path" => path}, socket) do
    case decode(path) do
      [] -> {:noreply, socket}
      at -> {:noreply, settle(socket, remove_part(socket.assigns.settings.tree, at))}
    end
  end

  def handle_event("part_move", %{"path" => path, "by" => by}, socket) when by in ["-1", "1"] do
    tree = socket.assigns.settings.tree
    at = decode(path)

    case beside(tree, at, String.to_integer(by)) do
      nil -> {:noreply, socket}
      to -> {:noreply, settle(socket, move_part(tree, at, to))}
    end
  end

  # A part dragged to another place among its siblings: `to` is the one it was dropped beside.
  def handle_event("part_move", %{"path" => path, "to" => to}, socket) when is_binary(to) do
    at = decode(path)

    case {Enum.split(at, -1), Enum.split(decode(to), -1)} do
      {{parent, [_i]}, {parent, [to]}} ->
        {:noreply, settle(socket, move_part(socket.assigns.settings.tree, at, to))}

      _not_siblings ->
        {:noreply, socket}
    end
  end

  def handle_event("child_open", %{"path" => path}, socket),
    do: {:noreply, update(socket, :settings, &%{&1 | adding: path, adding_query: ""})}

  def handle_event("child_close", _params, socket),
    do: {:noreply, update(socket, :settings, &%{&1 | adding: nil})}

  def handle_event("child_query", %{"value" => query}, socket) when is_binary(query),
    do: {:noreply, update(socket, :settings, &%{&1 | adding_query: query})}

  def handle_event("media_open", %{"path" => path, "attr" => attr}, socket) do
    tree = socket.assigns.settings.tree
    at = decode(path)

    {:noreply,
     update(
       socket,
       :settings,
       &%{&1 | media: %{path: at, attr: attr, accepts: accepts(tree, at, attr)}}
     )}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The settings of a placed component, once the palette that says what it takes has been read.
  defp edit(
         %{assigns: %{components: %AsyncResult{ok?: true}, loaded_for: site, site_id: site}} =
           socket,
         tree,
         serial
       ) do
    case listed(socket.assigns.components, tree.name) do
      %{} ->
        {:reply, %{ok: true}, socket |> close() |> open_settings(tree, serial)}

      nil ->
        message = refused(tree.name)
        {:reply, %{error: message}, assign(socket, open?: true, settings: nil, notice: message)}
    end
  end

  defp edit(socket, tree, serial) do
    {:reply, %{ok: true},
     socket |> assign(open?: false, pending: {tree, serial}, notice: nil) |> load()}
  end

  # Which of the editor's edits this is: what it writes back carries it, so the editor tells an
  # answer for this edit from one for an earlier.
  defp serial(serial) when is_integer(serial), do: serial
  defp serial(_none), do: nil

  defp open_settings(socket, tree, serial) do
    entries = entries(socket.assigns.components)
    tree = writable(tree, entries)

    assign(socket,
      settings: %{
        tree: tree,
        serial: serial,
        marker: written(tree),
        adding: nil,
        adding_query: "",
        media: nil,
        drawn: nil,
        changed: [],
        unchanged: []
      },
      notice: nil
    )
    |> previews([written(tree)])
  end

  # THE DRAWER'S TEXT BOXES ARE LINES: two boxes side by side are written as two lines, not run
  # together into one.
  defp written(tree), do: tree |> lined() |> ContentComponents.write()

  defp lined(%{parts: parts} = container) do
    parts =
      parts
      |> Enum.map(fn
        {:component, tree} -> {:component, lined(tree)}
        {:slot, slot} -> {:slot, lined(slot)}
        text -> text
      end)
      |> Enum.reduce([], fn
        {:text, text}, [{:text, before} | rest] -> [{:text, joined(before, text)} | rest]
        part, acc -> [part | acc]
      end)
      |> Enum.reverse()

    %{container | parts: parts}
  end

  defp joined(before, text) do
    case String.trim(before) == "" or String.trim(text) == "" do
      true -> before <> text
      false -> before <> "<br>" <> text
    end
  end

  defp close_settings(socket) do
    socket
    |> assign(:settings, nil)
    |> push_event(@event, %{
      id: socket.assigns.editor,
      done: true,
      serial: socket.assigns.settings.serial
    })
  end

  defp close_media(%{assigns: %{settings: %{} = settings}} = socket),
    do: assign(socket, :settings, %{settings | media: nil})

  defp close_media(socket), do: socket

  # A PLACED COMPONENT CHANGED ON ITS BLOCK — a part moved, or one dropped in. With its settings
  # open (`serial` is theirs), the settings take the change and write it back as they write their
  # own; else the answer is the marker it now writes. `change` answers `nil` when there is no place
  # for it.
  defp reshape(
         %{assigns: %{settings: %{serial: serial} = settings}} = socket,
         _marker,
         serial,
         change
       )
       when is_integer(serial) do
    case change.(settings.tree) do
      %{} = tree -> {:reply, %{ok: true}, settle(socket, tree)}
      nil -> {:reply, %{error: refused("")}, socket}
    end
  end

  defp reshape(socket, marker, _serial, change) do
    with {:ok, tree} <- ContentComponents.read(marker),
         %{} = changed <- change.(tree),
         written when is_binary(written) <- ContentComponents.write(changed) do
      {:reply, %{name: changed.name, marker: written}, previews(socket, [written])}
    else
      _no_place -> {:reply, %{error: refused("")}, socket}
    end
  end

  # What a drop puts inside a component: one from the palette as it arrives, or a ready-made block.
  defp arriving_child(%{"name" => name}, socket) when is_binary(name) do
    components = socket.assigns.components

    case listed(components, name) do
      %{} = entry -> arriving(entry, entries(components))
      nil -> nil
    end
  end

  defp arriving_child(%{"block" => id}, socket) when is_binary(id) do
    case Enum.find(socket.assigns.blocks, &(&1.id == id)) do
      %{tree: tree} -> tree
      nil -> nil
    end
  end

  defp arriving_child(_params, _socket), do: nil

  # `child` among the parts of `tree`: before its part `beside`, after it when `after` is `true`, or
  # at the end.
  defp put_inside(%{parts: parts} = tree, child, beside, after?) do
    at =
      case is_binary(beside) && decode(beside) do
        [s] when s >= 0 and s < length(parts) -> if(after? == true, do: s + 1, else: s)
        _the_end -> length(parts)
      end

    %{tree | parts: List.insert_at(parts, at, {:component, child})}
  end

  # Where a part at `i` goes to stand before — or after — its sibling at `s`, once it is taken out.
  defp placed(i, s, true) when s > i, do: s
  defp placed(i, s, false) when s > i, do: s - 1
  defp placed(_i, s, true), do: s + 1
  defp placed(_i, s, false), do: s

  # THE COMPONENT IN THE CONTENT FOLLOWS THE SETTINGS as they change: the marker they now write
  # replaces the one being edited, and its preview is drawn again.
  defp settle(socket, tree) do
    settings = socket.assigns.settings

    case written(tree) do
      marker when is_binary(marker) and marker != settings.marker ->
        socket
        |> assign(:settings, %{settings | tree: tree, marker: marker})
        |> push_event(@event, %{
          id: socket.assigns.editor,
          serial: settings.serial,
          applied: %{name: tree.name, marker: marker}
        })
        |> previews([marker])

      _unchanged_or_unwritable ->
        assign(socket, :settings, %{settings | tree: tree})
    end
  end

  @impl true
  def handle_async(:components, {:ok, {:ok, {entries, blocks}}}, socket) do
    socket =
      socket
      |> assign(
        components: AsyncResult.ok(entries),
        blocks: blocks,
        tab: socket.assigns.tab || ((blocks == [] && "components") || "blocks")
      )
      |> push_event(@event, %{
        id: socket.assigns.editor,
        holders: for(%{inner_block: true, name: name} <- entries, do: name)
      })

    case socket.assigns.pending do
      nil -> {:noreply, socket}
      {tree, serial} -> {:noreply, socket |> assign(:pending, nil) |> open_pending(tree, serial)}
    end
  end

  def handle_async(:components, {:ok, {:error, reason}}, socket),
    do: {:noreply, failed(socket, reason)}

  def handle_async(:components, {:exit, reason}, socket), do: {:noreply, failed(socket, reason)}

  def handle_async(:styles, {:ok, {:ok, href}}, socket) do
    {:noreply,
     socket
     |> assign(:styles, href)
     |> push_event(@event, %{id: socket.assigns.editor, styles: href})}
  end

  def handle_async(:styles, _not_built, socket), do: {:noreply, socket}

  def handle_async({:preview, marker}, {:ok, preview}, socket),
    do: {:noreply, socket |> compared(marker, preview) |> push_previews([{marker, preview}])}

  def handle_async({:preview, marker}, {:exit, _reason}, socket),
    do: {:noreply, push_previews(socket, [{marker, failed(marker)}])}

  # A CHANGE THAT DRAWS WHAT WAS DRAWN BEFORE SAYS SO, on the setting changed: whatever stops it — the
  # other settings, a component that draws nothing without its data — an author who saw nothing
  # happen is told rather than left to try again.
  defp compared(%{assigns: %{settings: %{marker: marker} = settings}} = socket, marker, preview) do
    unchanged =
      case settings do
        %{drawn: ^preview, changed: [_ | _] = changed} -> changed
        _drawn_otherwise -> []
      end

    assign(socket, :settings, %{settings | drawn: preview, changed: [], unchanged: unchanged})
  end

  defp compared(socket, _marker, _preview), do: socket

  # Every attribute, by part, that holds another value than it did.
  defp changed(before, tree), do: changed_at(before, tree, [])

  defp changed_at(%{attrs: was, parts: was_parts}, %{attrs: now, parts: now_parts}, path) do
    own =
      for name <- Enum.uniq(Map.keys(was) ++ Map.keys(now)),
          Map.get(was, name) != Map.get(now, name),
          do: {encode(path), to_string(name)}

    inside =
      was_parts
      |> Enum.zip(now_parts)
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{{kind, was_part}, {kind, now_part}}, i} when kind in [:component, :slot] ->
          changed_at(was_part, now_part, path ++ [i])

        _text_or_moved ->
          []
      end)

    own ++ inside
  end

  defp open_pending(socket, tree, serial) do
    case listed(socket.assigns.components, tree.name) do
      %{} -> open_settings(socket, tree, serial)
      nil -> assign(socket, open?: true, notice: refused(tree.name))
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
    |> styles()
    |> assign(components: AsyncResult.loading(), loaded_for: site_id, blocks: [])
    |> MishkaGervaz.Messages.start_async(:components, fn ->
      with {:ok, entries} <- ContentComponents.palette(user, site_id) do
        {:ok, {entries, ContentBlocks.available(entries, site_id, user)}}
      end
    end)
  end

  defp close(socket),
    do: assign(socket, open?: false, notice: nil, query: "", category: "all", pending: nil)

  defp refuse(socket, name) do
    message = refused(name)
    {:reply, %{error: message}, assign(socket, open?: true, notice: message)}
  end

  defp listed(%AsyncResult{ok?: true, result: entries}, name) when is_binary(name),
    do: Enum.find(entries, &(&1.name == name))

  defp listed(_components, _name), do: nil

  defp entries(%AsyncResult{ok?: true, result: entries}), do: Map.new(entries, &{&1.name, &1})
  defp entries(_components), do: %{}

  # A component from the palette: only the attributes it declares, and an empty entry for each slot
  # it requires, so it is drawn as soon as those are filled.
  # Placed as it is, a component arrives as it says it does; given attributes or text, it is built
  # around them.
  defp built(entry, attrs, inner, entries) when attrs in [nil, %{}] and inner in [nil, ""],
    do: entry |> arriving(entries) |> ContentComponents.write()

  defp built(entry, attrs, inner, _entries) do
    tree = fresh(entry)
    inner = text(inner)

    parts =
      case inner do
        nil -> tree.parts
        html -> [{:text, html} | tree.parts]
      end

    ContentComponents.write(%{tree | attrs: declared(entry.attrs, attrs), parts: parts})
  end

  # A COMPONENT ARRIVES AS ITS KIT SAYS IT DOES WHEN DROPPED — its furnishing, what the page builder
  # places too — and empty when it says nothing. Placed empty, a heading or a timeline drew nothing at
  # all, and every setting changed on it changed nothing an author could see.
  defp arriving(entry, entries) do
    case ContentBlocks.plain(entry, entries) do
      [%{tree: tree}] -> tree
      [] -> fresh(entry)
    end
  end

  defp fresh(entry) do
    slots = for %{required: true} = slot <- entry.slots, do: {:slot, fresh_slot(slot)}
    %{name: entry.name, attrs: %{}, parts: slots}
  end

  defp fresh_slot(slot), do: %{name: slot.name, attrs: %{}, parts: []}

  # Only the attributes declared, as text a marker can hold.
  defp declared(attrs, %{} = given) do
    for %{name: name} <- attrs,
        value = Map.get(given, name),
        is_binary(value),
        into: %{},
        do: {name, value}
  end

  defp declared(_attrs, _given), do: %{}

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  defp refused(name),
    do: gettext("%{name} is not a component this site can place in content.", name: name)

  defp segment({:html, html}), do: %{type: "html", html: html}

  defp segment({:component, %{name: name, marker: marker}}),
    do: %{type: "component", name: name, marker: marker}

  # THE PREVIEWS ARE DRAWN WITH THE SITE'S STYLESHEET and every component its palette offers —
  # `ContentEditorStyles` — built in the background once per site, and the editor told where it is.
  # The admin's own stylesheet holds none of a kit's colours or variants. A record with no site is
  # previewed with the base every site starts from and the global components.
  defp styles(%{assigns: %{site_id: site_id, styles_for: site_id}} = socket), do: socket

  defp styles(socket) do
    %{current_user: user, site_id: site_id} = socket.assigns

    socket
    |> assign(styles_for: site_id)
    |> MishkaGervaz.Messages.start_async(:styles, fn -> stylesheet(user, site_id) end)
  end

  defp stylesheet(user, site_id) do
    with {:ok, entries} <- ContentComponents.palette(user, site_id),
         do: ContentEditorStyles.ensure(site_id, Enum.map(entries, & &1.name))
  end

  defp previews(socket, []), do: socket

  # EACH PREVIEW IN A TASK OF ITS OWN, so a component that raises as it is drawn takes down its own
  # preview and no other — drawn together, one such component left every block blank.
  defp previews(socket, markers) do
    %{site_id: site_id, current_user: user, editor: editor} = socket.assigns
    site = site_name(site_id)

    Enum.reduce(markers, socket, fn marker, socket ->
      MishkaGervaz.Messages.start_async(socket, {:preview, marker}, fn ->
        :ok = Translations.put_site(site_id)
        preview(marker, site, user, editor)
      end)
    end)
  end

  # What a block shows when its component raised as it was drawn: the page would fail the same way.
  defp failed(marker) do
    name =
      case ContentComponents.read(marker) do
        {:ok, %{name: name}} -> name
        :error -> ""
      end

    message =
      gettext(
        "%{name} could not be drawn with these settings, and the page would fail on it too — change its settings, or remove it.",
        name: name
      )

    ~s(<span data-role="content-component-unavailable" class="#{ContentComponents.unavailable_class()}">) <>
      (message |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()) <> "</span>"
  end

  # Drawn as the record's site draws it — the task answers for that site — and scrubbed after,
  # because it is shown inside the admin: no script, no event attribute and no `phx-` binding
  # reaches the editor.
  defp preview(marker, site, user, editor) do
    %{html: marked(marker), site: site, current_user: user, id: editor <> "-preview"}
    |> ContentComponents.draw(:static)
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
    |> ContentPreviewScrubber.sanitize()
  end

  # THE PARTS A PREVIEW DRAWS ARE MARKED, for the editor to find each one on the block — to move it
  # there (`"reorder"`), or drop a component between them (`"nest"`): an empty `mishka-part`
  # element before each part drawn where the component draws what it holds, `data-part` its place
  # as the settings write it, one ending each run of them (`data-end`), and one at the start of each
  # slot entry with content of its own, naming its slot (`data-slot`). A text that is only spacing
  # draws nothing and is not marked, and a component holding none is left as it is. The editor takes
  # the marks out before the preview is shown.
  defp marked(marker) do
    with {:ok, tree} <- ContentComponents.read(marker),
         written when is_binary(written) <- ContentComponents.write(marks(tree, [])) do
      written
    else
      _unreadable -> marker
    end
  end

  defp marks(%{parts: parts} = node, path) do
    placed = Enum.with_index(parts, fn part, i -> {part, path ++ [i]} end)
    run = for {part, at} <- placed, drawn_inline?(part), do: at

    marked =
      Enum.flat_map(placed, fn
        {{:slot, slot}, at} -> [{:slot, entry_marks(slot, at)}]
        {{:component, child}, at} -> [mark(at), {:component, marks(child, at)}]
        {text, at} -> if(at in run, do: [mark(at), text], else: [text])
      end)

    case run do
      [] ->
        %{node | parts: marked}

      _drawn ->
        %{
          node
          | parts: marked ++ [{:text, ~s(<mishka-part data-end="#{encode(path)}"></mishka-part>)}]
        }
    end
  end

  defp entry_marks(%{parts: []} = slot, _at), do: slot

  defp entry_marks(slot, at) do
    %{parts: parts} = marks(slot, at)
    own = ~s(<mishka-part data-part="#{encode(at)}" data-slot="#{slot.name}"></mishka-part>)
    %{slot | parts: [{:text, own} | parts]}
  end

  defp mark(at), do: {:text, ~s(<mishka-part data-part="#{encode(at)}"></mishka-part>)}

  defp drawn_inline?({:component, _child}), do: true
  defp drawn_inline?({:text, text}), do: String.trim(text) != ""
  defp drawn_inline?(_slot), do: false

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

  ####################################################################################
  ############################ (▰˘◡˘▰) The tree (▰˘◡˘▰) #############################
  ####################################################################################

  # A place in the tree is the index of each part on the way to it, root first: `[]` is the
  # component itself, `[2, 0]` the first part of its third. In the form it is written `r-2-0`.
  defp encode(path), do: Enum.join(["r" | path], "-")

  defp decode(path) when is_binary(path) do
    case String.split(path, "-") do
      ["r" | indexes] -> Enum.flat_map(indexes, &index/1)
      _not_a_path -> [-1]
    end
  end

  defp index(text) do
    case Integer.parse(text) do
      {n, ""} when n >= 0 -> [n]
      _not_an_index -> [-1]
    end
  end

  defp part_at(tree, []), do: {:component, tree}
  defp part_at(%{parts: parts}, [i]), do: at(parts, i)

  defp part_at(%{parts: parts}, [i | rest]) do
    case at(parts, i) do
      {kind, %{parts: _} = inner} when kind in [:component, :slot] -> part_at(inner, rest)
      _not_a_container -> nil
    end
  end

  defp at(parts, i) when i >= 0, do: Enum.at(parts, i)
  defp at(_parts, _i), do: nil

  # `fun` on the part at `path`; a path that leads nowhere changes nothing.
  defp update_part(tree, [], fun) do
    case fun.({:component, tree}) do
      {:component, updated} -> updated
      _refused -> tree
    end
  end

  defp update_part(%{parts: parts} = container, [i | rest], fun) do
    case at(parts, i) do
      nil ->
        container

      part when rest == [] ->
        %{container | parts: List.replace_at(parts, i, fun.(part))}

      {kind, %{parts: _} = inner} when kind in [:component, :slot] ->
        %{container | parts: List.replace_at(parts, i, {kind, update_part(inner, rest, fun)})}

      _not_a_container ->
        container
    end
  end

  defp put_attrs(tree, path, values) do
    update_part(tree, path, fn
      {kind, %{attrs: attrs} = node} when kind in [:component, :slot] ->
        {kind, %{node | attrs: merged(attrs, values)}}

      other ->
        other
    end)
  end

  defp merged(attrs, values) do
    Enum.reduce(values, attrs, fn
      {key, ""}, attrs -> Map.delete(attrs, key)
      {key, value}, attrs when is_binary(value) -> Map.put(attrs, key, value)
      _not_text, attrs -> attrs
    end)
  end

  defp put_text(tree, path, text) when is_binary(text) do
    update_part(tree, path, fn
      {:text, _old} -> {:text, html_of(text)}
      other -> other
    end)
  end

  defp put_text(tree, _path, _text), do: tree

  defp add_part(tree, path, part) do
    update_part(tree, path, fn
      {kind, %{parts: parts} = node} when kind in [:component, :slot] ->
        {kind, %{node | parts: parts ++ [part]}}

      other ->
        other
    end)
  end

  defp remove_part(tree, path) do
    {parent, [i]} = Enum.split(path, -1)

    update_part(tree, parent, fn
      {kind, %{parts: parts} = node} when kind in [:component, :slot] and i >= 0 ->
        {kind, %{node | parts: List.delete_at(parts, i)}}

      other ->
        other
    end)
  end

  # The part at `path` taken out and put at `to` among its siblings — after the one there when it
  # moves down, before it when it moves up.
  defp move_part(tree, path, to) do
    {parent, [i]} = Enum.split(path, -1)

    update_part(tree, parent, fn
      {kind, %{parts: parts} = node} when kind in [:component, :slot] ->
        case i >= 0 and to >= 0 and to < length(parts) and i < length(parts) do
          true ->
            {part, rest} = List.pop_at(parts, i)
            {kind, %{node | parts: List.insert_at(rest, to, part)}}

          false ->
            {kind, node}
        end

      other ->
        other
    end)
  end

  # Where a move by one takes the part at `path`: beside the nearest part shown that way, passing
  # over a text that is only spacing, which the drawer does not show; `nil` when there is none.
  defp beside(tree, path, by) do
    with {parent, [i]} <- Enum.split(path, -1),
         {kind, %{parts: parts}} when kind in [:component, :slot] <- part_at(tree, parent) do
      parts
      |> Enum.with_index()
      |> Enum.filter(fn {part, j} -> (j - i) * by > 0 and shown?(part, parts) end)
      |> Enum.min_by(fn {_part, j} -> abs(j - i) end, fn -> {nil, nil} end)
      |> elem(1)
    else
      _nowhere -> nil
    end
  end

  # The values a form sent for the part at `path`, only for the attributes it declares.
  defp declared_values(tree, path, values, entries) when is_map(values) do
    names = for %{name: name} <- declared_attrs(tree, path, entries), do: name
    Map.take(values, names)
  end

  defp declared_values(_tree, _path, _values, _entries), do: %{}

  defp declared_attrs(tree, path, entries) do
    case part_at(tree, path) do
      {:component, %{name: name}} ->
        entries |> Map.get(name, %{attrs: []}) |> Map.fetch!(:attrs)

      {:slot, %{name: name}} ->
        case slot_of(tree, Enum.drop(path, -1), name, entries) do
          %{attrs: attrs} -> attrs
          nil -> []
        end

      _other ->
        []
    end
  end

  # The declaration of the slot `name` of the component at `path`.
  defp slot_of(tree, path, name, entries) do
    with {:component, %{name: component}} <- part_at(tree, path),
         %{slots: slots} <- Map.get(entries, component) do
      Enum.find(slots, &(&1.name == name))
    else
      _not_a_component -> nil
    end
  end

  # Whether what is at `path` draws content of its own — a component with an inner block, or a slot
  # its component renders — and so takes text and components.
  defp takes_content?(tree, path, entries) do
    case part_at(tree, path) do
      {:component, %{name: name}} ->
        match?(%{inner_block: true}, Map.get(entries, name))

      {:slot, %{name: name}} ->
        match?(%{inner: true}, slot_of(tree, Enum.drop(path, -1), name, entries))

      _nothing_there ->
        false
    end
  end

  # A component that takes text gets a box for it even when it holds none yet, and so does a slot
  # whose content is drawn.
  defp writable(%{name: name, parts: parts} = tree, entries) do
    entry = Map.get(entries, name)

    parts =
      Enum.map(parts, fn
        {:component, child} -> {:component, writable(child, entries)}
        {:slot, slot} -> {:slot, writable_slot(slot, entry)}
        text -> text
      end)

    %{tree | parts: with_text(parts, match?(%{inner_block: true}, entry))}
  end

  defp writable_slot(slot, %{slots: declared}) do
    case Enum.find(declared, &(&1.name == slot.name)) do
      %{inner: true} -> %{slot | parts: with_text(slot.parts, true)}
      _no_content -> slot
    end
  end

  defp writable_slot(slot, _entry), do: slot

  defp with_text([], true), do: [{:text, ""}]
  defp with_text(parts, _takes_text), do: parts

  # A FILE'S KIND COMES WITH IT. A `src` chosen beside a `type` — a video's `source` requires both —
  # takes the kind its file name says, `video/webm` for a `.webm`, so the two always agree.
  defp kind_of(tree, %{path: path, attr: "src"}, url, entries) do
    case Enum.any?(declared_attrs(tree, path, entries), &(&1.name == "type")) do
      true -> %{"type" => MIME.from_path(url)}
      false -> %{}
    end
  end

  defp kind_of(_tree, _target, _url, _entries), do: %{}

  defp accepts(tree, path, attr) do
    names =
      for n <- 0..length(path),
          {kind, %{name: name}} <- [part_at(tree, Enum.take(path, n))],
          kind in [:component, :slot],
          do: name

    case attr in ["src"] and Enum.any?(names, &(&1 =~ ~r/video|audio|source|track/)) do
      true -> :videos
      false -> :images
    end
  end

  ####################################################################################
  ############################ (▰˘◡˘▰) Labels (▰˘◡˘▰) ###############################
  ####################################################################################

  # A component's name without the kit's word all its components share — "chelekom-card-title" is
  # "Card title" — the full name shown beside it.
  defp label(name, prefixes) do
    words = String.split(name, "-")

    words =
      case words do
        [head | [_ | _] = rest] -> (MapSet.member?(prefixes, head) && rest) || words
        _single -> words
      end

    words |> Enum.join(" ") |> String.capitalize()
  end

  defp prefixes(entries) do
    entries
    |> Enum.map(&(&1.name |> String.split("-") |> hd()))
    |> Enum.frequencies()
    |> Enum.filter(fn {_prefix, count} -> count >= 3 end)
    |> MapSet.new(fn {prefix, _count} -> prefix end)
  end

  defp matching(items, query, words_of) do
    case query |> String.downcase() |> String.split() do
      [] -> items
      words -> Enum.filter(items, fn item -> found?(words_of.(item), words) end)
    end
  end

  defp found?(text, words), do: Enum.all?(words, &String.contains?(text, &1))

  defp component_words(entry, prefixes) do
    [
      entry.name,
      label(entry.name, prefixes),
      entry.description || "",
      ContentComponents.category_label(entry.category),
      entry.category
    ]
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp block_words(block, prefixes) do
    [
      block.id,
      block.title,
      block.component,
      label(block.component, prefixes),
      ContentComponents.category_label(block.category)
    ]
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp grouped(items, category_of) do
    groups = Enum.group_by(items, category_of)

    for category <- ContentComponents.sort_categories(Map.keys(groups)),
        do: {category, Map.fetch!(groups, category)}
  end

  defp configurable?(entry), do: entry.attrs != [] or entry.inner_block or entry.slots != []

  ####################################################################################
  ############################ (▰˘◡˘▰) Render (▰˘◡˘▰) ###############################
  ####################################################################################

  @impl true
  def render(assigns) do
    palette = (assigns.components.ok? && assigns.components.result) || []

    assigns =
      assign(assigns,
        detached: assigns.id <> "-detached",
        prefixes: prefixes(palette),
        entries: entries(assigns.components)
      )

    ~H"""
    <div id={@id} data-role="content-editor-components" class="contents">
      <div
        :if={@open?}
        id={@id <> "-panel"}
        data-role="content-editor-panel"
        class="absolute end-2 top-[46px] z-30 flex max-h-[min(80vh,600px)] w-[400px] max-w-[calc(100%-1rem)] flex-col rounded-[16px] border border-[#ecebe6] bg-white p-3.5 shadow-[0_16px_40px_rgba(27,26,24,0.14)] [&>*:not(:last-child)]:flex-none"
      >
        <div class="flex items-center gap-2">
          <span class="min-w-0 flex-1 truncate text-[14px] font-bold text-[#1b1a18]">
            {gettext("Add to the content")}
          </span>
          <button
            type="button"
            id={@id <> "-close"}
            phx-click="close"
            phx-target={@myself}
            aria-label={gettext("Close")}
            class="flex size-8 items-center justify-center rounded-[9px] text-[#5c5a54] hover:bg-[#f6f5f2]"
          >
            <.icon name="hero-x-mark" class="size-[18px]" />
          </button>
        </div>

        <p
          :if={@notice}
          id={@id <> "-notice"}
          class="mt-2 rounded-[10px] bg-[#fbeef1] px-3 py-2 text-[12px] font-medium text-[#b5495f]"
        >
          {@notice}
        </p>

        <div
          role="tablist"
          aria-label={gettext("What to add")}
          class="mt-3 grid grid-cols-2 gap-1 rounded-[12px] bg-[#f4f3ef] p-1"
        >
          <button
            :for={
              {tab, text} <- [
                {"blocks", gettext("Ready blocks")},
                {"components", gettext("All components")}
              ]
            }
            type="button"
            role="tab"
            id={@id <> "-tab-" <> tab}
            aria-selected={to_string(@tab == tab)}
            data-active={@tab == tab}
            phx-click="tab"
            phx-value-tab={tab}
            phx-target={@myself}
            class="h-9 rounded-[9px] text-[12.5px] font-semibold text-[#6d6a63] data-[active]:bg-white data-[active]:text-[#1b1a18] data-[active]:shadow-[0_1px_3px_rgba(27,26,24,0.1)]"
          >
            {text}
          </button>
        </div>

        <div class="relative mt-3">
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute start-3.5 top-1/2 size-[18px] -translate-y-1/2 text-[#a8a49b]"
          />
          <input
            type="search"
            id={@id <> "-query"}
            form={@detached}
            value={@query}
            placeholder={
              (@tab == "blocks" && gettext("Search blocks")) || gettext("Search components")
            }
            autocomplete="off"
            phx-keyup="search"
            phx-target={@myself}
            phx-debounce="150"
            dir="auto"
            class={[
              "h-11 pe-11 ps-11 text-[14px] [&::-webkit-search-cancel-button]:hidden",
              field_class()
            ]}
          />
          <button
            :if={@query != ""}
            type="button"
            id={@id <> "-query-clear"}
            phx-click="search"
            phx-value-value=""
            phx-target={@myself}
            aria-label={gettext("Clear the search")}
            class="absolute end-2 top-1/2 flex size-8 -translate-y-1/2 items-center justify-center rounded-[8px] text-[#4f4bcc] hover:bg-[#f2f1fc]"
          >
            <.icon name="hero-x-mark-mini" class="size-[18px]" />
          </button>
        </div>

        <div
          :if={@tab == "components" and @components.ok?}
          id={@id <> "-categories"}
          class="mt-3 flex gap-1.5 overflow-x-auto pb-1 [scrollbar-width:thin]"
        >
          <button
            :for={
              category <- [
                "all" | ContentComponents.sort_categories(Enum.map(@components.result, & &1.category))
              ]
            }
            type="button"
            id={@id <> "-category-" <> category}
            data-active={@category == category}
            phx-click="category"
            phx-value-category={category}
            phx-target={@myself}
            class="h-7 flex-none rounded-[8px] border border-[#ecebe6] bg-white px-2.5 text-[11.5px] font-semibold text-[#6d6a63] hover:border-[#dcdbf5] data-[active]:border-[#dcdbf5] data-[active]:bg-[#f2f1fc] data-[active]:text-[#4f4bcc]"
          >
            {(category == "all" && gettext("All")) || ContentComponents.category_label(category)}
          </button>
        </div>

        <p class="mt-2 text-[11px] font-medium text-[#8a877f]">
          {gettext(
            "Click to place it at the cursor, or drag it into the text. Drop a component on a box to put it inside."
          )}
        </p>

        <.async_result :let={entries} assign={@components}>
          <:loading>
            <p class="mt-3 text-[12.5px] font-medium text-[#8a877f]">{gettext("Loading…")}</p>
          </:loading>
          <:failed>
            <p class="mt-3 text-[12.5px] font-medium text-[#b5495f]">
              {gettext("The components could not be read.")}
            </p>
          </:failed>

          <.blocks
            :if={@tab == "blocks"}
            id={@id}
            blocks={matching(@blocks, @query, &block_words(&1, @prefixes))}
            prefixes={@prefixes}
          />

          <.components
            :if={@tab == "components"}
            id={@id}
            entries={
              entries
              |> Enum.filter(&(@category == "all" or &1.category == @category))
              |> matching(@query, &component_words(&1, @prefixes))
            }
            prefixes={@prefixes}
          />
        </.async_result>
      </div>

      <.portal id={@id <> "-drawer-portal"} target="body">
        <.drawer
          :if={@settings}
          id={@id}
          editor={@editor}
          settings={@settings}
          entries={@entries}
          prefixes={@prefixes}
          site_id={@site_id}
          current_user={@current_user}
          myself={@myself}
        />
      </.portal>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :blocks, :list, required: true
  attr :prefixes, :any, required: true

  defp blocks(assigns) do
    ~H"""
    <div id={@id <> "-blocks"} class="mt-2 min-h-0 flex-1 overflow-y-auto">
      <section :for={{category, blocks} <- grouped(@blocks, & &1.category)} class="mb-3">
        <.heading text={ContentComponents.category_label(category)} count={length(blocks)} />
        <div class="grid grid-cols-2 gap-2">
          <button
            :for={block <- blocks}
            type="button"
            id={@id <> "-block-" <> block.id}
            draggable="true"
            data-block-card={block.id}
            class="flex cursor-grab flex-col items-start gap-1 rounded-[12px] border border-[#ecebe6] bg-white px-3 py-2.5 text-start hover:border-[#c3c1f0] hover:bg-[#faf9ff] active:cursor-grabbing"
          >
            <span class="text-[12.5px] font-semibold text-[#1b1a18]">
              {block.title || label(block.component, @prefixes)}
            </span>
            <span class="line-clamp-2 text-[11px] font-medium leading-[1.4] text-[#8a877f]">
              {(block.title && label(block.component, @prefixes)) || gettext("Plain, to fill in")}
            </span>
          </button>
        </div>
      </section>

      <p :if={@blocks == []} class="mt-3 text-[12.5px] font-medium text-[#8a877f]">
        {gettext("No block matches — try All components.")}
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :entries, :list, required: true
  attr :prefixes, :any, required: true

  defp components(assigns) do
    ~H"""
    <div id={@id <> "-list"} class="mt-2 min-h-0 flex-1 overflow-y-auto">
      <section :for={{category, entries} <- grouped(@entries, & &1.category)} class="mb-3">
        <.heading text={ContentComponents.category_label(category)} count={length(entries)} />
        <ul class="flex flex-col gap-0.5">
          <li :for={entry <- entries}>
            <button
              type="button"
              id={@id <> "-pick-" <> entry.name}
              draggable="true"
              data-component-card={entry.name}
              data-configurable={to_string(configurable?(entry))}
              class="flex w-full cursor-grab flex-col items-start gap-0.5 rounded-[10px] px-2.5 py-2 text-start hover:bg-[#f6f5f2] active:cursor-grabbing"
            >
              <span class="flex w-full items-center gap-1.5">
                <span class="text-[12.5px] font-semibold text-[#1b1a18]">
                  {label(entry.name, @prefixes)}
                </span>
                <span
                  :if={entry.stateful}
                  class="rounded-full bg-[#eef1fc] px-1.5 text-[10px] font-bold text-[#4f4bcc]"
                >
                  {gettext("Keeps state")}
                </span>
                <span
                  :if={!entry.global}
                  class="rounded-full bg-[#fbf1df] px-1.5 text-[10px] font-bold text-[#8a5514]"
                >
                  {gettext("This site")}
                </span>
                <span dir="ltr" class="ms-auto truncate font-mono text-[10px] text-[#a8a49b]">
                  {entry.name}
                </span>
              </span>
              <span
                :if={entry.description}
                dir="auto"
                class="line-clamp-1 text-[11px] font-medium text-[#8a877f]"
              >
                {entry.description}
              </span>
            </button>
          </li>
        </ul>
      </section>

      <p :if={@entries == []} class="mt-3 text-[12.5px] font-medium text-[#8a877f]">
        {gettext("No component matches.")}
      </p>
    </div>
    """
  end

  attr :text, :string, required: true
  attr :count, :integer, required: true

  defp heading(assigns) do
    ~H"""
    <div class="mb-1.5 mt-1 flex items-center gap-2">
      <span class="text-[10.5px] font-bold uppercase tracking-[0.1em] text-[#6d6a63]">{@text}</span>
      <span class="h-px flex-1 bg-[#f0efea]"></span>
      <span class="text-[10px] font-semibold text-[#a8a49b]">{@count}</span>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :editor, :string, required: true
  attr :settings, :map, required: true
  attr :entries, :map, required: true
  attr :prefixes, :any, required: true
  attr :site_id, :string, default: nil
  attr :current_user, :any, default: nil
  attr :myself, :any, required: true

  defp drawer(assigns) do
    assigns = assign(assigns, :tree, assigns.settings.tree)

    ~H"""
    <aside
      id={@id <> "-drawer"}
      data-role="content-editor-drawer"
      data-editor={@editor}
      aria-label={gettext("Component settings")}
      class="fixed inset-y-0 end-0 z-[200] flex w-full max-w-[460px] flex-col border-s border-[#ecebe6] bg-white shadow-[-18px_0_44px_rgba(27,26,24,0.16)]"
    >
      <header class="flex items-center gap-3 border-b border-[#f0efea] px-4 py-3">
        <span class="grid size-9 flex-none place-items-center rounded-[10px] bg-[#f2f1fc] text-[#4f4bcc]">
          <.icon name="hero-adjustments-horizontal" class="size-[18px]" />
        </span>
        <div class="min-w-0 flex-1">
          <p class="truncate text-[14px] font-bold text-[#1b1a18]">{label(@tree.name, @prefixes)}</p>
          <p dir="ltr" class="truncate font-mono text-[10.5px] text-[#a8a49b]">{@tree.name}</p>
        </div>
        <button
          type="button"
          id={@id <> "-drawer-close"}
          phx-click="settings_done"
          phx-target={@myself}
          aria-label={gettext("Close")}
          class="flex size-9 items-center justify-center rounded-[10px] text-[#5c5a54] hover:bg-[#f6f5f2]"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </header>

      <div class="relative flex min-h-0 flex-1 flex-col">
        <form
          id={@id <> "-settings"}
          inert={@settings.media != nil}
          phx-change="settings_change"
          phx-submit="settings_done"
          phx-target={@myself}
          class="min-h-0 flex-1 overflow-y-auto px-4 py-4"
        >
          <.node_fields
            id={@id}
            path={[]}
            tree={@tree}
            entries={@entries}
            prefixes={@prefixes}
            adding={@settings.adding}
            adding_query={@settings.adding_query}
            unchanged={@settings.unchanged}
            myself={@myself}
          />
        </form>

        <footer
          inert={@settings.media != nil}
          class="flex items-center gap-3 border-t border-[#f0efea] px-4 py-3"
        >
          <span class="min-w-0 flex-1 text-[11px] font-medium text-[#8a877f]">
            {gettext("Changes show in the editor as you type.")}
          </span>
          <button
            type="submit"
            form={@id <> "-settings"}
            id={@id <> "-drawer-done"}
            class="h-9 rounded-[10px] bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] px-5 text-[12.5px] font-bold text-white"
          >
            {gettext("Done")}
          </button>
        </footer>

        <div :if={@settings.media} class="absolute inset-0 flex flex-col bg-white">
          <.live_component
            module={ContentMediaChooser}
            id={@id <> "-media"}
            target={@id}
            site_id={@site_id}
            current_user={@current_user}
            accepts={@settings.media.accepts}
          />
        </div>
      </div>
    </aside>
    """
  end

  attr :id, :string, required: true
  attr :path, :list, required: true
  attr :tree, :map, required: true
  attr :entries, :map, required: true
  attr :prefixes, :any, required: true
  attr :adding, :string, default: nil
  attr :adding_query, :string, default: ""
  attr :unchanged, :list, default: []
  attr :myself, :any, required: true

  # One component's settings: its attributes, then what it holds.
  defp node_fields(assigns) do
    entry = Map.get(assigns.entries, assigns.tree.name)

    assigns =
      assign(assigns,
        entry: entry,
        key: encode(assigns.path),
        root: assigns.path == [],
        holds: !!entry and (entry.inner_block or entry.slots != [])
      )

    ~H"""
    <section
      id={@id <> "-node-" <> @key}
      data-content-node={@key}
      data-content-part={!@root && @key}
      data-name={@tree.name}
      phx-mounted={!@root && JS.ignore_attributes(["data-collapsed"])}
      class={[
        "flex flex-col gap-3",
        !@root && ["rounded-[12px] border border-[#ecebe6] bg-white p-3", collapsible()]
      ]}
    >
      <.part_head
        :if={!@root}
        id={@id}
        key={@key}
        section={@id <> "-node-" <> @key}
        title={label(@tree.name, @prefixes)}
        name={@tree.name}
        hint={hint(@tree, @entry)}
        myself={@myself}
      />

      <div data-part="body" class="flex flex-col gap-3">
        <p
          :if={!@entry}
          class="rounded-[10px] bg-[#fbeef1] px-3 py-2 text-[11.5px] font-medium text-[#b5495f]"
        >
          {refused(@tree.name)}
        </p>

        <.attr_fields
          :if={@entry}
          id={@id}
          key={@key}
          attrs={@entry.attrs}
          values={@tree.attrs}
          entry={@entry}
          unchanged={@unchanged}
          myself={@myself}
        />

        <div :if={@holds} class="flex flex-col gap-2">
          <p class="text-[10.5px] font-bold uppercase tracking-[0.1em] text-[#8a877f]">
            {gettext("Inside it")}
          </p>

          <.parts id={@id} key={@key} gap="gap-2" any?={@tree.parts != []}>
            <.part_fields
              :for={{part, i} <- Enum.with_index(@tree.parts)}
              :if={shown?(part, @tree.parts)}
              id={@id}
              path={@path ++ [i]}
              part={part}
              parent={@entry}
              entries={@entries}
              prefixes={@prefixes}
              adding={@adding}
              adding_query={@adding_query}
              unchanged={@unchanged}
              myself={@myself}
            />
          </.parts>

          <div class="flex flex-wrap gap-1.5">
            <.add_button
              :if={@entry.inner_block}
              id={@id <> "-add-text-" <> @key}
              text={gettext("Text")}
              values={%{"path" => @key, "kind" => "text"}}
              myself={@myself}
            />
            <button
              :if={@entry.inner_block}
              type="button"
              id={@id <> "-add-component-" <> @key}
              phx-click={(@adding == @key && "child_close") || "child_open"}
              phx-value-path={@key}
              phx-target={@myself}
              class="inline-flex h-8 items-center gap-1 rounded-[9px] border border-[#dcdbf5] bg-[#f7f6fe] px-2.5 text-[11.5px] font-semibold text-[#4f4bcc] hover:bg-[#efeefb]"
            >
              <.icon name="hero-plus-mini" class="size-4" />{gettext("Component")}
            </button>
            <.add_button
              :for={slot <- @entry.slots}
              id={@id <> "-add-slot-" <> @key <> "-" <> slot.name}
              text={Inspector.label(slot.name)}
              values={%{"path" => @key, "kind" => "slot", "name" => slot.name}}
              myself={@myself}
            />
          </div>

          <.child_picker
            :if={@adding == @key}
            id={@id}
            key={@key}
            parent={@tree.name}
            entries={@entries}
            prefixes={@prefixes}
            query={@adding_query}
            myself={@myself}
          />
        </div>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :path, :list, required: true
  attr :part, :any, required: true
  attr :parent, :map, default: nil
  attr :entries, :map, required: true
  attr :prefixes, :any, required: true
  attr :adding, :string, default: nil
  attr :adding_query, :string, default: ""
  attr :unchanged, :list, default: []
  attr :myself, :any, required: true

  defp part_fields(%{part: {:text, text}} = assigns) do
    assigns = assign(assigns, text: text, key: encode(assigns.path))

    ~H"""
    <div data-content-part={@key} class="flex items-start gap-1.5">
      <textarea
        id={@id <> "-text-" <> @key}
        name={"t[" <> @key <> "]"}
        rows="2"
        dir="auto"
        phx-debounce="300"
        placeholder={gettext("Text")}
        class={["min-h-[2.75rem] py-2", field_class()]}
      >{lines_of(@text)}</textarea>
      <.part_actions id={@id} key={@key} myself={@myself} />
    </div>
    """
  end

  defp part_fields(%{part: {:component, tree}} = assigns) do
    assigns = assign(assigns, :tree, tree)

    ~H"""
    <.node_fields
      id={@id}
      path={@path}
      tree={@tree}
      entries={@entries}
      prefixes={@prefixes}
      adding={@adding}
      adding_query={@adding_query}
      unchanged={@unchanged}
      myself={@myself}
    />
    """
  end

  defp part_fields(%{part: {:slot, slot}} = assigns) do
    declared = assigns.parent && Enum.find(assigns.parent.slots, &(&1.name == slot.name))

    assigns =
      assign(assigns, slot: slot, declared: declared, key: encode(assigns.path))

    ~H"""
    <section
      id={@id <> "-slot-" <> @key}
      data-content-slot={@key}
      data-content-part={@key}
      data-name={@slot.name}
      phx-mounted={JS.ignore_attributes(["data-collapsed"])}
      class={[
        "flex flex-col gap-3 rounded-[12px] border border-dashed border-[#d9d7f3] bg-[#fbfbff] p-3",
        collapsible()
      ]}
    >
      <.part_head
        id={@id}
        key={@key}
        section={@id <> "-slot-" <> @key}
        title={Inspector.label(@slot.name)}
        name={@declared && @declared.doc}
        hint={hint(@slot, @declared)}
        myself={@myself}
      />
      <div data-part="body" class="flex flex-col gap-3">
        <.attr_fields
          :if={@declared}
          id={@id}
          key={@key}
          attrs={@declared.attrs}
          values={@slot.attrs}
          unchanged={@unchanged}
          myself={@myself}
        />
        <.parts id={@id} key={@key} gap="gap-3" any?={@slot.parts != []}>
          <.part_fields
            :for={{part, i} <- Enum.with_index(@slot.parts)}
            :if={shown?(part, @slot.parts)}
            id={@id}
            path={@path ++ [i]}
            part={part}
            entries={@entries}
            prefixes={@prefixes}
            adding={@adding}
            adding_query={@adding_query}
            unchanged={@unchanged}
            myself={@myself}
          />
        </.parts>
      </div>
    </section>
    """
  end

  defp part_fields(assigns), do: ~H""

  attr :id, :string, required: true
  attr :key, :string, required: true
  attr :gap, :string, required: true
  attr :any?, :boolean, required: true
  slot :inner_block, required: true

  # THE PARTS ONE PART HOLDS, in their order, dragged by their grips to another place among
  # themselves (`ContentParts` in the admin's hooks), which sends `part_move` with the part dropped
  # beside.
  defp parts(assigns) do
    ~H"""
    <div
      :if={@any?}
      id={@id <> "-parts-" <> @key}
      phx-hook="ContentParts"
      data-target={"#" <> @id}
      class={["flex flex-col", @gap]}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  # A text between the components a part holds that is only spacing is not shown; text standing
  # alone is, and an empty one — a box just added — always is.
  defp shown?({:text, text}, parts),
    do: text == "" or String.trim(text) != "" or Enum.all?(parts, &match?({:text, _}, &1))

  defp shown?(_part, _parts), do: true

  attr :id, :string, required: true
  attr :key, :string, required: true
  attr :section, :string, required: true
  attr :title, :string, required: true
  attr :name, :string, default: nil
  attr :hint, :string, default: nil
  attr :myself, :any, required: true

  # A part's head: a button folding the part away and opening it again — in the browser alone, kept
  # through the server's updates — its name and what it says, and its moves.
  defp part_head(assigns) do
    ~H"""
    <div data-part="head" class="flex items-center gap-1.5">
      <button
        type="button"
        data-part="fold"
        phx-click={JS.toggle_attribute({"data-collapsed", "true"}, to: "#" <> @section)}
        aria-label={gettext("Fold or open")}
        title={gettext("Fold or open")}
        class="flex size-7 flex-none items-center justify-center rounded-[8px] text-[#8a877f] hover:bg-[#f2f1ec] hover:text-[#3a382f]"
      >
        <.icon name="hero-chevron-down-mini" class="size-4 transition-transform" />
      </button>
      <div class="min-w-0 flex-1">
        <p class="truncate text-[12.5px] font-bold text-[#3a382f]">
          {@title}<span :if={@hint} dir="auto" class="font-medium text-[#8a877f]"> · {@hint}</span>
        </p>
        <p :if={@name} dir="auto" class="truncate text-[10.5px] font-medium text-[#a8a49b]">
          {@name}
        </p>
      </div>
      <.part_actions id={@id} key={@key} myself={@myself} />
    </div>
    """
  end

  # A folded part shows its head alone, its arrow turned.
  defp collapsible,
    do: [
      "[&[data-collapsed]>[data-part=body]]:hidden",
      "[&[data-collapsed]>[data-part=head]_[data-part=fold]>span]:-rotate-90"
    ]

  # WHAT A FOLDED PART SAYS: the first Content attribute it fills in, else the first of its words.
  defp hint(%{attrs: attrs, parts: parts}, declared) do
    filled =
      for %{name: name, group: "Content"} <- (declared && declared.attrs) || [],
          value = Map.get(attrs, name),
          is_binary(value),
          String.trim(value) != "",
          do: value

    words = for {:text, text} <- parts, words = plain(text), words != "", do: words

    case filled ++ words do
      [first | _] -> String.slice(first, 0, 40)
      [] -> nil
    end
  end

  defp plain(html),
    do: html |> String.replace(~r/<[^>]*>/, " ") |> String.split() |> Enum.join(" ")

  # A TEXT BOX HOLDS LINES; the content holds HTML. Each `<br>` is a line in the box, and each line
  # typed there is a `<br>` in the content.
  defp lines_of(text), do: String.replace(text, ~r{<br\s*/?>}i, "\n")

  defp html_of(text), do: text |> String.replace("\r\n", "\n") |> String.replace("\n", "<br>")

  attr :id, :string, required: true
  attr :key, :string, required: true
  attr :myself, :any, required: true

  defp part_actions(assigns) do
    ~H"""
    <div class="flex flex-none items-center">
      <span
        data-part="grip"
        title={gettext("Drag to move")}
        class="flex size-7 cursor-grab items-center justify-center rounded-[8px] text-[#a8a49b] hover:bg-[#f2f1ec] hover:text-[#3a382f] active:cursor-grabbing"
      >
        <.icon name="hero-bars-2-mini" class="size-4" />
      </span>
      <button
        :for={
          {by, icon, label} <- [
            {"-1", "hero-arrow-up-mini", gettext("Move up")},
            {"1", "hero-arrow-down-mini", gettext("Move down")}
          ]
        }
        type="button"
        phx-click="part_move"
        phx-value-path={@key}
        phx-value-by={by}
        phx-target={@myself}
        aria-label={label}
        title={label}
        class="flex size-7 items-center justify-center rounded-[8px] text-[#8a877f] hover:bg-[#f2f1ec] hover:text-[#3a382f]"
      >
        <.icon name={icon} class="size-4" />
      </button>
      <button
        type="button"
        id={@id <> "-remove-" <> @key}
        phx-click="part_remove"
        phx-value-path={@key}
        phx-target={@myself}
        aria-label={gettext("Remove")}
        title={gettext("Remove")}
        class="flex size-7 items-center justify-center rounded-[8px] text-[#8a877f] hover:bg-[#fbeef1] hover:text-[#b5495f]"
      >
        <.icon name="hero-trash-mini" class="size-4" />
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :values, :map, required: true
  attr :myself, :any, required: true

  defp add_button(assigns) do
    assigns =
      assign(assigns, :values, Enum.map(assigns.values, fn {k, v} -> {"phx-value-#{k}", v} end))

    ~H"""
    <button
      type="button"
      id={@id}
      phx-click="part_add"
      phx-target={@myself}
      class="inline-flex h-8 items-center gap-1 rounded-[9px] border border-[#ecebe6] bg-white px-2.5 text-[11.5px] font-semibold text-[#3a382f] hover:border-[#c3c1f0]"
      {@values}
    >
      <.icon name="hero-plus-mini" class="size-4" />{@text}
    </button>
    """
  end

  attr :id, :string, required: true
  attr :key, :string, required: true
  attr :parent, :string, required: true
  attr :entries, :map, required: true
  attr :prefixes, :any, required: true
  attr :query, :string, required: true
  attr :myself, :any, required: true

  # What can go inside: the parent's own parts first — `chelekom-card-title` for `chelekom-card` —
  # then every other component, searched by name.
  defp child_picker(assigns) do
    stem = assigns.parent <> "-"
    all = assigns.entries |> Map.values() |> Enum.sort_by(& &1.name)
    found = matching(all, assigns.query, &component_words(&1, assigns.prefixes))
    {suggested, others} = Enum.split_with(found, &String.starts_with?(&1.name, stem))

    assigns =
      assign(assigns,
        suggested: suggested,
        others: Enum.take(others, 40),
        more: Enum.count_until(others, 41) > 40
      )

    ~H"""
    <div
      id={@id <> "-children-" <> @key}
      class="flex flex-col gap-2 rounded-[12px] border border-[#ecebe6] bg-[#faf9f6] p-2.5"
    >
      <input
        type="search"
        id={@id <> "-children-query-" <> @key}
        form={@id <> "-detached"}
        value={@query}
        placeholder={gettext("Search components")}
        autocomplete="off"
        phx-keyup="child_query"
        phx-target={@myself}
        phx-debounce="150"
        dir="auto"
        class={["h-10", field_class()]}
      />
      <ul class="flex max-h-[240px] flex-col gap-0.5 overflow-y-auto">
        <li :for={
          {entry, suggested?} <- Enum.map(@suggested, &{&1, true}) ++ Enum.map(@others, &{&1, false})
        }>
          <button
            type="button"
            id={@id <> "-child-" <> @key <> "-" <> entry.name}
            phx-click="part_add"
            phx-value-path={@key}
            phx-value-kind="component"
            phx-value-name={entry.name}
            phx-target={@myself}
            class="flex w-full items-center gap-1.5 rounded-[8px] px-2 py-1.5 text-start hover:bg-white"
          >
            <span class="text-[12px] font-semibold text-[#1b1a18]">{label(entry.name, @prefixes)}</span>
            <span
              :if={suggested?}
              class="rounded-full bg-[#f2f1fc] px-1.5 text-[10px] font-bold text-[#4f4bcc]"
            >
              {gettext("Goes here")}
            </span>
            <span dir="ltr" class="ms-auto truncate font-mono text-[10px] text-[#a8a49b]">
              {entry.name}
            </span>
          </button>
        </li>
      </ul>
      <p :if={@more} class="text-[10.5px] font-medium text-[#8a877f]">
        {gettext("Search to find more.")}
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :key, :string, required: true
  attr :attrs, :list, required: true
  attr :values, :map, required: true
  attr :entry, :map, default: nil
  attr :unchanged, :list, default: []
  attr :myself, :any, required: true

  # THE ATTRIBUTES UNDER THE PAGE BUILDER'S HEADINGS. What an author fills in — Content, a picture or
  # a video, anything required — stands open; every other heading is folded, in the builder's order.
  defp attr_fields(assigns) do
    {main, more} =
      Enum.split_with(assigns.attrs, &(&1.required or &1.media or &1.group == "Content"))

    groups = Enum.group_by(more, & &1.group)

    more =
      for group <- Inspector.groups() ++ (Map.keys(groups) -- Inspector.groups()),
          attrs = Map.get(groups, group),
          do: {group, attrs}

    assigns = assign(assigns, main: main, more: more)

    ~H"""
    <div :if={@main != []} class="flex flex-col gap-2.5">
      <.attr_field
        :for={attr <- @main}
        id={@id}
        key={@key}
        attr={attr}
        value={value_of(@values, attr.name)}
        inert={@entry && ContentComponents.inert(@entry, attr.name, @values)}
        still={{@key, attr.name} in @unchanged}
        myself={@myself}
      />
    </div>
    <details
      :for={{group, attrs} <- @more}
      id={@id <> "-group-" <> @key <> "-" <> String.downcase(group)}
      data-group={group}
      phx-mounted={JS.ignore_attributes(["open"])}
      class="group rounded-[10px] border border-[#f0efea] px-3 py-2"
    >
      <summary class="cursor-pointer text-[11.5px] font-semibold text-[#6d6a63]">
        {Gettext.gettext(MishkaCmsCore.Gettext, group)}
        <span class="text-[#a8a49b]">({length(attrs)})</span>
      </summary>
      <div class="mt-2.5 flex flex-col gap-2.5">
        <.attr_field
          :for={attr <- attrs}
          id={@id}
          key={@key}
          attr={attr}
          value={value_of(@values, attr.name)}
          inert={@entry && ContentComponents.inert(@entry, attr.name, @values)}
          still={{@key, attr.name} in @unchanged}
          myself={@myself}
        />
      </div>
    </details>
    """
  end

  defp value_of(values, name) do
    case Map.get(values, name) do
      true -> "true"
      value when is_binary(value) -> value
      _unset -> ""
    end
  end

  attr :id, :string, required: true
  attr :key, :string, required: true
  attr :attr, :map, required: true
  attr :value, :string, required: true
  attr :inert, :map, default: nil
  attr :still, :boolean, default: false
  attr :myself, :any, required: true

  defp attr_field(assigns) do
    assigns =
      assign(assigns,
        field: "#{assigns.id}-f-#{assigns.key}-#{assigns.attr.name}",
        name: "a[#{assigns.key}][#{assigns.attr.name}]",
        media: assigns.attr.media
      )

    ~H"""
    <div class="flex flex-col gap-1">
      <label for={@field} class="text-[11.5px] font-semibold text-[#3a382f]">
        {Inspector.label(@attr.name)}<span :if={@attr.required} class="text-[#b5495f]"> *</span>
      </label>
      <div class="flex items-center gap-1.5">
        <.value_input id={@field} name={@name} attr={@attr} value={@value} />
        <button
          :if={@media}
          type="button"
          id={@field <> "-choose"}
          phx-click="media_open"
          phx-value-path={@key}
          phx-value-attr={@attr.name}
          phx-target={@myself}
          title={gettext("Choose from the media library")}
          class="inline-flex h-10 flex-none items-center gap-1 rounded-[10px] border border-[#dcdbf5] bg-[#f2f1fc] px-2.5 text-[11.5px] font-semibold text-[#4f4bcc] hover:bg-[#e9e7fb]"
        >
          <.icon name="hero-photo-mini" class="size-4" />{gettext("Choose")}
        </button>
      </div>
      <span
        :if={@inert}
        id={@field <> "-inert"}
        data-inert
        class="rounded-[8px] bg-[#fdf6e8] px-2 py-1 text-[10.5px] font-semibold text-[#9a6200]"
      >
        {inert_note(@inert)}
      </span>
      <span
        :if={@still and !@inert}
        id={@field <> "-still"}
        data-still
        class="rounded-[8px] bg-[#f2f1ec] px-2 py-1 text-[10.5px] font-semibold text-[#6d6a63]"
      >
        {gettext("That made no visible difference with the other settings as they are.")}
      </span>
      <span :if={@attr.doc} dir="auto" class="text-[10.5px] font-medium text-[#8a877f]">
        {@attr.doc}
      </span>
    </div>
    """
  end

  # A SETTING THE OTHERS SWITCH OFF SAYS SO: chosen under the `base` variant, a colour draws nothing,
  # and an author changing it saw nothing change.
  defp inert_note(reason) do
    settings =
      Enum.map_join(reason, ", ", fn {attr, value} ->
        gettext("%{setting} is %{value}", setting: Inspector.label(attr), value: value || "—")
      end)

    gettext("No effect while %{settings} — choose another to use it.", settings: settings)
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :attr, :map, required: true
  attr :value, :string, required: true

  defp value_input(%{attr: %{values: [_ | _]}} = assigns) do
    ~H"""
    <div class="relative">
      <select
        id={@id}
        name={@name}
        class={["h-10 cursor-pointer appearance-none pe-9", field_class()]}
      >
        <option value="">{default_label(@attr)}</option>
        <option :for={value <- @attr.values} value={value} selected={to_string(value) == @value}>
          {value}
        </option>
      </select>
      <.select_chevron />
    </div>
    """
  end

  defp value_input(%{attr: %{type: "boolean"}} = assigns) do
    ~H"""
    <div class="relative">
      <select
        id={@id}
        name={@name}
        class={["h-10 cursor-pointer appearance-none pe-9", field_class()]}
      >
        <option value="">{default_label(@attr)}</option>
        <option value="true" selected={@value == "true"}>{gettext("Yes")}</option>
        <option value="false" selected={@value == "false"}>{gettext("No")}</option>
      </select>
      <.select_chevron />
    </div>
    """
  end

  defp value_input(%{attr: %{type: type}} = assigns) when type in ["integer", "float"] do
    assigns = assign(assigns, :step, (type == "integer" && "1") || "any")

    ~H"""
    <input
      type="number"
      id={@id}
      name={@name}
      value={@value}
      step={@step}
      placeholder={placeholder(@attr)}
      phx-debounce="300"
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
      name={@name}
      value={@value}
      placeholder={placeholder(@attr)}
      autocomplete="off"
      phx-debounce="300"
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
