defmodule MishkaCmsCore.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  Styling is plain Tailwind CSS only — style components with Tailwind utilities
  such as `flex`, `bg-*`, `rounded-*`, and `text-*`. Here are useful references:

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <%!-- IT GOES AWAY ON ITS OWN. A notice that waits to be clicked is a notice sitting over the
          thing you were about to click, and in an editor that is most of the screen — the Review
          sheet's own header, the top bar's buttons. `phx-mounted` starts the countdown when it
          appears and `hide/1` runs the same transition the click does, so dismissing early and
          waiting it out end the same way.

          Errors stay longer than confirmations: "Saved" is a nicety, "that element is gone" is
          something to read. --%>
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      phx-hook="FlashAutoDismiss"
      data-dismiss-after={(@kind == :error && 7000) || 4000}
      data-kind={@kind}
      role="alert"
      class="fixed end-4 top-4 z-50 w-80 sm:w-96"
      {@rest}
    >
      <div class={[
        "flex items-start gap-3 rounded-lg p-4 text-wrap shadow-lg ring-1",
        @kind == :info && "bg-emerald-50 text-emerald-800 ring-emerald-200",
        @kind == :error && "bg-red-50 text-red-800 ring-red-200"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div class="flex-1">
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <button
          type="button"
          class="group shrink-0 cursor-pointer self-start"
          aria-label={gettext("close")}
        >
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate="/">Home</.button>
      <.button variant="soft" icon="hero-trash">Remove</.button>

  `primary` is the page's one main action; `soft` is outlined, for the actions beside it; `accent`
  is tinted, for the one of those worth drawing the eye to. `icon` is a hero icon before the label.

  `type` is the button's HTML type. `"submit"` is what a button with no type already does, so it is
  not written into the markup.
  """
  attr :type, :string, default: "submit", values: ~w(button submit reset)
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :string
  attr :variant, :string, values: ~w(primary soft accent)
  attr :icon, :string, default: nil
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns =
      assign_new(assigns, :class, fn ->
        [
          "inline-flex h-[42px] items-center justify-center gap-2 rounded-xl px-[17px] text-[12.5px] font-bold ",
          "transition-opacity disabled:cursor-not-allowed disabled:opacity-60 ",
          button_variant(assigns[:variant])
        ]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        <.icon :if={@icon} name={@icon} class="size-4" />
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest} type={@type != "submit" && @type}>
        <.icon :if={@icon} name={@icon} class="size-4" />
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  The page's own "+ Add …" button, with the other ways of making one behind a caret beside it.

  THE MAIN HALF OPENS THE VISUAL EDITOR, because that is what making one usually means now: the
  editor asks for the two or three things a record cannot exist without and then shows the structure
  chooser. The long form — every field the resource declares — is still one click away under the
  caret, for the times somebody wants to fill it in.

  The menu is markup, shown by a JS command: nothing behind it needs the server, and a round trip to
  open a two-item list would be a round trip that changes nothing. Each item closes it, because a
  JS-shown element keeps a sticky `display` no later render can clear.

  ## Example

      <.create_menu
        id="add-page"
        label="+ Add Page"
        navigate="/admin/dashboard/runtime/builder/page"
        modal="page-form-modal"
      >
        <:way id="pb-create-form-page" label="Create with the full form" modal>
          Every field this resource has, on one form.
        </:way>
        <:way id="pb-create-open-page" label="Fill in the form, then open the editor" event="create_and_open">
          The same form, and the editor opens on what it saved.
        </:way>
      </.create_menu>

  A `:navigate` way is a link and leaves; an `:event` way pushes that event to THIS page and then
  opens the modal, so the page can remember what was asked for by the time the save arrives; a
  `modal` way just opens it.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :navigate, :string, required: true, doc: "where the main half goes — the visual editor"
  attr :modal, :string, required: true, doc: "the create modal the caret's items can open"

  slot :way, doc: "one other way to create, drawn under the caret" do
    attr :label, :string, required: true
    attr :modal, :boolean, doc: "the item opens the create modal"
    attr :event, :string, doc: "an event this page handles, and then the modal opens"
    attr :navigate, :string, doc: "a path — the item is a link and leaves"
    attr :id, :string
  end

  def create_menu(assigns) do
    assigns = assign(assigns, :menu, assigns.id <> "-ways")

    ~H"""
    <div class="relative flex w-fit" phx-click-away={JS.hide(to: "##{@menu}")}>
      <.button navigate={@navigate} class={create_menu_class(:main)}>{@label}</.button>
      <button
        type="button"
        id={@id <> "-toggle"}
        phx-click={JS.toggle(to: "##{@menu}")}
        phx-window-keydown={JS.hide(to: "##{@menu}")}
        phx-key="escape"
        title={gettext("Other ways to create this")}
        aria-haspopup="menu"
        class={create_menu_class(:caret)}
      >
        <svg
          width="12"
          height="12"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2.6"
          stroke-linecap="round"
          stroke-linejoin="round"
        >
          <path d="m6 9 6 6 6-6" />
        </svg>
      </button>

      <div id={@menu} role="menu" class={create_menu_class(:menu)}>
        <.create_way :for={way <- @way} way={way} menu={@menu} modal={@modal} />
      </div>
    </div>
    """
  end

  attr :way, :map, required: true
  attr :menu, :string, required: true
  attr :modal, :string, required: true

  # A LINK LEAVES, A BUTTON OPENS THE FORM. Either way the menu closes itself first: it was shown by
  # a JS command, so the sticky `display` it wrote outlives any later render.
  defp create_way(%{way: %{navigate: _}} = assigns) do
    ~H"""
    <.link
      id={@way[:id]}
      navigate={@way.navigate}
      phx-click={JS.hide(to: "##{@menu}")}
      class={create_menu_class(:item)}
    >
      <.create_way_text way={@way} />
    </.link>
    """
  end

  defp create_way(%{way: %{event: _}} = assigns) do
    ~H"""
    <button
      type="button"
      id={@way[:id]}
      phx-click={JS.hide(to: "##{@menu}") |> JS.push(@way.event) |> show_modal(@modal)}
      class={create_menu_class(:item)}
    >
      <.create_way_text way={@way} />
    </button>
    """
  end

  defp create_way(assigns) do
    ~H"""
    <button
      type="button"
      id={@way[:id]}
      phx-click={JS.hide(to: "##{@menu}") |> show_modal(@modal)}
      class={create_menu_class(:item)}
    >
      <.create_way_text way={@way} />
    </button>
    """
  end

  attr :way, :map, required: true

  defp create_way_text(assigns) do
    ~H"""
    <span class="block text-[12px] font-semibold text-[#1b1a18]">{@way.label}</span>
    <span class="mt-0.5 block text-[10.5px] font-medium leading-[1.45] text-[#6d6a63]">
      {render_slot(@way)}
    </span>
    """
  end

  defp create_menu_class(:main),
    do: create_menu_class(:base) <> " rounded-s-xl ps-[17px] pe-[15px]"

  defp create_menu_class(:base),
    do:
      "inline-flex h-[42px] items-center justify-center gap-2 text-[12.5px] font-bold transition-opacity " <>
        "border-none bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] text-white " <>
        "shadow-[0_5px_14px_rgba(79,75,204,0.28)] hover:opacity-95"

  defp create_menu_class(:caret),
    do:
      create_menu_class(:base) <>
        " grid w-8 flex-none place-items-center rounded-e-xl border-s border-white/25"

  defp create_menu_class(:menu),
    do:
      "absolute end-0 top-[50px] z-50 hidden w-[280px] max-w-[calc(100vw-2rem)] " <>
        "max-[560px]:start-0 max-[560px]:end-auto rounded-[13px] border border-[#ecebe6] " <>
        "bg-white p-1.5 text-start shadow-[0_18px_46px_rgba(20,18,26,.22)]"

  defp create_menu_class(:item),
    do: "block w-full rounded-[9px] p-[9px] text-start hover:bg-[#f6f5f2]"

  defp button_variant("soft"),
    do: "border border-[#ecebe6] bg-white text-[#5c5a54] hover:bg-[#f7f6f3]"

  defp button_variant("accent"),
    do: "border border-[#ded8f7] bg-[#f4f2fd] text-[#4f4bcc] hover:bg-[#eceafb]"

  defp button_variant(_),
    do:
      "border-none bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] text-white shadow-[0_5px_14px_rgba(79,75,204,0.28)] hover:opacity-95"

  @doc """
  A record's site in an admin list: a globe and "Global" for a record every site shares, a server
  and the site's name otherwise — the Site column the runtime lists draw.

      <MishkaCmsCore.CoreComponents.site_cell global?={is_nil(r.site_id)} name={r.site && r.site.name} />
  """
  attr :global?, :boolean, required: true
  attr :name, :string, default: nil

  def site_cell(assigns) do
    ~H"""
    <div class="flex items-center gap-[7px]">
      <svg
        :if={@global?}
        width="14"
        height="14"
        viewBox="0 0 24 24"
        fill="none"
        stroke="#7a5bd0"
        stroke-width="1.7"
        stroke-linecap="round"
        stroke-linejoin="round"
        class="shrink-0"
      >
        <circle cx="12" cy="12" r="9" />
        <path d="M3 12h18M12 3a15 15 0 0 1 0 18M12 3a15 15 0 0 0 0 18" />
      </svg>
      <svg
        :if={!@global?}
        width="14"
        height="14"
        viewBox="0 0 24 24"
        fill="none"
        stroke="#a8a5a0"
        stroke-width="1.7"
        stroke-linecap="round"
        stroke-linejoin="round"
        class="shrink-0"
      >
        <rect x="4" y="4" width="16" height="6" rx="1.5" />
        <rect x="4" y="14" width="16" height="6" rx="1.5" />
        <path d="M8 7h.01M8 17h.01" />
      </svg>
      <span class={[
        "text-[12.5px] font-medium",
        if(@global?, do: "text-[#6d4fc0]", else: "text-[#3a382f]")
      ]}>
        {if @global?, do: gettext("Global"), else: @name || gettext("Unknown")}
      </span>
    </div>
    """
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as hidden and radio,
  are best written directly in your templates.

  ## Examples

      <.input field={@form[:email]} type="email" />
      <.input name="my-input" errors={["oh no!"]} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :string, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :string, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="mb-2">
      <label>
        <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
        <span class="flex items-center gap-2">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "size-4 rounded border-gray-300"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="mb-2">
      <label>
        <span :if={@label} class="mb-1 block text-sm font-medium text-gray-700">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[
            @class || "w-full rounded-lg border border-gray-300 bg-white px-3 py-2 text-sm",
            @errors != [] && (@error_class || "border-red-500")
          ]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    assigns = put_input_dir(assigns)

    ~H"""
    <div class="mb-2">
      <label>
        <span :if={@label} class="mb-1 block text-sm font-medium text-gray-700">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full rounded-lg border border-gray-300 bg-white px-3 py-2 text-sm",
            @errors != [] && (@error_class || "border-red-500")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    assigns = put_input_dir(assigns)

    ~H"""
    <div class="mb-2">
      <label>
        <span :if={@label} class="mb-1 block text-sm font-medium text-gray-700">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full rounded-lg border border-gray-300 bg-white px-3 py-2 text-sm",
            @errors != [] && (@error_class || "border-red-500")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  defp put_input_dir(%{type: type} = assigns) do
    case input_dir(type) do
      nil -> assigns
      dir -> assign(assigns, :rest, Map.put_new(assigns.rest, :dir, dir))
    end
  end

  defp input_dir(type) when type in ~w(email url tel number password), do: "ltr"
  defp input_dir(type) when type in ~w(text search textarea), do: "auto"
  defp input_dir(_type), do: nil

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-red-600">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[
      @actions != [] &&
        "flex flex-wrap items-start justify-between gap-6 max-[560px]:flex-col!",
      "mb-[22px]"
    ]}>
      <div>
        <h1 class="m-0 font-['Newsreader'] text-[30px] font-medium leading-[1.05] tracking-[-0.01em] text-[#17161a]">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-[7px] text-[13.5px] font-medium text-[#7c7a75]">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div :if={@actions != []} class="flex-none max-[560px]:w-full!">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="w-full text-start text-sm">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="divide-y divide-gray-200">
      <li :for={item <- @item} class="flex items-center gap-4 py-2">
        <div class="flex-1">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ms-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  @doc """
  A short tip beside what it explains: a light amber box, a small speech-bubble glyph and small
  text. The builder's sheets, its SEO tab and a page's settings draw their notes with it.

  ## Examples

      <.tip id="pb-seo-record-note" class="mt-3">Each record fills what you leave empty.</.tip>
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def tip(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex items-start gap-2.5 rounded-[11px] border border-[#f0e3c9] bg-[#fdf8ef] px-3 py-2.5",
        @class
      ]}
    >
      <svg
        width="14"
        height="14"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.9"
        stroke-linecap="round"
        stroke-linejoin="round"
        class="mt-[1px] flex-none text-[#8a5514]"
        aria-hidden="true"
      >
        <path d="M4 5h16v9H4z M9 14l3 4 3-4" />
      </svg>
      <span class="min-w-0 flex-1 text-[10.5px] font-medium leading-[1.55] text-[#8a5514]">
        {render_slot(@inner_block)}
      </span>
    </div>
    """
  end

  @doc """
  Renders a modal dialog.

  ## Examples

      <.modal id="my-modal">
        Modal content
      </.modal>

      <.modal id="my-modal" show on_cancel={JS.navigate(~p"/")}>
        Modal content
      </.modal>

  Open programmatically: `JS.show(to: "#my-modal")`.
  Close programmatically: `JS.exec("data-cancel", to: "#my-modal")`.
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  attr :width_class, :string, default: "max-w-3xl"
  attr :padding_class, :string, default: "p-6"
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      data-cancel={JS.exec(@on_cancel, "phx-remove")}
      class="relative z-50 hidden"
    >
      <div
        id={"#{@id}-bg"}
        class="bg-black/50 fixed inset-0 transition-opacity"
        aria-hidden="true"
      />
      <div
        class="fixed inset-0 overflow-y-auto"
        aria-labelledby={"#{@id}-title"}
        aria-describedby={"#{@id}-description"}
        role="dialog"
        aria-modal="true"
        tabindex="0"
      >
        <div class="flex min-h-full items-center justify-center">
          <div class={["w-full p-4 sm:p-6 lg:py-8", @width_class]}>
            <.focus_wrap
              id={"#{@id}-container"}
              phx-window-keydown={JS.exec("data-cancel", to: "##{@id}")}
              phx-key="escape"
              phx-click-away={JS.exec("data-cancel", to: "##{@id}")}
              class={[
                "shadow-zinc-700/10 ring-zinc-700/10 relative hidden overflow-hidden rounded-2xl bg-white shadow-lg ring-1 transition",
                @padding_class
              ]}
            >
              <div class="absolute top-4 end-4">
                <button
                  phx-click={JS.exec("data-cancel", to: "##{@id}")}
                  type="button"
                  class="-m-3 flex-none p-3 opacity-50 hover:opacity-70"
                  aria-label={gettext("close")}
                >
                  <.icon name="hero-x-mark-solid" class="h-5 w-5" />
                </button>
              </div>
              <div id={"#{@id}-content"}>
                {render_slot(@inner_block)}
              </div>
            </.focus_wrap>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def show_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.show(to: "##{id}")
    |> JS.show(
      to: "##{id}-bg",
      time: 300,
      transition: {"transition-all ease-out duration-300", "opacity-0", "opacity-100"}
    )
    |> show("##{id}-container")
    |> JS.add_class("overflow-hidden", to: "body")
    |> JS.focus(to: "##{id}-container")
  end

  @doc """
  Shows the modal `id` with the Gervaz form inside it started over as an empty create form, the
  form's defaults kept — what an "Add" button runs that opens a form modal on the client. `form` is
  the form's resource, or its component id when the page mounts it under another one.

      <button phx-click={show_form_modal("post-form-modal", MyApp.Post)}>Add post</button>

  A page that opens the modal from the server sends the form `reset: true` instead — see
  `MishkaGervaz.Form.Web.Live`.
  """
  def show_form_modal(js \\ %JS{}, id, form) when is_binary(id) do
    js
    |> MishkaGervaz.Form.Web.Live.reset(form_component_id(form))
    |> show_modal(id)
  end

  defp form_component_id(id) when is_binary(id), do: id

  defp form_component_id(resource) when is_atom(resource),
    do: MishkaGervaz.Resource.Info.Form.component_id(resource)

  def hide_modal(js \\ %JS{}, id) do
    js
    |> JS.hide(
      to: "##{id}-bg",
      transition: {"transition-all ease-in duration-200", "opacity-100", "opacity-0"}
    )
    |> hide("##{id}-container")
    |> JS.hide(to: "##{id}", transition: {"block", "block", "hidden"})
    |> JS.remove_class("overflow-hidden", to: "body")
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(MishkaCmsCore.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(MishkaCmsCore.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end

  @doc """
  Whether a relationship or field holds a value a template can read through.

  A relationship nobody loaded is `%Ash.NotLoaded{}` and a field a policy hides is
  `%Ash.ForbiddenField{}` — structs, so both are truthy, and `:if={@record.site}` waves them past the
  guard the loaded record was meant to pass. The read behind it, `{@record.site.name}`, then raises
  and takes the LiveView with it. Ask this instead:

      <span :if={present?(@record.site)}>{@record.site.name}</span>
  """
  def present?(nil), do: false
  def present?(%Ash.NotLoaded{}), do: false
  def present?(%Ash.ForbiddenField{}), do: false
  def present?(_value), do: true
end
