# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Templates.SeoForm do
  @moduledoc """
  A MishkaGervaz custom form template, and the events its markup sends: the SEO tab of the builder's
  settings modal, over `MishkaCmsCore.Runtime.PageBuilder.SeoSettings`.

  A page's tab is two columns: on the left its basics, its structured data, the variables those may
  use and an Advanced section (the canonical address, every tag, the JSON-LD); on the right its
  previews — Google, X, Facebook — drawn with placeholders or with one of the records of the kind
  the page shows each address of, which its General tab picks. A layout's is its tags and the
  variables. Every field shows its default as its
  placeholder, and a blank one uses it. The chips at the foot put a variable where the caret last
  was in a field marked `data-seo-vars` — see the `PbSeoFields` hook, which also puts the share
  image a Media pick sends (`pb-seo-set`) into its field.

  ## The draft lives on the form's component

  The form opens on the record `SeoSettings` reads, which is the draft. Each edit is
  `SeoSettings.change/3` and lands on the component as `@seo`; Save sends `SeoSettings.params/1`
  through Gervaz's own save, and the editor closes the modal on `{:form_saved, :update, record}`.

  Cancel and Media name no `phx-target`: closing the modal and opening the Media sheet are the
  editor's.
  """

  use MishkaGervaz.Form.Behaviours.Template
  use MishkaGervaz.Form.Web.Events
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCoreWeb.Live.Admin.Builder.Panels, only: [icon: 1]

  alias MishkaCmsCore.Runtime.{Page, PageDraft, Seo}
  alias MishkaCmsCore.Runtime.PageBuilder.SeoSettings
  alias MishkaCmsCoreWeb.Live.Admin.Components.ShareCardField

  @impl true
  def name, do: :seo_settings

  @impl true
  def label, do: gettext("SEO")

  @impl true
  def icon, do: "hero-magnifying-glass"

  @impl true
  def render_loading(assigns) do
    ~H"""
    <div data-role="pb-seo-skeleton" class="px-6 pb-5 pt-4">
      <div class="h-[220px] animate-pulse rounded-[12px] bg-[#f7f6f3]"></div>
    </div>
    """
  end

  @impl true
  def render(%{state: %{form: nil}} = assigns), do: render_loading(assigns)

  def render(assigns) do
    assigns =
      assigns
      |> assign(:seo, assigns[:seo] || assigns.state.form.source.data)
      |> assign(:problems, problems(assigns.state))

    ~H"""
    <div id={@static.id <> "-form-wrapper"}>
      <.form
        for={%{}}
        as={:seo}
        id="pb-seo-form"
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
        phx-hook="PbSeoFields"
        class="px-6 pb-5 pt-4"
      >
        <div
          :if={@seo.mode == :page}
          class="grid gap-6 min-[980px]:grid-cols-[minmax(0,1fr)_380px]"
        >
          <div class="flex min-w-0 flex-col gap-5">
            <.seo_basics seo={@seo} target={@myself} />
            <.seo_schema seo={@seo} target={@myself} />
            <.seo_variables seo={@seo} />
            <.seo_advanced seo={@seo} target={@myself} />
          </div>
          <div class="min-w-0">
            <div class="flex flex-col gap-3 min-[980px]:sticky min-[980px]:top-4">
              <.seo_previews seo={@seo} target={@myself} />
              <.seo_share_card seo={@seo} />
            </div>
          </div>
        </div>

        <div :if={@seo.mode != :page} class="flex flex-col gap-5">
          <.seo_tag_list seo={@seo} target={@myself} />
          <.seo_variables seo={@seo} />
        </div>

        <div class="-mx-6 mt-5 flex items-center gap-2 border-t border-[#f0efea] px-6 pt-3.5">
          <p
            :if={@problems != []}
            id="pb-seo-errors"
            class="min-w-0 flex-1 text-[10.5px] font-semibold leading-[1.45] text-[#b5495f]"
          >
            {Enum.join(@problems, " ")}
          </p>
          <span :if={@problems == []} class="flex-1"></span>
          <button
            type="button"
            id="pb-seo-cancel"
            phx-click="close_settings"
            class="h-8 flex-none rounded-[9px] border border-[#ecebe6] bg-white px-3 text-[11.5px] font-semibold text-[#5c5a54] hover:bg-[#f6f5f2]"
          >
            {gettext("Cancel")}
          </button>
          <button
            type="submit"
            id="pb-seo-save"
            class="h-8 flex-none rounded-[9px] bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] px-3.5 text-[11.5px] font-bold text-white"
          >
            {gettext("Save")}
          </button>
        </div>
      </.form>
    </div>
    """
  end

  # A refused save: what no field shows, and what the fields show, since this form draws no error
  # under its own inputs but the JSON box's.
  defp problems(state),
    do: state.form_errors ++ (state.errors |> Map.values() |> List.flatten())

  @impl true
  def handle("validate", %{"seo" => params} = event, socket),
    do: edit(socket, &SeoSettings.change(&1, params, Map.get(event, "_target", [])))

  def handle("save", params, socket) do
    case draft(socket) do
      nil ->
        {:noreply, socket}

      seo ->
        seo = SeoSettings.typed(seo, Map.get(params, "seo", %{}))

        case seo.json_error do
          nil ->
            super("save", %{"form" => SeoSettings.params(seo)}, assign(socket, :seo, seo))

          # A component cannot put a flash, so the editor is asked to, as a Gervaz bulk action does.
          _mistake ->
            message = gettext("The JSON-LD has a mistake. Fix it before saving.")
            send(self(), {:put_flash, :error, message})
            {:noreply, assign(socket, :seo, SeoSettings.preview(seo))}
        end
    end
  end

  def handle("seo_add_tag", _params, socket), do: edit(socket, &SeoSettings.add_tag/1)

  def handle("seo_remove_tag", %{"index" => index}, socket),
    do: edit(socket, &SeoSettings.remove_tag(&1, index))

  def handle("seo_faq_add", _params, socket), do: edit(socket, &SeoSettings.add_question/1)

  def handle("seo_faq_remove", %{"index" => index}, socket),
    do: edit(socket, &SeoSettings.remove_question(&1, index))

  def handle("seo_advanced", _params, socket), do: edit(socket, &SeoSettings.toggle_advanced/1)

  def handle("seo_view", %{"view" => view}, socket),
    do: edit(socket, &SeoSettings.put_view(&1, view))

  def handle("seo_image_manual", _params, socket),
    do: edit(socket, &SeoSettings.toggle_image_manual/1)

  def handle("seo_image_clear", _params, socket), do: edit(socket, &SeoSettings.clear_image/1)

  def handle(event, params, socket), do: super(event, params, socket)

  defp edit(socket, change) do
    case draft(socket) do
      nil -> {:noreply, socket}
      seo -> {:noreply, assign(socket, :seo, change.(seo))}
    end
  end

  # The draft as edited, else as the form opened on it; nil until the record has loaded.
  defp draft(%{assigns: %{seo: %SeoSettings{} = seo}}), do: seo

  defp draft(%{assigns: %{form_state: %{form: %{source: %{data: %SeoSettings{} = seo}}}}}),
    do: seo

  defp draft(_socket), do: nil

  @seo_input "h-9 w-full min-w-0 rounded-[10px] border border-[#ecebe6] bg-[#faf9f6] px-3 font-['Space_Grotesk'] text-[12px] font-medium text-[#1b1a18] outline-none placeholder:text-[#a8a5a0] focus:border-[#c3c1f0] focus:bg-white"
  @seo_select "h-9 w-full appearance-none rounded-[10px] border border-[#ecebe6] bg-[#faf9f6] ps-3 pe-[30px] font-['Space_Grotesk'] text-[12px] font-semibold text-[#3a382f] outline-none focus:border-[#c3c1f0]"
  @seo_button "h-9 flex-none rounded-[9px] border border-[#dcdbf5] bg-[#f2f1fc] px-3 text-[11.5px] font-bold text-[#4f4bcc] hover:bg-[#e9e7fb] disabled:cursor-not-allowed disabled:opacity-50"

  attr(:id, :string, default: nil)
  slot(:inner_block, required: true)

  defp seo_heading(assigns) do
    ~H"""
    <div id={@id} class="mb-2.5 text-[10.5px] font-bold uppercase tracking-[0.1em] text-[#6d6a63]">
      {render_slot(@inner_block)}
    </div>
    """
  end

  @views [{"google", "Google"}, {"x", "X"}, {"facebook", "Facebook"}]

  attr(:seo, :map, required: true)

  # THE PAGE'S SHARE CARD, as drawn, and Regenerate. The published page's: a draft names it by its
  # source. A page that shows records leaves each record its own, in that record's modal.
  defp seo_share_card(assigns) do
    document = assigns.seo.document

    assigns =
      assign(assigns,
        page_id: share_page_id(document),
        site_id: Map.get(document, :site_id)
      )

    ~H"""
    <section
      :if={@page_id && @site_id && is_nil(@seo.record)}
      id="pb-seo-share-card"
      class="flex flex-col gap-2 rounded-[12px] border border-[#ecebe6] bg-white p-3"
    >
      <span class="text-[10.5px] font-bold uppercase tracking-[0.1em] text-[#6d6a63]">
        {gettext("Share image")}
      </span>
      <.live_component
        module={ShareCardField}
        id="pb-seo-share-card-field"
        site_id={@site_id}
        target={{:page, @page_id}}
      />
    </section>
    """
  end

  defp share_page_id(%Page{id: id}), do: id
  defp share_page_id(%PageDraft{source_page_id: id}), do: id
  defp share_page_id(_other), do: nil

  attr(:seo, :map, required: true)
  attr(:target, :any, required: true)

  # A search result and two link shares, drawn from the head the page would render. Every view is
  # drawn and the others hidden, so switching is instant. A picture box opens the Media library.
  defp seo_previews(assigns) do
    head = assigns.seo.head
    host = preview_host(head.url)
    type = SeoSettings.record_type(assigns.seo)
    share_title = head_meta(head, "property", "og:title")
    share_text = head_meta(head, "property", "og:description")

    assigns =
      assign(assigns,
        head: head,
        host: host,
        site: head_meta(head, "property", "og:site_name") || host,
        crumb: preview_crumb(head.url),
        image: preview_image(head.image, assigns.seo.base),
        share_title: share_title,
        share_text: share_text,
        x_title: head_meta(head, "name", "twitter:title") || share_title,
        x_text: head_meta(head, "name", "twitter:description") || share_text,
        large?: head_meta(head, "name", "twitter:card") != "summary",
        samples: (type && type.samples) || [],
        views: @views,
        select: @seo_select
      )

    ~H"""
    <section id="pb-seo-previews" class="flex flex-col gap-3">
      <div class="flex items-center gap-2">
        <span class="flex-1 text-[10.5px] font-bold uppercase tracking-[0.1em] text-[#6d6a63]">
          {gettext("Preview")}
        </span>
        <div role="tablist" class="flex gap-0.5 rounded-[9px] bg-[#f2f1ec] p-[3px]">
          <button
            :for={{key, label} <- @views}
            type="button"
            role="tab"
            id={"pb-seo-view-#{key}"}
            aria-selected={to_string(@seo.view == key)}
            phx-click="seo_view"
            phx-value-view={key}
            phx-target={@target}
            class={[
              "h-6 rounded-[7px] px-2.5 font-['Space_Grotesk'] text-[10.5px] font-bold",
              (@seo.view == key && "bg-white text-[#1b1a18] shadow-[0_1px_2px_rgba(30,28,24,.1)]") ||
                "text-[#6d6a63] hover:text-[#3a382f]"
            ]}
          >
            {label}
          </button>
        </div>
      </div>

      <div :if={@samples != []} class="flex items-center gap-2">
        <label for="pb-seo-sample" class="flex-none text-[10.5px] font-bold text-[#3a382f]">
          {gettext("Preview with")}
        </label>
        <div class="relative min-w-0 flex-1">
          <select id="pb-seo-sample" name="seo[sample]" class={@select}>
            <option value="">{gettext("Placeholders")}</option>
            <option
              :for={{sample, index} <- Enum.with_index(@samples)}
              value={index}
              selected={@seo.sample == sample}
            >
              {sample.label}
            </option>
          </select>
          <.icon
            name={:chevron_down}
            size={13}
            class="pointer-events-none absolute end-[11px] top-1/2 -translate-y-1/2 text-[#a8a5a0]"
          />
        </div>
      </div>

      <div id="pb-seo-google" class={["flex flex-col gap-2", @seo.view != "google" && "hidden"]}>
        <div id="pb-seo-search" class="rounded-[12px] border border-[#ecebe6] bg-white px-3.5 py-3">
          <div class="flex min-w-0 items-center gap-2">
            <span class="grid size-[22px] flex-none place-items-center rounded-full bg-[#f2f1ec] font-['Space_Grotesk'] text-[10px] font-bold uppercase text-[#6d6a63]">
              {String.first(@site || "·")}
            </span>
            <span class="min-w-0">
              <span class="block truncate text-[11.5px] font-medium text-[#1b1a18]">{@site}</span>
              <span
                id="pb-seo-search-url"
                dir="ltr"
                class="block truncate text-[10.5px] text-[#6d6a63] rtl:text-right"
              >
                {@crumb}
              </span>
            </span>
          </div>
          <p
            id="pb-seo-search-title"
            class="mt-1.5 truncate text-[15px] leading-[1.35] text-[#1a0dab]"
          >
            {clip(@head.title, 60)}
          </p>
          <p
            :if={@seo.stars}
            id="pb-seo-stars"
            class="mt-0.5 flex items-center gap-1 text-[11px] text-[#70757a]"
          >
            <span class="tracking-[1px] text-[#e7a000]">{stars(@seo.stars.value)}</span>
            <span>{gettext("Rating: %{value}", value: rating_text(@seo.stars.value))}</span>
            <span :if={@seo.stars.count}>
              · {gettext("%{count} reviews", count: @seo.stars.count)}
            </span>
          </p>
          <p
            id="pb-seo-search-description"
            class={[
              "mt-0.5 line-clamp-2 text-[11.5px] leading-[1.5]",
              (@head.description && "text-[#4d5156]") || "italic text-[#a8a5a0]"
            ]}
          >
            {clip(@head.description, 160) ||
              gettext("No description: search engines pick a passage from the page.")}
          </p>
        </div>

        <div class="grid grid-cols-2 gap-3">
          <.seo_meter
            id="pb-seo-meter-title"
            label={gettext("Title")}
            text={@head.title}
            min={30}
            max={60}
          />
          <.seo_meter
            id="pb-seo-meter-description"
            label={gettext("Description")}
            text={@head.description}
            min={70}
            max={160}
          />
        </div>
      </div>

      <div id="pb-seo-x" class={[@seo.view != "x" && "hidden"]}>
        <div
          :if={@large?}
          class="overflow-hidden rounded-[16px] border border-[#cfd9de] bg-white"
        >
          <.seo_picture
            id="pb-seo-x-image"
            src={@image}
            class="aspect-[1.91/1] w-full"
            caption={@x_title}
          />
        </div>
        <div
          :if={!@large?}
          class="flex overflow-hidden rounded-[16px] border border-[#cfd9de] bg-white"
        >
          <.seo_picture id="pb-seo-x-image" src={@image} class="size-[96px] flex-none" />
          <div class="min-w-0 flex-1 border-s border-[#cfd9de] px-3 py-2.5">
            <p dir="ltr" class="truncate text-[11px] text-[#536471] rtl:text-right">{@host}</p>
            <p id="pb-seo-x-title" class="truncate text-[12.5px] text-[#0f1419]">{@x_title}</p>
            <p class="line-clamp-2 text-[11px] leading-[1.4] text-[#536471]">
              {clip(@x_text, 200)}
            </p>
          </div>
        </div>
        <p :if={@large?} class="mt-1 text-[11px] text-[#536471]">
          {gettext("From %{host}", host: @host)}
        </p>
      </div>

      <div
        id="pb-seo-share"
        class={[
          "overflow-hidden rounded-[10px] border border-[#dddfe2] bg-white",
          @seo.view != "facebook" && "hidden"
        ]}
      >
        <.seo_picture id="pb-seo-share-image" src={@image} class="aspect-[1.91/1] w-full" />
        <div class="border-t border-[#dddfe2] bg-[#f0f2f5] px-3 py-2.5">
          <p dir="ltr" class="truncate text-[10.5px] uppercase text-[#65676b] rtl:text-right">
            {@host}
          </p>
          <p
            id="pb-seo-share-title"
            class="mt-0.5 truncate text-[13px] font-semibold leading-[1.3] text-[#050505]"
          >
            {@share_title}
          </p>
          <p id="pb-seo-share-description" class="mt-0.5 line-clamp-1 text-[11.5px] text-[#65676b]">
            {clip(@share_text, 200)}
          </p>
        </div>
      </div>
    </section>
    """
  end

  attr(:id, :string, required: true)
  attr(:src, :string, default: nil)
  attr(:class, :string, default: nil)
  attr(:caption, :string, default: nil)

  # A preview's picture, or the box that asks for one; either opens the Media library. No
  # `phx-target`: the library is the editor's.
  defp seo_picture(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="seo_pick_image"
      title={gettext("Choose from Media")}
      class={["group relative block overflow-hidden bg-[#f2f1ec]", @class]}
    >
      <img :if={@src} id={@id} src={@src} alt="" class="h-full w-full object-cover" />
      <span
        :if={!@src}
        class="grid h-full w-full place-items-center text-[#a8a5a0] group-hover:text-[#4f4bcc]"
      >
        <.icon name={:image} size={20} />
      </span>
      <span
        :if={@caption}
        class="absolute bottom-2 start-2 max-w-[88%] truncate rounded-[4px] bg-[#000]/60 px-1.5 py-0.5 text-[11px] text-white"
      >
        {@caption}
      </span>
    </button>
    """
  end

  defp stars(value) do
    full = round(value)
    String.duplicate("★", full) <> String.duplicate("☆", 5 - full)
  end

  defp rating_text(value), do: :erlang.float_to_binary(value / 1, decimals: 1)

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:text, :string, default: nil)
  attr(:min, :integer, required: true)
  attr(:max, :integer, required: true)

  # A length against the range search engines show in full.
  defp seo_meter(assigns) do
    length = String.length(assigns.text || "")

    state =
      cond do
        length < assigns.min -> "short"
        length > assigns.max -> "long"
        true -> "good"
      end

    assigns =
      assign(assigns,
        length: length,
        state: state,
        width: min(100, round(length * 100 / (assigns.max * 1.2)))
      )

    ~H"""
    <div
      id={@id}
      data-state={@state}
      title={gettext("Best between %{min} and %{max} characters", min: @min, max: @max)}
      class="flex min-w-0 items-center gap-2"
    >
      <span class="flex-none text-[10px] font-semibold text-[#6d6a63]">{@label}</span>
      <span class="relative h-[5px] min-w-0 flex-1 overflow-hidden rounded-full bg-[#f2f1ec]">
        <span
          class={[
            "absolute inset-y-0 start-0 rounded-full",
            meter_colour(@state, "bg")
          ]}
          style={"width:#{@width}%"}
        ></span>
      </span>
      <span class={[
        "flex-none font-['Space_Grotesk'] text-[10px] font-bold",
        meter_colour(@state, "text")
      ]}>
        {@length}/{@max}
      </span>
    </div>
    """
  end

  defp meter_colour("good", "bg"), do: "bg-[#1f9d6b]"
  defp meter_colour("good", "text"), do: "text-[#177a53]"
  defp meter_colour("long", "bg"), do: "bg-[#d5544b]"
  defp meter_colour("long", "text"), do: "text-[#b5495f]"
  defp meter_colour(_short, "bg"), do: "bg-[#cf8a24]"
  defp meter_colour(_short, "text"), do: "text-[#8a5514]"

  attr(:label, :string, required: true)
  attr(:for, :string, required: true)
  attr(:hint, :string, default: nil)
  slot(:inner_block, required: true)

  defp seo_field(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <label for={@for} class="text-[10.5px] font-bold text-[#3a382f]">{@label}</label>
      {render_slot(@inner_block)}
      <p :if={@hint} class="text-[10px] font-medium leading-[1.5] text-[#6d6a63]">{@hint}</p>
    </div>
    """
  end

  attr(:seo, :map, required: true)
  attr(:target, :any, required: true)

  defp seo_basics(assigns) do
    assigns =
      assign(assigns,
        input: @seo_input,
        button: @seo_button,
        title: Seo.tag_value(assigns.seo.tags, "title"),
        image: Seo.tag_value(assigns.seo.tags, "og:image"),
        noindex?: (Seo.tag_value(assigns.seo.tags, "robots") || "") =~ "noindex"
      )

    assigns =
      assign(
        assigns,
        :image_src,
        assigns.image && preview_image(assigns.seo.head.image, assigns.seo.base)
      )

    ~H"""
    <section id="pb-seo-basics" class="flex flex-col gap-3">
      <.seo_heading>{gettext("Basics")}</.seo_heading>

      <.seo_field
        for="pb-seo-title"
        label={gettext("Title")}
        hint={
          gettext("The browser tab and the headline of a search result. Empty uses the one shown.")
        }
      >
        <input
          type="text"
          id="pb-seo-title"
          dir="auto"
          name="seo[title]"
          value={@title}
          data-seo-vars
          placeholder={@seo.head.title}
          phx-debounce="250"
          class={@input}
        />
      </.seo_field>

      <.seo_field
        for="pb-seo-description"
        label={gettext("Description")}
        hint={gettext("The summary under the title in a search result and a link share.")}
      >
        <textarea
          id="pb-seo-description"
          dir="auto"
          name="seo[description]"
          rows="3"
          data-seo-vars
          placeholder={
            (@seo.record_driven && gettext("Empty: each record's own description.")) ||
              gettext("Empty: search engines pick a passage from the page.")
          }
          phx-debounce="250"
          class={[@input, "h-auto resize-y py-2 leading-[1.5]"]}
        >{@seo.description}</textarea>
      </.seo_field>

      <.seo_field for="pb-seo-image" label={gettext("Share image")}>
        <div class="flex items-start gap-3">
          <div class="relative flex-none">
            <button
              type="button"
              id="pb-seo-image-pick"
              phx-click="seo_pick_image"
              title={gettext("Choose from Media")}
              class="grid h-[78px] w-[140px] place-items-center overflow-hidden rounded-[11px] border border-dashed border-[#dcdbf5] bg-[#faf9f6] text-[#8580d8] hover:border-[#c3c1f0] hover:bg-[#f2f1fc]"
            >
              <img
                :if={@image_src}
                id="pb-seo-image-thumb"
                src={@image_src}
                alt=""
                class="h-full w-full object-cover"
              />
              <.icon :if={!@image_src} name={:image} size={20} />
            </button>
            <button
              :if={@image}
              type="button"
              id="pb-seo-image-clear"
              phx-click="seo_image_clear"
              phx-target={@target}
              title={gettext("Remove")}
              class="absolute -end-2 -top-2 grid size-6 place-items-center rounded-full border border-[#ecebe6] bg-white text-[#8a877f] shadow-[0_2px_6px_rgba(20,18,26,.12)] hover:text-[#d5544b]"
            >
              <.icon name={:close} size={11} />
            </button>
          </div>
          <div class="min-w-0 flex-1 pt-0.5">
            <p class="text-[10px] font-medium leading-[1.5] text-[#6d6a63]">
              {cond do
                @image -> gettext("The picture a link share shows. Click it to choose another.")
                @seo.record_driven -> gettext("Empty: each record's own picture.")
                true -> gettext("Click the box to choose a picture from Media.")
              end}
            </p>
            <button
              type="button"
              id="pb-seo-image-manual"
              phx-click="seo_image_manual"
              phx-target={@target}
              class="mt-1 text-[10.5px] font-bold text-[#4f4bcc] hover:underline"
            >
              {(@seo.image_manual && gettext("Hide the address")) ||
                gettext("Use an address or a variable")}
            </button>
          </div>
        </div>
        <input
          :if={@seo.image_manual}
          type="text"
          id="pb-seo-image"
          dir="ltr"
          name="seo[image]"
          value={@image}
          data-seo-vars
          placeholder="{{post.image}}, https://…"
          phx-debounce="250"
          class={[@input, "mt-2"]}
        />
        <input
          :if={!@seo.image_manual}
          type="hidden"
          id="pb-seo-image"
          name="seo[image]"
          value={@image}
        />
      </.seo_field>

      <label
        for="pb-seo-noindex"
        class="flex cursor-pointer items-center gap-2.5 rounded-[10px] border border-[#ecebe6] px-3 py-2.5"
      >
        <span class="min-w-0 flex-1">
          <span class="block text-[11.5px] font-semibold text-[#3a382f]">
            {gettext("Hide from search engines")}
          </span>
          <span class="mt-0.5 block text-[10px] font-medium text-[#6d6a63]">
            {(@seo.restricted &&
                gettext("Hidden already: this page needs a permission or is a sign-in page.")) ||
              gettext("Asks search engines not to list this page or follow its links.")}
          </span>
        </span>
        <input type="hidden" name="seo[noindex]" value="false" />
        <input
          type="checkbox"
          id="pb-seo-noindex"
          name="seo[noindex]"
          value="true"
          checked={@noindex?}
          class="peer sr-only"
        />
        <span class="flex h-[23px] w-10 flex-none items-center justify-start rounded-full bg-[#d9d7d0] px-[3px] transition-colors peer-checked:justify-end peer-checked:bg-[#5b57d6]">
          <span class="size-[17px] rounded-full bg-white shadow-[0_1px_3px_rgba(0,0,0,.22)]"></span>
        </span>
      </label>
    </section>
    """
  end

  attr(:seo, :map, required: true)
  attr(:target, :any, required: true)

  # The stored tags, each removable, and a row that adds one from the catalog or by hand.
  defp seo_tag_list(assigns) do
    adding = assigns.seo.adding

    assigns =
      assign(assigns,
        input: @seo_input,
        select: @seo_select,
        button: @seo_button,
        adding: adding,
        entry: adding && Enum.find(Seo.catalog(), &(&1.id == adding.id))
      )

    ~H"""
    <section id="pb-seo-tags">
      <.seo_heading>{gettext("Tags")}</.seo_heading>

      <p :if={@seo.tags == []} id="pb-seo-tags-empty" class="text-[10.5px] font-medium text-[#6d6a63]">
        {gettext("None stored: the page uses its defaults.")}
      </p>

      <ul :if={@seo.tags != []} class="rounded-[11px] border border-[#ecebe6]">
        <li
          :for={{tag, index} <- Enum.with_index(@seo.tags)}
          id={"pb-seo-tag-#{index}"}
          class="flex items-center gap-2 border-b border-[#f4f3ee] px-3 py-2 last:border-b-0"
        >
          <span
            class="w-[120px] flex-none truncate text-[11px] font-semibold text-[#3a382f]"
            title={tag_name(tag)}
          >
            {tag_label(tag)}
          </span>
          <span
            dir="auto"
            class="min-w-0 flex-1 truncate font-['Space_Grotesk'] text-[11px] text-[#6d6a63]"
          >
            {Seo.stored_value(tag)}
          </span>
          <button
            type="button"
            id={"pb-seo-tag-remove-#{index}"}
            phx-click="seo_remove_tag"
            phx-target={@target}
            phx-value-index={index}
            title={gettext("Remove")}
            class="grid size-6 flex-none place-items-center rounded-[7px] text-[#a8a5a0] hover:bg-[#f6f5f2] hover:text-[#d5544b]"
          >
            <.icon name={:close} size={12} />
          </button>
        </li>
      </ul>

      <div id="pb-seo-add" class="mt-2 flex flex-col gap-2 rounded-[11px] bg-[#faf9f6] p-2.5">
        <div class="relative">
          <select id="pb-seo-add-tag" name="seo[add]" class={[@select, "bg-white"]}>
            <option value="">{gettext("Add a tag…")}</option>
            <optgroup :for={{group, entries} <- seo_tag_groups()} label={group}>
              <option
                :for={entry <- entries}
                value={entry.id}
                selected={@entry && @entry.id == entry.id}
              >
                {entry.label}
              </option>
            </optgroup>
            <option value="custom" selected={@adding && @adding.id == "custom"}>
              {gettext("Custom…")}
            </option>
          </select>
          <.icon
            name={:chevron_down}
            size={13}
            class="pointer-events-none absolute end-[11px] top-1/2 -translate-y-1/2 text-[#a8a5a0]"
          />
        </div>

        <div :if={@adding} class="flex flex-col gap-2">
          <p :if={@entry} class="text-[10px] font-medium leading-[1.5] text-[#6d6a63]">
            {@entry.help}
          </p>

          <div :if={@adding.id == "custom"} class="flex gap-2">
            <div class="relative w-[150px] flex-none">
              <select id="pb-seo-custom-kind" name="seo[custom_kind]" class={[@select, "bg-white"]}>
                <option
                  :for={{kind, label} <- custom_kinds()}
                  value={kind}
                  selected={@adding.kind == kind}
                >
                  {label}
                </option>
              </select>
              <.icon
                name={:chevron_down}
                size={13}
                class="pointer-events-none absolute end-[11px] top-1/2 -translate-y-1/2 text-[#a8a5a0]"
              />
            </div>
            <input
              type="text"
              id="pb-seo-custom-key"
              dir="ltr"
              name="seo[custom_key]"
              value={@adding.key}
              placeholder={gettext("e.g. theme-color")}
              phx-debounce="250"
              class={[@input, "bg-white"]}
            />
          </div>

          <input
            :for={{need, value} <- @adding.needs}
            type="text"
            id={"pb-seo-add-need-#{need}"}
            dir="auto"
            name={"seo[add_needs][#{need}]"}
            value={value}
            data-seo-vars
            placeholder={need}
            phx-debounce="250"
            class={[@input, "bg-white"]}
          />

          <div
            :if={@entry && @entry.multiple?}
            id="pb-seo-add-values"
            class="flex flex-wrap gap-[5px]"
          >
            <input type="hidden" name="seo[add_values][]" value="" />
            <label :for={value <- @entry.values} class="cursor-pointer">
              <input
                type="checkbox"
                name="seo[add_values][]"
                value={value}
                checked={value in @adding.values}
                class="peer sr-only"
              />
              <span class="inline-flex h-[26px] items-center rounded-[20px] border border-[#ecebe6] bg-white px-2.5 text-[10px] font-semibold text-[#6d6a63] peer-checked:border-[#dcdbf5] peer-checked:bg-[#f2f1fc] peer-checked:text-[#4f4bcc]">
                {value}
              </span>
            </label>
          </div>

          <div :if={is_map(@entry) and @entry.values != [] and not @entry.multiple?} class="relative">
            <select id="pb-seo-add-value" name="seo[add_value]" class={[@select, "bg-white"]}>
              <option :for={value <- @entry.values} value={value} selected={@adding.value == value}>
                {value}
              </option>
            </select>
            <.icon
              name={:chevron_down}
              size={13}
              class="pointer-events-none absolute end-[11px] top-1/2 -translate-y-1/2 text-[#a8a5a0]"
            />
          </div>

          <div class="flex gap-2">
            <input
              :if={is_nil(@entry) or @entry.values == []}
              type="text"
              id="pb-seo-add-value"
              dir="auto"
              name="seo[add_value]"
              value={@adding.value}
              data-seo-vars
              placeholder={gettext("Value")}
              phx-debounce="250"
              class={[@input, "bg-white"]}
            />
            <span :if={@entry && @entry.values != []} class="flex-1"></span>
            <button
              type="button"
              id="pb-seo-add-confirm"
              phx-click="seo_add_tag"
              phx-target={@target}
              disabled={is_nil(@adding.tag)}
              class={@button}
            >
              {gettext("Add")}
            </button>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr(:seo, :map, required: true)
  attr(:target, :any, required: true)

  # The page's JSON-LD: one object written from a type and its fields, and all of it as JSON.
  defp seo_schema(assigns) do
    type = Enum.find(Seo.schema_types(), &(&1.type == assigns.seo.type))

    assigns =
      assign(assigns,
        input: @seo_input,
        select: @seo_select,
        button: @seo_button,
        type: type,
        others: Enum.count(assigns.seo.schema) - if(type, do: 1, else: 0)
      )

    ~H"""
    <section id="pb-seo-schema" class="flex flex-col gap-2">
      <.seo_heading>{gettext("Structured data")}</.seo_heading>

      <div class="relative">
        <select id="pb-seo-type" name="seo[type]" class={@select}>
          <option value="">
            {(@seo.record_driven && gettext("Default (from each record)")) ||
              gettext("Default (WebPage, automatic)")}
          </option>
          <option
            :for={known <- Seo.schema_types()}
            value={known.type}
            selected={@seo.type == known.type}
          >
            {known.label}
          </option>
        </select>
        <.icon
          name={:chevron_down}
          size={13}
          class="pointer-events-none absolute end-[11px] top-1/2 -translate-y-1/2 text-[#a8a5a0]"
        />
      </div>

      <p
        :if={is_nil(@type) and @others == 0}
        class="text-[10px] font-medium leading-[1.5] text-[#6d6a63]"
      >
        {(@seo.record_driven &&
            gettext("Each record writes its own, unless you choose a type here.")) ||
          gettext("A WebPage is written from the title, description and image above.")}
      </p>
      <p :if={@others > 0} class="text-[10px] font-medium leading-[1.5] text-[#6d6a63]">
        {ngettext(
          "The page also holds 1 other object, kept as it is.",
          "The page also holds %{count} other objects, kept as they are.",
          @others
        )}
      </p>

      <div :if={@type && !@type.faq?} id="pb-seo-type-fields" class="grid grid-cols-2 gap-2">
        <.seo_field :for={field <- @type.fields} for={"pb-seo-field-#{field.key}"} label={field.label}>
          <input
            type="text"
            id={"pb-seo-field-#{field.key}"}
            dir="auto"
            name={"seo[fields][#{field.key}]"}
            value={@seo.fields[field.key]}
            data-seo-vars
            placeholder={field.default}
            phx-debounce="250"
            class={@input}
          />
        </.seo_field>
      </div>

      <div :if={@type && @type.faq?} id="pb-seo-faq" class="flex flex-col gap-2">
        <div
          :for={{pair, index} <- Enum.with_index(@seo.fields["questions"] || [])}
          id={"pb-seo-faq-#{index}"}
          class="flex flex-col gap-1.5 rounded-[11px] border border-[#ecebe6] p-2.5"
        >
          <div class="flex gap-2">
            <input
              type="text"
              name={"seo[faq][#{index}][question]"}
              dir="auto"
              value={pair["question"]}
              data-seo-vars
              placeholder={gettext("Question")}
              phx-debounce="250"
              class={@input}
            />
            <button
              type="button"
              id={"pb-seo-faq-remove-#{index}"}
              phx-click="seo_faq_remove"
              phx-target={@target}
              phx-value-index={index}
              title={gettext("Remove")}
              class="grid size-9 flex-none place-items-center rounded-[9px] text-[#a8a5a0] hover:bg-[#f6f5f2] hover:text-[#d5544b]"
            >
              <.icon name={:trash} size={13} />
            </button>
          </div>
          <textarea
            name={"seo[faq][#{index}][answer]"}
            dir="auto"
            rows="2"
            data-seo-vars
            placeholder={gettext("Answer")}
            phx-debounce="250"
            class={[@input, "h-auto resize-y py-2 leading-[1.5]"]}
          >{pair["answer"]}</textarea>
        </div>
        <button
          type="button"
          id="pb-seo-faq-add"
          phx-click="seo_faq_add"
          phx-target={@target}
          class={[@button, "self-start"]}
        >
          {gettext("Add a question")}
        </button>
      </div>

      <p
        :if={@type && @type.stars?}
        id="pb-seo-stars-note"
        class="text-[10px] font-medium leading-[1.5] text-[#6d6a63]"
      >
        {gettext(
          "Search results may show its rating as stars. A rating can name a variable, such as {{post.rating}}."
        )}
      </p>
    </section>
    """
  end

  attr(:seo, :map, required: true)
  attr(:target, :any, required: true)

  # WHAT MOST PAGES NEVER NEED, folded away: the canonical address, every stored tag, and the
  # structured data as JSON. Folded, it is still drawn, so what it holds is still sent.
  defp seo_advanced(assigns) do
    assigns =
      assign(assigns,
        input: @seo_input,
        canonical: Seo.tag_value(assigns.seo.tags, "canonical")
      )

    ~H"""
    <section id="pb-seo-advanced-section" class="rounded-[12px] border border-[#ecebe6]">
      <button
        type="button"
        id="pb-seo-advanced"
        phx-click="seo_advanced"
        phx-target={@target}
        aria-expanded={to_string(@seo.advanced)}
        class="flex w-full items-center gap-2.5 px-3.5 py-3 text-start"
      >
        <.icon
          name={(@seo.advanced && :chevron_down) || :chevron}
          size={12}
          class="flex-none text-[#8a877f]"
        />
        <span class="min-w-0 flex-1">
          <span class="block text-[11.5px] font-bold text-[#3a382f]">{gettext("Advanced")}</span>
          <span class="mt-0.5 block text-[10px] font-medium text-[#6d6a63]">
            {gettext("The canonical address, every tag, and the structured data as JSON-LD.")}
          </span>
        </span>
        <span class="flex-none rounded-full bg-[#f2f1ec] px-2 py-0.5 font-['Space_Grotesk'] text-[9.5px] font-bold text-[#6d6a63]">
          {ngettext("1 tag", "%{count} tags", length(@seo.tags))}
        </span>
      </button>

      <div class={[
        "flex flex-col gap-5 border-t border-[#f0efea] px-3.5 pb-4 pt-3.5",
        !@seo.advanced && "hidden"
      ]}>
        <.seo_field
          for="pb-seo-canonical"
          label={gettext("Canonical address")}
          hint={gettext("Only when another address should be indexed in this page's place.")}
        >
          <input
            type="text"
            id="pb-seo-canonical"
            dir="ltr"
            name="seo[canonical]"
            value={@canonical}
            data-seo-vars
            placeholder={@seo.head.url}
            phx-debounce="250"
            class={@input}
          />
        </.seo_field>

        <.seo_tag_list seo={@seo} target={@target} />

        <div class="flex flex-col gap-1">
          <.seo_heading>{gettext("JSON-LD")}</.seo_heading>
          <textarea
            id="pb-seo-json"
            dir="ltr"
            name="seo[json]"
            rows="9"
            data-seo-vars
            spellcheck="false"
            phx-debounce="400"
            class="w-full resize-y rounded-[10px] border-0 bg-[#17161a] px-3 py-2.5 font-['Space_Grotesk'] text-[11.5px] leading-[1.7] text-[#c9c7d1] outline-none [[data-theme=dark]_&]:[filter:invert(1)_hue-rotate(180deg)]"
          >{@seo.json}</textarea>
          <p
            :if={@seo.json_error}
            id="pb-seo-json-error"
            class="text-[10.5px] font-semibold text-[#b5495f]"
          >
            {@seo.json_error}
          </p>
          <p :if={!@seo.json_error} class="text-[10px] font-medium text-[#6d6a63]">
            {gettext("A list of objects, each with an \"@type\". Values may use the variables above.")}
          </p>
        </div>
      </div>
    </section>
    """
  end

  # The variables a value may name, and a note when the page's SEO comes from each record.
  defp seo_variables(assigns) do
    ~H"""
    <section id="pb-seo-vars">
      <.seo_heading>{gettext("Variables")}</.seo_heading>
      <p class="mb-2 text-[10px] font-medium leading-[1.5] text-[#6d6a63]">
        {gettext("Click one to put it in the field you were typing in, or at the end of the title.")}
      </p>
      <div class="flex flex-wrap gap-[5px]">
        <button
          :for={var <- @seo.vars}
          type="button"
          id={"pb-seo-var-#{String.replace(var.key, ".", "-")}"}
          data-seo-var={"{{" <> var.key <> "}}"}
          title={var.label}
          class="h-[26px] flex-none whitespace-nowrap rounded-[20px] border border-[#ecebe6] bg-white px-2.5 font-['Space_Grotesk'] text-[10px] font-semibold text-[#6d6a63] hover:border-[#dcdbf5] hover:text-[#4f4bcc]"
        >
          {var.key}
        </button>
      </div>

      <MishkaCmsCore.CoreComponents.tip :if={@seo.record_driven} id="pb-seo-record-note" class="mt-3">
        {gettext(
          "Each record fills what you leave empty here. What you set wins, and can use the variables above to place the record's own data."
        )}
      </MishkaCmsCore.CoreComponents.tip>
    </section>
    """
  end

  defp seo_tag_groups do
    groups = [
      {gettext("Basics"), &(not String.contains?(&1, ":"))},
      {gettext("Open Graph"), &String.starts_with?(&1, "og:")},
      {gettext("X (Twitter)"), &String.starts_with?(&1, "twitter:")},
      {gettext("Article"), &String.starts_with?(&1, "article:")}
    ]

    catalog = Seo.catalog()

    for {label, member?} <- groups,
        entries = Enum.filter(catalog, &member?.(&1.id)),
        entries != [],
        do: {label, entries}
  end

  defp custom_kinds,
    do: [
      {"name", gettext("meta name")},
      {"property", gettext("meta property")},
      {"rel", gettext("link rel")}
    ]

  # A stored tag's catalog label, or the name it carries when the catalog has none.
  defp tag_label(tag) do
    case Seo.entry_of(tag) do
      %{label: label} -> label
      nil -> tag_name(tag)
    end
  end

  defp tag_name(%{tag: tag, attrs: attrs}) do
    named = Enum.find_value(~w(name property rel http-equiv charset), &Map.get(attrs, &1))
    Enum.join(Enum.filter([tag, named, attrs["hreflang"]], &is_binary/1), " ")
  end

  defp head_meta(%{tags: tags}, key, name) do
    Enum.find_value(tags, fn
      {"meta", attrs} -> {key, name} in attrs && head_text(List.keyfind(attrs, "content", 0))
      _link -> nil
    end)
  end

  defp head_text({_key, value}) when is_binary(value), do: value
  defp head_text(_no_value), do: nil

  defp preview_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host, port: port, scheme: scheme} when is_binary(host) ->
        if port in [nil, 80, 443] or URI.default_port(scheme) == port,
          do: host,
          else: "#{host}:#{port}"

      _no_host ->
        nil
    end
  end

  defp preview_host(_no_url), do: nil

  # `example.com › en › about`, as a search result writes an address.
  defp preview_crumb(url) when is_binary(url) do
    segments =
      url |> URI.parse() |> Map.get(:path) |> to_string() |> String.split("/", trim: true)

    Enum.join(Enum.filter([preview_host(url) | segments], &is_binary/1), " › ")
  end

  defp preview_crumb(_no_url), do: nil

  # A picture on the site is drawn from its path, so the editor loads it from its own origin.
  defp preview_image(image, base) when is_binary(image) and is_binary(base) do
    if String.starts_with?(image, base <> "/"),
      do: String.replace_prefix(image, base, ""),
      else: image
  end

  defp preview_image(image, _base), do: image

  defp clip(text, max) when is_binary(text) do
    if String.length(text) > max,
      do: String.slice(text, 0, max - 1) |> String.trim_trailing() |> Kernel.<>("…"),
      else: text
  end

  defp clip(_no_text, _max), do: nil
end
