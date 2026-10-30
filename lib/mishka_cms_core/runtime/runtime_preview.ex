# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.RuntimePreview do
  @moduledoc """
  Builds the sandboxed-iframe document and the Overview details for the runtime
  preview modal (`MishkaCmsCoreWeb.Live.Admin.Components.RuntimePreviewModal`),
  for any module-backed runtime resource.

  `render_document/3` renders a record to a standalone HTML document (doctype + a
  `<head>` that inlines the record's site CSS bundle from
  `MishkaCmsCore.Runtime.States.AssetsState`, so the preview looks like production)
  and returns `{document_html, note}` where `note` is `nil` on a clean render or a
  short explanation otherwise. The document is bound to a sandboxed `<iframe srcdoc>`,
  never with `allow-same-origin`.

  ## A COMPONENT generates its own CSS; everything else links a bundle

  A page, a layout and an error page each belong to one site, so that site's compiled bundle is
  exactly right for them. A component belongs to no site — it is installed once and used by whoever
  uses it — so no bundle is right, and picking the largest one meant a component previewed correctly
  only if some site already rendered it. Backwards, for a browser whose job is showing an
  administrator the components they have NOT used yet.

  So a Component's document carries the same in-browser Tailwind the page builder's canvas runs,
  plus the `@theme` blocks its tokens come from, and generates its rules from its own markup. Its
  frame is the one that gets `allow-scripts` — never with `allow-same-origin` — and the engine is
  inlined rather than linked, because an opaque origin cannot fetch a subresource. Nothing is
  compiled on the server and no site's stylesheet changes, which is the point: a component earns a
  place in a site's CSS by being used in a page, not by being looked at.

  Renderability differs by resource:

    * **Page** / **Component** — render the `:template` to HTML.
    * **Layout** — render `:template` with placeholder `inner_content` (layouts wrap
      other content, so this is an approximation).
    * **ErrorPage** — render a chosen status's `:template` (and its optional per-status
      `:layout`) wrapped in the record's `root_layout_template`, compiled with the same
      `Phoenix.HTML.Engine` the runtime serves it with, so the preview matches production.

  Anything that needs live request data degrades to a styled note; the Code tab still
  shows the real source.

  ## The chrome styles itself with a `<style>`, never a `style` attribute

  A Content-Security-Policy has no nonce to offer an attribute, so the only way to close
  `style-src-attr 'unsafe-inline'` is for the attribute not to exist. A Tailwind class is no help
  here either: the srcdoc document is served no stylesheet but the bundle inlined into its own
  `<head>`, and the `inner_html/4` fragments land in `MishkaCmsWeb.DraftPreviewLive`, whose only
  stylesheet is the per-draft bundle compiled from the draft's own template. A class written in
  THIS module is seen by no Tailwind build.

  So the chrome — the unavailable-preview note, the layout placeholder, the stacked examples, the
  short hints — is written as `mishka-preview-*` classes whose rules travel with them:

    * `document/4` appends `chrome_css/0` to the `<style>` it already writes;
    * `MishkaCmsWeb.DraftPreviewLive` renders `chrome_css/0` into its own NONCED `<style>`, which is
      what the enforced PUBLIC policy needs;
    * `note_body/2` additionally carries a `<style>` of its own, because a note can end up inside an
      author's `root_layout_template` — or be the whole document, when that layout is what failed to
      compile — where neither of the other two homes exists.

  ## Every `<style>` written here takes the CSP nonce

  A `srcdoc` document inherits the EMBEDDER's policy, and `style-src-elem` grants `'self'` plus a
  nonce but not `'unsafe-inline'` — see `MishkaCmsWeb.Runtime.Plugs.SecurityHeaders`. Without a
  nonce the preview's whole stylesheet is refused the moment the ADMIN audience moves from
  `:report_only` to `:enforce`, and the modal shows an unstyled document rather than an error.

  So the nonce is the last argument of every entry point — `render_document/3`,
  `render_error_document/3`, `render_example/3`, `inner_html/4` — and is carried down to each
  `<style>` on the way, `note_body/2` included: a degraded fragment's note lands in
  `MishkaCmsWeb.DraftPreviewLive`, where the PUBLIC policy is already enforced.
  `MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers` reads `socket.assigns[:csp_nonce]`
  for the modal and that LiveView its own; both values come from the session rather than the
  request, which is what lets a re-render keep them — `MishkaCmsCore.Runtime.CspNonce` says why.

  The argument is optional and defaults to `nil`, which emits NO attribute — never the string
  "nil", which names nothing and would block the very stylesheet it was meant to allow. Its value
  is HTML-escaped like the title beside it, so a quote cannot close the attribute; in practice it
  is `Base.encode64/1` output, whose alphabet escaping leaves untouched.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Builder.Events

  alias MishkaCmsCore.Runtime.{
    Page,
    PageDraft,
    Component,
    Layout,
    LayoutDraft,
    ErrorPage,
    ErrorPageDraft
  }

  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.ErrorStatus
  alias MishkaCmsCore.Runtime.LiveViewHelpers
  alias MishkaCmsCore.Runtime.Authoring.Icons
  alias MishkaCmsCore.Runtime.PreviewHooks
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler
  alias MishkaCmsCore.Runtime.States.AssetsState

  @device_widths %{"desktop" => 1280, "tablet" => 768, "mobile" => 375}

  # `requires.components` lists sibling components an example nests, not an option axis.
  @non_axis_requires ["components"]

  @note_css """
  .mishka-preview-note{font-family:ui-sans-serif,system-ui,sans-serif;padding:24px;color:#9f1239}
  .mishka-preview-note-title{font-weight:600;margin:0 0 8px}
  .mishka-preview-note-text{margin:0 0 12px;color:#6b7280}
  .mishka-preview-note-code{white-space:pre-wrap;background:#fff1f2;border:1px solid #fecdd3;border-radius:8px;padding:12px;font-size:12px;overflow:auto}
  """

  @fragment_css """
  .mishka-preview-example{margin-bottom:20px}
  .mishka-preview-placeholder{padding:2rem;border:2px dashed #cbd5e1;border-radius:8px;color:#64748b;text-align:center}
  .mishka-preview-hint{padding:24px;font-family:ui-sans-serif,system-ui,sans-serif;color:#6b7280}
  """

  @doc ~S|Pixel width for a device key (`"desktop"` / `"tablet"` / `"mobile"`).|
  def device_width(device), do: Map.get(@device_widths, device, 1280)

  @doc """
  The rules behind the `mishka-preview-*` classes this module's chrome is written in.

  A host renders these into a `<style>` element it owns, so the chrome needs no `style` attribute.
  `document/4` does it for the sandboxed preview document; `MishkaCmsWeb.DraftPreviewLive` does it
  for the shareable `/_preview/:resource/:token` page, where the element takes the CSP nonce.
  """
  @spec chrome_css() :: String.t()
  def chrome_css, do: @fragment_css <> @note_css

  @doc """
  Assemble the preview document for `record` of `resource`, marking its `<style>` with `nonce`.

  Returns `{document_html, note}` — `note` is `nil` on a clean render, otherwise a
  short message (the document still renders, showing the message/example inside).
  """
  def render_document(record, resource, nonce \\ nil) do
    {html, note} = for_record_site(record, fn -> assemble(record, resource, nonce) end)

    {Events.preview_document(html, %{
       resource: resource,
       record_id: Map.get(record, :id),
       site_id: site_id(record),
       note: note
     }), note}
  end

  defp assemble(record, Page, nonce),
    do: wrap(record, body(record.template, page_assigns(record), nonce), nonce)

  defp assemble(record, PageDraft, nonce),
    do: wrap(record, body(record.template, page_assigns(record), nonce), nonce)

  # A component can't render on its own — its template needs attrs (`@variant`, `@type`, …). So the
  # preview renders its `examples` (real `<.component …/>` invocations that supply the attrs) that
  # this install can render, stacked one per line, like the live page uses them. None → a note.
  defp assemble(record, Component, nonce) do
    case component_examples_list(record) do
      [] ->
        {document(title(record), "", component_no_example_note(nonce), nonce), "no example"}

      examples ->
        {document(
           title(record),
           "",
           stacked_examples(record, examples, nonce),
           nonce,
           generate?: site_id(record)
         ), nil}
    end
  end

  defp assemble(record, resource, nonce) when resource in [Layout, LayoutDraft],
    do:
      wrap(
        record,
        body(record.template, layout_assigns(record), nonce),
        nonce,
        layout_note(record)
      )

  defp assemble(record, resource, nonce) when resource in [ErrorPage, ErrorPageDraft],
    do: error_full_document(record, default_status(record), nonce)

  defp assemble(record, _resource, nonce),
    do:
      {document(
         title(record),
         "",
         note_body(gettext("Preview isn't available for this resource."), nonce),
         nonce
       ), "needs live request"}

  @doc """
  Render one of a Component's `examples` strings (a self-contained `<.component … site="Global" …/>`
  invocation) to a standalone document for the Examples tab. Uses the same TagEngine render + inlined
  site CSS as the Component preview, so `<.component>` resolves to the real compiled module.
  Returns `{document_html, note}`.
  """
  def render_example(source, site \\ "Global", nonce \\ nil) when is_binary(source) do
    {html, note} =
      LiveViewHelpers.rendering_for(site, fn -> body(source, %{site: site}, nonce) end)

    {document(gettext("Example"), "", html, nonce, generate?: theme_site_id(site)), note}
  end

  # EACH PREVIEW RENDERS FOR ITS OWN RECORD'S SITE, and only while it renders: the admin that builds
  # one previews every site's records from the same process. What that site may draw is what its
  # published page may draw — its own components and the global ones — see
  # `MishkaCmsCore.Runtime.LiveViewHelpers.component/1`.
  defp for_record_site(record, fun), do: LiveViewHelpers.rendering_for(site_name(record), fun)

  # Render each example's inner HTML and stack them, one per line, separated by a thin rule.
  defp stacked_examples(record, examples, nonce) do
    Enum.map_join(examples, "\n", fn example ->
      {html, _note} = body(example, %{site: site_name(record)}, nonce)

      # No per-example box/background — just spacing, so the examples sit on the preview background.
      ~s|<div class="mishka-preview-example">#{html}</div>|
    end)
  end

  # `extra.examples` tags each example with the option values it needs (`requires`); an install is
  # narrowed to the axes the operator picked, so an example whose variant/color was never installed
  # is dead markup — drop it. Bundles without `extra.examples` keep the flat `examples` as-is.
  defp component_examples_list(record) do
    case rich_examples(record) do
      [] -> flat_examples(record)
      rich -> installed_examples(record, rich)
    end
  end

  defp installed_examples(record, rich) do
    features = installed_features(record)

    rich
    |> Enum.filter(&example_installed?(Map.get(&1, "requires"), features))
    |> Enum.map(&Map.get(&1, "source"))
    |> Enum.filter(&renderable_example?/1)
    |> case do
      [] -> base_example(record, rich)
      sources -> sources
    end
  end

  # Every axis the example needs must be a subset of what the record actually ships. An axis the
  # record says nothing about (no discriminators for it) is no evidence of absence — keep it.
  defp example_installed?(%{} = requires, features) do
    requires
    |> Map.drop(@non_axis_requires)
    |> Enum.all?(fn {axis, values} ->
      case Map.get(features, axis) do
        nil -> true
        installed -> values |> List.wrap() |> Enum.all?(&(&1 in installed))
      end
    end)
  end

  defp example_installed?(_requires, _features), do: true

  # The option universe the record was installed with, folded from its helpers' `discriminators`
  # (narrowing physically drops the ruled-out helper clauses). `UiKitHandler.component_features/1`
  # owns that fold, but reads a string-keyed bundle map — the record carries `Helper` structs.
  defp installed_features(record) do
    record
    |> Map.get(:helpers)
    |> List.wrap()
    |> Enum.map(&%{"discriminators" => List.wrap(helper_discriminators(&1))})
    |> then(&UiKitHandler.component_features(%{"helpers" => &1}))
  end

  defp helper_discriminators(helper) when is_map(helper),
    do: Map.get(helper, :discriminators) || Map.get(helper, "discriminators")

  defp helper_discriminators(_helper), do: []

  # Showing the base example beats showing nothing when narrowing ruled every example out.
  defp base_example(record, rich) do
    rich
    |> Enum.find_value(fn
      %{"base" => true, "source" => source} -> renderable_example?(source) && source
      _ -> nil
    end)
    |> case do
      source when is_binary(source) -> [source]
      _ -> record |> flat_examples() |> Enum.take(1)
    end
  end

  defp rich_examples(%{extra: %{"examples" => examples}}) when is_list(examples),
    do: Enum.filter(examples, &is_map/1)

  defp rich_examples(_record), do: []

  defp flat_examples(%{examples: examples}) when is_list(examples),
    do: Enum.filter(examples, &renderable_example?/1)

  defp flat_examples(_record), do: []

  defp renderable_example?(example), do: is_binary(example) and example != ""

  # Any site's compiled CSS bundle styles a global component — they're baked into every site's CSS.
  # Pick the largest non-empty bundle in `AssetsState` (a full site bundle carries every component's
  # utility classes), so the examples render with their real colors/variants.
  @doc """
  The `@theme` blocks a browser-side Tailwind generator needs, for `site_id` and the global rows.

  Only the theme travels: a kit's tokens (`--color-primary-…`) are what turn `bg-primary` into a
  colour and the generator cannot know them, while the rest of a stylesheet is already in whatever
  compiled bundle the document links — sending it twice would have it fight itself in the cascade.

  Public so that an editor's canvas (the `mishka_cms_builder` package's) asks the same question of
  the same engine.
  """
  @spec theme_source(String.t() | nil) :: String.t()
  def theme_source(site_id \\ nil), do: site_id |> stylesheet_source() |> theme_blocks()

  @doc """
  The full CSS of the stylesheet rows for `site_id` and the global ones.

  BOTH HALVES ARE NEEDED, and only together. A kit's `@theme` block is mostly ALIASES —

      @theme { --color-base-border-light: var(--base-border-light); }

  — and the variable it points at is declared outside that block, in a plain `:root` rule further up
  the same row. Ship the block alone and every alias dead-ends: the generator emits
  `border-color: var(--color-base-border-light)`, the chain resolves to nothing, and the browser
  falls back to black on a component whose border is grey.

  So a preview document carries this whole thing in an ordinary `<style>` — where the browser
  applies the `:root` rules and ignores the `@theme` at-rule it does not know — and the extracted
  blocks separately as `type="text/tailwindcss"`, which is the only part the generator reads.

  The canvas needs no equivalent: it links the site's COMPILED bundle, where Tailwind has already
  turned all of this into resolved `:root` variables.
  """
  @spec stylesheet_source(String.t() | nil) :: String.t()
  def stylesheet_source(site_id \\ nil) do
    [nil, site_id]
    |> Enum.uniq()
    |> Enum.flat_map(&compiler_stylesheets/1)
    |> Enum.map_join("\n", & &1.content)
  end

  defp compiler_stylesheets(site_id) do
    MishkaCmsCore.Runtime.Stylesheet
    |> Ash.Query.for_read(:for_compiler, %{site_id: site_id}, authorize?: false)
    |> Ash.read(page: false, authorize?: false)
    |> case do
      {:ok, %{results: sheets}} -> sheets
      {:ok, sheets} when is_list(sheets) -> sheets
      _error -> []
    end
  end

  defp theme_blocks(css) when is_binary(css) do
    ~r/@theme[^{]*\{(?:[^{}]|\{[^{}]*\})*\}/
    |> Regex.scan(css)
    |> Enum.map_join("\n", &hd/1)
  end

  defp theme_blocks(_css), do: ""

  defp component_no_example_note(nonce),
    do:
      note_body(
        gettext(
          "This component has no example yet — add one to preview it (a component needs attributes to render)."
        ),
        nonce
      )

  @doc """
  Render `record`'s template to just the inner body HTML (no doctype/head), for embedding inside the
  real LiveView preview (`MishkaCmsWeb.DraftPreviewLive`) — where the per-site JS bundle and the
  temporary draft CSS are linked by the layout. Returns the HTML string (or a styled note).

  For an ErrorPage, `status` selects which code (404/500/… or `:offline`) to render; nil falls back
  to the `status` in `request`'s `:query_params`, then to the first entry.
  A fragment that degrades to a note carries a `<style>` of its own, so `nonce` reaches that too.

  For a Page, `request` is the address the preview was opened at: `:path` is handed to the template
  as `@page.path` and `:query_params` as `@query_params`, so a page that links to itself —
  `base={@page.path}` with `params={@query_params}` — pages inside the preview instead of leaving
  it. Without them the template sees the record's own path and an empty query.
  """
  def inner_html(record, resource, status \\ nil, nonce \\ nil, site \\ nil, request \\ []) do
    # An author's preview, drawn to a string, so kept out of `MishkaCmsCore.Runtime.RenderMetrics`.
    MishkaCmsCore.Runtime.RenderMetrics.unmeasured(fn ->
      drawn_inner(record, resource, status, nonce, site, request)
    end)
  end

  defp drawn_inner(record, resource, _status, nonce, site, request)
       when resource in [Page, PageDraft],
       do: render_inner(previewable(record.template, site), page_assigns(record, request), nonce)

  defp drawn_inner(record, resource, _status, nonce, site, _request)
       when resource in [Layout, LayoutDraft],
       do: render_inner(previewable(record.template, site), layout_assigns(record), nonce)

  defp drawn_inner(record, Component, _status, nonce, _site, _request) do
    case component_examples_list(record) do
      [] ->
        ~s|<div class="mishka-preview-hint">#{escape(gettext("This component needs attributes — add an example to preview it."))}</div>|

      examples ->
        stacked_examples(record, examples, nonce)
    end
  end

  defp drawn_inner(record, resource, status, nonce, _site, request)
       when resource in [ErrorPage, ErrorPageDraft],
       do: error_page_inner(record, status || requested_status(request), nonce)

  defp drawn_inner(_record, _resource, _status, _nonce, _site, _request),
    do:
      ~s|<div class="mishka-preview-hint">#{escape(gettext("Live preview isn't available for this type yet."))}</div>|

  defp render_inner(template, assigns, nonce), do: elem(body(template, assigns, nonce), 0)

  # A HOOK NAMED FOR ANOTHER SITE, POINTED AT THIS ONE'S — and only in a preview. On a published page
  # a hook the site does not have is a hook it does not get, correctly; here the whole point is to
  # show whether the page WORKS, and a master opening one page under three sites would get a button
  # that draws and does nothing on two of them. See `MishkaCmsCore.Runtime.PreviewHooks`.
  defp previewable(template, nil), do: template
  defp previewable(template, site), do: PreviewHooks.resolve(template, site)

  defp error_page_inner(record, status, nonce) do
    case resolve_status(record, status) do
      nil ->
        ~s|<div class="mishka-preview-hint">#{escape(gettext("No error templates to preview yet."))}</div>|

      resolved ->
        elem(error_inner_body(record, resolved, nonce), 0)
    end
  end

  # Keep the chosen status when the record actually has it, else fall back to the first one.
  defp resolve_status(record, status) do
    statuses = error_statuses(record)
    status = ErrorStatus.parse(status)
    if status in statuses, do: status, else: List.first(statuses)
  end

  # The preview's own address names the entry as text, `?status=offline` included.
  defp requested_status(request) do
    case Keyword.get(request, :query_params) do
      %{"status" => status} -> ErrorStatus.parse(status)
      _none -> nil
    end
  end

  @doc """
  The statuses present in an ErrorPage record's `error_pages` collection (in order) — HTTP codes,
  and `:offline` for the page an offline site shows.
  """
  def error_statuses(record),
    do:
      record
      |> Map.get(:error_pages)
      |> List.wrap()
      |> Enum.map(&estatus/1)
      |> Enum.reject(&is_nil/1)

  defp default_status(record), do: record |> error_statuses() |> List.first()

  defp estatus(entry), do: ErrorStatus.parse(Map.get(entry, :status) || Map.get(entry, "status"))

  @doc """
  Render ONE error code's COMPLETE page exactly like the runtime serves it: the status's `:template`
  (then its optional per-status `:layout`) wrapped in the ErrorPage's `root_layout_template`, or the
  default document when none is set. Compiled with `Phoenix.HTML.Engine` — the same engine
  `MishkaCmsCore.Runtime.Compilers.ErrorCompiler` uses — so a server-rendered root layout's
  attribute interpolation (`content="<%= ... %>"`) renders instead of raising. Returns `{html, note}`.
  """
  def render_error_document(record, status, nonce \\ nil),
    do: for_record_site(record, fn -> error_full_document(record, status, nonce) end)

  defp error_full_document(record, nil, nonce),
    do:
      {document(
         title(record),
         css_bundle(record),
         note_body(gettext("No error page template to preview."), nonce),
         nonce
       ), "no template"}

  defp error_full_document(record, status, nonce) do
    case find_status(record, status) do
      nil ->
        {document(
           title(record),
           css_bundle(record),
           note_body(gettext("No template for status %{status}.", status: status), nonce),
           nonce
         ), "no template"}

      _entry ->
        {inner, note} = error_inner_body(record, status, nonce)
        render_root_layout(record, status, inner, note, nonce)
    end
  end

  # The inner page for a status: its `:template`, then its optional per-status `:layout`
  # (mirrors ErrorCompiler's `render/2 -> layout/2`). `{html, note}`.
  defp error_inner_body(record, status, nonce),
    do: error_inner_body(record, status, nonce, find_status(record, status))

  defp error_inner_body(_record, status, nonce, nil),
    do:
      {note_body(gettext("No template for status %{status}.", status: status), nonce),
       "no template"}

  defp error_inner_body(record, status, nonce, entry) do
    # Inner + per-status layout render through the HEEx TagEngine (like the live server) so
    # `<.component site={@site} />` and `phx-*` hooks work; `site`/`page` mirror page_assigns/1.
    assigns = %{
      conn: preview_conn(record, status),
      status: status,
      site: site_name(record),
      page: record,
      inner_content: ""
    }

    {inner, note} = render_heex(entry_template(entry), assigns, nonce)

    case status_layout_template(entry) do
      nil ->
        {inner, note}

      layout_template ->
        {wrapped, layout_note} =
          render_heex(layout_template, %{assigns | inner_content: Phoenix.HTML.raw(inner)}, nonce)

        {wrapped, note || layout_note}
    end
  end

  # Wrap the inner page in the record's `root_layout_template` (classic `Phoenix.HTML.Engine`, so it
  # may use `@conn`/csrf/site-CSS attribute interpolation like the live server), or the default full
  # document when none is set.
  defp render_root_layout(record, status, inner, note, nonce) do
    case Map.get(record, :root_layout_template) do
      root when is_binary(root) and root != "" ->
        {html, root_note} =
          render_html(
            root,
            %{
              conn: preview_conn(record, status),
              status: status,
              site: site_name(record),
              page: record,
              inner_content: Phoenix.HTML.raw(inner)
            },
            nonce
          )

        {html, note || root_note}

      _ ->
        {document(
           gettext("%{title} — %{status}", title: title(record), status: status),
           css_bundle(record),
           inner,
           nonce
         ), note}
    end
  end

  # HEEx render for error inner/per-status-layout templates (components + hooks resolve).
  defp render_heex(template, assigns, nonce) do
    case LiveViewCompiler.render_template(template, assigns) do
      html when is_binary(html) -> {html, nil}
      {:error, message} -> {note_body(message, nonce), message}
    end
  end

  defp render_html(template, assigns, nonce) do
    case LiveViewCompiler.render_html_template(template, assigns) do
      html when is_binary(html) -> {html, nil}
      {:error, message} -> {note_body(message, nonce), message}
    end
  end

  defp entry_template(entry), do: Map.get(entry, :template) || Map.get(entry, "template") || ""

  defp status_layout_template(entry) do
    case Map.get(entry, :layout) || Map.get(entry, "layout") do
      %{} = layout -> Map.get(layout, :template) || Map.get(layout, "template")
      _ -> nil
    end
  end

  defp find_status(record, status) do
    status = ErrorStatus.parse(status)
    Enum.find(List.wrap(Map.get(record, :error_pages)), &(estatus(&1) == status))
  end

  # A `conn`-shaped assign so a server-style root layout's `@conn.assigns.current_site` resolves to
  # the record's loaded site — its CSS/JS injection then matches what the live page renders.
  # THE ONE DOCUMENT THAT IS ABOUT THE REQUEST. An error page links back to where the visitor was —
  # the seeded 500 carries `<a href={@conn.request_path}>Try again</a>` — and that is correct markup
  # for the live page and the exact thing a preview has no request for. The stand-in used to be the
  # site and nothing else, so the template raised and the preview showed a red box instead of the
  # page it exists to show.
  #
  # These are stand-ins, not guesses at a real request: the path a preview would "retry" is the
  # site's root, and none of these values reaches a pixel — they land in an `href` and a line of
  # copy. `status` is the one the author chose in the strip, so the page says the number it is for;
  # the offline page is answered as a 503, as `MishkaCms.Plugs.MaintenanceGate` answers it.
  defp preview_conn(record, status) do
    %{
      assigns: %{current_site: preview_site(record)},
      request_path: "/",
      query_string: "",
      method: "GET",
      host: preview_host(record),
      status: http_status(status)
    }
  end

  defp http_status(:offline), do: 503
  defp http_status(status), do: status

  defp preview_site(record) do
    case Map.get(record, :site) do
      %{name: name} = site when is_binary(name) -> site
      _ -> nil
    end
  end

  defp preview_host(record) do
    case Map.get(record, :site) do
      %{host: host} when is_binary(host) -> host
      _ -> "localhost"
    end
  end

  defp css_bundle(record), do: AssetsState.get_value(site_name(record), "css") || ""

  @doc """
  Parse the Code-tab's serialized error pages (`<!-- 404 -->`-delimited blocks, `<!-- offline -->`
  for the offline page, as produced by `source/1`) back into the `error_pages` collection
  (`[%{status, template}]`). Used when saving an `ErrorPageDraft` from the editor.
  """
  def parse_error_pages(text) when is_binary(text) do
    ~r/<!--\s*(\d+|offline)\s*-->\s*\n?(.*?)(?=\n*<!--\s*(?:\d+|offline)\s*-->|\z)/s
    |> Regex.scan(text)
    |> Enum.map(fn [_, status, template] ->
      %{status: ErrorStatus.parse(status), template: String.trim(template)}
    end)
  end

  def parse_error_pages(_text), do: []

  # A layout wraps a page via `@inner_content`. For a standalone preview we fill that slot with the
  # layout's own `:example` HTML (so it renders for real), falling back to a dashed placeholder.
  defp layout_assigns(record),
    do: Map.put(page_assigns(record), :inner_content, layout_inner_content(record))

  @doc """
  What a layout is previewed around: its `example`, or a placeholder.
  """
  def layout_inner_content(%{example: example}) when is_binary(example) and example != "",
    do: Phoenix.HTML.raw(example)

  def layout_inner_content(_record), do: placeholder()

  defp layout_note(%{example: example}) when is_binary(example) and example != "", do: nil

  defp layout_note(_record),
    do:
      gettext(
        "Layout wraps page content — previewed with placeholder content (add an Example to render real content)."
      )

  @doc """
  Overview detail rows (`{label, value}`) for `record` of `resource`. Resource-specific
  fields (section, priority, layout) appear only when present.
  """
  def details(record, resource) do
    config = MishkaCmsCore.Runtime.RuntimeStatus.config(resource)

    [
      {gettext("Type"), config.label},
      maybe_row(gettext("Section"), Map.get(record, :section)),
      {gettext("Format"), format_value(record)},
      maybe_row(gettext("Priority"), Map.get(record, :priority)),
      maybe_row(gettext("Layout"), layout_name(record))
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc "Human file size of the record's source."
  def file_size(record), do: format_bytes(byte_size(source(record)))

  @doc "The record's raw source string for the Code tab."
  def source(record) do
    cond do
      is_binary(Map.get(record, :template)) -> record.template
      is_binary(Map.get(record, :content)) -> record.content
      is_list(Map.get(record, :error_pages)) -> error_pages_source(record.error_pages)
      true -> ""
    end
  end

  defp error_pages_source(pages) do
    Enum.map_join(pages, "\n\n", fn page ->
      status = Map.get(page, :status) || Map.get(page, "status")
      template = Map.get(page, :template) || Map.get(page, "template") || ""
      "<!-- #{status} -->\n#{template}"
    end)
  end

  defp wrap(record, {body_html, error_note}, nonce, info_note \\ nil) do
    css = AssetsState.get_value(site_name(record), "css") || ""
    {document(title(record), css, body_html, nonce), error_note || info_note}
  end

  defp body(template, assigns, nonce) when is_binary(template) do
    case LiveViewCompiler.render_template(template, assigns) do
      html when is_binary(html) -> {html, nil}
      {:error, message} -> {note_body(message, nonce), message}
    end
  end

  defp body(_template, _assigns, nonce),
    do: {note_body(gettext("Nothing to render."), nonce), "empty"}

  defp document(title, css, body, nonce, opts \\ []) do
    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>#{escape(title)}</title>
        <style#{nonce_attr(nonce)}>#{css}
    #{chrome_css()}</style>
    #{generator(Keyword.get(opts, :generate?, false), body, nonce)}
      </head>
      <body>#{body}</body>
    </html>
    """
  end

  # THE SAME ENGINE THE CANVAS RUNS, for the same reason: these classes belong to a component, not to
  # a site, so no site's compiled bundle is the right answer for them. The engine reads the markup
  # and writes the rules it needs — which is precisely the question a component preview asks — and
  # nothing is compiled on the server or added to any site's stylesheet.
  #
  # INLINED RATHER THAN LINKED, because the frame is sandboxed without `allow-same-origin` and an
  # opaque origin cannot fetch a subresource: `<script src>` is refused, with no CSP violation to
  # explain it. Granting `allow-same-origin` would let the frame reach the admin document and remove
  # its own sandbox, which is not a trade worth 281 KB. So the bytes travel with the document, and
  # only ever to an administrator who opened the Preview tab — a visitor never sees them.
  #
  # The nonce shim in front is the one `root.html.heex` uses for the canvas: the engine delivers its
  # output through a `<style>` element and offers no nonce option, while `srcdoc` inherits the ADMIN
  # policy, whose `style-src-elem` names a nonce and not `'unsafe-inline'`.
  defp generator(false, _body, _nonce), do: ""

  defp generator(site_id, body, nonce) do
    case engine_source() do
      "" ->
        ""

      engine ->
        sheets = stylesheet_source(site_id)

        # The icons FIRST and in a `<style>` of their own, so their layer order comes before any layer
        # a stylesheet row declares, and a row's `@import` stays first in its own `<style>`.
        """
        <style#{nonce_attr(nonce)}>#{body |> Icons.classes_in() |> Icons.css()}</style>
            <style#{nonce_attr(nonce)}>#{sheets}</style>
            <style type="text/tailwindcss"#{nonce_attr(nonce)}>#{theme_blocks(sheets)}</style>
            <script#{nonce_attr(nonce)}>
              (() => {
                const nonce = document.currentScript.nonce;
                const make = document.createElement.bind(document);
                document.createElement = (tag, ...rest) => {
                  const el = make(tag, ...rest);
                  if (String(tag).toLowerCase() === "style") el.setAttribute("nonce", nonce);
                  return el;
                };
              })();
            </script>
            <script#{nonce_attr(nonce)}>#{engine}</script>\
        """
    end
  end

  @engine_key {__MODULE__, :tailwind_browser}
  @engine_path "priv/admin_assets/vendor/tailwind-browser.js"

  # Read once per node and kept in `:persistent_term` — one shared copy, and no disk read on the way
  # to rendering a preview. Missing file degrades to no generator at all: the preview renders
  # unstyled, which is what it did before, rather than a broken document.
  defp engine_source do
    case :persistent_term.get(@engine_key, :unread) do
      :unread ->
        source =
          case :mishka_cms_core |> Application.app_dir(@engine_path) |> File.read() do
            {:ok, js} -> js
            {:error, _reason} -> ""
          end

        :persistent_term.put(@engine_key, source)
        source

      source ->
        source
    end
  end

  defp nonce_attr(nonce) when is_binary(nonce) and nonce != "", do: ~s| nonce="#{escape(nonce)}"|

  defp nonce_attr(_nonce), do: ""

  defp placeholder do
    Phoenix.HTML.raw(
      ~s|<div class="mishka-preview-placeholder">#{escape(gettext("Page content appears here"))}</div>|
    )
  end

  @doc """
  The "Preview unavailable" note for `message`, with its own `<style>` marked with `nonce`.
  """
  def note_body(message, nonce) do
    """
    <style#{nonce_attr(nonce)}>#{@note_css}</style>
    <div class="mishka-preview-note">
      <p class="mishka-preview-note-title">#{escape(gettext("Preview unavailable"))}</p>
      <p class="mishka-preview-note-text">
        #{escape(gettext("This needs data that only exists when served live. The source is still on the Code tab."))}
      </p>
      <pre class="mishka-preview-note-code">#{escape(redact(message))}</pre>
    </div>
    """
  end

  # WHAT THE NOTE MAY SAY. `/_preview/:resource/:token` takes no login — the token is the capability,
  # and the link gets handed to whoever needs to look at the page — so an exception message is not
  # free text to publish. `KeyError` inspects the map it searched, which here is the assigns: the
  # note was printing the site's id, host and allowed origins into a shareable page.
  #
  # The half worth reading is the part before the dump — "key :request_path not found" — and every
  # other failure this note carries is a compile error, which has no term in it and is unharmed by
  # the cap.
  @note_limit 300

  defp redact(message) when is_binary(message) do
    message
    |> String.split(" in: ", parts: 2)
    |> hd()
    |> String.slice(0, @note_limit)
  end

  defp redact(message), do: message |> inspect() |> String.slice(0, @note_limit)

  # Assigns a page/draft template expects at render time. `site` is the critical one: nested
  # `<.component name="..." site={@site} />` calls compute their module from it, so without it
  # they resolve to the "Global" module and fail to render.
  # `query_params` EMPTY RATHER THAN ABSENT. `MishkaCmsWeb.RuntimeLive` assigns the visitor's query
  # string under this name, so a page template may read it — and the admin's Preview tab has no
  # address bar. Absent would raise `key :query_params not found` and turn a page that pages itself
  # through the URL into a preview nobody can open.
  #
  # THE SHAREABLE PREVIEW DOES HAVE ONE, and `request` carries it. Its path stands in for the page's
  # own, because every template link built on `@page.path` means "this page" — and in a preview this
  # page lives at `/_preview/…`, not at the published path, which is a different page to the router.
  #
  # `page_languages` EMPTY FOR THE SAME REASON as `query_params`: `RuntimeLive` assigns a page's other
  # editions under it, and a preview is no published URL to have alternates of.
  defp page_assigns(record, request \\ []) do
    %{
      page: Map.put(record, :path, Keyword.get(request, :path, Map.get(record, :path))),
      site: site_name(record),
      query_params: Keyword.get(request, :query_params, %{}),
      page_languages: []
    }
  end

  defp title(record), do: Map.get(record, :name) || gettext("Preview")

  defp site_name(%{site: %{name: name}}) when is_binary(name), do: name
  defp site_name(_record), do: "Global"

  # A TENANT component may use a token its own site declares, and the generator resolves nothing it
  # has not been handed. `nil` reads the global rows alone, which is right for a global component.
  defp site_id(%{site: %{id: id}}) when is_binary(id), do: id
  defp site_id(_record), do: nil

  # The examples route carries a site NAME, because that is what a `<.component site="…">` attribute
  # holds and what the module hash is built from. The theme lookup wants the id.
  defp theme_site_id(name) when name in [nil, "Global"], do: nil

  defp theme_site_id(name) do
    case MishkaCmsCore.Runtime.States.SiteState.get_by_name(name) do
      {:ok, site} -> site.id
      {:error, :not_found} -> nil
    end
  end

  defp layout_name(%{layout: %{name: name}}) when is_binary(name), do: name
  defp layout_name(%{tenant_layout: %{name: name}}) when is_binary(name), do: name
  defp layout_name(_record), do: nil

  defp format_value(record) do
    case Map.get(record, :format) do
      nil -> "—"
      format -> to_string(format)
    end
  end

  defp maybe_row(_label, nil), do: nil
  defp maybe_row(_label, ""), do: nil
  defp maybe_row(label, value), do: {label, to_string(value)}

  @doc "`n` bytes as the modal shows a size: `812 B`, `7.8 KB`, `1.2 MB`."
  @spec format_bytes(non_neg_integer()) :: String.t()
  def format_bytes(n) when n < 1024, do: gettext("%{size} B", size: n)

  def format_bytes(n) when n < 1_048_576,
    do: gettext("%{size} KB", size: Float.round(n / 1024, 1))

  def format_bytes(n), do: gettext("%{size} MB", size: Float.round(n / 1_048_576, 1))

  defp escape(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
