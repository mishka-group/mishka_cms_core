# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Builder.BuilderLive do
  @moduledoc """
  The page builder's chrome: top bar, the two side panels, the crumb bar, the code drawer and the
  overlays — everything around the canvas, which is its own LiveView inside an iframe
  (`MishkaCmsCoreWeb.Live.Admin.Builder.CanvasLive`).

  Both LiveViews share one `MishkaCmsCore.Runtime.PageBuilder.EditorSession`, keyed by a token in
  the canvas URL, and stay in step over that session's PubSub topic. This module owns the *editing
  context* — what is selected, which breakpoint is being edited, what the palette shows — and the
  canvas owns the document's pixels.

  ## Sections

  One editor, four resources: `page`, `layout`, `error_page` and `component`. They differ in which
  Ash actions load and save them and in a handful of panels; everything else — tree, canvas,
  inspector, history — is identical, which is the point of modelling the document as a tree rather
  than as four bespoke forms.

  ## Extension points

  Every panel region is a `MishkaCmsCore.Builder.Events` registry, seeded with the core's own
  entries. The rails, the inspector's sections, the command palette and the canvas toolbar are all
  collected the same way a plugin's contribution would be, so the seam is exercised on every mount
  rather than being a promise.
  """
  use MishkaCmsCore.ExtensionLiveView

  alias MishkaCmsCore.Builder.Collection
  alias MishkaCmsCore.Builder.Descriptor
  alias MishkaCmsCore.Builder.Events
  alias MishkaCmsCore.Builder.PaletteEntry
  alias MishkaCmsCore.Localized
  alias MishkaCmsCore.Runtime.PageBuilder.CardPreview
  alias MishkaCmsCore.Runtime.PageBuilder.Strict

  require MishkaCmsCore.Runtime.PageBuilder.Strict
  alias MishkaCmsCore.Layouts
  require Logger
  require Ash.Query

  alias MishkaCmsCore.Runtime.ErrorAddress
  alias MishkaCmsCore.Runtime.Media
  alias MishkaCmsCore.Runtime.MediaCategory
  alias MishkaCmsCore.Runtime.Translation
  alias MishkaCmsCore.Runtime.Translations
  alias MishkaCmsCoreWeb.Live.Admin.Components.TranslationGroup
  alias MishkaCmsCore.Runtime.PageBuilder.AiBackend
  alias MishkaCmsCore.Runtime.PageBuilder.Classes
  alias MishkaCmsCore.Runtime.PageBuilder.CodeAccess
  alias MishkaCmsCore.Runtime.PageBuilder.CodeCheck
  alias MishkaCmsCore.Runtime.PageBuilder.ElementCss
  alias MishkaCmsCore.Runtime.PageBuilder.ElementScopes
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Styles
  alias MishkaCmsCore.Runtime.PageBuilder.Hooks
  alias MishkaCmsCore.Runtime.PageBuilder.Conditions
  alias MishkaCmsCore.Runtime.PageBuilder.Interactions
  alias MishkaCmsCore.Runtime.PageBuilder.Interface
  alias MishkaCmsCore.Runtime.PageBuilder.LayoutSlot
  alias MishkaCmsCore.Runtime.PageBuilder.Drafts
  alias MishkaCmsCore.Runtime.PageBuilder.History
  alias MishkaCmsCore.Runtime.PageBuilder.Examples
  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.PageBuilder.Review
  alias MishkaGervaz.Table.Web.UrlSync
  alias MishkaCmsCore.Runtime.States.EditorSessionState
  alias MishkaCmsCore.Runtime.PageBuilder.Inspector
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler
  alias MishkaCmsCore.Runtime.PageBuilder.Marketplace
  alias MishkaCmsCore.Runtime.Compilers.Helpers, as: CompilerHelpers
  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.FormChecks
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.FormPlacement
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.Naming
  alias MishkaCmsCore.Runtime.PageBuilder.Mentions
  alias MishkaCmsCore.Runtime.PageComment
  alias MishkaCmsCore.Settings
  alias MishkaCmsCore.Runtime.PageBuilder.DesignToken
  alias MishkaCmsCore.Runtime.PageBuilder.Presence
  alias MishkaCmsCore.Runtime.PageBuilder.Presets
  alias MishkaCmsCore.Runtime.PageBuilder.Section
  alias MishkaCmsCore.Runtime.PageBuilder.SeoSettings
  alias MishkaCmsCore.Runtime.PageBuilder.Visibility
  alias MishkaCmsCore.Runtime.PageBuilder.Wizard
  alias MishkaCmsCore.Runtime.PageBuilder.Tokens
  alias MishkaCmsCore.Runtime.PageBuilder.Snippets
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Shadow
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer
  alias MishkaCmsCore.Sidebar
  alias MishkaCmsCoreWeb.Live.Admin.Builder.Panels

  @devices [
    {:frames, gettext_noop("All breakpoints"), gettext_noop("side by side")},
    {:desktop, gettext_noop("Desktop"), "100%"},
    {:tablet, gettext_noop("Tablet"), "834px"},
    {:mobile, gettext_noop("Mobile"), "390px"}
  ]

  @frame_widths [
    {gettext_noop("Desktop"), 1180},
    {gettext_noop("Tablet"), 900},
    {gettext_noop("Mobile"), 560}
  ]

  # EVERY TAB THE CODE WINDOW HAS, in the order it draws them. Two events name a tab — one opens the
  # window on it, one switches to it while it is open — and both have to agree about which names are
  # real, because `tab_atom/2` falls back to the head of this list for anything it does not know.
  @source_tabs [:template, :interface, :state, :events, :infos, :helpers, :styles]

  # How many panel forms keep what was typed into them (`typed:<form id>`). The ones on screen at
  # once are a handful.
  @typed_forms 24

  # `layout: false` drops the admin shell — sidebar, topbar and the 1340px content column — so the
  # editor owns the whole viewport the way the prototype does. It is not a preference: the editor is
  # a `h-screen` three-column workspace, and nesting it inside a scrolling, padded, width-capped
  # `<main>` costs it roughly 300px of canvas and puts a second scrollbar around it. The root layout
  # still applies, which is where the fonts, Tailwind and the theme script come from; the two things
  # the app layout contributed that this page still needs — flashes and the dark-mode filter — are
  # in `render/1` instead.
  @impl true
  def mount(params, _session, socket) do
    section = Section.normalize(params["section"])

    case Section.known?(section) do
      false -> {:ok, redirect(socket, to: "/admin/dashboard")}
      true -> mount_allowed(socket, section, params)
    end
  end

  # EACH TYPE'S BUILDER OPENS FOR ITS OWN RUNTIME AREA OR `admin:dashboard:code`
  # (`Section.permissions/1`), so opening the page builder says nothing about opening the layout
  # builder. The list the reader came from is where they are sent back to; it stays readable to
  # every dashboard admin.
  defp mount_allowed(socket, section, params) do
    case Section.allowed?(socket.assigns[:current_user], section) do
      true -> mount_document(socket, section, params)
      false -> {:ok, refuse_builder(socket, section)}
    end
  end

  defp refuse_builder(socket, section) do
    socket
    |> put_flash(
      :error,
      gettext("You do not have permission to open the %{noun} builder.", noun: noun(section))
    )
    |> redirect(to: Section.list_path(section))
  end

  defp permitted(entries, socket),
    do: Descriptor.permitted(entries, socket.assigns[:current_user])

  # A DEAD LINK IS NOT AN EMPTY EDITOR. `load_record/3` answers nil for "no id was asked for", which
  # is the create flow, and for "the id in the URL could not be read" — a deleted row, a malformed
  # id, another site's row — which is nothing at all. The second used to open a whole editor over
  # nothing: the palette, the canvas, the stage chip, and every save a silent no-op, because
  # `Drafts.autosave/7` answers `:unsupported` for a nil record and publishing has nothing to write
  # to. Work could be done for an hour and go nowhere, and nothing on the screen said so.
  defp mount_document(socket, section, params) do
    case load_record(section, params["id"], socket.assigns[:current_user]) do
      {:ok, record} -> {:ok, mount_section(socket, section, params, record), layout: false}
      :none -> open_or_start(socket, section, params)
      refused -> {:ok, refuse_document(socket, section, refused)}
    end
  end

  # A SITE HAS ONE ERROR PAGE, so "make an error page" for a site that has one is really "open the
  # one it has" — and the essentials step in front of it would have asked for a name, taken the
  # answer, and been refused by `unique_path_per_site` after the typing rather than before it.
  # `MishkaCmsCore.Runtime.ErrorAddress` says why there is only one.
  #
  # A TENANT'S SITE IS KNOWN HERE AND A MASTER'S IS NOT. A master has not said which site yet — that
  # is what the essentials step's Site picker is for — so there is nothing to look up, and the
  # identity's own message is what answers them if they pick a site that is already taken.
  #
  # A MASTER IS A USER WHOSE `site_id` IS NIL, never the absence of one: a viewer who is not a user
  # is sent back to the list, as for a document that is not there.
  defp open_or_start(socket, "error-page", params) do
    case socket.assigns[:current_user] do
      %{site_id: site_id} when is_binary(site_id) -> already_there(socket, site_id, params)
      %{site_id: nil} -> {:ok, mount_section(socket, "error-page", params, nil), layout: false}
      _nobody -> {:ok, refuse_document(socket, "error-page", :gone)}
    end
  end

  defp open_or_start(socket, section, params) do
    case socket.assigns[:current_user] do
      %{site_id: site_id} when is_nil(site_id) or is_binary(site_id) ->
        {:ok, mount_section(socket, section, params, nil), layout: false}

      _nobody ->
        {:ok, refuse_document(socket, section, :gone)}
    end
  end

  defp already_there(socket, site_id, params) do
    case ErrorAddress.find(site_id) do
      nil ->
        {:ok, mount_section(socket, "error-page", params, nil), layout: false}

      existing ->
        {:ok,
         socket
         |> put_flash(:info, gettext("This site already has an error page — here it is."))
         |> redirect(to: Section.builder_path("error-page", existing.id))}
    end
  end

  # WHICH OF THE THREE IT WAS is deliberately not guessed at, and the list they land on is the answer
  # to "then what is there?". A SHARED DOCUMENT IS THE ONE CASE WORTH NAMING, because it is not a
  # dead end and saying "deleted" about it would be a lie: the layout or component is there, the
  # reader's site uses it, and the only thing they cannot do is change it for everybody.
  defp refuse_document(socket, section, reason) do
    socket
    |> put_flash(:error, refusal(section, reason))
    |> redirect(to: Section.list_path(section))
  end

  defp refusal(section, :gone),
    do:
      gettext("That %{noun} could not be opened — it may have been deleted.",
        noun: noun(section)
      )

  defp refusal(section, :shared),
    do:
      gettext(
        "That %{noun} is shared with every site, so only a master can edit it. Yours can still use it.",
        noun: noun(section)
      )

  defp noun("page"), do: gettext("page")
  defp noun("layout"), do: gettext("layout")
  defp noun("error-page"), do: gettext("error page")
  defp noun("error_page"), do: gettext("error page")
  defp noun("component"), do: gettext("component")

  defp section_label("page"), do: gettext("Page")
  defp section_label("layout"), do: gettext("Layout")
  defp section_label("error-page"), do: gettext("Error page")
  defp section_label("error_page"), do: gettext("Error page")
  defp section_label("component"), do: gettext("Component")

  # A LiveView mounts twice. The static render builds the session WITHOUT registering it, so nothing
  # is left behind and no canvas URL is published; the connected mount is the one that opens a real
  # session. Registering on both minted two tokens per page load, so the canvas iframe was pointed at
  # one URL and then at another — it loaded twice, and the first session was orphaned in ETS.
  # A THREAD IS ROWS, AND ROWS ARE SEEN BY EVERYONE. Two people who each opened this page from the
  # list have two SESSIONS and two session topics, so the session channel cannot tell them about
  # each other's notes — the notes themselves are the only thing they share. These are
  # `MishkaCmsCore.Runtime.PageComment`'s own `pub_sub` topics.
  #
  # THE UNSCOPED FOUR ARE THE WHOLE FEED. `publish :create, [[nil, :site_id], "created"]` emits the
  # `nil` alternative for every row, so `page_comment:created` already carries every site's notes
  # and the global ones; `page_comment:<site>:created` is a strict subset, and subscribing to both
  # would deliver a tenant's own writes twice — the same thing
  # `MishkaCmsCoreWeb.Live.Admin.Runtime.SettingsLive` records about the identical shape.
  #
  # The suffixes are the resource's own words rather than Gervaz's `created/updated/destroyed`:
  # resolving is an `:update` action that publishes `…:resolved`, so a generic realtime helper would
  # sit on `page_comment:updated` and never hear a thing.
  @review_topics ~w(
    page_comment:created
    page_comment:resolved
    page_comment:reopened
    page_comment:destroyed
  )

  defp subscribe_review do
    Enum.each(@review_topics, &Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, &1))
  end

  # THE FOLDER RAIL HAS NO COMPONENT TO SUBSCRIBE FOR IT. The Assets sheet's gallery is a Gervaz
  # table, and `Table.Web.Live` subscribes to `media:*` on our behalf — a LiveComponent shares this
  # process, so its `Phoenix.PubSub.subscribe/2` registers US. Nothing does that for categories, so
  # a folder added anywhere else would never appear here.
  #
  # The site-less topics only. Ash publishes `[[nil, :site_id], "created"]`, which is BOTH
  # `media_category:created` and `media_category:<site>:created`; taking both would hand us every
  # write twice. The site is checked on arrival instead.
  @folder_topics ~w(
    media_category:created
    media_category:updated
    media_category:destroyed
  )

  defp subscribe_folders do
    Enum.each(@folder_topics, &Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, &1))
  end

  # A BUNDLE THAT DID NOT BUILD, said where the author works. The canvas and the live site keep the
  # last bundle that built, so nothing on screen looks broken, which is exactly why the author has to
  # be told the latest change is not live. A site's document hears its own bundles and the shared
  # base its CSS starts with; a global document is built into every site, so it hears them all.
  defp subscribe_asset_builds(editor) do
    editor
    |> asset_bundles()
    |> Enum.map(&CompilerHelpers.asset_builds_topic/1)
    |> Enum.uniq()
    |> Enum.each(&Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, &1))
  end

  defp asset_bundles(%{site_name: site_name}) when is_binary(site_name),
    do: [site_name, "__shared_base__"]

  defp asset_bundles(_global_document), do: [:all]

  @asset_pages %{
    "css" => "/admin/dashboard/runtime/stylesheets",
    "js" => "/admin/dashboard/runtime/js-hooks"
  }

  # The link goes to the page that shows the error, and only for someone that page opens to; the
  # reason is in the bar itself either way. A site admin on a global document hears only their own
  # site and the shared base.
  defp asset_failures(editor, actor) do
    case failed_builds(editor, actor) do
      [] ->
        []

      failures ->
        links =
          Map.new(@asset_pages, fn {type, path} -> {type, Sidebar.opens?(actor, path) && path} end)

        Enum.map(failures, &Map.put(&1, :link, links[&1.type] || nil))
    end
  end

  # The site's own CSS failure already carries the shared base's reason when that is the cause, so
  # the base's bar is drawn only when the site's CSS has none of its own.
  defp failed_builds(%{site_name: site_name}, _actor) when is_binary(site_name) do
    css =
      Enum.find_value([site_name, "__shared_base__"], fn bundle ->
        failure = CompilerHelpers.asset_build_failure(bundle, "css")
        failure && Map.merge(failure, %{bundle: bundle, type: "css"})
      end)

    js =
      case CompilerHelpers.asset_build_failure(site_name, "js") do
        nil -> nil
        failure -> Map.merge(failure, %{bundle: site_name, type: "js"})
      end

    Enum.reject([css, js], &is_nil/1)
  end

  defp failed_builds(_global_document, actor) do
    for type <- ~w(css js),
        {bundle, failure} <- CompilerHelpers.asset_build_failures(type),
        heard?(bundle, actor),
        do: Map.merge(failure, %{bundle: bundle, type: type})
  end

  defp heard?("__shared_base__", _actor), do: true
  defp heard?(_bundle, %{site_id: nil}), do: true

  defp heard?(bundle, %{site_id: site_id}) do
    match?({:ok, %{name: ^bundle}}, MishkaCmsCore.Runtime.States.SiteState.get(site_id))
  end

  defp heard?(_bundle, _actor), do: false

  # A STORED TEMPLATE THE TOKENIZER REFUSES USED TO BE A CRASH LOOP. `resume_or_open/5` answers
  # `{:error, %{line:, column:, message:}}` when the document will not parse, and `{opened, editor}`
  # MATCHES that — it is a two-tuple — so the error map became the editor and the mount died on
  # `editor.token` with a `KeyError`. The page could not then be opened to fix the thing that broke
  # it, which is the worst shape a failure can take.
  #
  # It cannot arrive through the front door: the Page actions refuse a template that will not compile.
  # It arrives from a seed, a hand edit, or a page saved before that validation existed — and the
  # editor still has to open it, because the editor is where it gets fixed.
  defp mount_section(socket, section, params, record) do
    actor = socket.assigns[:current_user]

    case resume_or_open(section, params, record, actor, connected?(socket)) do
      {:error, %{} = fault} -> mount_recovery(socket, section, params, record, fault)
      {opened, editor} -> mount_editor(socket, section, params, record, actor, opened, editor)
    end
  end

  defp mount_recovery(socket, section, params, record, fault) do
    # THE ENTRY THAT FAILED, not the first one. There is no session here to ask which status is open
    # — the tree would not parse, which is why this screen is up — so the URL answers, exactly as it
    # did for the parse that just refused. Taken from the default instead, a broken 500 put the 404's
    # markup in the box and aimed `persist/4` at the 404, which the template validation then refused
    # over the 500 it had left alone — so the one door into an unopenable entry neither showed it nor
    # mended it. `Section.status/2` answers a status for every section; only an error page saves,
    # navigates or reads by it.
    status = Section.status(record, status: params["status"])

    socket
    |> assign(:admin_css, true)
    |> assign(:admin_fonts, true)
    |> assign(:page_title, gettext("Could not open"))
    |> assign(:section, section)
    |> assign(:record, record)
    |> assign(:status, status)
    |> assign(
      :recover,
      Map.put(fault, :template, Section.template(section, record, status: status))
    )
    |> assign(:recover_error, nil)
    |> assign(:typed, %{})
  end

  defp mount_editor(socket, section, params, record, actor, opened, editor) do
    if connected?(socket) do
      Events.session_opened(editor)
      EditorSession.subscribe(editor.token)
      Presence.join(editor.token, actor)
      subscribe_review()
      subscribe_folders()
      subscribe_asset_builds(editor)
    end

    socket = load_palette_async(socket, editor, actor, params)
    socket = warm_components(socket, editor)

    socket
    |> assign(:admin_css, true)
    |> assign(:admin_fonts, true)
    # THE JIT, here and in the canvas only. The reader types a class into the inspector and the
    # utility has to exist a frame later, which no build-time scan can anticipate. Every other admin
    # page is styled by the compiled `app.css` the layout links.
    |> assign(:live_tailwind, true)
    # The editor's own hooks (grips, shortcuts, the canvas bridge) live in the admin `app.js`, so the
    # builder loads that bundle rather than the site's: an admin page has no use for the site's
    # JavaScript, and the site bundle would neither carry these hooks nor tolerate a second
    # LiveSocket alongside them.
    |> assign(:standalone_assets, true)
    |> assign(:suppress_site_js, true)
    # Publishes WHERE CodeMirror lives, and downloads none of it. The drawer's editor asks for the
    # bundle the first time somebody opens a code box; a visit that never opens one pays nothing.
    |> assign(:code_editor, true)
    # THE BUILDER EDITS FOUR THINGS AND CALLED ITSELF THE SAME NAME FOR ALL OF THEM. A tab reading
    # "Page Builder" over a component is wrong twice: it names the wrong noun, and with four editors
    # open — a page, its layout, a component and an error page — the browser's tab strip is four
    # identical words. `Section.label/1` is the same wording the flash messages and the back link
    # already use, so the tab, the header and the error text agree.
    |> assign(:page_title, gettext("%{section} builder", section: section_label(section)))
    # THE SITE'S OWN COLOURS, beside the editor's five neutrals. A swatch row of hardcoded hex is a
    # palette that has nothing to do with the site being edited, so a rebrand means repainting every
    # element by hand — while the tokens the whole theme already resolves through sit in the Studio,
    # one panel away, unreachable from the control that paints things.
    #
    # OFF THE MOUNT, for the reason the palette is: `Tokens.list/1` reads every stylesheet row the
    # site can see and parses them, and an editor that cannot open because a swatch row could not be
    # filled has traded something it needs for something it would merely like. It is also read once
    # rather than per render — the Inspector redraws on every selection, and a query and a parse
    # between clicking an element and seeing its panel is a query and a parse too many.
    |> assign(:style_tokens, [])
    |> load_tokens_async(editor)
    |> assign(:asset_failures, asset_failures(editor, actor))
    |> assign(:section, section)
    # BACK TO WHERE THE AUTHOR CAME FROM. A component opened from a page's Inspector carries that
    # page's builder in `return_to`, so editing what the page uses is a trip rather than a detour
    # through the component list. See `Section.back_path/2` for why it is matched, not trusted.
    |> assign(:back_path, Section.back_path(section, params["return_to"]))
    |> assign(:record, record)
    # ASKED OF THE URL, not of the record. The two agree by the time this runs — `mount_document/3`
    # turns an id that resolves to nothing away — and the URL is the one that says what was MEANT: an
    # editor opened with no id is someone making a document, which is the only case that earns the
    # essentials step.
    |> assign(:new_document?, is_nil(params["id"]))
    # WHICH STATUS IS THE SESSION'S ANSWER, not the URL's. The two agree on every ordinary route —
    # both read `?status=` — but `?session=` JOINS a canvas someone else opened and carries nothing
    # else, so asking the URL there answered the default while the canvas showed the 500. Everything
    # keyed to this assign then went to a status nobody had open: the publish wrote the 500's markup
    # over the live 404, the fork copied into it, and the element-CSS prune kept the wrong tree's
    # scopes. `editor.status` is nil for the three sections that keep one template, which leaves the
    # URL to answer for them exactly as it did.
    |> assign(:status, Section.status(record, status: editor.status || params["status"]))
    |> assign(:statuses, Section.statuses(section, record, editor.status))
    # nil until the socket connects, which is what tells the centre column to draw the frame's loading
    # state instead of an iframe pointing at a session that is about to be replaced.
    |> assign(:token, connected?(socket) && editor.token)
    |> assign(:editors, Presence.others(editor.token, actor))
    |> assign_offers(section, params, record, actor, editor, opened, connected?(socket))
    |> assign_session_draft(section, record, actor, editor, connected?(socket))
    |> assign(:drafts_enabled?, Drafts.supported?(section) and not is_nil(record))
    |> assign(:drafts_resource, Drafts.resource(section))
    |> assign(:drafts_revision, 0)
    |> assign_editor(editor)
    |> assign_defaults()
  end

  # Work the last session left behind and never published — OFFERED, never loaded. Opening a page and
  # silently getting something other than the page is the behaviour this whole feature exists to
  # avoid; the bar says when it was left and lets the author take it or throw it away.
  #
  # Skipped when the session was resumed from memory (the work is already on screen), when the editor
  # is already pointed at a draft, and when the autosave is older than the live record — which means
  # it was published or superseded and is no longer news.
  #
  # AND SKIPPED ENTIRELY ON THE STATIC RENDER, which is a different bar's business. A disconnected
  # mount BUILDS a session rather than resuming one (`session/2`), so it can never know it walked
  # back into a draft — `inherited_draft` is nil, this bar's guard passes, and the amber bar paints
  # for one frame before the connected mount replaces it with the violet one. Two banners in a row
  # for one situation. It also saves the drafts query whose answer that render threw away.
  defp resumable(connected?, section, record, actor, editor)

  defp resumable(true, section, record, actor, %{draft_id: nil} = _editor)
       when not is_nil(record) do
    section
    |> Drafts.list(record, actor)
    |> Enum.find(&newer?(&1, record))
  end

  defp resumable(_connected?, _section, _record, _actor, _editor), do: nil

  # THE TWO BARS ANSWER ONE QUESTION — "which document did you mean?" — so they are decided together
  # and only ever one of them is filled.
  #
  # `?draft_id=` is that question already answered, out loud, by somebody who picked a draft in the
  # preview modal and clicked through to the editor. It used to be answered again here, from the
  # table: the editor read the drafts for itself and offered whichever was newest, so choosing the
  # second badge and clicking Visual Editor arrived at an offer to carry on with the FIRST — and if
  # the session happened to be resumed, at an offer to carry on with whatever the last sitting was
  # in, which had nothing to do with the click at all.
  #
  # A named draft therefore takes the carry-on bar and empties the other one: the resume bar's
  # sentence ("you are looking at the live page", never published) is about work nobody asked for,
  # and its Discard DELETES — neither belongs over a draft that was just deliberately chosen.
  defp assign_offers(socket, section, params, record, actor, editor, opened, connected?) do
    case chosen_draft(connected?, section, record, actor, params["draft_id"]) do
      # ALREADY THERE. A URL naming the draft the session is ALREADY in has asked for nothing —
      # there is no other document to offer, and a bar reading "you picked X, and this editor is
      # still in X" is a question with one answer. The ordinary carry-on bar below is the one that
      # says which draft you are in; this hands the visit back to it.
      %{id: id} = chosen when id != editor.draft_id ->
        socket
        |> assign(:resumable, nil)
        |> assign(:inherited_draft, inherited_draft(opened, editor, chosen))

      _nothing_new ->
        socket
        |> assign(:resumable, resumable(connected?, section, record, actor, editor))
        # ARRIVING BACK INTO SOMEONE ELSE'S SENTENCE. The session outlives a reload, which is what
        # stops a refresh throwing work away — but it also meant walking into the editor and
        # silently being somewhere other than the live page, with a draft already open and no word
        # about it. Whether a draft is CHOSEN or INHERITED is the difference: choosing one
        # mid-session needs no announcement, inheriting one on the way in does. Set only here, so it
        # asks once per visit.
        |> assign(:inherited_draft, inherited_draft(opened, editor, nil))
    end
  end

  # The id is read against the LIST rather than fetched, so a draft that belongs to another document
  # — or to a site this actor cannot see — resolves to nothing and the URL is simply ignored. Read on
  # the connected mount only, like every other draft question here: the static render has no bar to
  # paint and would only throw the answer away.
  defp chosen_draft(true, section, record, actor, id)
       when is_binary(id) and id != "" and not is_nil(record),
       do: section |> Drafts.list(record, actor) |> Enum.find(&(&1.id == id))

  defp chosen_draft(_connected?, _section, _record, _actor, _id), do: nil

  defp newer?(%{updated_at: draft_at}, %{updated_at: record_at})
       when not is_nil(draft_at) and not is_nil(record_at),
       do: DateTime.compare(draft_at, record_at) == :gt

  defp newer?(_draft, _record), do: false

  # THE DRAFT THE LAST SITTING WAS IN, as an OFFER rather than a state the reader was put back into.
  #
  # A reload used to land inside that draft and then ask whether to carry on with it — a question
  # already answered before it was shown, which is why Carry on appeared to do nothing. Opening is
  # the live page, always; the draft is a row in the list and this bar is the way back to it.
  #
  # Carries the id as well as the label, because Carry on now has to be able to OPEN it. `nil` when
  # nothing was inherited — never `false`, because the banner and the resume bar both test with
  # `is_nil/1` and `false` is not nil.
  #
  # `source` is what the bar's sentence turns on: one of these is news about the last sitting, the
  # other is the click that got here, and telling somebody they "were working in" a draft they chose
  # ten seconds ago on the previous screen is a bar that reads like it misunderstood.
  defp inherited_draft(_opened, _editor, %{id: id, label: label}),
    do: %{id: id, label: label || gettext("that draft"), source: :chosen}

  defp inherited_draft(:resumed, %{draft_id: id, draft_label: label}, nil) when is_binary(id),
    do: %{id: id, label: label || gettext("your last draft"), source: :session}

  defp inherited_draft(_opened, _editor, nil), do: nil

  # `?session=<token>` JOINS an open session instead of starting a fresh one. That is what makes
  # co-editing real: without it two admins on the same URL each get their own private tree, presence
  # shows nobody, and the avatars would be decoration. A token that has expired or names a different
  # document falls back to opening normally rather than erroring.
  defp resume_or_open(section, params, record, actor, connected?) do
    with token when is_binary(token) <- params["session"],
         {:ok, editor} <- EditorSession.fetch(token),
         true <- editor.resource_id == params["id"],
         true <- joinable_status?(editor, section, record, params) do
      {:ok, editor}
    else
      _fresh -> own_session_or_open(section, params, record, actor, connected?)
    end
  end

  # AN ADDRESS THAT NAMES BOTH ANSWERS ITSELF. `?session=` says "the canvas I am on" and `?status=`
  # says "the entry I want"; an error page has one template per status, so when the two disagree
  # joining anyway would put someone who asked for the 404 on the host's 500 and publish it there.
  # The token is the one refused — the status was spelled out, the token only points at a canvas —
  # and the entry that was asked for opens in a session of its own.
  #
  # Only when the URL says so. A plain `?session=` carries no status because the status is the
  # SESSION'S, and every other section answers nil on both sides.
  defp joinable_status?(editor, section, record, %{"status" => asked}),
    do: editor.status == Section.editing_status(section, record, status: asked)

  defp joinable_status?(_editor, _section, _record, _params), do: true

  # Reopening the SAME document picks up where it was left, without a token in the URL. A reload — or
  # a canvas that crashed and took the frame with it — used to mint a new token and rebuild from the
  # database, which threw away every edit since the last save with nothing said. The session outlives
  # both; only the lookup was missing.
  #
  # Scoped to this actor, so it resumes YOUR session and never silently joins someone else's; that is
  # what `?session=` is for, deliberately and by invitation.
  defp own_session_or_open(section, params, record, actor, true = connected?) do
    case EditorSessionState.find(
           Section.to_underscored(section),
           params["id"],
           actor && actor.id,
           Section.editing_status(section, record, status: params["status"])
         ) do
      # PUBLISH-MODE WORK IS NOT PICKED BACK UP. Nothing was written for it — that is what publish
      # mode means — so resuming would show edits with nowhere to go, and the reload that was
      # supposed to bring back the original would bring back a ghost of them instead.
      {:ok, %{stage: :published}} ->
        open_session(section, params, record, actor, connected?)

      # A SESSION THAT WAS IN A DRAFT REOPENS ON THE LIVE PAGE. The draft is not lost — it is a saved
      # row, and the bar above the canvas offers it by name — but walking back in and being silently
      # somewhere other than the live page is the thing the whole draft model exists to avoid.
      # `inherited_draft/2` reads the draft off this same session to build that offer, so nothing is
      # forgotten by detaching here.
      {:ok, %{draft_id: id} = editor} when is_binary(id) ->
        {:resumed, detach_draft(editor, section, record, params)}

      {:ok, editor} ->
        {:resumed, editor}

      :error ->
        open_session(section, params, record, actor, connected?)
    end
  end

  defp own_session_or_open(section, params, record, actor, connected?),
    do: open_session(section, params, record, actor, connected?)

  # Back to what the live record says, with the draft's name kept only long enough for the bar to
  # offer it. A failure to re-read the live template leaves the session exactly as it was, which is
  # the safe half of the trade: still in the draft, and the bar still says so.
  #
  # THE HELD ELEMENT CSS STAYS HELD. The markup of this sitting survives detaching — it is a Drafts
  # row, and the bar offers it by name — and the CSS typed beside it has no row anywhere, so dropping
  # it here would make an ordinary reload the one gesture that deletes an author's work outright. The
  # publish prunes it against the markup that is actually being written, so holding it costs nothing.
  defp detach_draft(editor, section, record, params) do
    with false <- is_nil(record),
         {:ok, tree} <- Tree.parse(Section.template(section, record, status: params["status"])),
         {:ok, _editor} <-
           EditorSession.put_tree(editor.token, tree, reason: :restore, dirty?: false),
         {:ok, detached} <-
           EditorSession.mark_saved(editor.token, stage: :draft, draft_id: nil, draft_label: nil) do
      %{detached | draft_id: editor.draft_id, draft_label: editor.draft_label}
    else
      _unavailable -> editor
    end
  end

  # The palette is read once when the session opens, so a component installed FROM the Studio would
  # not appear in it until a reload. Re-reading it here is what makes Install mean "you can place
  # this now".
  defp reload_palette(socket) do
    params = %{"site_id" => socket.assigns.editor.site_id}

    case palette_components(socket.assigns[:current_user], params, socket.assigns.editor) do
      {:ok, components} ->
        {:ok, _editor} = EditorSession.put_components(socket.assigns.token, components)
        sync_session(socket, socket.assigns.token)

      # Already logged. The palette the author is looking at is the one they had a moment ago, which
      # is a better answer than emptying it because a re-read after an install did not land.
      {:error, _reason} ->
        put_flash(
          socket,
          :error,
          gettext("Could not refresh the component list — try again in a moment.")
        )
    end
  end

  # The palette is 183 rows carrying every component's template, attrs, slots, helpers AND its
  # examples — 3.4 MB and 1.6 seconds of it, measured. It used to be read HERE, synchronously, on
  # both the dead render and the connected mount: three seconds before the editor drew anything, for
  # a list nobody has reached for yet.
  #
  # It now opens empty and arrives through `handle_async(:palette, …)`, so the shell paints at once
  # and the panel shows its skeleton until the list lands.
  defp open_session(section, params, record, actor, connected?) do
    session(connected?, %{
      section: Section.to_underscored(section),
      resource_id: params["id"],
      site_id: site_id(actor, params, record),
      site_name: site_name(record),
      actor_id: actor.id,
      template: Section.template(section, record, status: params["status"]),
      status: Section.editing_status(section, record, status: params["status"]),
      components: []
    })
  end

  defp session(true, attrs), do: EditorSession.open(attrs)
  defp session(false, attrs), do: EditorSession.build(attrs)

  @doc """
  The URL that invites someone else into THIS editing session — the same page plus the session
  token, so both browsers drive one document and each sees the other in the avatar row.

  It names the status as well, for the one section that has several. The token answers which entry
  is open only while the session lives, and a link pasted into a chat is followed later — without
  the status that reader lands on the 404 when the invitation was written on the 500. The two agree
  by construction, which is what `resume_or_open/5` asks of an address naming both.
  """
  @spec share_url(map()) :: String.t()
  def share_url(%{section: section, record: record, token: token} = assigns)
      when not is_nil(record),
      do: Section.builder_path(section, record.id) <> invitation(token, assigns)

  def share_url(%{section: section, token: token} = assigns),
    do: Section.builder_path(section) <> invitation(token, assigns)

  # A TOKEN IS ONE ONLY ONCE THE SOCKET IS UP — `:token` is `false` on the static render — and an
  # address carrying `session=false` invites a reader into a session that never existed. The bare
  # path opens the document instead, which is what the invitation meant.
  defp invitation(token, _assigns) when not is_binary(token), do: ""

  # And the status rides with a RECORD. A document being made has no entries yet, so naming one of
  # them is a query string with nothing behind it.
  defp invitation(token, %{record: %{}, editor: %{status: status}})
       when is_integer(status) or status == :offline,
       do: "?" <> URI.encode_query(session: token, status: status)

  defp invitation(token, _assigns), do: "?" <> URI.encode_query(session: token)

  # The freshly written row, read back the way the mount reads it — or the one the save answered
  # with, when that read cannot be made. A record with a thin `site` is still the right name and the
  # right path; refusing to show them because a badge would read "This site" would be the worse
  # trade.
  # A SESSION RESUMED INSIDE A DRAFT IS STILL WRITING IT, before anyone answers the carry-on bar, so
  # `@draft` is that row from the first render — the settings and the original's notice read it.
  defp assign_session_draft(socket, section, record, actor, %{draft_id: id}, true)
       when is_binary(id) and not is_nil(record) do
    case section |> Drafts.list(record, actor) |> Enum.find(&(&1.id == id)) do
      nil -> socket
      draft -> assign(socket, :draft, draft)
    end
  end

  defp assign_session_draft(socket, _section, _record, _actor, _editor, _connected?), do: socket

  # WHILE THE EDITOR WRITES A DRAFT, ITS SETTINGS ARE THE DRAFT'S. The draft carries the whole
  # document and publishing it writes all of it over the page, so a setting saved to the page while
  # a draft is open came back undone at its publish. In Publish mode, and before a change has made a
  # draft, they are the page's.
  defp settings_draft(:draft, %{} = draft), do: draft
  defp settings_draft(_stage, _draft), do: nil

  # A page's layout is drawn around its canvas, and it is one of the settings — so the canvas is told
  # to read it again.
  defp settings_saved(socket, record) do
    if is_binary(socket.assigns[:token]),
      do: EditorSession.announce(socket.assigns.token, {:layout, Map.get(record, :layout_id)})

    socket
    |> assign(settings_open?: false, seo_form?: false)
    |> saved_settings(record)
    |> put_flash(:info, gettext("Saved."))
  end

  defp saved_settings(socket, %resource{} = record) do
    if resource == Drafts.resource(section(socket)),
      do: assign(socket, :draft, record),
      else: assign(socket, :record, reloaded(socket, record))
  end

  defp reloaded(socket, record) do
    case load_record(section(socket), record.id, socket.assigns[:current_user]) do
      {:ok, loaded} -> loaded
      _unreadable -> record
    end
  end

  defp load_record(_section, nil, _actor), do: :none

  defp load_record(section, id, actor) do
    resource = Section.resource(section)

    with {:ok, opts} <- Section.read_opts(resource, actor),
         {:ok, record} <- Ash.get(resource, id, opts) do
      editable(record, actor)
    else
      _unreadable -> :gone
    end
  end

  # A GLOBAL DOCUMENT IS EVERY SITE'S, AND THEREFORE NOT THIS SITE'S TO CHANGE. `Layout` and
  # `Component` both accept a nil `site_id`, and every site sees and places those rows — that is what
  # makes them worth having. Editing one is a different act: it rewrites the thing thirty sites are
  # currently rendering, and the resources say so themselves ("Global layouts can only be modified by
  # master users") from inside their `:update` validation.
  #
  # The editor used to let a tenant all the way in and only tell them at Publish, after the work.
  # The read that got them there is the right read — `:get_for_tenant_with_globals` is how a tenant
  # legitimately SEES a shared row — so the answer is not to blind it but to separate the two
  # questions: what may this actor read, and what may they edit.
  #
  # The cross-site clause is belt and braces. No tenant read returns another site's row today; it is
  # here so that "a tenant never opens another tenant's document" is a property of this function
  # rather than a property of eight action definitions elsewhere.
  defp editable(record, %{site_id: nil}), do: {:ok, record}

  defp editable(record, %{site_id: site_id}) when is_binary(site_id) do
    case record.site_id do
      nil -> :shared
      ^site_id -> {:ok, record}
      _elsewhere -> :gone
    end
  end

  defp site_name(%{site: %{name: name}}), do: name
  defp site_name(_record), do: nil

  defp site_id(%{site_id: nil}, params, record), do: params["site_id"] || record_site_id(record)
  defp site_id(%{site_id: site_id}, _params, _record) when is_binary(site_id), do: site_id

  defp record_site_id(%{site_id: site_id}), do: site_id
  defp record_site_id(_record), do: nil

  defp assign_defaults(socket) do
    socket
    |> assign_new(:left_tab, fn -> :components end)
    |> assign_new(:icon_picker, fn -> nil end)
    |> assign_new(:aim_target, fn -> nil end)
    |> assign_new(:act_action, fn -> nil end)
    |> assign_new(:group_folds, fn -> %{} end)
    |> assign_new(:example_tab, fn -> :examples end)
    |> assign_new(:wizard, fn -> %{} end)
    |> assign_new(:icon_query, fn -> "" end)
    |> assign_new(:icon_variant, fn -> "" end)
    |> assign_new(:icon_library, fn -> nil end)
    |> assign_new(:right_tab, fn -> :layers end)
    |> assign_new(:left_w, fn -> 344 end)
    |> assign_new(:right_w, fn -> 300 end)
    |> assign_new(:drawer_h, fn -> 300 end)
    |> assign_new(:left_hidden, fn -> false end)
    |> assign_new(:right_hidden, fn -> false end)
    # WHERE THE SESSION LEFT IT, not always desktop. The breakpoint is restored from the saved
    # session; the frame was not. Reopen an editor last used on Mobile and the Mobile tab is active
    # over a desktop-width canvas — and the first click on Mobile then appears to do nothing, because
    # the tab it highlights was already the one highlighted.
    |> assign_new(:device, fn -> frame_for(socket.assigns[:breakpoint]) end)
    |> assign_new(:zoom, fn -> 100 end)
    |> assign_new(:frame_zoom, fn -> 30 end)
    |> assign_new(:frame_row, fn -> true end)
    |> assign_new(:code_open, fn -> false end)
    # The top bar's Code. `nil` rather than `false` for the error so an empty string can mean
    # "there is a message and it is blank" without being mistaken for "no message".
    |> assign_new(:url_state, fn -> nil end)
    # COUNTED ONCE, THEN MAINTAINED. It used to be recomputed at the end of `assign_editor/2`,
    # which meant a `SELECT count(*)` on every selection, every breakpoint switch and every undo — in
    # both LiveViews — for a number only four things can change. All four already say so:
    # `{:review, :changed}` from a co-editor's session, `PageComment`'s own notification from someone
    # who never shared one, and `refresh_review/1` for a write made here. So it is seeded here and
    # left alone until one of them arrives.
    |> assign_new(:open_bugs, fn -> Review.open_bugs(Panels.review_scope(socket.assigns)) end)
    |> assign_new(:review_revision, fn -> 0 end)
    |> assign_new(:reply_to, fn -> nil end)
    |> assign_new(:find_open, fn -> false end)
    |> assign_new(:find, fn -> "" end)
    |> assign_new(:replace, fn -> "" end)
    |> assign_new(:find_hits, fn -> [] end)
    |> assign_new(:class_draft, fn -> %{} end)
    |> assign_new(:typed, fn -> %{} end)
    |> assign_new(:class_error, fn -> nil end)
    |> assign_new(:component_presets, fn -> %{} end)
    |> assign_new(:presets_count, fn -> -1 end)
    |> assign_new(:classes, fn ->
      Classes.all(socket.assigns[:current_user], socket.assigns.editor.site_id)
    end)
    |> assign_new(:mentions, fn -> [] end)
    |> assign_new(:note_on_page?, fn -> false end)
    |> assign_new(:source_modal, fn -> false end)
    |> assign_new(:source_draft, fn -> nil end)
    # WHETHER THIS DEPLOYMENT TAKES CODE. Whoever opened this builder may write its document's code
    # (`Section.permissions/1`); `:page_code` set to `:off` stops it for everyone.
    |> assign_new(:code_allowed?, fn -> CodeAccess.enabled?() end)
    # The selected form as it was when its rename began, and the stored handler names that rename
    # moves onto a token (`Inspector.retagged/3`).
    |> assign_new(:rename_origin, fn -> nil end)
    |> assign_new(:retagged, fn -> %{} end)
    |> assign_new(:folder_form?, fn -> false end)
    |> assign_new(:preview_media, fn -> nil end)
    |> assign_new(:source_error, fn -> nil end)
    |> assign_new(:source_tab, fn -> :template end)
    # What the Handlers tab puts in front of the reader: `{:entry, index}` or `{:form, node_id}`.
    |> assign_new(:code_focus, fn -> nil end)
    |> assign_new(:element_css_rules, fn ->
      # AND INTO THE SESSION, not only into these assigns. The canvas renders this CSS from
      # `session.element_css`, and nothing but `save_element_css` ever wrote it — so a document
      # reopened with element CSS already saved showed the author their rules in the panel while the
      # frame had no `<style>` for them at all. Written where they are read, so the two cannot part.
      #
      # THE ROW PLUS WHAT THE SESSION IS HOLDING. Draft-stage CSS is not in the row — that is the
      # point of it — so a reconnect that read the row alone would show the author the live page's
      # rules and paint the canvas with them, over an element they styled ten seconds ago.
      rules =
        socket.assigns[:current_user]
        |> ElementCss.all(socket.assigns.editor.site_id, css_owner(socket))
        |> ElementCss.merge(socket.assigns.editor.staged_element_css)

      EditorSession.set_element_css(socket.assigns.token, ElementCss.css(rules))
      rules
    end)
    # COLLECTED ONCE, not per render. Both libraries are merged with whatever extensions contribute
    # here rather than inside the Blocks panel, because that panel is a render function — a plugin's
    # code was running twice on every debounced keystroke in the search box. A plugin set does not
    # change mid-session, so once at mount is also when it is true.
    # SCOPED TO THE DOCUMENT for the reason the elements are: the three form blocks are bound to
    # handlers, and only a Page has an `events` column to hold one.
    |> assign_new(:block_library, fn ->
      Events.collect_appended(
        :blocks,
        MishkaCmsCore.Runtime.PageBuilder.Blocks.for_section(section(socket))
      )
    end)
    # SCOPED TO THE DOCUMENT, because four of them are. `{@inner_content}` is an assign only a layout
    # is handed, and offering it on a page would be offering a document that will not compile.
    |> assign_new(:element_library, fn ->
      Events.collect_appended(
        :elements,
        MishkaCmsCore.Runtime.PageBuilder.Elements.for_section(section(socket))
      )
    end)
    |> assign_new(:element_css_error, fn -> nil end)
    |> assign_new(:element_css_advice, fn -> nil end)
    |> assign_new(:js_hooks, fn ->
      Hooks.registry(
        socket.assigns[:current_user],
        socket.assigns.editor.site_id,
        socket.assigns.editor.site_name
      )
    end)
    |> assign_new(:code_fault, fn -> nil end)
    |> assign_new(:fragments, fn -> code_fragments(socket.assigns[:record]) end)
    |> assign_new(:code_tab, fn -> :html end)
    |> assign_new(:heex_error, fn -> nil end)
    |> assign_new(:sheet, fn -> :none end)
    |> assign_new(:settings_open?, fn -> false end)
    |> assign_new(:settings_tab, fn -> :general end)
    # The SEO tab's draft, read from the record when the tab first opens; nil while it is closed.
    |> assign_new(:seo_form?, fn -> false end)
    |> assign_new(:command_open, fn -> false end)
    |> assign_new(:command_query, fn -> "" end)
    |> assign_new(:palette_query, fn -> "" end)
    |> assign_new(:palette_cat, fn -> "all" end)
    |> assign_new(:attr_form, fn -> false end)
    |> assign_new(:tokens_revision, fn -> 0 end)
    |> assign_new(:snippets_revision, fn -> 0 end)
    |> assign_new(:examples_for, fn -> nil end)
    |> assign_new(:examples, fn -> Phoenix.LiveView.AsyncResult.ok([]) end)
    |> assign_new(:example_index, fn -> 0 end)
    |> assign_new(:example_device, fn -> "desktop" end)
    |> assign_new(:studio_tab, fn -> :tokens end)
    |> assign_new(:studio_scope, fn -> :all end)
    |> assign_new(:studio_cat, fn -> "all" end)
    |> assign_new(:studio_query, fn -> "" end)
    |> assign_new(:reload_confirm, fn -> false end)
    # Where the author was going when the editor stopped them, and the only thing that renders the
    # question. Nil is the ordinary state: nothing to lose, or nobody leaving.
    |> assign_new(:leave_to, fn -> nil end)
    |> assign_new(:ai_attachment, fn -> nil end)
    |> assign_new(:autosave_failed?, fn -> false end)
    # Which property the Inspector should land on, set when a property row in the tree is clicked.
    |> assign_new(:focus_attr, fn -> nil end)
    |> assign_studio_settings()
    |> assign_new(:token_format, fn -> :tw end)
    # Loading, not `ok([])`. The rail is only ever drawn inside the Assets sheet and opening that
    # sheet is what reads the folders, so an empty ok here was the editor answering "this site has no
    # folders" for the length of the query it had not run yet — the one answer the reader cannot tell
    # apart from the truth.
    |> assign_new(:media_categories, fn -> Phoenix.LiveView.AsyncResult.loading() end)
    |> assign_new(:assets_category, fn -> nil end)
    |> assign_new(:media_target, fn -> nil end)
    |> assign_new(:history_revision, fn -> 0 end)
    |> assign_new(:history_clearable?, fn -> false end)
    |> assign_new(:history_flushing?, fn -> false end)
    |> assign_new(:history_reverting?, fn -> false end)
    |> assign_new(:history_flush_again?, fn -> false end)
    |> assign_new(:history_recording?, fn -> true end)
    |> assign_new(:draft, fn -> nil end)
    # WHETHER THAT ROW IS ONE THE AUTHOR CHOSE. Autosave attaches a row of its own on the first
    # change, so `@draft` is set on the live page too — and it is the live page's working copy, its
    # fields frozen at that first keystroke. Only a draft that was OPENED is another document, and
    # only another document is something to copy from; see `write_draft/3`.
    |> assign_new(:draft_opened?, fn -> false end)
    |> assign_new(:history_tab, fn -> :history end)
    |> assign_new(:autosaving?, fn -> false end)
    |> assign_new(:autosaving_revision, fn -> nil end)
    |> assign_new(:draft_again?, fn -> false end)
    # The publish-mode bar is down while the draft it asked for is being written. It is the bar's
    # own flag and not the session's `dirty?`, because clearing that is what stops the write.
    |> assign_new(:keeping_draft?, fn -> false end)
    # THE NAME THIS SESSION'S WORK IS KEPT UNDER, decided when the editor opens and stamped with the
    # time so two sittings — and two people — never write over each other. The old automatic save
    # owned one row called "Autosave" per document, so a colleague's session and yesterday's session
    # were the same row.
    |> assign_new(:draft_label, fn -> session_draft_label() end)
    |> assign_new(:dev_mode?, fn -> false end)
    |> assign_new(:drafts_enabled?, fn -> false end)
    |> assign_new(:draft_conflict, fn -> nil end)
    |> assign_new(:theme, fn -> "light" end)
    |> assign_new(:ai_messages, fn -> [] end)
    |> assign_new(:ai_prompt, fn -> "" end)
    |> assign_new(:ai_backend, fn -> AiBackend.adapter().name() end)
    # The Studio chip counts the tokens this site added on top of the theme's own. It asked with no
    # site at all, which reads the GLOBAL sheets — the one place a site's own token can never be —
    # and `assign_new` meant it was answered once at mount and never again, so editing a token left
    # the count behind. Counted off the sheet load the Studio already does, in `handle_async`.
    |> assign_new(:studio_badge, fn -> 0 end)
    |> assign_new(:stage, fn -> :draft end)
    |> assign_new(:mob_panel, fn -> :canvas end)
    # A PLUGIN'S ENTRY NAMES WHO MAY SEE IT (`MishkaCmsCore.Builder.Descriptor.permitted/2`), and an
    # entry the reader may not see is not drawn, so its events never fire either.
    |> assign_new(:rails, fn -> permitted(Events.collect(:rails, Panels.core_rails()), socket) end)
    |> assign_new(:inspector_sections, fn ->
      permitted(Events.collect(:inspector_sections, Panels.core_inspector_sections()), socket)
    end)
    |> assign_new(:commands, fn ->
      permitted(Events.collect(:commands, Panels.core_commands()), socket)
    end)
    # NO `:toolbar` HERE. The element toolbar is drawn inside the frame, by `CanvasLive`, which
    # collects `builder:canvas:toolbar` with the seed it renders. Collecting it again out here draws
    # nothing and fires every plugin a second time, with a seed that disagrees with the one on
    # screen — which is what it used to do.
    |> assign_new(:goto, fn -> goto_targets(socket.assigns[:current_user]) end)
    # A MASTER has no `site_id` of their own, which is exactly what lets them install for every
    # site. A tenant is scoped by the same field, so the two questions share one answer.
    |> assign_new(:registry_master?, fn -> master?(socket.assigns[:current_user]) end)
    # This site by default, even for a master: the editor is open on one site, and sharing a
    # package with every site on the server should be a thing someone chose.
    |> assign_new(:block_cat, fn -> "all" end)
    |> assign_new(:block_query, fn -> "" end)
  end

  # THE ACTOR IS THE SESSION'S, as it is everywhere else that writes runtime rows. The scope this
  # site_id came from is already the actor's own — `UiKitHandler.install_scope/2`, above — and now
  # the WRITE is theirs too, so the component's policy answers for them and its history says who
  # installed it instead of nobody.
  defp install_package(socket, id, site_id) do
    case Marketplace.install(:package, id, site_id, socket.assigns[:current_user]) do
      {:ok, %{installed: [_only]}} ->
        {:noreply,
         socket |> put_flash(:info, gettext("%{id} installed.", id: id)) |> reload_palette()}

      {:ok, %{installed: installed}} ->
        extra = length(installed) - 1

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{id} installed, with %{extra} it depends on.", id: id, extra: extra)
         )
         |> reload_palette()}

      {:ok, _other} ->
        {:noreply,
         socket |> put_flash(:info, gettext("%{id} installed.", id: id)) |> reload_palette()}

      :ok ->
        {:noreply,
         socket |> put_flash(:info, gettext("%{id} installed.", id: id)) |> reload_palette()}

      {:error, {:not_available, message}} ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, human(reason))}
    end
  end

  defp master?(%{site_id: nil}), do: true
  defp master?(_actor), do: false

  # The palette's "Go to" group is the admin's real menu, already permission-filtered by
  # `MishkaCmsCore.Sidebar.menu/1` — so it can never offer a page this user would be refused, and it
  # picks up whatever an extension registered on `sidebar:menus` without knowing those routes here.
  defp goto_targets(actor) do
    %{main: main, footer: footer} = Sidebar.menu(actor)

    (main ++ footer)
    |> Enum.flat_map(fn
      %{items: items} -> items
      item -> [item]
    end)
    |> Enum.map(&%{key: &1.key, label: &1.label, path: &1.path, icon: &1.icon})
  end

  # The mobile bar names a panel, not a tab, so the panel it opens has to be showing the right one.
  defp assign_panel_tab(socket, panel) when panel in [:components, :inspector],
    do: assign(socket, :left_tab, panel)

  defp assign_panel_tab(socket, panel) when panel in [:layers, :assistant, :audit],
    do: assign(socket, :right_tab, panel)

  defp assign_panel_tab(%{assigns: %{rails: rails}} = socket, panel) do
    case Enum.any?(rails, &(to_string(Descriptor.key(&1)) == to_string(panel))) do
      true -> assign(socket, :right_tab, panel)
      false -> socket
    end
  end

  defp assign_panel_tab(socket, _panel), do: socket

  # Read back on every write and on mount, so the switches show what is stored rather than what was
  # clicked.
  defp prompt_with(text, nil), do: text

  defp prompt_with(text, %{source: source, label: label}),
    do: text <> "\n\n<!-- attached: " <> label <> " -->\n" <> source

  defp attach(socket, :selection) do
    node = socket.assigns[:selected_node]
    tree = socket.assigns.editor.tree

    source = tree |> Tree.subtree(node.id) |> Serializer.serialize()

    socket
    |> assign(:ai_attachment, %{
      kind: :selection,
      label:
        ngettext(
          "%{tag} · %{bytes} byte",
          "%{tag} · %{bytes} bytes",
          byte_size(source),
          tag: Panels.selection_tag(node),
          bytes: byte_size(source)
        ),
      source: source
    })
  end

  defp attach(socket, :template) do
    source = socket.assigns.editor.tree |> Serializer.serialize()

    socket
    |> assign(:ai_attachment, %{
      kind: :template,
      label:
        ngettext(
          "whole template · %{bytes} byte",
          "whole template · %{bytes} bytes",
          byte_size(source),
          bytes: byte_size(source)
        ),
      source: source
    })
  end

  defp reload_canvas(socket) do
    socket
    |> assign(:reload_confirm, false)
    |> push_event("pb:reload-canvas", %{})
  end

  defp assign_studio_settings(socket) do
    site_id = socket.assigns.editor.site_id

    options =
      Map.new(Panels.studio_options(), fn {key, _label, _note} ->
        {key, Settings.get(key, false, site_id) == true}
      end)

    socket
    |> assign(:studio_options, options)
    |> assign(:license_token, Settings.get("studio.license_token", "", site_id))
    |> assign(
      :registry_source,
      Settings.get("studio.registry_source", "registry.mishka.tools", site_id)
    )
    |> assign(:applied_preset, Settings.get("studio.applied_preset", nil, site_id))
  end

  # Two levels open on arrival — the roots and their children — because a tree that starts fully
  # collapsed shows one row and says nothing about the page, and one that starts fully open buries
  # the shape of it in text nodes. Only branches that HAVE children are listed, so the set never
  # holds an id whose row draws no chevron.
  defp default_expanded(tree) do
    children = Enum.flat_map(tree.roots, &branch_ids(tree, &1))

    MapSet.new(Enum.filter(tree.roots, &branch?(tree, &1)) ++ children)
  end

  defp branch_ids(tree, id) do
    case Tree.get(tree, id) do
      nil -> []
      node -> Enum.filter(node.children, &branch?(tree, &1))
    end
  end

  defp branch?(tree, id) do
    case Tree.get(tree, id) do
      %{children: [_ | _]} -> true
      _leaf_or_missing -> false
    end
  end

  # Selecting a component on the canvas opens it in the tree as well, so its children and its markup
  # are there without a second click.
  #
  # ITS PROPERTIES ARE NOT OPENED WITH IT, and used to be. A `chelekom-modal` declares nineteen of
  # them; expanding that group on selection pushed the component's own children some four hundred
  # pixels down the rail, behind rows that are not drop targets and never were. So the commonest
  # thing an author does with a dialog — drag something into it — had no reachable target in the
  # tree, which is exactly how it was reported: "so much property listed instead of under
  # something". The group is one click away and its row says how many it holds.
  #
  # Opening the branch is not enough when the tree is long: the row can be five hundred pixels below
  # the fold. The scroll is pushed rather than left to the hook's own lifecycle — the rail is patched
  # row by row and `updated()` does not reliably fire for an attribute deep inside it, which is why
  # selecting on the canvas left the rail wherever it was.
  defp expand_selected(socket, %{selection: id}) when is_binary(id) do
    socket
    |> update(:expanded, &MapSet.put(&1, id))
    |> push_event("pb:reveal-layer", %{id: id})
  end

  defp expand_selected(socket, _editor), do: socket

  defp assign_editor(socket, editor) do
    {undone, total} = EditorSession.history_counter(editor)

    socket
    |> release_page_scope(editor.selection)
    |> follow_left_form(editor)
    |> assign_new(:expanded, fn -> default_expanded(editor.tree) end)
    |> expand_to_selection(editor)
    |> expand_selected(editor)
    |> assign(:editor, editor)
    |> assign(:tree, editor.tree)
    |> assign_presets(editor)
    |> assign(:selection, editor.selection)
    |> assign(:marked, editor.marked)
    |> assign(:picked, editor.picked)
    |> assign(:selected_node, Tree.get(editor.tree, editor.selection))
    |> then(&assign(&1, :element_css, selected_css(&1, editor)))
    |> then(&assign(&1, :element_css_advice, ElementCss.advice(&1.assigns.element_css)))
    |> assign(:crumbs, Tree.path(editor.tree, editor.selection))
    |> assign(:breakpoint, editor.breakpoint)
    |> assign(:pseudo, editor.pseudo)
    |> assign(:dir, editor.dir)
    |> assign(:preview?, editor.preview?)
    |> assign(:dirty?, editor.dirty?)
    |> assign_applied_stage(editor)
    |> assign(:saved_at, editor.saved_at)
    |> assign(:history_position, undone)
    |> assign(:history_total, total)
    |> assign(:can_undo?, editor.past != [])
    |> assign(:can_redo?, editor.future != [])
    |> assign(:clipboard_label, editor.clipboard_label)
    |> assign_drafts_url_state()
    |> assign_history_url_state()
    |> assign_history_clearable()
    |> assign_tokens_url_state()
    |> assign_snippets_url_state()
    |> assign_snippet_defaults()
    |> assign_snippet_source()
    |> draft_the_change(editor)
  end

  # WRITTEN AS IT HAPPENS, not on a clock. A thirty-second timer is a promise to lose up to thirty
  # seconds of work, and a draft row is cheap — no `SendToOban`, no compile, one small update.
  #
  # The session's revision is what says "the document moved": `assign_editor/2` also runs for a
  # selection, a hover and a breakpoint switch, and none of those are worth a write.
  #
  # COUNTED, NOT MEASURED. This asked `{length(past), length(future)}`, and the undo stack is capped
  # while every change empties the redo stack — so once the stack filled, from that change onward
  # the pair was `{50, 0}` before and after every edit, and this returned untouched. Autosave stopped
  # and so did the history flush: an afternoon's work past that point was neither saved as a draft
  # nor recorded as having happened.
  defp draft_the_change(socket, editor) do
    case socket.assigns[:drafted_revision] == editor.revision do
      true ->
        socket

      false ->
        socket |> assign(:drafted_revision, editor.revision) |> autosave() |> flush_history()
    end
  end

  # THE HISTORY IS WRITTEN IN PUBLISHED STAGE TOO, which is the one thing autosave above does not do
  # — `autosave/1` returns untouched there on purpose, because nothing may be written to the page.
  # The page still is not; the record of what somebody did is. That is what stopped "leave in publish
  # mode" meaning "lose it".
  #
  # Off the LiveView process, like the draft write beside it, and idempotent: entries carry ids
  # minted when they settled, so a flush that overlaps another upserts rather than duplicating.
  defp cancel_running_revert(%{assigns: %{history_reverting?: true}} = socket),
    do: cancel_async(socket, :history_revert)

  defp cancel_running_revert(socket), do: socket

  defp flush_history(%{assigns: %{history_flushing?: true}} = socket),
    do: assign(socket, :history_flush_again?, true)

  defp flush_history(socket) do
    %{token: token, current_user: actor} = socket.assigns

    socket
    |> assign(:history_flushing?, true)
    |> assign(:history_flush_again?, false)
    |> MishkaGervaz.Messages.start_async(:history_flush, fn -> History.flush(token, actor) end)
  end

  # Everything the drafts table needs travels in `url_state`, because it is a LiveComponent: the
  # document whose drafts these are, the draft the editor is pointed at (which the rows mark
  # "Editing"), and a revision this LiveView bumps when the list must be read again. Gervaz reloads
  # exactly when this map stops matching the component's own state, so a map that is unchanged costs
  # nothing on an unrelated re-render, and a changed one costs precisely one read.
  defp assign_drafts_url_state(%{assigns: %{drafts_enabled?: false}} = socket),
    do: assign(socket, :drafts_url_state, nil)

  defp assign_drafts_url_state(socket) do
    %{record: record, editor: editor, drafts_revision: revision} = socket.assigns

    assign(socket, :drafts_url_state, %{
      filters: %{},
      sort: [updated_at: :desc],
      page: 1,
      page_size: nil,
      path_params: %{
        Drafts.source_key(section(socket)) => record.id,
        :editing_draft_id => editor.draft_id,
        :revision => revision
      }
    })
  end

  # Who may clear a document's whole history: a master, or an admin of the site that owns it. Read
  # off the actor rather than a permission of its own — this is the same boundary every other
  # destructive act in the editor uses.
  defp assign_history_clearable(socket) do
    assign(
      socket,
      :history_clearable?,
      clearable?(socket.assigns[:current_user], socket.assigns.editor.site_id)
    )
  end

  defp clearable?(%{site_id: nil}, _site_id), do: true
  defp clearable?(%{site_id: site_id}, site_id) when is_binary(site_id), do: true
  defp clearable?(_actor, _site_id), do: false

  # WHAT THE EDITOR IS ON, which is what the timeline shows: this record, on this branch. `draft_id`
  # is part of the scope, so switching between the live document and a draft changes which history
  # you are reading rather than filtering one list. `revision` is what makes a freshly written row
  # appear — the table re-reads when the state it was handed stops matching.
  defp assign_history_url_state(socket) do
    %{record: record, editor: editor} = socket.assigns

    assign(socket, :history_url_state, %{
      filters: %{},
      sort: [inserted_at: :desc],
      page: 1,
      page_size: nil,
      # `branch_id`, not `draft_id`: a path param whose name matches an attribute is filtered on
      # exactly by Gervaz, and this one is not an exact match — a draft's timeline includes the page's
      # own history, which the resource's `on_load` expresses.
      # `editor.section`, NOT the URL's: the address says "error-page" and the log files it under
      # `:error_page`, so converting the URL form raised on the one section whose two spellings
      # differ — and it raised inside mount, which took the whole editor down with it.
      path_params: %{
        source_type: Section.to_atom!(editor.section),
        source_id: record && record.id,
        branch_id: editor.draft_id,
        revision: socket.assigns[:history_revision] || 0
      }
    })
  end

  # The Studio's tokens table, scoped the same way the draft picker is: everything it needs travels
  # in `path_params`. `revision` is what makes an edited token reappear — the table reads again when
  # the state it was handed changes, and a token write changes nothing it is subscribed to.
  # Read with defaults rather than destructured: this runs alongside the drafts state, before
  # `assign_defaults/1` has put `token_format` and `tokens_revision` on the socket.
  defp assign_tokens_url_state(socket) do
    editor = socket.assigns.editor
    format = Map.get(socket.assigns, :token_format, :tw)
    revision = Map.get(socket.assigns, :tokens_revision, 0)

    # `path_params` and nothing else. The category chips are the TABLE's own filters, the sort is
    # its `default_sort`, and its depth is whatever the reader built with "load more" — claiming any
    # of the three here would reset it on every revision bump, which is what sent a 92-row list back
    # to 30 and un-selected the chip each time a token was edited.
    assign(socket, :tokens_url_state, %{
      path_params: %{
        site_id: editor.site_id,
        token_format: format,
        revision: revision,
        # The chips count every token, not the loaded page — so they cannot be counted from the
        # table's own rows. Counting them means parsing the site's stylesheets, which is 33 ms, so
        # it happens here once per revision rather than on each of the table's renders.
        token_categories: Map.get(socket.assigns, :token_categories, [])
      }
    })
  end

  defp assign_token_categories(socket) do
    categories =
      %{path_params: %{site_id: socket.assigns.editor.site_id}}
      |> DesignToken.rows()
      |> Panels.token_categories()

    assign(socket, :token_categories, categories)
  end

  # The snippet list is a Gervaz table, so only `path_params` travels — the scope chips are the
  # table's own filter and its depth is whatever the reader built. The keys are PREFIXED because
  # Gervaz turns a path param named after an attribute into an equality filter, and `site_id == X`
  # would drop exactly the global snippets this list exists to include.
  defp assign_snippets_url_state(socket) do
    %{editor: editor, record: record} = socket.assigns

    assign(socket, :snippets_url_state, %{
      path_params: %{
        editor_section: editor.section,
        editor_document_id: record && record.id,
        revision: Map.get(socket.assigns, :snippets_revision, 0)
      }
    })
  end

  # What the save box needs that the author does not type. Deliberately NOT the markup: `defaults`
  # rebuilds the form when it changes, and the markup changes on every canvas edit.
  defp assign_snippet_defaults(socket) do
    %{editor: editor, record: record} = socket.assigns
    selected = socket.assigns[:selected_node]

    assign(socket, :snippet_defaults, %{
      section: editor.section,
      # NOT `site_id` or `document_id`. Every default key is merged into the submit params,
      # replacing anything blank — so a deliberate "no site", which is what "All sites" means, would
      # be refilled with this site and the global snippet would quietly become a local one, and the
      # "no document" a snippet for every site keeps would be refilled with this site's page.
      editor_document_id: record && record.id,
      editor_site_id: editor.site_id,
      # The old implicit rule, kept as the PRESELECTED choice rather than the only one: a selection
      # belongs to its own page, a whole page has nowhere else to go but shared.
      visibility: (selected && record && "page") || "shared",
      selection_tag: (selected && Panels.selection_tag(selected)) || gettext("whole page"),
      save_label:
        (selected && gettext("Save selection as snippet")) ||
          gettext("Save this page as a snippet")
    })
  end

  # The markup itself, recomputed whenever the tree or the selection moves. It reaches the form
  # through a hidden input rather than through `defaults`, so it can change freely without
  # rebuilding the form under a half-typed name.
  defp assign_snippet_source(socket) do
    assign(
      socket,
      :snippet_source,
      snippet_source(socket.assigns.editor, socket.assigns[:selected_node])
    )
  end

  defp refresh_snippets(socket) do
    socket
    |> update(:snippets_revision, &(&1 + 1))
    |> assign_snippets_url_state()
  end

  defp refresh_tokens(socket) do
    socket
    |> update(:tokens_revision, &(&1 + 1))
    |> assign_token_categories()
    |> assign_tokens_url_state()
  end

  # Nothing pushes rows into the table; the table reads again when the state it was handed changes.
  defp refresh_drafts(socket) do
    socket
    |> update(:drafts_revision, &(&1 + 1))
    |> assign_drafts_url_state()
  end

  # Selecting on the canvas has to reveal the node in the layers tree, or the two panels disagree
  # about where you are. Ancestors are opened, never closed: a branch the author opened by hand
  # stays open.
  defp expand_to_selection(socket, %{selection: nil}), do: socket

  defp expand_to_selection(socket, editor) do
    ancestors = editor.tree |> Tree.ancestors(editor.selection) |> Enum.map(& &1.id)

    socket
    |> assign_new(:expanded, fn -> MapSet.new() end)
    |> update(:expanded, fn expanded -> Enum.reduce(ancestors, expanded, &MapSet.put(&2, &1)) end)
  end

  # The Assets sheet reads the site's real Media library, so it is loaded when the sheet opens
  # rather than on every mount — an editor that never opens Assets should not pay for it.
  # A sheet opens NOW and fills in when its query answers. Both of these are database reads, and
  # doing them inline meant the click that opened the panel held the LiveView until Postgres came
  # back — on a slow query the whole editor stopped, not just the panel.
  # The query's inputs are captured, never the socket — closing over the socket copies the whole
  # thing (tree, history, clipboard) into the new process on every open.
  # Counting the chips parses the site's stylesheets, so it happens when the Studio opens rather
  # than when the editor loads — an author who never opens the sheet never pays for it.
  defp blank_to_nil(""), do: nil
  defp blank_to_nil("__all__"), do: nil
  defp blank_to_nil(id), do: id

  # EVERY ROUTE INTO A SHEET GOES THROUGH HERE. A sheet's contents are read when it opens
  # (`load_sheet/2`), so a route that set `:sheet` by hand opened the panel and never asked for them:
  # the folder rail of the Assets sheet drew its placeholders for as long as the sheet stayed open
  # when it was reached from an Inspector's image button, a background, the SEO share image or a
  # file attached to the assistant — and the Studio did the same from a node's right-click menu.
  defp show_sheet(socket, sheet), do: socket |> assign(:sheet, sheet) |> load_sheet(sheet)

  # THE SHEET OPENS, AND THEN ITS CONTENTS ARRIVE. Everything the Studio shows was read on the way
  # in: `assign_token_categories/1` parses every stylesheet the site has, and the render itself
  # called `Marketplace.packages/1`, which parses the kit bundles — 10.8 MB of JSON for Chelekom
  # alone. Both ran before anything could paint, so pressing Studio did nothing at all for as long
  # as they took and then the finished sheet appeared.
  #
  # Off the click now, the way the Assets sheet's folders already are. The sheet opens at once and
  # draws a skeleton the shape of what is coming; `handle_async(:studio_data, …)` fills it in.
  defp load_sheet(socket, :studio) do
    socket
    |> assign(:studio_data, nil)
    |> assign_tokens_url_state()
    |> load_studio_async()
  end

  # The sheet's own sidebar is the folder list, so what it needs loading is CATEGORIES — the files
  # themselves are the Gervaz table's business and it fetches its own page.
  defp load_sheet(socket, :assets) do
    actor = socket.assigns[:current_user]
    site_id = socket.assigns.editor.site_id

    MishkaGervaz.Messages.assign_async(socket, :media_categories, fn ->
      {:ok, %{media_categories: site_categories(actor, site_id)}}
    end)
  end

  # THE WORDS THIS DOCUMENT ASKS FOR, as it stands in the editor rather than as it was last saved —
  # a `t("…")` typed a moment ago is already there to translate — in its markup and in the code of
  # its helpers, events and infos (`Translations.source_keys/1`). They are registered on the way in,
  # which is safe to repeat: `:register` never touches a row that exists, value included.
  #
  # Registered only where the reader may write. A site admin opening a GLOBAL component would
  # otherwise be minting global rows, which is a master's to do; they still see what is there.
  # AND THE WORDS OF EVERY COMPONENT IT RENDERS, nested ones included: a page's heading is often a
  # card's, and an author translating "the page" means everything on it. Each component's words are
  # registered under that COMPONENT's site — a global card's as global rows — and only where the
  # reader may write, the same line as the document's own.
  defp load_sheet(socket, :translations) do
    %{editor: editor, current_user: actor} = socket.assigns

    keys =
      socket.assigns
      |> Map.get(:fragments, %{})
      |> Map.put(:template, Serializer.serialize(editor.tree))
      |> Translations.source_keys()

    if translatable_here?(actor, editor.site_id),
      do: :ok = Translations.register(editor.site_id, keys)

    words = editor.tree |> component_refs() |> Translations.component_words()

    for {site_id, component_keys} <- words,
        Translations.may_write?(actor, site_id),
        do: :ok = Translations.register(site_id, component_keys)

    all_keys = Enum.uniq(keys ++ Enum.flat_map(words, &elem(&1, 1)))
    assign(socket, translation_keys: all_keys, translation_group: nil)
  end

  defp load_sheet(socket, _sheet), do: socket

  defp translatable_here?(%{site_id: nil}, _site_id), do: true
  defp translatable_here?(%{site_id: site_id}, site_id), do: true
  defp translatable_here?(_actor, _site_id), do: false

  # Only while the sheet is open. Every other route into these handlers — a deep link, a restored
  # session — leaves the assigns alone, and asking for a catalogue nobody is looking at is a
  # stylesheet parse and a bundle parse for nothing.
  defp reload_studio_if_filtered(socket) do
    case socket.assigns[:sheet] do
      :studio -> load_studio_async(socket)
      _elsewhere -> socket
    end
  end

  # Read together because they are drawn together, and a sheet that filled in one tab at a time
  # would flicker four times instead of once. The category is part of the question for two of them,
  # so changing it asks again.
  defp load_studio_async(socket) do
    site_id = socket.assigns.editor.site_id
    category = Map.get(socket.assigns, :studio_cat, "all")

    MishkaGervaz.Messages.start_async(socket, :studio_data, fn ->
      tokens = Panels.studio_token_list(site_id)

      %{
        tokens: tokens,
        token_categories:
          %{path_params: %{site_id: site_id}} |> DesignToken.rows() |> Panels.token_categories(),
        presets: Marketplace.presets(%{category: category}),
        packages: Marketplace.packages(%{category: category, site_id: site_id}),
        package_categories: Marketplace.package_categories(%{site_id: site_id})
      }
    end)
  end

  # SILENTLY, which is the whole point of not reusing `load_sheet/2`. `assign_async/3` puts the
  # rail back into its loading state, so every upload would blink the folders away and back for the
  # length of one query. This replaces the value in place and the reader sees only the count change.
  #
  # Nothing to do before the sheet has ever been opened: the assign does not exist yet, and it will
  # load when it does.
  # WHOSE UPLOAD THIS PANEL IS SHOWING. A document scoped to a site hears its own site's writes and
  # nobody else's — an unfiltered forward would drop another site's upload into this site's editor.
  #
  # A GLOBAL LAYOUT OR COMPONENT HAS NO SITE, which is the whole point of one: every site uses it and
  # only a master edits it. `Media` and `MediaCategory` both declare `allow_nil? false` on their site,
  # so comparing theirs to this editor's nil could never be true — the gallery and the folder rail
  # went deaf, and an upload landed with a flash saying so while nothing on screen moved until the
  # page was reloaded. The panel is already showing every site's library there, so every site's write
  # is one of its own.
  defp media_in_scope?(%{assigns: %{editor: %{site_id: nil}}}, _row), do: true

  defp media_in_scope?(%{assigns: %{editor: %{site_id: site_id}}}, row),
    do: row.site_id == site_id

  defp media_in_scope?(_socket, _row), do: false

  defp refresh_folders(socket) do
    case socket.assigns[:media_categories] do
      %Phoenix.LiveView.AsyncResult{ok?: true} = async ->
        categories = site_categories(socket.assigns[:current_user], socket.assigns.editor.site_id)

        assign(socket, :media_categories, Phoenix.LiveView.AsyncResult.ok(async, categories))

      _not_loaded ->
        socket
    end
  end

  # The folders this site has, with how much is in each. `media_count` is the resource's own
  # calculation, so the number beside a folder is the number the Media page shows for it.
  defp site_categories(actor, site_id) do
    {action, tenant} = media_scope(actor, site_id)

    MishkaCmsCore.Runtime.MediaCategory
    |> Ash.Query.for_read(action, %{}, actor: actor, tenant: tenant)
    |> narrow_media(action, site_id)
    |> Ash.Query.load(:media_count)
    |> Ash.Query.sort(name: :asc)
    # A LIMIT RATHER THAN `page: false`: pagination is `required?: true` on the master read, and
    # asking it to skip paging raises rather than returning everything. A folder rail that needs
    # more than 200 entries has a different problem.
    |> Ash.read(page: [limit: 200])
    |> case do
      {:ok, %{results: categories}} -> categories
      {:ok, categories} when is_list(categories) -> categories
      _error -> []
    end
  end

  # `:master_read` bypasses multitenancy, and the resources' `TenantContext` validation refuses a
  # non-nil tenant on a bypass action — the same trap that made every master save fail. A master
  # therefore reads with no tenant at all; a tenant admin reads scoped to its own site.
  # THE FEW FIELDS THIS STEP ASKS FOR. Everything else the resource's form declares is hidden rather
  # than removed, so what is left is the resource's OWN field — its label, its validation, its
  # relation picker — and not a second copy of it that can drift.
  #
  # `:site_id` is on the list for every section: Gervaz already decides that a tenant never sees it,
  # because the tenant create action does not accept one.
  # BOTH WORDS FOR WHAT A THING IS CALLED, because the four sections do not agree on which one
  # they have. A page asks for `:title` and derives its `:name`; a layout, a component, a snippet and
  # an error page still ask for `:name` and have no title. This is a KEEP-list — a field missing from
  # it is hidden — so a section whose own word is absent here renders a form with no way to name
  # anything, and for a page that means a required field it cannot fill.
  #
  # A page also picks here what each of its addresses shows (`:record`), because that is what kind
  # of page it is; the other sections have no such field, so it hides nothing of theirs.
  @essentials [:name, :title, :path, :record, :site_id]

  defp hidden_fields(resource) do
    resource
    |> MishkaGervaz.Resource.Info.Form.fields()
    |> Enum.map(& &1.name)
    |> Enum.reject(&(&1 in @essentials))
  end

  defp media_scope(%{site_id: nil}, _site_id), do: {:master_read, nil}
  defp media_scope(_actor, site_id), do: {:read, site_id}

  # Media has no site-argument read, so a master's bypass read would offer every site's library at
  # once. Since the bypass leaves `site_id` filterable, the site being edited is applied by hand.
  defp narrow_media(query, :master_read, site_id) when is_binary(site_id) do
    Ash.Query.filter(query, site_id == ^site_id)
  end

  # A global document is rendered by every site, so its folders are only those of sites that are up.
  defp narrow_media(query, :master_read, nil) do
    open = MishkaCmsCore.Runtime.SiteAvailability.open_site_ids()
    Ash.Query.filter(query, site_id in ^open)
  end

  defp narrow_media(query, _action, _site_id), do: query

  # LiveView's own async assign, so the panel gets `AsyncResult.loading/0` and `<.async_result>`
  # rather than a hand-rolled boolean. The read also writes the palette into the SESSION, because the
  # canvas binds each component to a site from that list — the assign is for this socket's panel, the
  # session is for the frame.
  defp load_palette_async(socket, editor, actor, params) do
    MishkaGervaz.Messages.assign_async(socket, :palette, fn ->
      with {:ok, components} <- palette_components(actor, params, editor),
           {:ok, _editor} <- EditorSession.put_components(editor.token, components) do
        {:ok, %{palette: components}}
      end
    end)
  end

  # THE COMPONENTS THIS DOCUMENT USES, COMPILED BEFORE THE CANVAS ASKS FOR THEM.
  #
  # A runtime component is built the first time something renders it, which is right — a kit of 136
  # should not compile 136 modules to open a page that places five. But the canvas renders NODE BY
  # NODE, so it meets those five one at a time and blocks on each: measured cold, this page's five
  # are 603 ms end to end, and `chelekom-button-link` alone is 295 ms of it, because the kit ships
  # every variant/colour/size combination as its own function clause — 177 of them, 64 KB of source.
  #
  # Compiling them here changes neither WHICH components are built nor WHEN they are first needed. It
  # changes the shape of the wait: `ModuleCompilerHandler` keys one worker per module and makes a
  # second caller wait on the first, so asking for all five at once compiles them CONCURRENTLY and
  # the canvas — which loads in its own iframe, after this mount — finds them ready or already in
  # flight. Serial 603 ms becomes roughly the slowest single module.
  #
  # Off the mount, like the palette, because a failure to warm must cost nothing: the canvas still
  # compiles on demand exactly as it did, and this is only ever an optimisation that ran early.
  defp warm_components(socket, editor) do
    names = component_names(editor.tree)

    MishkaGervaz.Messages.start_async(socket, :warm_components, fn ->
      names
      |> Task.async_stream(
        &MishkaCmsCore.Runtime.LiveViewHelpers.ensure_component_loaded(&1, editor.site_name),
        max_concurrency: 8,
        timeout: :timer.seconds(30),
        on_timeout: :kill_task
      )
      |> Enum.count(&match?({:ok, true}, &1))
    end)
  end

  # ONLY THE RUNTIME ONES. `Node.component_name/1` answers for every `:component` node, and `<.link>`
  # is one — it is `Phoenix.Component.link/1`, imported into every page, not a row anything can
  # compile. Asking for it reaches the database, finds nothing, and is deliberately NOT cached as a
  # miss, so each warm paid for the same fruitless lookup again.
  #
  # `{component_name, site}` — the site as written, a global component's being none or "Global".
  defp component_refs(tree) do
    for node <- Tree.walk(tree),
        match?(%Node{kind: :component, tag: ".component"}, node),
        name = Node.component_name(node),
        is_binary(name),
        uniq: true,
        do: {name, Node.attr_text(node, "site")}
  end

  defp component_names(tree),
    do: tree |> component_refs() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

  defp palette_components(actor, params, editor) do
    {args, tenant} = palette_scope(actor, params)

    MishkaCmsCore.Runtime.Component
    |> Ash.Query.for_read(:for_tenant_with_globals, args, actor: actor, tenant: tenant)
    # `helpers` is selected because the property panel's option lists live in its `discriminators`,
    # not in the attributes — see `MishkaCmsCore.Runtime.PageBuilder.Inspector.features/1`. The old
    # palette payload omitted it, which is why a variant dropdown was never possible.
    |> Ash.Query.select([
      :id,
      :name,
      # The component's OWN markup, so the layers tree can show what is inside it without sending the
      # author to another page for a look.
      :template,
      :type,
      :description,
      :priority,
      :attrs,
      :slots,
      :helpers,
      # WHICH SHAPE THIS COMPONENT COMPILES INTO. An unselected attribute is not an error and is not
      # `%Ash.NotLoaded{}` — the struct field simply reads `nil`, which is falsy — so leaving it out
      # would make the palette quietly call every component stateless, seed no id, and every drop of
      # a stateful one would land without the id a LiveComponent cannot exist without.
      :stateful,
      :site_id
    ])
    # NOT `:extra`. The palette needs two facts out of it — the glyph and whether the Examples modal
    # has anything — and selecting the column to learn them shipped 2.9 MB of `demo_examples` per
    # load. These calculations answer both inside the query. Measured: 1573 ms → 725 ms.
    |> Ash.Query.load([
      :icon_name,
      :has_examples,
      :furnishing,
      :doc_url,
      :ui_kit_label,
      :form_meta
    ])
    |> Ash.read(page: [limit: 1000])
    |> case do
      {:ok, %{results: components}} ->
        {:ok, components |> collect_palette() |> without_self(editor)}

      {:ok, components} when is_list(components) ->
        {:ok, components |> collect_palette() |> without_self(editor)}

      # A FAILED READ IS NOT AN EMPTY SITE. This used to answer `collect_palette([])`, which drew a
      # palette with nothing in it — indistinguishable from a site that has no components installed,
      # with no flash, no log line and nothing for the reader to act on. A dropped connection under
      # load therefore read as "my components vanished".
      #
      # `assign_async/3` already carries a failure state and the panel already renders a `:failed`
      # slot for it; the error simply never got that far.
      error ->
        Logger.error("[Builder] palette read failed: #{inspect(error)}")
        {:error, error}
    end
  end

  # The database palette is the SEED of the `builder:components` registry, never the whole of it:
  # an extension whose component is real live code (rather than a stored template) contributes a
  # descriptor here. Seeded and never `[]`, `uniq_by` keeping the first declaration — the
  # `sidebar:menus` convention, so a plugin can add but never redefine a core component.
  # A COMPONENT CANNOT BE MADE OUT OF ITSELF. The palette is every component this site can place, and
  # while one is open in the editor it is in that list — so it could be dropped into its own
  # template. What that produces is a runtime module that calls itself for as long as the machine
  # allows: the canvas's heap ceiling ends the iframe, and a published one ends the request.
  #
  # One row, in one section. A page may place every component, a layout may, and a component may
  # place every component but this one. Applied after `Events.collect/2` so a plugin cannot put it
  # back by contributing an entry of its own.
  defp without_self(components, %{section: "component", resource_id: id}) when is_binary(id),
    do: Enum.reject(components, &(&1.id == id))

  defp without_self(components, _editor), do: components

  defp collect_palette(components) do
    extensions = extension_kits()

    components
    |> Enum.map(&palette_entry(&1, extensions))
    |> then(&Events.collect(:components, &1))
  end

  # EACH INSTALLED EXTENSION'S OWN KIT, by the name its components carry — `mishka_blog` — to the
  # label the extension registers under, `Blog`. An extension's kit is named after its OTP app, the
  # key `MishkaCmsCore.Install.Extensions` lists it by; a UI kit is no extension and is not in it.
  defp extension_kits,
    do: Map.new(MishkaCmsCore.Install.Extensions.installable(), &{&1.key, &1.label})

  # WHERE THE PALETTE FILES A COMPONENT: under its extension's name when an installed extension's own
  # kit brought it, so a blog's or a documentation's blocks are found together rather than spread
  # over the categories they share with the UI kit; under its category otherwise.
  defp palette_group(component, extensions) do
    case Map.fetch(extensions, kit_name(component.ui_kit_label)) do
      {:ok, label} -> {label, true}
      :error -> {component.type || "general", false}
    end
  end

  # `ui_kit_label` is the kit's name, then its version: `mishka_blog 3.7.0`.
  defp kit_name(label) when is_binary(label), do: label |> String.split(" ", parts: 2) |> hd()
  defp kit_name(_no_kit), do: nil

  # `:for_tenant_with_globals` is the one read that serves both callers: it bypasses multitenancy and
  # takes the site as an ARGUMENT, which is how a master narrows to the site being edited while still
  # seeing the global components. Reaching for `:master_read` here was the trap the comment above
  # `media_scope/2` describes — a master opening `?site_id=…` handed a tenant to a bypass action, the
  # read errored, and the palette came back empty.
  defp palette_scope(%{site_id: nil}, params), do: {site_arg(params["site_id"]), nil}
  defp palette_scope(%{site_id: site_id}, _params) when is_binary(site_id), do: {%{}, site_id}

  defp site_arg(site_id) when is_binary(site_id), do: %{site_id: site_id}
  defp site_arg(_site_id), do: %{}

  # `form:` carries which attribute a binding goes on, when the kit says so.
  # `MishkaCmsCore.Builder.FormRole` reads it and `MishkaCmsCore.Runtime.PageBuilder.Fields` infers
  # when it is absent, which is every kit exported before the key existed.
  defp palette_entry(component, extensions) do
    {group, extension?} = palette_group(component, extensions)

    %{
      id: component.id,
      # `key` is what the registry de-duplicates on, so a plugin contributing an entry that names an
      # existing component leaves the core's one in place.
      key: component.name,
      name: component.name,
      template: component.template,
      label: humanize(component.name),
      type: component.type || "general",
      group: group,
      extension?: extension?,
      description: component.description,
      slots: component.slots || [],
      attrs: component.attrs || [],
      # NOT `helpers`. THE SOURCE IS READ HERE AND NEVER AGAIN. A kit's helper bodies are the biggest
      # thing a component owns — measured at 87% of a 10.65 MB palette, ~11,300 decoded structs — and
      # the palette rides inside the editing session, which ETS copies whole on every read and every
      # write: about thirteen times for one placed component. Only two questions are ever asked of
      # that source, and both are answered here, once: which assigns the component reads, and which
      # option axes its `discriminators` declare.
      reads: PaletteEntry.reads(component),
      doc_url: component.doc_url,
      features: Inspector.features(component),
      # NOT curated here. Curating one component parses every example it ships; doing it for all 183
      # cost 7.8 seconds at open, to answer a question the palette only asks as "is there anything to
      # browse?". The modal curates the one component it is opened for.
      examples: [],
      has_examples?: component.has_examples == true,
      # THE BADGE OPENS A MODAL WITH TWO TABS, and only one of them is about examples. Gating it on
      # examples alone put a fully working Wizard behind a door with no handle: a kit shipping good
      # `attrs` and no `extra` got a perfect palette tile, no badge, and therefore no option
      # pickers, no live preview and no Insert. Cheap to answer here — `Wizard.axes/1` reads the
      # attrs and helpers this entry already carries, with no extra query and no example parsing.
      offers_options?: offers_options?(component),
      # A component may name its own palette glyph in `extra.icon`; the panel suggests one from the
      # name and type when it does not.
      icon: component.icon_name,
      # What this component says it should look like on a fresh drop, if it says anything —
      # `MishkaCmsCore.Builder.Furnishing`. Absent for the great majority, and then
      # `MishkaCmsCore.Runtime.PageBuilder.Starter` infers one.
      furnishing: component.furnishing,
      # Whether this component renders its own content closed — see `PaletteEntry.concealed?/1`.
      # Answered once here, beside `reads`, because the template it is read from is the thing the
      # palette deliberately does not carry.
      concealed?: PaletteEntry.concealed?(component),
      # Whether this component reaches for the elements an author puts inside it — see
      # `PaletteEntry.shapes_children?/1`. Read from the same template and helper bodies, for the
      # same reason, and the canvas uses it to decide whether it may put a box of its own between
      # the two.
      shapes_children?: PaletteEntry.shapes_children?(component),
      # And HOW it says to open it, if it says — `PaletteEntry.opens/1`. Read here for the same
      # reason and from the same template, so a click aimed at this component compiles to the
      # component's own command instead of the editor's guess at one.
      opens: PaletteEntry.opens(component),
      form: component.form_meta,
      # WHOSE MARKUP THIS IS, in about twenty bytes. The Custom CSS panel names the kit and version
      # when a rule reaches inside a component. `extra`, where the two live, is exactly the column
      # this query must not pull — so `ui_kit_label` answers it in SQL, the way `doc_url` does.
      kit: component.ui_kit_label,
      global?: is_nil(component.site_id),
      # Whether placing this one has to carry an `id`. `== true` rather than the value itself,
      # because a row read before the column existed answers `nil`.
      stateful?: component.stateful == true
    }
  end

  # The example's `source` is the whole point and the old payload stripped it, which is why
  # "insert example" could only ever place a bare component and dropped every attribute the example
  # demonstrated. It is kept here and inserted as a parsed subtree.
  # Curated rather than passed through: a bundle ships the kit's exhaustive catalogue AND every real
  # usage from its documentation site, and the modal used to show only the first — twelve previews
  # whose body reads "Base". `Examples` merges, dedups and describes them.

  defp opening_tab(socket, name) do
    entry = Enum.find(socket.assigns.editor.components, &(&1.name == name))

    case entry &&
           {PaletteEntry.optional(entry, :has_examples?),
            PaletteEntry.optional(entry, :offers_options?)} do
      {false, true} -> :wizard
      _examples_or_nothing -> :examples
    end
  end

  defp offers_options?(component) do
    component
    |> Map.take([:name, :template, :attrs, :slots, :helpers, :site_id])
    |> Wizard.axes()
    |> Enum.any?()
  end

  defp humanize(name) do
    name
    |> String.replace(["-", "_"], " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  # Clicking an element in the canvas is how you say "this is the one I want to work on", so the
  # left panel comes back and lands on its form — the same thing a layers row does through
  # `inspect`. Only a CANVAS selection does this: selecting from the tree is navigation, and swapping
  # the panel out from under someone who is browsing the tree loses their place.
  # THE BUILDER READS ITS OWN PARAMS IN MOUNT and has never needed `handle_params`. It needs one now
  # because the Assets sheet mounts a Gervaz table, and `Runtime.Media`'s table declares
  # `url_sync do mode :bidirectional end` — it pushes a patch whenever its filters, sort or page
  # change. Without a `handle_params` that patch raises; with one that ignores it, the patch would
  # still rewrite the builder's URL to `/`, because a table with no `url_state` has no base path.
  #
  # Decoding it properly is what makes both true: the patch stays on the builder's own URL, and the
  # gallery's filters survive a reload the way they do on the Media page.
  @impl true
  def handle_params(params, uri, socket) do
    {:noreply,
     assign(socket, :url_state, UrlSync.decode(params, uri, MishkaCmsCore.Runtime.Media))}
  end

  # THE FORM ANNOUNCES; THIS PAGE ACTS. The essentials step is the resource's own Gervaz form, so it
  # creates through the resource's own action and says so exactly as every list page hears it — the
  # editor's only job is to reopen on what was just made, and to leave if the reader backs out.
  @impl true
  def handle_info(
        {:form_saved, :create, record},
        %{assigns: %{new_document?: true, record: nil, section: section}} = socket
      ) do
    {:noreply, push_navigate(socket, to: Section.builder_path(section, record.id))}
  end

  def handle_info(
        {:form_cancelled, _resource},
        %{assigns: %{new_document?: true, record: nil, section: section}} = socket
      ) do
    {:noreply, push_navigate(socket, to: Section.list_path(section))}
  end

  # THE SETTINGS MODAL SAVED, and the editor takes the new name and path.
  #
  # RE-READ RATHER THAN TAKEN FROM THE FORM. What a Gervaz save answers with is the row the action
  # wrote, with nothing loaded onto it — and the header reads `record.site.name` for its scope badge.
  # Assigning the form's record directly turned "localhost" into "This site" on every save, which is
  # the badge falling through to its last clause rather than any change of scope. `load_record/3` is
  # the read the mount makes, so what lands here is the shape the rest of the editor was written
  # against instead of a second, thinner one.
  #
  # `@record` is the only thing that moves. The working tree is not on this record and the modal
  # never had it: a rename while a design is half-finished leaves the design exactly where it was.
  # A file edited in the Media sheet while the SEO tab is choosing a picture is not the document.
  #
  # The SEO tab saves the same way, and the document it wrote comes back on its record.
  def handle_info(
        {:form_saved, :update, %SeoSettings{document: record}},
        %{assigns: %{settings_open?: true}} = socket
      ),
      do: {:noreply, settings_saved(socket, record)}

  def handle_info(
        {:form_saved, :update, %resource{} = record},
        %{assigns: %{settings_open?: true}} = socket
      )
      when resource not in [Media, MediaCategory],
      do: {:noreply, settings_saved(socket, record)}

  def handle_info({:form_cancelled, _resource}, %{assigns: %{settings_open?: true}} = socket),
    do: {:noreply, assign(socket, settings_open?: false, seo_form?: false)}

  def handle_info({:builder_session, token, {:selection, id, :canvas}}, socket)
      when is_binary(id) do
    {:noreply,
     socket
     |> sync_session(token)
     |> assign(left_hidden: false, left_tab: :inspector)}
  end

  # CLICKED ON THE THING THAT SAYS WHAT IS MISSING. A component that cannot render without a value
  # draws "needs src — click to choose src" in its place, and the attribute travels with the click,
  # so the author lands ON that row rather than on an eighteen-row form with nothing marked.
  #
  # And where there is a chooser, it opens. The icon picker and the media library both already
  # existed and both already worked — they were reachable only by knowing which row to scroll to and
  # which small button to press, which is the whole of reports 12 and 13. `Inspector.widget/3` says
  # which chooser a property has, so nothing here guesses from the attribute's name.
  def handle_info({:builder_session, token, {:selection, id, {:canvas, prop}}}, socket)
      when is_binary(id) and is_binary(prop) do
    socket = socket |> sync_session(token) |> assign(left_hidden: false, left_tab: :inspector)

    {:noreply, offer_chooser(socket, id, prop)}
  end

  # A NOTE IS NOT SESSION STATE, so this is not a `sync_session`: the rows changed, not the session.
  # Kept for a co-editor who joined through `?session=`; the row broadcast below is what reaches
  # everybody else.
  def handle_info({:builder_session, _token, {:review, :changed}}, socket),
    do: {:noreply, reread_review(socket)}

  # THE THREAD FOLLOWS THE ROWS. `PageComment`'s own `pub_sub` reaches every editor with this
  # document open — including the two people who each opened it from the list and therefore share
  # no session — which is what makes a note appear at the top of the thread as it is written rather
  # than when somebody next reloads.
  #
  # `notification.data` is the note itself, so the document can be tested without a read: the topic
  # only knows the site. `from` is the pid that ran the action, stamped by `Ash.Notifier.notify/1`,
  # and skipping our own is what stops the author paying for the write twice — `refresh_review/1`
  # has already re-read, synchronously, so the badge and the thread are right in the same render as
  # the flash.
  def handle_info(
        %Phoenix.Socket.Broadcast{
          payload: %Ash.Notifier.Notification{resource: PageComment, data: note, from: from}
        },
        socket
      )
      when from != self() do
    scope = Panels.review_scope(socket.assigns)

    case note.section == scope.section and note.document_id == scope.document_id do
      true -> {:noreply, reread_review(socket)}
      false -> {:noreply, socket}
    end
  end

  # THE ASSETS GALLERY IS A GERVAZ TABLE, and a LiveComponent has no `handle_info` — its
  # subscription registered THIS process, so the broadcast lands here and has to be handed back
  # down. `send_update/2` on a sheet that is shut is a no-op, so there is nothing to guard.
  #
  # The site test is not belt-and-braces. A master's table shows every site by design, and the
  # notification path inserts the row without re-applying this mount's `path_params` — so an
  # unfiltered forward would drop another site's upload into this site's editor.
  #
  # The rail is re-read on a MEDIA event too: every upload and every archive moves a folder's count.
  def handle_info(
        %Phoenix.Socket.Broadcast{
          payload: %Ash.Notifier.Notification{resource: Media, data: media} = notification
        },
        socket
      ) do
    case media_in_scope?(socket, media) do
      true ->
        send_update(MishkaGervaz.Table.Web.Live,
          id: "pb-assets-gallery",
          pubsub_notification: notification
        )

        {:noreply, refresh_folders(socket)}

      false ->
        {:noreply, socket}
    end
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          payload: %Ash.Notifier.Notification{resource: MediaCategory, data: category}
        },
        socket
      ) do
    case media_in_scope?(socket, category) do
      true -> {:noreply, refresh_folders(socket)}
      false -> {:noreply, socket}
    end
  end

  # THE TRANSLATIONS SHEET'S TABLE HEARS ITS WORDS CHANGE, as the admin list does — a save, a
  # delete, a language the sheet registered on the way in — and never reloads to find out. Only a
  # word this document asks for is handed down: the sheet's table reads those keys and no others,
  # and whose rows of them it shows is still the resource's read policy, applied as it redraws.
  # Our own writes come back too, and they are exactly the ones the table has to show.
  def handle_info(
        %Phoenix.Socket.Broadcast{
          payload: %Ash.Notifier.Notification{resource: Translation, data: row} = notification
        },
        socket
      ) do
    if row.key in (socket.assigns[:translation_keys] || []),
      do:
        send_update(MishkaGervaz.Table.Web.Live,
          id: "pb-translations",
          pubsub_notification: notification
        )

    {:noreply, socket}
  end

  # Somebody else's document, or our own write coming back to us.
  def handle_info(%Phoenix.Socket.Broadcast{payload: %Ash.Notifier.Notification{}}, socket),
    do: {:noreply, socket}

  def handle_info({:builder_session, token, _message}, socket),
    do: {:noreply, sync_session(socket, token)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply,
     assign(
       socket,
       :editors,
       Presence.others(socket.assigns.token, socket.assigns[:current_user])
     )}
  end

  # A row action from the drafts table. Gervaz dispatches it to the table component, whose `self()`
  # is this LiveView — so the action arrives as a message and is answered by the same handlers the
  # rest of the editor uses. One implementation, whichever control was clicked.
  def handle_info({:draft_row_action, event, id}, socket) when is_binary(id) do
    case event do
      "fork_draft" -> handle_event("fork_draft", %{"id" => id}, socket)
      "delete_draft" -> {:noreply, socket |> refresh_drafts() |> forget_deleted(id)}
      _unknown -> {:noreply, socket}
    end
  end

  # The Gervaz form announces a successful create by messaging its parent — there is no callback and
  # no PubSub. The list has to be told to read again, because nothing else knows a row appeared.
  # THE GALLERY'S "USE" ARRIVES AS A ROW ACTION, not a click on a tile of ours — the tiles are
  # Gervaz's now. A row action reaches the page as `{:row_action, event, %{"id" => id}}`, carrying
  # the record id rather than a URL, so the path is read from the record.
  def handle_info({:row_action, "use_media", %{"id" => id}}, socket) do
    {:noreply, place_media(socket, id)}
  end

  # THE EYE OPENS THE FILE, here as on the Media page. It used to be answered and dropped, on the
  # grounds that the editor had no overlay to put a file in — which made it a button that did
  # nothing, and a reader cannot tell that apart from a broken one.
  def handle_info({:row_action, "preview", %{"id" => id}}, socket) do
    case read_media(socket, id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("That file is no longer in the library."))}

      media ->
        {:noreply,
         assign(socket, :preview_media, %{
           name: media.name,
           url: media_href(media.relative_path),
           image?: media.type == :images
         })}
    end
  end

  # The composer is a Gervaz form, so a saved note arrives the way every Gervaz save does. Refreshing
  # the badge here is what makes it derived rather than remembered.
  def handle_info({:form_saved, _mode, %MishkaCmsCore.Runtime.PageComment{} = note}, socket) do
    Events.after_comment(%{
      id: note.id,
      body: note.body,
      type: note.type,
      node_id: note.node_id,
      reply?: !is_nil(note.parent_comment_id),
      section: socket.assigns.editor.section,
      source_id: socket.assigns.editor.resource_id,
      site_id: socket.assigns.editor.site_id,
      actor_id: actor_id(socket)
    })

    {:noreply,
     socket
     |> assign(:reply_to, nil)
     |> assign(:mentions, [])
     |> refresh_review()
     |> put_flash(
       :info,
       (note.parent_comment_id && gettext("Reply posted.")) || gettext("Note posted.")
     )}
  end

  # `PageComment.refuse/1` rejects a blank note before the submit, because this composer has no
  # error slot and Gervaz reports a refusal by assigning errors for the TEMPLATE to draw — which a
  # template with nowhere to draw them swallows silently.
  def handle_info({:review_error, message}, socket) do
    {:noreply, put_flash(socket, :error, message)}
  end

  # UPLOADING DURING A PICK IS PICKING. Something asked for a file — that is why the reader opened
  # the library and why they uploaded at all — and then the sheet stayed open, said "Uploaded", and
  # left them to find the card they had just made and press Use on it. The two halves were written
  # separately and the step between them exists for no other reason.
  #
  # A file the field cannot show is NOT placed, and says so rather than failing quietly: the gallery
  # is filtered to what the field accepts, so a PDF uploaded during a picture pick would vanish from
  # the grid the moment it saved — uploaded successfully, invisible, and apparently lost.
  def handle_info(
        {:form_saved, _mode, %MishkaCmsCore.Runtime.Media{} = media},
        %{assigns: %{media_target: %{} = target}} = socket
      ) do
    case usable?(target, media) do
      true ->
        {:noreply,
         socket
         |> place_media(media.id)
         |> put_flash(:info, gettext("Uploaded “%{name}” and used it.", name: media.name))}

      false ->
        {:noreply, put_flash(socket, :error, not_a_picture(media))}
    end
  end

  def handle_info({:form_saved, _mode, %MishkaCmsCore.Runtime.Media{} = media}, socket) do
    {:noreply, put_flash(socket, :info, gettext("Uploaded “%{name}”.", name: media.name))}
  end

  # The rail is not touched here. `MediaCategory` publishes the create, and the clause that hears it
  # re-reads the folders — the same route a folder made in another tab arrives by.
  def handle_info({:form_saved, _mode, %MediaCategory{} = category}, socket) do
    {:noreply,
     socket
     |> assign(:folder_form?, false)
     |> put_flash(:info, gettext("Folder “%{name}” added.", name: category.name))}
  end

  # THE INTERFACE FORM HAS SAVED. It writes the component's own row, which is the row this editor is
  # showing — `@record` feeds the Interface tab's undeclared advice and the tab's own count, so a
  # stale one would go on offering to declare an attribute that now exists.
  def handle_info({:form_saved, _mode, %MishkaCmsCore.Runtime.Component{} = record}, socket),
    do: {:noreply, assign(socket, :record, record)}

  def handle_info({:form_cancelled, MediaCategory}, socket),
    do: {:noreply, assign(socket, :folder_form?, false)}

  # THE TRANSLATIONS SHEET IS THE ADMIN MODAL'S BODY, moved the same way — see
  # `MishkaCmsCoreWeb.Live.Admin.Components.TranslationGroup`. "Translate" on a row opens the word in
  # every language; a save reads it again and moves on to the next language still missing. The
  # table hears the save over PubSub, like every other change to its words.
  def handle_info({:row_action, "edit_translation", %{"id" => id}}, socket),
    do: {:noreply, TranslationGroup.open(socket, id)}

  def handle_info({:row_action, "delete_translation_key", %{"id" => id}}, socket) do
    case Translations.delete_key(socket.assigns.current_user, id) do
      {:ok, removed} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           gettext("Deleted in every language (%{count}).", count: removed)
         )}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("That word is no longer there."))}
    end
  end

  def handle_info({:form_saved, _mode, %Translation{}}, socket),
    do:
      {:noreply,
       socket |> TranslationGroup.saved() |> put_flash(:info, gettext("Translation saved."))}

  def handle_info({:form_cancelled, Translation}, socket),
    do: {:noreply, TranslationGroup.close(socket)}

  def handle_info({:form_saved, _mode, %MishkaCmsCore.Runtime.Snippet{} = snippet}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("Saved “%{name}”.", name: snippet.name))
     |> refresh_snippets()}
  end

  # The save box has no error slot, so a refused save says so the way it always has.
  def handle_info({:snippet_error, message}, socket),
    do: {:noreply, put_flash(socket, :error, message)}

  # A GERVAZ BULK ACTION REPORTS BY MESSAGE, not by return value — `BulkActionHandler` sends
  # `{:put_flash, level, message}` to the LiveView, because the work happens in a LiveComponent and
  # a component cannot put a flash. Without this clause the catch-all below eats it and archiving
  # eleven files looks exactly like archiving none.
  def handle_info({:put_flash, level, message}, socket),
    do: {:noreply, put_flash(socket, level, message)}

  def handle_info({:asset_build, _bundle, _type}, socket) do
    %{editor: editor, current_user: actor} = socket.assigns
    {:noreply, assign(socket, :asset_failures, asset_failures(editor, actor))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp sync_session(socket, token) do
    case EditorSession.fetch(token) do
      {:ok, editor} -> assign_editor(socket, editor)
      :error -> socket
    end
  end

  # CHOOSING AN ELEMENT IS CHOOSING WHAT THE NOTE IS ABOUT. "About the whole page" is a deliberate
  # override of the selection, so it lasts exactly until the selection changes — otherwise clearing
  # it once would leave every later note filed against the page, and the composer would look broken
  # in the opposite direction.
  # WHAT BELONGED TO THE ELEMENT JUST LEFT. A new selection is a new question, so the half-made
  # answers to the old one go with it: the note's page scope, and the target and verb sitting in the
  # On-click form before anyone pressed Apply. Carried over, they described the previous element —
  # and the verb decides which box the form draws under it.
  defp release_page_scope(%{assigns: %{selection: selection}} = socket, selection), do: socket

  defp release_page_scope(socket, _selection) do
    socket
    |> assign(:note_on_page?, false)
    |> assign(:aim_target, nil)
    |> assign(:act_action, nil)
  end

  @impl true
  # A stylesheet that cannot be read leaves the row as it started — five neutrals and no tokens —
  # rather than taking the editor with it. There is nothing here the author cannot do by typing the
  # colour, so a failure is worth a missing convenience and not a lost session.
  # Nothing to assign — the point of warming is that the canvas found the modules loaded. Both
  # clauses exist so a result or a crash cannot reach the LiveView's catch-all as an unhandled
  # message; a failure means the canvas compiles on demand exactly as it always did.
  def handle_async(:warm_components, {:ok, _count}, socket), do: {:noreply, socket}
  def handle_async(:warm_components, {:exit, _reason}, socket), do: {:noreply, socket}

  # `assign_tokens_url_state/1` again because the chips' counts are read off the categories, and on
  # the first open there were none to read when it last ran.
  def handle_async(:studio_data, {:ok, data}, socket) do
    {:noreply,
     socket
     |> assign(:studio_data, data)
     |> assign(:token_categories, data.token_categories)
     |> assign(:studio_badge, Enum.count(data.tokens, & &1.custom?))
     |> assign_tokens_url_state()}
  end

  # An empty Studio is survivable and a crashed editor is not — the same trade `Marketplace.Kits`
  # makes when a bundle will not resolve.
  def handle_async(:studio_data, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :studio_data, Panels.empty_studio_data())}

  def handle_async(:style_tokens, {:ok, tokens}, socket),
    do: {:noreply, assign(socket, :style_tokens, tokens)}

  def handle_async(:style_tokens, {:exit, _reason}, socket), do: {:noreply, socket}

  # THE PUBLISH BAR WAITS ON THIS, so the flag it hides behind comes down with every answer, good or
  # bad: a draft that was written clears `dirty?` and the bar stays down of its own accord, while one
  # that failed — or one the author has already edited past — leaves it true and the bar comes back
  # saying so.
  def handle_async(:autosave, {:ok, result}, socket) do
    socket = socket |> assign(:autosaving?, false) |> autosaved(result)

    case socket.assigns.draft_again? do
      true ->
        {:noreply, socket |> assign(:draft_again?, false) |> write_again() |> holding_draft()}

      false ->
        {:noreply, holding_draft(socket)}
    end
  end

  def handle_async(:autosave, {:exit, _reason}, socket),
    do: {:noreply, socket |> assign(:autosaving?, false) |> holding_draft() |> autosave_failed()}

  # A FLUSH THAT FAILS IS NOT SILENT. `History.flush/2` puts the entries back, so the next change
  # retries them; what must not happen is the editor carrying on as though the history were being
  # kept. `builder_live` already says a page that quietly stopped keeping work is the worst thing
  # this editor could do without mentioning it — the same applies to its record of what happened.
  def handle_async(:history_flush, {:ok, result}, socket) do
    socket =
      socket
      |> assign(:history_flushing?, false)
      |> assign(:history_recording?, match?({:ok, _}, result))
      |> bump_history_revision(result)

    case socket.assigns[:history_flush_again?] do
      true -> {:noreply, flush_history(socket)}
      _settled -> {:noreply, socket}
    end
  end

  def handle_async(:history_flush, {:exit, _reason}, socket),
    do:
      {:noreply,
       socket |> assign(:history_flushing?, false) |> assign(:history_recording?, false)}

  # NOTHING IS TOLD, because nothing was lost: the page is published, the rows are written, and all
  # this job drops is weight. It is also self-healing — `History.collect/5` takes the whole branch,
  # so the next publish collects whatever this one left behind.
  #
  # THE SHEET IS RE-READ ALL THE SAME. The rows it is drawing have just lost their payloads, and a
  # Restore button over a payload that is gone is an offer the editor cannot keep — the press fails
  # safe, but the button should not have been there to press.
  def handle_async(:history_collect, {:ok, {:ok, _swept}}, socket),
    do: {:noreply, bump_history_revision(socket)}

  # A CLEANUP THE POLICIES REFUSED IS NOT A PUBLISH THAT FAILED, so nothing changes on screen — but
  # it is the difference between the payloads being gone and still being there, and the only way
  # anyone learns that this stopped working is that it says so. It was silent for exactly that long.
  def handle_async(:history_collect, {:ok, {:error, reason}}, socket) do
    Logger.warning("[PageBuilder] the publish cleanup was refused: #{inspect(reason)}")
    {:noreply, socket}
  end

  def handle_async(:history_collect, {:exit, reason}, socket) do
    Logger.warning("[PageBuilder] the publish cleanup did not finish: #{inspect(reason)}")
    {:noreply, socket}
  end

  def handle_async(:history_revert, {:ok, {:ok, _editor}}, socket),
    do:
      {:noreply,
       socket
       |> assign(:history_reverting?, false)
       |> put_flash(
         :info,
         gettext("Restored in the editor. The live page does not change until you publish.")
       )}

  def handle_async(:history_revert, {:ok, {:error, :gone}}, socket),
    do:
      {:noreply,
       socket
       |> assign(:history_reverting?, false)
       |> put_flash(:error, gettext("That step's document is no longer kept."))}

  # `:error` bare, as well as `{:error, reason}`: `History.revert/3` threads a `with` over
  # `decompress/1`, which answers `:error` on a payload that will not inflate.
  def handle_async(:history_revert, {:ok, _refused}, socket),
    do:
      {:noreply,
       socket
       |> assign(:history_reverting?, false)
       |> put_flash(:error, gettext("That step could not be restored."))}

  def handle_async(:history_revert, {:exit, _reason}, socket),
    do:
      {:noreply,
       socket
       |> assign(:history_reverting?, false)
       |> put_flash(:error, gettext("That step could not be restored."))}

  # WHAT THE CARD WILL PUT ON THE PAGE, rendered while the pointer rests on it.
  #
  # The client owns everything about showing it — when to ask, where to put it, when to take it away
  # — and the server owns only the render. So this pushes the document back rather than assigning it:
  # a preview that followed the pointer through the LiveView diff would patch the panel on every
  # card, and the panel is the one piece of chrome that must never flicker.
  #
  # `cancel_async` first, because `start_async` does not replace an in-flight task of the same name;
  # without it, a slow first render for one card could land after a fast one for the next and show
  # the wrong component.
  def handle_async(:card_preview, {:ok, {template, {:ok, html}}}, socket),
    do: {:noreply, push_event(socket, "pb:card-preview", %{template: template, html: html})}

  def handle_async(:card_preview, {:ok, {template, {:error, message}}}, socket),
    do: {:noreply, push_event(socket, "pb:card-preview", %{template: template, note: message})}

  # A render that crashes says so in the panel rather than leaving a spinner turning for ever. The
  # component's own author is who can fix it, and the log already carries the crash.
  def handle_async(:card_preview, {:exit, _reason}, socket),
    do:
      {:noreply,
       push_event(socket, "pb:card-preview", %{
         template: nil,
         note: gettext("This component could not be drawn.")
       })}

  # The sheet is a gervaz table, and it re-reads when the state it was handed stops matching — so a
  # written row is how the timeline learns there is something new to show.
  defp bump_history_revision(socket, {:ok, n}) when n > 0,
    do: bump_history_revision(socket)

  defp bump_history_revision(socket, _nothing_written), do: socket

  # AND HANDED OVER AGAIN, like every other table here refreshes. The number alone sits in an assign
  # the sheet never sees: `history_url_state` is rebuilt by `assign_editor/2`, so a bump with no edit
  # behind it reached the timeline whenever the author next happened to change something — which is
  # how a sheet open across a publish kept offering Restore over payloads that were already gone.
  defp bump_history_revision(socket),
    do: socket |> update(:history_revision, &((&1 || 0) + 1)) |> assign_history_url_state()

  # NOTHING IS SAVED WHILE PUBLISHING. The stage says where the next press goes, and on Publish the
  # answer is the live page — so a draft written behind it would be a second copy nobody asked for.
  # It also makes the promise the bar makes true: leave in publish mode and a reload shows the
  # original, because nothing was written and the session is not resumed.
  # "Draft · 9 Aug 2026, 20:15" — a name a reader can pick out of the drafts list a week later.
  defp save_draft_now(socket) do
    socket
    |> assign(:drafted_revision, nil)
    |> assign(:stage, :draft)
    |> autosave()
    |> assign(:stage, socket.assigns.stage)
  end

  # A QUEUED WRITE IN PUBLISH MODE IS ONE THE AUTHOR ASKED FOR. `autosave/1` refuses that stage
  # outright, so nothing but `save_draft_now/1` — the publish bar's "Keep as a draft" and the •••
  # menu's "Save draft now" — can have queued one here. Replaying the queue through `autosave/1`
  # walked it back into that refusal, so a second press during the first write wrote nothing at all.
  defp write_again(%{assigns: %{stage: :published}} = socket), do: save_draft_now(socket)

  defp write_again(socket), do: autosave(socket)

  # THE BAR IS ONLY DOWN WHILE A WRITE IT ASKED FOR IS RUNNING, and `autosaving?` is the proof there
  # is one: a `handle_async` is then guaranteed to come and answer for it. Read after every answer
  # and after every retry, so the flag can never outlive the write it stands for.
  defp holding_draft(%{assigns: %{stage: :published}} = socket),
    do: assign(socket, :keeping_draft?, socket.assigns.autosaving?)

  defp holding_draft(socket), do: assign(socket, :keeping_draft?, false)

  # A COMPONENT ANSWERS FIRST, WHATEVER THE STAGE. `Drafts` has no resource for one and answers
  # `:unsupported`, and the stage control is offered for a component like anything else — so with
  # this clause second, a component in publish mode was told its work had been kept as a draft by a
  # write that cannot happen at all.
  defp flash_drafted(%{assigns: %{section: "component"}} = socket),
    do: put_flash(socket, :error, gettext("A component has no drafts — use Publish to save it."))

  defp flash_drafted(%{assigns: %{stage: :published}} = socket),
    do: put_flash(socket, :info, gettext("Kept as a draft. Publish is still the live page."))

  defp flash_drafted(socket),
    do:
      put_flash(
        socket,
        :info,
        gettext("Saved to “%{label}”.", label: socket.assigns.draft_label)
      )

  defp session_draft_label do
    gettext("Draft · %{time}", time: Localized.datetime(DateTime.utc_now(), :yMMMdHm))
  end

  defp autosave(%{assigns: %{stage: :published}} = socket), do: socket

  defp autosave(%{assigns: %{dirty?: false}} = socket), do: socket

  # OFF the LiveView process. A draft write is a database round trip, and doing it inline froze the
  # editor for its duration every thirty seconds — every click, keystroke and drag queued behind it.
  # The tree is serialized here, where it is consistent, and only the write is handed away; the
  # result comes back as `{:autosaved, …}` below.
  #
  # `start` rather than `start_link`: a failed write must report itself, not take the editor down
  # with it. The task is supervised, so it is still cleaned up.
  # ONE WRITE AT A TIME, AND NEVER A LOST ONE. A change that arrives mid-write is remembered rather
  # than dropped, and written the moment the current one answers — so the draft always ends up
  # holding the last thing the author did, without a queue of overlapping writes to the same row.
  defp autosave(%{assigns: %{autosaving?: true}} = socket),
    do: assign(socket, :draft_again?, true)

  # SERIALIZING IS THE EXPENSIVE HALF, and it used to be the half that stayed. `to_heex/1` serializes
  # the tree, parses the result back to prove it survives a round trip, then runs the HEEx formatter
  # over it — three passes over the whole document, on the LiveView process, while the editor could
  # not answer a click. Only the database write was handed away.
  #
  # It all goes to the task now. The closure captured the whole `editor` struct already — `draft_id`
  # is read from it — so carrying the tree there costs nothing it was not already paying, and the
  # failure it can raise is reported by the same `handle_async` clause that reports a failed write.
  defp autosave(socket) do
    %{section: section, record: record, editor: editor} = socket.assigns
    actor = socket.assigns.current_user
    label = editor.draft_label || socket.assigns.draft_label
    who = actor_id(socket)

    socket
    |> assign(:autosaving?, true)
    # WHICH DOCUMENT THIS WRITE IS OF. The canvas stays live for the whole round trip, so by the
    # time it answers the author may have moved on — and `autosaved/2` has no other way to tell.
    |> assign(:autosaving_revision, editor.revision)
    |> assign(:draft_again?, false)
    |> MishkaGervaz.Messages.start_async(:autosave, fn ->
      case Serializer.to_heex(editor.tree) do
        {:ok, heex} -> gated_autosave(section, record, heex, actor, editor, label, who)
        _unserializable -> {:error, :unserializable}
      end
    end)
  end

  # ONLY THE DOCUMENT THAT WAS WRITTEN IS CALLED SAVED. `as_of` is the revision the task carried off;
  # an edit made while it was away leaves the session past that number and keeps it dirty, so the
  # publish bar comes back for work no draft holds instead of the editor falling silent over it.
  #
  # AND THE ROW IT MADE IS ADOPTED HERE, not waited for. `mark_saved/2` puts `draft_id` on the
  # session, but the socket's copy of the editor is the one the next write reads — left stale, a
  # retry saw no draft to update and made a second row for the same sitting.
  #
  # SO IS WHAT THE WRITE SETTLED. `dirty?` and `saved_at` come from the session this write stored,
  # in the same answer that takes `keeping_draft?` down. Left to the session's broadcast, which
  # arrives a message later, a render in between read a document still dirty with no write holding
  # the publish bar back — and "Keep as a draft" put the bar back up over work it had just kept.
  defp autosaved(socket, {:ok, draft}) do
    {:ok, editor} =
      EditorSession.mark_saved(socket.assigns.editor.token,
        stage: :draft,
        draft_id: draft.id,
        draft_label: draft.label,
        as_of: socket.assigns.autosaving_revision
      )

    socket
    |> adopt_history(draft)
    |> assign(:editor, editor)
    |> assign(:dirty?, editor.dirty?)
    |> assign(:saved_at, editor.saved_at)
    |> assign(:draft, draft)
    |> assign(:autosave_failed?, false)
  end

  # A COMPONENT HAS NO DRAFT RESOURCE, and saying so once a change would be a lie told constantly.
  # Its Save button is its only persistence, which the drafts sheet already says in words.
  defp autosaved(socket, :unsupported), do: socket

  defp autosaved(socket, _unsaved), do: autosave_failed(socket)

  # THE DRAFT IS MADE ON THE FIRST SAVE, not when the editor opens — so the first changes of a
  # sitting are recorded before there is a draft to attach them to, and would otherwise stay on the
  # live record's timeline while everything after them sat on the draft's. One afternoon, two lists,
  # for a reason no reader could infer. Only ever adopts what THIS sitting wrote.
  defp adopt_history(%{assigns: %{draft: %{id: id}}} = socket, %{id: id}), do: socket

  defp adopt_history(socket, draft) do
    %{token: token, current_user: actor} = socket.assigns
    History.adopt_draft(token, draft.id, actor)
    bump_history_revision(socket)
  end

  defp autosave_failed(%{assigns: %{autosave_failed?: true}} = socket), do: socket

  defp autosave_failed(socket) do
    socket
    |> assign(:autosave_failed?, true)
    |> put_flash(
      :error,
      gettext("Autosave is failing. Your edits are still here, but nothing is saved.")
    )
  end

  # A destination arrives from the browser, so it is checked before it is used: only a path of this
  # app, and never `//host`, which is a different origin wearing a path's clothes.
  # "RECORDED" IS THE WORD, everywhere. Not "kept" — draft mode already uses that for something
  # different, and one word for two states makes them read as one. Not "recoverable" — that is a
  # promise the retention cap can break, while "recorded" stays true even for a row whose document
  # was dropped. Seven strings say this; they are one sentence told in seven places and they change
  # together.
  defp flash_stage(socket, :published),
    do:
      put_flash(
        socket,
        :info,
        gettext(
          "Publish mode: changes are recorded but not saved to the page. It goes live when you press Publish."
        )
      )

  defp flash_stage(socket, :draft),
    do: put_flash(socket, :info, gettext("Draft mode: every change is kept as you make it."))

  defp leaving(socket, "//" <> _elsewhere), do: socket
  defp leaving(socket, "/" <> _path = to), do: ask_or_go(socket, to)
  defp leaving(socket, _elsewhere), do: socket

  defp ask_or_go(%{assigns: %{stage: :published, dirty?: true}} = socket, to),
    do: assign(socket, :leave_to, to)

  defp ask_or_go(socket, to), do: push_navigate(socket, to: to)

  @impl true
  def terminate(_reason, socket) do
    case socket.assigns[:editor] do
      nil -> :ok
      editor -> Events.session_closed(editor)
    end
  end

  @impl true
  def handle_event("set_left_tab", %{"tab" => tab}, socket),
    do: {:noreply, assign(socket, :left_tab, tab_atom(tab, [:components, :blocks, :inspector]))}

  # THE RAILS THAT EXIST, not the three the core ships. A whitelist of atoms rejected a contributed
  # rail before it could open — the tab drew, the click did nothing, and the registry that invited
  # the extension in was the thing refusing it.
  def handle_event("set_right_tab", %{"tab" => tab}, socket),
    do: {:noreply, assign(socket, :right_tab, rail_tab(socket, tab))}

  def handle_event("toggle_left", _params, socket),
    do: {:noreply, assign(socket, :left_hidden, !socket.assigns.left_hidden)}

  def handle_event("toggle_right", _params, socket),
    do: {:noreply, assign(socket, :right_hidden, !socket.assigns.right_hidden)}

  # Sent ONCE, when the grip is released — the drag itself is the browser's, painted locally at frame
  # rate. This is the value the panel is rendered from afterwards, so it still has to be clamped
  # here: what arrives is whatever the page chose to send.
  def handle_event("resize", %{"panel" => "left", "value" => value}, socket),
    do: {:noreply, assign(socket, :left_w, clamped(:left, value))}

  def handle_event("resize", %{"panel" => "right", "value" => value}, socket),
    do: {:noreply, assign(socket, :right_w, clamped(:right, value))}

  def handle_event("resize", %{"panel" => "drawer", "value" => value}, socket),
    do: {:noreply, assign(socket, :drawer_h, clamped(:drawer, value))}

  # THE LINK HAS TO RUN BOTH WAYS OR IT IS A TRAP. Choosing a breakpoint moves the frame; choosing a
  # FRAME left the breakpoint exactly where it was. So the canvas went to 390px while the Inspector's
  # strip still read Desktop — and every control on that strip still carried the `base` bucket, which
  # is every width. An author sizing something on a mobile canvas was writing an override for the
  # whole site and being shown a strip that disagreed with the picture in front of them.
  #
  # It reads the other way round too, and that is how it was reported: switch the frame back to
  # Desktop with Mobile still chosen in the Inspector and the Mobile tab sits lit over a desktop
  # canvas — so the first press on Mobile appears to do nothing, because it was already the lit one.
  def handle_event("set_device", %{"device" => device}, socket),
    do: {:noreply, follow_device(socket, tab_atom(device, [:frames, :desktop, :tablet, :mobile]))}

  def handle_event("zoom", %{"step" => step}, socket),
    do: {:noreply, assign(socket, :zoom, zoomed(:single, socket.assigns.zoom + to_int(step)))}

  def handle_event("zoom_reset", _params, socket), do: {:noreply, assign(socket, :zoom, 100)}

  def handle_event("frame_zoom", %{"step" => step}, socket),
    do: {:noreply, update(socket, :frame_zoom, &zoomed(:frame, &1 + to_int(step)))}

  def handle_event("frame_zoom_reset", _params, socket),
    do: {:noreply, assign(socket, :frame_zoom, 100)}

  # The value `PbZoom` settled on once the clicking stopped. An integer, or a string of one, is
  # clamped to `Panels.zoom_bounds/1`; anything else leaves the zoom where it is.
  def handle_event("zoom_set", params, socket),
    do: {:noreply, set_zoom(socket, :zoom, :single, params["value"])}

  def handle_event("frame_zoom_set", params, socket),
    do: {:noreply, set_zoom(socket, :frame_zoom, :frame, params["value"])}

  def handle_event("toggle_frame_row", _params, socket),
    do: {:noreply, update(socket, :frame_row, &(!&1))}

  # THE PAGE'S SOURCE, in a window. `to_heex/1` rather than `serialize/1` because the question
  # this answers is "what is stored", and those two strings are not the same: the drawer shows the
  # unformatted serialisation, a save writes the formatted one.
  #
  # OPENED ON A NAMED TAB when the click already knew which one it wanted. Everything that opens this
  # window opens it on whatever tab was last looked at, which is right for a button labelled "Code"
  # and wrong for a control that is a view of ONE tab's contents — the rail's `.interface` group is
  # the first of those, and landing on Template and hunting for Interface is not what it asked for.
  # A code tab opens only where this deployment takes code.
  def handle_event("open_source", %{"tab" => tab}, %{assigns: %{code_allowed?: false}} = socket)
      when tab in ~w(events infos helpers),
      do: {:noreply, put_flash(socket, :error, CodeAccess.refusal())}

  # `form` names a form whose handler entry, or else its row, the Handlers tab focuses.
  def handle_event("open_source", params, socket) do
    socket = assign(socket, source_modal: true, source_error: nil)

    case params do
      %{"tab" => tab} ->
        {:noreply,
         socket
         |> assign(:source_tab, tab_atom(tab, @source_tabs))
         |> focus_form(params["form"])}

      _wherever_it_was ->
        {:noreply, socket}
    end
  end

  # THE WAY OUT OF RECOVERY MODE. Parsed here first, because the point of this screen is that the
  # document does not parse and writing another one that does not would land the author straight back
  # on it. Then written through `Section.save/4` — the same action the editor saves with, so the
  # resource's own gate still applies and a correction that compiles for the tokenizer but not for
  # HEEx is refused rather than stored.
  def handle_event("recover_template", %{"template" => template}, socket) do
    case recover_template(socket, template) do
      :ok -> {:noreply, push_navigate(socket, to: recover_path(socket))}
      {:error, message} -> {:noreply, refused_recovery(socket, template, message)}
    end
  end

  # CLOSING FORGETS WHAT WAS NOT SAVED. `add_code` puts a blank entry straight into `fragments`, and
  # closing used to leave it there — so an empty handler somebody added and then cancelled went on
  # being part of the page for the rest of the session, and `CodeCheck` went on refusing it. Reading
  # the fragments back off the record is what "cancel" has always meant everywhere else.
  def handle_event("close_source", _params, socket) do
    {:noreply,
     assign(socket,
       source_modal: false,
       source_error: nil,
       code_fault: nil,
       code_focus: nil,
       source_draft: nil,
       fragments: code_fragments(socket.assigns[:record])
     )}
  end

  # THE PAGE'S OWN ELIXIR, in the window that already holds its markup. `events`, `infos` and
  # `helpers` have been Page attributes since the resource was written, and
  # `Compilers.LiveViewCompiler` has always turned them into `handle_event/3`, `handle_info/2` and
  # plain `def`s — but the only way to reach them was the Pages form, which is not where anyone is
  # when they need a handler for the button they just placed.
  # CSS FOR ONE ELEMENT. The element gets a minted class if it has none — that class is what the
  # rule is keyed on and it goes into the markup, so it survives a save and travels with the node on
  # copy — and the rule body goes into a stylesheet row the compiler already knows how to build.
  # Clearing the box takes the class back off, so nothing is left carrying a name for a rule that no
  # longer exists.
  def handle_event("save_element_css", %{"node_id" => node_id, "css" => css}, socket) do
    write_element_css(
      socket,
      socket.assigns.editor.tree,
      node_id,
      css,
      gettext("Style applied.")
    )
  end

  # ONE HAND-WRITTEN LINE, HANDED TO THE CONTROL THAT OWNS IT. The two never competed for storage —
  # controls own `meta.styles`, the text owns itself — so nothing here is a merge: the declaration is
  # read, written as an override, and taken out of the text.
  #
  # EXPLICIT AND ONE-WAY, on purpose. A live two-way binding — the control following the text as it
  # is typed, and the text following the control — is the obvious-looking design and Bricks is the
  # only builder in the field that ships one, still marked experimental, because keeping them in step
  # means rewriting the author's text underneath the cursor. A button they press when they mean it
  # costs one click and never surprises anyone.
  #
  # THE OP GOES FIRST, and the order is the whole safety argument. If the write to the stylesheet row
  # fails afterwards, the control is set and the line is still there: the CSS still wins, the page
  # looks exactly as it did, and the author is told. The other order loses the declaration the moment
  # anything downstream refuses.
  def handle_event("move_css_to_controls", %{"node_id" => node_id, "index" => index}, socket) do
    css = socket.assigns.element_css
    index = to_int(index)

    with %{} = declaration <- Enum.at(ElementCss.declarations(css), index),
         {:ok, {prop, value}} <- Styles.from_declaration(declaration.property, declaration.value),
         {:ok, editor} <- move_op(socket, node_id, declaration.bucket, prop, value) do
      focus_bucket(socket, declaration.bucket)
      write_element_css(socket, editor.tree, node_id, ElementCss.without(css, index), moved(prop))
    else
      _gone ->
        {:noreply,
         put_flash(socket, :error, gettext("That line is no longer there — reopen the panel."))}
    end
  end

  # WHAT AN ELEMENT DOES WHEN CLICKED, as a LiveView JS command in the markup rather than a script.
  # Under LiveView the server owns the DOM, so a script that changes a class is undone by the next
  # patch that touches the element — a declared command is part of what the server rendered and
  # survives. The target is the element's own scope class, which is the same handle its custom CSS
  # is keyed on: toggle `is-open` here, write `&.is-open { … }` there.
  # WHICH TARGET IS BEING AIMED AT, WHILE IT IS STILL BEING PICKED. The verbs a click can honour
  # depend on what it is pointed at — a dialog is opened and closed, a navbar is toggled — so the
  # action list has to follow the select rather than describe whatever was saved last time.
  # `"target"` is the select's own `name`, which is what a per-input `phx-change` posts — not
  # `"value"`, which is what the style forms next door post because their input is named that.
  def handle_event("aim_interaction", %{"target" => target}, socket),
    do: {:noreply, assign(socket, :aim_target, target)}

  # A CONDITION IS ONE CHOICE, so it saves on change rather than behind an Apply button — there is
  # nothing to fill in beside it and nothing to get half-right. `""` is "Always", which is the
  # attribute being taken off rather than an expression that is always true.
  def handle_event("save_condition", %{"node_id" => node_id, "rule" => rule}, socket) do
    write_condition(socket, node_id, Conditions.source(String.trim(rule)))
  end

  def handle_event("save_interaction", %{"node_id" => node_id} = params, socket) do
    action = String.trim(params["action"] || "")

    written =
      EditorSession.update_tree(
        socket.assigns.token,
        &interaction_tree(socket, &1, node_id, action, params),
        reason: :interaction
      )

    socket
    |> assign(:aim_target, nil)
    |> assign(:act_action, nil)
    |> save_interaction(written, action)
  end

  # WHICH BOX TO SHOW UNDER THE VERB. "Toggle a class" wants a class, "Show a message" wants words,
  # and "Show" wants neither — the panel used to draw the class box for all of them, which asked an
  # author to work out for themselves that it did nothing for four of the six. Answered on change
  # the same way the target select already answers one, because the form is already re-rendered when
  # the aim moves.
  def handle_event("pick_interaction", %{"action" => action}, socket),
    do: {:noreply, assign(socket, :act_action, action)}

  # ATTACHING A HOOK, NOT WRITING ONE. The name written is the one the JavaScript compiler registers
  # in the browser, asked for rather than rebuilt here. LiveView requires a unique id on any element
  # carrying `phx-hook` and silently never mounts one without it, so an element that has none is
  # given one.
  def handle_event("save_hook", %{"node_id" => node_id} = params, socket) do
    %{editor: editor, current_user: actor} = socket.assigns

    write_hook(socket, node_id, hook_outcome(actor, editor, String.trim(params["hook"] || "")))
  end

  def handle_event("source_tab", %{"tab" => tab}, %{assigns: %{code_allowed?: false}} = socket)
      when tab in ~w(events infos helpers),
      do: {:noreply, put_flash(socket, :error, CodeAccess.refusal())}

  def handle_event("source_tab", %{"tab" => tab}, socket) do
    {:noreply,
     socket
     |> assign(:source_tab, tab_atom(tab, @source_tabs))
     |> assign(:code_fault, nil)
     |> assign(:code_focus, nil)}
  end

  # The Styles tab lists rules, and a rule is only editable where its element is — so the way out of
  # the index is the same click that would have taken you there: select the element, close the
  # window, and land in the Inspector with its Custom CSS in front of you.
  def handle_event("select_from_code", %{"id" => node_id}, socket) do
    EditorSession.select(socket.assigns.token, node_id)

    {:noreply,
     socket
     |> assign(
       source_modal: false,
       source_error: nil,
       code_fault: nil,
       code_focus: nil,
       source_draft: nil
     )
     |> assign(:left_tab, :inspector)}
  end

  # THE SAME GATE, ONE STEP EARLIER. `Validations.CodeChange` refuses the Elixir whatever happens
  # here, so this is the difference between being told now and being told after typing a handler.
  # The events are refused as well as the tabs being hidden, because a hidden tab is not a closed
  # door: an event can be sent without one. Markup typed into the Template tab or an element's HEEx
  # box is code too, and the builder saves it as markup it generated, so it is refused here.
  #
  # ABOVE the clauses they guard. Elixir takes the first match, so underneath them they would never
  # run.
  def handle_event(event, _params, %{assigns: %{code_allowed?: false}} = socket)
      when event in ~w(add_code save_code remove_code apply_source apply_element_heex),
      do: {:noreply, put_flash(socket, :error, CodeAccess.refusal())}

  def handle_event("add_code", %{"tab" => tab}, socket) do
    key = tab_atom(tab, [:events, :infos, :state, :helpers])
    entries = Map.get(socket.assigns.fragments, key, []) ++ [blank_entry(key)]

    {:noreply,
     socket
     |> assign(:fragments, Map.put(socket.assigns.fragments, key, entries))
     |> assign(:code_fault, nil)}
  end

  def handle_event("remove_code", %{"tab" => tab, "index" => index}, socket) do
    key = tab_atom(tab, [:events, :infos, :state, :helpers])
    entries = socket.assigns.fragments |> Map.get(key, []) |> List.delete_at(to_int(index))

    {:noreply,
     socket
     |> assign(:fragments, Map.put(socket.assigns.fragments, key, entries))
     |> assign(:code_fault, nil)
     |> assign(:code_focus, nil)}
  end

  # Customize: keeps what was typed, then adds the form event's default code as a new entry and
  # focuses it. Nothing is stored until Save.
  def handle_event("save_code", %{"tab" => "events", "customize" => event} = params, socket) do
    {:noreply,
     socket
     |> assign(:fragments, Map.put(socket.assigns.fragments, :events, submitted_entries(params)))
     |> assign(:code_fault, nil)
     |> customize(event)}
  end

  # WRITTEN HERE, NOT CARRIED. Code is page configuration rather than document content, so it does
  # not belong in the document's save: the draft stage writes a Draft holding the tree and nothing
  # else, and anything merely held in an assign would have been lost the moment the tab closed.
  # Restoring a three-day-old draft reverting today's handlers would be the other half of the same
  # mistake.
  #
  # It is checked first, because the author is looking at the box the fault belongs to and will not
  # be by the time a flash arrives.
  # A TAB SWITCH SUBMITS THE FORM RATHER THAN NAVIGATING AWAY FROM IT — see `Panels.leaving/2`. What
  # was typed reaches the server this way and nowhere else, so this clause keeps it and moves on
  # without writing anything to the record: leaving a tab is not a save, and running `CodeCheck` over
  # a half-written handler would report a fault about a sentence somebody is still in the middle of.
  def handle_event("save_code", %{"tab" => tab, "go" => going} = params, socket)
      when is_binary(going) and going != "" do
    key = tab_atom(tab, [:events, :infos, :state, :helpers])

    {:noreply,
     socket
     |> assign(:fragments, Map.put(socket.assigns.fragments, key, submitted_entries(params)))
     |> assign(:source_tab, tab_atom(going, @source_tabs))
     |> assign(:code_fault, nil)
     |> assign(:code_focus, nil)}
  end

  def handle_event("save_code", %{"tab" => tab} = params, socket) do
    key = tab_atom(tab, [:events, :infos, :state, :helpers])
    fragments = Map.put(socket.assigns.fragments, key, submitted_entries(params))

    case CodeCheck.check(checkable(socket, fragments)) do
      :ok -> {:noreply, write_code(socket, fragments)}
      {:error, [fault | _rest]} -> {:noreply, held(socket, fragments, fault)}
    end
  end

  # A COMPONENT'S INTERFACE — the `attrs` and `slots` columns, which the builder could not edit at
  # all. They drive the Inspector's controls, `.properties`, `.slots` and every drop rule about the
  # component, and the only place to write them was the Components table form.
  #
  # Written through the same `save_section/4` the code fragments take, because they are the same kind
  # of thing: columns on this record that are not the document.
  # ONE CLICK RATHER THAN A SENTENCE TELLING YOU TO. The template already says what it needs; the
  # only thing left is to write it down, and the type it gets is `string` because that is what a
  # `{@thing}` in markup almost always is and the select beside it is one click from any other.
  #
  # It writes the column directly rather than reaching into the Gervaz form beside it: the form is
  # the resource's and owns its own state, and a record it did not save is one it re-reads when the
  # parent hands it a new `record_id`. See `refresh_interface_form/1`.
  def handle_event("declare_missing", %{"kind" => kind, "name" => name}, socket) do
    record = socket.assigns.record
    attrs = Interface.attrs(record)
    slots = Interface.slots(record)

    {attrs, slots} =
      case kind do
        "attr" -> {declared(attrs, "attr", name), slots}
        _slot -> {attrs, declared(slots, "slot", name)}
      end

    {:noreply, write_interface(socket, attrs, slots)}
  end

  # Applying re-parses and replaces the working tree — the same call a draft restore makes, so it is
  # one undo step and every open frame follows. Unparseable text keeps the window open with the text
  # still in it: losing what someone just typed is not a way to report a typo.
  # WHAT WAS TYPED SURVIVES A REFUSAL. The box is fed from the tree, and the tree does not change
  # when the parse fails — so the text held out for exactly as long as nothing else re-rendered it.
  # One `set_attr` from a collaborator, one autosave, and LiveView patched the textarea back to the
  # document and took a page of hand-written markup with it.
  #
  # The draft is held until it applies or the window closes, and it is what the box renders.
  def handle_event("apply_source", %{"source" => source}, socket) do
    case Events.before_code_apply(code_payload(socket, source, :document, nil)) do
      :ok -> apply_source(socket, source)
      {:error, message} -> {:noreply, assign(socket, :source_error, message)}
    end
  end

  # THE DRAWER'S HEEx PANE, applying to whatever it is scoped to. With nothing selected that is the
  # document and the work is `apply_source`'s; with an element selected it is that element, and
  # replacing one node in place is a DELETE AND AN INSERT AT THE SAME INDEX, run as one op so it is
  # one undo step, one broadcast, and passes the same containment and permission checks every other
  # edit does. Doing it as tree surgery here would have skipped all three.
  #
  # Delete first, insert second, and that order is deliberate: `insert` is the op that reports a
  # focus, so the element the reader ends up holding is the one they just wrote rather than the id of
  # something that no longer exists.
  def handle_event("apply_element_heex", %{"source" => source} = params, socket) do
    case Map.get(params, "node_id") do
      blank when blank in [nil, ""] -> apply_document_heex(socket, source)
      node_id -> apply_node_heex(socket, node_id, source)
    end
  end

  def handle_event("toggle_code", _params, socket),
    do: {:noreply, assign(socket, :code_open, !socket.assigns.code_open)}

  def handle_event("set_code_tab", %{"tab" => tab}, socket),
    do: {:noreply, assign(socket, :code_tab, tab_atom(tab, [:html, :css, :js]))}

  def handle_event("toggle_preview", _params, socket) do
    {:ok, _editor} = EditorSession.set_preview(socket.assigns.token, !socket.assigns.preview?)
    {:noreply, socket}
  end

  # Developer mode is the canvas's own outlines and node ids — a way to SEE the structure while
  # looking at the page, which is why it sits with the other ways of looking rather than in a
  # settings panel.
  def handle_event("toggle_dev_mode", _params, socket),
    do: {:noreply, update(socket, :dev_mode?, &(!&1))}

  def handle_event("set_dir", %{"dir" => dir}, socket) when dir in ~w(ltr rtl) do
    {:ok, _editor} = EditorSession.set_dir(socket.assigns.token, dir)
    {:noreply, socket}
  end

  # The menu SELECTS; it does not act. Picking "Published" from a dropdown and having the page go
  # live in the same gesture is not a choice anyone gets to reconsider — so this records the intent
  # and the button beside it is what carries it out.
  # PICKING A STAGE IS NOT DOING IT. The menu chooses where the NEXT press goes, and the difference
  # between the two choices is invisible until something is typed — so each one says, once, what it
  # has just changed about the way the editor behaves. Publish especially: choosing it stops the
  # saving, and a page that quietly stopped keeping work is the worst thing this editor could do
  # without mentioning it.
  def handle_event("set_stage", %{"stage" => stage}, socket) do
    stage = tab_atom(stage, [:draft, :published])
    {:ok, _editor} = EditorSession.set_stage(socket.assigns.token, stage)

    # The stage decides whose settings are drawn — the draft's or the page's — the layout among them.
    EditorSession.announce(socket.assigns.token, {:layout, :stage})

    {:noreply, socket |> assign(:stage, stage) |> flash_stage(stage)}
  end

  # ONLY WHEN THERE IS SOMETHING TO APPLY. When the selected stage is already the page's, the button
  # opens the menu instead — and it does that in the browser, so the template picks between the two
  # and this clause never sees the other case.
  def handle_event("apply_stage", _params, %{assigns: %{stage: :published}} = socket),
    do: {:noreply, save(socket, :published)}

  def handle_event("apply_stage", _params, socket),
    do: {:noreply, socket |> save_draft_now() |> flash_drafted()}

  # THE WAY OUT OF PUBLISH MODE WITHOUT LOSING THE WORK. Publish mode writes nothing until Publish is
  # pressed, which is the point of it — but an author who got there by accident needs somewhere for
  # their changes to go that is not "press Publish and hope".
  #
  # THE WRITE COMES FIRST, AND THE FLAG FOLLOWS IT. Marking the session saved here to take the bar
  # down left `autosave/1` looking at a clean session, and its second clause returns untouched on
  # one — so the single write this button exists to make never happened, the flash said it had, and
  # the bar that would have said so was the thing that had just been cleared. `draft_and_leave` is
  # the shape: write, then `autosaved/2` clears `dirty?` from the row it really got back.
  #
  # The bar goes down on a flag of its own instead, and only while a write it asked for is running —
  # `holding_draft/1` reads that flag off `autosaving?` after every answer, so a write that failed,
  # or one the author has edited past, puts the bar back rather than leaving the editor quiet over
  # work nothing has kept.
  def handle_event("keep_as_draft", _params, socket) do
    {:noreply, socket |> save_draft_now() |> holding_draft() |> flash_drafted()}
  end

  def handle_event("open_sheet", %{"sheet" => sheet}, socket) do
    sheets = [:none, :studio, :assets, :review, :history, :examples, :translations]
    opened = tab_atom(sheet, sheets)

    # The Record-history button always lands on Record history. Only the routes that mean "drafts"
    # — the header chip, the stage menu, the More menu — open the other tab.
    {:noreply, socket |> assign(:history_tab, :history) |> show_sheet(opened)}
  end

  # Switching tab resets the category: "media" means something different to a package than it does to
  # a token, so carrying the filter across would silently hide most of the next catalogue.
  # ASKED OF THE SAME LIST THE BUTTONS ARE DRAWN FROM. `Panels.studio_tabs/0` is
  # `Events.collect(:studio_tabs, …)`, so an extension can add one — and this list was written out
  # again by hand. `tab_atom/2` falls back to the head of what it is given, so a plugin's tab drew a
  # button that silently landed on Tokens, with no error to notice.
  def handle_event("studio_tab", %{"tab" => tab}, socket) do
    tabs = Enum.map(Panels.studio_tabs(socket.assigns[:current_user]), & &1.key)

    {:noreply,
     socket
     |> assign(studio_tab: tab_atom(tab, tabs), studio_cat: "all")
     |> reload_studio_if_filtered()}
  end

  # Inserting a snippet is the ordinary insert op, so it is undoable and containment-checked.
  def handle_event("pick_example", %{"index" => index}, socket),
    do: {:noreply, assign(socket, :example_index, to_int(index))}

  def handle_event("example_device", %{"device" => device}, socket)
      when device in ~w(desktop mobile),
      do: {:noreply, assign(socket, :example_device, device)}

  def handle_event("insert_snippet", %{"id" => id}, socket) do
    case Snippets.source(id, snippet_actor(socket)) do
      nil -> {:noreply, put_flash(socket, :error, gettext("That snippet no longer exists."))}
      source -> place_template(socket, source)
    end
  end

  # Deleting is scoped by who is asking, not by the id in the click: a tenant may delete its own
  # site's snippets and nothing else — not a global one, and not another site's.
  def handle_event("delete_snippet", %{"id" => id}, socket) do
    case Snippets.delete(id, snippet_actor(socket)) do
      :ok ->
        {:noreply, socket |> put_flash(:info, gettext("Snippet deleted.")) |> refresh_snippets()}

      {:error, :shared_with_every_site} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("That snippet is shared with every site — only a master can delete it.")
         )}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, gettext("That snippet belongs to another site."))}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("That snippet is no longer there."))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, human(reason))}
    end
  end

  def handle_event("token_format", %{"format" => format}, socket) do
    socket = assign(socket, :token_format, tab_atom(format, [:tw, :css, :json, :ex]))

    # Each row shows its reference in the selected format, so the table has to be told.
    {:noreply, assign_tokens_url_state(socket)}
  end

  # CLICKS ONLY. Escape belongs to `shortcut("escape", …)`, which is the editor's one keyboard
  # authority; this closes the sheet when its X is pressed or when a click lands outside it. The
  # folder form needs no guard here, because it is DRAWN inside the sheet — `phx-click-away` reads
  # the DOM, so a click in the form is not a click away from the sheet.
  def handle_event("close_sheet", _params, socket),
    do: {:noreply, socket |> assign(:sheet, :none) |> assign(:media_target, nil)}

  def handle_event("translation_pick", %{"id" => id}, socket),
    do: {:noreply, TranslationGroup.pick(socket, id)}

  def handle_event("translation_add_language", %{"language" => language}, socket),
    do: {:noreply, TranslationGroup.add_language(socket, language)}

  def handle_event("translation_back", _params, socket),
    do: {:noreply, TranslationGroup.close(socket)}

  # THE NAME AND THE PATH, over the editor rather than back on the list. The modal is the resource's
  # own Gervaz form, so everything after the click belongs to the resource — see
  # `MishkaCmsCoreWeb.Live.Admin.Builder.Panels.settings_modal/1`.
  # The ••• menu's SEO entry opens the same modal on its SEO tab, and on General where there is none.
  def handle_event("open_settings", params, socket) do
    socket = assign(socket, settings_open?: true, settings_tab: :general, seo_form?: false)
    handle_event("settings_tab", params, socket)
  end

  def handle_event("close_settings", _params, socket),
    do: {:noreply, assign(socket, settings_open?: false, seo_form?: false)}

  # THE SETTINGS MODAL'S TABS. The SEO tab's form mounts the first time the tab opens and stays,
  # hidden, until the modal closes, so moving between the tabs loses nothing typed in either.
  def handle_event("settings_tab", %{"tab" => "seo"}, %{assigns: %{section: section}} = socket) do
    case SeoSettings.mode(section) do
      nil -> {:noreply, socket}
      _mode -> {:noreply, assign(socket, settings_tab: :seo, seo_form?: true)}
    end
  end

  def handle_event("settings_tab", _params, socket),
    do: {:noreply, assign(socket, :settings_tab, :general)}

  # The share image is chosen from the site's Media library, in the same sheet and with the same Use
  # button an image on the canvas is. The modal steps aside while the sheet is open.
  def handle_event("seo_pick_image", _params, socket) do
    {:noreply,
     socket
     |> assign(:media_target, %{
       node_id: "seo",
       name: gettext("Share image"),
       seo: :image,
       accepts: :images
     })
     |> show_sheet(:assets)}
  end

  # RESOLVING RECORDS WHO DID IT. The action sets the resolver from the actor, together with the
  # timestamp, so nothing here names one.
  def handle_event("resolve_comment", %{"id" => id}, socket) do
    {:noreply, update_comment(socket, id, :resolve, gettext("Resolved."))}
  end

  def handle_event("reopen_comment", %{"id" => id}, socket) do
    {:noreply, update_comment(socket, id, :reopen, gettext("Reopened."))}
  end

  # REPLYING IS SEEDING THE COMPOSER, not opening a second one — the same move
  # `MishkaBlog.Comment`'s admin makes, where a Reply row action loads the parent and hands its ids
  # to the create form as `defaults`. Here the composer is already on screen, so there is nothing to
  # open: the parent goes on `defaults`, the form rebuilds, and the box is a reply box.
  def handle_event("reply_to_comment", %{"id" => id}, socket) do
    case Review.fetch(id, Panels.review_scope(socket.assigns)) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("That note is no longer here."))}

      comment ->
        {:noreply,
         socket
         |> assign(:reply_to, %{
           id: comment.id,
           node_id: comment.node_id,
           node_path: comment.node_path,
           node_label: comment.node_label
         })
         |> focus_composer()}
    end
  end

  def handle_event("cancel_reply", _params, socket),
    do: {:noreply, socket |> assign(:reply_to, nil) |> focus_composer()}

  # A NOTE ABOUT THE PAGE, WITH SOMETHING SELECTED. The composer anchors to whatever the canvas has,
  # which is right nearly always and wrong exactly when the thing you want to say is about the page
  # rather than the div you happen to have clicked. Deselecting in the canvas to say it is a detour;
  # this is the one click. It lasts until the selection changes, and then the composer goes back to
  # following it.
  def handle_event("comment_on_page", _params, socket),
    do: {:noreply, socket |> assign(:note_on_page?, true) |> focus_composer()}

  # NAMING SOMEBODY. The list is the server's because the candidates are — who a note may reach is a
  # tenancy question, and shipping every account to the browser to filter there would answer it in
  # the one place that cannot be trusted with it. The typing that drives it is the client's: the
  # `MentionBox` hook decides when a `@word` is being written and only then asks.
  def handle_event("mention_search", %{"q" => query}, socket) do
    {:noreply,
     assign(socket, :mentions, Mentions.candidates(Panels.review_scope(socket.assigns), query))}
  end

  # PICKING IS THE BROWSER'S ENTIRELY — it owns the caret, the arrow keys and the list's highlight,
  # and it tells the server only that the list is finished with. The server's whole part is answering
  # WHO can be named, which is the one question a browser must not be trusted with.
  def handle_event("mention_close", _params, socket),
    do: {:noreply, assign(socket, :mentions, [])}

  def handle_event("delete_comment", %{"id" => id}, socket) do
    {:noreply, update_comment(socket, id, :destroy, gettext("Note deleted."))}
  end

  # A NOTE POINTS AT AN ELEMENT, and clicking it goes there. `node_id` is the editor's own
  # handle, minted fresh by every parse, so it can point at nothing; `Review.locate/2` is the whole
  # of what to do about that, and the three answers get three different sentences rather than a
  # selection of nil.
  def handle_event("goto_comment", %{"id" => id}, socket) do
    scope = Panels.review_scope(socket.assigns)

    case id |> Review.fetch(scope) |> Review.locate(socket.assigns.editor.tree) do
      {:ok, node_id} ->
        EditorSession.select(socket.assigns.token, node_id, :panel)

        {:noreply,
         socket
         |> assign(sheet: :none, left_hidden: false, left_tab: :inspector)}

      :page ->
        {:noreply, put_flash(socket, :info, gettext("That note is about the whole page."))}

      :gone ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("The element that note was on is no longer on this page.")
         )}
    end
  end

  def handle_event("toggle_command", _params, socket),
    do: {:noreply, update(socket, :command_open, &(!&1))}

  def handle_event("command_query", %{"value" => value}, socket),
    do: {:noreply, assign(socket, :command_query, value)}

  def handle_event("palette_query", %{"value" => value}, socket),
    do: {:noreply, assign(socket, :palette_query, value)}

  def handle_event("palette_cat", %{"cat" => cat}, socket),
    do: {:noreply, assign(socket, :palette_cat, cat)}

  # The pick rides on the SESSION, not on this LiveView: the click that places the component lands
  # inside the canvas, which is a different LiveView and cannot see these assigns.
  # Four of the mobile tabs are not panels: they open the overlay the top bar has no room for at that
  # width, and leave the canvas showing underneath.
  def handle_event("set_mob_panel", %{"panel" => panel}, socket)
      when panel in ~w(assets studio review history),
      do:
        {:noreply,
         socket
         |> assign(:mob_panel, :canvas)
         |> show_sheet(tab_atom(panel, [:assets, :studio, :review, :history]))}

  def handle_event("set_mob_panel", %{"panel" => "palette"}, socket),
    do: {:noreply, assign(socket, command_open: true, command_query: "", mob_panel: :canvas)}

  def handle_event("set_mob_panel", %{"panel" => "dir"}, socket) do
    {:ok, _editor} =
      EditorSession.set_dir(socket.assigns.token, (socket.assigns.dir == "rtl" && "ltr") || "rtl")

    {:noreply, socket}
  end

  def handle_event("set_mob_panel", %{"panel" => panel}, socket)
      when panel in ~w(canvas components layers inspector assistant audit) do
    panel = tab_atom(panel, [:canvas, :components, :layers, :inspector, :assistant, :audit])

    {:noreply,
     socket
     |> assign(mob_panel: panel, sheet: :none)
     |> assign_panel_tab(panel)}
  end

  # The button is real and so is the answer: presets arrive through `Marketplace`, and the adapter
  # this install has configured is the mock one, which has nothing to apply. Saying so beats a button
  # that looks live and does nothing.
  def handle_event("apply_preset", %{"preset" => preset}, socket) do
    {:noreply,
     put_flash(
       socket,
       :info,
       gettext(
         "%{preset} is a marketplace preset. Connect a registry under Studio → Settings to apply it.",
         preset: preset
       )
     )}
  end

  def handle_event("pick", %{"name" => name}, socket), do: arm_or_place(socket, name)

  def handle_event("place", params, socket) do
    case EditorSession.place(
           socket.assigns.token,
           params["parent_id"] || "root",
           to_int(params["index"] || 0)
         ) do
      {:ok, _editor} -> {:noreply, socket}
      {:relocated, _editor, note} -> {:noreply, put_flash(socket, :info, note)}
      {:error, :nothing_picked} -> {:noreply, socket}
      {:error, reason} -> {:noreply, put_flash(socket, :error, human(reason))}
    end
  end

  # THE POINTER HAS RESTED ON A CARD. The template is the one the card would drop, sent up rather
  # than looked up, so the preview matches the drag even when a preset changed it.
  #
  # `PbPaletteHover` only asks once the pointer has settled, and asks again for nothing it has
  # already been given — so this is one render per component per session, not one per pass of the
  # mouse. See `MishkaCmsCore.Runtime.PageBuilder.CardPreview` for what that costs.
  def handle_event("preview_card", %{"template" => template}, socket)
      when is_binary(template) and template != "" do
    site_name = socket.assigns.editor.site_name

    # READ HERE, not in the task. A srcdoc document inherits this page's Content-Security-Policy, and
    # the admin's enforces `style-src-elem 'self' 'nonce-<n>'` — so the preview's own `<style>` needs
    # the nonce or it is refused and the card draws unstyled, which reads as a broken component. The
    # nonce lives on the socket, and the task does not get to look at the socket.
    nonce = socket.assigns[:csp_nonce]

    {:noreply,
     socket
     |> cancel_async(:card_preview)
     |> MishkaGervaz.Messages.start_async(:card_preview, fn ->
       {template, CardPreview.document(template, site_name, nonce)}
     end)}
  end

  def handle_event("preview_card", _params, socket), do: {:noreply, socket}

  # Opening the modal starts on the first variant and on the preview, not on the code — the question
  # a reader has about a variant is what it looks like.
  # AND IT OPENS ON THIS SITE'S PRESET. A preset is what a DRAG of this component places, and the
  # wizard used to open on the kit's defaults instead — so the preview showed one thing while the
  # card beside it placed another, and "make this the default" saved only what the reader had
  # re-picked, quietly dropping the rest of a preset they never meant to change.
  def handle_event("show_examples", %{"name" => name}, socket) do
    site_id = socket.assigns.editor.site_id

    {:noreply,
     socket
     |> set_wizard(Presets.get(site_id, name))
     |> assign(
       examples_for: name,
       sheet: :examples,
       example_index: 0,
       example_device: "desktop",
       # OPEN ON WHAT THERE IS. The badge now fires for a component with option lists and no example
       # markup, and landing such a reader on an empty Examples tab would be a worse door than the
       # one they could not open before.
       example_tab: opening_tab(socket, name)
     )
     # Curated for THIS component only, and only now. The palette carries no examples at all — see
     # `palette_entry/1` — because parsing every component's took 7.8 seconds at open.
     |> MishkaGervaz.Messages.assign_async(:examples, fn ->
       {:ok, %{examples: curated_examples(name, site_id)}}
     end)}
  end

  def handle_event("close_examples", _params, socket),
    do: {:noreply, socket |> set_wizard(%{}) |> assign(examples_for: nil, sheet: :none)}

  # An example is inserted as its PARSED SUBTREE — every attribute and child the example
  # demonstrates, not just its outermost tag — with each component's `site` bound to the scope that
  # component actually lives in, which for a global component is "Global" even on a tenant's page.
  def handle_event("insert_example", %{"index" => index}, socket) do
    with %{} = entry <- examples_entry(socket),
         example when not is_nil(example) <- Enum.at(entry.examples, to_int(index)),
         {:ok, subtree} <- Tree.parse(example.source) do
      template =
        subtree
        |> Tree.rewrite_site(socket.assigns.editor.site_name, socket.assigns.editor.components)
        |> Serializer.serialize()

      socket
      |> set_wizard(%{})
      |> assign(examples_for: nil, sheet: :none)
      |> then(&place_template(&1, template))
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, human(reason))}
      _missing -> {:noreply, assign(socket, examples_for: nil, sheet: :none)}
    end
  end

  # A pick is placed by CLICKING, and the layers tree is somewhere you can click. Clicking a row
  # while something is picked means "put it in here" — the same gesture the canvas offers, through
  # the same `place_at/2`, which puts it inside the row when the row can hold it, immediately after
  # when it cannot, and beside the other bands when the thing being placed is one. Clicking a row
  # with nothing picked still just selects.
  def handle_event("select", %{"id" => id}, socket) do
    place_or_select(socket.assigns.editor.picked, id, socket)
  end

  @doc """
  Drops the selection, so the code pane goes back to the whole document.

  The same two calls `shortcut("escape", …)` makes, reachable by clicking rather than only by a key
  nothing advertises — the code pane's scope chip is the button. A picked component is dropped with
  it: the author asking for the whole document back is not mid-placement.
  """
  def handle_event("clear_selection", _params, socket) do
    {:ok, _editor} = EditorSession.select(socket.assigns.token, nil)
    {:ok, _editor} = EditorSession.pick(socket.assigns.token, nil)
    {:noreply, socket}
  end

  def handle_event("toggle_expand", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      case MapSet.member?(expanded, id) do
        true -> MapSet.delete(expanded, id)
        false -> MapSet.put(expanded, id)
      end

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("toggle_lock", %{"id" => id}, socket) do
    {:ok, _editor} = EditorSession.toggle_lock(socket.assigns.token, id)
    {:noreply, socket}
  end

  def handle_event("toggle_hidden", %{"id" => id}, socket) do
    {:ok, _editor} = EditorSession.toggle_hidden(socket.assigns.token, id)
    {:noreply, socket}
  end

  def handle_event("toggle_pinned", %{"id" => id}, socket) do
    {:ok, _editor} = EditorSession.toggle_pinned(socket.assigns.token, id)
    {:noreply, socket}
  end

  def handle_event("studio_scope", %{"scope" => scope}, socket),
    do: {:noreply, assign(socket, :studio_scope, tab_atom(scope, [:all, :downloaded, :shop]))}

  # One category filter serves all four catalogues — switching tab resets it, because "media" means
  # something different to a package than it does to a token.
  def handle_event("studio_cat", %{"cat" => cat}, socket),
    do: {:noreply, socket |> assign(:studio_cat, cat) |> reload_studio_if_filtered()}

  def handle_event("studio_query", %{"value" => value}, socket),
    do: {:noreply, assign(socket, :studio_query, value)}

  # Reloading the frame is safe for the document — the canvas re-reads the same session — but not for
  # whatever is mid-edit in the browser, so unsaved work earns a question first.
  def handle_event("reload_canvas", _params, %{assigns: %{dirty?: true}} = socket),
    do: {:noreply, assign(socket, :reload_confirm, true)}

  def handle_event("reload_canvas", _params, socket), do: {:noreply, reload_canvas(socket)}

  def handle_event("close_reload", _params, socket),
    do: {:noreply, assign(socket, :reload_confirm, false)}

  # The tree is the map and the Inspector is the form, so a row that HAS a form opens it: the left
  # panel comes back if it was collapsed, lands on the Inspector, and the named property is focused
  # and ringed so it is obvious which of thirty fields you asked for.
  # A component or slot row opens its form — unless something is picked, in which case the click
  # means the same thing it means on every other row and on the canvas: put it in here. Without this
  # the tree would place into a `<div>` but not into the component you actually wanted it inside,
  # which is the only reason to click a component row while placing.
  def handle_event("inspect", %{"id" => id} = params, socket) do
    case socket.assigns.editor.picked do
      nil -> {:noreply, open_inspector(socket, id, params["prop"])}
      picked -> place_or_select(picked, id, socket)
    end
  end

  # The icon picker is opened per PROPERTY, not globally: a component can declare `icon`, `start_icon`
  # and `end_icon`, and one shared "is the picker open" flag would open all three at once.
  # The modal's two tabs. A component with no option lists has no Wizard tab at all, so landing on
  # it is impossible rather than empty.
  def handle_event("example_tab", %{"tab" => tab}, socket),
    do: {:noreply, assign(socket, :example_tab, tab_atom(tab, [:examples, :wizard]))}

  # Each pick goes through the SESSION as well as the socket: the preview is a second LiveView in an
  # iframe, and the session is how the two share anything.
  def handle_event("wizard_pick", %{"name" => name, "value" => value}, socket),
    do: {:noreply, set_wizard(socket, Map.put(socket.assigns.wizard, name, value))}

  # Back to the KIT'S defaults, not to this site's preset — "reset" has meant the component as it
  # ships since there was a wizard, and forgetting the preset is the button next to it.
  def handle_event("wizard_reset", _params, socket), do: {:noreply, set_wizard(socket, %{})}

  # Composed from the reader's choices and placed through the same op pipeline an example uses, so
  # it lands as an ordinary node: containment-checked, undoable, editable afterwards.
  def handle_event("insert_wizard", _params, socket) do
    entry = examples_entry(socket.assigns)

    %{wizard: wizard, editor: editor} = socket.assigns

    case entry && Wizard.compose(entry, wizard, editor.site_name, :blank, editor.components) do
      nil ->
        {:noreply, socket}

      source ->
        socket
        |> set_wizard(%{})
        |> assign(examples_for: nil, sheet: :none)
        |> place_template(source)
    end
  end

  # A design token is a declaration in the site's own theme stylesheet, so setting one rewrites that
  # row, and the row's save rebuilds the site's CSS. Every component that resolves through the token
  # changes at once — which is the whole reason this lives in the Studio rather than on an element.
  def handle_event("set_token", %{"key" => key, "value" => value}, socket) do
    editor = socket.assigns.editor

    case Events.before_token_set(%{
           key: key,
           value: value,
           site_id: editor.site_id,
           site_name: editor.site_name,
           actor_id: actor_id(socket)
         }) do
      {:ok, value} -> set_token(socket, editor, key, value)
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  # Which sections the reader has folded, and only the ones they touched. A group nobody has clicked
  # is absent from the map and falls back to its own default — open for a component's properties,
  # closed for the chrome under a component that already has a long panel. The heading sends the
  # state it is currently in, so the toggle does not have to know which default applied.
  def handle_event("toggle_prop_group", %{"group" => group} = params, socket) do
    folded = params["folded"] == "true"

    {:noreply, assign(socket, :group_folds, Map.put(socket.assigns.group_folds, group, !folded))}
  end

  # Re-runs the read the `:failed` slot's Retry button offers. Almost every palette failure is
  # transient — a connection dropped under load — so trying again is the whole remedy, and doing it
  # without a page reload keeps the document, the history and the selection intact.
  def handle_event("retry_palette", _params, socket) do
    editor = socket.assigns.editor
    params = %{"site_id" => editor.site_id}

    {:noreply, load_palette_async(socket, editor, socket.assigns[:current_user], params)}
  end

  # CLICKING THE OPEN ONE CLOSES IT, which needs the already-open case to match rather than be
  # computed: `(open == name && nil) || name` yields `name` when they are equal, because `nil || name`
  # is `name`. Written that way the picker opened and never closed.
  def handle_event(
        "toggle_icon_picker",
        %{"name" => name},
        %{assigns: %{icon_picker: name}} = socket
      ),
      do: {:noreply, socket |> assign(:icon_picker, nil) |> assign(:icon_query, "")}

  def handle_event("toggle_icon_picker", %{"name" => name}, socket),
    do: {:noreply, socket |> assign(:icon_picker, name) |> assign(:icon_query, "")}

  def handle_event("close_icon_picker", _params, socket),
    do: {:noreply, assign(socket, :icon_picker, nil)}

  # TYPED, not picked. The control is a combobox: the catalogue is a suggestion, never a whitelist.
  #
  # The reason is that the catalogue can only ever be the sets this install registered, and an author
  # may legitimately name an icon from one it has not — a second kit's own glyphs, a class the host
  # ships itself. A control that refuses those makes the editor the arbiter of what icons exist,
  # which it is not in a position to be. So every keystroke writes the attribute AND narrows the
  # grid, and the grid is there to save typing rather than to constrain it.
  def handle_event(
        "icon_typed",
        %{"name" => name, "node_id" => node_id, "value" => value} = params,
        socket
      ) do
    # Through the ordinary `op` path, so clearing the box removes the attribute and the component's
    # own default comes back — the same rule every other field follows.
    {:noreply, socket} =
      handle_event(
        "op",
        icon_op(params, %{"kind" => "set_attr", "node_id" => node_id, "name" => name}, value),
        socket
      )

    {:noreply, socket |> assign(:icon_query, value) |> assign(:icon_picker, name)}
  end

  def handle_event("icon_variant", %{"variant" => variant}, socket),
    do: {:noreply, assign(socket, :icon_variant, variant)}

  # PICKING is a decision; typing is not. The grid used to fire `op` directly, which set the
  # attribute and left the popover sitting open over the rest of the panel — the reader had chosen,
  # and the editor still looked like it was asking. Typing deliberately keeps it open, because there
  # the list is a filter being narrowed rather than a question being answered.
  def handle_event("icon_picked", %{"value" => value} = params, socket) do
    op = params |> Map.take(["node_id", "name"]) |> Map.put("kind", "set_attr")

    {:noreply, socket} = handle_event("op", icon_op(params, op, value), socket)

    {:noreply, assign(socket, :icon_picker, nil)}
  end

  # Only rendered when more than one icon set is registered, so on a stock install this never fires.
  # Clicking the active one clears the filter, which is how every other toggle here behaves.
  def handle_event(
        "icon_library",
        %{"library" => library},
        %{assigns: %{icon_library: library}} = socket
      ),
      do: {:noreply, assign(socket, :icon_library, nil)}

  def handle_event("icon_library", %{"library" => library}, socket),
    do: {:noreply, assign(socket, :icon_library, library)}

  # An attribute the component never declared — `aria-label`, `data-role`, a stray `phx-hook`. It
  # reaches the component through its `@rest` catch-all, which is why the panel lists these apart
  # from the declared properties rather than pretending they are the same thing.
  #
  # A blank name is a no-op, not an error: the form is a text box, and typing nothing into it is a
  # way of changing your mind.
  def handle_event("add_extra_attr", %{"node_id" => id, "name" => name}, socket) do
    socket = clear_typed(socket, "pb-extra-form-#{id}")

    case String.trim(name) do
      "" -> {:noreply, socket}
      trimmed -> attr_added(socket, Tree.get(socket.assigns.editor.tree, id), trimmed, nil)
    end
  end

  def handle_event("drop_attachment", _params, socket),
    do: {:noreply, assign(socket, :ai_attachment, nil)}

  # What travels with the next prompt. The prototype attaches a screenshot; this attaches the SOURCE,
  # because the editor already holds it and a model can act on markup but not on a picture of it.
  def handle_event("attach", %{"kind" => "selection"}, socket) do
    {:noreply, attach(socket, :selection)}
  end

  def handle_event("attach", %{"kind" => "template"}, socket) do
    {:noreply, attach(socket, :template)}
  end

  # A file means a file the site already has, so this opens the library rather than inventing an
  # upload the assistant could not read anyway.
  def handle_event("attach", %{"kind" => "file"}, socket) do
    {:noreply, show_sheet(socket, :assets)}
  end

  # LEAVING IN PUBLISH MODE IS THE ONE WAY TO LOSE WORK HERE. Every other mode writes as you go, so
  # the door is free to walk through; publish mode deliberately writes nothing, which is what makes
  # "refresh and the original comes back" true and what makes a closed tab final.
  #
  # The client asks rather than decides: `data-armed` is a rendered attribute, so it is one patch
  # behind a change made in the same breath as the click, and the server always has the current
  # answer. A destination that is not a path of this app is refused outright — it arrives from the
  # browser, and `//host` is a different origin wearing a path's clothes.
  def handle_event("leaving", %{"to" => to}, socket), do: {:noreply, leaving(socket, to)}

  def handle_event("stay", _params, socket), do: {:noreply, assign(socket, :leave_to, nil)}

  def handle_event("leave_anyway", _params, %{assigns: %{leave_to: to}} = socket)
      when is_binary(to),
      do: {:noreply, push_navigate(socket, to: to)}

  def handle_event("leave_anyway", _params, socket),
    do: {:noreply, assign(socket, :leave_to, nil)}

  # THIS SAVE CANNOT BE ASYNCHRONOUS. `push_navigate` takes the LiveView down and a `start_async`
  # task dies with it, so the draft the author just asked for would be a race they lose about half
  # the time. One inline round trip, on the way out, and the flash names what it was kept as.
  #
  # IT IS STILL AN ORDINARY AUTOSAVE, so it goes through `gated_autosave/7` like the sitting's own.
  # Calling `Drafts` directly left the status off the end of the call — the one argument that says
  # WHICH of an error page's templates is being written — so the 500 an author was editing was filed
  # under 404, over a 404 they never opened, by the one button whose whole purpose is not to lose
  # work. It also skipped the gate an extension refuses a draft with and the announcement a backup
  # or a sync integration listens for.
  def handle_event("draft_and_leave", _params, socket) do
    %{section: section, record: record, editor: editor, leave_to: to} = socket.assigns
    label = editor.draft_label || socket.assigns.draft_label

    with {:ok, heex} <- Serializer.to_heex(editor.tree),
         {:ok, draft} <-
           gated_autosave(
             section,
             record,
             heex,
             socket.assigns.current_user,
             editor,
             label,
             actor_id(socket)
           ) do
      {:ok, _editor} =
        EditorSession.mark_saved(editor.token,
          stage: :draft,
          draft_id: draft.id,
          draft_label: draft.label
        )

      {:noreply,
       socket
       |> put_flash(:info, gettext("Kept as “%{label}”.", label: draft.label))
       |> push_navigate(to: to)}
    else
      _unsaved ->
        {:noreply,
         socket
         |> assign(:leave_to, nil)
         |> put_flash(
           :error,
           gettext("That could not be saved, so you are still here with your changes.")
         )}
    end
  end

  # THE OTHER ANSWER TO THE SAME QUESTION. Publishing is already synchronous — `save/2` writes the
  # live record and enqueues the compile before it returns — so this is the ordinary publish with a
  # navigation on the end, and it only navigates when the write actually happened. A publish that
  # failed leaves the author here, looking at the error and still holding their work.
  # It leaves only if the write REALLY happened: `write/2` swaps in the record it persisted, so a new
  # struct is the proof, and a refusal — a required property left empty, a serializer that could not
  # read the tree — leaves the old one in place. Doubt keeps the author here with their work and the
  # error in front of them, which is the safe direction for this to be wrong in.
  def handle_event("publish_and_leave", _params, socket) do
    %{leave_to: to, record: before} = socket.assigns
    published = save(socket, :published)

    case published.assigns.record != before do
      true -> {:noreply, push_navigate(published, to: to)}
      false -> {:noreply, assign(published, :leave_to, nil)}
    end
  end

  def handle_event("confirm_reload", _params, socket), do: {:noreply, reload_canvas(socket)}

  def handle_event("save_and_reload", params, socket) do
    {:noreply, saved} = handle_event("save", params, socket)
    {:noreply, reload_canvas(saved)}
  end

  # The Studio's switches are real settings, written through the same actor-aware façade the settings
  # page uses — so a tenant cannot write another site's row and a master's write is audited.
  def handle_event("studio_option", %{"key" => key}, socket) do
    site_id = socket.assigns.editor.site_id
    value = !Map.get(socket.assigns.studio_options, key, false)

    case Settings.put_as(socket.assigns[:current_user], key, value, site_id: site_id) do
      {:ok, _value} -> {:noreply, assign_studio_settings(socket)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, human(reason))}
    end
  end

  def handle_event("registry_source", %{"registry" => %{"source" => source}}, socket) do
    site_id = socket.assigns.editor.site_id

    case Settings.put_as(socket.assigns[:current_user], "studio.registry_source", source,
           site_id: site_id
         ) do
      {:ok, _value} -> {:noreply, assign_studio_settings(socket)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, human(reason))}
    end
  end

  # Installing brings the component's dependency closure with it, so the flash names what actually
  # arrived rather than only what was clicked — picking `card` installs `icon` too, and a count that
  # does not match the button is the kind of surprise that reads as a bug.
  # THE SCOPE COMES FROM THE ACTOR, not from the event. A tenant who never sees the control can still
  # emit this click with `scope: "global"`, and `install_kit!/2` writes `site_id` straight through —
  # their components would land on every site on the server, removable only by a master.
  def handle_event("install_package", %{"package" => id} = params, socket) do
    requested =
      case Map.get(params, "scope") do
        "global" -> :global
        _this_site -> socket.assigns.editor.site_id
      end

    case UiKitHandler.install_scope(socket.assigns[:current_user], requested) do
      {:ok, site_id} ->
        install_package(socket, id, site_id)

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, gettext("You cannot install for that site."))}
    end
  end

  # SAME FLOW AS A COMPONENT, THROUGH THE SAME FIELD. The pick lives in the SESSION so the canvas
  # sees it too: held in this LiveView's own assigns it armed the panel and nothing else, and
  # clicking the page did nothing while the hint said "click the canvas or a layer".
  #
  # `Tree.insert/4` splices a section's several roots in as ONE undoable op, so a forty-node pricing
  # table arrives and leaves in a single step.
  def handle_event("pick_block", %{"block" => id}, socket), do: arm_or_place(socket, {:block, id})

  def handle_event("block_cat", %{"cat" => cat}, socket),
    do: {:noreply, assign(socket, :block_cat, cat)}

  def handle_event("block_query", %{"value" => value}, socket),
    do: {:noreply, assign(socket, :block_query, value)}

  # The pills are the gervaz table's own filter now — the template renders them and the table handles
  # the event, so the editor no longer keeps a parallel copy of which one is active.

  # Opening the library ON BEHALF of one attribute. The target rides in an assign rather than in the
  # sheet's markup because the sheet is a different panel entirely — and it is cleared on close, so
  # browsing the library later never writes into an attribute nobody was choosing for.
  def handle_event("pick_media", %{"node_id" => node_id, "name" => name} = params, socket) do
    {:noreply,
     socket
     |> assign(:media_target, %{
       node_id: node_id,
       name: name,
       # ONE PICTURE OUT OF A LIST. A filterable gallery's photographs are items in an attribute, so
       # the library has to be told which one is being chosen for — the attribute alone addresses
       # the whole collection. Absent for every ordinary media attribute, and `place_media/2` then
       # writes the attribute itself exactly as it always did.
       item: item_target(params),
       accepts: accepts(socket, node_id, name)
     })
     |> show_sheet(:assets)}
  end

  # THE WHOLE COLLECTION, REWRITTEN. One `set_attr` per change, so one add, one removal and one edit
  # are each one undo step — and an attribute the editor could not read is left alone rather than
  # replaced with what it made of it.
  def handle_event("collection_add", %{"node_id" => node_id, "name" => name}, socket) do
    write_collection(socket, node_id, name, fn items ->
      Collection.add(items, Collection.blank(items))
    end)
  end

  def handle_event(
        "collection_remove",
        %{"node_id" => node_id, "name" => name, "index" => index},
        socket
      ) do
    write_collection(socket, node_id, name, &Collection.remove(&1, to_index(index)))
  end

  def handle_event(
        "collection_set",
        %{"node_id" => node_id, "name" => name, "index" => index, "value" => value} = params,
        socket
      ) do
    at = to_index(index)

    change =
      case params["key"] do
        blank when blank in [nil, ""] -> &Collection.put(&1, at, value)
        "__key" -> &Collection.put_side(&1, at, :key, value)
        "__value" -> &Collection.put_side(&1, at, :value, value)
        key -> &Collection.put_in_item(&1, at, key, value)
      end

    write_collection(socket, node_id, name, change)
  end

  # THE SAME LIBRARY, FOR THE ONE PLACE A PICTURE IS NOT AN ATTRIBUTE. A hero's photograph is a
  # background, so it has no `src` to point at — which left the site's own library reachable from an
  # `<img>` and not from the element people most want a picture on, and left the author typing a
  # path they had to go and read off another page.
  def handle_event("pick_background", %{"node_id" => node_id, "bucket" => bucket}, socket) do
    {:noreply,
     socket
     |> assign(:media_target, %{
       node_id: node_id,
       bucket: bucket,
       prop: "background",
       accepts: :images
     })
     |> show_sheet(:assets)}
  end

  # THE SHEET'S SIDEBAR IS A FILTER. It rides `path_params` rather than the table's filter event
  # because `media_category_id` matches a Media attribute, and Gervaz turns such a param into an
  # equality filter — the same channel `site_id` already uses to scope the sheet to one site. Going
  # through the filter event would mean the sidebar and the search box overwriting each other, since
  # a filter push replaces the whole set.
  def handle_event("select_asset_category", %{"id" => id}, socket),
    do: {:noreply, assign(socket, :assets_category, blank_to_nil(id))}

  def handle_event("cancel_media_pick", _params, socket),
    do: {:noreply, assign(socket, :media_target, nil)}

  # A FOLDER IS MADE HERE OR IT IS NOT MADE. `+ Folder` used to navigate to the Media library, which
  # is a page away from the document being edited and loses the sheet, the selection and the pick
  # the author came in with — for a control whose whole job is to hold the file they are about to
  # drop.
  def handle_event("new_folder", _params, socket),
    do: {:noreply, assign(socket, :folder_form?, true)}

  def handle_event("close_folder", _params, socket),
    do: {:noreply, assign(socket, :folder_form?, false)}

  def handle_event("close_media_preview", _params, socket),
    do: {:noreply, assign(socket, :preview_media, nil)}

  # THE RECORD IS MADE HERE, then the editor reopens on it. Creating it up front rather than holding
  # the answers until the first save keeps every other path — autosave, drafts, publish, the canvas
  # itself — working on an ordinary record instead of a special half-made one.
  #
  # `save_section/4` already knows master from tenant: a master writes `:master_create` with the
  # site they chose, a tenant writes `:create` under their own and the site is dropped. That is why
  # the form only asks a master.
  # A chip fills the box rather than sending, so the wording stays the author's to adjust.
  def handle_event("ai_chip", %{"text" => text}, socket),
    do: {:noreply, assign(socket, :ai_prompt, text)}

  # Restore rolls the document back to the state a reply produced, through the session's own history
  # rather than a parallel one — so it is itself undoable.
  def handle_event("ai_restore", %{"index" => index}, socket) do
    message = Enum.at(socket.assigns.ai_messages, to_int(index))

    case message && Map.get(message, :tree) do
      nil ->
        {:noreply, socket}

      tree ->
        {:ok, _editor} = EditorSession.put_tree(socket.assigns.token, tree, reason: :revert)
        # The captured tree is the one from BEFORE the prompt, so this undoes that request rather
        # than restoring what it produced. "Rolled back to r5" said the opposite.
        {:noreply,
         put_flash(
           socket,
           :info,
           gettext("Undid %{revision} — the document is back to before that request.",
             revision: message.revision
           )
         )}
    end
  end

  def handle_event("audit_rerun", _params, socket),
    do:
      {:noreply, put_flash(socket, :info, gettext("Checks re-run against the current document."))}

  # A Forms finding names an edit rather than a decision — wrap this field, rename that form, move
  # this button — so Fix makes it, in one history entry, and where there is no edit to make it says
  # why in a sentence rather than swinging the rail over to the assistant. Any other finding is handed
  # to the assistant as scoped prompt text — the one rail that can actually change the document.
  # Selecting the node first is what makes the request scoped.
  # NOT `%{"rule" => rule, "id" => id}`. A finding about the DOCUMENT — no meta description, no
  # title, no heading, a bundle over budget — has no node, and HEEx omits an attribute whose value is
  # `nil`, so those clicks arrive without an `id` at all and used to fall through to the catch-all.
  # Which meant the Fix button did nothing on exactly the findings that fire on every page.
  def handle_event("audit_fix", %{"rule" => rule} = params, socket) do
    case FormChecks.rule?(rule) do
      true -> form_fix(rule, params, socket)
      false -> audit_ask(rule, params, socket)
    end
  end

  # A Behavior switch edits the element's `class`, so it goes through the same `set_attr` op every
  # other property edit uses — one funnel, one history entry, one containment check.
  #
  # THE SWITCH EDITS CLASSES, NOT THE TEXT OF THE ATTRIBUTE. Joining what the element wears back
  # into one string wrote an expression's own source onto it as literal text, so flipping a switch
  # on a component with a computed class left markup the page could not be compiled from.
  # `Tree.class_with/2` and `Tree.class_without/2` answer the value in the shape it already has.
  def handle_event("toggle_behavior", %{"id" => id, "key" => key}, socket) do
    case Tree.get(socket.assigns.editor.tree, id) do
      nil ->
        {:noreply, socket}

      node ->
        {_key, _label, toggled} =
          Enum.find(Panels.behavior_toggles(), fn {k, _l, _c} -> k == key end)

        {kind, value} =
          case Panels.behavior_on?(node, key) do
            true -> Tree.class_without(node, toggled)
            false -> Tree.class_with(node, toggled)
          end

        handle_event(
          "op",
          %{
            "kind" => "set_attr",
            "node_id" => id,
            "name" => "class",
            "value" => value,
            "value_kind" => to_string(kind)
          },
          socket
        )
    end
  end

  def handle_event("toggle_attr_form", _params, socket),
    do: {:noreply, update(socket, :attr_form, &(!&1))}

  # Adding an attribute is the same `set_attr` op the existing rows use — the form only supplies the
  # name, which those rows cannot. A blank name is ignored rather than writing a nameless attribute.
  #
  # An ELEMENT is where `:if`, `phx-click` and `phx-hook` live, and this box asks the same question
  # of a name as its sibling in Advanced does: the list above it holds every attribute the element
  # carries, so a name already in that list is a row to land on and not a second attribute. Typing
  # one with the value box left empty used to reach the empty-value rule below and REMOVE it.
  def handle_event("add_attr", %{"attr" => %{"name" => name} = attr}, socket) do
    socket = socket |> assign(:attr_form, false) |> clear_typed("pb-attr-form")

    case String.trim(name) do
      "" ->
        {:noreply, socket}

      trimmed ->
        node = Tree.get(socket.assigns.editor.tree, socket.assigns.editor.selection)

        attr_added(socket, node, trimmed, attr["value"])
    end
  end

  # AND THE CANVAS GOES WITH IT. Choosing Tablet in the Inspector says "I am working on tablet", and
  # leaving the frame at desktop width answers that with a page the override cannot be seen on — the
  # author sets a value, nothing moves, and the control reads as broken when it is the viewport that
  # is wrong.
  #
  # Only when the frame is showing ONE device. `:frames` is the side-by-side view, where every width
  # is already on screen and switching it to one would take away what the reader opened it for.
  def handle_event("set_breakpoint", %{"value" => value}, socket) do
    breakpoint = tab_atom(value, [:base, :tablet, :mobile])

    {:ok, _editor} = EditorSession.set_breakpoint(socket.assigns.token, breakpoint)

    {:noreply, follow_breakpoint(socket, breakpoint)}
  end

  def handle_event("set_pseudo", %{"value" => value}, socket) do
    {:ok, _editor} =
      EditorSession.set_pseudo(
        socket.assigns.token,
        tab_atom(value, [:base, :hover, :focus, :active])
      )

    {:noreply, socket}
  end

  # Both halves of the hybrid. `drag_start` hands the rail (and the palette, which drags into the
  # canvas across the frame boundary) the whole tree's verdict for this one drag, so its drop line is
  # a lookup rather than a round trip. See `EditorSession.drop_hints/2`.
  def handle_event("drag_start", params, socket) do
    case EditorSession.drop_hints(socket.assigns.token, params) do
      {:ok, accepts} ->
        {:noreply,
         push_event(socket, "pb:drop-hints", %{
           accepts: accepts,
           field: EditorSession.drop_field?(socket.assigns.token, params)
         })}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  # A drop resolved by the client is still only a proposal: it becomes a `:move` or an `:insert` here
  # and is re-checked against containment before the tree changes. A refusal relocates rather than
  # discards — see `EditorSession.apply_drop/2`.
  def handle_event("drop", params, socket) do
    case EditorSession.apply_drop(socket.assigns.token, params) do
      {:ok, _editor} -> {:noreply, socket}
      {:relocated, _editor, note} -> {:noreply, put_flash(socket, :info, note)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, human(reason))}
    end
  end

  # Setting a property to nothing REMOVES it, so the component's own default comes back. Writing an
  # empty string instead is what made a field you merely clicked into and left blank the message —
  # blur sent "", the attribute was written empty, and the default it was showing disappeared.
  def handle_event("op", %{"kind" => "set_attr", "value" => value} = params, socket)
      when value in ["", nil] do
    handle_event("op", Map.put(params, "kind", "delete_attr"), socket)
  end

  def handle_event("op", params, socket) do
    case EditorSession.apply_op(socket.assigns.token, params) do
      {:ok, _editor} -> {:noreply, socket}
      {:error, reason} -> {:noreply, put_flash(socket, :error, human(reason))}
    end
  end

  # A SHADOW IS EDITED ONE NUMBER AT A TIME AND STORED AS ONE STRING, so every control here reads
  # the whole shadow, replaces its own part and writes it back. Six ops for six parts would be six
  # undo steps for one decision, and five of them would be shadows nobody chose.
  #
  # It ends in the same `op` funnel as every other Inspector write — one undo step, one broadcast,
  # one history entry, the same containment and plugin hooks — rather than reaching for the session
  # itself. `Shadow.put/3` is what decides the new string, including what to do with one it cannot
  # read: replace it, rather than keep half.
  def handle_event(
        "set_shadow",
        %{"node_id" => node_id, "bucket" => bucket, "field" => field} = params,
        socket
      ) do
    with part when not is_nil(part) <- shadow_part(field),
         {:ok, bucket_key} <- Styles.bucket_atom(bucket),
         %Tree.Node{} = node <- Tree.get(socket.assigns.editor.tree, node_id) do
      value =
        node.meta
        |> Map.get(:styles, %{})
        |> Map.get(bucket_key, %{})
        |> Map.get("shadow")
        |> Shadow.put(part, shadow_value(part, params["value"]))

      handle_event(
        "op",
        %{
          "kind" => "set_style",
          "node_id" => node_id,
          "bucket" => bucket,
          "prop" => "shadow",
          "value" => value || ""
        },
        socket
      )
    else
      _unknown -> {:noreply, socket}
    end
  end

  # A VALIDATION RULE IS AN ORDINARY ATTRIBUTE EDIT, so it goes down the same funnel every other
  # Inspector write does: one undo step, one broadcast, one history entry, and the same containment
  # and plugin hooks. `MishkaCmsCore.Runtime.PageBuilder.Inspector.rule_op/3` decides whether that is
  # a write or a delete — a rule turned off must not survive as `required=""`, which is still
  # required to a browser while reading back as no rule on the server.
  #
  # Its op is atom-keyed, which is also why a switch turned ON never meets the clause above: it
  # writes `value: ""` and means it.
  def handle_event("set_rule", %{"key" => key, "node_id" => node_id} = params, socket) do
    written_rule(
      socket,
      attr_rule(key, socket.assigns[:code_allowed?] == true),
      Tree.get(socket.assigns.editor.tree, node_id),
      params["value"]
    )
  end

  # ALL FIVE NAMES IN ONE BATCH. Five ops would be five undo steps, and four of them would leave the
  # form's id, param name, page assign and two event names disagreeing about what this form is.
  def handle_event("rename_form", %{"node_id" => node_id, "value" => seed}, socket) do
    renamed(socket, Tree.get(socket.assigns.editor.tree, node_id), seed)
  end

  # HOW IT WORKS: a form sends when they press Send, or works as they type with no Send button.
  def handle_event("form_how", %{"node_id" => node_id, "value" => how}, socket)
      when how in ~w(send typing) do
    how = Map.fetch!(%{"send" => :send, "typing" => :typing}, how)

    case FormPlacement.how_ops(socket.assigns.editor, node_id, how) do
      {:ok, ops, told} ->
        socket.assigns.token
        |> EditorSession.apply_ops(ops, how_label(how))
        |> set_form(socket, node_id, {:how, how})
        |> told_setting(socket, told)

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  def handle_event("form_how", _params, socket), do: {:noreply, socket}

  # MAKE IT A WORKING FORM: a kit form is wired where it stands, a raw <form> becomes a <.form>.
  def handle_event("wire_form", %{"node_id" => node_id}, socket) do
    editor = socket.assigns.editor
    events = code_events(socket)

    case Tree.get(editor.tree, node_id) do
      %Node{kind: :tag} -> FormPlacement.replace_ops(editor, node_id, events: events)
      %Node{} = node -> FormPlacement.wiring(editor.tree, node, editor.components, events: events)
      nil -> {:error, gettext("That form is no longer on the page.")}
    end
    |> wired(socket)
  end

  # SEND TO ANOTHER ADDRESS: the four attributes it needs, written or removed together.
  def handle_event("form_address", %{"node_id" => node_id, "value" => typed}, socket) do
    %{tree: tree, components: components} = socket.assigns.editor

    with %Node{} = node <- Tree.get(tree, node_id),
         {:ok, ops} <- Inspector.address_ops(tree, node, typed, components) do
      socket.assigns.token
      |> EditorSession.apply_ops(ops, gettext("Changed where a form sends"))
      |> set_form(socket, node_id, {:address, address_of(typed)})
      |> addressed(socket)
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, reason)}
      nil -> {:noreply, socket}
    end
  end

  # IN FORM: the whole field moves to the chosen form, or a new one, rebound there as one step.
  def handle_event("move_to_form", %{"node_id" => node_id, "form" => target}, socket)
      when is_binary(target) and target != "" do
    socket.assigns.token |> EditorSession.move_to_form(node_id, target) |> told_form(socket)
  end

  def handle_event("move_to_form", _params, socket), do: {:noreply, socket}

  def handle_event("merge_forms", %{"node_id" => from_id, "form" => into_id}, socket)
      when is_binary(into_id) and into_id != "" do
    socket.assigns.token |> EditorSession.merge_forms(from_id, into_id) |> told_form(socket)
  end

  def handle_event("merge_forms", _params, socket), do: {:noreply, socket}

  # RANDOM ACCESS, which is why the history keeps whole documents rather than a log of inverse ops:
  # this jumps straight to any entry in the rail. The entry itself carries only a reference now, so
  # the tree is asked for — and a step whose tree is no longer held says so instead of reverting to
  # nothing.
  # REVERT KEYS ON THE ROW, not a position. The sheet is a filtered, paginated table now, so
  # "the nth entry of the undo stack" stopped being a thing a button could mean. The snapshot on the
  # row is self-sufficient — which is why this works for a row written by a colleague, by the
  # assistant, or last week, none of which has an in-memory tree here to point at.
  # Master, or the record's own site admin — the same people who may delete anything else here.
  def handle_event("history_clear", _params, %{assigns: %{history_clearable?: true}} = socket) do
    %{record: record, editor: editor, current_user: actor} = socket.assigns
    section = Section.to_atom!(editor.section)

    case History.clear(section, record.id, actor) do
      {:ok, n} ->
        {:noreply,
         socket
         |> bump_history_revision()
         |> put_flash(
           :info,
           ngettext(
             "Cleared %{count} recorded change.",
             "Cleared %{count} recorded changes.",
             n
           )
         )}

      _error ->
        {:noreply, put_flash(socket, :error, gettext("That history could not be cleared."))}
    end
  end

  def handle_event("history_clear", _params, socket), do: {:noreply, socket}

  # OFF THE LIVEVIEW, because restoring is the slow half of this feature: the payload has to be
  # un-gzipped and the document re-parsed, measured at roughly a second per megabyte. Run here, that
  # is a second per megabyte during which the editor answers nothing at all — no typing, no
  # selection, no canvas — and the assistant's rows are allowed a document four times the size.
  #
  # The document arrives by the session's own broadcast, exactly as it does when a colleague changes
  # something, so there is nothing to assign back.
  # AND THE LAST CLICK WINS. `start_async/3` does not stop a task already running under the same
  # name — it replaces the tracking entry and lets the old one finish, so a slow restore and a fast
  # one both reach `put_tree/3` and the slower one lands second, replacing a document the editor has
  # already said it restored. Its result is discarded by then, so nothing is even shown.
  #
  # Cancelling first kills that task before it writes, which is the whole reason the write is the
  # last thing `History.revert/3` does. Re-arming under the same name then drops the dead task's exit
  # rather than reporting it as a failed restore.
  def handle_event("history_revert", %{"id" => id}, socket) do
    %{token: token, current_user: actor} = socket.assigns

    {:noreply,
     socket
     |> cancel_running_revert()
     |> assign(:history_reverting?, true)
     |> put_flash(:info, gettext("Restoring…"))
     |> MishkaGervaz.Messages.start_async(:history_revert, fn ->
       History.revert(token, id, actor)
     end)}
  end

  def handle_event("revert", %{"index" => index}, socket) do
    entry = Enum.at(socket.assigns.editor.past, to_int(index))

    with false <- is_nil(entry),
         {:ok, tree} <- EditorSession.entry_tree(socket.assigns.editor, entry),
         {:ok, editor} <-
           EditorSession.put_tree(socket.assigns.token, tree, reason: :revert) do
      {:noreply,
       socket
       |> busy_frames(gettext("Reverting to “%{label}”…", label: entry.label), editor)
       |> put_flash(:info, gettext("Reverted to \"%{label}\"", label: entry.label))}
    else
      true ->
        {:noreply, socket}

      :error ->
        {:noreply, put_flash(socket, :error, gettext("That step is no longer available."))}

      _failed ->
        {:noreply, socket}
    end
  end

  def handle_event("undo", _params, socket) do
    {:ok, _editor} = EditorSession.undo(socket.assigns.token)
    {:noreply, socket}
  end

  def handle_event("redo", _params, socket) do
    {:ok, _editor} = EditorSession.redo(socket.assigns.token)
    {:noreply, socket}
  end

  def handle_event("copy", _params, socket),
    do: {:noreply, clipboard(socket, &EditorSession.copy/2)}

  def handle_event("cut", _params, socket),
    do: {:noreply, clipboard(socket, &EditorSession.cut/2)}

  def handle_event("paste", _params, socket) do
    case EditorSession.paste(socket.assigns.token) do
      {:ok, _editor} -> {:noreply, socket}
      {:relocated, _editor, note} -> {:noreply, put_flash(socket, :info, note)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, human(reason))}
    end
  end

  # THE RIGHT-CLICK MENU, from either surface. What each entry does lives in
  # `EditorSession.context_action/3` so the canvas and the layers rail cannot answer the same word
  # differently; what is left here is the one entry that is not an edit — saving a selection for
  # reuse is a form, and the form is already in the Studio.
  #
  # Right-clicking also SELECTS. Every other builder does, and without it the menu acts on one node
  # while the inspector beside it describes another.
  # ⌘-CLICK HOLDS A SECOND ELEMENT. The ordinary selection stays exactly one — it is what the
  # inspector edits and the toolbar names — and these ride alongside it, so nothing that reads a
  # single selection had to change.
  def handle_event("mark", %{"id" => node_id}, socket) when is_binary(node_id) do
    {:ok, _editor} = EditorSession.mark(socket.assigns.token, node_id)
    {:noreply, socket}
  end

  def handle_event("clear_marks", _params, socket) do
    {:ok, _editor} = EditorSession.clear_marks(socket.assigns.token)
    {:noreply, socket}
  end

  # What is typed in the class form is the form's draft, so a reconnect finds it where it was left.
  def handle_event("class_change", %{"name" => name, "utilities" => utilities}, socket)
      when is_binary(name) and is_binary(utilities),
      do: {:noreply, assign(socket, :class_draft, %{name: name, utilities: utilities})}

  # REUSABLE CLASSES. Style once, apply to twenty, change in one place — the half the per-element
  # style panel cannot do. See `MishkaCmsCore.Runtime.PageBuilder.Classes`.
  def handle_event("save_class", %{"name" => name, "utilities" => utilities}, socket) do
    case Events.before_class_save(%{
           name: name,
           utilities: utilities,
           site_id: site_id(socket),
           actor_id: actor_id(socket)
         }) do
      :ok -> save_class(socket, name, utilities)
      {:error, message} -> {:noreply, assign(socket, :class_error, message)}
    end
  end

  def handle_event("edit_class", %{"name" => name}, socket) do
    {:noreply,
     assign(socket,
       class_draft: Enum.find(socket.assigns.classes, &(&1.name == name)),
       class_error: nil
     )}
  end

  def handle_event("delete_class", %{"name" => name}, socket) do
    case Classes.delete(socket.assigns.current_user, site_id(socket), name) do
      {:ok, classes} ->
        {:noreply, assign(socket, classes: classes, class_draft: %{}, class_error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :class_error, human(reason))}
    end
  end

  # APPENDED, never replacing. An element's own utilities are the exceptions to the shared class and
  # have to survive it — and putting the same class on twice would be noise in the markup.
  def handle_event("apply_class", %{"name" => name}, socket) do
    node = Tree.get(socket.assigns.editor.tree, socket.assigns.selection)

    case node && with_class(node, name) do
      nil ->
        {:noreply, socket}

      {kind, value} ->
        handle_event(
          "op",
          %{
            "kind" => "set_attr",
            "node_id" => node.id,
            "name" => "class",
            "value" => value,
            "value_kind" => to_string(kind)
          },
          socket
        )
    end
  end

  # THIS SITE'S DEFAULT FOR A COMPONENT. The wizard is the one screen where the choices are already
  # made, so it is where they can be kept — see `MishkaCmsCore.Runtime.PageBuilder.Presets`.
  def handle_event("save_preset", _params, socket) do
    {:noreply, store_preset(socket, socket.assigns.wizard || %{})}
  end

  def handle_event("clear_preset", _params, socket), do: {:noreply, store_preset(socket, %{})}

  # FIND AND REPLACE, over the page's words rather than its markup — see
  # `EditorSession.find_text/2` for why the two are not the same search.
  def handle_event("open_find", _params, socket),
    do: {:noreply, socket |> assign(:find_open, true) |> refresh_hits()}

  def handle_event("close_find", _params, socket),
    do: {:noreply, assign(socket, :find_open, false)}

  def handle_event("find_query", params, socket) do
    {:noreply,
     socket
     |> assign(:find, params["find"] || "")
     |> assign(:replace, params["replace"] || "")
     |> refresh_hits()}
  end

  def handle_event("replace_all", _params, socket) do
    case EditorSession.replace_text(
           socket.assigns.token,
           socket.assigns.find,
           socket.assigns.replace
         ) do
      {:ok, _editor} -> {:noreply, socket |> assign(:find, "") |> assign(:find_hits, [])}
      {:error, reason} -> {:noreply, put_flash(socket, :error, human(reason))}
    end
  end

  def handle_event("bulk", %{"action" => action}, socket) do
    case EditorSession.bulk(socket.assigns.token, action) do
      {:ok, _editor} -> {:noreply, socket}
      {:error, reason} -> {:noreply, put_flash(socket, :error, human(reason))}
    end
  end

  def handle_event("ctx", %{"action" => action, "node_id" => node_id}, socket)
      when is_binary(node_id) do
    case action in Panels.context_actions() do
      false -> {:noreply, socket}
      true -> {:noreply, run_context_action(socket, action, node_id)}
    end
  end

  def handle_event("duplicate", _params, socket), do: selection_op(socket, "duplicate")
  def handle_event("delete", _params, socket), do: selection_op(socket, "delete")

  # HIDDEN FROM VISITORS, OR SHOWN AGAIN. The Inspector's Show names its node; the keyboard and the
  # command palette act on the selection. See `MishkaCmsCore.Runtime.PageBuilder.Visibility`.
  def handle_event("toggle_visibility", %{"id" => id}, socket) when is_binary(id),
    do: {:noreply, run_context_action(socket, "visibility", id)}

  def handle_event("toggle_visibility", _params, socket) do
    case socket.assigns.selection do
      nil -> {:noreply, needs_selection(socket)}
      id -> {:noreply, run_context_action(socket, "visibility", id)}
    end
  end

  # SAVE MEANS SAVE THE DRAFT. It used to write the live page and enqueue a compile — under a button
  # called "Save draft now", with the stage chip reading Draft — so a keystroke meant for safekeeping
  # published half-built work to visitors. Publishing is the other button, and says so.
  def handle_event("save", _params, socket) do
    {:noreply, socket |> save_draft_now() |> flash_drafted()}
  end

  def handle_event("publish", _params, socket), do: {:noreply, save(socket, :published)}

  # ---- drafts ------------------------------------------------------------------------------
  # The editor edits ONE target and the top bar names it: the live document, the autosave, or a draft
  # someone named. Nothing here changes the target without being asked to.

  # Every route to the drafts list — the header chip, the stage menu, the More menu — lands on the
  # same tab of the same sheet. One place to look, however you got there.
  def handle_event("draft_sheet", _params, socket) do
    {:noreply,
     socket
     |> assign(:draft_conflict, nil)
     |> assign(history_tab: :drafts, sheet: :history)
     |> refresh_drafts()}
  end

  # Switching to Drafts has to LOAD them. Only the routes that open the sheet did, so arriving by the
  # tab showed "No drafts yet" on a page whose own resume bar was offering one — the two read the
  # same table, so the empty list could only ever be a list nobody had asked for.
  def handle_event("history_tab", %{"tab" => tab}, socket),
    do: {:noreply, show_history_tab(socket, tab_atom(tab, [:history, :drafts]))}

  def handle_event("open_draft", %{"id" => id}, socket) do
    case Enum.find(draft_list(socket), &(&1.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("That draft is no longer there."))}

      draft ->
        # `edit_draft/3` sets the stage itself, in the same write — see the note there on what two
        # calls cost on this path.
        {:ok, editor} =
          EditorSession.edit_draft(socket.assigns.token, draft, draft_template(socket, draft))

        # The tree is a DIFFERENT tree now — its nodes have their own ids, so the ids the old one was
        # expanded by mean nothing to it and the rail collapsed to a row of closed roots. Opening a
        # draft should leave you looking at its structure, the same way opening the page does.
        #
        # AND THE CHIP FOLLOWS THE TARGET. Choosing a draft is choosing where the work goes, so a
        # chip left on Publish would sit above a draft it refuses to write to — the editor would
        # say "editing “Tuesday”" and then keep nothing.
        {:noreply,
         socket
         |> assign(
           sheet: :none,
           draft: draft,
           draft_opened?: true,
           expanded: default_expanded(editor.tree)
         )
         # BOTH OFFERS ARE ANSWERED BY OPENING ONE. `resumable` is the autosave bar and
         # `inherited_draft` is the "carry on where you left off" bar; only the first was cleared
         # here, and the second was cleared by the CARRY-ON BUTTON rather than by opening. So every
         # other route in — choosing a different draft from the drafts sheet, the stage menu, the
         # header chip — left the amber bar standing, still offering a draft the author had just
         # moved past, and clicking it re-opened the one they had navigated away from.
         #
         # The question the bar asks is "which document do you want?", and opening any draft is an
         # answer to it however it was given. That belongs here, where every route passes, not on
         # one button.
         |> assign(stage: :draft, resumable: nil, inherited_draft: nil)
         |> busy_frames(
           gettext("Opening “%{label}”…", label: Drafts.display_label(draft.label)),
           editor
         )
         |> put_flash(
           :info,
           gettext("Editing draft “%{label}”. Saves go here as you work.",
             label: Drafts.display_label(draft.label)
           )
         )}
    end
  end

  # A name already in use is never silently overwritten: the author is told which one and when it was
  # last saved, and chooses. `save_as_draft` with a `draft_id` is that choice made.
  def handle_event("save_as_draft", %{"label" => label} = params, socket) do
    case {String.trim(label), params["draft_id"]} do
      {"", _id} ->
        {:noreply, put_flash(socket, :error, gettext("Give the draft a name."))}

      {name, nil} ->
        confirm_or_write(
          socket,
          name,
          Drafts.named(section(socket), socket.assigns.record, socket.assigns.current_user, name)
        )

      {name, id} ->
        {:noreply, write_draft(socket, name, id)}
    end
  end

  # A draft is the author's, so they can take a copy of it or throw it away. Forking answers "start
  # from this one without losing it", which is the whole reason someone keeps a draft they are not
  # currently editing.
  def handle_event("fork_draft", %{"id" => id}, socket) do
    case Enum.find(draft_list(socket), &(&1.id == id)) do
      nil -> {:noreply, put_flash(socket, :error, gettext("That draft is no longer there."))}
      draft -> {:noreply, fork(socket, draft)}
    end
  end

  def handle_event("delete_draft", %{"id" => id}, socket) do
    case Drafts.discard(section(socket), id, socket.assigns.current_user) do
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, human(reason))}

      _deleted ->
        {:noreply,
         socket
         |> refresh_drafts()
         |> forget_deleted(id)
         |> put_flash(:info, gettext("Draft deleted."))}
    end
  end

  # KEEP GOING. Nothing to do but stop asking — the session is already pointed at that draft, which
  # is exactly the state the banner appeared to explain.
  # CARRY ON OPENS THE DRAFT. It used to only dismiss the bar, which was honest about nothing: the
  # session had already been resumed into that draft before the bar rendered, so the button appeared
  # to do nothing because there was nothing left for it to do. Opening starts on the live page now,
  # so this is the step that actually moves.
  def handle_event("continue_draft", _params, socket) do
    case socket.assigns.inherited_draft do
      # `open_draft` clears the bar itself now, for every route that reaches it.
      %{id: id} when is_binary(id) -> handle_event("open_draft", %{"id" => id}, socket)
      _gone -> {:noreply, assign(socket, :inherited_draft, nil)}
    end
  end

  # NOTHING TO LEAVE. A draft named in the URL is an OFFER over the live page — reopening a document
  # detaches the session from whatever draft it was in, so the canvas is the live page already. The
  # full clause below re-reads the template and reloads the frames, which here is a loading overlay
  # for no movement and a flash reading "Back on the live page" about a page nobody left.
  #
  # Guarded on the OFFER rather than on the session's target, because the offer is what this button
  # is answering; the two agree on every route in, and the offer is the one that says so.
  def handle_event(
        "start_fresh",
        _params,
        %{assigns: %{inherited_draft: %{source: :chosen}}} = socket
      ),
      do: {:noreply, assign(socket, :inherited_draft, nil)}

  # START AGAIN FROM THE LIVE PAGE. The draft is LEFT ALONE — it stays in the list and can be opened
  # from there — so this is "not that one", never "throw that away"; Discard on the other bar is the
  # button that deletes, and it says so.
  #
  # Both halves are needed. Detaching without reloading would write the draft's content into a new
  # draft, which is a fork; reloading without detaching would put the live page back into the draft
  # you just said you did not want.
  #
  # The element CSS applied in this sitting is NOT thrown away with the markup, for the reason the
  # draft is not: it is still the author's, and unlike the markup it has no row to be still in. It
  # keeps showing in the box and on the canvas, and the flash says so rather than letting it look
  # like the live page's own styling.
  def handle_event("start_fresh", _params, socket) do
    %{token: token, record: record} = socket.assigns

    with {:ok, tree} <-
           Tree.parse(Section.template(section(socket), record, status: socket.assigns.status)),
         {:ok, _editor} <- EditorSession.put_tree(token, tree, reason: :restore, dirty?: false),
         {:ok, editor} <-
           EditorSession.mark_saved(token, stage: :draft, draft_id: nil, draft_label: nil) do
      {:noreply,
       socket
       |> busy_frames(gettext("Reloading the live page…"), editor)
       |> assign(:inherited_draft, nil)
       |> assign(draft: nil, draft_opened?: false)
       |> assign(:draft_label, session_draft_label())
       |> assign(:drafted_revision, nil)
       |> sync_session(token)
       |> refresh_drafts()
       |> put_flash(:info, back_on_live_page(editor))}
    else
      _unavailable ->
        {:noreply,
         socket
         |> assign(:inherited_draft, nil)
         |> put_flash(
           :error,
           gettext("Could not reload the live page — you are still in the draft.")
         )}
    end
  end

  def handle_event("resume_autosave", _params, socket) do
    case socket.assigns.resumable do
      nil -> {:noreply, assign(socket, :resumable, nil)}
      draft -> handle_event("open_draft", %{"id" => draft.id}, assign(socket, :resumable, nil))
    end
  end

  # Deleted rather than dismissed. A bar offering to restore work you have already refused, every
  # time you open the page, is one people learn to click past without reading.
  def handle_event("discard_autosave", _params, socket) do
    with %{id: id} <- socket.assigns.resumable,
         :ok <- discarded(Drafts.discard(section(socket), id, socket.assigns.current_user)) do
      {:noreply,
       socket |> assign(:resumable, nil) |> put_flash(:info, gettext("Unsaved work discarded."))}
    else
      _kept -> {:noreply, assign(socket, :resumable, nil)}
    end
  end

  # WHAT A PANEL'S FORM HOLDS WHILE IT IS BEING FILLED IN. A page that reconnects sends every form
  # with a `phx-change` back through that event and is drawn again from what the server holds, so a
  # form without one comes back empty. `typed:<form id>` keeps the values under the form's id — the
  # panel draws its inputs from `typed` (`Panels.typed_in/4`) — and a form that lets go of them
  # (`clear_typed/2`) is not drawn from them again. A bounded number of forms is kept: the ones on
  # screen are few.
  def handle_event("typed:pb-" <> rest, params, socket) when is_map(params) do
    form_id = "pb-" <> rest
    typed = socket.assigns.typed

    if map_size(typed) < @typed_forms or is_map_key(typed, form_id) do
      {:noreply, assign(socket, :typed, Map.put(typed, form_id, Map.delete(params, "_target")))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("ai_change", %{"prompt" => prompt}, socket) when is_binary(prompt),
    do: {:noreply, assign(socket, :ai_prompt, prompt)}

  # The Assistant rail is only honest if Send actually reaches a backend. The default one replies
  # that no model is configured rather than inventing an edit it never made.
  def handle_event("ai_submit", %{"prompt" => prompt}, socket) do
    case String.trim(prompt) do
      "" -> {:noreply, socket}
      text -> {:noreply, ask_assistant(socket, text)}
    end
  end

  def handle_event("shortcut", %{"key" => key}, socket), do: shortcut(key, socket)

  # The canvas has no flash of its own, so a refusal it could not show — an illegal drop, say —
  # is posted up to this document and surfaced here.
  def handle_event("flash_error", %{"message" => message}, socket),
    do: {:noreply, put_flash(socket, :error, message)}

  # Same route for the drop that was ALLOWED but not where it was aimed: a relocation the person
  # dragging cannot see happen is a bug report waiting to be filed.
  def handle_event("flash_info", %{"message" => message}, socket),
    do: {:noreply, put_flash(socket, :info, message)}

  # The canvas toolbar's "Ask AI" and "Comment" act on chrome the canvas cannot reach, so they are
  # posted up and opened here — already scoped to the selection both panels read.
  def handle_event("open_rail", %{"action" => "ask_ai"}, socket),
    do: {:noreply, assign(socket, right_tab: :assistant, right_hidden: false)}

  def handle_event("open_rail", %{"action" => "comment"}, socket),
    do: {:noreply, assign(socket, sheet: :review)}

  # A CONTROL THAT NOBODY HANDLES IS A CONTROL THAT DOES NOTHING, and this clause is what made that
  # invisible: every unmatched event returned the socket unchanged, so a button wired to a typo, or
  # to an event whose handler was later renamed, kept looking exactly like a working one.
  #
  # Loud where it can be fixed and quiet where it cannot: in dev and test this raises with the event
  # name, so the click that goes nowhere fails at the moment somebody makes it; in production it
  # stays the swallow it always was, because a broken button is not worth taking an author's page
  # down over. Same rule as everywhere else in the editor — see
  # `MishkaCmsCore.Runtime.PageBuilder.Strict`.
  def handle_event(event, _params, socket) do
    Strict.violation!("builder_live", "no handler for the #{inspect(event)} event")
    {:noreply, socket}
  end

  # CLEARING IS A CHOICE; FAILING TO BUILD ONE IS NOT. `Interactions.source/3` answers `nil` for both
  # — for an action outside its own table, which is every action an extension contributes to the
  # dropdown, and for a class-taking action whose class box is empty. Writing that `nil` deleted
  # whatever interaction the element already had, so picking a plugin's action or forgetting to type
  # a class threw away working behaviour and said "Click action removed."
  # THE TARGET NEEDS A HANDLE TOO, and it is the same handle: `Tree.ensure_scope/2` mints the node's
  # `pb-xxxxxxxx` class if it has none, which is what the action's `to:` then names. Minting it here
  # rather than asking the author for an id is the same bargain `save_hook` already makes — a person
  # choosing "open the newsletter dialog" should not have to give it a name first.
  #
  # An empty target, or one naming the element being clicked, is not a target at all: the action
  # falls back to the element's own scope, which is what every interaction written before this did.
  # WHAT THE ATTRIBUTE HOLDS, WHICH IS NOT ALWAYS A NAME. `chelekom-pagination` declares each of its
  # arrows as a map so an author can put a caption there instead of a glyph, and the control has to
  # write the map back or the component's own `Map.get(@previous_label, :type)` is a `Map.get/2` on a
  # binary. Clearing the box still removes the attribute, so the component's default comes back.
  defp icon_op(%{"shape" => "map"}, op, ""), do: Map.put(op, "value", "")

  defp icon_op(%{"shape" => "map"}, op, value) do
    op
    |> Map.put("value", ~s(%{type: :icon, value: #{inspect(value)}}))
    |> Map.put("value_kind", "expr")
  end

  defp icon_op(_params, op, value), do: Map.put(op, "value", value)

  defp item_target(%{"index" => index, "key" => key}) do
    with {number, ""} <- Integer.parse(to_string(index)),
         true <- key not in [nil, ""] do
      %{index: number, key: to_string(key)}
    else
      _not_an_item -> nil
    end
  end

  defp item_target(_params), do: nil

  defp to_index(index) do
    case Integer.parse(to_string(index)) do
      {number, ""} when number >= 0 -> number
      _other -> -1
    end
  end

  # Read the node, change the list, write it back as an expression — through the same `op` funnel as
  # every other Inspector write, so it is one undo step, one broadcast and one history entry rather
  # than a change the canvas only finds out about on its next reload.
  #
  # `:error` is an attribute bound to something outside the page — `media={@photos}` — and the only
  # right answer there is to leave it exactly as the author wrote it.
  defp write_collection(socket, node_id, name, change) do
    with %{} = editor <- socket.assigns[:editor],
         %Node{} = node <- Tree.get(editor.tree, node_id),
         {:ok, items} <- Collection.read(node, name, declared_default(socket, node, name)) do
      handle_event(
        "op",
        %{
          "kind" => "set_attr",
          "node_id" => node_id,
          "name" => name,
          "value" => items |> change.() |> Collection.write(),
          "value_kind" => "expr"
        },
        socket
      )
    else
      _unreadable -> {:noreply, socket}
    end
  end

  defp declared_default(socket, node, name) do
    with %{} = editor <- socket.assigns[:editor],
         %{} = entry <-
           Enum.find(editor.components || [], &(&1.name == Node.component_name(node))),
         %{} = attr <- Enum.find(Inspector.attrs(entry), &(Inspector.name(&1) == name)) do
      Inspector.default(attr)
    else
      _none -> []
    end
  end

  defp aimed_scope(tree, target_id, node_id)
       when is_binary(target_id) and target_id != "" and target_id != node_id do
    Tree.ensure_scope(tree, target_id)
  end

  defp aimed_scope(tree, _target_id, _node_id), do: {tree, nil}

  # WHAT THE AUTHOR TYPED, WITHOUT THIS HANDLER KNOWING THE FIELD NAMES. The panel draws the boxes an
  # action declared and names them after its own fields, so everything posted that is not part of the
  # click's context is one of those values. Naming them here would be the one place a package still
  # had to be written into core.
  defp typed(params, target, opener) do
    params
    |> Map.drop(["node_id", "action", "target", "_target", "_csrf_token"])
    |> Map.merge(%{target: target, opener: opener})
  end

  # A FORM THAT DOES NOT ASK CANNOT ANSWER. The target `<select>` is rendered only when this document
  # has something to aim at — `:if={@openable != []}` — and the browser posts nothing for a field
  # that is not on the page. Reading `params["target"]` therefore answered `nil` in exactly the two
  # cases where the author had changed nothing about the target: while the palette was still loading,
  # and after a palette fetch failed. `nil` then fell through to "aim at yourself", and pressing
  # Apply to change the ACTION quietly re-pointed a working "open the dialog" at the button itself,
  # under a flash reading "Click action set."
  #
  # An absent field means "leave it alone", which is not the same answer as an empty one — that one
  # is the author choosing "This element" — so the two are read apart here rather than merged.
  defp aimed(tree, %{"target" => chosen}, node_id), do: aimed_scope(tree, chosen, node_id)

  defp aimed(tree, _unasked, node_id), do: {tree, held_aim(tree, node_id)}

  defp held_aim(tree, node_id) do
    case Tree.get(tree, node_id) do
      %Node{} = node -> Interactions.target(Node.attr(node, "phx-click"))
      _gone -> nil
    end
  end

  # WHAT THE TARGET SAYS ABOUT BEING OPENED. `nil` aim is a click on the element itself, which is the
  # one case there is nothing to look up: the author is toggling a class on the thing they selected.
  defp opener_for(_socket, _tree, nil), do: %{}

  defp opener_for(socket, tree, aim) do
    with %Node{} = node <- Enum.find(Tree.walk(tree), &(Tree.scope(tree, &1.id) == aim)),
         name when is_binary(name) <- Node.component_name(node),
         %{} = entry <- Enum.find(socket.assigns.editor.components || [], &(&1.name == name)) do
      Map.get(entry, :opens) || %{}
    else
      _undeclared -> %{}
    end
  end

  defp write_condition(socket, node_id, source) do
    case EditorSession.update_tree(
           socket.assigns.token,
           &set_condition(&1, node_id, source),
           reason: :condition
         ) do
      {:ok, _editor} ->
        {:noreply, put_flash(socket, :info, condition_flash(source))}

      # THE NODE MAY HAVE GONE. The editor is shared over a session channel, so a panel can be drawn
      # against a node another editor has since deleted. Same swallow `save_hook` makes.
      _gone ->
        {:noreply, socket}
    end
  end

  defp set_condition(tree, node_id, nil),
    do: Tree.delete_attr(tree, node_id, Conditions.attribute())

  defp set_condition(tree, node_id, source),
    do: Tree.set_attr(tree, node_id, Conditions.attribute(), {:expr, source})

  defp condition_flash(nil), do: gettext("This element is always on the page.")
  defp condition_flash(_source), do: gettext("Condition set.")

  # THE SCOPE, THE AIM AND THE COMMAND ARE ALL READ OFF THE STORED TREE, because all three are the
  # element as it is now: see `EditorSession.update_tree/3`. A scope of `nil` is the one answer
  # `Tree.ensure_scope/2` gives for an element that is not there, and taking a click action off an
  # element deleted since the panel was drawn is nothing to write.
  defp interaction_tree(socket, tree, node_id, action, params) do
    case Tree.ensure_scope(tree, node_id) do
      {_tree, nil} ->
        :gone

      {tree, scope} ->
        {tree, target} = aimed(tree, params, node_id)
        opener = opener_for(socket, tree, target)
        source = Interactions.source(action, scope, typed(params, target, opener))

        interaction_written(tree, node_id, action, source, socket.assigns.element_css)
    end
  end

  defp interaction_written(tree, node_id, "", _source, css),
    do: {:ok, write_interaction(tree, node_id, nil, css)}

  defp interaction_written(_tree, _node_id, _action, nil, _css), do: :unwritable

  defp interaction_written(tree, node_id, _action, source, css),
    do: {:ok, write_interaction(tree, node_id, source, css)}

  defp save_interaction(socket, {:ok, _editor}, ""),
    do: {:noreply, put_flash(socket, :info, gettext("Click action removed."))}

  defp save_interaction(socket, {:ok, _editor}, _action),
    do: {:noreply, put_flash(socket, :info, gettext("Click action set."))}

  defp save_interaction(socket, :unwritable, _action) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext(
         "That action needs a class to toggle or words to say, or is one this editor cannot write. Nothing was changed."
       )
     )}
  end

  defp save_interaction(socket, _gone, _action),
    do: {:noreply, put_flash(socket, :error, gettext("That element is no longer on the page."))}

  # The rail's Fix, for every finding whose answer is a sentence rather than an edit. A Forms
  # finding reaches this only when the document has moved on under the click, or when the answer is
  # code somebody has to write.
  defp audit_ask(rule, params, socket) do
    socket =
      case params["id"] || "" do
        "" ->
          socket

        node_id ->
          then(socket, fn s ->
            {:ok, _e} = EditorSession.select(s.assigns.token, node_id)
            s
          end)
      end

    socket
    |> assign(right_tab: :assistant, right_hidden: false)
    |> ask_assistant(audit_prompt(rule))
    |> then(&{:noreply, &1})
  end

  # A run rather than one op wherever the repair is two edits that only make sense together:
  # wrapping a stray field is an insert and a delete, and undoing half of that loses the field.
  # A form the Fix makes, or makes work, is announced on `builder:form:after_create` as `:fixed`.
  defp form_fix(rule, params, socket) do
    token = socket.assigns.token

    case FormChecks.repair(socket.assigns.editor, rule, params["id"], params["fix"]) do
      {:op, op} ->
        token |> EditorSession.apply_op(op, announce: :fixed) |> fixed(socket)

      {:ops, ops} ->
        token
        |> EditorSession.apply_ops(ops, audit_label(rule, params["fix"]), announce: :fixed)
        |> set_form(socket, params["id"], fixed_setting(params["fix"]))
        |> fixed(socket)

      {:say, sentence} ->
        {:noreply, put_flash(socket, :error, sentence)}

      {:code, event, sentence} ->
        {:noreply, answer_in_code(socket, event, sentence)}

      :none ->
        audit_ask(rule, params, socket)
    end
  end

  # A code author gets the Code window on the form's handler, customized if it has none; anyone else
  # reads the sentence.
  defp answer_in_code(%{assigns: %{code_allowed?: true}} = socket, event, _sentence) do
    socket
    |> assign(source_modal: true, source_error: nil, source_tab: :events, code_fault: nil)
    |> customize(event)
  end

  defp answer_in_code(socket, _event, sentence), do: put_flash(socket, :info, sentence)

  # Adds the default code for `event` when no entry answers it, else focuses the one that does,
  # counting a handler a pending rename moves onto the form. An event no form on the page names any
  # more changes nothing.
  defp customize(socket, event) do
    followed = followed_events(socket)

    case PageForms.handler_for(socket.assigns.editor.tree, followed, event) do
      nil -> socket
      %{custom?: true} -> assign(socket, :code_focus, answering(followed, event))
      row -> customized(socket, code_events(socket), row)
    end
  end

  defp customized(socket, entries, row) do
    entry = %{
      "name" => row.event,
      "code" => LiveViewCompiler.form_handler_sample(row.kind, row.event)
    }

    Events.form_customized(%{
      node_id: row.node_id,
      event: row.event,
      kind: row.kind,
      section: section(socket),
      resource_id: socket.assigns.editor.resource_id,
      site_id: socket.assigns.editor.site_id,
      actor_id: actor_id(socket)
    })

    socket
    |> assign(:fragments, Map.put(socket.assigns.fragments, :events, entries ++ [entry]))
    |> assign(:code_focus, {:entry, length(entries)})
  end

  defp code_events(socket), do: socket.assigns |> Map.get(:fragments, %{}) |> Map.get(:events, [])

  # The Handlers tab's entries under the names a Save will store them by, in the same order.
  defp followed_events(socket),
    do:
      socket
      |> code_events()
      |> PageForms.follow(PageForms.events(socket.assigns.editor.tree), retagged(socket))

  defp answering(entries, event) do
    case Enum.find_index(entries, &PageForms.answered?([&1], event)) do
      nil -> nil
      index -> {:entry, index}
    end
  end

  # The form's entry, On submit first, or else its row in the forms list.
  defp focus_form(socket, nil), do: assign(socket, :code_focus, nil)

  defp focus_form(socket, node_id) do
    entries = followed_events(socket)

    focus =
      case Tree.get(socket.assigns.editor.tree, node_id) do
        nil ->
          nil

        form ->
          form |> form_events() |> Enum.find_value(&answering(entries, &1)) || {:form, node_id}
      end

    assign(socket, :code_focus, focus)
  end

  defp form_events(form),
    do:
      form
      |> PageForms.handlers([])
      |> Enum.sort_by(&(&1.kind != :submit))
      |> Enum.map(& &1.event)

  defp fixed({:ok, _editor}, socket), do: {:noreply, socket}
  defp fixed({:error, reason}, socket), do: {:noreply, put_flash(socket, :error, human(reason))}

  # The controls `Inspector.rule_op/3` answers for: the ones that write a single attribute. The Form
  # section's seed is deliberately not among them — it writes five names at once and takes
  # `rename_form` instead — so a control key arriving here that no rule owns writes nothing rather
  # than raising on a document somebody is editing.
  # The field bindings that name an event are written only by someone who may write their code.
  defp attr_rule(key, code_allowed?) do
    Inspector.validation_controls()
    |> Enum.concat(Inspector.form_controls())
    |> Enum.concat(Inspector.phoenix_form_controls())
    |> Enum.concat(Inspector.field_controls(nil))
    |> Enum.concat(Inspector.send_controls(nil))
    |> Enum.find(&(&1.key == key and is_binary(&1.attr)))
    |> allowed_rule(code_allowed?)
  end

  defp allowed_rule(control, true), do: control

  defp allowed_rule(control, false) do
    case control in Inspector.field_code_controls() do
      true -> nil
      false -> control
    end
  end

  defp written_rule(socket, nil, _node, _value), do: {:noreply, socket}
  defp written_rule(socket, _control, nil, _value), do: {:noreply, socket}

  defp written_rule(socket, control, node, value),
    do: handle_event("op", Inspector.rule_op(node, control, value), socket)

  # A NAME THE NODE ALREADY CARRIES IS NOT A SECOND ATTRIBUTE. Both add boxes are free text, and
  # Advanced lists only what the component does not declare, so `color="primary"` is nowhere on
  # screen while it is being typed — and an add has no value to offer that the row it lands on does
  # not already hold. That emptied a string attribute down to `color=""`, which beats the component's
  # own default, and an expression down to `:if={}`, which HEEx reads as nil: the element and
  # everything inside it stopped being rendered while the tree went on showing the node. The box on
  # an element sends a value with the name, so there it was the empty-value rule that took over and
  # the attribute was REMOVED instead. So the panel lands on the row that already holds the name
  # rather than writing over it — `Panels.attr_addable?/3` asks the same rules the list beside each
  # box is built from, and that row rings to say where the name went.
  defp attr_added(socket, %Node{} = node, name, value) do
    case Panels.attr_addable?(socket.assigns, node, name) do
      true ->
        {:noreply, written} = handle_event("op", added_attr_op(node, name, value), socket)
        {:noreply, assign(written, :focus_attr, name)}

      false ->
        {:noreply, assign(socket, :focus_attr, name)}
    end
  end

  defp attr_added(socket, _gone, _name, _value), do: {:noreply, socket}

  # Through `op` like every other write in the panel, so containment, the permission check and a
  # plugin's veto all apply and a refusal is put on screen rather than swallowed. The kind is stated
  # because an add box only ever types a literal, and an empty value is left OUT rather than sent:
  # the row has to exist before it can be typed into, and an empty `value` is the one thing that
  # funnel turns into a `delete_attr`.
  defp added_attr_op(node, name, value) do
    op = %{
      "kind" => "set_attr",
      "node_id" => node.id,
      "name" => name,
      "value_kind" => "string"
    }

    case value do
      blank when blank in [nil, ""] -> op
      typed -> Map.put(op, "value", typed)
    end
  end

  defp how_label(:typing), do: gettext("Made a form work as they type")
  defp how_label(:send), do: gettext("Gave a form its Send button")

  defp told_setting({:ok, _editor}, socket, told), do: {:noreply, put_flash(socket, :info, told)}

  defp told_setting({:error, reason}, socket, _told),
    do: {:noreply, put_flash(socket, :error, human(reason))}

  defp wired({:ok, ops}, socket) do
    socket.assigns.token
    |> EditorSession.apply_ops(ops, gettext("Made it a working form"), announce: :wired)
    |> told_setting(
      socket,
      gettext("It is a working form now. Its fields are checked and sent.")
    )
  end

  defp wired({:error, reason}, socket), do: {:noreply, put_flash(socket, :error, reason)}

  defp address_of(typed), do: typed |> String.trim() |> blank_to_nil()

  defp addressed({:ok, _editor}, socket), do: {:noreply, socket}

  defp addressed({:error, reason}, socket),
    do: {:noreply, put_flash(socket, :error, human(reason))}

  defp fixed_setting("typing"), do: {:how, :typing}
  defp fixed_setting(_fix), do: nil

  # Announces `builder:form:after_setting` once a form's setting was written.
  defp set_form({:ok, editor} = result, socket, node_id, {setting, value}) do
    Events.form_setting(%{
      node_id: node_id,
      seed: editor.tree |> Tree.get(node_id) |> seed_or_nil(),
      setting: setting,
      value: value,
      section: section(socket),
      resource_id: editor.resource_id,
      site_id: editor.site_id,
      actor_id: actor_id(socket)
    })

    result
  end

  defp set_form(result, _socket, _node_id, _setting), do: result

  defp seed_or_nil(%Node{} = node), do: PageForms.param_name(node)
  defp seed_or_nil(nil), do: nil

  defp told_form({:relocated, _editor, note}, socket),
    do: {:noreply, put_flash(socket, :info, note)}

  defp told_form({:error, reason}, socket),
    do: {:noreply, put_flash(socket, :error, human(reason))}

  defp renamed(socket, nil, _seed), do: {:noreply, socket}

  defp renamed(socket, node, seed) do
    refusal = Inspector.seed_refusal(socket.assigns.editor.tree, node, seed)

    rename_form(socket, node, seed, refusal)
  end

  # A REFUSED SEED CHANGES NOTHING AND SAYS WHY. Two forms sharing a name is two sets of params, two
  # assigns and two pairs of handlers colliding, and renumbering the author's typing behind their
  # back would answer a question they did not ask.
  defp rename_form(socket, _node, _seed, refusal) when is_binary(refusal),
    do: {:noreply, put_flash(socket, :error, refusal)}

  defp rename_form(socket, node, seed, nil) do
    events = socket.assigns |> Map.get(:fragments, %{}) |> Map.get(:events, [])
    origin = rename_origin(socket.assigns[:rename_origin], node)

    token =
      Inspector.rename_token(socket.assigns.editor.tree, node, events,
        origin: origin,
        code_allowed?: socket.assigns[:code_allowed?] == true
      )

    ops = Inspector.rename_ops(node, seed, token)

    case EditorSession.apply_ops(socket.assigns.token, ops, gettext("Renamed a form")) do
      {:ok, _editor} ->
        {:noreply,
         socket
         |> assign(:rename_origin, origin)
         |> assign(
           :retagged,
           Map.merge(retagged(socket), Inspector.retagged(origin, token, events))
         )
         |> announce_rename(node, ops)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, human(reason))}
    end
  end

  # The form as it was when this rename began, kept while the same form stays selected.
  defp rename_origin(%Node{id: id} = origin, %Node{id: id}), do: origin
  defp rename_origin(_kept, node), do: node

  defp retagged(socket), do: socket.assigns[:retagged] || %{}

  # Announces `builder:form:after_rename` when the rename changed any of the five names.
  defp announce_rename(socket, node, ops) do
    written = Map.new(ops, &{&1.name, &1.value})

    written
    |> Enum.all?(fn {name, value} -> Node.attr_text(node, name) == value end)
    |> renamed_form(socket, node, written)
  end

  defp renamed_form(true = _unchanged?, socket, _node, _written), do: socket

  defp renamed_form(false, socket, node, written) do
    Events.form_renamed(%{
      node_id: node.id,
      from: Inspector.form_seed(node),
      to: String.trim_leading(written["as"], ":"),
      token: Naming.token(written["phx-submit"]),
      change: written["phx-change"],
      submit: written["phx-submit"],
      section: section(socket),
      resource_id: socket.assigns.editor.resource_id,
      site_id: socket.assigns.editor.site_id,
      actor_id: actor_id(socket)
    })

    socket
  end

  defp audit_label("form-no-submit", "typing"), do: gettext("Made a form work as they type")
  defp audit_label(rule, _fix), do: audit_label(rule)

  defp audit_label("field-no-form"), do: gettext("Wrapped a field in a form")
  defp audit_label("field-no-key"), do: gettext("Named a field")
  defp audit_label("form-duplicate-seed"), do: gettext("Renamed a form")
  defp audit_label("form-duplicate-token"), do: gettext("Gave a form its own handlers")

  defp audit_label("form-duplicate-source"),
    do: gettext("Gave a form its own place to keep values")

  defp audit_label(rule), do: gettext("Fixed %{rule}", rule: rule)

  defp audit_prompt("img-alt"), do: gettext("Write an alt attribute describing this image.")

  defp audit_prompt("img-alt-empty"),
    do: gettext("Replace this empty alt with a real description.")

  defp audit_prompt("link-text"), do: gettext("Give this link visible text.")
  defp audit_prompt("button-text"), do: gettext("Give this button a label.")

  defp audit_prompt("heading-skip"),
    do: gettext("Fix the heading order so it does not skip a level.")

  defp audit_prompt("no-h1"), do: gettext("Make the first heading on this page an h1.")
  defp audit_prompt("no-heading"), do: gettext("Add a top-level heading to this page.")

  defp audit_prompt("nested-html"),
    do: gettext("Remove the nested <html> element from this template.")

  defp audit_prompt("field-no-form"), do: gettext("Put this field inside a form.")
  defp audit_prompt("field-no-key"), do: gettext("Give this field a name to submit under.")

  defp audit_prompt("field-name-shadow"),
    do: gettext("Let this field's binding decide the key it sends.")

  defp audit_prompt("form-no-as"), do: gettext("Give this form a name of its own.")

  defp audit_prompt("form-no-source"),
    do: gettext("Point this form at a page assign to hold what is typed.")

  defp audit_prompt("form-duplicate-seed"),
    do: gettext("Rename this form so no other form shares its name.")

  defp audit_prompt("form-duplicate-token"),
    do: gettext("Give this form event names no other form on this page shares.")

  defp audit_prompt("form-duplicate-source"),
    do: gettext("Give this form its own place to keep what is typed into it.")

  defp audit_prompt("form-in-form"), do: gettext("Take this form out of the form around it.")

  defp audit_prompt("form-no-change"),
    do: gettext("Check this form as the visitor types, not only on send.")

  defp audit_prompt("form-no-submit"), do: gettext("Add a submit button to this form.")
  defp audit_prompt("submit-no-form"), do: gettext("Put this submit button inside a form.")
  defp audit_prompt(rule), do: gettext("Fix the %{rule} issue on this page.", rule: rule)

  defp ask_assistant(socket, text) do
    scope = %{
      node_id: socket.assigns.selection,
      label: (socket.assigns.selected_node && ai_scope_label(socket.assigns.selected_node)) || nil
    }

    author = Presence.display_name(socket.assigns[:current_user])
    attachment = socket.assigns[:ai_attachment]

    message =
      text
      |> AiBackend.user_message(scope)
      |> Map.put(:author, author)
      |> Map.put(:attachment, attachment && attachment.label)

    user = socket.assigns.ai_messages ++ [message]

    # The attached source travels WITH the question, not as a note about it, so a real backend gets
    # the markup it is being asked about.
    case ask_backend(socket, text, attachment, scope) do
      {:ok, reply} ->
        socket
        |> assign(:ai_prompt, "")
        |> assign(:ai_attachment, nil)
        |> assign(:ai_messages, user ++ [applied(reply, text, socket)])

      {:error, reason} ->
        socket |> assign(:ai_messages, user) |> put_flash(:error, human(reason))
    end
  end

  # THE REPLY'S OPS ARE THE EDIT, not a report of one. They go through `apply_ops/4` — the funnel a
  # person's own drag ends in — so an assistant's change is containment-checked, plugin-visible and
  # undoable as the one step it was asked for, and the row it leaves in history is the assistant's
  # rather than the operator's. Nothing is stamped until that write lands: a revision beside an
  # unchanged document is a claim the editor cannot keep, and its Restore would write the pre-prompt
  # tree over whatever the author did between asking and pressing it.
  #
  # `prompt` is what the AUTHOR TYPED, deliberately, and not the string `ask_backend/4` handed the
  # model: the row is an audit of who asked for what, and the attached source and any `before_ask`
  # rewrite are about what the model was shown.
  defp applied(%{ops: [_ | _] = ops} = reply, prompt, socket) do
    was = stored_tree(socket)

    case EditorSession.apply_ops(socket.assigns.token, ops, changes(ops),
           author_type: :ai,
           note: reply[:plain],
           prompt: prompt,
           backend: socket.assigns[:ai_backend]
         ) do
      # A run leaving the very same tree is not an edit — the session records none, so neither does
      # the transcript.
      {:ok, %{tree: ^was}} -> reply
      {:ok, _editor} -> stamp_revision(reply, was, socket)
      {:error, reason} -> refused(reply, reason)
    end
  end

  defp applied(reply, _prompt, _socket), do: reply

  # THE STORED TREE, NOT THIS LIVEVIEW'S COPY OF IT — see `EditorSession.update_tree/3`. The rail sits
  # blocked inside `ai_submit` for the whole round trip, so every edit the canvas made while the model
  # was thinking is still in this process's mailbox: our copy is the document as it was when the
  # question was asked. Read here, "the run changed nothing" is the session's own rule rather than a
  # guess against a stale tree, and the restore point is the document as it was when the answer
  # landed. A session that has expired leaves no tree, and `apply_ops/4` below refuses for the same
  # reason.
  defp stored_tree(socket) do
    case EditorSession.fetch(socket.assigns.token) do
      {:ok, editor} -> editor.tree
      :error -> nil
    end
  end

  # A REFUSAL REPLACES THE MODEL'S SENTENCE RATHER THAN FOOTNOTING IT. The headline is the loud line
  # in the bubble; left alone it goes on claiming the edit the run just refused, with the correction
  # in grey underneath. The model's own words move down there instead, where they read as what it
  # meant to do.
  defp refused(reply, reason) do
    reply
    |> Map.put(:text, gettext("Nothing was changed. %{reason}", reason: human(reason)))
    |> Map.put(:plain, reply[:text])
  end

  # The tree captured with the revision is the one from BEFORE the prompt, which is what Restore puts
  # back; it goes through `put_tree/3`, so the rollback is itself undoable.
  defp stamp_revision(reply, was, socket) do
    revision = "r" <> Integer.to_string(length(socket.assigns.ai_messages) + 1)

    reply
    |> Map.put(:revision, revision)
    |> Map.put(:tree, was)
    |> Map.put(:revision_note, revision_note(reply))
  end

  defp revision_note(%{ops: ops}),
    do:
      gettext("%{changes} · %{time}",
        changes: changes(ops),
        time: Localized.time(DateTime.utc_now(), :Hm)
      )

  # What the run did, in the rail's note and in the history row's own title.
  defp changes(ops) do
    count = length(ops)

    ngettext("%{count} change", "%{count} changes", count)
  end

  defp ai_scope_label(%{kind: :text}), do: gettext("text")
  defp ai_scope_label(%{tag: tag}), do: tag

  # WHICH CHOOSER THIS PROPERTY HAS, asked of the same function the Inspector asks when it draws the
  # row — a second rule keyed on the attribute's name would drift from it the first time a kit called
  # something `poster` instead of `src`.
  defp offer_chooser(socket, id, prop) do
    socket = assign(socket, :focus_attr, prop)

    case chooser_for(socket, id, prop) do
      :icon ->
        socket |> assign(:icon_picker, prop) |> assign(:icon_query, "")

      :media ->
        socket
        |> assign(:media_target, %{node_id: id, name: prop})
        |> show_sheet(:assets)

      _no_chooser ->
        socket
    end
  end

  defp chooser_for(socket, id, prop) do
    with %Node{kind: :component} = node <- Tree.get(socket.assigns.editor.tree, id),
         %{} = entry <-
           Enum.find(socket.assigns.editor.components, &(&1.name == Node.component_name(node))),
         %{} = attr <- Enum.find(entry.attrs || [], &(attr_name(&1) == prop)) do
      Inspector.widget(attr, Inspector.features(entry), entry)
    else
      _unknown -> nil
    end
  end

  defp attr_name(%{name: name}), do: name
  defp attr_name(%{"name" => name}), do: name
  defp attr_name(_attr), do: nil

  defp open_inspector(socket, id, prop) do
    {:ok, _editor} = EditorSession.select(socket.assigns.token, id)

    socket
    |> assign(:left_hidden, false)
    |> assign(:left_tab, :inspector)
    |> assign(:focus_attr, prop)
  end

  # A SELECTION IS ALREADY AN ANSWER TO "WHERE". Picking with an element selected used to arm the
  # palette and then wait for a click naming the element that was already named — so putting a card
  # inside the section you were looking at took two clicks on the same thing. It places instead, by
  # the rule a click on that element would have used: inside it when it can hold this, immediately
  # after it when it cannot, and beside the other bands when what is being placed is a slice of the
  # page. `place_at/2` clears the pick, so nothing is left armed behind it.
  #
  # With nothing selected the pick still arms, because there is no answer yet — the canvas and the
  # layers tree are both waiting to give one.
  defp arm_or_place(socket, choice) do
    %{token: token, editor: editor} = socket.assigns

    cond do
      editor.picked == choice ->
        {:ok, _editor} = EditorSession.pick(token, nil)
        {:noreply, socket}

      is_binary(editor.selection) ->
        {:ok, _editor} = EditorSession.pick(token, choice)
        place_or_select(choice, editor.selection, socket)

      true ->
        {:ok, _editor} = EditorSession.pick(token, choice)
        {:noreply, socket}
    end
  end

  defp place_or_select(nil, id, socket) do
    {:ok, _editor} = EditorSession.select(socket.assigns.token, id)
    {:noreply, socket}
  end

  defp place_or_select(_picked, id, socket) do
    case EditorSession.place_at(socket.assigns.token, id) do
      {:ok, _editor} -> {:noreply, socket}
      {:relocated, _editor, note} -> {:noreply, put_flash(socket, :info, note)}
      {:error, :nothing_picked} -> {:noreply, socket}
      {:error, reason} -> {:noreply, put_flash(socket, :error, human(reason))}
    end
  end

  defp section(%{assigns: %{section: section}}), do: section

  # A fork copies the CONTENT, not the name — two drafts called the same thing is the confusion the
  # name-collision guard exists to prevent, so the copy says what it is and can be renamed.
  #
  # AND IT COPIES THE DRAFT, not the page underneath it: the draft is the source every field but the
  # open template is taken from, or the copy carries today's published layout, SEO tags, language and
  # section — and, for an error page, the published markup of every status the author is not looking
  # at. See `Drafts.save_as/8`.
  defp fork(socket, draft) do
    %{record: record, current_user: actor} = socket.assigns
    name = copy_name(section(socket), record, actor, draft.label)

    case Drafts.save_as(
           section(socket),
           record,
           draft,
           draft_template(socket, draft),
           actor,
           nil,
           name,
           socket.assigns[:status]
         ) do
      {:ok, copy} ->
        socket
        |> refresh_drafts()
        |> put_flash(:info, gettext("Copied to “%{label}”.", label: copy.label))

      :unsupported ->
        put_flash(socket, :error, gettext("This section does not keep drafts."))

      {:error, reason} ->
        put_flash(socket, :error, human(reason))
    end
  end

  # "Promo copy", then "Promo copy 2" — a name that is free, without asking, because the author asked
  # for a copy and not for a conversation about what to call it.
  defp copy_name(section, record, actor, label) do
    base = gettext("%{label} copy", label: label || gettext("Draft"))

    Enum.find_value(1..50, base, fn
      1 -> is_nil(Drafts.named(section, record, actor, base)) && base
      n -> is_nil(Drafts.named(section, record, actor, "#{base} #{n}")) && "#{base} #{n}"
    end)
  end

  # A DRAFT'S MARKUP IS READ THE SECTION'S WAY. Three of them keep a `template`; an error page's
  # draft keeps `error_pages` and the editor is looking at one status of it — the same question
  # `Section.template/3` answers for the live record, asked of the draft.
  # A DOCUMENT SWAP IS NOT A NAVIGATION, and the frame's own loading state only ever knew about one.
  # `FrameLoader` hides its spinner on the iframe's `load`, which fires exactly once; opening a
  # draft, reverting a version or dropping back to the live page replaces the whole document inside a
  # frame that never navigates, so what the author saw was the OLD page, unchanged, for as long as
  # the new one took to render. Reported as "the page stuck until it loads".
  #
  # The revision travels with the label so the overlay is settled by the canvas actually painting
  # THAT document rather than by the next patch to arrive — the editor's own re-render answers first
  # otherwise, and the spinner would blink out before anything had changed.
  defp busy_frames(socket, label, %{revision: revision}),
    do: push_event(socket, "pb:frame-busy", %{label: label, revision: revision})

  defp busy_frames(socket, _label, _editor), do: socket

  defp draft_template(socket, draft),
    do: Section.template(section(socket), draft, status: socket.assigns[:status])

  # A deleted draft cannot go on being the save target or the thing the resume bar offers.
  defp forget_deleted(%{assigns: %{editor: %{draft_id: id}}} = socket, id) do
    {:ok, _editor} =
      EditorSession.mark_saved(socket.assigns.token, draft_id: nil, draft_label: nil)

    assign(socket, :resumable, nil)
  end

  defp forget_deleted(socket, id) do
    case socket.assigns.resumable do
      %{id: ^id} -> assign(socket, :resumable, nil)
      _other -> socket
    end
  end

  defp back_on_live_page(%{staged_element_css: nil}),
    do: gettext("Back on the live page. Your draft is still in the list.")

  defp back_on_live_page(_editor),
    do:
      gettext(
        "Back on the live page. Your draft is still in the list. The element styles you applied are still held for your next publish."
      )

  defp show_history_tab(socket, :drafts),
    do: socket |> assign(history_tab: :drafts, draft_conflict: nil) |> refresh_drafts()

  defp show_history_tab(socket, tab), do: assign(socket, :history_tab, tab)

  defp draft_list(socket),
    do: Drafts.list(section(socket), socket.assigns.record, socket.assigns.current_user)

  defp confirm_or_write(socket, name, nil), do: {:noreply, write_draft(socket, name, nil)}

  defp confirm_or_write(socket, name, %{} = existing),
    do: {:noreply, assign(socket, :draft_conflict, %{label: name, draft: existing})}

  # SAVING UNDER A NEW NAME COPIES THE OPEN DRAFT, for the reason `fork/2` gives — it is the same
  # create, reached from inside the document instead of from the drafts table.
  #
  # THE OPEN DRAFT, NOT `@draft`. Autosave puts its own row there on the first change, so on the
  # live page `@draft` is a snapshot of the page taken at that keystroke — copying it filed the
  # section, layout, SEO tags and language as they were before a Configuration save the author made
  # a minute earlier, and publishing the copy put them back. With no draft opened the live record is
  # the document, and it is the source.
  defp write_draft(socket, name, draft_id) do
    %{editor: editor, record: record, current_user: actor} = socket.assigns

    section(socket)
    |> Drafts.save_as(
      record,
      opened_draft(socket),
      editor_html(editor),
      actor,
      draft_id,
      name,
      editor.status
    )
    |> case do
      {:ok, draft} ->
        {:ok, _editor} =
          EditorSession.mark_saved(editor.token,
            stage: :draft,
            draft_id: draft.id,
            draft_label: draft.label
          )

        socket
        |> assign(draft: draft, draft_conflict: nil)
        |> refresh_drafts()
        |> put_flash(:info, gettext("Saved as “%{label}”.", label: draft.label))

      :unsupported ->
        put_flash(socket, :error, gettext("This section does not keep drafts."))

      {:error, reason} ->
        put_flash(socket, :error, human(reason))
    end
  end

  defp opened_draft(%{assigns: %{draft_opened?: true, draft: draft}}), do: draft
  defp opened_draft(_live_page), do: nil

  defp editor_html(editor), do: Tree.Serializer.serialize(editor.tree)

  defp discarded({:ok, _draft}), do: :ok
  defp discarded(:ok), do: :ok
  defp discarded(_error), do: :error

  defp shortcut("undo", socket), do: handle_event("undo", %{}, socket)
  defp shortcut("redo", socket), do: handle_event("redo", %{}, socket)
  defp shortcut("save", socket), do: handle_event("save", %{}, socket)
  defp shortcut("copy", socket), do: handle_event("copy", %{}, socket)
  defp shortcut("cut", socket), do: handle_event("cut", %{}, socket)
  defp shortcut("paste", socket), do: handle_event("paste", %{}, socket)
  defp shortcut("duplicate", socket), do: handle_event("duplicate", %{}, socket)
  defp shortcut("delete", socket), do: handle_event("delete", %{}, socket)
  defp shortcut("visibility", socket), do: handle_event("toggle_visibility", %{}, socket)
  defp shortcut("command", socket), do: handle_event("toggle_command", %{}, socket)
  defp shortcut("find", socket), do: handle_event("open_find", %{}, socket)
  defp shortcut("code", socket), do: handle_event("toggle_code", %{}, socket)
  defp shortcut("preview", socket), do: handle_event("toggle_preview", %{}, socket)
  defp shortcut("fit", socket), do: {:noreply, assign(socket, :zoom, 100)}

  # ESCAPE HAS ONE OWNER, and it is this. The sheet used to bind `phx-window-keydown="close_sheet"`
  # as well, so a press arrived twice and whichever landed first cleared the state the other needed:
  # escape shut the sheet AND the folder form drawn on top of it. The binding is gone; this decides.
  #
  # Topmost first. The form is over the sheet, so the first press closes the form and the second
  # closes the sheet — which is what a reader expects and what one handler can guarantee.
  defp shortcut("escape", %{assigns: %{preview_media: media}} = socket) when not is_nil(media),
    do: {:noreply, assign(socket, :preview_media, nil)}

  defp shortcut("escape", %{assigns: %{folder_form?: true}} = socket),
    do: {:noreply, assign(socket, :folder_form?, false)}

  defp shortcut("escape", socket) do
    {:ok, _editor} = EditorSession.select(socket.assigns.token, nil)
    {:ok, _editor} = EditorSession.pick(socket.assigns.token, nil)
    {:noreply, assign(socket, command_open: false, sheet: :none)}
  end

  defp shortcut(_key, socket), do: {:noreply, socket}

  # NOTHING SELECTED IS NOT A REJECTED EDIT. Every command here is reachable with an empty selection
  # — the palette draws each one as a plain button and the shortcut table sends Backspace and ⌘D
  # from anywhere in the chrome — and handing `Op.build/1` a nil node id turned a stray keystroke
  # into "node_id is required for delete", an error about the page in words for a tampered payload.
  # The canvas toolbar has always guarded this; the chrome now answers with what to do instead.
  defp selection_op(socket, kind) do
    case socket.assigns.selection do
      nil -> {:noreply, needs_selection(socket)}
      id -> handle_event("op", %{"kind" => kind, "node_id" => id}, socket)
    end
  end

  defp clipboard(socket, fun) do
    case socket.assigns.selection do
      nil ->
        needs_selection(socket)

      id ->
        case fun.(socket.assigns.token, id) do
          {:ok, _editor} -> socket
          {:error, reason} -> put_flash(socket, :error, human(reason))
        end
    end
  end

  defp needs_selection(socket),
    do: put_flash(socket, :info, gettext("Select an element on the page first."))

  # Runtime components are placed in their wrapper form, which is what every stored template uses
  # and what the compilers emit: the name is data, and a hyphenated one could not be a tag at all.
  # `site` is written as the page's own scope rather than the example's hardcoded "Global".
  @doc """
  The palette entry the examples modal is open for, or `nil`.

  Exposed so the panel components can read it without threading another assign through every render.
  """
  def examples_entry(%{assigns: assigns}), do: examples_entry(assigns)

  def examples_entry(%{examples_for: name, editor: editor} = assigns) when is_binary(name) do
    case Enum.find(editor.components, &(&1.name == name)) do
      nil -> nil
      entry -> Map.put(entry, :examples, loaded_examples(assigns))
    end
  end

  def examples_entry(_assigns), do: nil

  # The modal is opened before its examples are curated, so an empty list here means "still coming",
  # which is what its own empty state already says.
  defp loaded_examples(%{examples: %Phoenix.LiveView.AsyncResult{ok?: true, result: examples}})
       when is_list(examples),
       do: examples

  defp loaded_examples(_assigns), do: []

  # An extension that ships a component can ship its examples too, or reorder the ones a kit provides.
  defp curated_examples(name, site_id),
    do: Events.examples(Examples.for_name(name, site_id), %{entry: name, site_id: site_id})

  # Placement follows the same rule as the palette: into the selection when it can hold children,
  # otherwise beside it, otherwise at the end of the document.
  # No selection means the whole document, which is what the button says it will do.
  # Who is asking, for the paths where an id alone is not authority: the snippet is read and deleted
  # as the signed-in user, whose site and names the snippet's policies hold it to.
  defp snippet_actor(socket), do: socket.assigns[:current_user]

  defp snippet_source(editor, nil), do: Serializer.serialize(editor.tree)

  defp snippet_source(editor, node) do
    editor.tree |> Tree.subtree(node.id) |> Serializer.serialize()
  end

  # THE SAME RULE AS THE PALETTE, because it is the same gesture. A snippet, an example and a
  # composed component all mean "put this where I am looking", and this path used to answer that by
  # always dropping the template beside the selection — so a `<section>` snippet inserted while a
  # heading inside a hero was selected landed inside that hero.
  defp place_template(socket, template) do
    case EditorSession.place_template(
           socket.assigns.token,
           template,
           socket.assigns.editor.selection
         ) do
      {:ok, _editor} -> {:noreply, socket}
      {:relocated, _editor, note} -> {:noreply, put_flash(socket, :info, note)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, human(reason))}
    end
  end

  defp save(socket, stage) do
    case missing_required(socket) ++ missing_slots(socket) do
      [] -> save_whole(socket, stage)
      missing -> refuse_save(socket, missing)
    end
  end

  # THE SAME PROMISE AS A REQUIRED PROPERTY, made by the section rather than by a component. A layout
  # renders the page it wraps through `@inner_content`; one that no longer does compiles, saves and
  # previews, and quietly empties every page on it. That is a page the author has already broken, so
  # it is refused here alongside the others rather than reported after the fact.
  #
  # Only publishing comes through this. The autosaved draft is written by `autosave/1` and is not
  # gated — an author who cut the chip to paste it somewhere else must not lose the minute of work
  # in between.
  # THE TOKENIZER IS NOT THE COMPILER, AND NEITHER IS THE SERIALIZER. The document in the editor
  # arrived through `Tree.parse/1`, which takes `{@a + }` — the braces delimit an expression and the
  # expression is a token to it. `to_heex/1` reads every expression on the way out and catches that
  # one; what neither of them reads is the HEEx itself, so `<div :foo={@a}>` — a special attribute
  # that does not exist — survives both and is refused by the engine that has to build the module.
  #
  # `Validations.PageCodeCompiles` catches all of this for a PAGE at the action boundary. A layout,
  # an error page and a component have no such validation, so for three of the four sections this is
  # the last place it can be caught before the site stops compiling — and the document does not have
  # to have been typed here to be broken: a seed, an import or a hand edit is enough.
  #
  # `CodeCheck.template/1` rather than `check/1`: this is the syntax question, it costs milliseconds
  # rather than the second a page compile does, and the semantic half belongs to the resource that
  # owns the module's shape.
  defp save_whole(socket, stage) do
    with true <- wraps_a_page?(socket),
         {:ok, heex} <- Serializer.to_heex(socket.assigns.editor.tree),
         :ok <- CodeCheck.template(heex) do
      write(socket, stage, heex)
    else
      false -> refuse_slotless_layout(socket)
      {:error, reason} -> refuse_uncompilable(socket, reason)
    end
  end

  defp refuse_uncompilable(socket, reason) do
    put_flash(
      socket,
      :error,
      gettext("Not published — this markup will not compile. %{reason}",
        reason: compile_reason(reason)
      )
    )
  end

  # A fault from `CodeCheck`, or the compiler's own sentence from the serializer — which arrives
  # naming a file called `nofile`, so the prose above it is what makes it readable.
  defp compile_reason(fault) when is_map(fault), do: CodeCheck.message(fault)
  defp compile_reason(reason) when is_binary(reason), do: reason
  defp compile_reason(reason), do: inspect(reason)

  defp wraps_a_page?(%{assigns: %{editor: editor}}),
    do:
      Section.normalize(editor.section) != "layout" or
        LayoutSlot.renders_inner_content?(editor.tree)

  defp refuse_slotless_layout(socket) do
    case LayoutSlot.holds_inner_content?(socket.assigns.editor.tree) do
      true ->
        put_flash(
          socket,
          :error,
          gettext(
            "Not published — @inner_content is inside an element hidden from visitors, so every page using this layout would come out empty. Show it first."
          )
        )

      false ->
        put_flash(
          socket,
          :error,
          gettext(
            "Not published — nothing on this layout renders @inner_content, so every page using it would come out empty."
          )
        )
    end
  end

  # A component that declares a property as required means the page will not render without it, so
  # saving one that is missing writes a page that is already broken. The fields are marked in the
  # Inspector; this is the second half of that — it says WHICH, and it does not save.
  # WHAT THE PAGE WAS TOLD IT MUST HAVE. Both of these used to be their own reading of the
  # declaration, and the layers rail had a third — which is to say it had none, and the author found
  # out at Publish. `Inspector.unmet/3` is the one answer all three now take, so the badge on a row
  # and the refusal on the button cannot disagree about which field is missing.
  #
  # A required SLOT is the same promise as a required property: the component will not render without
  # it, so a page that never filled it is not savable either. Phoenix allows exactly one option
  # inside a slot block — `:required` — and the kit uses it twelve times.
  defp missing_required(%{assigns: %{editor: editor}}) do
    components = component_lookup(editor)

    for node <- Tree.walk(editor.tree),
        {:attr, name} <- Inspector.unmet(node, editor.tree, components),
        do: "#{owner_label(node)}.#{name}"
  end

  defp missing_slots(%{assigns: %{editor: editor}}) do
    components = component_lookup(editor)

    for node <- Tree.walk(editor.tree),
        {:slot, name} <- Inspector.unmet(node, editor.tree, components),
        do: "#{Node.component_name(node)}.:#{name}"
  end

  defp component_lookup(%{components: components}) when is_list(components),
    do: Map.new(components, &{&1.name, &1})

  defp component_lookup(_editor), do: %{}

  defp owner_label(node), do: Node.component_name(node) || ":#{Node.slot_name(node)}"

  defp refuse_save(socket, missing) do
    put_flash(
      socket,
      :error,
      ngettext(
        "Not saved — %{fields} is required and empty.",
        "Not saved — %{fields} are required and empty.",
        length(missing),
        fields: Enum.join(Enum.uniq(missing), ", ")
      )
    )
  end

  defp write(socket, stage, serialized) do
    editor = socket.assigns.editor

    with heex <- Events.serialize(serialized, %{section: editor.section, stage: stage}),
         :ok <- gate(stage, editor, heex),
         {:ok, record} <- persist(socket, heex, going_live(stage)) do
      published_draft_is_spent(socket, stage, editor)
      css = prune_element_css(socket, editor, record)
      announce(stage, record, editor)

      socket
      |> collect_history(stage, editor, record)
      |> assign(:record, record)
      |> assign(:stage, next_stage(stage))
      |> assign(:applied, {stage, editor.revision})
      |> assign(:applied_stage, stage)
      |> assign(:resumable, nil)
      |> assign(:drafted_revision, nil)
      |> refresh_drafts()
      |> put_flash(
        :info,
        stage
        |> saved_message(socket.assigns.section)
        |> saved_flash(css)
        |> hidden_note(stage, editor.tree)
      )
    else
      {:error, reason} -> put_flash(socket, :error, human(reason))
    end
  end

  # A PUBLISH DROPS WEIGHT, NOT RECORD. The snapshots behind this branch go — they are 91% of what
  # history costs, and reverting into the middle of a shipped draft is not a thing anyone wants — and
  # the rows stay, because they are the record of who did what. One summary row is written in their
  # place, carrying the published document, so the page's own timeline has a revert point per publish.
  #
  # Off the LiveView, because publishing already compiles, rebuilds CSS and broadcasts; and after the
  # write rather than inside it, so cleanup can never fail a publish. `start_async` rather than a
  # bare task, like the flush beside it: a job nothing awaits is one whose failure nobody hears, and
  # one no test can assert on either — so the collect's own answer is what the job returns, not the
  # sweep's, and a refusal is reported below.
  #
  # It is linked to this LiveView and dies with it, which is why `History.collect/5` writes the
  # summary row before it sweeps anything: leaving the builder mid-cleanup costs weight, never the
  # row that says the page was published.
  #
  # `editor.draft_id` is read here rather than by the task, because `published_draft_is_spent/3` has
  # already spent the session's copy by now — what this collects is the branch the publish shipped.
  defp collect_history(socket, :published, editor, record) do
    actor = socket.assigns.current_user
    section = Section.to_atom!(editor.section)
    draft_id = editor.draft_id

    summary = %{
      site_id: editor.site_id,
      label: gettext("Published %{name}", name: record.name),
      detail: publish_detail(editor),
      note:
        gettext(
          "Published to the live page. The changes behind this are recorded but no longer restorable."
        )
    }

    MishkaGervaz.Messages.start_async(socket, :history_collect, fn ->
      with {:ok, _collected} <- History.collect(section, record.id, draft_id, summary, actor),
           do: History.sweep_orphan_snapshots()
    end)
  end

  defp collect_history(socket, _draft, _editor, _record), do: socket

  defp publish_detail(%{tree: tree}) do
    ngettext("1 element live", "%{count} elements live", length(Tree.walk(tree)))
  end

  # DELETING AN ELEMENT DELETES ITS CSS, and until this ran nothing ever noticed. A rule is keyed on
  # a class in the markup, so removing the element takes the only reference to it away — but the rule
  # stayed in the row, and kept being compiled into the site's stylesheet and served to every visitor
  # for as long as the page existed. `ElementCss.live_rules/2` was written and tested for this, and
  # asking it rather than working the same thing out again here is the point: a second answer to
  # "which rules is this tree still wearing" diverges from the first in silence, and the tests over
  # the one nobody calls stay green while the author's CSS goes.
  #
  # ON SAVE, not on delete: the tree the author is holding is not the document until they save it, and
  # pruning against a tree they might still undo would drop the CSS of an element they are about to
  # bring back.
  #
  # A failure here does not refuse the save — the page is already written — but it is reported, which
  # it was not: the worst case used to be a dead rule left behind and is now the author's brand-new
  # CSS not reaching the page a flash has just called published.
  #
  # THE ROW BELONGS TO THE RECORD, NOT TO THE STATUS. An error page keeps five templates in one
  # record and all five write into one element-CSS row, so "anything not in this tree belongs to an
  # element that is gone" — true for a page — deleted every rule the author had written on the other
  # four statuses the moment one of them was published. Their scopes are counted as live too.
  #
  # AND WHAT THE DRAFT HELD IS WRITTEN HERE TOO, which is the other half of the same sentence: a rule
  # is keyed on a class in the markup, so the save that puts the class on the live page is the save
  # that puts the rule there. `staged_element_css` is what a draft-stage Apply left in the session.
  #
  # READ NOW, NOT AT MOUNT. The row is what this compares against and what it writes, so it is asked
  # for here: the socket's copy is as old as this LiveView, and an error page's other status, a
  # second browser on this session, or the Stylesheets page can all have written it since.
  defp prune_element_css(socket, editor, record) do
    row = ElementCss.all(socket.assigns.current_user, editor.site_id, css_owner(socket))
    held = ElementCss.merge(row, editor.staged_element_css)

    live =
      [editor.tree | sibling_trees(socket, record)]
      |> Enum.map(&ElementCss.live_rules(&1, held))
      |> Enum.reduce(%{}, &Map.merge/2)

    socket |> fold_element_css(editor, row, live) |> released(socket)
  end

  defp fold_element_css(_socket, _editor, row, row), do: {:ok, row}

  defp fold_element_css(socket, editor, _row, live),
    do: ElementCss.sync(socket.assigns.current_user, editor.site_id, css_owner(socket), live)

  # The hold is released only once the row has it, so a write that failed leaves the author's CSS
  # where it was rather than nowhere — the next publish carries it again.
  defp released({:ok, _rules}, socket) do
    with {:ok, _editor} <- EditorSession.unstage_element_css(socket.assigns.token), do: :ok
  end

  defp released({:error, reason}, _socket), do: {:error, reason}

  # WHAT A PUBLISH LEFT OUT, said once, at the moment it was left out — so an element hidden weeks
  # ago and forgotten is not a mystery on the live page. See `PageBuilder.Visibility`.
  defp hidden_note(saved, :published, tree) do
    case length(Visibility.hidden_roots(tree)) do
      0 ->
        saved

      count ->
        ngettext(
          "%{saved} 1 hidden element was left out.",
          "%{saved} %{count} hidden elements were left out.",
          count,
          saved: saved
        )
    end
  end

  defp hidden_note(saved, _stage, _tree), do: saved

  defp saved_flash(saved, :ok), do: saved

  defp saved_flash(saved, {:error, _reason}),
    do:
      gettext("%{saved} The element styles were kept, not published — try publishing again.",
        saved: saved
      )

  # The statuses that are not open. Their markup is stored rather than in the session, so it is
  # parsed to ask the same question of it; a template that will not parse contributes nothing rather
  # than taking the whole prune down.
  #
  # THE RECORD THE SAVE JUST WROTE, not the one this LiveView opened with. The other statuses are
  # edited in their own tabs, and a snapshot taken before one of them was published shows markup
  # without the class its rule is keyed on — so the prune read that rule as belonging to an element
  # nobody could see and deleted it.
  defp sibling_trees(%{assigns: %{section: section}} = socket, %{} = record) do
    section
    |> Section.sibling_templates(record, status: socket.assigns[:status])
    |> Enum.flat_map(fn template ->
      case Tree.parse(template) do
        {:ok, tree} -> [tree]
        _unreadable -> []
      end
    end)
  end

  defp sibling_trees(_socket, _record), do: []

  defp next_stage(:published), do: :draft
  defp next_stage(stage), do: stage

  # WHAT THE DOCUMENT ON SCREEN IS, as against what the stage menu has selected; the two differ
  # exactly while the stage button has something to do. A write applies its stage to the revision it
  # wrote, and only to that one: an edit after a publish is new work, and new work is draft work —
  # autosaved like any other — so choosing Published again offers Publish rather than the menu.
  defp assign_applied_stage(socket, %{revision: revision}) do
    case socket.assigns[:applied] do
      {stage, ^revision} -> assign(socket, :applied_stage, stage)
      _moved_or_never_written -> assign(socket, :applied_stage, :draft)
    end
  end

  defp published_draft_is_spent(socket, :published, %{draft_id: id} = _editor)
       when is_binary(id) do
    Drafts.discard(section(socket), id, socket.assigns.current_user)
    {:ok, _editor} = EditorSession.set_stage(socket.assigns.token, :draft)

    {:ok, _editor} =
      EditorSession.mark_saved(socket.assigns.token,
        stage: :published,
        draft_id: nil,
        draft_label: nil
      )
  end

  defp published_draft_is_spent(socket, :published, _editor) do
    {:ok, _editor} = EditorSession.set_stage(socket.assigns.token, :draft)
    {:ok, _editor} = EditorSession.mark_saved(socket.assigns.token, stage: :published)
  end

  defp published_draft_is_spent(socket, stage, _editor),
    do: {:ok, _editor} = EditorSession.mark_saved(socket.assigns.token, stage: stage)

  defp gate(:published, editor, heex),
    do:
      Events.before_publish(%{
        tree: editor.tree,
        serialized: heex,
        resource_id: editor.resource_id,
        section: editor.section
      })

  defp gate(_stage, editor, heex),
    do:
      Events.before_save(%{
        tree: editor.tree,
        serialized: heex,
        resource_id: editor.resource_id,
        section: editor.section
      })

  defp announce(:published, record, editor),
    do: Events.after_publish(%{record_id: record.id, section: editor.section, stage: :published})

  defp announce(_stage, record, editor),
    do: Events.after_save(%{record_id: record.id, section: editor.section, stage: :draft})

  # ONE WRITE PATH, and recovery mode uses it too. The only thing recovery cannot supply is the
  # editing session — there is no tree, which is why it is in recovery mode — so the id and the site
  # are arguments rather than read from `@editor`. `Helpers.save_section/4` still chooses the action
  # (`:master_update` for a master, `:update` for a tenant) and still carries the actor, so there is
  # no second opinion here about which action a save uses.
  # PUBLISHED IS IN FRONT OF VISITORS — the stage menu says so. A document named in the editor arrives
  # inactive, so it is not live while it is empty; publishing is what puts it live, and without this
  # it stayed off until somebody found the switch on the list page.
  defp going_live(:published), do: %{"active" => true}
  defp going_live(_draft), do: %{}

  defp persist(socket, heex, extra) do
    %{editor: editor} = socket.assigns

    persist(socket, heex, editor.resource_id, editor.site_id, extra)
  end

  # AND THE WRITE IS NOT BUILT OUT OF `@record`. That assign is the snapshot this LiveView mounted
  # on, and an error page's save is the whole `error_pages` list with one entry replaced — so a tab
  # open on the 404 since before the 500 was published put the old 500 back, reverting a publish the
  # author had already been told was live. `Section.save_fields/3` defers that list and
  # `save_section/4` builds it from the row it reads on the way to updating it.
  defp persist(socket, heex, id, site_id, extra, opts \\ []) do
    section = socket.assigns.section
    resource = Section.resource(section)

    fields =
      section
      |> Section.save_fields(heex, status: socket.assigns[:status])
      |> Map.merge(extra)
      |> Map.merge(%{"id" => id, "site_id" => site_id})

    MishkaCmsCore.Runtime.PageBuilder.Helpers.save_section(
      resource,
      &Ash.get(resource, &1, &2),
      fields,
      socket.assigns.current_user,
      opts
    )
  end

  # THREE ANSWERS, NOT TWO. An unknown name used to fall to the same branch as the empty one, so
  # Apply took the hook that was there off — and the id minted with it, which a link or a stylesheet
  # may point at — and said "Hook attached." It reached that branch for a hook archived in another
  # tab, the picker being assigned once at mount, and for every hook a plugin contributed, back when
  # the picker and `known?/4` read different lists. Changing nothing is the only answer that cannot
  # cost the author work they can see.
  defp hook_outcome(_actor, _editor, ""), do: :detach

  defp hook_outcome(actor, editor, name) do
    case Hooks.known?(actor, editor.site_id, editor.site_name, name) do
      true -> {:attach, name}
      false -> :unavailable
    end
  end

  defp write_hook(socket, node_id, {:attach, name}),
    do: hook_written(socket, &attach_hook(&1, node_id, name), gettext("Hook attached."))

  defp write_hook(socket, node_id, :detach),
    do: hook_written(socket, &detach_hook(&1, node_id), gettext("Hook removed."))

  defp write_hook(socket, _node_id, :unavailable),
    do:
      {:noreply,
       put_flash(socket, :error, gettext("That hook is no longer available on this site."))}

  # THE NODE MAY HAVE GONE. The editor is shared over a session channel, so a panel can be drawn
  # before a co-editor's delete and pressed after it — and both helpers matched `{:ok, tree}` on a
  # write that answers `{:error, _}` for a node that is not there, which raised and took the whole
  # session down, unsaved edits and all.
  defp hook_written(socket, change, flash) do
    case EditorSession.update_tree(socket.assigns.token, change, reason: :js_hook) do
      {:ok, _editor} ->
        {:noreply, put_flash(socket, :info, flash)}

      _gone ->
        {:noreply, put_flash(socket, :error, gettext("That element is no longer on the page."))}
    end
  end

  defp attach_hook(tree, node_id, name) do
    case Tree.set_attr(tree, node_id, "phx-hook", {:string, name}) do
      {:ok, tree} -> {:ok, with_hook_id(tree, node_id)}
      _gone -> :gone
    end
  end

  defp with_hook_id(tree, node_id) do
    case Node.attr(Tree.get(tree, node_id), "id") do
      nil -> Tree.set_attr(tree, node_id, "id", {:string, hook_id(node_id)}) |> elem(1)
      _held -> tree
    end
  end

  # TAKE BACK ONLY WHAT WAS GIVEN. Detaching removes the id this module minted — recognisable by its
  # prefix — and never one the author wrote, which may be the target of a link or a stylesheet.
  defp detach_hook(tree, node_id) do
    case Tree.delete_attr(tree, node_id, "phx-hook") do
      {:ok, tree} -> {:ok, without_minted_id(tree, node_id)}
      _gone -> :gone
    end
  end

  defp without_minted_id(tree, node_id) do
    case Node.attr(Tree.get(tree, node_id), "id") do
      {:string, "el-" <> rest} when byte_size(rest) == 8 ->
        {:ok, tree} = Tree.delete_attr(tree, node_id, "id")
        tree

      _authors_own_or_none ->
        tree
    end
  end

  # The node id is already unique in the document and is what everything else points at, so hashing
  # it gives a stable, readable id rather than a counter to keep.
  defp hook_id(node_id),
    do: "el-" <> (:erlang.md5(node_id) |> Base.encode16(case: :lower) |> binary_part(0, 8))

  # THE SCOPE CLASS SERVES BOTH FEATURES, so removing the click action only takes it off when the
  # other one is not using it. `Tree.drop_scope/2` can see an interaction still naming the class,
  # because that lives in an attribute; it cannot see the CSS, which lives in a stylesheet row — so
  # the emptiness of the box is checked here, where it is known.
  # THE PROMPT, BEFORE THE MODEL SEES IT. A plugin may rewrite it — a house style, a redaction pass —
  # or refuse it outright, which is where anything about prompt handling belongs.
  defp ask_backend(socket, text, attachment, scope) do
    editor = socket.assigns.editor

    case Events.before_ask(%{
           prompt: prompt_with(text, attachment),
           scope: scope,
           backend: socket.assigns[:ai_backend],
           section: editor.section,
           resource_id: editor.resource_id,
           site_id: editor.site_id,
           actor_id: actor_id(socket)
         }) do
      {:ok, prompt} ->
        # WHICH DOCUMENT, AND WHICH SESSION. A backend that writes its own ops rather than returning
        # them needs the token `EditorSession` is addressed by; without it the `opts` the callback
        # declares was a keyword list nothing ever filled.
        AiBackend.ask(prompt, scope,
          token: editor.token,
          section: editor.section,
          resource_id: editor.resource_id,
          site_id: editor.site_id
        )

      {:error, message} ->
        {:error, message}
    end
  end

  # THE CHOICES LIVE IN TWO PLACES, because the preview is a second LiveView: the socket renders the
  # controls and the SESSION is what the iframe can read. They are written together here, always.
  # Every point that cleared one of them used to leave the other, so a variant picked for one
  # component survived the modal that made it — into the next component's wizard, and into a preview
  # still composing from choices nobody could see any more.
  defp set_wizard(socket, choices) do
    {:ok, _session} = EditorSession.put_wizard(socket.assigns.token, choices)
    assign(socket, :wizard, choices)
  end

  # A design-system plugin gets a say before a token changes: it can normalise the value — snap a
  # colour to the palette, a length to the scale — or refuse it outright.
  defp set_token(socket, editor, key, value) do
    case Tokens.put(socket.assigns.current_user, editor.site_id, "--" <> key, value) do
      {:ok, _token} ->
        # The table has nothing to subscribe to — a token lives in a stylesheet's CSS text — so the
        # write bumps the revision and the table reads again.
        {:noreply, refresh_tokens(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, token_error(reason))}
    end
  end

  # UNDER THE FIELD, AND THE DRAFT STAYS PUT. A refusal here names the utility Tailwind could not
  # resolve, which is only useful next to the box holding it — and only actionable if the box still
  # holds what was typed.
  defp save_class(socket, name, utilities) do
    case Classes.put(socket.assigns.current_user, site_id(socket), name, utilities) do
      {:ok, classes} ->
        {:noreply, assign(socket, classes: classes, class_draft: %{}, class_error: nil)}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           class_draft: %{name: name, utilities: utilities},
           class_error: human(reason)
         )}
    end
  end

  # WHAT THE CODE DRAWER IS ABOUT TO APPLY. A schema or house-style plugin refuses here, before
  # hand-written markup replaces the document.
  # THE SECOND MARKUP PANE, and it was the one that wrote without asking. The drawer's HEEx pane runs
  # `compiles/2` before it replaces anything — the whole document or one element — and this modal,
  # which replaces the whole document too, ran the tokenizer and nothing else.
  defp apply_source(socket, source) do
    with {:ok, tree} <- Tree.parse(source),
         :ok <- compiles(socket, tree) do
      EditorSession.put_tree(socket.assigns.token, tree, reason: :source_edit)
      {:noreply, assign(socket, source_modal: false, source_error: nil, source_draft: nil)}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:source_error, source_message(reason))
         |> assign(:source_draft, source)}
    end
  end

  defp code_payload(socket, source, tab, node_id) do
    editor = socket.assigns.editor

    %{
      source: source,
      tab: tab,
      node_id: node_id,
      section: editor.section,
      resource_id: editor.resource_id,
      site_id: editor.site_id,
      actor_id: actor_id(socket)
    }
  end

  # A draft is a write, so an extension gets the same say over it that it has over a save — and hears
  # about it afterwards, which is what a backup or a sync integration needs.
  defp gated_autosave(section, record, heex, actor, editor, label, who) do
    payload = %{
      section: section,
      resource_id: record.id,
      draft_id: editor.draft_id,
      label: label,
      serialized: heex,
      site_id: editor.site_id,
      actor_id: who
    }

    case Events.before_draft_save(payload) do
      :ok ->
        result =
          Drafts.autosave(section, record, heex, actor, editor.draft_id, label, editor.status)

        announce_draft(result, payload)
        result

      {:error, message} ->
        {:error, message}
    end
  end

  defp announce_draft({:ok, draft}, payload),
    do: Events.after_draft_save(%{payload | draft_id: Map.get(draft, :id, payload.draft_id)})

  defp announce_draft(_other, _payload), do: :ok

  defp actor_id(%{assigns: %{current_user: %{id: id}}}), do: id
  defp actor_id(_socket), do: nil

  defp write_interaction(tree, node_id, nil, css) do
    {:ok, tree} = Tree.delete_attr(tree, node_id, "phx-click")

    case String.trim(css || "") do
      "" -> Tree.drop_scope(tree, node_id)
      _still_styled -> tree
    end
  end

  defp write_interaction(tree, node_id, source, _css) do
    {:ok, tree} = Tree.set_attr(tree, node_id, "phx-click", {:expr, source})
    tree
  end

  defp write_element_css(socket, tree, node_id, css, flash) do
    {_scoped, scope} = Tree.ensure_scope(tree, node_id)

    case Events.before_element_css(%{
           node_id: node_id,
           css: css,
           owner: css_owner(socket),
           site_id: socket.assigns.editor.site_id,
           actor_id: actor_id(socket)
         }) do
      :ok ->
        put_element_css(socket, node_id, css, flash, scope)

      # A HANDLER RETURN, not a pair. This answered `{socket, tree}` — which LiveView refuses
      # outright — so a gate doing exactly what it exists for took the editor down with it, losing
      # every unsaved edit in the session. The sibling gate at `save_class` already answers this way.
      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp put_element_css(socket, node_id, css, flash, scope) do
    case place_element_css(socket, scope, css) do
      {:ok, rules} ->
        Events.after_element_css(%{
          node_id: node_id,
          css: css,
          owner: css_owner(socket),
          site_id: socket.assigns.editor.site_id,
          actor_id: actor_id(socket),
          # WHICH SAVE THIS WAS. `builder:save:after` and `builder:publish:after` already say so, and
          # a listener that rebuilds something from this CSS has the same question: draft-stage rules
          # are held for the publish and are not on the live page yet.
          stage: socket.assigns.stage
        })

        EditorSession.update_tree(
          socket.assigns.token,
          &scoped(&1, node_id, scope, css),
          reason: :element_css
        )

        EditorSession.set_element_css(socket.assigns.token, ElementCss.css(rules))

        {:noreply,
         socket
         |> assign(:element_css_rules, rules)
         |> assign(:element_css_error, nil)
         |> put_flash(:info, css_flash(socket.assigns.stage, flash))}

      {:error, reason} ->
        {:noreply, assign(socket, :element_css_error, human(reason))}
    end
  end

  # THE STAGE SAYS WHERE AN APPLY GOES, which is the promise the markup already makes. The row is the
  # live site — writing one recompiles the site bundle — and this had no gate at all, so a colour
  # typed under a chip reading Draft changed the page for every visitor the moment it was applied, on
  # any element already wearing a scope class. An interaction mints one too, so a first-ever Apply on
  # a page nobody had styled was enough.
  #
  # EITHER WAY THE SESSION IS TOLD, and that is not bookkeeping: the publish folds the hold over the
  # row, so an element styled in Draft and then restyled under Publish would have the older body put
  # back over the newer one by its own publish if only the draft half were recorded.
  defp place_element_css(socket, scope, css) do
    with {:ok, rules} <- staged_or_written(socket, scope, css),
         {:ok, _editor} <-
           EditorSession.stage_element_css(
             socket.assigns.token,
             scope,
             Map.get(rules, scope, "")
           ) do
      {:ok, rules}
    end
  end

  # Draft stage checks the CSS and keeps it, and `prune_element_css/3` writes it with the markup
  # carrying the class it is keyed on.
  defp staged_or_written(%{assigns: %{stage: :draft}} = socket, scope, css),
    do: ElementCss.place(socket.assigns.element_css_rules, scope, css)

  # Publish stage writes the row — pressing Apply under a chip reading Publish asks for the live page
  # — and `put/5` reads the row to write it, so the rule lands beside whatever else is in there now
  # rather than over it.
  defp staged_or_written(socket, scope, css) do
    ElementCss.put(
      socket.assigns.current_user,
      socket.assigns.editor.site_id,
      css_owner(socket),
      scope,
      css
    )
  end

  # WHERE THE STYLE WENT, IN THE SENTENCE THAT SAYS IT WAS SAVED. Both stages said "Style applied."
  # — the same words for a rule held for the next publish and one already on the live page. The
  # holding place is named too, because it is an editing session and not a row: nothing else in the
  # product keeps work there, and an author who is told only "when you publish" would read it as
  # saved.
  defp css_flash(:draft, said),
    do:
      gettext("%{said} Held in this editing session — it goes live when you publish.",
        said: said
      )

  defp css_flash(_published, said), do: said

  # THE CLASS THE RULE WAS JUST WRITTEN UNDER, put on the element as it is stored — or taken off it
  # when the box was cleared — rather than on the copy the panel was drawn from, which would put back
  # every edit stored since. An element that has gone from the stored tree, or has come to carry
  # another scope, is left alone: handing it a class no rule is written for styles nothing.
  defp scoped(tree, node_id, scope, css) do
    case {Tree.ensure_scope(tree, node_id), String.trim(css)} do
      {{tree, ^scope}, ""} -> {:ok, Tree.drop_scope(tree, node_id)}
      {{tree, ^scope}, _css} -> {:ok, tree}
      {_gone_or_rescoped, _css} -> :unscoped
    end
  end

  defp move_op(socket, node_id, bucket, prop, value) do
    EditorSession.apply_op(socket.assigns.token, %{
      "kind" => "set_style",
      "node_id" => node_id,
      "bucket" => to_string(bucket),
      "prop" => prop,
      "value" => value
    })
  end

  # THE PANEL FOLLOWS THE VALUE. A line under `&:hover` becomes a `:hover` override, and a line at
  # the top of the box becomes a `:base` one whichever device tab happens to be open — so the control
  # that now holds it can easily be one the author is not looking at. The State section is folded by
  # default and carries no count, so a hover move showed nothing at all: the line vanished, the flash
  # said it had moved, and the panel looked untouched.
  defp focus_bucket(socket, :base) do
    EditorSession.set_breakpoint(socket.assigns.token, :base)
    EditorSession.set_pseudo(socket.assigns.token, :base)
  end

  defp focus_bucket(socket, pseudo), do: EditorSession.set_pseudo(socket.assigns.token, pseudo)

  defp moved(prop),
    do:
      gettext("Moved %{property} to the controls.",
        property: elem(Styles.declaration(prop, ""), 0)
      )

  defp clear_typed(socket, form_id), do: update(socket, :typed, &Map.delete(&1, form_id))

  defp recover_template(socket, template) do
    with {:ok, _tree} <- Tree.parse(template),
         {:ok, _record} <- save_recovered(socket, template) do
      :ok
    else
      {:error, %{message: message}} -> {:error, message}
      {:error, reason} -> {:error, human(reason)}
    end
  end

  # What was typed stays in the box. Handing back the version that was already broken would throw
  # away the correction someone just spent a minute on.
  defp refused_recovery(socket, template, message) do
    socket
    |> assign(:recover, Map.put(socket.assigns.recover, :template, template))
    |> assign(:recover_error, message)
  end

  # Typed into a box, not generated from a tree: written as code, which a deployment that turned code
  # off refuses (`Validations.CodeChange`).
  defp save_recovered(%{assigns: %{record: record}} = socket, template),
    do: persist(socket, template, record.id, Map.get(record, :site_id), %{}, typed: true)

  defp recover_path(%{assigns: %{section: section, record: record, status: status}}),
    do:
      Section.builder_path(
        section,
        record.id,
        Section.editing_status(section, record, status: status)
      )

  # THE RULE FOR THE ELEMENT IN FRONT OF YOU. The rules are held whole because they are one
  # stylesheet row; the panel only ever shows the one the selection is keyed to.
  defp selected_css(socket, editor) do
    with %{} = rules <- socket.assigns[:element_css_rules],
         scope when is_binary(scope) <- Tree.scope(editor.tree, editor.selection) do
      Map.get(rules, scope, "")
    else
      _none -> ""
    end
  end

  # The document this page's element CSS is filed under. A layout and a component get their own, so
  # a page and the layout it sits in never rewrite each other's row. Named by `ElementScopes`, which
  # is where every copy flow reads the same row.
  defp css_owner(%{assigns: %{section: section, editor: editor}}),
    do: ElementScopes.owner(section, editor.resource_id)

  # ONLY A PAGE HAS THEM. `events` and `infos` are Page attributes; a Layout, a Component and an
  # error page have `helpers` and no handlers, so writing the keys on those sections would be
  # rejected by the resource rather than ignored.
  @fragment_keys [:state, :events, :infos, :helpers]

  defp code_keys(resource),
    do: Enum.filter(@fragment_keys, &(!is_nil(Ash.Resource.Info.attribute(resource, &1))))

  defp code_fragments(record) do
    Map.new(@fragment_keys, fn key -> {key, entries_of(record, key)} end)
  end

  defp entries_of(record, key) do
    record
    |> fetch(key)
    |> case do
      list when is_list(list) -> Enum.map(list, &entry_map(&1, key))
      _absent -> []
    end
  end

  defp fetch(nil, _key), do: nil
  defp fetch(record, key), do: Map.get(record, key) || Map.get(record, Atom.to_string(key))

  # String keys throughout, because the form posts strings and a map that changed shape on the way
  # to the template would need two readers.
  defp entry_map(entry, key) do
    base = %{"name" => value(entry, :name), "code" => value(entry, :code)}

    case key do
      :helpers -> Map.put(base, "args", value(entry, :args))
      _other -> base
    end
  end

  defp value(entry, key) when is_map(entry),
    do: Map.get(entry, key) || Map.get(entry, Atom.to_string(key)) || ""

  defp value(_entry, _key), do: ""

  defp blank_entry(:helpers), do: %{"name" => "", "args" => "", "code" => ""}
  defp blank_entry(_key), do: %{"name" => "", "code" => ""}

  # The form names its rows `entry[0][name]`, so they arrive as a map keyed by index-as-string and
  # have to be put back in order.
  defp submitted_entries(%{"entry" => entries}) when is_map(entries) do
    entries
    |> Enum.sort_by(fn {index, _entry} -> to_int(index) end)
    |> Enum.map(fn {_index, entry} -> entry end)
    |> Enum.reject(&blank_row?/1)
  end

  defp submitted_entries(_params), do: []

  defp blank_row?(entry) do
    ["name", "args", "code"]
    |> Enum.map(&Map.get(entry, &1, ""))
    |> Enum.all?(&(String.trim(to_string(&1)) == ""))
  end

  defp checkable(socket, fragments),
    do: checkable(socket, fragments, socket.assigns.editor.tree)

  defp checkable(_socket, fragments, tree) do
    fragments
    |> Map.new(fn {key, entries} -> {key, entries} end)
    |> Map.put(:template, page_source(tree))
  end

  # A REFUSAL THE AUTHOR CANNOT SEE IS A SAVE THAT LOOKED LIKE IT WORKED. `code_fault` is assigned
  # here and read NOWHERE — no panel renders it — so a helper that will not compile, and a write the
  # resource refused, both left the drawer looking exactly like one that had saved. The fault is
  # still recorded for whatever comes to read it; the message is now said out loud as well.
  defp held(socket, fragments, fault) do
    socket
    |> assign(:fragments, fragments)
    |> assign(:code_fault, fault)
    |> assign(:code_focus, nil)
    |> put_flash(:error, code_fault_message(fault))
  end

  # The name is what the reader is looking at when it happens, so it leads.
  defp code_fault_message(%{name: name, message: message})
       when is_binary(name) and name != "" and is_binary(message),
       do: "#{name}: #{message}"

  defp code_fault_message(%{message: message}) when is_binary(message) and message != "",
    do: message

  defp code_fault_message(_fault), do: gettext("That code could not be saved.")

  # THE DOCUMENT THAT IS OPEN, not always a page. This wrote `MishkaCmsCore.Runtime.Page` whatever the
  # editor was on, looking the record up by the id of a layout, an error page or a component — which
  # is a Page that does not exist, so the save failed for three of the four sections and the author
  # was told nothing. `Section.resource/1` is the same answer `persist/3` already asks for.
  #
  # AND ONLY THE FIELDS THAT RESOURCE HAS. A page carries `events`, `infos` and `helpers`; the other
  # three carry `helpers` alone, and an action refuses an input it does not accept — so the keys are
  # asked of the resource rather than written down a second time.
  defp declared(rows, kind, name) do
    case Enum.any?(rows, &(to_string(&1["name"]) == name)) do
      true -> rows
      false -> rows ++ [Map.put(blank_declaration(kind), "name", name)]
    end
  end

  defp blank_declaration("attr"), do: %{"name" => "", "type" => "string", "opts" => %{}}
  defp blank_declaration(_slot), do: %{"name" => "", "opts" => %{}, "attrs" => []}

  defp write_interface(socket, attrs, slots) do
    %{editor: editor} = socket.assigns
    resource = Section.resource(section(socket))

    fields = %{
      "attrs" => attrs,
      "slots" => slots,
      "id" => editor.resource_id,
      "site_id" => editor.site_id
    }

    case MishkaCmsCore.Runtime.PageBuilder.Helpers.save_section(
           resource,
           &Ash.get(resource, &1, &2),
           fields,
           socket.assigns.current_user
         ) do
      {:ok, record} ->
        socket
        |> assign(:record, record)
        |> put_flash(:info, gettext("Declared — every page using this component reads it."))

      # `Validations.InterfaceDeclaration` is what refuses a declaration that will not compile, so a
      # refusal here is the resource's sentence and is worth repeating verbatim.
      {:error, reason} ->
        put_flash(socket, :error, human(reason))
    end
  end

  # Handlers stored under a renamed form's old event names are saved under its current ones.
  defp write_code(socket, fragments) do
    section = section(socket)

    case store_code(socket, followed(fragments, socket.assigns.editor.tree, retagged(socket))) do
      {:ok, record} ->
        socket
        |> assign(:record, record)
        |> assign(:fragments, code_fragments(record))
        |> assign(:retagged, %{})
        |> assign(:code_fault, nil)
        |> assign(:code_focus, nil)
        |> put_flash(:info, gettext("Saved to the %{noun}.", noun: noun(section)))

      {:error, reason} ->
        held(socket, fragments, %{
          tab: nil,
          index: nil,
          name: nil,
          line: nil,
          message: human(reason)
        })
    end
  end

  defp store_code(socket, fragments) do
    %{editor: editor} = socket.assigns
    resource = Section.resource(section(socket))

    fields =
      resource
      |> code_keys()
      |> Map.new(fn key -> {Atom.to_string(key), Map.get(fragments, key, [])} end)
      |> Map.merge(%{"id" => editor.resource_id, "site_id" => editor.site_id})

    MishkaCmsCore.Runtime.PageBuilder.Helpers.save_section(
      resource,
      &Ash.get(resource, &1, &2),
      fields,
      socket.assigns.current_user
    )
  end

  defp followed(fragments, tree, retagged),
    do:
      Map.update(fragments, :events, [], &PageForms.follow(&1, PageForms.events(tree), retagged))

  # Leaving a form: a code author's stored handlers take its current event names (spec 0.8), and
  # the rename that began on it ends.
  defp follow_left_form(%{assigns: %{selected_node: %Node{id: id} = left}} = socket, editor)
       when editor.selection != id do
    (PageForms.form?(left) and socket.assigns[:code_allowed?] == true)
    |> left_form(socket, editor)
    |> assign(:rename_origin, nil)
  end

  defp follow_left_form(socket, _editor), do: socket

  # Read from the row, so a tab holding an older copy of the code never writes it back; a row that
  # cannot be read again writes nothing.
  defp left_form(true, %{assigns: %{record: %{id: id}}} = socket, editor),
    do:
      follow_stored(
        load_record(section(socket), id, socket.assigns[:current_user]),
        socket,
        editor.tree
      )

  defp left_form(_follow?, socket, _editor), do: socket

  defp follow_stored({:ok, row}, socket, tree) do
    stored = code_fragments(row)

    stored
    |> followed(tree, retagged(socket))
    |> store_followed(stored, socket, tree)
  end

  defp follow_stored(_unreadable, socket, _tree), do: socket

  defp store_followed(stored, stored, socket, _tree), do: socket

  # The Code window's unsaved edits in `fragments` are followed too, not replaced by the row.
  defp store_followed(fragments, _stored, socket, tree) do
    case store_code(socket, fragments) do
      {:ok, record} ->
        socket
        |> assign(:record, record)
        |> assign(:fragments, followed(socket.assigns.fragments, tree, retagged(socket)))
        |> assign(:retagged, %{})
        |> put_flash(:info, gettext("Its handlers were renamed with the form."))

      {:error, reason} ->
        put_flash(socket, :error, human(reason))
    end
  end

  defp saved_message(:published, section),
    do: gettext("%{section} published.", section: section_label(section))

  defp saved_message(_stage, section),
    do: gettext("%{section} saved.", section: section_label(section))

  # A rail's key is whatever the registry answered with, so the open tab is matched against that
  # list rather than against a fixed set — and an unknown one falls back to the first rail there is.
  defp rail_tab(%{assigns: %{rails: rails}}, tab) do
    key = to_string(tab)

    cond do
      not Enum.any?(rails, &(to_string(Descriptor.key(&1)) == key)) -> :layers
      core = Enum.find([:layers, :assistant, :audit], &(Atom.to_string(&1) == key)) -> core
      true -> key
    end
  end

  defp rail_tab(_socket, _tab), do: :layers

  defp tab_atom(value, allowed) when is_binary(value),
    do: Enum.find(allowed, hd(allowed), &(Atom.to_string(&1) == value))

  defp tab_atom(value, allowed) when is_atom(value),
    do: if(value in allowed, do: value, else: hd(allowed))

  defp token_error(:blank), do: gettext("A token needs a value.")
  defp token_error(:invalid_value), do: gettext("That is not a value a stylesheet can hold.")
  defp token_error(:too_long), do: gettext("That value is too long for a token.")
  defp token_error(:unknown_token), do: gettext("This site does not declare that token.")

  defp token_error(:forbidden),
    do: gettext("You do not have permission to change design tokens here.")

  defp token_error(%Ash.Error.Forbidden{}),
    do: gettext("You do not have permission to change design tokens here.")

  defp token_error(_other), do: gettext("The token could not be saved.")

  defp clamped(panel, value) do
    {min, max} = Panels.resize_bounds(panel)
    clamp(value, min, max)
  end

  defp clamp(value, min, max), do: value |> to_int() |> max(min) |> min(max)

  defp zoomed(kind, value) do
    {min, max} = Panels.zoom_bounds(kind)
    clamp(value, min, max)
  end

  defp set_zoom(socket, key, kind, value) do
    case zoom_value(value) do
      {:ok, zoom} -> assign(socket, key, zoomed(kind, zoom))
      :error -> socket
    end
  end

  defp zoom_value(value) when is_integer(value), do: {:ok, value}

  defp zoom_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {zoom, ""} -> {:ok, zoom}
      _other -> :error
    end
  end

  defp zoom_value(_value), do: :error

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> parsed
      :error -> 0
    end
  end

  defp to_int(_value), do: 0

  defp site_id(socket), do: socket.assigns.editor.site_id

  # THE PALETTE ARRIVES LATE. It is read asynchronously, so the first `assign_editor/2` sees no
  # components and the presets map would stay empty for the whole session — every card dragging the
  # kit's default while a click placed the site's. Keyed on the COUNT rather than the list: keeping
  # a second copy of 177 components in assigns to diff against is exactly the weight the palette
  # work went to remove, and the list only changes when one is installed or removed.
  defp assign_presets(socket, editor) do
    case socket.assigns[:presets_count] == length(editor.components) do
      true ->
        socket

      false ->
        socket
        |> assign(:presets_count, length(editor.components))
        |> assign(
          :component_presets,
          Events.preset_choices(
            Presets.for_entries(editor.components, editor.site_id),
            %{site_id: editor.site_id}
          )
        )
    end
  end

  # A card's `data-template` is what a DRAG carries, and LiveView only recomputes it when an assign
  # it reads has changed — so saving a preset has to hand the palette a new map, or dragging would
  # keep placing the old default while clicking placed the new one.
  defp refresh_presets(socket) do
    assign(
      socket,
      :component_presets,
      Presets.for_entries(socket.assigns.editor.components, socket.assigns.editor.site_id)
    )
  end

  # THE CLASSES THE ELEMENT WEARS, not the text of its class attribute: `class={@variant}` reads as
  # the literal `@variant` that way, so applying a reusable class wrote that text onto the element
  # and lost the value the component works out at render time.
  defp with_class(node, name) do
    case name in Tree.classes(node) do
      true -> nil
      false -> Tree.class_with(node, [name])
    end
  end

  defp store_preset(socket, choices) do
    entry = examples_entry(socket.assigns)
    site_id = socket.assigns.editor.site_id

    case entry && Presets.put(socket.assigns.current_user, site_id, entry.name, choices) do
      {:ok, _value} when map_size(choices) == 0 ->
        socket
        |> refresh_presets()
        |> put_flash(:info, gettext("%{name} goes back to the kit's default.", name: entry.name))

      {:ok, _value} ->
        socket
        |> refresh_presets()
        |> put_flash(
          :info,
          gettext("Every %{name} placed here will start this way.", name: entry.name)
        )

      {:error, reason} ->
        put_flash(socket, :error, human(reason))

      nil ->
        socket
    end
  end

  # Re-run against the tree as it is NOW, so a replace, an undo or a co-editor's change leaves the
  # list saying something true rather than offering nodes that have moved on.
  defp refresh_hits(socket),
    do:
      assign(
        socket,
        :find_hits,
        EditorSession.find_text(socket.assigns.editor, socket.assigns.find)
      )

  # The right-click menu SELECTS what it acts on, the way every other builder does — without it the
  # menu edits one node while the inspector beside it still describes another.
  defp run_context_action(socket, action, node_id) do
    EditorSession.select(socket.assigns.token, node_id)

    case EditorSession.context_action(socket.assigns.token, action, node_id) do
      {:open, :snippet} -> socket |> assign(:studio_tab, :snippets) |> show_sheet(:studio)
      {:ok, _editor} -> socket
      {:relocated, _editor, note} -> put_flash(socket, :info, note)
      {:error, reason} -> put_flash(socket, :error, human(reason))
    end
  end

  # Nothing to fill the row with until the socket is live, and nothing lost by waiting: the swatches
  # beside them are the editor's own and are drawn immediately.
  #
  # AND NOT AT ALL FOR AN ID THAT CANNOT NAME A SITE. `nil` is a real answer — a global document reads
  # the global sheets — but anything else that is not a uuid is a query that can only raise, and
  # spending a task on it buys a logged exception and one more thing for the editor to wait on.
  defp load_tokens_async(socket, editor) do
    case connected?(socket) and site_readable?(editor.site_id) do
      false ->
        socket

      true ->
        MishkaGervaz.Messages.start_async(socket, :style_tokens, fn ->
          colour_tokens(editor.site_id)
        end)
    end
  end

  defp site_readable?(nil), do: true
  defp site_readable?(site_id), do: match?({:ok, _uuid}, Ecto.UUID.cast(site_id))

  # Only the ones a colour control can paint with. A site declares spacing and radius tokens too, and
  # offering `--radius-lg` as a background is a swatch that draws nothing.
  @colour_token ~r/^(#|rgb|hsl|oklch|color\()/i

  defp colour_tokens(site_id) do
    site_id
    |> Tokens.list()
    |> Enum.filter(&Regex.match?(@colour_token, String.trim(&1.value)))
    |> Enum.map(&{&1.key, String.trim(&1.value), &1.label})
  end

  # Only when the frame is showing ONE device: `:frames` is the side-by-side view, where every width
  # is already on screen and switching it to one would take away what the reader opened it for.
  defp follow_breakpoint(%{assigns: %{device: :frames}} = socket, _breakpoint), do: socket
  defp follow_breakpoint(socket, breakpoint), do: assign(socket, :device, frame_for(breakpoint))

  # `:frames` is the one frame that is not a breakpoint — it is all three at once — so it moves
  # nothing, which is the same answer `follow_breakpoint/2` gives when it is showing.
  defp follow_device(socket, :frames), do: assign(socket, :device, :frames)

  # The breakpoint is not assigned here: writing it to the session is what announces it, and
  # `assign_editor/2` is the one place it reaches this socket — the same route `set_breakpoint` takes.
  defp follow_device(socket, device) do
    {:ok, _editor} = EditorSession.set_breakpoint(socket.assigns.token, breakpoint_for(device))

    assign(socket, :device, device)
  end

  # The inverse of `frame_for/1`. Desktop is the widest frame, and "every width" is what that shows.
  defp breakpoint_for(:tablet), do: :tablet
  defp breakpoint_for(:mobile), do: :mobile
  defp breakpoint_for(_desktop), do: :base

  # The frame that shows a breakpoint. `:base` is every width, and the widest frame is what that
  # looks like.
  defp frame_for(:tablet), do: :tablet
  defp frame_for(:mobile), do: :mobile
  defp frame_for(_base_or_unset), do: :desktop

  # NAMED, NOT CONVERTED. `String.to_existing_atom/1` on a field arriving from the browser is one
  # typo away from an exception in a hot path, and the set is four long.
  defp shadow_part("x"), do: :x
  defp shadow_part("y"), do: :y
  defp shadow_part("blur"), do: :blur
  defp shadow_part("spread"), do: :spread
  defp shadow_part("color"), do: :color
  defp shadow_part("inset"), do: :inset
  defp shadow_part(_other), do: nil

  # The switch sends the state it wants as its own `value`, because `phx-value-value` is overwritten
  # by `el.value` before the payload is built and would arrive empty.
  defp shadow_value(:inset, value), do: value == "true"
  defp shadow_value(_part, value), do: to_string(value)

  defp human(reason) when is_binary(reason), do: reason
  defp human(:unknown_node), do: gettext("That element is no longer on the page.")
  defp human(:unknown_session), do: gettext("This editing session expired. Reload the builder.")
  defp human(:invalid_parent), do: gettext("That element cannot hold content.")

  defp human(:nothing_to_link),
    do: gettext("That element holds nothing a link could go around.")

  defp human(:already_linked), do: gettext("That is a link already, or sits inside one.")
  defp human(:cyclic_move), do: gettext("An element cannot be moved inside itself.")

  defp human(:not_siblings),
    do: gettext("Only elements sitting side by side can be wrapped together.")

  defp human(:note_belongs_elsewhere), do: gettext("That note belongs to another site.")

  defp human(:document_root),
    do: gettext("That is the document itself — put content inside it rather than around it.")

  defp human(%{message: message}) when is_binary(message), do: message

  # ASH SAYS WHY IN ITS OWN WORDS. Without this an `Ash.Error.Invalid` reaches the reader as the
  # struct's `inspect` — a wall of changesets and stacktraces in a flash — when every one of them
  # already carries a written message.
  defp human(%Ash.Error.Invalid{} = error), do: Exception.message(error)
  defp human(%Ash.Error.Forbidden{} = error), do: Exception.message(error)

  # A FIELD-ERROR LIST IS WRITTEN WORDS ALREADY. `Op.build/1` answers with one for every op naming a
  # kind, a node id or a bucket the editor does not know — the ordinary way an assistant's op fails,
  # and now a line in a transcript an admin reads rather than a tampered payload nobody sees.
  defp human([%{message: message} | _]) when is_binary(message),
    do: gettext("That change could not be applied: %{message}.", message: message)

  # ONE REASON IS THE REASON. A list that does not lead with a written message was printed whole, so
  # an `Ash.Error` or a bare atom inside it reached the flash as `inspect` — the head gets the same
  # reading every other reason gets.
  defp human([first | _]), do: human(first)

  # A REASON WITH NO WORDS IS STILL NOT AN `inspect`. Sixteen bare atoms reach here from the op
  # funnel and the bulk bar — `:unknown_action`, `:contended`, `:empty_template` — and printing one
  # handed the author `:not_siblings` as if that were what was wrong with their page. Anything
  # worth reading gets a clause above; the rest gets the sentence `CanvasLive.message/1` has always
  # answered with.
  defp human(_other), do: gettext("That change could not be applied.")

  @doc "The device options the top bar offers, with their canvas widths."
  def devices, do: @devices

  @doc "The three frame widths the all-breakpoints view renders side by side."
  def frame_widths, do: @frame_widths

  @impl true
  def render(%{recover: %{}} = assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <Panels.recover
      fault={@recover}
      error={@recover_error}
      typed={@typed}
      section={@section}
      record={@record}
    />
    """
  end

  def render(assigns) do
    ~H"""
    <%!-- This page runs with `layout: false`, so the two things the admin shell used to provide are
          here: the flash group, and the dark-mode treatment the whole console shares (a filter
          inversion rather than a second palette — see the admin layout). --%>
    <Layouts.flash_group flash={@flash} />

    <%!-- The LTR/RTL toggle mirrors the DOCUMENT, not the editor: it rides on the session so the
          canvas inside the iframe picks it up (see `MishkaCmsCore.Runtime.PageBuilder.EditorSession.set_dir/2`).
          Flipping this chrome instead would mirror the panels and leave the page unchanged. --%>
    <%!-- `[&_button]:cursor-pointer` once here rather than on each of the two hundred buttons this
          editor draws: a `<button>` gets `cursor: default` from the user agent, so every tab, chip
          and icon in the chrome read as scenery — nothing said "you can click this". A disabled one
          says so instead. Anything that wants a different cursor (the drag grips, the palette's
          grab strip) sets its own further down the tree and wins. --%>
    <div
      id="pb-root"
      phx-hook="PbShortcuts"
      class="flex h-screen flex-col overflow-hidden bg-[#f6f5f2] font-[Manrope,ui-sans-serif,system-ui,sans-serif] text-[#1b1a18] antialiased [&_button]:cursor-pointer [&_button:disabled]:cursor-not-allowed [[data-theme=dark]_&]:[filter:invert(0.92)_hue-rotate(180deg)] [[data-theme=dark]_&]:[transition:filter_.3s_ease]"
    >
      <Panels.top_bar
        editor={@editor}
        record={@record}
        section={@section}
        back_path={@back_path}
        current_user={@current_user}
        editors={@editors}
        draft={@draft}
        drafts_enabled?={@drafts_enabled?}
        dirty?={@dirty?}
        saved_at={@saved_at}
        stage={@stage}
        applied_stage={@applied_stage}
        device={@device}
        dir={@dir}
        zoom={@zoom}
        preview?={@preview?}
        source_modal={@source_modal}
        dev_mode?={@dev_mode?}
        open_bugs={@open_bugs}
        studio_badge={@studio_badge}
        history_position={@history_position}
        history_total={@history_total}
      />
      <Panels.mobile_bar mob_panel={@mob_panel} dir={@dir} />

      <div data-role="pb-body" class="flex min-h-0 flex-1">
        <Panels.left_panel
          editor={@editor}
          section={@section}
          palette={@palette}
          component_presets={@component_presets}
          picked={@picked}
          palette_query={@palette_query}
          palette_cat={@palette_cat}
          block_query={@block_query}
          block_cat={@block_cat}
          block_library={@block_library}
          element_library={@element_library}
          left_hidden={@left_hidden}
          left_tab={@left_tab}
          left_w={@left_w}
          mob_panel={@mob_panel}
          selected_node={@selected_node}
          attr_form={@attr_form}
          typed={@typed}
          breakpoint={@breakpoint}
          pseudo={@pseudo}
          focus_attr={@focus_attr}
          group_folds={@group_folds}
          style_tokens={@style_tokens}
          icon_picker={@icon_picker}
          icon_query={@icon_query}
          icon_library={@icon_library}
          icon_variant={@icon_variant}
          element_css={@element_css}
          element_css_error={@element_css_error}
          element_css_advice={@element_css_advice}
          js_hooks={@js_hooks}
          fragments={@fragments}
          rename_origin={@rename_origin}
          retagged={@retagged}
          code_allowed?={@code_allowed?}
          record={@record}
          aim_target={@aim_target}
          act_action={@act_action}
          current_user={@current_user}
        />
        <Panels.center
          editor={@editor}
          tree={@tree}
          token={@token}
          record={@record}
          stage={@stage}
          dirty?={@dirty?}
          keeping_draft?={@keeping_draft?}
          crumbs={@crumbs}
          selection={@selection}
          selected_node={@selected_node}
          picked={@picked}
          device={@device}
          zoom={@zoom}
          frame_row={@frame_row}
          frame_zoom={@frame_zoom}
          breakpoint={@breakpoint}
          status={@status}
          statuses={@statuses}
          resumable={@resumable}
          inherited_draft={@inherited_draft}
          asset_failures={@asset_failures}
          original_changed?={
            is_binary(@editor.draft_id) and Drafts.original_changed?(@section, @record, @draft)
          }
          code_open={@code_open}
          code_tab={@code_tab}
          drawer_h={@drawer_h}
          marked={@marked}
          element_css={@element_css}
          element_css_error={@element_css_error}
          element_css_advice={@element_css_advice}
          heex_error={@heex_error}
        />
        <Panels.right_panel
          rails={@rails}
          right_tab={@right_tab}
          right_hidden={@right_hidden}
          right_w={@right_w}
          mob_panel={@mob_panel}
          editor={@editor}
          tree={@tree}
          selection={@selection}
          expanded={@expanded}
          selected_node={@selected_node}
          ai_messages={@ai_messages}
          ai_prompt={@ai_prompt}
          ai_backend={@ai_backend}
          ai_attachment={@ai_attachment}
          record={@record}
          section={@section}
          current_user={@current_user}
        />
      </div>

      <Panels.command_palette :if={@command_open} {assigns} />
      <Panels.reload_modal :if={@reload_confirm} />
      <Panels.leave_modal :if={@leave_to} />
      <Panels.source_modal
        :if={@source_modal}
        source={@source_draft || page_source(@editor.tree)}
        error={@source_error}
        label={source_label(assigns)}
        tab={@source_tab}
        fragments={@fragments}
        fault={@code_fault}
        rules={@element_css_rules}
        tree={@editor.tree}
        code_allowed?={@code_allowed?}
        section={@section}
        record={@record}
        current_user={@current_user}
        code_focus={@code_focus}
        retagged={@retagged}
      />
      <Panels.examples_modal
        :if={examples_entry(assigns)}
        entry={examples_entry(assigns)}
        token={@token}
        example_index={@example_index}
        example_device={@example_device}
        example_tab={@example_tab}
        wizard={@wizard}
        site_name={@editor.site_name}
        components={@editor.components}
        preset?={Presets.get(@editor.site_id, examples_entry(assigns).name) != %{}}
      />
      <%!-- ONE menu for both surfaces. The layers rail right-clicks into it directly; the canvas is a
            frame with none of this stylesheet, so it forwards its right-clicks here rather than
            drawing a second, inline-styled copy that would drift. --%>
      <Panels.find_modal :if={@find_open} find={@find} replace={@replace} hits={@find_hits} />
      <Panels.context_menu id="pb-ctx" target="[data-layer-row]" key="layerRow" />
      <Panels.sheet :if={@sheet not in [:none, :examples]} {assigns} />
      <Panels.new_document
        :if={@new_document? and is_nil(@record)}
        section={@section}
        current_user={@current_user}
        hidden_fields={hidden_fields(Section.resource(@section))}
      />
      <Panels.settings_modal
        :if={@settings_open? and not is_nil(@record)}
        section={@section}
        record={@record}
        draft={settings_draft(@stage, @draft)}
        current_user={@current_user}
        tab={@settings_tab}
        seo_form?={@seo_form?}
        hidden?={@sheet != :none}
      />
    </div>
    """
  end

  # WHAT A SAVE WOULD WRITE. `to_heex/1` serialises, proves the result re-parses, then formats — so
  # the string on screen is the string in the column. When formatting fails the raw serialisation is
  # shown anyway: a page whose source you cannot see is worse than an ugly one.
  defp page_source(tree) do
    case Serializer.to_heex(tree) do
      {:ok, heex} -> heex
      {:error, _reason} -> Serializer.serialize(tree)
    end
  end

  # What the window is showing the source OF — the record's own name, or the section when there is
  # no record yet.
  defp source_label(%{editor: %{section: section}, record: nil}), do: section_label(section)
  defp source_label(%{record: %{name: name}}) when is_binary(name), do: name
  defp source_label(%{editor: %{section: section}}), do: section_label(section)

  defp source_message(reason) when is_binary(reason), do: reason

  # THE DIAGNOSTIC, NOT ITS `inspect`. Both the tokenizer and `CodeCheck` answer a map carrying a
  # line, a column and the compiler's own words, and printing the map put `%{line: 1, message: "…"}`
  # and a pile of escaped newlines in a one-line box. What is worth reading is the first line of the
  # message and where it happened; the rest of what the compiler prints is a caret diagram of the
  # line the reader can already see, in the editor, directly above.
  defp source_message(%{message: message} = reason) when is_binary(message) do
    message
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.replace(~r/^nofile:\d+:\d+:\s*/, "")
    |> String.trim()
    |> at(placed(reason), Map.get(reason, :column))
  end

  defp source_message(reason),
    do: gettext("That is not markup this editor can read: %{reason}", reason: inspect(reason))

  # A `:page` fault comes from compiling the whole assembled module, so its line counts lines of a
  # file nobody wrote — "Line 3" against a one-line box sends the reader looking for a line 3.
  # `CodeCheck` marks those, and the honest thing is to give the sentence without a place.
  defp placed(%{tab: :page}), do: nil
  defp placed(reason), do: Map.get(reason, :line)

  defp at(message, line, column) when is_integer(line) and is_integer(column),
    do:
      gettext("Line %{line}, column %{column}: %{message}",
        line: line,
        column: column,
        message: message
      )

  defp at(message, line, _column) when is_integer(line),
    do: gettext("Line %{line}: %{message}", line: line, message: message)

  defp at(message, _line, _column), do: message

  # SUBMITTING WHAT IS ALREADY THERE IS NOT AN EDIT, and the check belongs here rather than after the
  # fact: the apply is a delete-and-insert, so a no-op still mints a fresh id for the node, moves the
  # reader's selection onto it and spends a compile — all to arrive back where it started.
  defp apply_document_heex(%{assigns: %{editor: %{tree: tree}}} = socket, source) do
    case page_source(tree) == source do
      true -> {:noreply, assign(socket, :heex_error, nil)}
      false -> write_document_heex(socket, source)
    end
  end

  defp write_document_heex(socket, source) do
    with {:ok, tree} <- Tree.parse(source),
         :ok <- compiles(socket, tree) do
      EditorSession.put_tree(socket.assigns.token, tree, reason: :source_edit)
      {:noreply, assign(socket, :heex_error, nil)}
    else
      {:error, reason} -> {:noreply, assign(socket, :heex_error, source_message(reason))}
    end
  end

  # THE TEXT IS NOT TOUCHED WHEN THIS REFUSES. The pane is `phx-update="ignore"`, so a failed apply
  # re-renders the error line beneath markup that is still exactly as it was typed — which is the
  # only useful state to be in while fixing a typo.
  defp apply_node_heex(socket, node_id, source) do
    tree = socket.assigns.editor.tree

    with %Node{} = node <- Tree.get(tree, node_id),
         false <- Serializer.serialize_node(tree, node_id) == source,
         {:ok, _editor} <- rewrite(socket, tree, node, source) do
      {:noreply, assign(socket, :heex_error, nil)}
    else
      # Unchanged. Nothing to report and nothing to do.
      true ->
        {:noreply, assign(socket, :heex_error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :heex_error, source_message(reason))}

      nil ->
        {:noreply, assign(socket, :heex_error, gettext("That element is no longer on the page."))}
    end
  end

  # WORDS ARE EDITED AS WORDS. A text node's parent is often a component that declares no slot — a
  # `<.link>` wrapping the word "Home" is the everyday case — and containment is right to refuse a
  # child there. But changing "Home" to "Start" is not adding a child, and answering it with
  # "A `<.link>` does not declare a slot to put content in." was both true and useless: the reader
  # had retyped one word.
  #
  # So a text node whose box still holds text is `set_text`, the op that exists for exactly this.
  # A text node whose box now holds an ELEMENT still goes the long way round and still gets that
  # message — because then it really is what the message says.
  defp rewrite(socket, tree, %Node{kind: :text} = node, source) do
    case text_only(source) do
      {:ok, text} -> set_text(socket, node, text)
      :element -> replace(socket, tree, node, source)
    end
  end

  defp rewrite(socket, tree, %Node{} = node, source), do: replace(socket, tree, node, source)

  defp text_only(source) do
    with {:ok, %Tree{roots: [id]} = parsed} <- Tree.parse(source),
         %Node{kind: :text, text: text} <- Tree.get(parsed, id) do
      {:ok, text || ""}
    else
      _element -> :element
    end
  end

  defp set_text(socket, %Node{} = node, text) do
    EditorSession.apply_op(
      socket.assigns.token,
      %{kind: :set_text, node_id: node.id, text: text}
    )
  end

  defp replace(socket, tree, %Node{} = node, source) do
    with index when is_integer(index) <- Tree.index_of(tree, node.id),
         {:ok, proposed} <- splice(tree, node, index, source),
         :ok <- compiles(socket, proposed) do
      replace_node(socket, node, index, source)
    end
  end

  # THE PAGE AS IT WOULD BE, built in memory and thrown away. Checking the fragment on its own would
  # miss what the fragment does to the document around it, and checking after the write would mean
  # undoing a change the reader already saw land.
  defp splice(tree, %Node{} = node, index, source) do
    with {:ok, without} <- Tree.delete(tree, node.id),
         {:ok, subtree} <- Tree.parse(source) do
      Tree.insert(without, Tree.refresh_ids(subtree), node.parent_id || :root, index)
    end
  end

  # THE REAL COMPILER, not the tokenizer. `Tree.parse` answers "is this markup" — it is the HTML
  # tokenizer, and it is happy with `{@user.name` and with a component attribute that no component
  # takes. Both of those compile to a page that 500s on the first visitor, and `CodeCheck` is what
  # already runs `LiveViewCompiler`'s own stages to find out. The Code window's Save has asked this
  # question since it was built; the markup panes were the two that wrote without asking.
  #
  # It costs a real compile, which is why it is on Apply and not on a debounce — see `save_code`.
  # WHAT THE MARKUP PANE IS ANSWERABLE FOR, and nothing else. `CodeCheck.check/1` reports faults in
  # the page's handlers before it ever reaches the template, so one broken handler refused every
  # markup edit on the page — and refused it by saying "This handler has no code", which is a true
  # sentence about something the reader cannot see from the box they are typing in.
  #
  # So a fault belonging to an Elixir tab is not this pane's to report: the Code window owns those
  # and shows them beside the snippet. It is dropped and the template checked again without those
  # fragments, which still catches the case that matters here — markup calling a helper that is not
  # there — against the helpers that actually compile.
  @code_tabs [:state, :events, :infos, :helpers]

  defp compiles(socket, tree) do
    case CodeCheck.check(checkable(socket, socket.assigns.fragments, tree)) do
      :ok -> :ok
      {:error, [%{tab: tab} | _rest]} when tab in @code_tabs -> without_code(socket, tree)
      {:error, [fault | _rest]} -> {:error, fault}
    end
  end

  defp without_code(socket, tree) do
    case CodeCheck.check(checkable(socket, %{}, tree)) do
      :ok -> :ok
      {:error, [fault | _rest]} -> {:error, fault}
    end
  end

  defp replace_node(socket, %Node{} = node, index, source) do
    EditorSession.apply_ops(
      socket.assigns.token,
      [
        %{kind: :delete, node_id: node.id},
        %{kind: :insert, template: source, parent_id: node.parent_id, index: index}
      ],
      gettext("Rewrote %{label}", label: Node.label(node))
    )
  end

  # Reads the chosen file and writes its path into the attribute the sheet was opened for. A record
  # that has vanished between the click and the read is a no-op rather than a crash: the gallery is
  # a live list and a file can be archived from another tab.
  # WHAT THE FIELD CAN ACTUALLY SHOW. The sheet listed every file in the library whatever was asking,
  # so pressing Use on the first card put `/uploads/documents/10.docx` into an `<img src>` — accepted
  # without complaint, and drawn as a broken picture on the page. A picker that can hand a field
  # something it cannot render is a picker with a wrong door in it.
  #
  # Images unless the element is one that plays: `<video>`, `<audio>`, `<source>` and `<track>` take
  # files this rule would otherwise hide. `poster` is the exception inside that exception — it is the
  # still frame, so it is an image even on a video.
  @plays ~w(video audio source track)

  defp accepts(socket, node_id, name) do
    tag = socket.assigns.editor.tree |> Tree.get(node_id) |> node_tag()

    cond do
      name == "poster" -> :images
      tag in @plays -> :any
      true -> :images
    end
  end

  defp node_tag(%Node{tag: tag}) when is_binary(tag), do: tag
  defp node_tag(_missing), do: nil

  # The same question `accepts/3` answered when the pick started, asked of the file that just landed.
  defp usable?(%{accepts: :images}, %{type: type}), do: type == :images
  defp usable?(_target, _media), do: true

  defp not_a_picture(%{type: :documents, name: name}),
    do:
      gettext(
        "“%{name}” is a document, and this field takes a picture. It is saved in the library.",
        name: name
      )

  defp not_a_picture(%{type: :videos, name: name}),
    do:
      gettext(
        "“%{name}” is a video, and this field takes a picture. It is saved in the library.",
        name: name
      )

  defp not_a_picture(%{name: name}),
    do:
      gettext(
        "“%{name}” is not a picture, and this field takes a picture. It is saved in the library.",
        name: name
      )

  defp place_media(%{assigns: %{media_target: nil}} = socket, _id), do: socket

  # The SEO tab's share image. Its draft is the SEO form's, so the address goes into the field it
  # types into, and the field's own change writes it — see the `PbSeoFields` hook.
  defp place_media(%{assigns: %{media_target: %{seo: :image}}} = socket, id) do
    case read_media(socket, id) do
      nil ->
        put_flash(socket, :error, gettext("That file is no longer in the library."))

      media ->
        socket
        |> push_event("pb-seo-set", %{id: "pb-seo-image", value: media_href(media.relative_path)})
        |> assign(media_target: nil, sheet: :none)
    end
  end

  # A BACKGROUND IS A STYLE, NOT AN ATTRIBUTE, so it goes down the style funnel and lands in whichever
  # bucket the panel was writing to — a picture on mobile only is the same one edit as a colour on
  # mobile only.
  #
  # `center/cover no-repeat` comes with it because a background image without them is almost never
  # what anybody meant: it tiles from the top left at its own size, which reads as a broken picture
  # rather than as a default. All three are ordinary CSS in the same declaration, so the author can
  # edit or delete them in the field underneath.
  defp place_media(
         %{assigns: %{media_target: %{node_id: node_id, bucket: bucket, prop: prop}}} = socket,
         id
       ) do
    case read_media(socket, id) do
      nil ->
        put_flash(socket, :error, gettext("That file is no longer in the library."))

      media ->
        EditorSession.apply_op(socket.assigns.token, %{
          kind: :set_style,
          node_id: node_id,
          bucket: bucket,
          prop: prop,
          value: "url(#{media_href(media.relative_path)}) center/cover no-repeat"
        })

        socket |> assign(:media_target, nil) |> assign(:sheet, :none)
    end
  end

  # ONE PICTURE OUT OF A LIST. A filterable gallery's photographs are items in an attribute rather
  # than attributes of their own, so the library was reachable for the collection and not for any
  # picture in it. The target says which item and which of its keys; everything else is the same
  # write the whole-attribute case makes.
  defp place_media(
         %{assigns: %{media_target: %{node_id: node_id, name: name, item: %{} = item}}} = socket,
         id
       ) do
    case read_media(socket, id) do
      nil ->
        put_flash(socket, :error, gettext("That file is no longer in the library."))

      media ->
        href = media_href(media.relative_path)

        {:noreply, socket} =
          write_collection(
            socket,
            node_id,
            name,
            &Collection.put_in_item(&1, item.index, item.key, href)
          )

        socket |> assign(:media_target, nil) |> assign(:sheet, :none)
    end
  end

  defp place_media(%{assigns: %{media_target: %{node_id: node_id, name: name}}} = socket, id) do
    case read_media(socket, id) do
      nil ->
        put_flash(socket, :error, gettext("That file is no longer in the library."))

      media ->
        EditorSession.apply_op(socket.assigns.token, %{
          kind: :set_attr,
          node_id: node_id,
          name: name,
          value: media_href(media.relative_path)
        })

        socket |> assign(:media_target, nil) |> assign(:sheet, :none)
    end
  end

  defp read_media(socket, id) do
    actor = socket.assigns[:current_user]
    {action, tenant} = media_scope(actor, socket.assigns.editor.site_id)

    MishkaCmsCore.Runtime.Media
    |> Ash.Query.for_read(action, %{}, actor: actor, tenant: tenant)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one()
    |> case do
      {:ok, media} -> media
      _missing -> nil
    end
  end

  # `relative_path` is already the browser-facing URL; the leading slash is the one thing that can be
  # missing from a hand-seeded row.
  defp media_href("/" <> _rest = path), do: path
  defp media_href("http://" <> _rest = url), do: url
  defp media_href("https://" <> _rest = url), do: url
  defp media_href(path) when is_binary(path), do: "/" <> path
  defp media_href(_path), do: ""

  # ONE PATH FOR EVERY WRITE TO A NOTE, so the badge is refreshed by construction rather than by
  # each caller remembering to. A note that has gone — deleted from another tab, or by someone else
  # — is a message, not a crash.
  defp update_comment(socket, id, action, done) do
    scope = Panels.review_scope(socket.assigns)

    case Review.fetch(id, scope) do
      nil ->
        put_flash(socket, :error, gettext("That note is no longer here."))

      comment ->
        comment
        |> apply_comment_action(action, socket.assigns[:current_user])
        |> case do
          # `Ash.destroy/2` answers `:ok`, not `{:ok, record}` — there is nothing left to hand back.
          :ok -> socket |> refresh_review() |> put_flash(:info, done)
          {:ok, _record} -> socket |> refresh_review() |> put_flash(:info, done)
          {:error, reason} -> put_flash(socket, :error, human(reason))
        end
    end
  end

  # Master and tenant take different actions on every runtime resource, and passing a tenant to a
  # master action is refused outright — the same trap recorded on the media reads.
  #
  # THE WRITE IS SCOPED BY WHO IS ASKING, not by the id in the click — the rule `delete_snippet`
  # states above. Taking the tenant off the NOTE handed a site-scoped admin every other site's: the
  # victim's own `site_id` satisfies both `TenantContext` and the policy, so nothing downstream
  # could tell, and `authorize?: false` meant nothing was asked. Both go: the actor names the
  # tenant, and the domain's own default decides authorization.
  defp apply_comment_action(comment, action, actor) do
    case comment_action(action, actor, comment.site_id) do
      {:ok, {name, tenant}} when action == :destroy ->
        comment
        |> Ash.Changeset.for_destroy(name, %{}, actor: actor, tenant: tenant)
        |> Ash.destroy()

      {:ok, {name, tenant}} ->
        comment
        |> Ash.Changeset.for_update(name, %{}, actor: actor, tenant: tenant)
        |> Ash.update()

      {:error, _reason} = refusal ->
        refusal
    end
  end

  # A master writes any note under no tenant; everyone else writes only their own site's, under
  # their own. An id naming anywhere else is refused rather than written under the tenant it names.
  defp comment_action(action, %{site_id: nil}, _site_id), do: {:ok, {master_action(action), nil}}

  defp comment_action(action, %{site_id: site_id}, site_id) when is_binary(site_id),
    do: {:ok, {action, site_id}}

  defp comment_action(_action, _actor, _site_id), do: {:error, :note_belongs_elsewhere}

  defp master_action(:resolve), do: :master_resolve
  defp master_action(:reopen), do: :master_reopen
  defp master_action(:destroy), do: :master_destroy

  # THE BADGE AND THE THREAD BOTH RE-READ; neither keeps a copy of the other's state.
  #
  # Nothing pushes rows into a Gervaz table — it reads again when the state it was handed changes.
  # So the revision is bumped and rides in the thread's `path_params`, exactly the way the Studio's
  # snippet list is refreshed after a save. `send_update` is not the tool here: the table's
  # `update/2` needs the full assign set it was mounted with, and a partial one raises.
  # THE CARET FOLLOWS THE MODE. The composer says "Replying to" from here, so the cursor has to move
  # from here too — a box that announces what it is for and then waits to be clicked is asking for a
  # click it should not need.
  #
  # `gervaz:exec-js` is the bridge every admin page already uses to run a `JS` command after an
  # event, and it is the only one that is safe against this particular patch: changing `defaults`
  # rebuilds the form, and a PUSHED event is dispatched AFTER the DOM is patched — so the bridge
  # focuses the textarea reply mode has just drawn, not the one it replaced. Composing `JS.focus/1`
  # onto the Reply button instead would resolve the target before the diff and hand the caret to a
  # detached node.
  defp focus_composer(socket) do
    push_event(socket, "gervaz:exec-js", %{
      target: "pb-comment-body",
      js: Jason.encode!(JS.focus().ops)
    })
  end

  # ONE CHANNEL FOR A NOTE. The session topic used to carry this as well, which was a second way of
  # saying what `PageComment`'s own `pub_sub` now says to every editor with the document open —
  # including, since a broadcast reaches its own sender, this one: the author re-read the thread
  # twice for every note they wrote.
  #
  # The local re-read stays because it is synchronous. The badge and the thread are right in the same
  # render as the flash, rather than a message later.
  defp refresh_review(socket), do: reread_review(socket)

  defp reread_review(socket) do
    socket
    |> update(:review_revision, &(&1 + 1))
    |> then(&assign(&1, :open_bugs, Review.open_bugs(Panels.review_scope(&1.assigns))))
  end
end
