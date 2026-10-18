# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Builder.CanvasLive do
  @moduledoc """
  The page-builder canvas: the document itself, rendered inside a same-origin iframe with the
  **site's** compiled CSS rather than the admin's.

  ## Why this is a second LiveView and not a div

  Three things fall out of the iframe that no same-document approach can give:

    * **Style isolation without portals.** The site's stylesheet cannot reach the editor chrome and
      the admin's cannot reach the page. The React editor rendered into an iframe through
      `createPortal` and had to bridge native events back across the boundary by hand.
    * **Real viewports.** A tablet frame is an 834px-wide iframe, so the site's own media and
      container queries actually fire. A CSS transform on a div only *looks* narrower.
    * **Ordinary bindings.** Selecting an element is `phx-click`, not a synthetic event forwarded
      across documents.

  ## Rendering is a function call

  A component node renders through `MishkaCmsCore.Runtime.LiveViewHelpers.component/1`, which
  `apply/3`s an already-compiled module. There is no `Code.eval_quoted/3` anywhere on this path and
  no HTTP round trip per component — the entire Phase-C re-render queue of the React editor exists
  because only the server could render a component and the editor was not the server. Here it is.

  Slot children become real Phoenix slot entries: `%{__slot__: name, inner_block: rendered}`, which
  `Phoenix.Component.render_slot/2` accepts directly. That is what makes the *inside* of a component
  editable — the opaque-leaf problem the JSON encoder created, resolved at the ownership boundary.

  ## Chrome styling

  Every piece of chrome this LiveView draws — the empty-page chooser, the floating element toolbar,
  the layout panel, the two placeholders — is a CSS rule in one of the nonced `<style>` blocks below,
  keyed on an id or a `data-pb-*` marker, not a `style` attribute. A Content-Security-Policy has no
  nonce to offer an attribute, so `style-src-attr 'unsafe-inline'` can only be closed by the
  attributes not existing; a rule, unlike an attribute, can be marked as ours.

  Every selector is anchored to an id, which matters more here than anywhere else in the admin: this
  frame is served the AUTHOR's compiled stylesheet, so the chrome and the document being edited share
  one cascade. An id-anchored rule outranks any utility that stylesheet contains, which is the
  property the `style` attribute used to supply for free.

  Two blocks, because Preview keeps half of it. `#pb-canvas-chrome` is switched off in preview — the
  hover outline, the selection ring, the chooser and the toolbar are editing affordances — while
  `#pb-canvas-ui` holds what is drawn in both modes: the stage itself, the empty-page well, the
  expression chip and the "could not render" placeholder.

  ## The one `style` attribute that stays

  `wrapper_style/1` still renders one, on the nodes that need it, and it is not the editor's:

    * the AUTHOR's own `style` attribute, lifted off the node and re-attached to the wrapper. It is
      page content, arbitrary, and unbounded — no finite rule set can express it, and turning it into
      a per-node rule would change where it sits in the cascade, because an attribute outranks every
      selector and a `[data-node-id="…"]` rule does not.
    * `@locked_style` and `@hollow_style`, which are appended AFTER it precisely so they win that
      clash — and which two hook routines (`lift` and `openEmpties` in `admin_hooks.js`) save and
      restore through `el.style`, expecting to find them there.

  So the canvas cannot be the surface that closes `style-src-attr`: a document that carries a `style`
  attribute anywhere, or a kit component that renders one, puts it back. What this file can promise
  is that the EDITOR never adds one. `present/1` returns `nil` rather than `""` and `wrapper_attrs/1`
  splats it as a runtime map — which is what actually drops it, since HEEx renders a written-out
  `style={nil}` as `style=""` — so a page with no authored styling renders through this canvas with
  no `style` attribute anywhere in it.

  ## Where the CSS comes from

  Two sources, and both are needed.

  The site's **compiled** bundle is LINKED from `MishkaCmsCoreWeb.AssetsController` when it has a
  content hash to address it by, and inlined from `AssetsState` when it does not. Inlining was the
  original answer, because a site that is inactive, undeployed or never compiled has no hash — and
  that is exactly the site someone opens the editor on. But the bundle is 3.6 MB on a real site, and
  inlining put all of it in the document of every preview the examples modal opened: re-sent and
  re-parsed each time. Linked, it is brotli-compressed, cached `immutable` for a year, and blocks
  rendering — so the frame paints once, already styled, instead of flashing unstyled icons. The hash
  is in the URL, so a recompile is a new URL rather than a stale cache. The inline path remains for
  the hashless case, which is why both still exist.

  Tailwind's **browser** build then generates any utility the moment its class appears in the DOM,
  which is what makes an edit visible immediately instead of after a compile. On its own it would not
  know the kit's design tokens, so the site's `@theme` source travels with it.
  """
  use MishkaCmsCore.ExtensionLiveView

  require Ash.Query
  require Logger

  alias MishkaCmsCore.Builder.Descriptor
  alias MishkaCmsCore.Builder.Events
  alias MishkaCmsCore.Builder.PaletteEntry
  alias MishkaCmsCore.Runtime.Compilers.Helpers, as: CompilerHelpers
  alias MishkaCmsCore.Runtime.LiveViewHelpers
  alias MishkaCmsCore.Runtime.PageBuilder.Containment
  alias MishkaCmsCore.Runtime.PageBuilder.Drafts
  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.PageBuilder.Inspector
  alias MishkaCmsCore.Runtime.PageBuilder.Fields
  alias MishkaCmsCore.Runtime.PageBuilder.Icons
  alias MishkaCmsCore.Runtime.PageBuilder.Wizard
  alias MishkaCmsCore.Runtime.PageBuilder.Examples
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.FormPlacement
  alias MishkaCmsCore.Runtime.PageBuilder.PageStarter
  alias MishkaCmsCore.Runtime.PageBuilder.Section
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Styles
  alias MishkaCmsCore.Runtime.PageBuilder.Visibility
  alias MishkaCmsCore.Runtime.DraftPreviewAssets
  alias MishkaCmsCore.Runtime.Layout
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.PageDraft
  alias MishkaCmsCore.Runtime.States.AssetsState
  alias MishkaCmsCore.Runtime.Translations
  alias MishkaCmsCoreWeb.Live.Admin.Builder.Panels

  @locked_style "opacity:.55;"

  # The empty-container treatment: enough height to aim at, and a dashed edge that says "this is a
  # box waiting for something" rather than "this is broken". `outline` rather than `border` so it
  # never changes the element's own box size, and `outline-offset` pulls it inside so two nested
  # empties do not draw on top of each other.
  @hollow_style "min-height:56px;outline:1px dashed #c9c7ee;outline-offset:-1px;"

  # AN IMAGE WITH NO FILE YET IS STILL A THING ON THE PAGE. `el-image` is placed with `src=""` on
  # purpose — the file is chosen from Assets afterwards — but a src-less `<img>` lays out at 0×0, so
  # the author dropped one, saw nothing appear, and had nothing to click to choose the file with.
  # Editing only, like `@hollow_style`, and never written to the document.
  @placeholder_style "min-height:120px;width:100%;outline:1px dashed #c9c7ee;outline-offset:-1px;" <>
                       "background:#faf9f6;"

  @impl true
  # The palette's examples modal previews one variant. It renders here, through this same canvas in
  # preview mode, rather than through a renderer of its own: a second renderer would answer "what
  # does this example look like" with a different picture than the one inserting it produces, which
  # is the only question the modal exists to answer. The tree is ephemeral — nothing is subscribed
  # to, nothing is written back — and the site rewrite is the same one `insert_example` performs, so
  # a global component previews as global.
  #
  # Must precede the token-only clause: a params map with three keys matches that pattern too.
  # The wizard's preview. Same canvas, same preview mode, same site rewrite as the example clause
  # below — the difference is only where the markup comes from: the reader's own choices, held in the
  # editing session so this second LiveView can read them, rather than a snippet the kit shipped.
  def mount(%{"token" => token, "wizard" => name}, _session, socket) do
    with {:ok, session} <- visible_session(token, socket.assigns[:current_user]),
         entry when not is_nil(entry) <- Enum.find(session.components, &(&1.name == name)),
         source =
           Wizard.compose(
             entry,
             session.wizard || %{},
             session.site_name,
             :preview,
             session.components
           ),
         {:ok, tree} <- Tree.parse(Fields.stage(source, entry)) do
      # It SUBSCRIBES, like the editing canvas does. Picking an option used to change the iframe's
      # DOM id, which made LiveView throw the element away and mount this again — a reload the
      # reader saw as a flash of empty frame on every click. Staying subscribed means the same
      # mounted preview re-renders in place.
      if connected?(socket), do: EditorSession.subscribe(token)

      {:ok,
       socket
       |> assign(:wizard_name, name)
       |> assign_session(session)
       |> assign_example(tree, session), layout: false}
    else
      :forbidden ->
        {:ok, assign(socket, missing?: :forbidden, token: token, page_title: gettext("Preview")),
         layout: false}

      :no_builder ->
        {:ok, assign(socket, missing?: :no_builder, token: token, page_title: gettext("Preview")),
         layout: false}

      _missing ->
        {:ok, assign(socket, missing?: :example, token: token, page_title: gettext("Preview")),
         layout: false}
    end
  end

  def mount(%{"token" => token, "name" => name, "index" => index}, _session, socket) do
    with {:ok, session} <- visible_session(token, socket.assigns[:current_user]),
         examples = Examples.for_name(name, session.site_id),
         example when not is_nil(example) <- Enum.at(examples, to_index(index)),
         entry = Enum.find(session.components, &(&1.name == name)),
         {:ok, tree} <- Tree.parse(Fields.stage(example.source, entry)) do
      {:ok, socket |> assign_session(session) |> assign_example(tree, session), layout: false}
    else
      :forbidden ->
        {:ok, assign(socket, missing?: :forbidden, token: token, page_title: gettext("Example")),
         layout: false}

      :no_builder ->
        {:ok, assign(socket, missing?: :no_builder, token: token, page_title: gettext("Example")),
         layout: false}

      _missing ->
        {:ok, assign(socket, missing?: :example, token: token, page_title: gettext("Example")),
         layout: false}
    end
  end

  def mount(%{"token" => token}, _session, socket) do
    case visible_session(token, socket.assigns[:current_user]) do
      {:ok, session} ->
        if connected?(socket), do: EditorSession.subscribe(token)
        bound_heap()

        {:ok,
         socket |> assign_session(session) |> assign_layout(session) |> assign(:missing?, false),
         layout: false}

      :forbidden ->
        {:ok, assign(socket, missing?: :forbidden, token: token, page_title: gettext("Canvas")),
         layout: false}

      :no_builder ->
        {:ok, assign(socket, missing?: :no_builder, token: token, page_title: gettext("Canvas")),
         layout: false}

      :error ->
        {:ok, assign(socket, missing?: true, token: token, page_title: gettext("Canvas")),
         layout: false}
    end
  end

  # THE CANVAS IS THE SECOND FRONT DOOR, and it is addressed by the editing session's token rather
  # than by the document's id — so not one of the checks the chrome makes at mount is inherited here.
  # A token is unguessable, but unguessable is not the same as authorized: it is handed out on
  # purpose by `?session=`, it sits in a URL and in a browser history, and "whoever has the link" is
  # the wrong answer to "who may read another site's page".
  #
  # The rule is the chrome's, said once more: a master sees every session, a tenant sees the ones
  # opened on their own site, and a session on a site-less document — a shared layout or component —
  # is a master's to hold.
  #
  # AND ONLY TO SOMEONE WHO MAY OPEN THAT BUILDER: the session's section names the builder, and the
  # names that open it (`Section.permissions/1`) are asked here as the chrome asks them at mount.
  defp visible_session(token, actor) do
    with {:ok, session} <- EditorSession.fetch(token),
         {:site, true} <- {:site, own_session?(actor, session)},
         {:builder, true} <- {:builder, Section.allowed?(actor, session.section)} do
      {:ok, session}
    else
      {:site, false} -> :forbidden
      {:builder, false} -> :no_builder
      :error -> :error
    end
  end

  defp own_session?(%{site_id: nil}, _session), do: true
  defp own_session?(%{site_id: site_id}, %{site_id: site_id}) when is_binary(site_id), do: true
  defp own_session?(_actor, _session), do: false

  # THE BOUND `contain/2` CANNOT GIVE. A `rescue` and a `catch` between them cover every way a
  # component render can LEAVE; neither covers one that does not leave — a comprehension over
  # something unbounded, a binary built in a loop. That render allocates inside this process until
  # the machine is out of memory, and it takes the node with it, not just this iframe.
  #
  # A heap ceiling is the one bound available without a second process, and a second process is not
  # available here: `Ecto.Adapters.SQL.Sandbox` ownership does not cross one, so every component that
  # reads the database would break under test (see the note on `contain/2`).
  #
  # 200 MB of WORDS — a word is 8 bytes on a 64-bit VM, so ~1.6 GB, which no honest canvas approaches
  # and a runaway reaches in seconds. `kill: true` ends this LiveView; the builder holding the
  # author's document is a different process and keeps it. `error_logger: true` so the reason is in
  # the log rather than being guessed at from a blank iframe.
  @heap_words 25_000_000

  defp bound_heap do
    Process.flag(:max_heap_size, %{
      size: @heap_words,
      kill: true,
      error_logger: true,
      include_shared_binaries: false
    })
  end

  defp assign_example(socket, tree, session) do
    rewritten = Tree.rewrite_site(tree, session.site_name, session.components)

    socket
    |> assign(:tree, rewritten)
    # RECOMPUTED for the tree being previewed, not the one being edited. `assign_session/2` derived
    # `icon_css` from `session.tree` — the page open in the editor — and a preview then replaced the
    # tree without replacing the rules, so an example's icon rendered only when the page underneath
    # happened to use the same one. `chelekom-alert`'s maintenance example asks for
    # `hero-wrench-screwdriver`, no page used it, and the reader saw a heading with a blank space
    # where the icon belongs — the class was in the code pane and had no rule behind it.
    |> assign(
      :icon_css,
      Icons.css(Enum.uniq(icons_set_by(rewritten) ++ icons_defaulted_by(session.components)))
    )
    |> assign(:missing?, false)
    |> assign(:selection, nil)
    |> assign(:preview?, true)
    |> assign(:example?, true)
    |> assign(:page_title, gettext("Example"))
  end

  # An example is one component on an empty sheet, so it sits in the middle of the stage rather than
  # pinned to the top — the prototype centres its mock the same way. Children keep their own width;
  # only the group is centred, or a full-bleed nav would shrink to its content.
  # A PAGE BORN EMPTY ALREADY HAS ONE CONTAINER IN IT — the database will not take a blank template
  # — so inserting beside it would leave an empty div above every structure anyone picks. Replacing
  # the document is the right move there, and it is still one undo step because it is replaced the
  # way a draft restore replaces it. On a page emptied back out by hand there is nothing to replace,
  # so it is an ordinary insert.
  #
  # EMPTY AS STORED, not as this canvas last drew it. Something placed from the layers rail a moment
  # ago has not reached this process yet, and replacing the document over it threw it away.
  defp place_starter(socket, structure) do
    with {:ok, tree} <- Tree.parse(structure.template),
         {:ok, _session} = replaced <-
           EditorSession.update_tree(
             socket.assigns.token,
             &over_empty(&1, tree),
             reason: :page_starter
           ) do
      replaced
    else
      _not_replaceable ->
        EditorSession.apply_op(socket.assigns.token, %{
          kind: :insert,
          parent_id: nil,
          index: 0,
          template: structure.template
        })
    end
  end

  defp over_empty(stored, tree) do
    case PageStarter.empty?(stored) do
      true -> {:ok, tree}
      false -> :occupied
    end
  end

  attr :section, :any, required: true

  # WHAT TO DO WITH A PAGE THAT HAS NOTHING ON IT. The dashed well this replaces said "Pick a
  # component on the left, then click here" — true, but it asks someone who has never built a page to
  # already know what the first thing should be. A container, probably. Then another one beside it.
  #
  # These four are that first decision made for them, as pictures: one click and the page has a shape
  # to hang things on. It is deliberately NOT a second page builder — no copy, no styling choices,
  # nothing to delete afterwards. `Start from scratch` is kept because someone who does know what
  # they want should not have to undo a structure first.
  #
  # Called a STARTER and not a layout: Runtime's Layout is a template that wraps a page and outlives
  # every page using it. This is scaffolding thrown away by the first edit. Two unrelated things with
  # one name in the same editor is how a word stops meaning anything.
  #
  # Every element here is named — an id where there is one of it, a `data-pb-*` marker where a
  # comprehension makes several — and drawn by a rule in `#pb-canvas-chrome`. The frame is served the
  # AUTHOR's compiled stylesheet, where the admin's Tailwind classes do not exist, so this chrome is
  # written as real CSS rather than as utilities; it is a nonced `<style>` rather than `style`
  # attributes so `style-src-attr` has nothing left to permit. The hero card's picture is the one
  # that stacks instead of splitting, which is why the preview and its bars carry the structure's own
  # id: `[data-pb-preview="hero"]` is the whole difference.
  defp page_starter(assigns) do
    # An extension can offer its own starting points here — a marketing kit's landing shapes, an
    # agency's house layouts — beside the core's.
    assigns =
      assign(assigns, :structures, Events.collect_appended(:page_starters, PageStarter.all()))

    ~H"""
    <div id="pb-page-starter">
      <div id="pb-page-starter-card">
        <div id="pb-page-starter-head">
          <div id="pb-page-starter-title">
            {gettext("This %{section} is empty", section: label(@section))}
          </div>
          <div id="pb-page-starter-hint">
            {gettext("How do you want to start? Pick a structure and begin filling it in.")}
          </div>
        </div>

        <div id="pb-page-starter-grid">
          <button
            :for={structure <- @structures}
            type="button"
            id={"pb-starter-#{structure.id}"}
            phx-click="page_starter"
            phx-value-structure={structure.id}
            title={Gettext.gettext(MishkaCmsCore.Gettext, structure.description)}
            data-pb-starter="true"
          >
            <span data-pb-preview={structure.id}>
              <span :for={_column <- 1..structure.columns//1} data-pb-column={structure.id}></span>
            </span>
            <span data-pb-body="true">
              <span data-pb-name="true">
                {Gettext.gettext(MishkaCmsCore.Gettext, structure.title)}
              </span>
              <span data-pb-desc="true">
                {Gettext.gettext(MishkaCmsCore.Gettext, structure.description)}
              </span>
            </span>
          </button>
        </div>

        <div id="pb-page-starter-foot">
          <span id="pb-page-starter-note">
            {gettext("Or drop a component straight onto the page.")}
          </span>
          <button type="button" id="pb-starter-scratch" phx-click="starter_scratch">
            {gettext("Start from scratch")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp label("component"), do: gettext("component")
  defp label("layout"), do: gettext("layout")
  defp label("error_page"), do: gettext("error page")
  defp label(_section), do: gettext("page")

  # WHERE THE PREVIEWED DOCUMENT DOES RUN. The new-tab entry lives over a saved draft, and only a
  # section that keeps drafts ever has one: a component saves straight to its live record, so
  # pointing its author at that menu pointed them at a control that never appears. The session
  # spells its section with an underscore and `Drafts` with a hyphen, hence the normalize.
  defp click_through(section) do
    case Drafts.supported?(Section.normalize(section)) do
      true ->
        gettext("use Preview ▸ Open in a new tab to click through a saved draft.")

      false ->
        gettext("they run on the published site once this %{section} is saved.",
          section: label(section)
        )
    end
  end

  defp to_index(index) do
    case Integer.parse(to_string(index)) do
      {number, _rest} -> number
      :error -> -1
    end
  end

  # Every heroicon class this document could render: the ones its nodes SET, and the default of every
  # icon-typed attribute on every component it uses — a component renders its default when the page
  # says nothing, and that value appears nowhere in the tree.
  # SPLIT BECAUSE THE TWO HALVES CHANGE AT DIFFERENT RATES. What the document SETS changes with every
  # edit and has to be walked again — but that is a 50-200 node walk and it is cheap. What the
  # components DEFAULT to only changes when the palette is loaded, and finding it means reading every
  # attribute of all ~180 components. Recomputing that on every broadcast — every selection, every
  # keystroke, every undo — was the expensive half, so it is memoised and invalidated by the one
  # message that can change it.
  defp icons_set_by(tree) do
    for node <- Tree.walk(tree),
        {_name, value} <- node.attrs,
        name <- icon_names(value),
        do: name
  end

  defp icons_defaulted_by(components) do
    for entry <- components,
        attr <- Inspector.attrs(entry),
        name <- icon_names(Inspector.default(attr)),
        do: name
  end

  # ANY REGISTERED SET, not one prefix. `Icons.known?/1` asks every registered library, so a name
  # guard here only ever excluded other people's icons: a kit shipping Lucide got a working picker —
  # the library row appeared, search found the glyph, the swatch drew it — and a blank box on the
  # canvas an inch away.
  #
  # AND ANY SHAPE, not only a bare string. An icon-typed attribute is a string, but a LABEL is a map
  # — `chelekom-pagination` defaults its five arrows and its separator to
  # `%{type: :icon, value: "hero-chevron-left"}`, which the bundle carries as an `__atom_map__`
  # envelope. Reading only `{:string, …}` meant every one of those glyphs had no rule generated for
  # it, so a dropped pagination drew empty boxes where its arrows should be. Walking the term rather
  # than matching a shape also covers a list of them, and an author who writes one by hand as an
  # expression.
  defp icon_names({:string, value}), do: icon_names(value)
  defp icon_names({:expr, source}) when is_binary(source), do: Icons.classes_in(source)

  defp icon_names(value) when is_binary(value) do
    case Icons.known?(value) do
      true -> [value]
      false -> []
    end
  end

  defp icon_names(%{} = map), do: map |> Map.values() |> Enum.flat_map(&icon_names/1)

  defp icon_names(list) when is_list(list), do: Enum.flat_map(list, &icon_names/1)

  defp icon_names(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.flat_map(&icon_names/1)

  defp icon_names(_other), do: []

  # THE FRAME RENDERS FOR THE DOCUMENT'S SITE, so it draws that site's components and the global ones
  # and refuses another site's exactly as the published page will — see
  # `MishkaCmsCore.Runtime.LiveViewHelpers.component/1`. A site-less document, a shared layout or
  # component, renders for no site. `t/1` in the frame reads the same site's words.
  defp assign_session(socket, session) do
    :ok = Translations.put_site(session.site_id)

    socket
    |> assign(:token, session.token)
    |> assign(:section, session.section)
    # DERIVED FROM THE PALETTE, so it is recomputed when the palette arrives and not before —
    # `required_attrs/1` reads every attribute of every component, and this runs on every broadcast.
    |> assign_new(:required_attrs, fn -> required_attrs(session.components) end)
    |> assign_new(:media_attrs, fn -> media_attrs(session.components) end)
    |> assign_new(:conceals, fn -> conceals(session.components) end)
    |> assign_new(:shapers, fn -> shapers(session.components) end)
    |> assign_new(:icon_defaults, fn -> icons_defaulted_by(session.components) end)
    |> assign(:components, session.components)
    |> assign(:tree, session.tree)
    |> assign_form_marks(session)
    # WHICH DOCUMENT THIS FRAME IS SHOWING, so the editor's own frame overlay can tell a canvas that
    # has repainted from one that has not. Nothing here reads it — `PbCanvas` posts it up to the
    # parent window on every patch where it changed, and the frame's spinner is dismissed by that.
    |> assign(:revision, session.revision)
    |> assign(:selection, session.selection)
    |> assign(:locked, session.locked)
    |> assign(:hidden, session.hidden)
    |> assign(:pinned, session.pinned || MapSet.new())
    |> assign(:site_scope, session.site_name)
    |> assign(:dir, session.dir)
    |> assign_new(:canvas_css, fn -> site_css(session.site_name) end)
    |> assign_new(:canvas_css_hrefs, fn -> css_hrefs(session.site_name) end)
    |> then(
      &assign(
        &1,
        :icon_css,
        Icons.css(Enum.uniq(icons_set_by(session.tree) ++ &1.assigns.icon_defaults))
      )
    )
    |> assign_new(:canvas_theme, fn -> theme_source(session.site_id) end)
    |> assign(:element_css, session.element_css || "")
    # `suppress_site_js` keeps the site's own bundle (and its LiveSocket) out — a second LiveSocket
    # inside the frame would fight this canvas for the same DOM — and `standalone_assets` loads the
    # admin `app.js` instead, which is where this canvas's hooks live. `suppress_site_css` turns the
    # layout's `<link>` off because the CSS is inlined here instead; see the moduledoc.
    |> assign(:current_site, session.site_name && %{name: session.site_name})
    |> assign(:suppress_site_js, true)
    |> assign(:suppress_site_css, true)
    |> assign(:standalone_assets, true)
    # The browser generator is a deliberate dependency here, not an accident of the layout: it is what
    # turns a class typed in the inspector into visible CSS without a compile.
    # FONTS ONLY, and `admin_css` turned OFF EXPLICITLY. This iframe renders a SITE's document; its
    # own chrome — the selection ring, the component chip, the "needs id" placeholder — is inline
    # styles computed from session state, so the dashboard's stylesheet has nothing to contribute.
    # It used to load it because one assign gated the fonts and the stylesheet together, and the
    # frames view mounts three of these at once.
    #
    # `false` rather than simply omitted: this is an admin LiveView, so `MishkaCmsCore.Layouts.Nav`
    # has already switched `admin_css` on for it by the time mount runs. Leaving it out inherits it.
    |> assign(:admin_css, false)
    |> assign(:admin_fonts, true)
    # See `BuilderLive`: the canvas renders whatever the document names, including kit components no
    # build ever scanned, so it needs the generator rather than a compiled sheet.
    |> assign(:live_tailwind, true)
    |> assign(:page_title, gettext("Canvas"))
    |> assign(:preview?, session.preview?)
    |> assign(:placing, session.picked)
    |> assign_new(:toolbar, fn assigns -> toolbar_actions(assigns[:current_user]) end)
    |> assign_new(:bucket, fn -> "base" end)
    |> assign_new(:example?, fn -> false end)
    |> assign_new(:layout_shell, fn -> {"", ""} end)
  end

  # A PAGE IS DRAWN INSIDE ITS LAYOUT, so an author edits what a visitor will see. The layout is
  # rendered once, by the module `MishkaCmsCore.Runtime.DraftPreviewAssets.ensure_module/2` compiles
  # for it, around a marker where `@inner_content` goes, and kept as the markup before and after
  # it: the document between them is still the canvas's own, diffed and editable, and the layout
  # is sent once. It is drawn but not used — `#pb-layout-shell` takes no pointer — and a layout
  # that does not render leaves the page alone.
  @layout_slot "<!--pb-layout-slot-->"

  defp assign_layout(socket, %{section: "page", resource_id: page_id} = session)
       when is_binary(page_id) do
    shell =
      with {:ok, page} <- read_document(session),
           %Layout{} = layout <- document_layout(page),
           {:ok, module} <- DraftPreviewAssets.ensure_module(layout, canvas_site(session)),
           {:html, html} <-
             contained(layout.name, socket.assigns.preview?, fn ->
               module.render(layout_assigns(page, session), Phoenix.HTML.raw(@layout_slot))
             end),
           [before, rest] <- String.split(html, @layout_slot, parts: 2) do
        {~s(<div id="pb-layout-shell">) <> before <> ~s(<div id="pb-layout-slot">),
         "</div>" <> rest <> "</div>"}
      else
        _no_layout -> {"", ""}
      end

    assign(socket, :layout_shell, shell)
  end

  defp assign_layout(socket, _session), do: socket

  # THE DRAFT BEING WRITTEN WHEN THERE IS ONE, since its settings — the layout among them — are the
  # ones the builder edits then; the page otherwise.
  defp read_document(%{stage: :draft, draft_id: draft_id}) when is_binary(draft_id),
    do: read_any(PageDraft, draft_id, layout: [:site])

  defp read_document(%{resource_id: page_id}), do: read_any(Page, page_id, [:loaded_layout])

  defp read_any(resource, id, load) do
    resource
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.load(load)
    |> Ash.read_one(authorize?: false)
  end

  defp document_layout(%Page{loaded_layout: layout}), do: layout
  defp document_layout(%PageDraft{layout: layout}), do: layout
  defp document_layout(_none), do: nil

  defp canvas_site(%{site_id: site_id, site_name: site_name}) when is_binary(site_id),
    do: %{id: site_id, name: site_name}

  defp canvas_site(_session), do: nil

  # What a layout reads around a published page — see `MishkaCmsWeb.RuntimeLive` — with nobody
  # signed in.
  defp layout_assigns(page, session) do
    %{
      page: %{
        title: page.title,
        path: page.path,
        section: page.section,
        language: page.language
      },
      private: %{site: session.site_name, site_id: session.site_id},
      current_site: canvas_site(session),
      current_user: nil,
      flash: %{},
      query_params: %{},
      page_languages: []
    }
  end

  # Which nodes are forms, and where a field dropped at a form's end lands, for a field drag on a
  # Page. The roles worked out are kept and grown, not asked again per broadcast.
  defp assign_form_marks(socket, session) do
    case FormPlacement.page_forms?(session) do
      true ->
        {marks, memo} =
          FormPlacement.marks(session.tree, session.components, socket.assigns[:form_memo] || %{})

        socket |> assign(:form_marks, marks) |> assign(:form_memo, memo)

      false ->
        assign(socket, :form_marks, nil)
    end
  end

  # The canvas never links the site's public asset URL. That route is keyed on the site's own name
  # and a content hash, and a site that is inactive, undeployed, or has simply never been compiled has
  # neither — which is exactly the site someone opens the editor on. Those bytes are already in
  # `AssetsState`, so they are inlined into the frame instead: no host to resolve, no route to hit,
  # and no dependence on the site being live.
  #
  # Both layers are needed. `__shared_base__` carries the global theme and every global component's
  # CSS; the site's own bundle carries what only that site uses.
  # ONE stylesheet, not two. A site's compiled bundle already CONTAINS the shared base —
  # `TailwindCompiler` builds it as `shared_css <> "\n/* Site: … */\n" <> site_css` — so linking
  # both made the frame download and parse the same 1.8 MB twice. Verified on a real site: the whole
  # of `__shared_base__` is a byte-identical prefix of the site bundle, and only ~38 KB of the site's
  # own 1.86 MB is not shared.
  #
  # The base is the fallback rather than a companion: a site with nothing compiled yet has no bundle
  # of its own, and the base alone is what the frame can show.
  defp css_hrefs(site_name) do
    case site_name && css_href(site_name) do
      nil -> ["__shared_base__" |> css_href() |> List.wrap()] |> List.flatten()
      href -> [href]
    end
  end

  defp css_href(id) do
    case AssetsState.get(id, "css") do
      {:ok, %{hash: hash, value: value}}
      when is_binary(hash) and hash != "" and is_binary(value) and value != "" ->
        "/assets/css/#{URI.encode_www_form(id)}/#{hash}"

      _no_hash ->
        nil
    end
  end

  # The inline fallback, and it picks ONE layer for the same reason `css_hrefs/1` links one: the
  # site's bundle already contains the base, so joining them inlined 1.8 MB of duplicate CSS.
  defp site_css(site_name) do
    case site_name && AssetsState.get_value(site_name, "css") do
      css when is_binary(css) and css != "" -> css
      _none -> AssetsState.get_value("__shared_base__", "css") || ""
    end
  end

  # Tailwind's browser build generates a utility the moment a class appears in the DOM, which is what
  # makes editing feel immediate — but it only knows the tokens it has been told about. Left alone it
  # renders `text-natural-bordered-text-light` as nothing, because that colour lives in the kit's
  # `@theme`. Handing it the site's own `@theme` source closes the gap: every kit token resolves live,
  # with no compile step between typing a class and seeing it.
  #
  # The COMPILED css cannot serve this purpose — Tailwind has already turned `@theme` into `:root`
  # variables by then, and variables alone do not tell the generator which utilities may exist.
  defp theme_source(site_id), do: MishkaCmsCore.Runtime.RuntimePreview.theme_source(site_id)

  # The per-element actions the demo floats over a selection. Collected through
  # `builder:canvas:toolbar` so an extension can add its own, exactly like every other region.
  defp toolbar_actions(user) do
    Events.collect(:canvas_toolbar, [
      %{key: "form", label: gettext("Form"), glyph: "▦", priority: 2},
      %{key: "layout", label: gettext("Layout"), glyph: "✥", priority: 3},
      %{key: "ask_ai", label: gettext("Ask AI about this element"), glyph: "✦", priority: 5},
      %{key: "comment", label: gettext("Comment on this element"), glyph: "💬", priority: 8},
      %{key: "duplicate", label: gettext("Duplicate"), glyph: "⧉", priority: 10},
      %{key: "delete", label: gettext("Delete"), glyph: "🗑", priority: 20}
    ])
    |> Descriptor.permitted(user)
  end

  @impl true
  # The wizard preview answers to one thing only: the options the reader has chosen. Recomposing
  # from the session is the whole update — there is no selection to sync in a preview.
  def handle_info({:builder_session, token, _message}, %{assigns: %{wizard_name: name}} = socket) do
    with {:ok, session} <- EditorSession.fetch(token),
         entry when not is_nil(entry) <- Enum.find(session.components, &(&1.name == name)),
         source =
           Wizard.compose(
             entry,
             session.wizard || %{},
             session.site_name,
             :preview,
             session.components
           ),
         {:ok, tree} <- Tree.parse(Fields.stage(source, entry)) do
      {:noreply, assign_example(socket, tree, session)}
    else
      _missing -> {:noreply, socket}
    end
  end

  # A REVIEW NOTE IS NOT A DOCUMENT CHANGE. Notes ride the session topic so both editors' sheets
  # follow each other, but the canvas has nothing to redraw for one — and re-reading the session
  # rebuilds the whole document, which the author sees as the page flashing every time anyone types
  # a comment. It is answered and ignored.
  def handle_info({:builder_session, _token, {:review, _what}}, socket), do: {:noreply, socket}

  # THE ONE MESSAGE THAT INVALIDATES THE PALETTE-DERIVED CACHES. `required_attrs` and the icon
  # defaults are read out of every component's every attribute, so they are computed once and kept;
  # this is the only event that can make them wrong, and it arrives exactly when `put_components/2`
  # writes a new list. Dropping the assigns lets `assign_new/3` below build them again.
  def handle_info({:builder_session, token, {:components, _count}}, socket) do
    case EditorSession.fetch(token) do
      {:ok, session} ->
        socket
        |> assign(:required_attrs, required_attrs(session.components))
        |> assign(:media_attrs, media_attrs(session.components))
        |> assign(:conceals, conceals(session.components))
        |> assign(:shapers, shapers(session.components))
        |> assign(:form_memo, %{})
        |> assign(:icon_defaults, icons_defaulted_by(session.components))
        |> sync_selection(socket.assigns[:selection], session)
        |> then(&{:noreply, &1})

      :error ->
        {:noreply, assign(socket, :missing?, true)}
    end
  end

  # THE PAGE WAS GIVEN ANOTHER LAYOUT in its settings, which are saved to the page and not to this
  # session — so the layout is read again rather than the document.
  def handle_info({:builder_session, token, {:layout, _layout_id}}, socket) do
    case EditorSession.fetch(token) do
      {:ok, session} -> {:noreply, assign_layout(socket, session)}
      :error -> {:noreply, assign(socket, :missing?, true)}
    end
  end

  def handle_info({:builder_session, token, _message}, socket) do
    case EditorSession.fetch(token) do
      {:ok, session} -> {:noreply, sync_selection(socket, socket.assigns[:selection], session)}
      :error -> {:noreply, assign(socket, :missing?, true)}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # The ring is drawn by the hook on the click itself, so the only selections that have to travel are
  # the ones made somewhere else — the layers rail, a comment's deep link, an undo that moved it.
  #
  # The PREVIOUS selection has to be read before the session is assigned. Comparing afterwards means
  # comparing the new value with itself, which is never a change, so the push never fired and a click
  # in the layers rail highlighted the row without moving the ring on the canvas.
  # ALWAYS PUSHED, even when the selection did not change. It used to skip an unchanged one as an
  # optimisation, and that is exactly the case a review note hits: click a note about the element
  # that is already selected in the session, and the client — which owns the ring, and may never
  # have been told about that selection at all — was told nothing again. The ring stayed off, and
  # the toolbar with it. A push_event is a few bytes; a selection nobody can see is a bug.
  # THE MARKS TRAVEL THE SAME WAY THE SELECTION DOES — as an id list the hook paints, never as
  # per-node markup. Rendering `data-marked` on every node would re-render the whole document on
  # every ⌘-click, which is the trap the selection ring already sidesteps.
  defp sync_selection(socket, _previous, %{selection: selection} = session) do
    socket
    |> assign_session(session)
    |> push_event("pb:selected", %{id: selection})
    |> push_event("pb:marked", %{ids: MapSet.to_list(session.marked || MapSet.new())})
  end

  @impl true
  # PREVIEW ANSWERS ONE EVENT: the way out of it. Every other event here belongs to editing, and the
  # bindings that send them do not go away when editing does — a node's wrapper keeps its
  # `phx-click="select"`, and a live component drawn cold keeps its own `phx-click` with the
  # `phx-target` rendered away, so its click arrives HERE under the component's own event name. The
  # blog kit's pager says "page" and nothing matches it; a kit button that said "drop" or "toolbar"
  # would have edited the document with editing off. Refusing by mode rather than by name closes
  # that for every event name, including ones no kit has written yet.
  def handle_event(event, _params, %{assigns: %{preview?: true}} = socket)
      when event != "leave_preview",
      do: {:noreply, socket}

  # While a palette component is armed, a click on the page PLACES it rather than selecting: that is
  # what the empty-page placeholder's "click here to place it" promises.
  # THE PROP TRAVELS WITH THE CLICK. A component that cannot render without a value shows a
  # placeholder saying which one, and until now that placeholder only selected the node: the author
  # landed on an eighteen-row Inspector with nothing marked and had to find `src` or `name`
  # themselves. The attribute is right there in the sentence they clicked, so it goes with them —
  # and for the two that have a chooser, the chooser opens.
  def handle_event("select", params, socket) when is_map(params) do
    place_or_select(socket.assigns.placing, params["id"], params["prop"], socket)
  end

  # LEAVING PREVIEW IS THE CHROME'S DECISION, not this frame's — the button that turns it on lives up
  # there. Posted up the same way a shortcut is, which is a channel that already exists and already
  # toggles preview, rather than a second route that would have to be kept in step with it.
  def handle_event("leave_preview", _params, socket),
    do: {:noreply, push_event(socket, "pb:leave-preview", %{})}

  # ⌘-click. The session holds the marks, so the chrome's bar and this frame's outlines are the same
  # answer arriving at two subscribers rather than two ideas of what is held.
  def handle_event("mark", %{"id" => node_id}, socket) when is_binary(node_id) do
    EditorSession.mark(socket.assigns.token, node_id)
    {:noreply, socket}
  end

  # FROM SCRATCH IS STILL A STARTING POINT. It used to place whatever was armed in the palette — and
  # nothing at all when nothing was, which is the state a reader who has not picked anything is in.
  # It lays down one `<main>` with a height worth aiming at, and the page is buildable.
  def handle_event("starter_scratch", _params, socket) do
    place_starter(socket, %{template: PageStarter.scratch()})
    {:noreply, socket}
  end

  # PICKING A STARTER IS AN ORDINARY INSERT, so it undoes, redoes, saves and broadcasts like anything
  # else the author does. The id is resolved against the SAME merged list the chooser drew, seed and
  # all: resolving it in the core's four alone made an extension's card a button that did nothing,
  # with no error and no flash to say why. `nil` is left for a genuinely stale id — a frame from
  # before a deploy should not take the canvas down.
  def handle_event("page_starter", %{"structure" => id}, socket) do
    case Events.fetch(:page_starters, PageStarter.all(), id) do
      nil ->
        {:noreply, socket}

      structure ->
        place_starter(socket, structure)
        {:noreply, socket}
    end
  end

  # WHAT ARRIVES HERE IS TYPING, NOT SOURCE. The box is `contenteditable="plaintext-only"` and the
  # hook pushes `textContent`, so the three characters that mean something to HTML arrive as the
  # characters the author pressed — and were written into the template as markup. Typing
  # `Fish & Chips <b>bold</b>` into a paragraph put a real `<b>` element in the document and a bare
  # `&` beside it; the same keystrokes could have put a `<script>` on a published page.
  #
  # Escaping them here is what makes `plaintext-only` true all the way down: the run round-trips as
  # the characters typed, and `text_html/1` shows them again unchanged. The code drawer's own path
  # into `:set_text` is NOT this one — there the text is already source, and is left alone.
  def handle_event("set_text", %{"id" => id, "text" => text}, socket) do
    EditorSession.apply_op(socket.assigns.token, %{
      kind: :set_text,
      node_id: id,
      text: escape_typed(text)
    })

    {:noreply, socket}
  end

  # WHICH SCREEN THE PANEL IS EDITING. Server state, because it decides what every swatch shows as
  # chosen — a client-side toggle would have to know the node's own overrides to do that.
  def handle_event("set_bucket", params, socket),
    do: {:noreply, assign(socket, :bucket, bucket_name(params["value"]))}

  # ONE HANDLER FOR EVERY LAYOUT CHOICE. It writes the same `:set_style` op the Inspector writes,
  # into the bucket the panel says it is editing, and `Styles` turns the pair into a Tailwind class
  # with the right responsive prefix. Nothing here knows what that class is.
  #
  # Pressing the chosen one again clears it, so an element can go back to inheriting rather than
  # being stuck with the first thing the reader tried.
  def handle_event("set_style_prop", %{"prop" => prop} = params, socket) do
    %{selection: id, tree: tree, bucket: bucket} = socket.assigns
    value = params["value"]
    value = if style_value(tree, id, bucket, prop) == value, do: "", else: value

    write_style(socket, prop, value)
  end

  def handle_event("set_cols", %{"name" => name} = params, socket) do
    op = %{
      kind: :set_attr,
      node_id: socket.assigns.selection,
      name: name,
      value: params["value"],
      value_kind: "string"
    }

    case socket.assigns.selection && EditorSession.apply_op(socket.assigns.token, op) do
      {:error, reason} ->
        {:noreply, push_event(socket, "pb:drop-rejected", %{message: message(reason)})}

      _applied ->
        {:noreply, socket}
    end
  end

  def handle_event("toolbar", %{"action" => action}, socket) when action in ~w(ask_ai comment) do
    {:noreply, push_event(socket, "pb:open-rail", %{action: action})}
  end

  def handle_event("toolbar", %{"action" => "duplicate"}, socket),
    do: toolbar_op(socket, :duplicate)

  def handle_event("toolbar", %{"action" => "delete"}, socket),
    do: toolbar_op(socket, :delete)

  # The layout panel is client state: the bar grows on the browser's side and this button pushes
  # nothing at all. Answered here anyway so that all five of the core's own keys are answered by the
  # core, which is what lets the clause below treat every key that is left as a plugin's.
  def handle_event("toolbar", %{"action" => "layout"}, socket), do: {:noreply, socket}

  # Selects the form the selection sits in, whatever inside it was clicked.
  def handle_event("toolbar", %{"action" => "form"}, socket) do
    case owning_form(socket.assigns.tree, socket.assigns.selection, socket.assigns.components) do
      %Node{id: id} -> {:ok, _session} = EditorSession.select(socket.assigns.token, id, :canvas)
      nil -> :none
    end

    {:noreply, socket}
  end

  # THE TOOLBAR IS AN OPEN REGISTRY, so "anything that is not delete" could not mean "duplicate".
  # It did, and every action an extension contributed pushed a copy of the selected element into the
  # document — a real undo step, autosaved — while the plugin that put the button there was never
  # called. A toolbar descriptor has no `run` dispatch to extend (that belongs to
  # `builder:interactions`), so a contributed key is handed back through an announcement instead.
  #
  # ONLY A KEY THE REGISTRY OFFERED. The buttons are drawn from this same list, so a key that is not
  # in it was forged or replayed, and announcing it would tell every plugin that something nobody
  # registered had been pressed. Logged and dropped rather than raised on: this is the canvas, and
  # the rule the catch-all below states holds for this event too — killing the iframe over a press
  # the browser made up reads as the editor loading itself over and over.
  def handle_event("toolbar", %{"action" => action}, socket) do
    if Enum.any?(socket.assigns.toolbar, &(Descriptor.key(&1) == action)) do
      Events.toolbar_invoked(%{
        action: action,
        node_id: socket.assigns.selection,
        token: socket.assigns.token
      })
    else
      Logger.warning("[Builder] no toolbar action is registered as #{inspect(action)}")
    end

    {:noreply, socket}
  end

  # Answered once, when the drag STARTS: the whole tree's verdict for this one thing being dragged, so
  # the blue line is a local lookup for the rest of the gesture. See `EditorSession.drop_hints/2`.
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

  def handle_event("drop", params, socket) do
    case EditorSession.apply_drop(socket.assigns.token, params) do
      {:ok, _session} ->
        {:noreply, socket}

      {:relocated, _session, note} ->
        {:noreply, push_event(socket, "pb:drop-moved", %{message: note})}

      {:error, reason} ->
        {:noreply, push_event(socket, "pb:drop-rejected", %{message: message(reason)})}
    end
  end

  # An unknown event is ignored rather than crashing the LiveView. This is not defensive padding: a
  # browser holding a stale JS bundle keeps pushing events this version no longer handles, and without
  # this clause each one kills the canvas process and the iframe reloads — which looks exactly like
  # the editor loading itself over and over.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp place_or_select(nil, id, prop, socket) do
    {:ok, _session} = EditorSession.select(socket.assigns.token, id, origin(prop))
    {:noreply, socket}
  end

  defp place_or_select(placing, id, _prop, socket), do: place_or_select(placing, id, socket)

  # `:canvas` when the click named no attribute, so every existing reader keeps matching on the atom
  # it has always matched on; the pair only when the placeholder said which value is missing.
  defp origin(prop) when is_binary(prop) and prop != "", do: {:canvas, prop}
  defp origin(_prop), do: :canvas

  defp place_or_select(_placing, id, socket) do
    case EditorSession.place_at(socket.assigns.token, id) do
      {:ok, _session} ->
        {:noreply, socket}

      {:relocated, _session, note} ->
        {:noreply, push_event(socket, "pb:drop-moved", %{message: note})}

      {:error, :nothing_picked} ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, push_event(socket, "pb:drop-rejected", %{message: message(reason)})}
    end
  end

  defp write_style(%{assigns: %{selection: nil}} = socket, _prop, _value), do: {:noreply, socket}

  defp write_style(socket, prop, value) do
    op = %{
      kind: :set_style,
      node_id: socket.assigns.selection,
      bucket: socket.assigns.bucket,
      prop: prop,
      value: value
    }

    case EditorSession.apply_op(socket.assigns.token, op) do
      {:error, reason} ->
        {:noreply, push_event(socket, "pb:drop-rejected", %{message: message(reason)})}

      _applied ->
        {:noreply, socket}
    end
  end

  # A bucket arrives from a button and must name one this editor actually has.
  defp bucket_name(name) when name in ["base", "tablet", "mobile"], do: name
  defp bucket_name(_other), do: "base"

  # The core's own two toolbar buttons, which are both ops on the selected element.
  defp toolbar_op(socket, kind) do
    op = %{kind: kind, node_id: socket.assigns.selection}

    case socket.assigns.selection && EditorSession.apply_op(socket.assigns.token, op) do
      {:error, reason} ->
        {:noreply, push_event(socket, "pb:drop-rejected", %{message: message(reason)})}

      _applied ->
        {:noreply, socket}
    end
  end

  defp message(reason) when is_binary(reason), do: reason
  defp message(_reason), do: gettext("That change could not be applied.")

  @impl true
  def render(%{missing?: :example} = assigns) do
    ~H"""
    <.canvas_notice
      nonce={assigns[:csp_nonce]}
      message={gettext("This example is no longer available.")}
    />
    """
  end

  def render(%{missing?: :forbidden} = assigns) do
    ~H"""
    <.canvas_notice
      nonce={assigns[:csp_nonce]}
      message={
        gettext(
          "This editing session belongs to another site. Open the document from your own list to edit it."
        )
      }
    />
    """
  end

  def render(%{missing?: :no_builder} = assigns) do
    ~H"""
    <.canvas_notice
      nonce={assigns[:csp_nonce]}
      message={gettext("You do not have permission to open this builder.")}
    />
    """
  end

  def render(%{missing?: true} = assigns) do
    ~H"""
    <.canvas_notice
      nonce={assigns[:csp_nonce]}
      message={
        gettext("This editing session has expired. Reopen the page from the builder to continue.")
      }
    />
    """
  end

  def render(assigns) do
    ~H"""
    <%!-- The editor's own rules for inside the frame. The hover outline lives here rather than in a
          computed inline style so that moving the pointer costs nothing: no event, no round trip, no
          re-render. The selection ring stays server-side because the server has to know the selection
          anyway. --%>
    <style :if={!@preview?} id="pb-canvas-chrome" nonce={assigns[:csp_nonce]}>
      [data-node-id]:hover { outline: 1px dashed #a5b4e8; outline-offset: 1px; }
      [data-node-id][data-selected="true"] { outline: 2px dashed #3a6cf4; outline-offset: 1px; }
      [data-node-id][data-selected="true"]:hover { outline: 2px dashed #3a6cf4; }
      /* Held with ⌘, alongside the one selection. Solid rather than dashed so the element being
         edited is still tellable from the ones going along with it. */
      [data-node-id][data-marked="true"] { outline: 2px solid #8580d8; outline-offset: 1px; }
      [data-node-id] [data-node-id]:hover { outline-color: #c3c1f0; }
      /* HIDDEN FROM VISITORS: kept in the page, left out of what a visitor gets. Faded and grey, and
         outlined while the hover and selection rings are not using the outline. One inside another
         is not faded twice. */
      [data-pb-hidden] { opacity: .38; filter: grayscale(1); }
      [data-pb-hidden] [data-pb-hidden] { opacity: 1; }
      [data-pb-hidden]:not([data-selected="true"]):not(:hover) { outline: 1px dashed #b4b1c8; outline-offset: 2px; }
      /* A field is being dragged: every form it could join is outlined until the drag ends. */
      html[data-pb-field-drag] [data-pb-form] { outline: 2px dashed #8b5cf6; outline-offset: 3px; }

      /* AN OVERLAY OPENS WHEN IT IS SELECTED, AND SHUTS WHEN THE SELECTION MOVES ON.

         Fourteen kit components render their content closed, and every one of them used to be held
         open for the whole session: a page with a dialog, a drawer and a dropdown on it drew all
         three over the content they belong to, permanently, and the author had no way to see the
         page. Selection is the answer every editor of this kind arrives at — clicking the thing you
         mean to edit is already the gesture, so opening it costs no second one.

         `data-selected` is painted by the canvas hook on the click itself, which is why this is CSS
         and not an assign: threading the selection through every node would re-render the whole
         document on every click, which is the trap the selection ring already sidesteps. `:has()`
         is what keeps it open while something INSIDE it is selected — a heading in a dialog is the
         author editing the dialog.

         `data-pb-reveal` is the third way in: the pin on the layers row, for the one case selection
         cannot express — keeping an overlay open while working on the page behind it.

         Each rule reaches DOWN, because none of this lands on the element the canvas wraps:
         `data-pb-overlay` is on the wrapper, the `hidden` is on the component's own root a level
         down and the `fixed` backdrop a level below that. `!important` because what is being beaten
         is a utility class, and no selector out-specifies a class from a rule that is not one.

         A node whose own root is a `<td>` or an `<option>` has no wrapper — see `component_frame/1`
         — so for it the two would be the same element and the rule would reach past what it means
         to open. No kit ships a component that is both concealed and stamped, and
         `MishkaCmsCoreWeb.Test.TableCellCanvasTest` is what says so.

         `.fixed` is neutralised rather than left alone: a dialog pins itself to the viewport, which
         is right for a dialog and wrong for something being edited in place — it would cover the
         page it belongs to. `aria-hidden` is the kit's own marker for its scrim, and an author is
         editing the content, not the overlay.

         AND ONLY `.fixed`. `.absolute` was swept in with it and is not the same thing: pinning to
         the VIEWPORT is what covers the page, while absolute positioning is ordinary layout inside
         the component's own box. A carousel is in this set, so selecting one un-positioned its own
         prev and next buttons and both fell into a heap in the top-left corner — reported as "the
         next and prev button is not obvious how they are and where they are".

         PREVIEW NEVER GETS THIS: the whole `<style>` is inside `:if={!@preview?}`, so a visitor sees
         the component close itself exactly as its author intended. */
      :is(
        [data-pb-reveal="true"],
        [data-pb-overlay][data-selected="true"],
        [data-pb-overlay]:has([data-selected="true"])
      ) :is(.hidden, .invisible, .opacity-0, .max-h-0, [hidden]) {
        display: block !important;
        visibility: visible !important;
        opacity: 1 !important;
        max-height: none !important;
        pointer-events: auto !important;
      }

      :is(
        [data-pb-reveal="true"],
        [data-pb-overlay][data-selected="true"],
        [data-pb-overlay]:has([data-selected="true"])
      ) .fixed { position: static !important; transform: none !important; }

      :is(
        [data-pb-reveal="true"],
        [data-pb-overlay][data-selected="true"],
        [data-pb-overlay]:has([data-selected="true"])
      ) [data-floating-content] { visibility: visible !important; opacity: 1 !important; }

      /* THE SCRIM GOES, THE PANEL STAYS. A modal's backdrop, a drawer's overlay and a scroll area's
         two scrollbars are all `aria-hidden` and all decorative — none holds a node an author put
         there — so hiding them while the overlay is open is right. A dropdown's and a popover's
         CONTENT is `aria-hidden` too while shut, and it is the one thing the author came to fill:
         this rule was hiding the panel the reveal above had just opened, which is why a dropdown
         showed its trigger and nothing else and read as "we cannot add any content inside". */
      :is(
        [data-pb-reveal="true"],
        [data-pb-overlay][data-selected="true"],
        [data-pb-overlay]:has([data-selected="true"])
      ) [aria-hidden="true"]:not([data-floating-content]):not(:has([data-node-id])) {
        display: none !important;
      }

      :is(
        [data-pb-reveal="true"],
        [data-pb-overlay][data-selected="true"],
        [data-pb-overlay]:has([data-selected="true"])
      ) { outline: 2px dotted #8580d8; outline-offset: 3px; }

      /* AND WHILE IT IS SHUT IT IS STILL SOMETHING ON THE PAGE, so it says what it is rather than
         collapsing to nothing. A dialog's root is `display:none`, so a closed one occupies no space
         at all: the author dropped a modal, watched it vanish, and had nothing left to click. The
         chip is what they click.

         `attr()` rather than markup, for the same reason the empty-dialog label below is: what is
         inside the wrapper belongs to the COMPONENT, and the editor's words have no business in
         somebody's dialog. */
      [data-pb-overlay] {
        position: relative;
        display: block;
        min-height: 32px;
      }

      [data-pb-overlay]::before {
        display: flex;
        align-items: center;
        height: 32px;
        padding: 0 11px;
        border: 1px dashed #c3c1f0;
        border-radius: 9px;
        background: #faf9ff;
        color: #6c67c9;
        font: 600 11.5px ui-sans-serif, system-ui;
        letter-spacing: .01em;
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
      }

      :is(
        [data-pb-reveal="true"],
        [data-pb-overlay][data-selected="true"],
        [data-pb-overlay]:has([data-selected="true"])
      )::before { display: none; }

      :is(
        [data-pb-reveal="true"],
        [data-pb-overlay][data-selected="true"],
        [data-pb-overlay]:has([data-selected="true"])
      ) { min-height: 0; }

      /* AND ONE WITH NOTHING IN IT SAYS WHAT IT IS AND ASKS FOR SOMETHING. Revealing an empty dialog
         reveals a few pixels of the kit's own padding, which is not a target anybody can hit — so
         the wrapper is given a real height and its own words. `attr()` rather than markup: what is
         inside the wrapper is the component's, and this is the editor talking. */
      :is(
        [data-pb-reveal="true"],
        [data-pb-overlay][data-selected="true"],
        [data-pb-overlay]:has([data-selected="true"])
      )[data-pb-hollow] {
        position: relative;
        min-height: 140px;
        border: 2px dashed #c3c1f0;
        border-radius: 12px;
        background: #faf9ff;
      }

      :is(
        [data-pb-reveal="true"],
        [data-pb-overlay][data-selected="true"],
        [data-pb-overlay]:has([data-selected="true"])
      )[data-pb-hollow]::after {
        position: absolute;
        inset: 0;
        display: flex;
        align-items: center;
        justify-content: center;
        color: #6c67c9;
        font: 600 12.5px ui-sans-serif, system-ui;
        letter-spacing: .01em;
        pointer-events: none;
      }

      /* A LIVE COMPONENT SAYS WHAT IT IS, where the pointer is. It is drawn with real data and
         looks like any other markup, so without this the only place that said it runs on the
         published page — and nowhere in this frame — was a badge in the Inspector.

         `::after`, because `::before` is the overlay chip's and a component can be both. The two
         other `::after` labels a wrapper can carry — an empty overlay's and the media well's — win
         over this one, and `live_label/1` is where: it leaves `data-pb-live` off a wrapper that has
         either, so the chip never merges into a box already drawing its own sentence.

         `position: relative` always rather than only on hover: switched on under the pointer it
         would move whatever inside the component is absolutely positioned, every time the pointer
         crossed it. `data-pb-live` is only ever on the editor's own wrapper — see `live_label/1`. */
      [data-pb-live] { position: relative; }

      :is([data-pb-live]:hover, [data-pb-live][data-selected="true"])::after {
        position: absolute;
        top: 6px;
        right: 6px;
        z-index: 2147483646;
        max-width: calc(100% - 12px);
        padding: 3px 8px;
        border-radius: 999px;
        background: #4f4bcc;
        color: #fff;
        font: 700 10.5px ui-sans-serif, system-ui;
        letter-spacing: .01em;
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
        pointer-events: none;
      }

      /* THE CHOOSER ON AN EMPTY PAGE. Every selector below is anchored to an id, so it outranks the
         site's own compiled utilities whatever they are — an author's stylesheet shares this
         document, and a `style` attribute used to be what kept the chrome out of its way. */
      #pb-page-starter { display: flex; align-items: center; justify-content: center; min-height: 70vh; padding: 24px; }
      #pb-page-starter-card { width: 100%; max-width: 560px; border: 1px solid #e6e4de; border-radius: 18px; background: #fff; box-shadow: 0 6px 26px rgba(30,28,24,.08); overflow: hidden; }
      #pb-page-starter-head { padding: 20px 22px 16px; border-bottom: 1px solid #f0efea; }
      #pb-page-starter-title { font: 700 16px system-ui; color: #17161a; }
      #pb-page-starter-hint { margin-top: 4px; font: 500 12.5px system-ui; color: #6d6a63; }
      #pb-page-starter-grid { display: grid; grid-template-columns: repeat(2,minmax(0,1fr)); gap: 12px; padding: 18px 22px; }
      #pb-page-starter [data-pb-starter] { display: block; padding: 0; border: 1px solid #ecebe6; border-radius: 12px; background: #fff; cursor: pointer; text-align: left; overflow: hidden; }
      #pb-page-starter [data-pb-preview] { display: flex; gap: 5px; align-items: stretch; height: 74px; padding: 10px; background: #faf9f6; }
      #pb-page-starter [data-pb-preview="hero"] { flex-direction: column; }
      #pb-page-starter [data-pb-column] { flex: 1; border-radius: 5px; background: #e0ded7; }
      #pb-page-starter [data-pb-column="hero"] { min-height: 18px; }
      #pb-page-starter [data-pb-body] { display: block; padding: 9px 11px 11px; }
      #pb-page-starter [data-pb-name] { display: block; font: 700 12px system-ui; color: #2e2b6b; }
      #pb-page-starter [data-pb-desc] { display: block; margin-top: 2px; font: 500 10.5px system-ui; color: #8a877f; }
      #pb-page-starter-foot { display: flex; align-items: center; gap: 8px; padding: 13px 22px; border-top: 1px solid #f0efea; background: #faf9f6; }
      #pb-page-starter-note { flex: 1; font: 500 11px system-ui; color: #8a877f; }
      #pb-starter-scratch { padding: 6px 12px; border: 1px solid #ecebe6; border-radius: 9px; background: #fff; color: #5c5a54; font: 700 11px system-ui; cursor: pointer; }

      /* ROOM FOR THE BAR ABOVE WHAT IT NAMES. `placeToolbar` keeps the bar on the selection's top
         edge — 6px above it, never closer than 4px to the top of the frame, and as tall as the row
         below — so anything that starts less than that far down gets the bar pinned ON it. On a
         16px stage that was the first element of every document: selecting the `<div>` around
         `{@size}` put the bar over the chip, and the double click meant for the expression pressed
         the bar instead, in all four builders and for the words of a first heading alike. The stage
         keeps the band clear, and a selection scrolled into view stops the same distance short of
         the top edge, so neither leaves an element under its own bar.

         The attribute is what outranks `#pb-canvas-ui`'s `padding: 16px`, which comes later in the
         document. */
      #pb-canvas-root[data-preview="false"] { padding-top: calc(4px + 26px + 6px); }
      html { scroll-padding-top: calc(4px + 26px + 6px); }

      /* THE FLOATING ELEMENT TOOLBAR. `display: none` is the state the hook toggles: it writes
         `bar.style.display` and `bar.style.left/top` through the CSSOM, which no `style-src`
         governs, so an inline value still wins over these rules exactly as it did over the
         attribute they replace. */
      #pb-el-toolbar { position: fixed; inset: auto; margin: 0; padding: 0; border: 0; z-index: 2147483647; display: none; flex-direction: column; width: max-content; border-radius: 9px; background: #17161a; box-shadow: 0 6px 20px rgba(20,18,26,.34); overflow: hidden; }
      #pb-el-toolbar-row { display: flex; align-items: stretch; height: 26px; }
      #pb-el-grip { display: inline-flex; align-items: center; gap: 7px; padding: 0 10px; cursor: grab; color: #8b8995; }
      #pb-el-grip-name { font: 700 10.5px 'Space Grotesk'; letter-spacing: .02em; color: #fff; }
      #pb-el-grip-count { font: 600 9px 'Space Grotesk'; color: #a3a1ad; }
      #pb-el-toolbar [data-pb-action] { display: contents; }
      #pb-el-toolbar [data-pb-rule] { width: 1px; background: #2e2c33; flex: none; }
      #pb-el-toolbar [data-pb-tb="primary"] { display: inline-flex; align-items: center; gap: 6px; padding: 0 11px; border: none; background: linear-gradient(140deg,#6d69e6,#4f4bcc); color: #fff; font: 700 10px Manrope; cursor: pointer; }
      #pb-el-toolbar [data-pb-tb="labelled"] { display: inline-flex; align-items: center; gap: 5px; padding: 0 10px; border: none; background: none; color: #8b8995; font: 700 10px Manrope; cursor: pointer; }
      #pb-el-toolbar [data-pb-tb="glyph"] { display: flex; align-items: center; justify-content: center; width: 30px; border: none; background: none; color: #8b8995; cursor: pointer; }

      /* THE LAYOUT PANEL. `display: none` here is toggled by the hook too, for the same reason. The
         "chosen" variant of each control repeats only the declarations that differ, so a swatch and
         its lit twin cannot drift apart. */
      #pb-eltb-cols { display: none; flex-direction: column; gap: 6px; padding: 8px; border-top: 1px solid #2e2c33; width: 246px; }
      #pb-eltb-at { display: flex; align-items: center; gap: 5px; }
      #pb-eltb-at-label { flex: 1; font: 700 8.5px Manrope; letter-spacing: .09em; text-transform: uppercase; color: #8b8995; }
      #pb-eltb-gap { display: flex; align-items: center; gap: 6px; }
      #pb-eltb-columns { display: flex; align-items: center; gap: 4px; flex-wrap: wrap; }
      #pb-eltb-cols [data-pb-label] { width: 52px; font: 600 9.5px Manrope; color: #8b8995; }
      #pb-eltb-cols [data-pb-label="row"] { flex: none; }
      #pb-eltb-cols [data-pb-row] { display: flex; align-items: center; gap: 4px; }
      #pb-eltb-cols [data-pb-bucket] { padding: 2px 7px; border: 0; border-radius: 5px; background: #26252c; color: #8b8995; font: 700 9px Manrope; cursor: pointer; }
      #pb-eltb-cols [data-pb-bucket="true"] { background: #6d69e6; color: #fff; }
      #pb-eltb-cols [data-pb-chip] { padding: 2px 8px; border: 1px solid #37353f; border-radius: 5px; background: #201f26; color: #8b8995; font: 700 9px Manrope; cursor: pointer; }
      #pb-eltb-cols [data-pb-chip="true"] { border-color: #6d69e6; background: #2b2952; color: #fff; }
      #pb-eltb-cols [data-pb-colbtn] { display: flex; gap: 2px; height: 18px; padding: 3px; border: 1px solid #37353f; border-radius: 5px; background: #201f26; cursor: pointer; }
      #pb-eltb-cols [data-pb-colbar] { flex: 1; border-radius: 2px; background: #8b8995; }
      #pb-eltb-cols [data-pb-swatch] { display: flex; width: 26px; height: 18px; padding: 3px; border: 1px solid #37353f; border-radius: 5px; background: #201f26; cursor: pointer; flex: none; }
      #pb-eltb-cols [data-pb-swatch="true"] { border-color: #6d69e6; background: #2b2952; }
      #pb-eltb-cols [data-pb-demo] { gap: 1.5px; width: 100%; height: 100%; }
      /* Four 9px bars cannot fit a 20px swatch, which is the point: `nowrap` runs them off the edge
         and `wrap` breaks them onto a second line. Without the clip the overflow spills over the
         border. */
      #pb-eltb-cols [data-pb-demo][data-pb-prop="wrap"] { align-content: flex-start; overflow: hidden; }
      /* The FIRST bar is brighter, which is the only way a reader can tell `row` from `row-reverse`
         in a picture: it shows where the children start. A bar that GROWS cannot show spacing, so
         Spread and Wrap keep their width and let the FREE SPACE move; Align uses `min-height` rather
         than `height` so `stretch` can still fill. */
      #pb-eltb-cols [data-pb-bar] { border-radius: 1.5px; background: #6f6d79; }
      #pb-eltb-cols [data-pb-bar]:first-child { background: #c9c7d4; }
      #pb-eltb-cols [data-pb-bar="display"], #pb-eltb-cols [data-pb-bar="direction"] { flex: 1; min-height: 3px; }
      #pb-eltb-cols [data-pb-bar="justify"] { flex: none; width: 5px; }
      #pb-eltb-cols [data-pb-bar="align"] { flex: none; width: 5px; }
      #pb-eltb-cols [data-pb-bar="align"]:nth-child(1) { min-height: 5px; }
      #pb-eltb-cols [data-pb-bar="align"]:nth-child(2) { min-height: 9px; }
      #pb-eltb-cols [data-pb-bar="align"]:nth-child(3) { min-height: 13px; }
      /* A wrapped line is only as tall as what is in it, and a bar with no height is nothing — the
         second row rendered at zero pixels and `wrap` looked like an empty box. */
      #pb-eltb-cols [data-pb-bar="wrap"] { flex: none; width: 9px; height: 6px; }
      <%= style_body(panel_rules()) %>
      <%= style_body(chrome_words()) %>
    </style>

    <%!-- Scrollbars are hidden inside the frame the way they are in the prototype. In the
          side-by-side view three of them would sit across the row at 30% scale, and a scrollbar drawn
          at that size reads as a rendering fault rather than an affordance. --%>
    <style id="pb-canvas-scroll" nonce={assigns[:csp_nonce]}>
      /* The UA's default 8px body margin makes the document permanently taller than its own
         viewport, so a frame sized to the content still reports a scroll it does not have. */
      body { margin: 0; }
      html { scrollbar-width: none; }
      html::-webkit-scrollbar, body::-webkit-scrollbar { width: 0; height: 0; }
    </style>

    <%!-- The chrome that Preview keeps. `#pb-canvas-chrome` above is switched off there — hover
          outlines and the chooser are editing affordances — but the stage itself, the empty-page
          well, the expression chip and the two placeholders are drawn in both modes, so their rules
          cannot live in a block that disappears. --%>
    <style id="pb-canvas-ui" nonce={assigns[:csp_nonce]}>
      #pb-canvas-root { box-sizing: border-box; min-height: 100vh; margin: 0; padding: 16px; }
      /* An example is one component on an empty sheet, so it sits in the middle of the stage rather
         than pinned to the top — the prototype centres its mock the same way. */
      #pb-canvas-root[data-example="true"] { display: flex; flex-direction: column; justify-content: center; }
      /* The page's layout is drawn, not used: only the page inside it answers the pointer. */
      #pb-layout-shell { pointer-events: none; }
      #pb-layout-slot { pointer-events: auto; }
      /* Indentation is a tree node: it stays in the DOM because the drop resolver counts DOM children
         to work out an insertion index, and `display: contents` is what keeps a grid or flex parent
         skipping it exactly as the published page does. A folded node keeps its place the same way
         and draws nothing. */
      #pb-canvas-root [data-ws="true"] { display: contents; }
      #pb-canvas-root [data-folded="true"] { display: none; }
      #pb-canvas-root [data-kind="text"]:not([data-ws]) { cursor: text; }
      #pb-canvas-root [data-pb-token] { display: inline-block; padding: 2px 8px; border-radius: 6px; background: #fbf1df; color: #a5691a; font: 600 11px ui-monospace,monospace; }
      /* `!important` reproduces where these declarations used to sit: appended AFTER the author's own
         `style` attribute, which is still rendered on the same element, so the placeholder has to win
         a clash the way it always did. Nothing writes these properties from JS. */
      #pb-canvas-root [data-incomplete="true"],
      #pb-canvas-root [data-render-error="true"] { display: block !important; padding: 10px 12px !important; border: 1px dashed #e4b8b8 !important; border-radius: 8px !important; background: #fdf6f6 !important; color: #a04141 !important; font: 500 12px ui-sans-serif,system-ui !important; }
      #pb-canvas-root [data-incomplete="true"] strong,
      #pb-canvas-root [data-render-error="true"] strong { font-weight: 700; }
      /* A COMPONENT WAITING FOR A PICTURE. `wants_media/1` puts the attribute's own name here, and
         `hollow_style/2` has already given the node the same 120px dashed well `el-image` gets — so
         all this adds is the sentence, and the sentence says what a click will do. `attr()` rather
         than a rendered label because the markup inside the wrapper belongs to the component, not to
         the editor: writing into it would put the editor's words inside somebody's avatar.

         `pointer-events: none` so the click lands on the wrapper, which carries `phx-value-prop` and
         opens the library on that attribute. `position: relative` only creates the containing block
         the label centres in; it does not move anything.

         Never in preview: `wants_media/1`'s first clause answers `nil` there, so the attribute this
         is keyed on is simply absent and the component renders as a visitor sees it. */
      #pb-canvas-root [data-wants-media] { position: relative; cursor: pointer; }
      #pb-canvas-root [data-wants-media]::after { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; gap: 6px; color: #8580d8; font: 600 12px ui-sans-serif,system-ui; letter-spacing: .01em; pointer-events: none; }
      #pb-canvas-empty { display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 8px; min-height: 60vh; border: 1.5px dashed #d9d7d0; border-radius: 16px; color: #8a877f; font: 500 13px system-ui; }
      #pb-canvas-empty-title { font: 700 15px system-ui; color: #5c5a54; }
      /* The preview bar sits ABOVE the page rather than over it: a visitor's view is what preview
         promises, and a floating strip covering the first band of the page is not that. It scrolls
         away with the document for the same reason. */
      #pb-preview-bar { display: flex; align-items: center; gap: 10px; margin: -16px -16px 16px; padding: 9px 16px; background: #1b1a18; color: #f6f5f2; font: 600 11.5px ui-sans-serif,system-ui; }
      #pb-preview-bar-text { flex: 1 1 auto; min-width: 0; }
      #pb-preview-bar-edit { flex: none; padding: 4px 10px; border: 0; border-radius: 8px; background: #f6f5f2; color: #1b1a18; font: 700 11px ui-sans-serif,system-ui; cursor: pointer; }
      #pb-preview-bar-edit:hover { background: #fff; }
      <%= style_body(ui_words()) %>
    </style>

    <%!-- The site's own compiled CSS, inlined rather than linked. This is the exception the house
          rule leaves open: it is not authored styling, it is the site's stylesheet delivered as data
          so the frame does not depend on that site being reachable.

          `<%= %>` rather than `{…}` in these three blocks is FORCED, not legacy: `<style>` is a
          raw-text element, and HEEx does not interpolate `{…}` inside one. Converting them empties
          the frame's stylesheet. --%>
    <%!-- LINKED, not inlined, whenever the compiled bundle has a content hash — and rendered in the
          root layout's `<head>`, not here. Here is `<body>`, which comes after the `<head>` the
          browser generator injects into, so the bundle overruled every class the editor generated.
          See the note beside the link in `root.html.heex`. --%>

    <%!-- The fallback, and the reason the inline path survives: a site that has never been compiled
          has bytes in `AssetsState` but no hash to address them by. --%>
    <style
      :if={@canvas_css_hrefs == [] and @canvas_css != ""}
      id="pb-canvas-css"
      nonce={assigns[:csp_nonce]}
    >
      <%= style_body(@canvas_css) %>
    </style>

    <%!-- The heroicon classes this document needs. The site's compiled stylesheet is generated from
          the classes its own pages RENDER, so a component's DEFAULT icon — which appears in no page's
          HTML — has no rule, and `chelekom-alert` drew an empty 28px box where its icon belongs.
          These are the plugin's own rules for the handful of icons actually in front of the reader,
          in the `components` layer so a size utility on an icon wins (`Icons.css/1`). --%>
    <style :if={@icon_css != ""} id="pb-canvas-icons" nonce={assigns[:csp_nonce]}>
      <%= style_body(@icon_css) %>
    </style>

    <%!-- ...and the kit's `@theme`, handed to Tailwind's browser generator so a class typed in the
          inspector resolves on the spot instead of after a recompile. --%>
    <style
      :if={@canvas_theme != ""}
      type="text/tailwindcss"
      id="pb-canvas-theme"
      nonce={assigns[:csp_nonce]}
    >
      <%= style_body(@canvas_theme) %>
    </style>

    <%!-- What an author wrote for one element, live. It is stored in a stylesheet row and reaches
          the published page through the compiler, which runs on save — so without this the editor
          would show the change one recompile late, which is the same as not showing it. Last in the
          document, and unlayered, because element CSS is meant to win. --%>
    <style
      :if={@element_css != ""}
      type="text/tailwindcss"
      id="pb-canvas-element-css"
      nonce={assigns[:csp_nonce]}
    >
      <%= style_body(@element_css) %>
    </style>

    <%!-- No `phx-click` on the root: a node's own click bubbles up here, and a deselect handler on
          the container would fire immediately after every selection and undo it. Clicking the
          background still deselects — the hook checks whether the click landed on a node first. --%>
    <div
      id="pb-canvas-root"
      phx-hook="PbCanvas"
      dir={@dir}
      data-token={@token}
      {%{"data-selection" => @selection}}
      data-preview={to_string(@preview?)}
      data-example={to_string(@example?)}
      data-revision={@revision}
    >
      <%!-- WHAT MODE THIS IS, SAID OUT LOUD. Preview looks exactly like the page — that is the whole
            point — which also means nothing on screen distinguishes it from editing until you try to
            change something and cannot. It says so, and it carries the way back.

            The frame is the canvas LiveView, not the chrome, so leaving is posted up to the editor —
            the same route the canvas toolbar's own buttons take.

            AND WHAT IT IS NOT. This is the unsaved document drawn without the editor, not a running
            page: there is no request behind it, live components are drawn cold and the site's own
            JS is not loaded, so a link, a pager or a sort button does nothing. "This is how a
            visitor sees the page" invited an author to click through it and conclude the page was
            broken. The saved draft's shareable link is the surface that runs one, so the bar names
            the menu entry that opens it, in that entry's own words — where the section has that
            entry at all, and under the document's own name rather than always "page".

            Not over an example or the wizard's options: neither is the author's page, and "Back to
            editing" there would toggle the editor's own preview from inside a modal. --%>
      <div :if={@preview? and !@example?} id="pb-preview-bar">
        <span id="pb-preview-bar-text">
          {gettext(
            "Preview — your unsaved %{section} as it looks. Links, paging and live components don't run here; %{hint}",
            section: label(@section),
            hint: click_through(@section)
          )}
        </span>
        <button type="button" id="pb-preview-bar-edit" phx-click="leave_preview">
          {gettext("Back to editing")}
        </button>
      </div>

      {raw(elem(@layout_shell, 0))}
      <.page_starter :if={PageStarter.empty?(@tree) and !@preview?} section={@section} />
      <%!-- Preview shows the plain dashed well: a chooser is an editing control, and Preview is
            supposed to be the page as a visitor gets it. --%>
      <div :if={@tree.roots == [] and @preview?} id="pb-canvas-empty">
        <span id="pb-canvas-empty-title">
          {gettext("This %{section} is empty", section: label(@section))}
        </span>
      </div>
      <.pb_node
        :for={id <- @tree.roots}
        id={id}
        tree={@tree}
        locked={@locked}
        hidden={@hidden}
        pinned={@pinned}
        preview?={@preview?}
        site_scope={@site_scope}
        required_attrs={@required_attrs}
        media_attrs={@media_attrs}
        conceals={@conceals}
        shapers={@shapers}
        form_marks={assigns[:form_marks]}
      />
      {raw(elem(@layout_shell, 1))}

      <%!-- One floating toolbar, positioned over the selection by the hook from its bounding box.
            Rendering it inside the selected node would need `position:relative` on the author's own
            element, which can silently change their layout.

            `popover` puts it in the browser's TOP LAYER, above every stacking context on the page.
            A z-index alone is not enough here: the document in this frame is the author's, and a
            sticky header or a modal of theirs with its own stacking context could paint over the one
            control that says what is selected. The top layer cannot be covered by page content. --%>
      <div :if={@selection && !@preview?} id="pb-el-toolbar" popover="manual">
        <div id="pb-el-toolbar-row">
          <%!-- The grip, the element's own name and its child count — the prototype's left cluster. It
              is the drag handle for the selection, which is why it carries the grab cursor. --%>
          <span id="pb-el-grip" draggable="true">
            <Panels.icon name={:grip} size={12} filled />
            <span id="pb-el-grip-name">{selection_label(@tree, @selection)}</span>
            <span :if={selection_count(@tree, @selection) > 0} id="pb-el-grip-count">
              {selection_count(@tree, @selection)}
            </span>
          </span>

          <span
            :for={action <- @toolbar}
            :if={offered?(action, @tree, @selection, @components)}
            data-pb-action="true"
          >
            <span data-pb-rule="true"></span>
            <button
              type="button"
              id={toolbar_id(action)}
              phx-click={(action.key != "layout" && "toolbar") || nil}
              phx-value-action={action.key}
              title={action.label}
              data-pb-tb={toolbar_kind(action)}
            >
              <Panels.icon name={toolbar_icon(action)} size={11} />{toolbar_label(action)}
            </button>
          </span>
        </div>

        <%!-- THE LAYOUT PANEL. Growing the bar keeps the hook's one positioning rule — a separate
              popover would need its own — and `overflow:hidden` on the container is what rounds it.

              OPENING IT IS CLIENT STATE. Asking the server to reveal a panel already on the page
              costs a patch of this element, and a patch takes back the `display` the hook wrote —
              the rule underneath says `none` — and drops it out of the top layer, so pressing the
              arrow made the whole toolbar vanish. The hook toggles it and re-applies the flag from
              `placeToolbar`; the server is asked only when a choice is made, because that writes to
              the document.

              EVERY CHOICE IS A PICTURE of what it does, not the Tailwind class it writes. The class
              is `Styles`' business — the same vocabulary the Inspector uses, so the two panels can
              never disagree, and the responsive prefix comes free from the bucket. --%>
        <div :if={styleable?(@tree, @selection)} id="pb-eltb-cols">
          <%!-- WHICH SCREEN AM I EDITING. It rides the panel rather than sitting in a section far
                above it, so the answer is never more than a glance away. --%>
          <div id="pb-eltb-at">
            <span id="pb-eltb-at-label">{gettext("Editing")}</span>
            <button
              :for={
                {bucket, label} <- [
                  {"base", gettext("Desktop")},
                  {"tablet", gettext("Tablet")},
                  {"mobile", gettext("Mobile")}
                ]
              }
              type="button"
              id={"pb-eltb-at-#{bucket}"}
              phx-click="set_bucket"
              value={bucket}
              title={gettext("Editing at %{device}", device: label)}
              data-pb-bucket={to_string(@bucket == bucket)}
            >
              {label}
            </button>
          </div>

          <.layout_row
            :for={row <- layout_rows(@tree, @selection, @components, @bucket)}
            row={row}
            bucket={@bucket}
          />

          <div id="pb-eltb-gap">
            <span data-pb-label="true">{gettext("Gap")}</span>
            <button
              :for={
                {value, key, label} <- [
                  {"", "0", "0"},
                  {"8px", "S", gettext("S")},
                  {"16px", "M", gettext("M")},
                  {"24px", "L", gettext("L")},
                  {"40px", "XL", gettext("XL")}
                ]
              }
              type="button"
              id={"pb-eltb-gap-#{key}"}
              phx-click="set_style_prop"
              phx-value-prop="gap"
              value={value}
              title={gettext("Space between children: %{size}", size: label)}
              data-pb-chip={to_string(style_value(@tree, @selection, @bucket, "gap") == value)}
            >
              {label}
            </button>
          </div>

          <div :if={column_values(@tree, @selection, @components) != []} id="pb-eltb-columns">
            <span data-pb-label="true">{gettext("Columns")}</span>
            <button
              :for={value <- column_values(@tree, @selection, @components)}
              type="button"
              id={"pb-eltb-cols-#{value}"}
              phx-click="set_cols"
              phx-value-name="cols"
              value={value}
              title={ngettext("%{count} column", "%{count} columns", column_bars(value))}
              data-pb-colbtn={column_bars(value)}
            >
              <span :for={_bar <- 1..column_bars(value)//1} data-pb-colbar="true"></span>
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :nonce, :string, default: nil
  attr :message, :string, required: true

  # The two dead ends this canvas can render. They come before the document does, so they carry a
  # `<style>` of their own rather than borrowing one of the six the main template emits — and it is
  # nonced, because `style-src-elem` refuses a `<style>` without one. `assigns[:csp_nonce]` is read
  # at the call site: a missing assign RAISES through `@`, and a canvas that raises on the "session
  # expired" path has nothing left to fall back to.
  defp canvas_notice(assigns) do
    ~H"""
    <style id="pb-canvas-notice" nonce={@nonce}>
      #pb-canvas-notice-text { font: 500 13px system-ui; color: #6d6a63; padding: 24px; }
    </style>
    <div id="pb-canvas-notice-text">{@message}</div>
    """
  end

  # Direction, alignment and wrapping only mean something once the container IS a flex row, so they
  # appear when it is and stay out of the way when it is not. A panel that offers a control which
  # cannot do anything is the thing this whole exercise is removing.
  defp layout_rows(tree, id, _components, bucket) do
    rows = [{"display", gettext("Layout")}]

    # THE EFFECTIVE VALUE, not the bucket's own. Tablet and Mobile inherit Desktop unless they
    # override it, so reading only the open bucket made Direction and its neighbours vanish the
    # moment you switched to Mobile — on an element that is plainly still a row on screen.
    rows =
      case style_value(tree, id, bucket, "display") || style_value(tree, id, "base", "display") do
        "flex" ->
          rows ++
            [
              {"direction", gettext("Direction")},
              {"justify", gettext("Spread")},
              {"align", gettext("Align")},
              {"wrap", gettext("Wrap")}
            ]

        _not_flex ->
          rows
      end

    for {prop, label} <- rows do
      %{
        prop: prop,
        label: label,
        current: style_value(tree, id, bucket, prop),
        options: Styles.pictures(prop)
      }
    end
  end

  attr :row, :map, required: true
  attr :bucket, :string, required: true

  defp layout_row(assigns) do
    ~H"""
    <div data-pb-row="true">
      <span data-pb-label="row">{@row.label}</span>
      <button
        :for={{value, title, _tailwind, _demo, bars} <- @row.options}
        type="button"
        id={"pb-eltb-#{@row.prop}-#{value}"}
        phx-click="set_style_prop"
        phx-value-prop={@row.prop}
        value={value}
        title={Gettext.gettext(MishkaCmsCore.Gettext, title)}
        aria-label={Gettext.gettext(MishkaCmsCore.Gettext, title)}
        aria-pressed={to_string(@row.current == value)}
        data-pb-swatch={to_string(@row.current == value)}
      >
        <span data-pb-demo={value} data-pb-prop={@row.prop}>
          <span :for={_index <- 1..bars//1} data-pb-bar={@row.prop}></span>
        </span>
      </button>
    </div>
    """
  end

  # The panel's rules that cannot be written out by hand, generated once into `#pb-canvas-chrome`.
  #
  # THE PICTURES ARE STILL `Styles`' ONE LIST. Each option demonstrates itself — the swatch for
  # `space-between` really is laid out `space-between` — and `Styles.pictures/1` carries that CSS
  # beside the Tailwind spelling the Inspector uses, so the two panels cannot drift. Copying the
  # twenty declarations into a stylesheet here would have started exactly the second list that
  # module's own note exists to prevent, so they are read from it instead and keyed on the value.
  #
  # A COLUMN SWATCH IS AS WIDE AS THE COUNT IT DRAWS, which is a per-row number rather than a fixed
  # one — so it is keyed on the count rather than written into an attribute. Twelve is the whole of
  # `column_bars/1`'s word vocabulary (`one` … `twelve`); a kit declaring a numeric count above that
  # draws its bars at the swatch's own content width.
  defp panel_rules do
    demos =
      for prop <- Styles.properties(),
          {value, _title, _tailwind, css, _bars} <- Styles.pictures(prop),
          into: "" do
        ~s|#pb-eltb-cols [data-pb-demo="#{value}"] { #{css} }\n|
      end

    for count <- 1..12, into: demos do
      ~s|#pb-eltb-cols [data-pb-colbtn="#{count}"] { width: #{10 + count * 5}px; }\n|
    end
  end

  @word_marker "␞"

  defp chrome_words do
    reveal =
      ~s|:is([data-pb-reveal="true"], [data-pb-overlay][data-selected="true"], | <>
        ~s|[data-pb-overlay]:has([data-selected="true"]))|

    """
    [data-pb-overlay]::before { content: #{css_content(gettext("%{name} — opens from its trigger", name: @word_marker), "data-pb-overlay")}; }
    #{reveal}[data-pb-hollow]::after { content: #{css_content(gettext("Empty %{name} — drop something in here", name: @word_marker), "data-pb-hollow")}; }
    :is([data-pb-live]:hover, [data-pb-live][data-selected="true"])::after { content: #{css_content(gettext("Live · %{name} — runs on the published page", name: @word_marker), "data-pb-live")}; }
    """
  end

  defp ui_words do
    """
    #pb-canvas-root [data-wants-media]::after { content: #{css_content(gettext("Choose %{name} — click to pick or upload", name: @word_marker), "data-wants-media")}; }
    """
  end

  defp css_content(translated, attribute) do
    translated
    |> String.split(@word_marker)
    |> Enum.map_join(" attr(#{attribute}) ", &css_string/1)
  end

  defp css_string(text) do
    escaped =
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\A ")

    ~s("#{escaped}")
  end

  # What the element is set to RIGHT NOW in the bucket being edited — nil when it inherits, so the
  # panel highlights nothing rather than lying about a value the author never chose.
  defp style_value(tree, id, bucket, prop) do
    with node when not is_nil(node) <- Tree.get(tree, id),
         styles when is_map(styles) <- node.meta[:styles],
         {:ok, bucket_key} <- Styles.bucket_atom(bucket),
         props when is_map(props) <- Map.get(styles, bucket_key) do
      Map.get(props, prop)
    else
      _unset -> nil
    end
  end

  # THE KIT'S OWN VOCABULARY, asked of `Inspector.widget/3` exactly as the Inspector's picker does, so
  # the toolbar can never offer a count the component would not render.
  #
  # ONE COMPONENT, AND ONLY WHEN THE ROW IS OPEN. The first version of this precomputed a map for
  # every installed component on every `assign_session/2` — 183 entries, each attribute re-parsing
  # the component's whole template and every helper through `Inspector.features/1`, on every
  # selection, every op and every broadcast. It made the canvas visibly slow to load and selection
  # laggy. The caller's `&&` short-circuits, so nothing here runs until the arrow is pressed.
  defp column_values(tree, id, components) do
    with node when not is_nil(node) <- Tree.get(tree, id),
         %{kind: :component} <- node,
         name when is_binary(name) <- Node.component_name(node),
         entry when not is_nil(entry) <- Enum.find(components, &(&1.name == name)) do
      features = Inspector.features(entry)

      Enum.find_value(Inspector.attrs(entry), [], fn attr ->
        case Inspector.widget(attr, features, entry) do
          {:columns, values} -> values
          _other -> nil
        end
      end)
    else
      _not_a_component -> []
    end
  end

  defp column_bars(value) do
    words = ~w(one two three four five six seven eight nine ten eleven twelve)

    case Integer.parse(to_string(value)) do
      {count, ""} when count > 0 -> count
      _word -> (Enum.find_index(words, &(&1 == to_string(value))) || 0) + 1
    end
  end

  defp selection_count(tree, id) do
    case Tree.get(tree, id) do
      nil -> 0
      node -> length(node.children)
    end
  end

  # The prototype's toolbar is not four identical icon buttons: Ask AI is a filled violet action, the
  # two labelled actions read as text, and duplicate and delete are bare 30px glyphs. Keeping that
  # distinction is what makes the primary action findable.
  @toolbar_labelled %{
    "ask_ai" => gettext_noop("Ask AI"),
    "comment" => gettext_noop("Comment"),
    "form" => gettext_noop("Form")
  }

  # Layout is for what can be styled; Form is for anything inside a form.
  defp offered?(%{key: "layout"}, tree, selection, _components), do: styleable?(tree, selection)

  defp offered?(%{key: "form"}, tree, selection, components),
    do: owning_form(tree, selection, components) != nil

  defp offered?(_action, _tree, _selection, _components), do: true

  defp owning_form(tree, selection, components) when is_binary(selection),
    do: FormPlacement.form_of(tree, Tree.get(tree, selection), components)

  defp owning_form(_tree, _selection, _components), do: nil

  defp toolbar_id(%{key: "form"}), do: "pb-toolbar-form"
  defp toolbar_id(action), do: "pb-eltb-#{action.key}"

  @toolbar_icons %{
    "form" => :layers,
    "layout" => :move,
    "ask_ai" => :bolt,
    "comment" => :comment,
    "duplicate" => :copy,
    "delete" => :trash
  }

  # A CONTRIBUTED ACTION DRAWS WHAT IT DECLARED. Both tables above hold the core's five, and keying
  # the render on them alone left every plugin's button an unlabelled box glyph — the `label` and
  # `icon` its descriptor carries were read by nothing but the tooltip. Same order the rail tabs
  # read theirs in: the descriptor's own icon first, the core's table for the core's own keys.
  defp toolbar_label(%{key: key}) when is_map_key(@toolbar_icons, key),
    do: translated(Map.get(@toolbar_labelled, key))

  defp toolbar_label(%{label: label}) when is_binary(label), do: label
  defp toolbar_label(_action), do: nil

  defp translated(nil), do: nil
  defp translated(text), do: Gettext.gettext(MishkaCmsCore.Gettext, text)

  defp toolbar_icon(%{icon: icon}) when is_binary(icon), do: Panels.icon_name(icon)
  defp toolbar_icon(%{key: key}), do: Map.get(@toolbar_icons, key, :box)

  # Text or glyph follows from whether there IS text, so a contributed label is never drawn into the
  # 30px box the core's bare glyphs sit in.
  defp toolbar_kind(%{key: "ask_ai"}), do: "primary"
  defp toolbar_kind(action), do: (toolbar_label(action) && "labelled") || "glyph"

  # The same name the layers tree uses, so the toolbar and the rail never disagree about what is
  # selected — a component reads as `global-footer`, not as the `.component` wrapper that calls it.
  defp selection_label(tree, id) do
    case Tree.get(tree, id) do
      nil -> ""
      node -> Panels.node_label(node)
    end
  end

  # NO `selection` HERE, DELIBERATELY. The ring is a CSS rule keyed on `data-selected`, which the hook
  # writes on the one element that is selected — so no node's markup depends on which node is
  # selected. Declaring the attr anyway meant every node was re-rendered on every click for a value
  # none of them read: measured at 63 node-function calls and a 1,237-byte diff for a selection that
  # should cost 32 bytes. The root still carries `data-selection` (:745) and the canvas still pushes
  # `pb:selected` (:487), which is how the client knows.
  attr :id, :string, required: true
  attr :tree, :any, required: true
  attr :locked, :any, required: true
  attr :hidden, :any, required: true
  attr :pinned, :any, default: nil
  attr :preview?, :boolean, default: false
  attr :site_scope, :string, default: nil
  attr :required_attrs, :map, default: %{}
  attr :media_attrs, :map, default: %{}
  attr :conceals, :any, default: nil
  attr :shapers, :any, default: nil
  attr :form_marks, :any, default: nil

  defp pb_node(assigns) do
    assigns = assign(assigns, :node, Tree.get(assigns.tree, assigns.id))
    render_node(assigns)
  end

  defp render_node(%{node: nil} = assigns), do: ~H""

  # HIDDEN FROM VISITORS IS NOT IN THE PREVIEW, which is the page a visitor gets. While editing it is
  # drawn as it is, faded by the `data-pb-hidden` rule in `#pb-canvas-chrome`.
  defp render_node(%{preview?: true, node: %Node{} = node} = assigns) do
    case Visibility.hidden?(node) do
      true -> ~H""
      false -> visible_node(assigns)
    end
  end

  defp render_node(%{node: %Node{}} = assigns) do
    case Node.hidden?(assigns.node, assigns.hidden) and !assigns.preview? do
      true -> folded_node(assigns)
      false -> visible_node(assigns)
    end
  end

  # A FOLDED NODE IS NOT DRAWN, BUT ITS PLACE IS KEPT. The canvas drop resolver works out an
  # insertion index by counting `[data-node-id]` children in DOM order, so a child that left no trace
  # at all shifted every sibling after it and landed the next drop one position early. That was
  # already true of anything switched off with the eye; it becomes the common case now that a comment
  # starts folded, so the slot is held by a box that draws nothing.
  #
  # `data-ws` is the marker for a node that holds a place without being content — the same one the
  # indentation runs carry — because a container holding nothing but a folded note is an empty
  # container and still needs its drop floor. `data-folded` is what tells the two apart for the rule
  # in `#pb-canvas-ui`: an indentation run is `display: contents`, a folded node draws nothing.
  defp folded_node(assigns) do
    ~H"""
    <span
      data-node-id={@node.id}
      data-kind={@node.kind}
      data-ws="true"
      data-folded="true"
    ></span>
    """
  end

  # INDENTATION IS NOT SOMETHING YOU CAN POINT AT. The run between two tags is a real node — the tree
  # keeps it so `<a>one</a> <a>two</a>` does not lose its space, and the formatter puts a fresh one
  # between every pair of children on each save — but giving it a box of its own made it a grid item:
  # an empty cell sitting in the middle of a card row, clickable, with nothing in the layers panel to
  # match it, because the panel has always hidden these.
  #
  # `display:contents` is the whole fix. The run still separates whatever is around it, a grid or flex
  # parent skips it exactly as the published page does, and hit testing walks past it to the parent,
  # so there is no phantom selection. It stays in the DOM because the drop resolver counts DOM
  # children to work out an insertion index, and a child missing here would shift every index after
  # it.
  # `</style>` INSIDE A STYLE TAG ENDS THE TAG, whatever the CSS around it meant by the characters.
  # Every body below is authored content — an element's own box, a site's stylesheet row — so the
  # sequence can arrive, and from there the browser stops reading CSS and starts reading markup: the
  # rest of the rule becomes elements in the canvas document, and anything after it is whatever the
  # author wrote.
  #
  # CSS supplies the escape for nothing. A backslash inside a string is an escape and `\/` is a `/`,
  # so `<\/style>` is the same string to a CSS parser and no longer a closing tag to an HTML one;
  # outside a string the sequence was never valid CSS to begin with. Case-insensitive, because
  # `</STYLE>` closes the tag just as well.
  #
  # It is applied at the boundary rather than on the way into storage: the same body is also served
  # as a real stylesheet, where the sequence is unremarkable and must survive untouched.
  defp style_body(css) when is_binary(css),
    do: css |> String.replace(~r{</style}i, "<\\/style") |> Phoenix.HTML.raw()

  defp style_body(_css), do: Phoenix.HTML.raw("")

  # INDENTATION BEFORE A CLOSING TAG IS NOT BETWEEN ANYTHING. Every other whitespace run keeps an
  # element, because the drop resolver counts DOM children to work out where a drop lands and a
  # missing one would shift every index after it — but the LAST child is the one position no index
  # can come after, so dropping it costs nothing and buys the thing a component's own rules need.
  #
  # `chelekom-button-group` joins what is inside it with `[&>*:not(:last-child)]:border-r`. With a
  # run of indentation sitting at the end, the last button was not the last child, so it took the
  # divider meant for the gaps and the group ended in a stray line.
  #
  # Only inside a COMPONENT, which is where a positional rule the editor did not write can see it.
  defp visible_node(%{node: %Node{kind: :text, meta: %{whitespace?: true}} = node} = assigns) do
    case trailing_in_component?(assigns, node) do
      true ->
        ~H"{@node.text}"

      false ->
        ~H|<span data-node-id={@node.id} data-kind="text" data-ws="true">{@node.text}</span>|
    end
  end

  defp visible_node(%{node: %Node{kind: :text}} = assigns) do
    ~H"""
    <span
      draggable="true"
      data-node-id={@node.id}
      data-kind="text"
      {wrapper_attrs(assigns)}
      phx-click="select"
      phx-value-id={@node.id}
    >{text_html(@node.text)}</span>
    """
  end

  # An expression keeps its chip even in preview: something real WILL render there, and hiding it
  # would show a gap the live page does not have. A comment is the opposite — it renders nothing
  # anywhere — so both comment kinds vanish in preview, below, and start folded away the rest of the
  # time: `Node.hidden?/2` gives them the opposite default, and the eye on their layers row is what
  # unfolds one.
  defp visible_node(%{node: %Node{kind: kind}} = assigns)
       when kind in [:eex, :eex_block] do
    assigns = assign(assigns, :chip_label, chip_label(assigns.node))

    ~H"""
    <span
      draggable="true"
      data-node-id={@node.id}
      data-kind={@node.kind}
      data-pb-token="true"
      title={
        gettext("Dynamic content — double-click to select it, then edit its source in the inspector")
      }
      {wrapper_attrs(assigns)}
      phx-click="select"
      phx-value-id={@node.id}
    >{@chip_label}</span>
    """
  end

  defp visible_node(%{node: %Node{kind: kind}} = assigns)
       when kind in [:html_comment, :eex_comment] do
    assigns = assign(assigns, :chip_label, chip_label(assigns.node))

    ~H"""
    <span
      :if={!@preview?}
      data-node-id={@node.id}
      data-kind={@node.kind}
      data-pb-token="true"
      {wrapper_attrs(assigns)}
      phx-click="select"
      phx-value-id={@node.id}
    >{@chip_label}</span>
    """
  end

  defp visible_node(%{node: %Node{kind: :component, tag: ".component"}} = assigns) do
    assigns =
      assigns
      |> assign(:component_name, Node.component_name(assigns.node))
      |> assign(
        :missing,
        missing_required(assigns.node, assigns[:required_attrs] || %{}, assigns.tree)
      )

    render_component_node(assigns)
  end

  # `<.input>`, `<.link>`, `<.form>` — an ordinary Phoenix function component. It takes the same two
  # roads as a kit component: the editor's box when there is somewhere to put one, and the
  # component's own root when there is not. A form block's field sits inside a row that joins it to
  # a button with `[&>div]:mb-0`, and that row means the field's own div, not a box around it.
  defp visible_node(%{node: %Node{kind: :component}} = assigns) do
    assigns =
      assigns
      |> assign(:target, function_component(assigns.node))
      |> assign(:component_name, nil)
      |> then(&assign(&1, :fn_assigns, function_component_assigns(&1)))
      |> then(&assign(&1, :missing, missing_given(&1.target, &1.fn_assigns)))

    case {assigns.missing, assigns.target} do
      {[], {module, function}} ->
        assigns
        |> assign(
          :rendered,
          contained(assigns.node.tag, assigns.preview?, fn ->
            apply(module, function, [assigns.fn_assigns])
          end)
        )
        |> component_frame()

      _unrenderable ->
        unresolved_component(assigns)
    end
  end

  defp visible_node(%{node: %Node{kind: :slot}} = assigns) do
    ~H"""
    <div data-node-id={@node.id} data-kind="slot" {wrapper_attrs(assigns)}>
      <.pb_node
        :for={child <- @node.children}
        id={child}
        tree={@tree}
        locked={@locked}
        hidden={@hidden}
        pinned={@pinned}
        preview?={@preview?}
        site_scope={@site_scope}
        required_attrs={@required_attrs}
        media_attrs={@media_attrs}
        conceals={@conceals}
        shapers={@shapers}
        form_marks={@form_marks}
      />
    </div>
    """
  end

  defp visible_node(%{node: %Node{meta: %{self_close: true}}} = assigns) do
    assigns =
      assign(
        assigns,
        :html_attrs,
        Map.merge(html_attrs(assigns.node, assigns.tree), form_marks(assigns))
      )

    ~H"""
    <.dynamic_tag
      tag_name={canvas_tag(@node.tag)}
      draggable="true"
      data-node-id={@node.id}
      style={wrapper_style(assigns)}
      phx-click="select"
      phx-value-id={@node.id}
      {@html_attrs}
    />
    """
  end

  defp visible_node(assigns) do
    assigns =
      assign(
        assigns,
        :html_attrs,
        Map.merge(html_attrs(assigns.node, assigns.tree), form_marks(assigns))
      )

    ~H"""
    <.dynamic_tag
      tag_name={canvas_tag(@node.tag)}
      draggable="true"
      data-node-id={@node.id}
      style={wrapper_style(assigns)}
      phx-click="select"
      phx-value-id={@node.id}
      {@html_attrs}
    >
      <.pb_node
        :for={child <- @node.children}
        id={child}
        tree={@tree}
        locked={@locked}
        hidden={@hidden}
        pinned={@pinned}
        preview?={@preview?}
        site_scope={@site_scope}
        required_attrs={@required_attrs}
        media_attrs={@media_attrs}
        conceals={@conceals}
        shapers={@shapers}
        form_marks={@form_marks}
      />
    </.dynamic_tag>
    """
  end

  defp trailing_in_component?(%{tree: tree}, %Node{parent_id: parent_id} = node) do
    case Tree.get(tree, parent_id) do
      %Node{kind: :component, children: children} -> List.last(children) == node.id
      _other -> false
    end
  end

  defp trailing_in_component?(_assigns, _node), do: false

  # A function the editor cannot resolve, or one missing something it declared required. Both are
  # the editor's own markup rather than the component's, so both keep the box.
  defp unresolved_component(assigns) do
    ~H"""
    <div {marker_attrs(assigns)}>
      <%= case @missing do %>
        <% [needed | _rest] -> %>
          <strong>{@node.tag}</strong>
          {gettext("needs %{fields} — click to choose %{needed}.",
            fields: Enum.join(@missing, ", "),
            needed: needed
          )}
        <% [] -> %>
          <span data-pb-token="true" {wrapper_attrs(assigns)}>{@node.tag}</span>
      <% end %>
    </div>
    """
  end

  # A component missing something it declared as required is shown as a placeholder rather than
  # rendered. It would raise — `<div id={@id}>` with no `id` is a `KeyError` — and a raise here takes
  # the canvas process with it, which costs the author every unsaved edit in the session.
  #
  # The placeholder keeps `data-node-id`, so the node is still selectable, still draggable and still
  # deletable: clicking it opens the Inspector with the missing field marked, which is where it gets
  # fixed. Saving is already refused while it is empty.
  defp render_component_node(%{missing: [_ | _]} = assigns) do
    ~H"""
    <div
      draggable="true"
      data-node-id={@node.id}
      data-kind="component"
      data-component={@component_name}
      data-incomplete="true"
      {wrapper_attrs(assigns)}
      phx-click="select"
      phx-value-id={@node.id}
      phx-value-prop={hd(@missing)}
    >
      <strong>{@component_name}</strong>
      {gettext("needs %{fields} — click to choose %{needed}.",
        fields: Enum.map_join(@missing, ", ", &"#{&1}"),
        needed: hd(@missing)
      )}
    </div>
    """
  end

  defp render_component_node(assigns) do
    assigns =
      assigns
      |> assign(:component_assigns, component_assigns(assigns))
      |> assign(:stateful?, stateful_entry?(assigns))
      |> assign(:wants_media, wants_media(assigns))
      |> assign(:overlay, overlay(assigns))
      |> assign(:reveal, reveal(assigns))
      |> assign(:hollow, hollow(assigns))

    assigns
    |> assign(
      :rendered,
      contained(assigns.component_name, assigns.preview?, fn ->
        LiveViewHelpers.static_component(assigns.component_assigns)
      end)
    )
    |> component_frame()
  end

  # A CELL CANNOT BE PUT IN A BOX. The editor wraps every node in a `<div>` carrying its id, its
  # drag handle and its click target — and a `<div>` between a `<tr>` and its `<td>` is markup no
  # parser keeps. It foster-parents the wrapper out of the table: the cells reattach and the table
  # looks right at rest, while each wrapper becomes a full-width, zero-height orphan above it.
  # `openEmpties()` then inflates every orphan into a dashed strip on every dragstart — the stack of
  # hatched bars over the page — and the pointer lands on one, so a drop aimed at the footer read
  # "Inside <chelekom-td>".
  #
  # So the markers go onto the component's own root instead, which is the element that belongs
  # there. This is also the only way a cell becomes selectable at all: the real `<td>` carried no
  # `data-node-id` before, whatever happened to the wrapper.
  #
  # Asked of the RENDER, not of the entry: the editor has the component's own HTML in its hands at
  # exactly this moment, and what its first tag turns out to be is the only thing that decides
  # whether a wrapper survives. A kit whose cell is called something else is covered without being
  # named.
  defp component_frame(%{rendered: {:html, html}} = assigns) do
    case stampable?(assigns, html) do
      true ->
        assigns |> assign(:body, stamp(html, marker_attrs(assigns))) |> stamped_frame()

      false ->
        assigns
        |> assign(:body, Phoenix.HTML.raw(html))
        |> assign(:live, live_label(assigns))
        |> wrapped_frame()
    end
  end

  # A component that raised gets the wrapper it always got: the placeholder is the editor's own
  # markup, so there is no root of the component's to stamp, and a `<span>` misplaced inside a table
  # costs nothing a failed render has not already cost.
  defp component_frame(%{rendered: {:refused, placeholder}} = assigns) do
    assigns |> assign(:body, placeholder) |> wrapped_frame()
  end

  # TWO REASONS A BOX CANNOT GO HERE, and one reason it has to.
  #
  # The first is the parser's: a `<td>` outside a `<tr>` is not a cell.
  #
  # The second is the PARENT's. `chelekom-button-group` joins what is inside it with
  # `[&>*]:rounded-none [&>*]:border-0` — the element immediately inside, which on the canvas was
  # the wrapper and not the button. So the author saw three separately rounded buttons here and one
  # joined control on the published page, which is what it was reported as. Fourteen kit components
  # write a selector that would land on a wrapper this way; `PaletteEntry.shapes_children?/1` is
  # what says which, read off their own markup rather than off a list of names.
  #
  # AND AN OVERLAY KEEPS ITS BOX. `#pb-canvas-chrome` opens a shut dialog with descendant rules
  # aimed from the wrapper DOWN at the component's own root — `data-pb-overlay` on the one, the
  # `hidden` on the other. Stamped, both would be the same element and the rule would reach past
  # what it means to open. The wrapper is doing real work there and stays.
  defp stampable?(assigns, html) do
    not conceals?(assigns, assigns.node) and
      (Containment.parent_restricted?(first_tag(html)) or shaped_by_parent?(assigns))
  end

  defp shaped_by_parent?(%{node: node, tree: tree} = assigns),
    do: tree |> Tree.get(node.parent_id) |> shapes_children?(assigns)

  defp shaped_by_parent?(_assigns), do: false

  # A KIT SAYS IT IN ITS OWN MARKUP; AN AUTHOR SAYS IT IN A CLASS. `<div class="[&>*]:rounded-none">`
  # is the same promise written by hand, and the canvas has to keep it the same way — otherwise the
  # editor disagrees with the page over markup the author wrote themselves.
  defp shapes_children?(%Node{kind: :component} = parent, assigns) do
    case assigns[:shapers] do
      nil -> false
      names -> MapSet.member?(names, Node.component_name(parent))
    end
  end

  defp shapes_children?(%Node{kind: :tag} = parent, _assigns),
    do: PaletteEntry.shapes_children?(Node.attr_text(parent, "class"))

  defp shapes_children?(_parent, _assigns), do: false

  defp wrapped_frame(assigns) do
    ~H"""
    <div {Map.put(marker_attrs(assigns), "data-pb-live", assigns[:live])}>{@body}</div>
    """
  end

  # A LIVE COMPONENT SAYS SO ON THE CANVAS, which nothing did. `data-stateful` has been on the node
  # since the canvas learned to draw one, and no rule read it: the list drew real posts, looked like
  # any other markup, and the author learned it was a different kind of thing from the Inspector or
  # not at all. The chip the `data-pb-live` rules in `#pb-canvas-chrome` draw is that word, where the
  # pointer is.
  #
  # ON THE WRAPPER ONLY, which is why it is not `data-stateful`. A stamped root carries every marker
  # the wrapper would have — and it is the component's own `<td>`, or a child its parent joins with
  # `[&>*]:` — so a `position` and a pseudo-element put there land inside somebody else's layout.
  #
  # A placeholder is not given one either: the red box is the editor's own words about a render that
  # failed, and "live" over it would be describing something that is not on the canvas. Never in
  # preview, like every other editing affordance on the wrapper.
  #
  # NOR A WRAPPER WHOSE `::after` IS ALREADY SPOKEN FOR. An element has one `::after`, and the media
  # well's and the empty overlay's are keyed on this same wrapper by selectors that outrank the chip's
  # — so a live component wanting a picture drew the well's sentence in the chip's violet over its
  # whole box, and never the word "Live". Both of those ask the author to DO something here, which
  # the chip does not; the Inspector's badge still says what the component is.
  defp live_label(%{preview?: true}), do: nil
  defp live_label(%{wants_media: wanted}) when is_binary(wanted), do: nil
  defp live_label(%{hollow: hollow}) when is_binary(hollow), do: nil
  defp live_label(%{stateful?: true, component_name: name}), do: name
  defp live_label(_assigns), do: nil

  defp stamped_frame(assigns) do
    ~H"""
    {@body}
    """
  end

  # The one list of what makes a node an editable node, so the wrapper and the stamp cannot drift.
  defp marker_attrs(assigns) do
    missing = assigns[:missing] || []

    %{
      "draggable" => "true",
      "data-node-id" => assigns.node.id,
      "data-kind" => "component",
      "data-component" => assigns[:component_name] || assigns.node.tag,
      "data-stateful" => assigns[:stateful?] && "true",
      "data-wants-media" => assigns[:wants_media],
      "data-incomplete" => missing != [] && "true",
      "data-pb-overlay" => assigns[:overlay],
      "data-pb-reveal" => assigns[:reveal],
      "data-pb-hollow" => assigns[:hollow],
      "data-pb-hidden" => Visibility.hidden?(assigns.node) && "true",
      "phx-click" => "select",
      "phx-value-id" => assigns.node.id,
      "phx-value-prop" => assigns[:wants_media] || List.first(missing)
    }
    |> Map.merge(wrapper_attrs(assigns))
  end

  # THE FRAME DRAWS MARKUP, IN PREVIEW AS IN EDITING. `LiveViewHelpers.static_component/1` renders a
  # stateful component's own HTML in its cold state; a function component takes the path it always
  # took, so the 141 already installed are not affected either way.
  #
  # Preview used to take the live dispatch, on the reasoning that a preview is the real page and
  # this is a LiveView that could host the real thing. It cannot: `contain/3` forces the result to
  # iodata to draw it inside the frame, and a `%Phoenix.LiveView.Component{}` raises when asked for
  # any — so preview drew a red box over every live component instead. Three surfaces set
  # `preview?: true`, and two of them are the wizard and example previews an author reads while
  # CONFIGURING a kit component, before there is a page to preview at all.
  #
  # Hosting it live for real would mean kit-written `handle_event/3` running inside the process that
  # holds the editing-session token, which is the trade the editing canvas declines and preview
  # declines for the same reason. A preview is a picture of a page, and a picture does not respond
  # to clicks.

  # A PICTURE NOBODY HAS CHOSEN YET IS STILL A THING ON THE PAGE — the same argument `el-image`'s
  # placeholder already makes, for the seven kit components that never got it. Two of the nine media
  # attributes are required, so those draw "needs src" and always did. The other seven are optional,
  # which means the component renders PERFECTLY and renders nothing: a gallery tile whose
  # `<img :if={@src}>` collapses to zero height, an avatar drawing a src-less `<img>`, a navbar logo
  # nested inside a `<.link :if={!is_nil(@link)}>` that is not there either. The author dropped one,
  # saw an empty strip, and had nothing to aim at.
  #
  # `nil` when there is nothing wanted, which is what keeps the attribute off every other node —
  # `phx-value-prop={nil}` renders no attribute, and a click then means what it has always meant.
  #
  # In PREVIEW it answers nothing at all: a visitor is not choosing anything, and the well is an
  # editing affordance like every other thing `wrapper_style/1` strips there.
  # AN OVERLAY SAYS WHAT IT IS WHILE IT IS SHUT.
  #
  # This used to be a third glyph on the layers row, beside the eye and the lock, that the author had
  # to find and click. It was the wrong shape twice over. It asked a person to know that a dialog is
  # a thing with a hidden state before they could put anything in one — and it was pushed to the
  # canvas only on a session broadcast, never at mount, so every canvas reload, device switch and
  # socket reconnect snapped the thing shut while the rail still showed the glyph lit. The next click
  # then TURNED IT OFF, and nothing happened. That is exactly what it was reported as: "when i click
  # on the icon it does not work".
  #
  # It was then held open for the whole session, which traded that for the opposite complaint: three
  # overlays on a page cover the page. The label is what the `data-pb-overlay` rules in
  # `#pb-canvas-chrome` draw as a chip, and selecting it is what opens it.
  #
  # Never in preview: a visitor sees the component close itself exactly as its author intended.
  defp overlay(%{preview?: true}), do: nil

  defp overlay(%{node: node} = assigns) do
    case conceals?(assigns, node) do
      true -> Node.component_name(node) |> label_for()
      false -> nil
    end
  end

  # HELD OPEN ON PURPOSE. Selection opens an overlay and closing it again is the selection moving on,
  # which is the wrong answer exactly once: when the point is the page BEHIND the dialog. The pin on
  # the layers row is that case, and it is the only thing this attribute now means.
  defp reveal(%{preview?: true}), do: nil

  defp reveal(%{node: node} = assigns) do
    case conceals?(assigns, node) and MapSet.member?(assigns[:pinned] || MapSet.new(), node.id) do
      true -> "true"
      false -> nil
    end
  end

  # AND AN EMPTY ONE SAYS SO, in words, at a size a person can drop something onto.
  #
  # Revealing a dialog with nothing in it reveals nothing: the kit's own chrome is a few pixels of
  # padding, so the author was looking for a target that was not there. The label is `::after`
  # content rather than markup, for the same reason the media well's is — what is inside the wrapper
  # belongs to the COMPONENT, and the editor's words have no business in somebody's dialog.
  defp hollow(%{preview?: true}), do: nil

  defp hollow(%{node: node} = assigns) do
    case conceals?(assigns, node) and node.children == [] do
      true -> Node.component_name(node) |> label_for()
      false -> nil
    end
  end

  defp conceals?(assigns, %Node{kind: :component} = node) do
    case assigns[:conceals] do
      nil -> false
      names -> MapSet.member?(names, Node.component_name(node))
    end
  end

  defp conceals?(_assigns, _node), do: false

  # "chelekom-mega-menu" reads as "mega menu". The kit's prefix is noise in a sentence addressed to
  # the author, who chose the thing out of a palette that had already grouped it.
  defp label_for(name) when is_binary(name) do
    name
    |> String.split("-")
    |> Enum.drop(1)
    |> Enum.join(" ")
    |> case do
      "" -> name
      words -> words
    end
  end

  defp label_for(_absent), do: gettext("component")

  # The names of every component that renders its own content closed, read off the palette once.
  defp conceals(components) do
    for entry <- components || [],
        Map.get(entry, :concealed?, false),
        into: MapSet.new(),
        do: entry.name
  end

  # And of every component that reaches for the elements an author puts inside it, read off the same
  # palette at the same moment.
  defp shapers(components) do
    for entry <- components || [],
        Map.get(entry, :shapes_children?, false),
        into: MapSet.new(),
        do: entry.name
  end

  defp wants_media(%{preview?: true}), do: nil

  defp wants_media(%{node: node, tree: tree} = assigns),
    do: blank_media(node, assigns[:media_attrs] || %{}, tree)

  @doc false
  # ONE COMPONENT MUST NOT COST THE WHOLE SESSION.
  #
  # A component render is two stages. `apply/3` returns a `%Phoenix.LiveView.Rendered{}` whose
  # `dynamic` field is a closure; the author's `<div id={@id}>` does not run until LiveView invokes
  # that closure, deep inside its own diff — long after any `try` around the call site has returned.
  # That is why the note on `required_attrs/1` says a check was the answer and a rescue was not, and
  # it is still true of the call.
  #
  # So the closure is run HERE, on purpose. `Phoenix.HTML.Safe.to_iodata/1` on a `%Rendered{}` walks
  # it and invokes the dynamic, which brings the raise inside a `rescue` we own. What it costs is
  # the STATIC half of that subtree's change tracking: LiveView can no longer send only the dynamic
  # values for it, because what it now holds is one flat binary. The dynamic half was already gone —
  # `tracked/1` hands every runtime component `__changed__: nil`, so its assigns are recomputed on
  # every render regardless.
  #
  # A raise is not an error to hide. It is logged with its stacktrace, and the placeholder says which
  # component and what it said, because the author is the one who can fix it.
  #
  # ALL THREE WAYS OUT, not only the one that is easy to picture. `rescue` catches an exception and
  # nothing else, so a component that `throw`s, or that calls a GenServer which is down — an `exit`
  # of `{:noproc, …}`, and the likeliest of the three in a component that talks to anything — went
  # straight past this and killed the canvas. The author lost every edit since their last save to a
  # component that was merely misconfigured.
  #
  # WHAT THIS STILL DOES NOT BOUND is time: a component that loops forever hangs the canvas, and
  # there is no answer to that inside one process. The obvious fix — render each component in a Task
  # with a deadline — was measured and rejected: `Ecto.Adapters.SQL.Sandbox` ownership is per
  # process, so every component that reads the database would break under test, and the caller's
  # process dictionary does not travel either, which is where the Gettext locale lives. The blast
  # radius of the loop is one author's canvas iframe; the builder holding their document is a
  # separate process and survives, which is the property that actually matters.
  def contain(name, preview?, render) do
    render.() |> Phoenix.HTML.Safe.to_iodata() |> settled(preview?) |> Phoenix.HTML.raw()
  rescue
    error -> refuse(name, "raised", Exception.message(error), __STACKTRACE__)
  catch
    :throw, value -> refuse(name, "threw", inspect(value), __STACKTRACE__)
    :exit, reason -> refuse(name, "exited", Exception.format_exit(reason), __STACKTRACE__)
  end

  # A COMPONENT MUST NOT CLOSE ITSELF UNDER THE AUTHOR'S POINTER.
  #
  # The kit's overlays dismiss on a click outside and on Escape — `phx-click-away` and
  # `phx-window-keydown` on `chelekom-modal`'s focus wrap, and on the drawer, the dropdown and the
  # rest. On a real page that is exactly right. On the canvas EVERY click is outside: selecting the
  # heading next to a dialog, the layers row, the page itself — each one ran the component's own
  # cancel sequence and shut the thing being edited, and the only way back was the eye on the layers
  # row, off and on again. That is what it was reported as, and it is not a styling problem: the
  # bindings are the component's own markup, which no assign of ours reaches.
  #
  # So they are dropped from what the canvas draws. On the flattened render rather than in the tree,
  # because the tree does not hold them — they belong to the component, and this is the one moment
  # the editor has the component's own HTML in its hands. Both attributes are always rendered
  # double-quoted with their contents escaped, which is what makes the match exact.
  #
  # NEVER IN PREVIEW: a visitor gets the component whole, Escape and click-away and all.
  @self_closing ~r/\s(?:phx-click-away|phx-window-keydown)="[^"]*"/

  # AND A COMPONENT MUST NOT FREEZE ITSELF EITHER. `phx-update="ignore"` is how a component tells
  # LiveView that the DOM inside it belongs to its own JavaScript — right on a published page, where
  # a carousel's hook is mid-animation and a diff would tear it. On the canvas it means the author's
  # every change is written into the document, accepted by the server, drawn in the Inspector, and
  # never redrawn here: the first render of that component is the last one. Two of the kit's carry it
  # and both are the ones whose content is a list — a gallery's pictures and a carousel's slides, the
  # two places an author adds things one at a time.
  #
  # Stripped for the same reason and in the same place as the self-closing bindings: it is the
  # component's own markup, no assign of ours reaches it, and this is the one moment the editor is
  # holding the flattened render.
  #
  # NEVER IN PREVIEW: a visitor gets the component whole, and its hook wants that DOM to itself.
  @frozen ~r/\sphx-update="ignore"/

  defp settled(iodata, true), do: iodata

  defp settled(iodata, _editing) do
    iodata
    |> IO.iodata_to_binary()
    |> String.replace(@self_closing, "")
    |> String.replace(@frozen, "")
  end

  # `contain/3`, with the rendered markup handed back as a binary the caller can still decide about.
  # A refusal stays whole — it is the editor's own placeholder, not the component's markup.
  defp contained(name, preview?, render) do
    case contain(name, preview?, render) do
      {:safe, iodata} -> {:html, IO.iodata_to_binary(iodata)}
      placeholder -> {:refused, placeholder}
    end
  end

  # The opening tag: what comes before it, its name, whatever it was written with, and how it closes.
  #
  # COMMENTS COUNT AS NOTHING BEFORE IT. In dev, HEEx writes a `<!-- @caller … -->` annotation ahead
  # of every component's own markup, so a match anchored on `\A\s*<` found no tag at all and every
  # cell went back to being wrapped — in the one environment where an author would see it, and in
  # none of the ones where this is tested.
  @open_tag ~r/\A((?:\s|<!--.*?-->)*)<([a-zA-Z][a-zA-Z0-9-]*)((?:"[^"]*"|'[^']*'|[^>"'])*)(\/?>)/s
  @style_attr ~r/\sstyle="([^"]*)"/

  defp first_tag(html) do
    case Regex.run(@open_tag, html) do
      [_whole, _before, tag | _rest] -> tag
      nil -> nil
    end
  end

  # Put the editor's markers on the element the component itself drew. `style` is merged rather than
  # added: two `style` attributes on one tag is one attribute, and the browser keeps the first.
  # The editor's goes last, so a lock outline wins over whatever the component styles itself with.
  defp stamp(html, attrs) do
    {style, markers} = Map.pop(attrs, "style")
    written = markers |> Phoenix.HTML.attributes_escape() |> Phoenix.HTML.safe_to_string()

    @open_tag
    |> Regex.replace(
      html,
      fn _whole, before, tag, attributes, close ->
        before <> "<" <> tag <> written <> merge_style(attributes, style) <> close
      end,
      global: false
    )
    |> Phoenix.HTML.raw()
  end

  defp merge_style(attributes, nil), do: attributes

  defp merge_style(attributes, style) do
    case Regex.run(@style_attr, attributes) do
      [_whole, theirs] ->
        String.replace(attributes, @style_attr, one_style(theirs, style), global: false)

      nil ->
        attributes <> one_style("", style)
    end
  end

  defp one_style(theirs, ours) do
    {:safe, escaped} = Phoenix.HTML.html_escape(ensure_semicolon(theirs) <> ours)
    ~s( style=") <> IO.iodata_to_binary(escaped) <> ~s(")
  end

  defp refuse(name, verb, message, stacktrace) do
    Logger.warning(
      "[Builder] #{name} #{verb} while rendering: #{message}\n" <>
        Exception.format_stacktrace(stacktrace)
    )

    failed(%{name: name, message: message})
  end

  attr(:name, :string, required: true)
  attr(:message, :string, required: true)

  # Styled like the missing-required placeholder above, because it is the same promise: the node is
  # still there, still selectable, still deletable. The alternative is a canvas that reloads itself
  # and an author who has lost everything since the last save.
  defp failed(assigns) do
    ~H"""
    <span data-render-error="true">
      <strong>{@name}</strong>
      {gettext("could not render — %{message}", message: @message)}
    </span>
    """
  end

  # A dotted tag that is NOT the runtime wrapper is an ordinary Phoenix function component — `<.link>`,
  # `<.icon>`, `<MyApp.Components.hero>`. A compiled page gets these from its own imports; the canvas
  # has to resolve them itself, and shows a labelled placeholder when it cannot rather than the
  # runtime resolver's red "failed to render", which would be a lie: nothing failed, the editor just
  # has no such function in scope.

  # `<.link>` and friends live in the host's core components or in Phoenix itself, in that order —
  # the same precedence a compiled page module's imports give them, and the order
  # `MishkaCmsCore.Runtime.PageBuilder.Fields.local_modules/0` names. A remote tag names its own
  # module.
  defp function_component(%Node{tag: "." <> name}),
    do: Enum.find_value(Fields.local_modules(), &resolve_component(&1, name))

  defp function_component(%Node{tag: tag}) when is_binary(tag) do
    {name, segments} = tag |> String.split(".") |> List.pop_at(-1)

    case segments do
      [] -> nil
      _prefix -> segments |> Module.concat() |> resolve_component(name)
    end
  end

  defp function_component(_node), do: nil

  # Resolved through the module's own declarative metadata, so a name from a template never mints an
  # atom — an undeclared one simply does not resolve.
  defp resolve_component(module, name) do
    module
    |> declared_components()
    |> Map.get(name)
    |> case do
      nil -> nil
      fun -> {module, fun}
    end
  end

  defp declared_components(module) do
    case Code.ensure_loaded?(module) and function_exported?(module, :__components__, 0) do
      true -> Map.new(module.__components__(), fn {fun, _meta} -> {Atom.to_string(fun), fun} end)
      false -> %{}
    end
  end

  defp component_meta(module, fun), do: module.__components__() |> Map.get(fun, %{})

  defp declared_attr_specs(module, fun), do: module |> component_meta(fun) |> Map.get(:attrs, [])

  defp declared_slots(module, fun), do: module |> component_meta(fun) |> Map.get(:slots, [])

  defp declared_component_attrs(module, fun) do
    module
    |> declared_attr_specs(fun)
    |> Map.new(&{Atom.to_string(&1.name), &1.name})
  end

  # WHICH ASSIGN A COMPONENT'S GLOBALS BELONG TO, FROM EITHER METADATA SHAPE, so the function-
  # component path and the runtime-kit path answer it once. A function component's specs come from
  # `__components__/0` with atom keys; a kit's from `__component_information__/1`, where the bundle's
  # JSON left name and type as strings. There is at most one such attribute per component — LiveView
  # refuses a second at compile time — so the first is the answer.
  defp global_key(attrs) do
    Enum.find_value(attrs, fn attr ->
      case attr_field(attr, :type) do
        type when type in [:global, "global"] -> attr |> attr_field(:name) |> global_name()
        _other -> nil
      end
    end)
  end

  defp global_name(nil), do: nil
  defp global_name(name) when is_atom(name), do: name
  defp global_name(name) when is_binary(name), do: String.to_existing_atom(name)

  defp attr_field(%{} = attr, key), do: Map.get(attr, key) || Map.get(attr, Atom.to_string(key))

  # AN ATTRIBUTE THE COMPONENT NEVER DECLARED IS STILL THE AUTHOR'S. HEEx collects every such name
  # into the component's `:global` assign — `Map.split/2` over the declared keys, at the call site —
  # and the canvas has no call site, so `required`, `minlength`, `pattern`, `placeholder` and every
  # `data-` the inspector's Validation section writes were dropped on the way in. The author set a
  # rule, the code drawer showed it written, and the field on the canvas rendered exactly as it had
  # before: the one surface they author on could not show them the thing they had just done.
  #
  # EVERY UNDECLARED NAME, NOT ONLY THE ONES LIVEVIEW CALLS GLOBAL. `__global__?/3` is what decides
  # whether HEEx WARNS at compile time; at run time the split keeps the attribute either way, and a
  # kit declaring a bare `attr :rest, :global` still renders the `required` a page hands it. Filtering
  # here by that predicate showed the canvas one thing and the published page another — which for
  # every Chelekom field, none of which declare an `:include`, was the whole Validation section.
  #
  # The map is assigned to the global's OWN key rather than left as loose keys for the generated
  # wrapper to gather: `put_declared_defaults/3` seeds that key with `%{}`, and an explicit global
  # assign is the branch the wrapper takes in preference to anything the caller passed.
  defp put_globals(assigns_map, _node, _declared, nil), do: assigns_map

  defp put_globals(assigns_map, node, declared, key) do
    globals =
      node.attrs
      |> Enum.flat_map(&global_pair(&1, declared))
      |> Map.new()

    Map.put(assigns_map, key, globals)
  end

  defp global_pair({name, value}, declared) when is_binary(name) do
    case !Map.has_key?(declared, name) and !canvas_owned?(name) do
      true -> Enum.map(attr_value(value), &{name, &1})
      false -> []
    end
  end

  defp global_pair(_attr, _declared), do: []

  defp function_component_assigns(%{target: nil}), do: tracked(%{})

  defp function_component_assigns(%{node: node, tree: tree, target: {module, fun}} = assigns) do
    declared = declared_component_attrs(module, fun)
    global = module |> declared_attr_specs(fun) |> global_key()

    node.attrs
    |> Enum.flat_map(fn
      {name, value} when is_binary(name) ->
        case Map.get(declared, name) do
          nil -> []
          key -> value |> attr_value() |> Enum.map(&{key, &1})
        end

      _attr ->
        []
    end)
    |> Map.new()
    |> put_globals(node, declared, global)
    |> put_declared_defaults(module, fun)
    |> put_form_fields(node, tree, declared)
    |> put_unresolved(node, module, fun)
    |> Map.merge(slot_assigns(node, tree, assigns))
    |> tracked()
  end

  # AN EXPRESSION THE CANVAS CANNOT COMPUTE IS STILL SOMETHING THE AUTHOR WROTE.
  #
  # `attr_value/1` folds a literal and DROPS everything else, which is right for an optional
  # attribute — the declared default takes over and the component renders. For a REQUIRED one it is
  # a raise: `<.focus_wrap id={"#{@id}-container"}>` is every Chelekom modal's own markup, and
  # opening that component in the builder means rendering it with no page assigns, so `@id` resolves
  # to nothing and Phoenix meets `focus_wrap` without the one attribute it declares. `key :id not
  # found`, from inside LiveView's diff.
  #
  # Refusing to render it — the `missing_given/2` placeholder below — is the right answer when the
  # author never wrote the attribute at all, because there is nothing to lose and something to fix.
  # It is the WRONG answer here: the modal's title, its close button and its body are CHILDREN of
  # that `focus_wrap`, so refusing hides the entire document the author came to edit behind a note
  # about an attribute the component's own source fills in.
  #
  # So the shape is honoured instead of the value, exactly as `put_form_fields/4` honours `f[:email]`
  # without evaluating it. The stand-in for a string is derived from the NODE — unique per element,
  # stable across renders, and shaped like a DOM id, because that is overwhelmingly what a required
  # string on a function component is for and a value with quotes in it would break the markup it
  # lands in. Nothing here reaches a published page: the compiled template carries the author's own
  # expression, and this map exists only to draw the canvas.
  defp put_unresolved(assigns_map, node, module, fun) do
    module
    |> declared_attr_specs(fun)
    |> Enum.reduce(assigns_map, fn attr, acc ->
      case Map.get(attr, :required, false) and not Map.has_key?(acc, attr.name) do
        true -> put_written(acc, node, attr)
        false -> acc
      end
    end)
  end

  defp put_written(assigns_map, node, attr) do
    case Node.attr(node, Atom.to_string(attr.name)) do
      {:expr, _source} -> Map.put(assigns_map, attr.name, stand_in(attr.type, node, attr.name))
      _unwritten -> assigns_map
    end
  end

  defp stand_in(:string, node, name), do: "pb-#{node.id}-#{name}"
  defp stand_in(:integer, _node, _name), do: 0
  defp stand_in(:float, _node, _name), do: 0.0
  defp stand_in(:boolean, _node, _name), do: false
  defp stand_in(:list, _node, _name), do: []
  defp stand_in(:map, _node, _name), do: %{}
  defp stand_in(_type, _node, _name), do: nil

  # A FUNCTION COMPONENT CALLED BY `apply/3` GETS NONE OF ITS OWN DECLARATIONS. HEEx fills the
  # defaults and builds the `:global` map at the CALL SITE, and the canvas has no call site — so
  # `<.form>` raised on `assigns.rest` before it ever reached its own handling of a missing `for`.
  # Read off `__components__/0`, the same metadata that resolved the function in the first place.
  defp put_declared_defaults(assigns_map, module, fun) do
    module
    |> declared_attr_specs(fun)
    |> Enum.reduce(assigns_map, fn attr, acc ->
      case {attr.type, Keyword.fetch(attr.opts, :default)} do
        {:global, _default} -> Map.put_new(acc, attr.name, %{})
        {_type, {:ok, value}} -> Map.put_new(acc, attr.name, value)
        {_type, :error} -> acc
      end
    end)
  end

  # A BOUND FIELD IS BOUND TO NOTHING HERE, and dropping the attribute is not a safe default. The
  # canvas has no page assigns and no `:let` — slot children are pre-rendered before the wrapper's
  # slot is ever invoked, so `Phoenix.Component.call_inner_block!/3` discards the argument and no
  # `f` can reach a child node in this renderer, in any execution order. Left dropped, a kit field
  # is called with neither `field` nor `name`, and `name` has no default on purpose: it raises
  # `KeyError` inside LiveView's diff, which is the red box on the surface the form is authored on.
  #
  # So the shape is honoured instead of the value. `f[:email]` is PARSED — never evaluated, the same
  # rule `literal/1` follows — and a blank `%Phoenix.HTML.FormField{}` is built from the nearest
  # ancestor form's own `as`. The delegating clause of a kit field then derives `name`, `value`,
  # `id` and an empty `errors` from it exactly as it does on a published page, so the author sees
  # their field carrying its real input name.
  #
  # The candidates are gathered BEFORE the tree is walked, so a node with nothing expression-shaped
  # on it — most of a document — never pays for the walk to its nearest form.
  defp put_form_fields(assigns_map, node, tree, declared) do
    node.attrs
    |> Enum.flat_map(&binding_candidate(&1, declared))
    |> bind_fields(assigns_map, node, tree)
  end

  defp binding_candidate({name, {:expr, source}}, declared) when is_binary(name) do
    case Map.get(declared, name) do
      nil -> []
      key -> [{key, source}]
    end
  end

  defp binding_candidate(_attr, _declared), do: []

  defp bind_fields([], assigns_map, _node, _tree), do: assigns_map

  defp bind_fields(candidates, assigns_map, node, tree) do
    form = binding_form(tree, node)
    var = let_of(form)
    blank = Phoenix.Component.to_form(%{}, as: param_of(form))

    Enum.reduce(candidates, assigns_map, fn {key, source}, acc ->
      put_form_field(acc, key, PageForms.field_access(source, var), blank)
    end)
  end

  # WHAT THE AUTHOR WROTE, NOT THE KEY IT REDUCES TO. `f[:email]`, `f[:email].name` and
  # `f[:email].value` are all the field `:email` — which is why `PageForms.field_key_from/2` answers
  # the same for the three — but they are three different VALUES, and a renderer needs the one that
  # was asked for. Handing a kit's `name` assign the whole `%Phoenix.HTML.FormField{}` raised
  # `protocol Phoenix.HTML.Safe not implemented` and red-boxed the node, on every kit that binds by
  # name and value rather than by the struct.
  #
  # The path is walked with `Map.fetch/2`, so `f[:email].nonsense` puts no assign at all rather than
  # raising: the author is mid-edit, and a half-typed expression is not a crash.
  defp put_form_field(assigns_map, _key, nil, _blank), do: assigns_map

  defp put_form_field(assigns_map, key, {field, path}, blank),
    do: blank |> Access.get(field) |> read(path) |> put_bound(assigns_map, key)

  defp read(value, []), do: {:ok, value}

  defp read(value, [step | rest]) when is_map(value),
    do: value |> Map.fetch(step) |> stepped(rest)

  defp read(_value, _path), do: :error

  defp stepped({:ok, value}, path), do: read(value, path)
  defp stepped(:error, _path), do: :error

  defp put_bound({:ok, value}, assigns_map, key), do: Map.put(assigns_map, key, value)
  defp put_bound(:error, assigns_map, _key), do: assigns_map

  # The nearest ancestor that binds a `:let`, which is the form this node's `f[:key]` names. Both
  # facts come off that one node so they cannot disagree: a field bound to `f` belongs to the form
  # that bound `f`, and takes its param name from the same place.
  defp binding_form(tree, node) do
    tree
    |> Tree.ancestors(node.id)
    |> Enum.find(&(PageForms.let_var(&1) != nil))
  end

  defp let_of(nil), do: nil
  defp let_of(node), do: PageForms.let_var(node)

  defp param_of(nil), do: "form"
  defp param_of(node), do: PageForms.param_name(node) || "form"

  defp chip_label(%Node{kind: :eex_block, text: text}), do: "<%= #{text} %>"
  defp chip_label(%Node{kind: :eex_comment, text: text}), do: "<%!-- #{text} --%>"
  # An HTML comment's text arrives with its own delimiters, so it already reads as a comment.
  defp chip_label(%Node{kind: :html_comment, text: text}), do: text
  defp chip_label(%Node{text: text}), do: "{#{text}}"

  # Preview mode strips every editor affordance so what an author sees is what a visitor gets — but
  # the author's own inline style stays, because that is page content.
  defp wrapper_style(%{preview?: true, node: node}), do: present(authored_style(node))

  # No selection ring here. The ring is a CSS rule keyed on `data-selected`, and that attribute is
  # set by the hook on the click itself — see the moduledoc. Locking IS server state (it changes what
  # the editor will let you do), so it stays.
  defp wrapper_style(%{node: node, locked: locked} = assigns) do
    case MapSet.member?(locked, node.id) do
      true -> present(authored_style(node) <> @locked_style <> hollow_style(node, assigns))
      false -> present(authored_style(node) <> hollow_style(node, assigns))
    end
  end

  # NO ATTRIBUTE AT ALL RATHER THAN AN EMPTY ONE. Most nodes have nothing to say here, and
  # `style={""}` renders `style=""` — still a style attribute, still refused by `style-src-attr`,
  # once per node on every patch of a document that has a couple of hundred of them. `nil` is the
  # value that can be dropped.
  defp present(""), do: nil
  defp present(style), do: style

  # AND IT HAS TO BE SPLATTED TO ACTUALLY BE DROPPED. `style={nil}` on an ordinary tag renders
  # `style=""` all the same: HEEx compiles a `style` attribute through `empty_attribute_encode/1`,
  # which turns `nil` into an empty string rather than into no attribute. So does a splat of a
  # LITERAL map — the compiler can see the key and takes the same path. A map built at runtime cannot
  # be read at compile time, so it goes through `Phoenix.HTML.attributes_escape/1` instead, which
  # drops a `nil` value outright. `.dynamic_tag` needs none of this: its attributes already travel as
  # a runtime map.
  defp wrapper_attrs(assigns),
    do: Map.merge(%{"style" => wrapper_style(assigns)}, form_marks(assigns))

  # `data-pb-form` on a form (its people name, "" when it does not work yet) and `data-pb-send` on
  # the node a field dropped at a form's end lands in front of. Editing only.
  defp form_marks(%{preview?: true}), do: %{}

  defp form_marks(%{node: %Node{id: id}, form_marks: %{forms: forms, landings: landings}}),
    do: %{
      "data-pb-form" => Map.get(forms, id),
      "data-pb-send" => (MapSet.member?(landings, id) && "true") || nil
    }

  defp form_marks(_assigns), do: %{}

  # AN EMPTY BOX HAS TO BE VISIBLE OR IT IS NOT A BOX. A `<section>` with nothing in it is zero
  # pixels tall: it cannot be clicked, cannot be dropped into, and reads as a drop that failed —
  # which made every structural element in
  # `MishkaCmsCore.Runtime.PageBuilder.Elements` unusable until this existed.
  #
  # EDITING ONLY. `wrapper_style/1`'s preview clause is above this one, so a visitor never sees it,
  # and it is never saved — this is computed at render, not written into the document.
  #
  # A VOID TAG IS CHILDLESS ON PURPOSE. `<img>`, `<hr>` and `<br>` are not empty containers, and
  # outlining them would put a dashed box around every rule on the page.
  defp hollow_style(%Node{kind: :tag, tag: "img"} = node, _assigns) do
    case Node.attr_text(node, "src") do
      source when is_binary(source) and source != "" -> ""
      _unset -> @placeholder_style
    end
  end

  defp hollow_style(%Node{kind: :tag, tag: tag} = node, assigns) when is_binary(tag) do
    case Containment.accepts_children?(tag) and Tree.blank?(assigns.tree, node.id) do
      true -> @hollow_style
      false -> ""
    end
  end

  # A COMPONENT CONTAINER IS A CONTAINER TOO, and leaving it out here made every empty one a dead
  # end: an empty `<.form>` is zero pixels, so it cannot be clicked, cannot be aimed at, and cannot
  # be filled — and it has to be filled before it stops being zero pixels.
  #
  # Only a component that DECLARES somewhere to put content, read off the same `__components__/0`
  # metadata that resolved the function. `<.icon name="hero-x" />` is childless because it draws a
  # glyph, not because it is waiting for something, and outlining it would put a dashed 56px box
  # around every icon on the page. `assigns.target` is set by the clause that renders a function
  # component, so the runtime `.component` wrapper — whose content is its own module's business —
  # never reaches this.
  defp hollow_style(%Node{kind: :component} = node, %{target: {module, fun}} = assigns) do
    case declared_slots(module, fun) != [] and Tree.blank?(assigns.tree, node.id) do
      true -> @hollow_style
      false -> ""
    end
  end

  # THE WELL FOR A COMPONENT THAT WANTS A PICTURE. Below the `%{target: …}` clause, so a function
  # component keeps its own treatment, and above the catch-all so a runtime `.component` finally has
  # one. Same 120px dashed box `el-image` gets, for the same reason and on the same terms: computed
  # at render, never written to the document, and never shown in preview — `wrapper_style/1`'s
  # preview clause sits above all of this.
  defp hollow_style(%Node{kind: :component} = node, %{tree: tree} = assigns) do
    case blank_media(node, assigns[:media_attrs] || %{}, tree) do
      nil -> ""
      _wanted -> @placeholder_style
    end
  end

  defp hollow_style(_node, _assigns), do: ""

  defp authored_style(node) do
    case Node.attr(node, "style") do
      {:string, value} -> ensure_semicolon(value)
      _other -> ""
    end
  end

  defp ensure_semicolon(""), do: ""
  defp ensure_semicolon(value), do: String.trim_trailing(value, ";") <> ";"

  # A tag's own attributes, materialized for rendering. `class` and `style` are merged rather than
  # replaced so the editor's ring survives alongside whatever the author wrote.
  # The `class` attribute is REBUILT rather than passed through. `Tree.Styles` lifts recognised
  # utilities out of what the author wrote and into `meta.styles` — that is what lets the inspector
  # show a real value for a class nobody set visually — so the authored attribute alone is missing
  # every absorbed class. Rendering it raw dropped `flex` off a nav and the menu stacked, while the
  # saved template stayed correct, because only serialization was merging them back.
  defp html_attrs(%Node{attrs: attrs} = node, tree) do
    attrs
    |> Enum.reject(&canvas_owned?/1)
    |> Enum.flat_map(&renderable_attr(&1, node, tree))
    |> Map.new()
    |> put_class(node)
  end

  # A CHARACTER REFERENCE IS A CHARACTER, and the canvas is the only place that used to disagree.
  # `&copy;` is what a footer is written with; interpolating it renders `&amp;copy;`, so the author
  # saw the six letters they typed while every other surface — the published page, the shareable
  # preview — showed ©. A layout is where this bites hardest, because its footer is a copyright line.
  #
  # Only `<` and `>` are escaped, which is the whole difference from interpolation. The browser then
  # reads the run exactly as it will on the page — every entity resolves, a bare `&` stays a bare `&`
  # — and no text can open a tag, so a run the tokenizer read as text cannot restructure the canvas.
  # `MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer` emits the same bytes back, so nothing here is
  # a conversion: the document is unchanged, only what the reader is shown.
  defp text_html(nil), do: Phoenix.HTML.raw("")

  defp text_html(text) do
    text
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> Phoenix.HTML.raw()
  end

  # Typing arrives as characters; the document keeps them as references. See the `set_text` handler.
  defp escape_typed(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape_typed(_text), do: ""

  # THE SAME QUESTION THE INSPECTOR ASKS, of the same node. Display, gap and the column shapes are
  # all classes, and a text run or an expression chip has nowhere to keep one — so on those the
  # Layout button opened a panel where every swatch was a no-op. See `Panels.styleable?/1`.
  defp styleable?(tree, id) do
    case Tree.get(tree, id) do
      %Node{} = node -> Node.container?(node)
      _none -> false
    end
  end

  # A LAYOUT'S ROOT IS `<body>`, AND A DOCUMENT MAY HOLD ONLY ONE. Every layout in this CMS opens
  # with one — it is the element a page is wrapped in — and the canvas is an ordinary document that
  # already has a body of its own. An HTML parser does not nest the second: it merges the start tag's
  # attributes onto the body already there and drops the tag, so the node vanished from the tree the
  # editor was pointing at. On the first render the merge made it look like it had worked; every
  # patch after that rebuilds a fragment, where there is no body to merge onto and the attributes are
  # discarded outright. Recolouring a layout's root changed the saved template and nothing on screen,
  # which reads as an editor that ignores you.
  #
  # A `div` stands in. It nests, it takes the same `data-node-id`, the same classes and the same
  # overrides, so selection, hover, drag and every style control work on it exactly as on any other
  # container — and `MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer` still writes `<body>`, because
  # the substitution is what the canvas draws and never what the document says.
  defp canvas_tag(tag) do
    case tag in Node.document_tags() do
      true -> "div"
      false -> tag
    end
  end

  # THE THREE THE AUTHOR WRITES AND THE CANVAS ANSWERS FOR. `class` and `style` are rebuilt from the
  # node's style overrides by `put_class/2` and `wrapper_attrs/1`, so passing the authored ones
  # through would fight that. A node's own LiveView bindings are not emitted either: the element's
  # `phx-click` would fight the canvas's own selection binding, and its `phx-hook` names a hook that
  # lives in the SITE's bundle — which this frame deliberately does not load — so LiveView logged
  # "unknown hook found" for every one of them. All three remain visible and editable in the
  # inspector's Attributes, because they are still part of the document.
  #
  # Both the tag path and the component path ask here, so a component cannot end up rendering an
  # authored `class` the tag path has already merged onto its wrapper.
  defp canvas_owned?({name, _value}), do: canvas_owned?(name)
  defp canvas_owned?(:root), do: true

  defp canvas_owned?(name) when is_binary(name) do
    name in ["class", "style"] or String.starts_with?(name, "phx-")
  end

  defp canvas_owned?(_name), do: false

  defp put_class(html_attrs, %Node{} = node) do
    case Styles.merge_class(Node.attr_text(node, "class"), node.meta[:styles] || %{},
           important?: node.kind == :component
         ) do
      nil -> html_attrs
      class -> Map.put(html_attrs, "class", class)
    end
  end

  defp renderable_attr({name, {:string, value}}, _node, _tree) when is_binary(name),
    do: [{name, value}]

  defp renderable_attr({name, :boolean}, _node, _tree) when is_binary(name), do: [{name, true}]

  defp renderable_attr({name, {:expr, source}}, node, tree) when is_binary(name) do
    case literal(source) do
      {:ok, value} -> [{name, value}]
      :error -> bound_attr(name, source, node, tree)
    end
  end

  defp renderable_attr(_attr, _node, _tree), do: []

  # A RAW TAG'S BINDING IS SHOWN THE WAY THE PUBLISHED PAGE SHOWS IT. A checkbox bound to its form
  # carries `name={f[:agree].name}`, which reads an assign, so `literal/1` refuses it and the input
  # rendered with no `name` at all — correct in the stored source, blank on the one surface the
  # author looks at, and indistinguishable from the unbound field the audit warns about.
  #
  # The same blank `%Phoenix.HTML.FormField{}` the component path synthesises answers it: the form
  # above the node gives the param name, so `f[:agree].name` resolves to `contact[agree]` exactly as
  # it will once published. A source that resolves to no string — a bare `f[:agree]`, which is the
  # whole struct — is left out rather than interpolated into markup as a struct.
  defp bound_attr(name, source, node, tree) do
    form = binding_form(tree, node)

    case PageForms.field_access(source, let_of(form)) do
      nil -> []
      access -> shown(name, access, Phoenix.Component.to_form(%{}, as: param_of(form)))
    end
  end

  defp shown(name, {field, path}, blank) do
    blank
    |> Access.get(field)
    |> read(path)
    |> case do
      {:ok, value} when is_binary(value) -> [{name, value}]
      _unshowable -> []
    end
  end

  # `size={5}`, `open={true}`, `label={"Hi"}` and `kind={:danger}` are literals and can be shown
  # truthfully. Anything referring to an assign or calling a function is left out — the canvas has no
  # page assigns, and evaluating author-supplied source here would be exactly the eval this rewrite
  # removes. An ATOM is a literal like any other, and refusing it was the reason no Chelekom colour
  # ever showed on the canvas: `chelekom-alert` takes its colour as `kind={:danger}`, and dropping
  # the attribute left every alert rendering the catch-all clause's `natural`.
  @doc """
  The value of an attribute EXPRESSION, when the canvas can resolve it without executing anything.

  Public so the kit-wide example sweep can hold the shipped bundle to the same rule the canvas
  applies, rather than restating it and drifting.
  """
  @spec literal(String.t()) :: {:ok, term()} | :error
  defdelegate literal(source), to: MishkaCmsCore.Builder.Literal, as: :value

  # Which attributes each component cannot render without, keyed by component name — computed once
  # per session rather than per node, because it is asked on every render of every component.
  #
  # This is a CHECK, not a rescue. A component that declares `attr :id, required: true` and writes
  # `<div id={@id}>` raises `KeyError` the moment it is rendered without one, and that raise happens
  # inside LiveView's diff — outside any `try` this module could wrap around the call. Catching it
  # would mean forcing the whole `%Rendered{}` to iodata inside a rescue, which throws away change
  # tracking for that subtree on every diff, forever, to guard a case we can simply look up first.
  defp required_attrs(components) do
    Map.new(components || [], fn entry ->
      {entry.name,
       for(attr <- Inspector.attrs(entry), Inspector.required?(attr), do: Inspector.name(attr))}
    end)
  end

  # WHICH ATTRIBUTES ARE A PICTURE. Read off `Inspector.widget/3` — the same function that decides
  # whether the Inspector draws a media row — rather than off a list of names, so a kit calling one
  # `poster` or `thumbnail` is covered without this having to be told about it.
  #
  # Nine attributes across the kit say `editor: "media"`, and only two of them are REQUIRED. Those
  # two get the "needs src" placeholder and always did; the other seven render for real and render to
  # NOTHING — `chelekom-gallery-media`'s `<img :if={@src}>` collapses to a zero-height div,
  # `chelekom-avatar` draws a src-less `<img>`, and `chelekom-navbar`'s logo is nested inside a
  # `<.link :if={!is_nil(@link)}>` so setting the image alone shows nothing at all. An author dropped
  # one, saw an empty strip, and had nothing to click.
  #
  # Computed once per palette like `required_attrs/1`, because it reads every attribute of every
  # component and the alternative is doing that on every broadcast.
  defp media_attrs(components) do
    Map.new(components || [], fn entry ->
      features = Inspector.features(entry)

      {entry.name,
       for(
         attr <- Inspector.attrs(entry),
         Inspector.widget(attr, features, entry) == :media,
         do: Inspector.name(attr)
       )}
    end)
  end

  # The FIRST media attribute this node has not been given, or `nil` when it has them all. First
  # rather than all, because the well is one box and a click has to mean one thing — and every kit
  # component here declares exactly one.
  defp blank_media(node, media, tree) do
    media
    |> Map.get(Node.component_name(node), [])
    |> Enum.find(&(!filled?(node, &1, tree)))
  end

  # The required attributes this node has not been given. Empty for everything healthy, which is the
  # only path that costs anything on a normal page.
  defp missing_required(node, required, tree) do
    case Map.get(required, Node.component_name(node), []) do
      [] -> []
      names -> Enum.reject(names, &filled?(node, &1, tree))
    end
  end

  # A FUNCTION COMPONENT HAS REQUIRED ATTRIBUTES TOO, AND NOTHING WAS CHECKING THEM.
  # `required_attrs/1` is built from the PALETTE, so it answers for `<.component component_name="…">`
  # and for nothing else — `<.focus_wrap>`, `<.form>`, `<.link>` went straight to `apply/3` with
  # whatever survived `attr_value/1`, which DROPS any expression it cannot fold to a literal. A
  # modal's own `<.focus_wrap id={"#{@id}-modal-content"}>` therefore reached Phoenix with no `id` at
  # all and raised `key :id not found` from inside LiveView's diff. `contain/2` turned that into a
  # red box rather than a dead canvas, which is why the report was "it just shows something like
  # this" — but the author still could not see or edit what was inside the modal.
  #
  # Asked of the ASSEMBLED assigns rather than of the node, because that map is what the component
  # will actually read: a default `put_declared_defaults/3` filled in counts as supplied, and so does
  # a form field `put_form_fields/4` synthesised, without either needing a special case here. It is
  # the same question `missing_required/3` asks of a kit, so the two paths cannot drift.
  defp missing_given(nil, _given), do: []

  defp missing_given({module, fun}, given) do
    for attr <- declared_attr_specs(module, fun),
        Map.get(attr, :required, false),
        not Map.has_key?(given, attr.name),
        do: Atom.to_string(attr.name)
  end

  # WRITTEN IS NOT THE SAME AS SUPPLIED, and this guard used to conflate them. An expression the
  # canvas cannot resolve — `@some_assign`, a function call — is dropped by `attr_value/1` and never
  # reaches the component, so counting it as filled let the render proceed without it and raise.
  #
  # Asking the same question `attr_value/1` answers keeps the two in step: anything it would drop is
  # missing here, and the reader gets the "needs …" placeholder they can act on instead of a canvas
  # that disappears.
  # A BINDING IS SUPPLIED TOO, since `put_form_fields/4` synthesises one. `field={f[:email]}` is an
  # expression `literal/1` refuses, so without this clause a kit field that declares `field`
  # required showed the "needs field" placeholder on a form that renders perfectly well.
  defp filled?(node, name, tree) do
    case Node.attr(node, name) do
      {:string, value} ->
        String.trim(value) != ""

      nil ->
        false

      {:expr, source} ->
        resolvable?(source) or bound?(source, node, tree) or page_form?(node, name)

      _boolean ->
        true
    end
  end

  defp resolvable?(source), do: match?({:ok, _value}, literal(source))

  # A WORKING FORM'S `for` IS THE PAGE'S OWN ASSIGN, `assigns[:contact_form]`, which the compiled page
  # always sets. Chelekom's Simple Form declares `for` required, so every one the editor wired drew
  # "needs for" on the canvas while the live page rendered it. `put_unresolved_kit/4` hands it the
  # stand-in.
  defp page_form?(node, "for"), do: PageForms.form?(node)
  defp page_form?(_node, _name), do: false

  defp bound?(source, node, tree),
    do: PageForms.field_key_from(source, tree |> binding_form(node) |> let_of()) != nil

  # ADDRESSED TO `.component`, NOT TO THE KIT. These two say which component to render and which
  # site's build of it, and `component_assigns/1` puts the resolved values back under the same keys
  # at the end. Left in with the author's other undeclared attributes they went on to the kit's
  # globals, and a field that renders `{@rest}` painted `component_name="chelekom-email-field"` on
  # its own input.
  @wrapper_attrs %{"component_name" => :component_name, "site" => :site}

  # ASKED OF THE COMPILED MODULE, like every other fact the canvas needs about a component. The
  # session's palette entry carries the flag too, but the module is what actually decides which
  # shape was emitted — and it is already loaded by the time this runs, because
  # `component_assigns/1` a few lines down has ensured it.
  defp stateful_entry?(%{node: node, site_scope: site}) do
    name = Node.component_name(node)
    scope = component_site(node, site)

    CompilerHelpers.module_name(name, scope, "Component")
    |> then(& &1.__component_information__([:private, :stateful]))
    |> Kernel.==(true)
  rescue
    _not_loaded_or_no_such_function -> false
  end

  defp component_assigns(%{node: node, tree: tree, site_scope: site} = assigns) do
    scope = component_site(node, site)
    name = Node.component_name(node)
    module = CompilerHelpers.module_name(name, scope, "Component")

    # WHICH ATTRIBUTES SURVIVE IS READ OFF THE COMPILED MODULE, so a component that has never been
    # built declares none and every attribute the author set would be dropped from the preview. A
    # component is built on first use, and reading its metadata is a use — the render a line below
    # would build it anyway, just too late for this. Loaded is the common case and costs a code-table
    # lookup; the compile happens once.
    #
    # ONLY FOR A COMPONENT THE FRAME MAY DRAW. Another site's name is refused by `static_component/1`
    # below, and building it here first would read that site's row and load its module on a tenant's
    # say-so. Left unbuilt, it declares nothing and nothing is drawn.
    _ =
      LiveViewHelpers.renders_here?(scope) and
        LiveViewHelpers.ensure_component_loaded(name, scope)

    specs = runtime_attr_specs(module)
    declared = names(specs)

    node.attrs
    |> Enum.flat_map(&component_attr(&1, module))
    |> Map.new()
    |> put_globals(node, Map.merge(declared, @wrapper_attrs), global_key(specs))
    |> put_form_fields(node, tree, declared)
    |> put_unresolved_kit(node, specs, declared)
    |> Map.merge(slot_assigns(node, tree, assigns))
    |> put_component_class(node, module)
    |> Map.put(@wrapper_attrs["component_name"], name)
    |> Map.put(@wrapper_attrs["site"], scope)
    |> tracked()
  end

  # `put_unresolved/4` for a kit component: an attribute the author wrote as an expression the canvas
  # cannot evaluate, which the kit declares with no default, still reaches the template as a key.
  # Chelekom's form wrapper declares `for` that way, so a wrapper bound to its page form
  # (`for={assigns[:contact_form]}`) raised `key :for not found` on every render. A required one only
  # gets this far when `missing_required/3` counts it as supplied, as a working form's `for`.
  defp put_unresolved_kit(assigns_map, node, specs, declared) do
    Enum.reduce(specs, assigns_map, fn attr, acc ->
      with name when is_binary(name) <- attr_name(attr),
           atom when not is_nil(atom) <- Map.get(declared, name),
           false <- Map.has_key?(acc, atom) or defaulted?(attr),
           {:expr, _source} <- Node.attr(node, name) do
        Map.put(acc, atom, stand_in(kit_type(attr), node, atom))
      else
        _supplied_defaulted_or_unwritten -> acc
      end
    end)
  end

  defp defaulted?(attr) do
    case attr_field(attr, :opts) do
      %{} = opts -> Map.has_key?(opts, "default") or Map.has_key?(opts, :default)
      opts when is_list(opts) -> Keyword.has_key?(opts, :default)
      _no_opts -> false
    end
  end

  @kit_types %{
    "string" => :string,
    "integer" => :integer,
    "float" => :float,
    "boolean" => :boolean,
    "list" => :list,
    "map" => :map
  }

  defp kit_type(attr) do
    case attr_field(attr, :type) do
      type when is_atom(type) -> type
      type when is_binary(type) -> Map.get(@kit_types, type, :any)
      _unknown -> :any
    end
  end

  # THE INSPECTOR EDITS COMPONENTS TOO. `Tree.extract_styles/1` lifts a node's utilities out of its
  # attributes into `meta.styles`, and the two tag clauses put them back through `put_class/2` — but
  # a component's assigns are built from `node.attrs` alone, so every override an author set on a kit
  # component painted nothing until the document was saved and reparsed. Padding, colour, radius,
  # every state: the panel showed the value and the canvas ignored it.
  #
  # Only when the component DECLARES `class`. Handing an undeclared assign to a function component is
  # a compile-time warning at best and a crash at worst, and a kit that styles itself from its own
  # attrs has no business being handed one.
  defp put_component_class(assigns, node, module) do
    with atom when not is_nil(atom) <- declared_attr(module, "class"),
         class when is_binary(class) <-
           Styles.merge_class(Node.attr_text(node, "class"), node.meta[:styles] || %{},
             important?: node.kind == :component
           ) do
      Map.put(assigns, atom, class)
    else
      _undeclared_or_unstyled -> assigns
    end
  end

  # The template's own `site` attribute wins over the editor's site scope. A site's page routinely
  # embeds a GLOBAL component as `<.component component_name="global-footer" site="Global" />`, and
  # the compiled module's name is hashed from *that* value — so scoping it to the page's own site
  # named a module nobody ever compiled and painted the runtime's red "failed to render" over a
  # component that renders perfectly well. An `{:expr, _}` site cannot be evaluated here, so the
  # editor's scope stays the fallback for it.
  defp component_site(node, fallback) do
    case Node.attr(node, "site") do
      {:string, value} -> value
      _other -> fallback
    end
  end

  # A function component built by hand still has to look like one HEEx called: components that use
  # `assign/3` or `assign_new/3` internally (`Phoenix.Component.link/1` does) refuse an assigns map
  # with no change-tracking key. `nil` is the "assume everything changed" value, which is exactly
  # right here — the canvas re-renders a node whenever its subtree is touched.
  defp tracked(assigns), do: Map.put(assigns, :__changed__, nil)

  # Attribute names are resolved against what the component itself declares, so a database-sourced
  # name never mints an atom and an unknown one is dropped rather than raising.
  defp component_attr({name, value}, module) when is_binary(name) do
    case declared_attr(module, name) do
      nil -> []
      atom -> attr_value(value) |> Enum.map(&{atom, &1})
    end
  end

  defp component_attr(_attr, _module), do: []

  defp attr_value({:string, value}), do: [value]
  defp attr_value(:boolean), do: [true]

  defp attr_value({:expr, source}) do
    case literal(source) do
      {:ok, value} -> [value]
      :error -> []
    end
  end

  defp declared_attr(module, name) do
    module
    |> declared_names()
    |> Map.get(name)
  end

  defp declared_names(module), do: module |> runtime_attr_specs() |> names()

  # A kit's attributes come from the module the compilers built for it, which a page can name before
  # anything has built it — so an unloaded module declares nothing rather than raising.
  defp runtime_attr_specs(module) do
    case CompilerHelpers.loaded?(module) do
      false -> []
      true -> apply(module, :__component_information__, [[:component, :attrs]])
    end
  end

  defp names(attrs) when is_list(attrs) do
    for attr <- attrs, name = attr_name(attr), into: %{} do
      {name, String.to_existing_atom(name)}
    end
  end

  defp names(_attrs), do: %{}

  defp attr_name(%{name: name}) when is_binary(name), do: name
  defp attr_name(%{"name" => name}) when is_binary(name), do: name
  defp attr_name(_attr), do: nil

  # Slot children become real Phoenix slot entries. `render_slot/2` accepts a pre-rendered struct as
  # `inner_block`, which is what lets a slot built at runtime behave like one written in a template.
  defp slot_assigns(node, tree, assigns) do
    {slots, plain} =
      node.children
      |> Enum.map(&Tree.get(tree, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.split_with(&(&1.kind == :slot))

    slots
    |> Enum.group_by(&Node.slot_name/1)
    |> Enum.flat_map(fn {name, entries} ->
      case slot_key(name) do
        nil -> []
        key -> [{key, Enum.map(entries, &slot_entry(&1, name, tree, assigns))}]
      end
    end)
    |> Map.new()
    |> put_inner_block(plain, tree, assigns)
  end

  # AN EMPTY `inner_block` IS STILL AN `inner_block`. Omitting it made every component that declares
  # one required unrenderable until something had been dropped inside it, and it cannot be dropped
  # into until it renders — `<.form>` answered the surface it is authored on with a red box.
  #
  # `put_new`, so a document that writes its content out as an explicit `<:inner_block>` keeps it.
  defp put_inner_block(slots, [], tree, assigns) do
    Map.put_new(slots, :inner_block, [
      %{__slot__: :inner_block, inner_block: render_children([], tree, assigns)}
    ])
  end

  defp put_inner_block(slots, plain, tree, assigns) do
    Map.put(slots, :inner_block, [
      %{__slot__: :inner_block, inner_block: render_children(plain, tree, assigns)}
    ])
  end

  defp slot_entry(slot_node, name, tree, assigns) do
    children = Enum.map(slot_node.children, &Tree.get(tree, &1)) |> Enum.reject(&is_nil/1)

    slot_node.attrs
    |> Enum.flat_map(fn
      # `to_existing_atom`, because these names come out of a stored page. An attribute somebody
      # typed into the source window would otherwise mint an atom that is never collected, from
      # document text, on every render — the leak `declared_slots/1` already routes around.
      # A name no slot declares is dropped: the kit would ignore it anyway.
      {attr_name, value} when is_binary(attr_name) ->
        case existing_atom(attr_name) do
          nil -> []
          key -> attr_value(value) |> Enum.map(&{key, &1})
        end

      _attr ->
        []
    end)
    |> Map.new()
    |> put_slot_class(slot_node)
    |> Map.put(:__slot__, slot_key(name))
    |> Map.put(:inner_block, render_children(children, tree, assigns))
  end

  # A SLOT'S OVERRIDES HAVE TO REACH ITS CLASS, and this is the only place they can. Parsing moves
  # every recognised utility OUT of the slot's `class` attribute and into `meta.styles`, so building
  # the slot assigns from `attrs` alone hands the kit a class with the author's overrides missing:
  # the document is right, the canvas paints nothing, and a reload does not rescue it because the
  # next parse lifts them straight back out again. Reported as "we cannot add any style to a table
  # header".
  #
  # `important?: true`, the same as a component, and for the same reason — a slot's class lands
  # inside the kit's own template, where its rules are written as descendant selectors:
  # `chelekom-table`'s default `padding: "small"` emits `[&_table_.table-header]:px-4`, which is
  # 0-2-1 against a plain `p-[8px]`'s 0-1-0 on the very same `<th>`. Without the bang the panel
  # writes a rule that loses to the component's own default, every time.
  defp put_slot_class(assigns, node) do
    case Styles.merge_class(Node.attr_text(node, "class"), node.meta[:styles] || %{},
           important?: true
         ) do
      nil -> assigns
      class -> Map.put(assigns, :class, class)
    end
  end

  defp existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  # A slot nobody declared is dropped: the kit would ignore it, and its name is document text that
  # must not be made into an atom.
  defp slot_key(name) when is_binary(name), do: existing_atom(name)
  defp slot_key(_name), do: :inner_block

  defp render_children(children, tree, assigns) do
    assigns = %{
      children: children,
      tree: tree,
      locked: assigns.locked,
      hidden: assigns.hidden,
      pinned: assigns[:pinned],
      preview?: assigns.preview?,
      site_scope: assigns.site_scope,
      required_attrs: assigns[:required_attrs] || %{},
      # EVERY NODE, WHEREVER IT SITS. This map is written out by hand rather than forwarded, so an
      # assign left out of it is one that silently stops at a component's edge: `media_attrs` was,
      # and a picture-less tile INSIDE a gallery got no well while the same tile beside it did.
      media_attrs: assigns[:media_attrs] || %{},
      conceals: assigns[:conceals],
      shapers: assigns[:shapers],
      form_marks: assigns[:form_marks]
    }

    ~H"""
    <.pb_node
      :for={child <- @children}
      id={child.id}
      tree={@tree}
      locked={@locked}
      hidden={@hidden}
      pinned={@pinned}
      preview?={@preview?}
      site_scope={@site_scope}
      required_attrs={@required_attrs}
      media_attrs={@media_attrs}
      conceals={@conceals}
      shapers={@shapers}
      form_marks={@form_marks}
    />
    """
  end
end
