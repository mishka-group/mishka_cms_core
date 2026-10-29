# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.LiveViewHelpers do
  @moduledoc """
  The render-time bridge between a compiled runtime template and a compiled runtime component.

  Every module built by `MishkaCmsCore.Runtime.Compilers.ComponentCompiler` imports `component/1`
  and `component/2` from here, so a template written as `<.component component_name="card" .../>`
  resolves against an already-loaded module rather than through an `Code.eval_quoted/3`
  interpretation. Which resolution it takes is the module's own answer: a function component is
  `apply(CardModule, :card, [assigns])`, and one compiled stateful goes through
  `Phoenix.Component.live_component/1` instead. The template is identical either way — see the fork
  in `applied/3` for why the call site must not change.

  `MishkaCmsCore.Runtime.StaticHelpers` is this module for the surfaces that render a template to a
  string, where a live component has no diff to be turned into HTML by.

  Slot items arriving from the database (`:runtime_slot`) are grouped by their `for_slot` name and
  resolved against the target module's **declared** slots, so a name the component never declared
  is reported as a slot error instead of silently minting an atom.

  ## Which site's components a render reaches

  A global component (`site="Global"`, or no `site`) and a component of the site this process renders
  for — the one `MishkaCmsCore.Runtime.Translations.put_site/1` named — and nothing else. A component
  reads as its own site, so one named from another site's page would draw that site's template and
  that site's rows to every visitor, and run its `handle_event`. It is refused before it is built and
  nothing is drawn in its place. A process that names no site reaches the global ones only. The
  module that answers is asked as well, since two names can hash to one module: it is drawn only
  when it was built from a row of the site asked for, or from a global row.

  The site is named where a request becomes a page — `MishkaCmsWeb.RuntimeLive`,
  `MishkaCmsWeb.DraftPreviewLive`, `MishkaCmsWeb.ErrorHTML` — and by the builder's canvas; a preview
  built for one site among others renders inside `rendering_for/2`. A global layout draws on the
  page's site, so it reaches that site's components and the global ones.

  ## In a task

  The site a template renders for and the response's CSP nonce are kept in the process rendering
  it, as Gettext's locale is. A task the template starts through
  `MishkaGervaz.Messages.start_async/4` — or `assign_async/4`, or `in_caller_locale/1` — is handed
  all three (`carry_into_tasks/0`), so `t/1,2`, `site_path/2`, `component/1` and `csp_nonce/0`
  answer inside it what they answer outside it:

      def load(socket) do
        MishkaGervaz.Messages.start_async(socket, :links, fn ->
          %{about: site_path("/:lang/about", "fa"), label: t("About")}
        end)
      end

  A task started any other way, `Phoenix.LiveView.start_async/4` among them, renders for no site
  and in the default locale: `site_path/2` is `nil` there, and `t/1` answers from the global words.

  ## Events

  - `runtime:render:component_unavailable` — what is drawn in place of a refused component, an empty
    `%Phoenix.LiveView.Rendered{}`, with `%{component_name: name, site: site, site_id: site_id}` as
    its meta: the name and site the template asked for, and the site being rendered. A plugin may
    answer with markup of its own.
  - `runtime:render:before_content_component` — before each component a `rich_content/1` marker
    names is drawn; see `MishkaCmsCore.Runtime.ContentComponents`.

  See also `MishkaCmsCore.Runtime.Compilers.ComponentCompiler` for how the target modules and their
  `__component_information__/0` metadata surface are generated.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  import Phoenix.Component
  alias MishkaCmsCore.Runtime.Compilers.ModuleCompiler
  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.ContentComponents
  alias MishkaCmsCore.Runtime.CspNonce
  alias MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.RenderMetrics
  alias MishkaCmsCore.Runtime.States.CompileFailureState
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.Translations
  alias MishkaInstaller.Event.Hook

  @renders [component: 1, component: 2, captcha: 1, sign_in_providers: 1, rich_content: 1]
  @translates [t: 1, t: 2]
  @nonces [csp_nonce: 0]
  @addresses [site_path: 2]

  @doc """
  What a runtime template imports from here — `component/1,2`, `captcha/1`, `sign_in_providers/1`,
  `rich_content/1`,
  `t/1,2`, `csp_nonce/0` and `site_path/2` — less any name its own `helpers` already define.

  Every compiler — component, page and layout — asks this rather than writing the list itself, so
  the three cannot drift. The exception is not hypothetical: importing a `t/1` into a module that
  defines one is a compile error, and a template that saved yesterday would stop saving today. Its
  own function wins, as a local function would anyway.
  """
  @spec imports([map()] | nil) :: keyword(non_neg_integer())
  def imports(helpers) do
    own = helpers |> List.wrap() |> MapSet.new(&helper_name/1)

    Enum.reject(@renders ++ @translates ++ @nonces ++ @addresses, fn {name, _arity} ->
      MapSet.member?(own, Atom.to_string(name))
    end)
  end

  @doc """
  This response's Content-Security-Policy nonce, for the rare `<style>` a template cannot avoid —
  a page, a layout and a component alike, since a component never sees the page's assigns.

      <style nonce={csp_nonce()}>…</style>

  `nil` outside a response, which HEEx renders as no attribute. See
  `MishkaCmsCore.Runtime.CspNonce` for where the value comes from.
  """
  @spec csp_nonce() :: String.t() | nil
  defdelegate csp_nonce(), to: MishkaCmsCore.Runtime.CspNonce, as: :current

  @doc """
  Registers what the imports above read from the process rendering a template — the site
  `MishkaCmsCore.Runtime.Translations.put_site/1` names and the nonce
  `MishkaCmsCore.Runtime.CspNonce.put/1` records — with
  `MishkaGervaz.Messages.carry_process_keys/1`, so a task started through
  `MishkaGervaz.Messages.start_async/4`, `assign_async/4` or `in_caller_locale/1` renders as its
  starter does. Gervaz carries the locale itself. See "In a task" above.

  Called once, when MishkaCmsCore.Application starts.
  """
  @spec carry_into_tasks() :: :ok
  def carry_into_tasks do
    MishkaGervaz.Messages.carry_process_keys([Translations.site_key(), CspNonce.process_key()])
  end

  @doc """
  The captcha a form asks — see `MishkaCmsCore.Captcha.Widget.captcha/1`.

      <.captcha form={f} for="sign_in" tenant={assigns[:current_tenant]} />
  """
  defdelegate captcha(assigns), to: MishkaCmsCore.Captcha.Widget

  @doc """
  The buttons of the services the site signs in with — see
  `MishkaCmsCore.Accounts.SignInProvider.Widget.sign_in_providers/1`.

      <.sign_in_providers site={assigns[:current_site]} />
  """
  defdelegate sign_in_providers(assigns), to: MishkaCmsCore.Accounts.SignInProvider.Widget

  @doc """
  Stored HTML with the components its markers name drawn in place — a post's body, say.

      <.rich_content
        id={"\#{@id}-body"}
        html={@body}
        site={site_name()}
        current_user={@current_user}
      />

    * `html` — sanitized HTML; it is drawn as it is given, markers aside.
    * `site` — the site's name, as `<.component site="…">` takes it. A marker names the site's own
      component, else the global one of that name. `nil` reaches the global ones alone.
    * `id` — what a stateful component's id starts with, `"content"` when not given; unique on the
      page when two of these draw content.
    * `current_user` — handed to a component that declares a `current_user` attribute.

  A marker that names nothing this site may draw is drawn as nothing. See
  `MishkaCmsCore.Runtime.ContentComponents` for the marker and its rules.
  """
  @spec rich_content(map()) :: Phoenix.LiveView.Rendered.t()
  def rich_content(assigns), do: ContentComponents.draw(assigns, :live)

  @doc """
  `key` in the language this page is being answered in — the runtime counterpart of `gettext/1`,
  for templates that live in the database and so can never reach a `.po` file.

      <h2>{t("Categories")}</h2>
      <p>{t("Read %{count} posts", count: @count)}</p>

  A key nobody has translated renders as itself. The value is a plain string, escaped like any
  other. See `MishkaCmsCore.Runtime.Translations.translate/2`.
  """
  @spec t(term(), keyword() | map()) :: String.t()
  def t(key, bindings \\ []), do: Translations.translate(key, bindings)

  @doc """
  The public address of a stored path on the site this page is rendered for, in a language or with
  captures — `MishkaCmsCore.Runtime.Languages.url/3`, so a link is written once and follows the
  site's URL mode:

      <.link navigate={site_path("/:lang/about", @page.language)}>About</.link>
      <a href={site_path("/:lang/blog/:slug", %{"lang" => @page.language, "slug" => @post.slug})}>

  A language of `nil` is the site's primary one. `nil` when the path makes no address — a capture
  it needs is missing, or the language is not one the site publishes in — which HEEx draws as no
  `href` at all. The site is the one `MishkaCmsCore.Runtime.Translations.put_site/1` named for this
  process, as for `component/1`.
  """
  @spec site_path(String.t(), String.t() | map() | nil) :: String.t() | nil
  def site_path(path, captures) when is_map(captures),
    do: Languages.url(path, captures, Translations.site())

  def site_path(path, language) when is_binary(language) or is_nil(language) do
    site_id = Translations.site()
    Languages.url(path, %{Languages.capture() => language || Languages.primary(site_id)}, site_id)
  end

  @doc """
  Renders a runtime component by name.

  Requires `:component_name`; `:site` selects the tenant-scoped module and may be `nil` for a
  global component. Any other assign is forwarded to the component untouched.

  A `:site` that is neither global nor the site this process renders for draws nothing and builds
  nothing — see "Which site's components a render reaches" above.

  A component whose `precompile` flag is unset is not built at boot, so it is built when a render
  first needs it. The page or layout drawing it builds the components it reaches several at once
  before it draws (`MishkaCmsCore.Runtime.ComponentPrefetch`), and one it could not tell it
  reaches **is built here** — by the first render that names it. `MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler`
  coordinates through its registry, so concurrent first renders of the same component wait on one
  compile rather than racing, and a component whose template does not compile is remembered in
  `MishkaCmsCore.Runtime.States.CompileFailureState` so the next render short-circuits to the
  placeholder instead of retrying.

  The component's CSS does not depend on this: `MishkaCmsCore.Runtime.Handlers.BootHandler` writes
  a template file for every active component whether or not it compiles a module, and that file is
  what the closure walk and Tailwind read. So a lazily-built component renders styled the first
  time it is seen.
  """
  def component(assigns) when is_map(assigns) do
    name = assigns[:component_name] || raise "component name is required"
    site = assigns[:site]
    module = Helpers.module_name(name, site, "Component")

    render_component(reachable(name, site, module), module, name, assigns)
  end

  @doc """
  Runs `fun` rendering for the site named `site`, then puts back the site this process rendered for.

  `site` is a name, as a `<.component site="…">` attribute carries one. `"Global"`, `nil` and a name
  `SiteState` does not know render for no site, which reaches the global components alone.

  For a process that renders one site's template and then another's — a preview built in the admin,
  a palette card — where naming the site for the whole process would leave it pointing at whichever
  was drawn last. `t/1` inside `fun` answers from the same site's words.
  """
  @spec rendering_for(String.t() | nil, (-> result)) :: result when result: term()
  def rendering_for(site, fun) when is_function(fun, 0) do
    previous = Translations.site()
    :ok = Translations.put_site(site_id(site))
    # An author's preview, not a visitor's render: kept out of `RenderMetrics`.
    result = RenderMetrics.unmeasured(fun)
    :ok = Translations.put_site(previous)
    result
  end

  @doc """
  The module `component/1` draws for `name` of the site named `site`, built on first use — or
  `:error` where it draws nothing: a name nothing answers to, an inactive component, another site's.

  For a caller that must know before it draws, as `rich_content/1` does to cast a marker's
  attributes to what the component declares.
  """
  @spec resolve_component(String.t(), String.t() | nil) :: {:ok, module()} | :error
  def resolve_component(name, site) do
    module = Helpers.module_name(name, site, "Component")

    case reachable(name, site, module) do
      true -> {:ok, module}
      _unreachable -> :error
    end
  end

  defp site_id(site) do
    case tenant_for(site) do
      {:ok, site_id} -> site_id
      :error -> nil
    end
  end

  # ASKED BEFORE ANYTHING IS BUILT, so a refused name never compiles and never reads its row. Two
  # ETS reads for a tenant component, none for a global one. The module that is then loaded is asked
  # whose it is.
  defp reachable(name, site, module) do
    case renders_here?(site) do
      true -> owned(ensure_loaded(name, site, module), module, name, site)
      false -> :elsewhere
    end
  end

  # A MODULE NAME IS NOT PROOF OF WHOSE COMPONENT IT IS. `Helpers.module_name/3` hashes the name and
  # the site with nothing between them, so `blog-post-list` of `coffee-shop` and
  # `blog-post-listcoffee-` of `shop` are one module, answering as whichever site built it first. The
  # module carries the site its row belongs to, and that is what is compared: a global template's
  # component must have no site, a tenant's the one being rendered, which `renders_here?/1` has
  # already shown is the site asked for. A local call, no ETS read.
  #
  # A MODULE LEFT BY A SITE THAT IS GONE belongs to nobody: a site deleted, and a new one given its
  # name, would otherwise draw nothing until something rebuilt it. It is unloaded and built again for
  # the site asking, once. One that belongs to another live site is refused.
  defp owned(false, _module, _name, _site), do: false

  defp owned(true, module, name, site) do
    built_for = built_for(module)

    cond do
      built_for == {:ok, owner(site)} ->
        true

      stale?(built_for) ->
        ModuleCompiler.unload(module)
        ensure_loaded(name, site, module) and built_for(module) == {:ok, owner(site)}

      true ->
        :elsewhere
    end
  end

  defp built_for(module) do
    if function_exported?(module, :__component_information__, 1),
      do: {:ok, module.__component_information__([:private, :site_id])},
      else: :unknown
  end

  defp stale?({:ok, site_id}) when is_binary(site_id),
    do: match?({:error, _not_found}, SiteState.get(site_id))

  defp stale?(_global_or_unknown), do: false

  defp owner(site) when site in [nil, "Global"], do: nil
  defp owner(_site), do: Translations.site()

  @doc """
  Whether a template rendered by this process may reach a component of the site named `site`.

  `"Global"` and `nil` always may; a site name only when it is the site
  `MishkaCmsCore.Runtime.Translations.put_site/1` named for this process. A name `SiteState` does
  not know never may. Two ETS reads for a site name, none for a global one.

  `component/1` and `static_component/1` ask it themselves. It is public for a caller that builds a
  component before rendering it — the builder's canvas reads a component's declared attributes
  first — so that a component the render would refuse is never built, and its row never read, on
  the way there.
  """
  @spec renders_here?(String.t() | nil) :: boolean()
  def renders_here?(site) when site in [nil, "Global"], do: true

  def renders_here?(site) do
    case SiteState.get_by_name(site) do
      {:ok, %{id: id}} -> id == Translations.site()
      {:error, :not_found} -> false
    end
  end

  # WHICH SHAPE THIS MODULE TOOK, asked of the module rather than of a name pattern or of a column
  # read on the render path. A module compiled before the flag existed answers `nil` through
  # `get_in/2`, which is falsy, so it takes the path it always took until something rebuilds it.
  #
  # THE STORED TEMPLATE DOES NOT CHANGE, and that is load-bearing rather than conservative.
  # `CssClosure` walks component reachability by finding `component_name="…"` in a template file; a
  # `<.live_component module={…}>` call site is not that edge, so the component's template would
  # never be handed to Tailwind and it would render completely unstyled on every site — silently,
  # in production only, with the canvas looking fine because it links the shared base. So the page
  # goes on writing `<.component component_name="…" …/>` and the fork happens HERE.
  defp applied(module, name, assigns) do
    case stateful?(module) do
      false ->
        RenderMetrics.measure(module, fn ->
          apply(module, String.to_existing_atom(name), [assigns])
        end)

      true ->
        live(module, name, assigns)
    end
  end

  defp stateful?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__component_information__, 1) and
      module.__component_information__([:private, :stateful]) == true
  end

  # A LIVE COMPONENT IS NOTHING WITHOUT AN ID. `Phoenix.LiveView.Diff` raises on one that has none,
  # and a raise here is inside the visitor's LiveView with nothing in front of it — so a missing id
  # draws the placeholder every other unrenderable component draws, rather than taking the page
  # down. The editor mints one at drop; this is for a template somebody hand-wrote.
  # `component_name` AND `site` ARE THE DISPATCH'S OWN, not the component's. A function component
  # simply ignores an assign it never declared; a live one sweeps every undeclared key into its
  # global attr, so both were rendered onto the component's root element —
  # `component_name="blog-post-list" site="probe4"` in the published HTML, on every live component on
  # every page. Dropped here, where they stop being needed.
  @dispatch_keys [:component_name, :site, :runtime_slot]

  defp live(module, _name, %{id: id} = assigns) when is_binary(id) and id != "" do
    assigns
    |> Map.drop(@dispatch_keys)
    |> Map.merge(%{module: module, id: id})
    |> Phoenix.Component.live_component()
  end

  defp live(_module, name, assigns) do
    assigns = Map.put(assigns, :component_name, name)

    ~H"""
    <div class="text-red-600 border border-red-300 p-2 rounded">
      {gettext("%{name} keeps state, so it needs an id — add one to its tag.",
        name: @component_name
      )}
    </div>
    """
  end

  @doc """
  Builds the runtime module for `name`/`site` if it is not already loaded, and says whether it is.

  `component/1` calls this itself. It is public for the callers that read a component's compiled
  metadata *before* rendering it — the page builder canvas asks `__component_information__/1` which
  attributes a component declares, and a component that has never been built declares nothing, so
  every attribute an author set would be silently dropped from the preview.
  """
  @spec ensure_component_loaded(String.t(), String.t() | nil) :: boolean()
  def ensure_component_loaded(name, site),
    do: ensure_loaded(name, site, Helpers.module_name(name, site, "Component"))

  defp ensure_loaded(name, site, module),
    do: available?(Helpers.loaded?(module), module, name, site)

  defp available?(true, _module, _name, _site), do: true
  defp available?(false, module, name, site), do: build(module, name, site, tenant_for(site))

  # A site name that `SiteState` does not know belongs to a site that has been archived or deleted.
  # Falling back to no tenant would read the GLOBAL row of that name and compile it under the
  # tenant's module hash, so there is nothing to build.
  defp build(_module, _name, _site, :error), do: false

  defp build(module, name, site, {:ok, tenant}) do
    case ModuleCompilerHandler.compile_or_return_module(module, name, site, tenant) do
      {:ok, _module} -> true
      {:error, reason} -> remember(module, reason)
    end
  end

  # A NAME THAT RESOLVES TO NOTHING MUST NOT COST TWICE. `ModuleCompilerHandler` leaves `:not_found`
  # deliberately uncached, which is right for a page: routing rejects an unknown path before the
  # compiler is ever asked, and a page that appears later has to compile. A component has no such
  # table in front of it, so an unresolvable name here would start a supervised worker and read the
  # database on EVERY render of the template that carries it. Remembering the outcome makes the
  # second render an ETS lookup, and `MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker` forgets
  # it as soon as a component of that name is created, activated or edited.
  defp remember(module, reason) do
    CompileFailureState.record(module, reason)
    false
  end

  # The site NAME travels in the assigns because that is what the module hash is built from; the
  # compile needs the site's id to read the row as that tenant. "Global" is the name a global
  # component carries, and its rows are the ones with no site at all.
  defp tenant_for(name) when name in [nil, "Global"], do: {:ok, nil}

  defp tenant_for(name) do
    case SiteState.get_by_name(name) do
      {:ok, site} -> {:ok, site.id}
      {:error, :not_found} -> :error
    end
  end

  @doc """
  Renders a runtime component from a name/site pair, merging any extra `assigns`.
  """
  def component(name, site, assigns \\ %{}) do
    component(Map.merge(assigns, %{component_name: name, site: site}))
  end

  @doc """
  The same component, rendered as MARKUP rather than as something LiveView will run — what the
  builder's canvas draws.

  ## Why the canvas cannot call `component/1`

  MishkaCmsBuilderWeb.Live.CanvasLive.contain/3 forces every node's render to iodata on
  purpose, so that a component's raise, throw or exit lands inside a rescue the editor owns rather
  than taking an author's unsaved session with it. `Phoenix.LiveView.Engine` implements
  `Phoenix.HTML.Safe` for `%Phoenix.LiveView.Component{}` only to raise — the two facts are
  irreconcilable, and `contain/3` is the one that must win.

  So a stateful component is rendered here the way LiveView would, minus the process: its `mount/1`
  runs if it has one, the compiler's `update_many/1` carries the author's assigns across, and
  `render/1` is called as the ordinary arity-1 function it is. Real markup, real size, real styling.

  ## What the author sees, and what they do not

  `@myself` is nil, so `phx-target` renders away rather than pointing at a cid that does not exist —
  which means nothing in the frame responds to a click. That is the honest picture: the canvas is
  showing the component's COLD state, and the editor says so beside the selection rather than
  leaving the reader to wonder why the dropdown will not open.

  The socket built here carries `private[:runtime_cold]`, which is how a component that loads in the
  background knows to read inline instead: there is no process to send a task's answer to. That is
  the ONLY surface where it is set — a page's first HTTP render is not connected either, and a
  component must not confuse the two.

  A function component takes the same path it always did, and another site's component is refused
  here exactly as `component/1` refuses it.
  """
  def static_component(assigns) when is_map(assigns) do
    name = assigns[:component_name] || raise "component name is required"
    site = assigns[:site]
    module = Helpers.module_name(name, site, "Component")

    static_render(reachable(name, site, module), module, name, assigns)
  end

  defp static_render(true, module, name, assigns) do
    case stateful?(module) do
      false -> render_component(true, module, name, assigns)
      true -> cold(module, assigns)
    end
  end

  defp static_render(unrenderable, module, name, assigns),
    do: render_component(unrenderable, module, name, assigns)

  # WHAT LIVEVIEW DOES, WITHOUT THE PROCESS. `mount/1` then `update_many/1` then `render/1` is the
  # order a real mount takes, and taking it here is what makes the frame show the component's own
  # markup rather than a box saying one is there. It runs the kit's `mount/1`, which is author code
  # — contained by the canvas's own rescue, which is the reason that rescue exists.
  # THE PRIVATE MAP IS PART OF WHAT LIVEVIEW DOES, and leaving it at the struct's default made a
  # whole family of components unrenderable here. `Phoenix.LiveView.stream/4` attaches an
  # `:after_render` hook to prune what it has sent, `attach_hook/4` reads `private.lifecycle`, and a
  # socket without that key raises `key :lifecycle not found` — inside the canvas's rescue, so the
  # author saw the red box and no reason for it. `Phoenix.LiveView.Diff.mount_component/3` is where
  # the real keys come from; the three that do not belong to a process are the three set here.
  #
  # AND `:runtime_cold` SAYS SO OUT LOUD, because `Phoenix.LiveView.connected?/1` cannot: it answers
  # false here AND on the first HTTP render of a real page, where there IS a process and the socket
  # connects a moment later. A component that reads asks the difference — inline where nobody will
  # ever hand it a task's answer, in the background everywhere else — and asking it of `view` or
  # `endpoint` being nil would be reading LiveView's own struct for a meaning it does not give them.
  # `Diff.mount_component/3` writes `private` itself, from the literal above, so this key cannot
  # reach a component that is being rendered by a LiveView.
  defp cold(module, assigns) do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: nil, myself: nil, flash: %{}},
      private: %{
        live_temp: %{},
        children_cids: [],
        lifecycle: %Phoenix.LiveView.Lifecycle{},
        runtime_cold: true
      }
    }

    given = assigns |> Map.drop(@dispatch_keys) |> with_source(module) |> Map.put_new(:id, nil)

    socket = mounted(module, socket)
    [socket] = module.update_many([{given, socket}])

    module.render(Map.put(socket.assigns, :__changed__, nil))
  end

  defp mounted(module, socket) do
    case function_exported?(module, :mount, 1) do
      false -> socket
      true -> module.mount(socket) |> elem(1)
    end
  end

  # NOTHING IS DRAWN, not a placeholder: to a visitor the page simply has no such block, the way any
  # other refusal looks like something that is not there.
  defp render_component(:elsewhere, _module, name, assigns) do
    meta = %{component_name: name, site: assigns[:site], site_id: Translations.site()}
    assigns = %{}

    Hook.call("runtime:render:component_unavailable", ~H"", meta: meta)
  end

  defp render_component(false, _module, _name, assigns) do
    ~H"""
    <div class="text-red-600">
      {gettext("%{name} Component failed to render!", name: @component_name)}
    </div>
    """
  end

  defp render_component(true, module, name, assigns) do
    case runtime_slot_assigns(module, assigns[:runtime_slot]) do
      {:ok, slot_assigns} ->
        assigns = assigns |> Map.drop([:runtime_slot]) |> Map.merge(slot_assigns)
        applied(module, name, with_source(assigns, module))

      {:error, message} ->
        assigns = Map.put(assigns, :slot_error, message)

        ~H"""
        <div class="text-red-600 border border-red-300 p-2 rounded">
          <strong>{gettext("Slot Error in %{name}:", name: @component_name)}</strong> {@slot_error}
        </div>
        """
    end
  end

  # THE PAGE'S ROWS GO ONLY TO A BLOCK THAT ASKS FOR THEM. A template hands every block of an
  # extension `page_source={assigns[:page_source]}` (`MishkaCmsCore.Runtime.PageSource`), and a
  # component that does not declare the attribute — one an admin keeps on an older kit — sweeps
  # every undeclared key into its global attribute, which draws it onto its root element: the rows
  # of the page as an HTML attribute, or a render that raises on a map it cannot write. Asked of the
  # module's own declaration, so a kit that adds the attribute is handed the rows the moment it is
  # compiled.
  defp with_source(%{page_source: _source} = assigns, module) do
    case declares?(module, "page_source") do
      true -> assigns
      false -> Map.delete(assigns, :page_source)
    end
  end

  defp with_source(assigns, _module), do: assigns

  defp declares?(module, name) do
    function_exported?(module, :__component_information__, 1) and
      module.__component_information__([:component, :attrs])
      |> List.wrap()
      |> Enum.any?(&(to_string(attr_name(&1)) == name))
  end

  defp attr_name(%{name: name}), do: name
  defp attr_name(%{"name" => name}), do: name
  defp attr_name(_not_an_attr), do: nil

  defp runtime_slot_assigns(_module, nil), do: {:ok, %{}}

  defp runtime_slot_assigns(module, slots) when is_list(slots) do
    with :ok <- validate_for_slot(slots) do
      group_by_declared_slot(slots, declared_slots(module))
    end
  end

  defp validate_for_slot(slots) do
    slots
    |> Enum.count(&(is_nil(&1[:for_slot]) || &1[:for_slot] == ""))
    |> case do
      0 -> :ok
      count -> {:error, gettext("Missing for_slot attribute in %{count} slot(s)", count: count)}
    end
  end

  defp group_by_declared_slot(slots, declared) do
    grouped = Enum.group_by(slots, & &1[:for_slot])

    grouped
    |> Map.keys()
    |> Enum.reject(&is_map_key(declared, &1))
    |> case do
      [] ->
        {:ok, Map.new(grouped, fn {name, items} -> {declared[name], items} end)}

      unknown ->
        {:error, gettext("Undeclared slot(s): %{slots}", slots: Enum.join(unknown, ", "))}
    end
  end

  # `slot :name` in the compiled module already created every declared atom, so resolving through
  # this map never creates one (B23) and never raises on unknown database input.
  defp declared_slots(module) do
    module
    |> apply(:__component_information__, [[:component, :slots]])
    |> List.wrap()
    |> Map.new(&{slot_name(&1), String.to_existing_atom(slot_name(&1))})
  end

  defp slot_name(%{name: name}), do: name
  defp slot_name(%{"name" => name}), do: name

  defp helper_name(helper) when is_map(helper),
    do: to_string(Map.get(helper, :name) || Map.get(helper, "name"))

  defp helper_name(_helper), do: nil
end
