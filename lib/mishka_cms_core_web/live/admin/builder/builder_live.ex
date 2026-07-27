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
  alias MishkaCmsCore.Runtime.PageBuilder.CardPreview
  alias MishkaCmsCore.Runtime.PageBuilder.Strict

  require MishkaCmsCore.Runtime.PageBuilder.Strict
  alias MishkaCmsCore.Layouts
  require Logger

  alias MishkaCmsCore.Runtime.ErrorAddress
  alias MishkaCmsCore.Runtime.PageBuilder.CodeCheck
  alias MishkaCmsCore.Runtime.PageBuilder.ElementCss
  alias MishkaCmsCore.Runtime.PageBuilder.ElementScopes
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Styles
  alias MishkaCmsCore.Runtime.PageBuilder.LayoutSlot
  alias MishkaCmsCore.Runtime.PageBuilder.Drafts
  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.States.EditorSessionState
  alias MishkaCmsCore.Runtime.PageBuilder.Inspector
  alias MishkaCmsCore.Runtime.PageBuilder.Presence
  alias MishkaCmsCore.Runtime.PageBuilder.Presets
  alias MishkaCmsCore.Runtime.PageBuilder.Section
  alias MishkaCmsCore.Runtime.PageBuilder.Visibility
  alias MishkaCmsCore.Runtime.PageBuilder.Wizard
  alias MishkaCmsCore.Runtime.PageBuilder.Tokens
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
      {_opened, editor} -> mount_editor(socket, section, params, record, actor, editor)
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
  end

  defp mount_editor(socket, section, params, record, actor, editor) do
    if connected?(socket) do
      Events.session_opened(editor)
      EditorSession.subscribe(editor.token)
      Presence.join(editor.token, actor)
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
    |> assign(:section, section)
    # BACK TO WHERE THE AUTHOR CAME FROM. A component opened from a page's Inspector carries that
    # page's builder in `return_to`, so editing what the page uses is a trip rather than a detour
    # through the component list. See `Section.back_path/2` for why it is matched, not trusted.
    |> assign(:back_path, Section.back_path(section, params["return_to"]))
    |> assign(:record, record)
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
    |> assign_editor(editor)
    |> assign_defaults()
  end

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


      {:ok, editor} ->
        {:resumed, editor}

      :error ->
        open_session(section, params, record, actor, connected?)
    end
  end

  defp own_session_or_open(section, params, record, actor, connected?),
    do: open_session(section, params, record, actor, connected?)

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
    |> assign_new(:group_folds, fn -> %{} end)
    |> assign_new(:icon_query, fn -> "" end)
    |> assign_new(:icon_variant, fn -> "" end)
    |> assign_new(:icon_library, fn -> nil end)
    |> assign_new(:right_tab, fn -> :layers end)
    |> assign_new(:left_w, fn -> 344 end)
    |> assign_new(:right_w, fn -> 300 end)
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
    |> assign_new(:find_open, fn -> false end)
    |> assign_new(:find, fn -> "" end)
    |> assign_new(:replace, fn -> "" end)
    |> assign_new(:find_hits, fn -> [] end)
    |> assign_new(:component_presets, fn -> %{} end)
    |> assign_new(:presets_count, fn -> -1 end)
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
    |> assign_new(:command_open, fn -> false end)
    |> assign_new(:command_query, fn -> "" end)
    |> assign_new(:palette_query, fn -> "" end)
    |> assign_new(:palette_cat, fn -> "all" end)
    |> assign_new(:attr_form, fn -> false end)
    |> assign_new(:reload_confirm, fn -> false end)
    # Where the author was going when the editor stopped them, and the only thing that renders the
    # question. Nil is the ordinary state: nothing to lose, or nobody leaving.
    |> assign_new(:leave_to, fn -> nil end)
    |> assign_new(:autosave_failed?, fn -> false end)
    # Which property the Inspector should land on, set when a property row in the tree is clicked.
    |> assign_new(:focus_attr, fn -> nil end)
    |> assign_new(:draft, fn -> nil end)
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
    |> assign_new(:theme, fn -> "light" end)
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
    # This site by default, even for a master: the editor is open on one site, and sharing a
    # package with every site on the server should be a thing someone chose.
    |> assign_new(:block_cat, fn -> "all" end)
    |> assign_new(:block_query, fn -> "" end)
  end

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

  defp assign_panel_tab(socket, panel) when panel in [:layers],
    do: assign(socket, :right_tab, panel)
  defp assign_panel_tab(%{assigns: %{rails: rails}} = socket, panel) do
    case Enum.any?(rails, &(to_string(Descriptor.key(&1)) == to_string(panel))) do
      true -> assign(socket, :right_tab, panel)
      false -> socket
    end
  end

  defp assign_panel_tab(socket, _panel), do: socket

  defp reload_canvas(socket) do
    socket
    |> assign(:reload_confirm, false)
    |> push_event("pb:reload-canvas", %{})
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
        socket |> assign(:drafted_revision, editor.revision) |> autosave()
    end
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
    components
    |> Enum.map(&palette_entry/1)
    |> then(&Events.collect(:components, &1))
  end

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
  defp palette_entry(component) do
    %{
      id: component.id,
      # `key` is what the registry de-duplicates on, so a plugin contributing an entry that names an
      # existing component leaves the core's one in place.
      key: component.name,
      name: component.name,
      template: component.template,
      label: humanize(component.name),
      type: component.type || "general",
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

  @impl true
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

  def handle_info(_message, socket), do: {:noreply, socket}

  defp sync_session(socket, token) do
    case EditorSession.fetch(token) do
      {:ok, editor} -> assign_editor(socket, editor)
      :error -> socket
    end
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
    gettext("Draft · %{time}",
      time:
        Calendar.strftime(
          DateTime.utc_now(),
          "%d %b %Y, %H:%M",
          MishkaCmsCore.Activity.Helpers.strftime_names()
        )
    )
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
  defp autosaved(socket, {:ok, draft}) do
    {:ok, editor} =
      EditorSession.mark_saved(socket.assigns.editor.token,
        stage: :draft,
        draft_id: draft.id,
        draft_label: draft.label,
        as_of: socket.assigns.autosaving_revision
      )

    socket
    |> assign(:editor, editor)
    |> assign(:draft, draft)
    |> assign(:autosave_failed?, false)
  end

  # A COMPONENT HAS NO DRAFT RESOURCE, and saying so once a change would be a lie told constantly.
  # Its Save button is its only persistence, which the drafts sheet already says in words.
  defp autosaved(socket, :unsupported), do: socket

  defp autosaved(socket, _unsaved), do: autosave_failed(socket)

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

  def handle_event("toggle_command", _params, socket),
    do: {:noreply, update(socket, :command_open, &(!&1))}

  def handle_event("command_query", %{"value" => value}, socket),
    do: {:noreply, assign(socket, :command_query, value)}

  def handle_event("palette_query", %{"value" => value}, socket),
    do: {:noreply, assign(socket, :palette_query, value)}

  def handle_event("palette_cat", %{"cat" => cat}, socket),
    do: {:noreply, assign(socket, :palette_cat, cat)}

  def handle_event("set_mob_panel", %{"panel" => "palette"}, socket),
    do: {:noreply, assign(socket, command_open: true, command_query: "", mob_panel: :canvas)}

  def handle_event("set_mob_panel", %{"panel" => "dir"}, socket) do
    {:ok, _editor} =
      EditorSession.set_dir(socket.assigns.token, (socket.assigns.dir == "rtl" && "ltr") || "rtl")

    {:noreply, socket}
  end

  def handle_event("set_mob_panel", %{"panel" => panel}, socket)
      when panel in ~w(canvas components layers inspector) do
    panel = String.to_existing_atom(panel)

    {:noreply,
     socket
     |> assign(mob_panel: panel)
     |> assign_panel_tab(panel)}
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

  # A pick is placed by CLICKING, and the layers tree is somewhere you can click. Clicking a row
  # while something is picked means "put it in here" — the same gesture the canvas offers, through
  # the same `place_at/2`, which puts it inside the row when the row can hold it, immediately after
  # when it cannot, and beside the other bands when the thing being placed is one. Clicking a row
  # with nothing picked still just selects.
  def handle_event("select", %{"id" => id}, socket) do
    place_or_select(socket.assigns.editor.picked, id, socket)
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
    case String.trim(name) do
      "" -> {:noreply, socket}
      trimmed -> attr_added(socket, Tree.get(socket.assigns.editor.tree, id), trimmed, nil)
    end
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
        key -> &Collection.put_in_item(&1, at, String.to_existing_atom(key), value)
      end

    write_collection(socket, node_id, name, change)
  rescue
    ArgumentError -> {:noreply, socket}
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
    socket = assign(socket, :attr_form, false)

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
         %Tree.Node{} = node <- Tree.get(socket.assigns.editor.tree, node_id) do
      value =
        node.meta
        |> Map.get(:styles, %{})
        |> Map.get(String.to_existing_atom(bucket), %{})
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

  def handle_event("shortcut", %{"key" => key}, socket), do: shortcut(key, socket)

  # The canvas has no flash of its own, so a refusal it could not show — an illegal drop, say —
  # is posted up to this document and surfaced here.
  def handle_event("flash_error", %{"message" => message}, socket),
    do: {:noreply, put_flash(socket, :error, message)}

  # Same route for the drop that was ALLOWED but not where it was aimed: a relocation the person
  # dragging cannot see happen is a bug report waiting to be filed.
  def handle_event("flash_info", %{"message" => message}, socket),
    do: {:noreply, put_flash(socket, :info, message)}

  def handle_event("open_rail", %{"action" => "ask_ai"}, socket), do: {:noreply, socket}
  def handle_event("open_rail", %{"action" => "comment"}, socket), do: {:noreply, socket}
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

  # WHICH CHOOSER THIS PROPERTY HAS, asked of the same function the Inspector asks when it draws the
  # row — a second rule keyed on the attribute's name would drift from it the first time a kit called
  # something `poster` instead of `src`.
  defp offer_chooser(socket, id, prop) do
    socket = assign(socket, :focus_attr, prop)

    case chooser_for(socket, id, prop) do
      :icon ->
        socket |> assign(:icon_picker, prop) |> assign(:icon_query, "")


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
  defp shortcut("preview", socket), do: handle_event("toggle_preview", %{}, socket)
  defp shortcut("fit", socket), do: {:noreply, assign(socket, :zoom, 100)}

  defp shortcut("escape", socket) do
    {:ok, _editor} = EditorSession.select(socket.assigns.token, nil)
    {:ok, _editor} = EditorSession.pick(socket.assigns.token, nil)
    {:noreply, assign(socket, command_open: false)}
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
      |> assign(:record, record)
      |> assign(:stage, next_stage(stage))
      |> assign(:applied, {stage, editor.revision})
      |> assign(:applied_stage, stage)
      |> assign(:drafted_revision, nil)
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

  defp saved_message(:published, section),
    do: gettext("%{section} published.", section: section_label(section))

  defp saved_message(_stage, section),
    do: gettext("%{section} saved.", section: section_label(section))

  # A rail's key is whatever the registry answered with, so the open tab is matched against that
  # list rather than against a fixed set — and an unknown one falls back to the first rail there is.
  defp rail_tab(%{assigns: %{rails: rails}}, tab) do
    keys = Enum.map(rails, &to_string(Descriptor.key(&1)))

    case to_string(tab) in keys do
      true -> String.to_existing_atom(to_string(tab))
      false -> :layers
    end
  end

  defp rail_tab(_socket, _tab), do: :layers

  defp tab_atom(value, allowed) when is_binary(value),
    do: Enum.find(allowed, hd(allowed), &(Atom.to_string(&1) == value))

  defp tab_atom(value, allowed) when is_atom(value),
    do: if(value in allowed, do: value, else: hd(allowed))

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
      {:open, :snippet} -> assign(socket, sheet: :studio, studio_tab: :snippets)
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
        record={@record}
        section={@section}
        back_path={@back_path}
        current_user={@current_user}
        editors={@editors}
        dirty?={@dirty?}
        saved_at={@saved_at}
        stage={@stage}
        applied_stage={@applied_stage}
        device={@device}
        dir={@dir}
        zoom={@zoom}
        preview?={@preview?}
        dev_mode?={@dev_mode?}
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
          record={@record}
        />
        <Panels.center
          token={@token}
          record={@record}
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
          marked={@marked}
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
          record={@record}
        />
      </div>

      <Panels.command_palette :if={@command_open} {assigns} />
      <Panels.reload_modal :if={@reload_confirm} />
      <Panels.leave_modal :if={@leave_to} />
      <%!-- ONE menu for both surfaces. The layers rail right-clicks into it directly; the canvas is a
            frame with none of this stylesheet, so it forwards its right-clicks here rather than
            drawing a second, inline-styled copy that would drift. --%>
      <Panels.find_modal :if={@find_open} find={@find} replace={@replace} hits={@find_hits} />
      <Panels.context_menu id="pb-ctx" target="[data-layer-row]" key="layerRow" />
    </div>
    """
  end

end
