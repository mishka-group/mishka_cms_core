# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers do
  @moduledoc """
  Shared wiring for the runtime "Preview" modal across every module-backed runtime
  admin table (Page / Component / Layout / ErrorPage).

  Each page keeps its own thin `handle_info` / `handle_async` / `handle_event` clauses
  and delegates here, reusing the `runtime_status_opts` that
  `MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.RuntimeStatusLive.setup/2` already
  stored (resource + master/tenant action + loads):

      def mount(...), do: socket |> RuntimeStatusLive.setup(...) |> PreviewHelpers.setup()

      def handle_info({:row_action, "show_preview_modal", %{"id" => id}}, s),
        do: {:noreply, PreviewHelpers.open(s, id)}

      def handle_async(name, result, s) when name in [:load_preview, :preview_versions, :preview_compile],
        do: {:noreply, PreviewHelpers.async_result(s, name, result)}

      def handle_event("preview_set_tab", %{"tab" => t}, s),
        do: {:noreply, PreviewHelpers.set_tab(s, t)}

  Render the modal once per page with `<RuntimePreviewModal.modal preview={@preview} />`.

  ## One modal, and everything in it is lazy

  Viewing and editing are the same modal: `open/2` lands on Overview, `open_configuration/2` on the
  Configuration tab that hosts the resource's `MishkaGervaz.Form.Web.Live` form. A page therefore
  mounts that form ONCE, which is also why it has to be here — two mounts of one form component on a
  page is two answers to "which record is open", and the DOM ids collide.

  Nothing in the modal does work before somebody asks for it:

    * the record + status + drafts load in `start_async` on open, behind a spinner;
    * the Preview tab builds its document — and, for a lazy record, compiles it — on first visit;
    * the Configuration tab mounts the form, and so reads the row and its relation options, on
      first visit;
    * the Versions tab pages and restores off the LiveView process.

  That last property is the point of `async_result/3`: separate async names, because
  `start_async/3` cancels an in-flight task that shares a name.

  ## The preview document is built here, so the CSP nonce is read here

  The modal only hands `@html` / `@edit_html` to an `<iframe srcdoc>`; the document itself is
  assembled by `MishkaCmsCore.Runtime.RuntimePreview`, from this module — `set_tab/2` on the first
  visit to the Preview tab, and `rerender/2` on an unsaved edit. A srcdoc document inherits the
  ADMIN policy, whose `style-src-elem` names a nonce and not `'unsafe-inline'`, so the document's
  `<style>` needs one or the whole preview renders unstyled once that policy is enforced.

  Both read `socket.assigns[:csp_nonce]` — through `Access`, so a page that somehow never ran
  `MishkaCmsCore.Runtime.CspNonce` gets `nil` and a `<style>` with no attribute rather than a crash.
  Both also run in the LiveView process rather than the async load task, which is what lets them
  read the socket at all.

  ## Nothing compiles until the Preview tab

  Rendering the document runs the record for real, and a record is built by the first thing that
  renders it. Doing that on modal open meant clicking the eye compiled a component, so the Pipeline
  tab reported "Live" about one nothing had ever rendered. Overview, Code, Versions and Pipeline
  read the record and never run it; only the Preview tab does.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  import Phoenix.LiveView, only: [push_event: 3, put_flash: 3, attach_hook: 4]
  import Phoenix.Component, only: [assign: 3]
  require Ash.Query

  alias MishkaCmsCore.Runtime.{RuntimePreview, RuntimeStatus, DraftPreviewAssets, ComponentCopy}
  alias MishkaCmsCore.Runtime.{Languages, PageEditions}
  alias MishkaCmsCore.Runtime.States.{AssetsState, SiteState}
  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.Helpers, as: RuntimeHelpers
  alias MishkaCmsCore.Runtime.PageBuilder.CodeAccess
  alias MishkaCmsCore.Runtime.PageBuilder.Section
  alias MishkaCmsCoreWeb.Templates.VersionHistory
  alias MishkaCmsCore.Runtime.Compilers.Helpers, as: CompilerHelpers
  alias MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler
  alias MishkaCmsCore.Runtime.RenderMetrics

  # The host's endpoint, named by configuration rather than hardcoded — this library does not know
  # which application it is installed into. Applied rather than called so it stays a runtime
  # dispatch: the host's endpoint is not compile-visible from here.
  @host_endpoint Application.compile_env!(:mishka_cms_core, :endpoint)

  @modal_id "runtime-preview-modal"
  @versions_per_page 5
  @drafts_per_page 5
  @metrics_every :timer.seconds(5)

  # The records built into a site's bundle rather than rendered: their card is about that bundle.
  @bundled [MishkaCmsCore.Runtime.Stylesheet, MishkaCmsCore.Runtime.JsHook]

  # The records whose renders `MishkaCmsCore.Runtime.RenderMetrics` times.
  @timed [
    MishkaCmsCore.Runtime.Component,
    MishkaCmsCore.Runtime.Page,
    MishkaCmsCore.Runtime.Layout,
    MishkaCmsCore.Runtime.ErrorPage
  ]

  # Every runtime resource this modal opens carries a "Configuration" tab hosting its MishkaGervaz
  # form, so the record is read, inspected and edited in ONE place. Editing used to mean a second,
  # separate `<resource>-form-modal` on the page, which meant two mounts of the same form component
  # and two answers to "which record is open".
  @configurable [
    MishkaCmsCore.Runtime.JsHook,
    MishkaCmsCore.Runtime.Stylesheet,
    MishkaCmsCore.Runtime.Component,
    MishkaCmsCore.Runtime.Layout,
    MishkaCmsCore.Runtime.Page,
    MishkaCmsCore.Runtime.ErrorPage
  ]

  @doc "True when the resource's preview modal includes a Configuration (form) tab."
  def has_config?(resource), do: resource in @configurable

  # THE RUNTIME TYPE EACH RESOURCE IS WRITTEN AS — `MishkaCmsCore.Runtime.Helpers.writers/1` names
  # who writes it. Reading the list and this modal is open to every dashboard admin; every control
  # that writes is offered, and run, only for a writer.
  @types %{
    MishkaCmsCore.Runtime.Page => "page",
    MishkaCmsCore.Runtime.Layout => "layout",
    MishkaCmsCore.Runtime.Component => "component",
    MishkaCmsCore.Runtime.ErrorPage => "error_page",
    MishkaCmsCore.Runtime.JsHook => "js_hook",
    MishkaCmsCore.Runtime.Stylesheet => "stylesheet"
  }

  # Whether `actor` writes records of `resource` from the dashboard, their code included.
  defp writable?(resource, actor),
    do: RuntimeHelpers.writes?(%{current_user: actor}, Map.get(@types, resource))

  # The words for a write this reader may not make on `resource`, naming who may.
  defp refusal(resource) do
    case RuntimeHelpers.writers(Map.get(@types, resource)) do
      [] ->
        gettext("You do not have permission to change this.")

      names ->
        gettext("You do not have permission to change this. It needs %{names}.",
          names: Enum.join(names, gettext(" or "))
        )
    end
  end

  # True when the resource defines a version-restore action (so the Versions tab shows Restore). Some
  # resources keep versions view-only.
  defp restorable?(resource),
    do: Ash.Resource.Info.action(resource, :master_restore_version) != nil

  # The field a draftless resource's Code tab shows and saves.
  @source_fields %{
    MishkaCmsCore.Runtime.JsHook => :content,
    MishkaCmsCore.Runtime.Stylesheet => :content,
    MishkaCmsCore.Runtime.Component => :template
  }

  # Per-resource draft config — which resources are draftable, and how. Page and Layout each have a
  # draft resource with the same action shape; everything below (list/save/publish/preview-url/
  # pubsub) is driven by this map so the modal is resource-generic.
  @draft_specs %{
    MishkaCmsCore.Runtime.Page => %{
      draft: MishkaCmsCore.Runtime.PageDraft,
      slug: "page",
      source_field: :source_page_id,
      list_actions: {:drafts_for_page, :master_drafts_for_page},
      content_field: :template,
      fields: [
        :name,
        :title,
        :path,
        :section,
        :description,
        :format,
        :priority,
        :extra,
        :content,
        :seo_tags,
        :schema,
        :events,
        :infos,
        :state,
        :resource_links,
        :helpers,
        :active,
        :precompile,
        :permissions,
        :layout_id,
        :language,
        :language_group_id
      ]
    },
    MishkaCmsCore.Runtime.Layout => %{
      draft: MishkaCmsCore.Runtime.LayoutDraft,
      slug: "layout",
      source_field: :source_layout_id,
      list_actions: {:drafts_for_layout, :master_drafts_for_layout},
      content_field: :template,
      fields: [
        :name,
        :path,
        :description,
        :format,
        :priority,
        :extra,
        :content,
        :resource_links,
        :seo_tags,
        :helpers,
        :active,
        :precompile,
        :permissions,
        :example
      ]
    },
    MishkaCmsCore.Runtime.ErrorPage => %{
      draft: MishkaCmsCore.Runtime.ErrorPageDraft,
      slug: "error_page",
      source_field: :source_error_page_id,
      list_actions: {:drafts_for_error_page, :master_drafts_for_error_page},
      # ErrorPage's editable content is the `error_pages` COLLECTION, not a single :template; the
      # editor round-trips it as serialized text (see `content_attr/2` + `RuntimePreview`).
      content_field: :error_pages,
      fields: [
        :name,
        :path,
        :root_layout_template,
        :format,
        :priority,
        :helpers,
        :active,
        :precompile,
        :extra
      ]
    }
  }

  # Resource segment for the `/_preview/<slug>/:token` URL — for drafts AND live originals, since the
  # same route serves both (each carries a `preview_token`).
  @draft_slugs %{
    MishkaCmsCore.Runtime.PageDraft => "page",
    MishkaCmsCore.Runtime.LayoutDraft => "layout",
    MishkaCmsCore.Runtime.ErrorPageDraft => "error_page",
    MishkaCmsCore.Runtime.Page => "page",
    MishkaCmsCore.Runtime.Layout => "layout",
    MishkaCmsCore.Runtime.ErrorPage => "error_page"
  }

  @empty %{
    resource: nil,
    record: nil,
    loading?: false,
    rendering?: false,
    active_tab: "overview",
    device: "desktop",
    html: nil,
    error: nil,
    status: nil,
    details: [],
    file_size: nil,
    versions: [],
    versions_total: 0,
    versions_page: 1,
    versions_per_page: @versions_per_page,
    version_masters: MapSet.new(),
    expanded_version_id: nil,
    modified_by: nil,
    visual_editor_url: nil,
    drafts_enabled?: false,
    direct_save?: false,
    code_visible?: true,
    editing?: false,
    edit_source: nil,
    edit_label: nil,
    render_nonce: 0,
    draft: nil,
    drafts: [],
    drafts_total: 0,
    drafts_page: 1,
    drafts_per_page: @drafts_per_page,
    live_url: nil,
    edit_html: nil,
    preview_source: "original",
    preview_error_status: nil,
    current_user: nil,
    form_record_id: nil,
    has_config?: false,
    config_mounted?: false,
    versions_loading?: false,
    compiling?: false,
    force_compilable?: false,
    restorable?: false,
    duplicable?: false,
    duplicating?: false,
    writable?: false,
    metrics: nil
  }

  @doc "The shared modal DOM id (used by the gervaz show/hide JS)."
  def modal_id, do: @modal_id

  @doc """
  `:preview` assign as a closed modal holds it — every key the modal reads, at its resting value.

  Public so a test can build a state by merging onto it rather than copying the shape. A copy goes
  stale the moment a key is added here, and the failure is a `KeyError` from the template rather
  than anything about the behaviour under test.
  """
  @spec empty() :: map()
  def empty, do: @empty

  @doc """
  Init the `:preview` assign and attach the realtime status hook. Call AFTER
  `RuntimeStatusLive.setup/2` and BEFORE `ActivityFeed.setup/2` (the feed hook halts the
  oban/compile broadcasts, so this must see them first) — same ordering rule the expand row
  follows. The hook recomputes the open preview's `status` (the Pipeline tab) on the same
  signals that drive the expand row: oban job events and the lazy `__runtime_compiled__`
  broadcast, so a page that compiles on a first visitor request flips to "Live" in the modal
  too.
  """
  def setup(socket) do
    socket
    |> assign(:preview, @empty)
    |> attach_hook(:preview_status, :handle_info, &status_hook/2)
  end

  defp status_hook(
         %Phoenix.Socket.Broadcast{event: "oban_activity", payload: %{__oban__: true, job: job}},
         socket
       ) do
    match? = &record_matches?(&1, job_record_id(job))
    socket = refresh_status(socket, match?)

    {:cont, if(match?.(socket.assigns.preview), do: load_metrics(socket), else: socket)}
  end

  defp status_hook(
         %Phoenix.Socket.Broadcast{payload: %{__runtime_compiled__: true, module: module}},
         socket
       ) do
    match? = &(&1.status != nil and &1.status.module == module)
    socket = refresh_status(socket, match?)

    {:cont, if(match?.(socket.assigns.preview), do: load_metrics(socket), else: socket)}
  end

  # The modal's own clock, so a page never sees it.
  defp status_hook({:preview_metrics_tick, record_id}, socket) do
    case record_matches?(socket.assigns.preview, record_id) do
      true -> {:halt, load_metrics(socket)}
      false -> {:halt, socket}
    end
  end

  defp status_hook(_message, socket), do: {:cont, socket}

  defp refresh_status(socket, match?) do
    preview = socket.assigns.preview

    if preview.record != nil and match?.(preview) do
      assign(socket, :preview, %{
        preview
        | status: RuntimeStatus.compute(preview.record, preview.resource)
      })
    else
      socket
    end
  end

  defp record_matches?(%{record: %{id: id}}, record_id) when not is_nil(record_id),
    do: to_string(id) == to_string(record_id)

  defp record_matches?(_preview, _record_id), do: false

  defp job_record_id(%{args: %{"data" => %{"id" => id}}}), do: id
  defp job_record_id(_job), do: nil

  @doc "Open the modal for `id` (Overview tab) and load the record off the LiveView process."
  def open(socket, id), do: open(socket, id, "overview")

  @doc "Open the modal for `id` straight on the Configuration (form) tab — the edit pencil / Edit button."
  def open_configuration(socket, id), do: open(socket, id, "configuration")

  defp open(socket, id, tab) do
    config = socket.assigns.runtime_status_opts
    actor = socket.assigns.current_user

    socket
    |> assign(:preview, %{
      @empty
      | resource: config.resource,
        loading?: true,
        active_tab: tab,
        current_user: actor,
        form_record_id: id,
        has_config?: configurable?(config.resource, actor),
        config_mounted?: tab == "configuration"
    })
    |> exec_modal_js(&MishkaCmsCore.CoreComponents.show_modal/1)
    |> MishkaGervaz.Messages.start_async(:load_preview, fn -> load(id, actor, config) end)
  end

  @doc """
  Open the modal on an empty Configuration form to ADD a record (the page's + button) — for a writer
  of the resource; anyone else is told what it needs.
  """
  def open_new(socket) do
    config = socket.assigns.runtime_status_opts

    case writable?(config.resource, socket.assigns.current_user) do
      true -> open_blank(socket, config)
      false -> put_flash(socket, :error, refusal(config.resource))
    end
  end

  defp open_blank(socket, config) do
    socket
    |> assign(:preview, %{
      @empty
      | resource: config.resource,
        active_tab: "configuration",
        current_user: socket.assigns.current_user,
        form_record_id: nil,
        has_config?: configurable?(config.resource, socket.assigns.current_user),
        config_mounted?: true
    })
    |> exec_modal_js(&MishkaCmsCore.CoreComponents.show_modal/1)
  end

  @doc """
  Route one of the modal's async operations to its own handler.

  Each page carries a single `handle_async/3` clause guarded on the names it can start and delegates
  here. They are SEPARATE names on purpose: `start_async/3` cancels an in-flight task of the same
  name, so sharing one would mean a click on the Versions pager killing the record load that opened
  the modal, or a tab switch killing a compile or a duplicate that is still running.
  """
  def async_result(socket, :load_preview, result), do: loaded(socket, result)
  def async_result(socket, :preview_versions, result), do: versions_loaded(socket, result)
  def async_result(socket, :preview_compile, result), do: compiled(socket, result)
  def async_result(socket, :preview_duplicate, result), do: duplicated(socket, result)
  def async_result(socket, :preview_metrics, result), do: metrics_loaded(socket, result)

  @doc "Place the loaded preview (or fail closed) into the `:preview` assign."
  # Preserve the tab the user opened on (e.g. edit opens straight on "configuration") — `build/3`
  # returns an `@empty`-based map that would otherwise reset `active_tab` to "overview".
  # The document arriving on its own, after the tab has already switched — see `set_tab/2`. Matched
  # BEFORE the whole-preview clause below, which would otherwise swallow it.
  def loaded(socket, {:ok, {:document, html, error}}),
    do: put_preview(socket, &%{&1 | html: html, error: error, rendering?: false})

  # WHAT THE READER ALREADY CHOSE OUTLIVES THE LOAD. `build/3` returns an `@empty`-based map, so
  # every key the click set before the read finished has to be carried across explicitly: the tab
  # they opened on, and whether the Configuration form has been mounted. Losing the second one meant
  # the edit pencil opened the right tab onto nothing at all — the form was mounted for the length of
  # one render and then dropped when the record arrived.
  def loaded(socket, {:ok, preview}) do
    open = socket.assigns.preview

    socket
    |> assign(:preview, %{
      preview
      | active_tab: open.active_tab,
        config_mounted?: open.config_mounted?
    })
    |> load_metrics()
  end

  def loaded(socket, {:exit, _reason}) do
    socket
    |> exec_modal_js(&MishkaCmsCore.CoreComponents.hide_modal/1)
    |> assign(:preview, @empty)
    |> put_flash(:error, gettext("Failed to load preview"))
  end

  # A RECORD'S RUNTIME NUMBERS — its render times, its last build and whether its module is in memory
  # now — read off the LiveView process, so the card shows "Loading…" rather than the modal waiting,
  # and read again every few seconds while the modal stays on it. One timer at a time: a new read
  # replaces the one pending, so opening the same record twice does not start a second loop. The
  # answer carries the record's id, so one that lands after the modal moved on is dropped.
  #
  # A GLOBAL RECORD'S COUNTS ARE EVERY SITE'S: renders on all of them land on its one module. A site
  # admin may open it, so its counts are shown to a master admin alone.
  defp load_metrics(
         %{
           assigns: %{
             preview:
               %{resource: resource, record: %{id: id} = record, status: %{module: module}} =
                 preview
           }
         } = socket
       )
       when resource in @timed and not is_nil(module) do
    counts? = record.site_id != nil or master?(preview.current_user)

    socket
    |> assign(:preview, %{preview | metrics: preview.metrics || :loading})
    |> MishkaGervaz.Messages.start_async(:preview_metrics, fn ->
      {id, metrics(resource, record, module, counts?)}
    end)
  end

  # A BUNDLED RECORD'S NUMBERS are its bundle's, as `AssetsState` holds it, with the build state and
  # the last rebuild's job the modal already read. Nothing renders them, so nothing is timed and
  # nothing ticks: a rebuild's job announces itself (`status_hook/2`).
  defp load_metrics(
         %{assigns: %{preview: %{resource: resource, record: %{id: id} = record} = preview}} =
           socket
       )
       when resource in @bundled do
    source = %{record: record, status: preview.status, viewer: preview.current_user}

    socket
    |> assign(:preview, %{preview | metrics: preview.metrics || :loading})
    |> MishkaGervaz.Messages.start_async(:preview_metrics, fn ->
      {id, bundle_metrics(resource, source)}
    end)
  end

  defp load_metrics(socket), do: socket

  # A SITE'S OWN STYLESHEET IS IN THAT SITE'S CSS; a global one is in the shared base every site's CSS
  # starts with — so a site admin sees their own site's CSS, which is what their visitors download,
  # and a master the shared base.
  defp bundle_metrics(MishkaCmsCore.Runtime.Stylesheet, %{record: record} = source),
    do: bundle(source, css_bundle(record, source), "css")

  # A SITE'S OWN HOOK IS IN ITS SITE'S JS. A global one is built into every site's JS — not into a
  # shared base, which exists only for a site with no hooks of its own — so a site admin sees their
  # own site's bundle, and a master in how many site bundles it is. How many templates attach it is
  # counted where the viewer may look (`PageBuilder.Hooks.named_in/3`).
  defp bundle_metrics(MishkaCmsCore.Runtime.JsHook, %{record: record} = source) do
    hook = Ash.load!(record, [:is_global], authorize?: false)
    {site_name, scope} = hook_scope(hook, source)

    source
    |> bundle(js_bundle(hook, site_name), "js")
    |> then(&Map.put(&1, :build, built(&1)))
    |> Map.merge(%{
      lazy?: hook.lazy == true,
      left_out?: left_out?(source.status, site_name),
      named_in: MishkaCmsCore.Runtime.PageBuilder.Hooks.named_in(hook, site_name, scope)
    })
  end

  defp hook_scope(%{site_id: site_id}, %{status: %{site_name: name}}) when is_binary(site_id),
    do: {name, site_id}

  defp hook_scope(_global, %{viewer: %{site_id: site_id}}) when is_binary(site_id),
    do: {site_name(site_id), {:with_globals, site_id}}

  defp hook_scope(_global, _master), do: {nil, :all}

  defp js_bundle(_hook, site_name) when is_binary(site_name), do: site_name
  defp js_bundle(_global, nil), do: :every_site

  # The card's Last Built row, which a JS hook's card shows under its boxes.
  defp built(%{updated_at: %DateTime{} = at}), do: %{at: at}
  defp built(_never), do: nil

  # LEFT OUT OF THE BUNDLE SHOWN. `JavaScriptCompiler.left_out/1` is per bundle, so a global hook
  # left out of another site's JS is not left out of a site admin's own; a master sees them all.
  defp left_out?(%{left_out: left_out}, site_name) when is_list(left_out),
    do: Enum.any?(left_out, fn {bundle, _reason} -> is_nil(site_name) or bundle == site_name end)

  defp left_out?(_status, _site_name), do: false

  defp bundle(source, :every_site, type) do
    sites = Enum.count(SiteState.get_active_sites(), &AssetsState.exists?(&1.name, type))
    %{bundle(source, nil, type) | bundle: :every_site, site_bundles: sites}
  end

  defp bundle(%{status: status}, bundle, type) do
    %{
      kind: :asset,
      type: type,
      bundle: bundle,
      sizes: sizes(bundle, type),
      hash: AssetsState.hash(bundle, type),
      updated_at: AssetsState.updated_at(bundle, type),
      state: status && status.state,
      took_ms: took_ms(status),
      site_bundles: nil
    }
  end

  defp css_bundle(%{site_id: site_id}, %{status: %{site_name: name}}) when is_binary(site_id),
    do: RuntimeStatus.asset_bundle_id(name)

  defp css_bundle(_global, %{viewer: %{site_id: site_id}}) when is_binary(site_id),
    do: site_name(site_id) || RuntimeStatus.asset_bundle_id("Global")

  defp css_bundle(_global, _master), do: RuntimeStatus.asset_bundle_id("Global")

  defp site_name(site_id) do
    case SiteState.get(site_id) do
      {:ok, %{name: name}} -> name
      _unknown -> nil
    end
  end

  defp sizes(nil, _type), do: nil

  defp sizes(bundle, type) do
    case size_of(bundle, type) do
      nil ->
        nil

      raw ->
        %{
          raw: raw,
          brotli: size_of(bundle, "brotli_" <> type),
          gzip: size_of(bundle, "gzip_" <> type)
        }
    end
  end

  defp size_of(bundle, type) do
    case AssetsState.get_value(bundle, type) do
      nil -> nil
      value -> byte_size(value)
    end
  end

  # How long the last rebuild of this record took, from its own compile job.
  defp took_ms(%{job: %{attempted_at: %DateTime{} = from, completed_at: %DateTime{} = to}}),
    do: DateTime.diff(to, from, :millisecond)

  defp took_ms(_no_finished_job), do: nil

  # AN ERROR PAGE IS COUNTED PER STATUS (`RenderMetrics` keeps `{module, status}`), read here for the
  # statuses the record holds, as the compiler names them — once each, as the compiler draws each
  # once; its Render Time is their average, weighted by how often each was shown.
  defp metrics(MishkaCmsCore.Runtime.ErrorPage, record, module, counts?) do
    module
    |> module_state()
    |> Map.put(:stats, counted(counts?, fn -> record |> statuses(module) |> shown() end))
  end

  defp metrics(_resource, _record, module, counts?) do
    module
    |> module_state()
    |> Map.put(:stats, counted(counts?, fn -> RenderMetrics.stats(module) end))
  end

  defp module_state(module),
    do: %{
      on?: RenderMetrics.on?(),
      loaded?: CompilerHelpers.loaded?(module),
      build: RenderMetrics.build(module)
    }

  defp counted(true, read), do: read.()
  defp counted(false, _read), do: :hidden

  defp statuses(record, module) do
    for status <- record |> RuntimePreview.error_statuses() |> Enum.uniq(),
        %{full: %{count: n} = full} <- [RenderMetrics.stats({module, status})],
        n > 0,
        do: {status, full}
  end

  defp shown(statuses) do
    count = statuses |> Enum.map(fn {_status, full} -> full.count end) |> Enum.sum()
    time = statuses |> Enum.map(fn {_status, full} -> full.avg_us * full.count end) |> Enum.sum()
    avg = if count > 0, do: div(time, count), else: 0

    %{full: %{count: count, avg_us: avg}, update: %{count: 0, avg_us: 0}, statuses: statuses}
  end

  defp metrics_loaded(socket, {:ok, {id, metrics}}) do
    case socket.assigns.preview do
      %{record: %{id: ^id}, resource: resource} = preview ->
        socket
        |> refresh_later(resource, id)
        |> assign(:preview, %{preview | metrics: metrics})

      _closed_or_another ->
        socket
    end
  end

  defp metrics_loaded(socket, {:exit, _reason}), do: socket

  defp refresh_later(socket, resource, id) when resource in @timed do
    if timer = socket.assigns[:preview_metrics_timer], do: Process.cancel_timer(timer)

    assign(
      socket,
      :preview_metrics_timer,
      Process.send_after(self(), {:preview_metrics_tick, id}, @metrics_every)
    )
  end

  defp refresh_later(socket, _bundled, _id), do: socket

  def set_tab(socket, tab) do
    # EVERYTHING THAT COMPILES HAPPENS HERE, on the Preview tab, and nowhere else — mirroring a
    # page, whose module compiles when its live preview iframe loads rather than when the modal
    # opens. Overview, Code, Versions and Pipeline all read the record and never run it, so a record
    # stays "Lazy" until somebody asks to see it rendered. That is what makes the Pipeline tab
    # honest: it reports what the runtime has actually been asked to do.
    preview = socket.assigns.preview
    if tab == "preview", do: maybe_warm_module(preview.record, preview.resource)

    socket
    |> update_preview(:active_tab, tab)
    |> maybe_mount_config(tab)
    |> maybe_render_document(tab)
  end

  # THE FORM IS NOT MOUNTED UNTIL SOMEBODY ASKS FOR IT. `MishkaGervaz.Form.Web.Live` reads the record
  # and every relation's options the moment it mounts, so mounting it inside the modal shell charged
  # a click on the eye — a look, not an edit — for a second read of the row plus a select's worth of
  # queries per relation. Once mounted it STAYS mounted (hidden on the other tabs), because that is
  # what keeps a half-typed field alive across a trip to the Code tab.
  #
  # Nothing here is async: the form's own `update/2` starts its record load in a `start_async` and
  # renders its loading template meanwhile, so the tab paints on the same round trip as the click.
  defp maybe_mount_config(socket, "configuration"),
    do: update_preview(socket, :config_mounted?, true)

  defp maybe_mount_config(socket, _tab), do: socket

  # THE TAB OPENS FIRST AND THE DOCUMENT ARRIVES AFTER. Building it renders the component for real —
  # which for one that has never been built means compiling it — and doing that inline froze the
  # modal on the tab the author had just left, with nothing to say why. The tab switch is assigned
  # above before this runs; here we only mark it rendering and let `loaded/2` fill it in.
  #
  # Built once. `rerender/2` replaces it for an unsaved edit.
  defp maybe_render_document(socket, "preview") do
    case socket.assigns.preview do
      %{html: nil, rendering?: false, record: record, resource: resource}
      when not is_nil(record) ->
        nonce = socket.assigns[:csp_nonce]

        socket
        |> update_preview(:rendering?, true)
        |> MishkaGervaz.Messages.start_async(:load_preview, fn ->
          {html, error} = RuntimePreview.render_document(record, resource, nonce)
          {:document, html, error}
        end)

      _rendered_already_or_in_flight_or_nothing_selected ->
        socket
    end
  end

  defp maybe_render_document(socket, _tab), do: socket

  def set_device(socket, device), do: update_preview(socket, :device, device)

  @doc ~S|Switch the Preview tab between the pending `"draft"` and the live `"original"`.|
  def set_preview_source(socket, source) when source in ["draft", "original"],
    do: update_preview(socket, :preview_source, source)

  def set_preview_source(socket, _source), do: socket

  @doc """
  Select which ErrorPage status code (404/500/…) the Preview tab renders. An ErrorPage holds many
  templates; its preview is a full LiveView (`/_preview/error_page/:token?status=…`), so this just
  records the chosen status and bumps the nonce — the modal rebuilds the iframe URL/id to that code.
  Clears any unsaved-edit doc so the selector always shows the live render.
  """
  def set_error_status(socket, status),
    do:
      put_preview(socket, fn p ->
        %{p | preview_error_status: status, edit_html: nil, render_nonce: p.render_nonce + 1}
      end)

  defp first_error_status(record, MishkaCmsCore.Runtime.ErrorPage),
    do: record |> RuntimePreview.error_statuses() |> List.first()

  defp first_error_status(_record, _resource), do: nil

  @doc """
  Enter Code-tab edit mode, seeding the editor from the pending draft if one exists — for a writer of
  the record; anyone else is told what it needs.
  """
  def edit_code(%{assigns: %{preview: %{writable?: false, resource: resource}}} = socket),
    do: put_flash(socket, :error, refusal(resource))

  def edit_code(socket) do
    put_preview(socket, fn p ->
      %{p | active_tab: "code", editing?: true, edit_source: editor_source(p), edit_label: nil}
    end)
  end

  @doc """
  Keep what is typed in the Code tab's editor (`source`, and the draft's `label` when the form has
  one), so the editor still holds it after a reconnect and a refused save leaves it as it was.
  """
  def type_code(socket, source, label) when is_binary(source) do
    put_preview(socket, fn p ->
      %{p | edit_source: source, edit_label: if(is_binary(label), do: label, else: p.edit_label)}
    end)
  end

  defp editor_source(%{draft: draft}) when not is_nil(draft), do: RuntimePreview.source(draft)
  defp editor_source(%{record: record}), do: RuntimePreview.source(record)

  @doc "Leave edit mode."
  def cancel_edit(socket), do: put_preview(socket, &%{&1 | editing?: false, edit_label: nil})

  @doc """
  Save the Code tab's edit straight to the record, for a resource with no drafts — a JS Hook, a
  Stylesheet, a Component — and reopen the modal on the Code tab with what was saved. It runs the
  update the Configuration form runs, as the master or as the site, so every rule that form meets
  is met here; a refusal keeps the editor open with the reason.
  """
  def save_source(
        %{assigns: %{preview: %{writable?: false, resource: resource}}} = socket,
        _source
      ),
      do: put_flash(socket, :error, refusal(resource))

  def save_source(socket, source) do
    %{record: record, resource: resource} = socket.assigns.preview
    attrs = %{Map.fetch!(@source_fields, resource) => source}

    case write_source(record, attrs, socket.assigns.current_user) do
      {:ok, saved} ->
        socket
        |> open(saved.id, "code")
        |> put_flash(:info, gettext("Saved."))

      {:error, error} ->
        socket
        |> put_preview(&%{&1 | edit_source: source})
        |> put_flash(:error, save_error(error))
    end
  end

  defp write_source(record, attrs, %{site_id: nil} = user) do
    record
    |> Ash.Changeset.for_update(:master_update, attrs, actor: user)
    |> Ash.update(actor: user)
  end

  defp write_source(record, attrs, %{site_id: site_id} = user) when is_binary(site_id) do
    record
    |> Ash.Changeset.for_update(:update, attrs, tenant: site_id, actor: user)
    |> Ash.update(actor: user)
  end

  defp write_source(_record, _attrs, _not_a_user), do: {:error, :forbidden}

  defp save_error(%Ash.Error.Invalid{} = error), do: invalid_message(error)
  defp save_error(_error), do: gettext("Could not save.")

  @doc """
  Re-render the (unsaved) edited template and jump to the Preview tab showing it as the Draft view
  with the Draft toggle active. Renders to a standalone doc (`edit_html`) — the live `Original`
  iframe is left untouched. Rendering runs the edit, so it is a writer's alone.
  """
  def rerender(%{assigns: %{preview: %{writable?: false, resource: resource}}} = socket, _source),
    do: put_flash(socket, :error, refusal(resource))

  def rerender(socket, source) do
    nonce = socket.assigns[:csp_nonce]

    put_preview(socket, fn p ->
      {html, error} =
        RuntimePreview.render_document(
          put_content(p.record, p.resource, source),
          p.resource,
          nonce
        )

      %{
        p
        | edit_source: source,
          edit_html: html,
          error: error,
          rendering?: false,
          render_nonce: p.render_nonce + 1,
          active_tab: "preview",
          preview_source: "draft"
      }
    end)
  end

  @doc """
  Select a draft from the picker. It's *context-aware*: on the Code tab it just swaps which draft's
  data the editor/source shows (stays on Code); on the Preview tab it renders THAT draft (switches
  to the Draft view). It never forces a tab change.
  """
  def select_draft(socket, id) do
    preview = socket.assigns.preview

    case Enum.find(preview.drafts, &(to_string(&1.id) == to_string(id))) do
      nil ->
        socket

      draft ->
        put_preview(socket, fn p ->
          base = %{
            p
            | draft: draft,
              edit_source: RuntimePreview.source(draft),
              edit_html: nil,
              render_nonce: p.render_nonce + 1
          }

          if p.active_tab == "preview", do: %{base | preview_source: "draft"}, else: base
        end)
    end
  end

  @doc """
  Start a brand-new draft: deselect + open the Code editor seeded from the page's template — for a
  writer of the record.
  """
  def new_draft(%{assigns: %{preview: %{writable?: false, resource: resource}}} = socket),
    do: put_flash(socket, :error, refusal(resource))

  def new_draft(socket) do
    put_preview(socket, fn p ->
      %{
        p
        | draft: nil,
          editing?: true,
          active_tab: "code",
          edit_html: nil,
          edit_label: nil,
          edit_source: RuntimePreview.source(p.record)
      }
    end)
  end

  @doc """
  Load a page of the drafts picker (selection is left unchanged). `page_num` is a number or the text
  the browser sent; text that is not a whole number leaves the picker as it is.
  """
  def drafts_paginate(socket, page_num) when is_binary(page_num) do
    case Integer.parse(page_num) do
      {number, ""} -> drafts_paginate(socket, number)
      _not_a_number -> socket
    end
  end

  def drafts_paginate(socket, page_num) when is_integer(page_num) do
    preview = socket.assigns.preview

    {drafts, total} =
      list_drafts(preview.record, preview.resource, socket.assigns.current_user, page_num)

    put_preview(socket, fn p ->
      %{p | drafts: drafts, drafts_total: total, drafts_page: max(page_num, 1)}
    end)
  end

  @doc """
  Reload the picker after a save/publish/discard. `page_num` is the page to show, `select_id` the
  draft to (re)select (`nil` → the latest in view). Leaves edit mode.
  """
  def reload_drafts(socket, page_num, select_id) do
    preview = socket.assigns.preview

    {drafts, total} =
      list_drafts(preview.record, preview.resource, socket.assigns.current_user, page_num)

    draft = pick_draft(select_id, drafts)

    put_preview(socket, fn p ->
      %{
        p
        | drafts: drafts,
          drafts_total: total,
          drafts_page: max(page_num, 1),
          draft: draft,
          editing?: false,
          edit_html: nil,
          edit_label: nil,
          edit_source: RuntimePreview.source(draft || p.record)
      }
    end)
  end

  @doc """
  Realtime sync of the open modal's picker from a draft notification (a publish/discard/edit that
  happened in another tab/session). Reloads the current page of drafts and keeps the selected one if
  it's still pending — which it isn't once published/discarded, so the selection (and the Code
  editor) fall back to the latest remaining, or clear when none are left. Works for Page and Layout
  drafts (the source id is read via the open resource's draft spec).
  """
  def sync_draft(socket, data, actor) do
    preview = socket.assigns.preview
    source_id = data |> draft_source_id(preview.resource) |> presence()

    if preview.record != nil and source_id != nil and
         to_string(preview.record.id) == to_string(source_id) do
      {drafts, total} = list_drafts(preview.record, preview.resource, actor, preview.drafts_page)
      draft = pick_draft(preview.draft && preview.draft.id, drafts)

      put_preview(socket, fn p ->
        %{
          p
          | drafts: drafts,
            drafts_total: total,
            draft: draft,
            editing?: p.editing? and draft != nil,
            edit_source: editor_source(%{p | draft: draft})
        }
      end)
    else
      socket
    end
  end

  defp draft_source_id(data, resource) do
    case draft_spec(resource) do
      %{source_field: field} -> Map.get(data, field)
      _ -> nil
    end
  end

  defp presence(nil), do: nil
  defp presence(value), do: value

  defp pick_draft(nil, drafts), do: List.first(drafts)

  defp pick_draft(id, drafts),
    do: Enum.find(drafts, List.first(drafts), &(to_string(&1.id) == to_string(id)))

  @doc """
  Create or update a draft from the Code editor (+ label), then reload the picker — for a writer of
  the record.
  """
  def save_draft(
        %{assigns: %{preview: %{writable?: false, resource: resource}}} = socket,
        _source,
        _label
      ),
      do: put_flash(socket, :error, refusal(resource))

  def save_draft(socket, source, label) do
    preview = socket.assigns.preview
    user = socket.assigns.current_user
    existing = preview.draft
    attrs = draft_attrs(preview.record, source, label, preview.resource)

    case write_draft(existing, attrs, preview.record, user, preview.resource) do
      {:ok, draft} ->
        DraftPreviewAssets.purge(draft)
        page_num = if existing, do: preview.drafts_page, else: 1

        socket
        |> reload_drafts(page_num, draft.id)
        |> put_flash(:info, gettext("Saved as draft — preview or publish it from the bar above."))

      {:error, _error} ->
        put_flash(socket, :error, gettext("Could not save the draft."))
    end
  end

  @doc "Publish the selected draft to its live record; keep the modal open and refresh the picker."
  def publish_draft(%{assigns: %{preview: %{writable?: false, resource: resource}}} = socket),
    do: put_flash(socket, :error, refusal(resource))

  def publish_draft(socket) do
    preview = socket.assigns.preview

    case do_publish(preview.draft, socket.assigns.current_user) do
      {:ok, _record} ->
        socket
        |> reload_drafts(1, nil)
        |> put_flash(:info, published_message(preview.resource))

      {:error, error} ->
        put_flash(socket, :error, publish_error(error))
    end
  end

  @doc """
  Discard a draft and refresh the picker. `id` names WHICH — `nil` means the selected one.

  A real delete — these resources do not archive, so the row does not survive and the discard is
  reportable only on the live activity feed, never from history.

  Two buttons reach this. The bar's Discard is always about the draft in focus and passes no id; a
  badge's ✖ names its own draft, which may be any one on the page. That difference is the whole
  reason the id is a parameter: `preview.draft` would have deleted the wrong row for every badge
  except the selected one.
  """
  def discard_draft(socket, id \\ nil)

  def discard_draft(
        %{assigns: %{preview: %{writable?: false, resource: resource}}} = socket,
        _id
      ),
      do: put_flash(socket, :error, refusal(resource))

  def discard_draft(socket, id) do
    case chosen_draft(socket.assigns.preview, id) do
      nil ->
        put_flash(socket, :error, gettext("That draft is no longer there."))

      draft ->
        case do_discard(draft, socket.assigns.current_user) do
          {:error, _refused} -> put_flash(socket, :error, gettext("Could not discard the draft."))
          _gone -> discarded(socket, draft)
        end
    end
  end

  defp chosen_draft(%{draft: draft}, nil), do: draft

  defp chosen_draft(%{drafts: drafts}, id),
    do: Enum.find(drafts, &(to_string(&1.id) == to_string(id)))

  # DELETING THE ONE YOU ARE READING IS A CHANGE OF SUBJECT; deleting any other one is not. So the
  # first goes back to the top and takes whatever is newest, and the second stays exactly where the
  # reader was, still on the draft they had chosen — except when it emptied the page they were on,
  # which is the one case where staying would show a picker with nothing in it.
  defp discarded(socket, deleted) do
    p = socket.assigns.preview
    chosen = p.draft && p.draft.id

    {page, select} =
      case chosen == deleted.id do
        true -> {1, nil}
        false -> {surviving_page(p), chosen}
      end

    socket |> reload_drafts(page, select) |> put_flash(:info, gettext("Draft discarded."))
  end

  defp surviving_page(%{drafts: [_last_one], drafts_page: page}), do: max(page - 1, 1)
  defp surviving_page(%{drafts_page: page}), do: page

  @doc """
  Subscribe the LiveView process to a resource's draft pubsub topics (so the open modal's picker
  stays realtime). Master gets the bare topics; a tenant also its own site's. No-op for
  non-draftable resources.
  """
  def subscribe_drafts(actor, resource) do
    case draft_spec(resource) do
      nil ->
        :ok

      spec ->
        prefix = spec.slug <> "_draft"
        Enum.each(draft_topics(prefix) ++ site_draft_topics(prefix, actor), &subscribe_topic/1)
    end
  end

  defp draft_module(resource), do: draft_spec(resource).draft

  defp draft_attrs(record, source, label, resource) do
    spec = draft_spec(resource)

    record
    |> Map.take(spec.fields)
    |> Map.merge(%{:label => normalize_label(label), spec.source_field => record.id})
    |> Map.merge(content_attr(spec, source))
  end

  # The editor works on a STRING. For Page/Layout that string IS the `:template`; for ErrorPage it's
  # the serialized `error_pages` collection, parsed back on save.
  defp content_attr(%{content_field: :error_pages}, source),
    do: %{error_pages: RuntimePreview.parse_error_pages(source)}

  defp content_attr(%{content_field: field}, source), do: %{field => source}

  # Put the editor string back into the record's content field for an unsaved re-render preview.
  defp put_content(record, resource, source) do
    case draft_spec(resource) do
      %{content_field: :error_pages} ->
        Map.put(record, :error_pages, RuntimePreview.parse_error_pages(source))

      %{content_field: field} ->
        Map.put(record, field, source)

      _ ->
        Map.put(record, :template, source)
    end
  end

  defp normalize_label(label) when is_binary(label) do
    case String.trim(label) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_label(_label), do: nil

  # THE ACTOR GOES ON THE CHANGESET, NOT ONLY ON THE CALL, for the reason
  # `PageBuilder.Helpers.create_section/4` gives: validations run when the changeset is BUILT, so
  # `Ash.create(actor: …)` alone reaches them too late. `TenantContext`'s master branch is the one
  # that asks who is writing, and it saw a nil actor on every draft write the preview bar makes.
  defp write_draft(nil, attrs, record, %{site_id: nil} = user, resource) do
    draft_module(resource)
    |> Ash.Changeset.for_create(
      :master_create,
      Map.put(attrs, :site_id, Map.get(record, :site_id)),
      actor: user
    )
    |> Ash.create(actor: user)
  end

  defp write_draft(nil, attrs, _record, %{site_id: site_id} = user, resource)
       when is_binary(site_id) do
    draft_module(resource)
    |> Ash.Changeset.for_create(:create, attrs, tenant: site_id, actor: user)
    |> Ash.create(actor: user)
  end

  defp write_draft(draft, attrs, _record, %{site_id: nil} = user, _resource) do
    draft
    |> Ash.Changeset.for_update(:master_update, attrs, actor: user)
    |> Ash.update(actor: user)
  end

  defp write_draft(draft, attrs, _record, %{site_id: site_id} = user, _resource)
       when is_binary(site_id) do
    draft
    |> Ash.Changeset.for_update(:update, attrs, tenant: site_id, actor: user)
    |> Ash.update(actor: user)
  end

  defp do_publish(draft, user) do
    with {:ok, {action, opts}} <- draft_scope(user, {:publish, :master_publish}) do
      result = draft |> Ash.Changeset.for_update(action, %{}, opts) |> Ash.update(actor: user)
      if match?({:ok, _}, result), do: DraftPreviewAssets.purge(draft)
      result
    end
  end

  defp do_discard(draft, user) do
    with {:ok, {action, opts}} <- draft_scope(user, {:destroy, :master_destroy}) do
      result = draft |> Ash.Changeset.for_destroy(action, %{}, opts) |> Ash.destroy(actor: user)
      if match?({:ok, _}, result) or result == :ok, do: DraftPreviewAssets.purge(draft)
      result
    end
  end

  # The actor rides in the opts the callers build their changesets from, so picking the action and
  # saying who picked it is one decision and cannot be half-made. The master action is a master's
  # (`site_id` nil) alone; a viewer who is not a user gets neither.
  defp draft_scope(%{site_id: site_id} = user, {tenant_action, _master}) when is_binary(site_id),
    do: {:ok, {tenant_action, [tenant: site_id, actor: user]}}

  defp draft_scope(%{site_id: nil} = user, {_tenant, master_action}),
    do: {:ok, {master_action, [actor: user]}}

  defp draft_scope(_not_a_user, _actions), do: {:error, :forbidden}

  defp publish_error(%Ash.Error.Invalid{} = error), do: invalid_message(error)
  defp publish_error(_error), do: gettext("Could not publish the draft.")

  defp invalid_message(%Ash.Error.Invalid{errors: errors}),
    do: Enum.map_join(errors, ", ", &error_message/1)

  defp error_message(error) do
    MishkaGervaz.Errors.translate_error(
      Map.get(error, :message) || dgettext_noop("errors", "Invalid"),
      Map.get(error, :vars)
    )
  end

  defp noun(resource), do: (draft_spec(resource) || %{slug: "record"}).slug

  defp published_message(resource) do
    case noun(resource) do
      "page" -> gettext("Published to the live page.")
      "layout" -> gettext("Published to the live layout.")
      "error_page" -> gettext("Published to the live error_page.")
      _record -> gettext("Published to the live record.")
    end
  end

  defp draft_topics(prefix), do: Enum.map(["created", "updated", "destroyed"], &"#{prefix}:#{&1}")

  defp site_draft_topics(prefix, %{site_id: site_id}) when is_binary(site_id),
    do: Enum.map(["created", "updated", "destroyed"], &"#{prefix}:#{site_id}:#{&1}")

  defp site_draft_topics(_prefix, _actor), do: []

  defp subscribe_topic(topic), do: apply(@host_endpoint, :subscribe, [topic])

  @doc "Clear preview state (the modal close button also hides it client-side)."
  def close(socket), do: assign(socket, :preview, @empty)

  @doc "Server-initiated close (e.g. after a successful Configuration-form save): hide AND reset."
  def dismiss(socket) do
    socket
    |> exec_modal_js(&MishkaCmsCore.CoreComponents.hide_modal/1)
    |> assign(:preview, @empty)
  end

  defp update_preview(socket, key, value),
    do: assign(socket, :preview, Map.put(socket.assigns.preview, key, value))

  defp put_preview(socket, fun),
    do: assign(socket, :preview, fun.(socket.assigns.preview))

  defp exec_modal_js(socket, build_js) do
    js = build_js.(@modal_id)
    push_event(socket, "gervaz:exec-js", %{target: @modal_id, js: Jason.encode!(js.ops)})
  end

  # OPENING THE MODAL RENDERS NOTHING. Building the preview document runs the record for real — a
  # Component's document is its examples, which are real `<.component …/>` invocations — and a
  # component is built by the first thing that renders it. So doing this on open meant clicking the
  # eye compiled it, and the Pipeline tab then reported "Live" about a component nothing had ever
  # rendered. The document is built when the Preview tab is opened instead; see `set_tab/2`.
  defp load(id, actor, config) do
    id
    |> fetch_record(actor, config)
    |> build(config.resource, actor)
  end

  defp fetch_record(id, %{site_id: nil} = actor, config),
    do:
      Ash.get!(config.resource, id,
        action: config.master_action,
        actor: actor,
        load: config.master_load
      )

  defp fetch_record(id, %{site_id: site_id} = actor, config) when is_binary(site_id) do
    opts =
      [actor: actor, tenant: site_id, load: config.tenant_load]
      |> maybe_action(config.tenant_action)

    Ash.get!(config.resource, id, opts)
  end

  defp maybe_action(opts, nil), do: opts
  defp maybe_action(opts, action), do: Keyword.put(opts, :action, action)

  defp build(record, resource, actor) do
    {drafts, drafts_total} = list_drafts(record, resource, actor, 1)
    draft = List.first(drafts)
    {versions, total, masters} = load_versions_page(record, resource, actor, 1)

    %{
      @empty
      | resource: resource,
        record: record,
        loading?: false,
        status: RuntimeStatus.compute(record, resource),
        details: RuntimePreview.details(record, resource),
        file_size: RuntimePreview.file_size(record),
        versions: versions,
        versions_total: total,
        versions_page: 1,
        version_masters: masters,
        modified_by: modified_by(versions, masters),
        visual_editor_url: visual_editor_url(record, resource, actor),
        drafts_enabled?: drafts_enabled?(resource, record, actor),
        direct_save?: direct_save?(resource, record, actor),
        code_visible?: code_visible?(resource, record, actor),
        preview_error_status: first_error_status(record, resource),
        draft: draft,
        drafts: drafts,
        drafts_total: drafts_total,
        edit_source: RuntimePreview.source(draft || record),
        live_url: live_url(record, resource),
        current_user: actor,
        form_record_id: record.id,
        has_config?: configurable?(resource, actor),
        force_compilable?: force_compilable?(record, resource) and writable?(resource, actor),
        restorable?: restorable?(resource) and writable?(resource, actor),
        duplicable?: duplicable?(record, resource, actor),
        writable?: writable?(resource, actor)
    }
  end

  @doc """
  Where the modal's "Open page" goes: an active page's own URL on its site's host, or `nil`.

  A stored path is a route, not always a URL. One that captures only `:lang` is filled with a
  language the page is served in, at the address the site's URL mode gives it
  (`MishkaCmsCore.Runtime.Languages.url/3`: `/:lang/blog` opens `/blog`, or `/en/blog` on a site
  that prefixes every language). One that captures a record — `/:lang/blog/:slug`,
  `/:lang/docs/:workspace/:section` — is the template of many URLs and the address of none, so it
  has no page to open: the button is hidden, and "Copy link" shares the preview instead of a path
  that answers 404.

      live_url(%Page{active: true, path: "/:lang/blog", language: "en", site: site}, Page)
      #=> "http://site-b.localhost:4000/blog"
  """
  @spec live_url(map(), module()) :: String.t() | nil
  def live_url(
        %{active: true, path: path, site: %{host: host} = site} = page,
        MishkaCmsCore.Runtime.Page
      )
      when is_binary(host) and is_binary(path) do
    captured = %{Languages.capture() => open_language(page, site)}

    case Languages.url(path, captured, Map.get(site, :id)) do
      nil -> nil
      address -> MishkaCmsCore.Helpers.site_url(host, address)
    end
  end

  def live_url(_record, _resource), do: nil

  # The page's own language when the site serves it there, else the first it is served in.
  defp open_language(page, site) do
    served = PageEditions.served_languages(page, Map.get(site, :id))
    if Map.get(page, :language) in served, do: page.language, else: List.first(served)
  end

  # EVERY MODULE-BACKED RECORD IS WARMED HERE, on the Preview tab and nowhere else. None of these
  # previews builds the module as a side effect — they render the record's template — so without
  # this the Pipeline tab would report "Lazy, compiles on first request" about something the reader
  # is looking at. The compile is async, off the async-load task, and emits the `:compiled`
  # telemetry the `:preview_status` hook already listens for, so the tab flips to "Live" on its own.
  #
  # This used to skip a Page, on the grounds that framing its live URL compiled it anyway. That
  # stopped being true when the frame moved to the same-origin preview route (see `frame_url/1`),
  # and skipping it left a Page reporting "Lazy" where a Layout beside it said "Live".
  # NO RECORD IS A REAL STATE, not a bug to crash on: opening a preview while the table is still
  # re-reading — a filter typed a keystroke earlier, a row deleted from under the click — resolves
  # to nothing, and the modal says "Nothing selected." This ran anyway and took the whole async
  # load process down with a `BadMapError`.
  defp maybe_warm_module(nil, _resource), do: :ok

  defp maybe_warm_module(record, resource) do
    cfg = RuntimeStatus.config(resource)

    if cfg.kind == :module and Map.get(record, :active, false) and
         is_binary(Map.get(record, :path)) do
      site = warm_site_name(record)
      module = CompilerHelpers.module_name(Map.get(record, cfg.key_field), site, cfg.type)

      if !CompilerHelpers.loaded?(module) do
        Task.start(fn ->
          ModuleCompilerHandler.compile_or_return_module(
            module,
            record.path,
            site,
            Map.get(record, :site_id)
          )
        end)
      end
    end

    :ok
  end

  defp warm_site_name(%{site: %{name: name}}) when is_binary(name), do: name
  defp warm_site_name(_record), do: "Global"

  # NO WARM-UP HERE ANY MORE. A component's preview document IS its examples — real
  # `<.component …/>` invocations — and rendering one builds whatever it names, transitively,
  # through `MishkaCmsCore.Runtime.LiveViewHelpers.component/1`. Walking `extra.examples[].requires`
  # and scraping `component_name="…"` out of the sources to compile them first was a second, partial
  # answer to a question the render already answers completely: it could only see what its regex
  # matched, and it ran on modal open, which is exactly where nothing should compile.

  @doc """
  Absolute shareable URL for a record's `/_preview/<resource>/:token`, on the domain of the admin
  who shares it: the master site's for a master, the admin's own site's for a site admin. With no
  admin given, the record's own site's, or the master site's for a record with no site. Resource
  segment (`page`/`layout`/`error_page`) is derived from the struct.

  The domain is read from the site records, never from a request. The preview route serves a record
  on its own site's domain and on the master site's
  (`MishkaCmsCore.Runtime.DraftPreviewAssets.served_on?/2`), so the link opens where it is sent.
  For the URL the modal FRAMES, see `frame_url/1`.
  """
  def preview_url(record, viewer \\ nil)

  def preview_url(%{preview_token: token} = record, viewer) when is_binary(token),
    do: build_preview_url(share_host(record, viewer), draft_slug(record), token)

  def preview_url(_record, _viewer), do: ""

  @doc """
  The same preview as a path with no host, so the browser loads it from the admin's own address.

  That address is the master site's for a master and a site admin's own site's for them:
  `MishkaCmsCore.Runtime.Plugs.SiteLookupPlug` signs neither in anywhere else. So the frame is
  always same-origin, as the admin's `frame-src 'self'` requires, and never names a host of its own.
  Building it from the endpoint's host named `localhost` in production, where a multi-site endpoint
  has no host configured, and the frame stayed empty.
  """
  def frame_url(%{preview_token: token} = record) when is_binary(token),
    do: "/_preview/#{draft_slug(record)}/#{token}"

  def frame_url(_record), do: nil

  defp share_host(_record, %{site_id: nil}), do: master_host()
  defp share_host(_record, %{site: %{host: host}}) when is_binary(host), do: host
  defp share_host(_record, %{site_id: site_id}) when is_binary(site_id), do: site_host(site_id)
  defp share_host(%{site: %{host: host}}, _no_viewer) when is_binary(host), do: host
  defp share_host(_record, _no_viewer), do: master_host()

  defp site_host(site_id) do
    case SiteState.get(site_id) do
      {:ok, %{host: host}} when is_binary(host) -> host
      _unknown -> master_host()
    end
  end

  defp master_host do
    case SiteState.get_by_master() do
      {:ok, %{host: host}} when is_binary(host) -> host
      _no_master_site -> endpoint_host()
    end
  end

  defp endpoint_host, do: apply(@host_endpoint, :struct_url, []).host

  defp build_preview_url(host, slug, token),
    do: MishkaCmsCore.Helpers.site_url(host, "/_preview/#{slug}/#{token}")

  defp draft_slug(%struct{}), do: Map.get(@draft_slugs, struct, "page")
  defp draft_slug(_draft), do: "page"

  defp draft_spec(resource), do: Map.get(@draft_specs, resource)
  defp draftable?(resource), do: Map.has_key?(@draft_specs, resource)

  defp master?(%{site_id: nil}), do: true
  defp master?(_actor), do: false

  # Who may EDIT (create drafts, change code, open the visual editor): the master always, and a
  # tenant on any row their own site owns. A row with NO site is the shared one — every site renders
  # it and every site places it, which is exactly why one site does not get to rewrite it. All four
  # global-capable resources say the same from inside their `:update` validation ("Global layouts can
  # only be modified by master users"); this is the button-level half of it.
  #
  # ASKED OF THE RECORD, NOT OF THE RESOURCE. It used to name `Layout` and only `Layout`, so a global
  # COMPONENT — the same shape, the same rule, the same validation — still offered its Code tab and
  # its Visual Editor to a tenant who could not save either.
  defp can_edit?(_resource, %{site_id: nil}, actor), do: master?(actor)
  defp can_edit?(_resource, _record, _actor), do: true

  defp drafts_enabled?(resource, record, actor),
    do: draftable?(resource) and can_edit?(resource, record, actor)

  # A RESOURCE WITH NO DRAFTS IS EDITED IN PLACE. Its Code tab only read, so changing a JS hook's
  # source meant leaving for Configuration; it gets the same Edit, saved straight to the record.
  defp direct_save?(resource, record, actor),
    do: Map.has_key?(@source_fields, resource) and can_edit?(resource, record, actor)

  # The Code tab is hidden entirely for a reader who cannot edit the row — a tenant looking at a
  # shared layout or component. Reading it would be harmless; offering an editor that refuses every
  # save is not.
  defp code_visible?(resource, record, actor), do: can_edit?(resource, record, actor)

  # THE CONFIGURATION FORM WRITES, so it is offered to a writer of the resource alone.
  defp configurable?(resource, actor), do: has_config?(resource) and writable?(resource, actor)

  # One page (newest first) of a record's PENDING drafts + the total — backs the picker, for any
  # draftable resource (Page/Layout) via its `draft_spec`.
  defp list_drafts(record, resource, actor, page_num) do
    case draft_spec(resource) do
      nil ->
        {[], 0}

      spec ->
        {action, opts} = drafts_list_scope(spec, actor)
        offset = (max(page_num, 1) - 1) * @drafts_per_page

        spec.draft
        |> Ash.Query.for_read(action, %{spec.source_field => record.id}, opts)
        |> Ash.Query.load([:site])
        |> Ash.read(page: [limit: @drafts_per_page, offset: offset, count: true])
        |> case do
          {:ok, %Ash.Page.Offset{results: results, count: count}} ->
            {results, count || length(results)}

          {:ok, results} when is_list(results) ->
            {results, length(results)}

          _ ->
            {[], 0}
        end
    end
  end

  # Master lists any site's drafts (bypass); a tenant only their own (scoped by `tenant:`). Both
  # carry the actor so policies run.
  defp drafts_list_scope(%{list_actions: {_tenant, master}}, %{site_id: nil} = actor),
    do: {master, [actor: actor]}

  defp drafts_list_scope(%{list_actions: {tenant, _master}}, %{site_id: site_id} = actor)
       when is_binary(site_id),
       do: {tenant, [actor: actor, tenant: site_id]}

  # The editor's address is the editor's to spell: `Section.editor_url/2` asks
  # `runtime:document:editor_url`, one question for all four kinds, and no editor installed is no
  # link. This used to name a `/builder/layout/:site/:id/edit` path that matched no route at all, and
  # returned `nil` for error pages and components — so three of the four editable resources had no
  # way in.
  #
  # `site_id` travels as a query param because a MASTER can edit another site's record and the
  # builder needs to know which tenant to scope its palette and its save to; a tenant admin's own
  # site is already implied by their actor, and a global row has no site at all.
  @builder_sections %{
    MishkaCmsCore.Runtime.Page => "page",
    MishkaCmsCore.Runtime.Layout => "layout",
    MishkaCmsCore.Runtime.ErrorPage => "error-page",
    MishkaCmsCore.Runtime.Component => "component"
  }

  # A button that leads to a refusal is worse than no button: `BuilderLive` turns a tenant away from
  # a shared row's address, so the row does not offer it one. Everything else about the record — the
  # preview, the details, the versions — stays, because seeing it was never the restricted part.
  #
  # AND ONLY TO SOMEONE WHO MAY OPEN THAT BUILDER — `Section.allowed?/2`, which `BuilderLive` asks
  # again at mount.
  defp visual_editor_url(record, resource, actor) do
    with {:ok, section} <- Map.fetch(@builder_sections, resource),
         true <- can_edit?(resource, record, actor),
         true <- Section.allowed?(actor, section),
         url when is_binary(url) <- Section.editor_url(section, record.id) do
      url <> site_query(record)
    else
      _no_way_in -> nil
    end
  end

  @doc """
  What a list screen of `resource` offers its reader, read once at mount: the reader's permissions
  loaded onto `:current_user` — so the table's row actions and this modal ask without a query each —
  and `:writable?`, whether it writes the resource's records.
  """
  @spec assign_access(Phoenix.LiveView.Socket.t(), module()) :: Phoenix.LiveView.Socket.t()
  def assign_access(socket, resource) do
    user = AccessPermissions.with_permissions(socket.assigns[:current_user])

    socket
    |> assign(:current_user, user)
    |> assign(:writable?, writable?(resource, user))
  end

  defp site_query(%{site_id: site_id}) when is_binary(site_id), do: "?site_id=#{site_id}"
  defp site_query(_record), do: ""

  defp modified_by([latest | _older], masters), do: VersionHistory.author(latest, masters)
  defp modified_by([], _masters), do: MishkaCmsCore.Accounts.Helper.label(:system)

  ## Versions (the modal's Versions tab — timeline + pagination + restore)
  ##
  ## BOTH READ THE DATABASE, SO NEITHER RUNS HERE. A page of versions is a read plus a count, and a
  ## restore is a write followed by the same pair; doing them in the LiveView process froze the whole
  ## modal — every tab, the close button included — for as long as they took. They run in
  ## `start_async(:preview_versions, …)` instead and the tab draws a spinner in the meantime.

  @doc """
  Go to a (clamped) versions page and reload it, off the LiveView process. `page` is a number or the
  text the browser sent; text that is not a whole number leaves the modal as it is.
  """
  def versions_paginate(socket, page) when is_binary(page) do
    case Integer.parse(page) do
      {number, ""} -> versions_paginate(socket, number)
      _not_a_number -> socket
    end
  end

  def versions_paginate(socket, page) when is_integer(page) do
    p = socket.assigns.preview
    max_page = max(1, ceil(p.versions_total / @versions_per_page))
    page = page |> max(1) |> min(max_page)
    {record, resource, actor} = {p.record, p.resource, socket.assigns.current_user}

    socket
    |> put_preview(&%{&1 | versions_loading?: true, expanded_version_id: nil})
    |> MishkaGervaz.Messages.start_async(:preview_versions, fn ->
      {versions, total, masters} = load_versions_page(record, resource, actor, page)
      {:versions, versions, total, masters, page, nil}
    end)
  end

  @doc "Expand/collapse a version's change details."
  def toggle_version(socket, version_id) do
    put_preview(socket, fn p ->
      %{
        p
        | expanded_version_id: if(p.expanded_version_id == version_id, do: nil, else: version_id)
      }
    end)
  end

  @doc "Restore a version (master/tenant aware) and reload the current page, off the LiveView process."
  def restore_version(
        %{assigns: %{preview: %{writable?: false, resource: resource}}} = socket,
        _id
      ),
      do: put_flash(socket, :error, refusal(resource))

  def restore_version(socket, version_id) do
    p = socket.assigns.preview
    user = socket.assigns.current_user
    {record, resource, page} = {p.record, p.resource, p.versions_page}

    socket
    |> put_preview(&%{&1 | versions_loading?: true})
    |> MishkaGervaz.Messages.start_async(:preview_versions, fn ->
      flash = run_restore(record, resource, version_id, user)
      {versions, total, masters} = load_versions_page(record, resource, user, page)
      {:versions, versions, total, masters, page, flash}
    end)
  end

  defp run_restore(record, resource, version_id, user) do
    with {:ok, {action, opts}} <- version_restore_action(user),
         {:ok, _restored} <-
           resource
           |> Ash.ActionInput.for_action(action, %{id: record.id, version_id: version_id}, opts)
           |> Ash.run_action(opts) do
      {:info, gettext("Version restored.")}
    else
      {:error, _reason} -> {:error, gettext("Could not restore the version.")}
    end
  end

  @doc "Place a freshly-read page of versions (and any flash the work produced) into the assign."
  def versions_loaded(socket, {:ok, {:versions, versions, total, masters, page, flash}}) do
    socket
    |> put_preview(fn p ->
      %{
        p
        | versions: versions,
          versions_total: total,
          version_masters: masters,
          versions_page: page,
          versions_loading?: false
      }
    end)
    |> maybe_flash(flash)
  end

  def versions_loaded(socket, {:exit, _reason}) do
    socket
    |> put_preview(&%{&1 | versions_loading?: false})
    |> put_flash(:error, gettext("Could not load the version history."))
  end

  defp maybe_flash(socket, nil), do: socket
  defp maybe_flash(socket, {kind, message}), do: put_flash(socket, kind, message)

  ## Force compile (the modal's action beside "Visual Editor")

  @doc """
  Build this record's runtime module NOW, whether or not it is marked for precompilation.

  A lazy record is built by the first request that needs it, which is the right default and a poor
  way to find out that its template no longer compiles: the person who broke it is not the person
  who discovers it. This is the same call the runtime makes on that first request, with `:update` so
  an already-loaded module is rebuilt rather than reported as fine.

  It also names a real cost, which is why it is a button and not something the modal does on its own:
  a compiled module is code held in RAM for the life of the node.
  """
  def force_compile(%{assigns: %{preview: %{writable?: false, resource: resource}}} = socket),
    do: put_flash(socket, :error, refusal(resource))

  def force_compile(socket) do
    p = socket.assigns.preview

    case compile_target(p.record, p.resource) do
      nil ->
        put_flash(socket, :error, gettext("This record has nothing to compile."))

      target ->
        socket
        |> put_preview(&%{&1 | compiling?: true})
        |> MishkaGervaz.Messages.start_async(:preview_compile, fn ->
          {:compiled, run_compile(target)}
        end)
    end
  end

  # Only a module-backed resource compiles, and only an active one: the compile worker reads the row
  # back through the same query the runtime uses, and for a Component that query filters on `active`
  # — so force-compiling a switched-off record would report `:not_found` rather than do anything.
  defp compile_target(nil, _resource), do: nil

  defp compile_target(record, resource) do
    cfg = RuntimeStatus.config(resource)
    lookup = Map.get(record, Map.get(cfg, :lookup_field))

    if cfg.kind == :module and Map.get(record, :active, false) and is_binary(lookup) do
      site = warm_site_name(record)

      %{
        module: CompilerHelpers.module_name(Map.get(record, cfg.key_field), site, cfg.type),
        lookup: lookup,
        site: site,
        site_id: Map.get(record, :site_id),
        label: String.downcase(cfg.label)
      }
    end
  end

  defp run_compile(target),
    do:
      ModuleCompilerHandler.compile_or_return_module(
        target.module,
        target.lookup,
        target.site,
        target.site_id,
        :update
      )

  @doc "Report a force compile and refresh the Pipeline tab from what actually happened."
  # THE MODULE NAME IS NOT A NAME THE READER HAS. A runtime module is `Runtime.<md5>.Component`,
  # which `inspect/1` renders as a quoted atom because the hash segment is not a valid alias — so
  # the message said `:"Elixir.MishkaCmsCore.Runtime.40542fb59cad45736c5cd234cc1109bf.Component"`
  # about a record the reader knows by its name. The Pipeline tab is where the module is spelled out.
  def compiled(socket, {:ok, {:compiled, {:ok, _module}}}) do
    socket
    |> refresh_after_compile()
    |> put_flash(:info, compiled_message(socket.assigns.preview))
  end

  def compiled(socket, {:ok, {:compiled, {:error, reason}}}) do
    socket
    |> refresh_after_compile()
    |> put_flash(:error, gettext("Compile failed: %{reason}", reason: compile_error(reason)))
  end

  def compiled(socket, {:exit, _reason}) do
    socket
    |> put_preview(&%{&1 | compiling?: false})
    |> put_flash(:error, gettext("The compile did not finish."))
  end

  defp compiled_message(%{record: record, resource: resource}) do
    case compile_target(record, resource) do
      nil -> gettext("Compiled — this record is now loaded in RAM.")
      _target -> loaded_message(resource)
    end
  end

  defp loaded_message(MishkaCmsCore.Runtime.Component),
    do: gettext("Compiled — this component is now loaded in RAM.")

  defp loaded_message(MishkaCmsCore.Runtime.Layout),
    do: gettext("Compiled — this layout is now loaded in RAM.")

  defp loaded_message(MishkaCmsCore.Runtime.ErrorPage),
    do: gettext("Compiled — this error page is now loaded in RAM.")

  defp loaded_message(MishkaCmsCore.Runtime.Page),
    do: gettext("Compiled — this page is now loaded in RAM.")

  defp loaded_message(_resource), do: gettext("Compiled — this record is now loaded in RAM.")

  defp refresh_after_compile(socket) do
    put_preview(socket, fn p ->
      %{p | compiling?: false, status: p.record && RuntimeStatus.compute(p.record, p.resource)}
    end)
  end

  defp compile_error({:compilation_error, message}) when is_binary(message), do: message
  defp compile_error(:not_found), do: gettext("the record could not be read back for compilation")
  defp compile_error(:compilation_timeout), do: gettext("it took too long and was given up on")
  defp compile_error(reason), do: inspect(reason)

  # The button is offered for exactly the records it can act on: module-backed and active.
  defp force_compilable?(record, resource), do: compile_target(record, resource) != nil

  ## Duplicate (the modal's action beside "Visual Editor", components only)

  @doc """
  Copy the open component as a new one, off the LiveView process — see
  `MishkaCmsCore.Runtime.ComponentCopy`.

  A copy is a whole create — validations, a signature, a version row and a compile job — so it runs
  in `start_async(:preview_duplicate, …)` and the button reports itself busy meanwhile. Only offered,
  and only run, when the modal decided `duplicable?`: the event is something a browser can send
  whether or not the button was drawn.
  """
  def duplicate(%{assigns: %{preview: %{duplicable?: true, record: record}}} = socket) do
    actor = socket.assigns.current_user

    socket
    |> put_preview(&%{&1 | duplicating?: true})
    |> MishkaGervaz.Messages.start_async(:preview_duplicate, fn ->
      ComponentCopy.duplicate(record, actor)
    end)
  end

  def duplicate(socket),
    do: put_flash(socket, :error, gettext("This component cannot be duplicated here."))

  @doc """
  Close the modal on a copy, which lands at the top of the table through the resource's own
  broadcast; keep it open on a refusal, so the reader still has the source in front of them.
  """
  # ONLY THE MODAL THAT ASKED IS CLOSED. Closing the modal does not stop the write, so the copy can
  # land after the reader closed it, opened another record, or reopened this one — and dismissing
  # then hides a modal they are reading. A copy names its source in `copied_from`.
  def duplicated(
        %{assigns: %{preview: %{duplicating?: true, record: %{id: id}}}} = socket,
        {:ok, {:ok, %{extra: %{"copied_from" => id}} = copy}}
      ) do
    socket
    |> dismiss()
    |> announce_copy(copy)
  end

  def duplicated(socket, {:ok, {:ok, copy}}), do: announce_copy(socket, copy)

  def duplicated(socket, {:ok, {:error, %Ash.Error.Invalid{} = error}}) do
    socket
    |> put_preview(&%{&1 | duplicating?: false})
    |> put_flash(
      :error,
      gettext("Could not duplicate: %{reason}", reason: invalid_message(error))
    )
  end

  def duplicated(socket, {:ok, {:error, _refused}}) do
    socket
    |> put_preview(&%{&1 | duplicating?: false})
    |> put_flash(:error, gettext("Could not duplicate this component."))
  end

  def duplicated(socket, {:exit, _reason}) do
    socket
    |> put_preview(&%{&1 | duplicating?: false})
    |> put_flash(:error, gettext("The duplicate did not finish."))
  end

  defp announce_copy(socket, copy),
    do: put_flash(socket, :info, gettext("Duplicated as “%{name}”", name: copy.name))

  # OFFERED ONLY WHERE THE WRITE WOULD LAND, because a button that leads to a refusal is worse than
  # no button. `can_edit?/3` keeps a site to its own rows, which is also what keeps a copy in its
  # source's scope; and a component carrying helpers is copied only while this deployment takes
  # author-written Elixir (`CodeAccess.enabled?/0`), since the copy writes them anew.
  defp duplicable?(record, MishkaCmsCore.Runtime.Component = resource, actor),
    do:
      can_edit?(resource, record, actor) and writable?(resource, actor) and
        (List.wrap(record.helpers) == [] or CodeAccess.enabled?())

  defp duplicable?(_record, _resource, _actor), do: false

  defp load_versions_page(record, resource, actor, page) do
    case version_get_action(actor) do
      {:ok, {action, opts}} -> versions_page(record, resource, actor, page, action, opts)
      {:error, :forbidden} -> {[], 0, MapSet.new()}
    end
  end

  defp versions_page(record, resource, actor, page, action, opts) do
    offset = (page - 1) * @versions_per_page

    versions =
      case resource
           |> Ash.Query.for_read(
             action,
             %{versions_limit: @versions_per_page, versions_offset: offset},
             opts
           )
           |> Ash.Query.filter(id == ^record.id)
           |> Ash.read_one(opts) do
        {:ok, %{sorted_versions: v}} when is_list(v) -> v
        _ -> []
      end

    {versions, count_versions(resource, record.id, actor), VersionHistory.master_ids(versions)}
  end

  defp version_get_action(%{site_id: site_id} = actor) when is_binary(site_id),
    do: {:ok, {:get_with_versions, [tenant: site_id, actor: actor]}}

  defp version_get_action(%{site_id: nil} = actor),
    do: {:ok, {:master_get_with_versions, [actor: actor]}}

  defp version_get_action(_not_a_user), do: {:error, :forbidden}

  defp count_versions(resource, id, actor) do
    version_resource = Module.concat(resource, Version)

    case version_resource
         |> Ash.Query.for_read(:read_any, %{}, actor: actor)
         |> Ash.Query.filter(version_source_id == ^id)
         |> Ash.count(actor: actor) do
      {:ok, n} -> n
      _ -> 0
    end
  end

  # The actor is in the opts the input is BUILT with, not only in the run: the action's own
  # validations see the actor the input was built with.
  defp version_restore_action(%{site_id: site_id} = actor) when is_binary(site_id),
    do: {:ok, {:restore_version_api, [tenant: site_id, actor: actor]}}

  defp version_restore_action(%{site_id: nil} = actor),
    do: {:ok, {:master_restore_version, [actor: actor]}}

  defp version_restore_action(_not_a_user), do: {:error, :forbidden}
end
