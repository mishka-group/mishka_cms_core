defmodule MishkaCmsCoreWeb.Live.Admin.Components.MediaField do
  @moduledoc """
  A form's picture field: the address the record stores, a preview of it, and the site's media
  library under it — an upload dropped there, or a file chosen from it, fills the field. It is what
  `MishkaCmsCoreWeb.UIAdapters.Admin.text_input/1` draws for `ui do extra %{media: :images} end`,
  with `folder: "name"` naming the library folder its uploads are filed in.

  The address stays the form's field: it can still be typed, and saving reads it as any other. A
  pick reaches the Gervaz form as the combobox's does, a `combobox_select` pushed to the form from
  the browser, once the pick is drawn here. The library is
  `MishkaCmsCoreWeb.Live.Admin.Components.ContentMediaChooser`, the content editor's own, closed
  until it is asked for.

  `opened` is the count of the form it is in (`MishkaGervaz.Form.Web.State`): a form opened again
  drops a pick it has not taken, and draws the library closed again.

  Outside a Gervaz form — the Settings page — `select` is how a pick or a clear reaches the form:
  a function of the new address returning the `Phoenix.LiveView.JS` to run, and `library: false`
  leaves the library out, for a field with no site to take files from.

  It is its own component because it keeps which pick the form has yet to take.
  """
  use Phoenix.LiveComponent
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  alias MishkaCmsCoreWeb.Live.Admin.Components.ContentMediaChooser
  alias Phoenix.LiveView.JS

  @impl true
  def mount(socket),
    do: {:ok, assign(socket, pick: nil, picks: 0, opened: nil, select: nil, library: true)}

  @impl true
  def update(%{media: %{url: url}}, socket) when is_binary(url),
    do: {:ok, assign(socket, pick: url, picks: socket.assigns.picks + 1)}

  def update(%{media: _closed}, socket), do: {:ok, socket}

  def update(assigns, socket) do
    {:ok,
     socket
     |> start_over(assigns)
     |> assign(
       Map.take(assigns, [
         :id,
         :input_id,
         :name,
         :value,
         :field,
         :form,
         :site_id,
         :current_user,
         :accepts,
         :folder,
         :placeholder,
         :disabled,
         :debounce,
         :class,
         :opened,
         :select,
         :library
       ])
     )}
  end

  defp start_over(%{assigns: %{opened: seen}} = socket, %{opened: opened})
       when not is_nil(seen) and opened != seen,
       do: assign(socket, :pick, nil)

  defp start_over(socket, _assigns), do: socket

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        shown?: is_binary(assigns.value) and assigns.value != "",
        select:
          assigns.select ||
            (&JS.push("combobox_select",
               value: %{field: assigns.field, value: &1},
               target: assigns.form
             ))
      )

    ~H"""
    <div id={@id} data-role="media-field" class="flex min-w-0 flex-col gap-2">
      <div class="flex items-center gap-2">
        <span
          id={@id <> "-preview"}
          class="grid size-11 flex-none place-items-center overflow-hidden rounded-[10px] border border-[#ecebe6] bg-[#f6f5f2]"
        >
          <img :if={@shown?} src={@value} alt="" class="size-full object-cover" />
          <.icon :if={!@shown?} name="hero-photo" class="size-5 text-[#b3b0a8]" />
        </span>
        <input
          type="text"
          id={@input_id}
          name={@name}
          value={@value}
          placeholder={@placeholder}
          disabled={@disabled}
          phx-debounce={@debounce}
          dir="ltr"
          autocomplete="off"
          class={[@class, "min-w-0 flex-1"]}
        />
        <button
          :if={@shown? && !@disabled}
          type="button"
          id={@id <> "-clear"}
          phx-click={@select.("")}
          aria-label={gettext("Remove the picture")}
          title={gettext("Remove the picture")}
          class="flex size-9 flex-none items-center justify-center rounded-[10px] text-[#8a877f] hover:bg-[#fbeef1] hover:text-[#b5495f]"
        >
          <.icon name="hero-x-mark-mini" class="size-4" />
        </button>
      </div>

      <div
        :if={!@disabled && @library}
        class="flex min-w-0 flex-col rounded-[14px] border border-[#ecebe6] bg-white [&_[data-role=content-media-chooser]_ul]:max-h-[18rem]"
      >
        <.live_component
          module={ContentMediaChooser}
          id={@id <> "-library"}
          target={@id}
          notify={__MODULE__}
          site_id={@site_id}
          current_user={@current_user}
          accepts={@accepts}
          folder={@folder}
          library={:closed}
          back={false}
          in_form={true}
          opened={@opened}
        />
      </div>

      <span
        :if={@pick}
        id={"#{@id}-pick-#{@picks}"}
        hidden
        phx-mounted={@select.(@pick)}
      ></span>
    </div>
    """
  end
end
