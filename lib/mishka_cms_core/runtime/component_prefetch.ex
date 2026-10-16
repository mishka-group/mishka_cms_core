# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.ComponentPrefetch do
  @moduledoc """
  Builds the components a page or a layout is about to draw, several at once, before it draws them.

  A component that is not precompiled is built by the first render that names it
  (`MishkaCmsCore.Runtime.LiveViewHelpers.component/1`), and a render meets its components one
  after another, a child only once its parent is drawn. So the first visitor of a cold page waited
  for every one of them in a row. Compiling is CPU-bound, and the node has more than one core.

  A page module and a layout module built by `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler` and
  `MishkaCmsCore.Runtime.Compilers.LayoutCompiler` call `prefetch/2` at the top of their `render/1`.

  ## A built page does nothing

  The module carries the components its own template names in a tag that says which copy it draws,
  as module names. When every one of them is loaded — or its last compile failed, or it is another
  site's — `prefetch/2` answers `:ok` having read nothing but the loaded-code table: no file, no
  database, no message.

  ## A cold one

  When one is not, the module's own template is walked from what it keeps
  (`MishkaCmsCore.Runtime.Compilers.CssClosure.reached_components/2`, `:references`), through the
  component templates the boot writes, to every component it reaches, each in the copy the render
  draws. Those not loaded, not known to fail, and global or of the site this process renders for
  are built through `MishkaCmsCore.Runtime.LiveViewHelpers.ensure_component_loaded/2` — the path
  the render takes, so the registry, the worker and `MishkaCmsCore.Runtime.Handlers.CompileGate`
  are the same ones, nothing is compiled twice, and a render or another request asking for one of
  them meanwhile waits for that compile. `render/1` goes on once they are all done.

  ## Its share of the node

  One render builds at most `slots/0` at once: `config :mishka_cms_core, :component_prefetch_share`
  of the gate's limit, rounded down and at least one — half when unset. The rest of the gate stays
  for every other request and site. `0` or `false` turns this off, and a render builds its
  components one after another, as it did.

  ## What it never does

  It takes no lock but a gate slot per compile, and reads no row itself: each compile reads its own
  in its worker, as a render's would. A component that does not compile fails as it does in a
  render — its failure is kept in `MishkaCmsCore.Runtime.States.CompileFailureState`, and the render
  draws the box it always draws in its place. A compile that crashes ends its task, not the page.

  ## Events

    * `runtime:compile:before_page_prefetch` — before anything is built, with
      `%{module: module, site: site_name, site_id: site_id, components: [%{name: name, site: site}]}`,
      `site` the site's name for a component of its own and `"Global"` for a global one. A plugin
      answers the map with other `components` to build more or fewer; only those not built yet, of
      the site rendered for or global, are built.
    * `runtime:compile:after_page_prefetch` — once they are built, with
      `%{module: module, site: site_name, site_id: site_id, built: [component],
      failed: [%{name: name, site: site, reason: reason}]}`.

  ## Telemetry

    * `[:mishka_cms, :runtime, :component_prefetch, :start | :stop | :exception]` — a span around a
      cold page's walk and build, with `%{module: module, site: site_name, site_id: site_id}`, and on
      `:stop` `asked`, `built`, `failed` and `slots` too. A built page emits nothing.
  """

  alias MishkaCmsCore.Runtime.Compilers.{CssClosure, Helpers}
  alias MishkaCmsCore.Runtime.Handlers.CompileGate
  alias MishkaCmsCore.Runtime.LiveViewHelpers
  alias MishkaCmsCore.Runtime.States.{CompileFailureState, SiteState}
  alias MishkaCmsCore.Runtime.Translations
  alias MishkaInstaller.Event.Hook

  @before_event "runtime:compile:before_page_prefetch"
  @after_event "runtime:compile:after_page_prefetch"
  @share 0.5

  @typedoc "A component, and the site a `<.component>` tag names to draw it."
  @type component :: %{name: String.t(), site: String.t()}

  @doc """
  Builds what `owner` is about to draw, unless every component in `named` is already built.

  `owner` is a page or layout module; `named` is the components its template names, as
  `{module, site}`, which the compiler writes into the call. Always `:ok`.
  """
  @spec prefetch(module(), [{module(), String.t()}]) :: :ok
  def prefetch(owner, named) when is_atom(owner) and is_list(named) do
    case Enum.all?(named, &ready?/1) do
      true -> :ok
      false -> cold(owner, slots())
    end
  end

  @doc """
  How many components one render builds at once: `:component_prefetch_share` of
  `MishkaCmsCore.Runtime.Handlers.CompileGate.limit/0`, at least one, and `0` when it is off.
  """
  @spec slots() :: non_neg_integer()
  def slots do
    case Application.get_env(:mishka_cms_core, :component_prefetch_share, @share) do
      share when is_number(share) and share > 0 ->
        max(1, trunc(CompileGate.limit() * min(share, 1)))

      _off ->
        0
    end
  end

  # Loaded first: on a built page that is all that is asked.
  defp ready?({module, site}) do
    Helpers.loaded?(module) or CompileFailureState.failed?(module) or
      not LiveViewHelpers.renders_here?(site)
  end

  defp cold(_owner, 0), do: :ok

  defp cold(owner, slots) do
    {site_id, site_name} = rendering_site()
    meta = %{module: owner, site: site_name, site_id: site_id}

    :telemetry.span([:mishka_cms, :runtime, :component_prefetch], meta, fn ->
      reached = owner |> reached(site_name) |> Enum.filter(&cold?(&1, site_name))

      wanted =
        case Hook.call(@before_event, Map.put(meta, :components, reached), meta: meta) do
          %{components: components} when is_list(components) -> components
          _unchanged -> reached
        end
        |> Enum.filter(&cold?(&1, site_name))
        |> Enum.uniq()

      {built, failed} = build(wanted, slots)

      Hook.call(@after_event, Map.merge(meta, %{built: built, failed: failed}),
        meta: meta,
        return: false
      )

      stop = %{asked: length(wanted), built: length(built), failed: length(failed), slots: slots}
      {:ok, Map.merge(meta, stop)}
    end)
  end

  # The site this process renders for, as `LiveViewHelpers.component/1` reads it: a process that
  # names none, or a site `SiteState` does not know, reaches the global components alone.
  defp rendering_site do
    with site_id when is_binary(site_id) <- Translations.site(),
         {:ok, %{name: name}} <- SiteState.get(site_id) do
      {site_id, name}
    else
      _no_site -> {nil, nil}
    end
  end

  defp reached(owner, site_name) do
    CssClosure.reached_components(site_name,
      roots: [],
      references: [owner.__component_references__()]
    ).components
  end

  defp cold?(%{name: name, site: site}, site_name) when is_binary(name) and is_binary(site) do
    module = Helpers.module_name(name, site, "Component")

    site in ["Global", site_name] and not Helpers.loaded?(module) and
      not CompileFailureState.failed?(module)
  end

  defp cold?(_not_a_component, _site_name), do: false

  defp build([], _slots), do: {[], []}

  defp build(components, slots) do
    MishkaCmsCore.Runtime.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(components, &built?/1,
      max_concurrency: slots,
      ordered: false,
      timeout: :infinity,
      zip_input_on_exit: true
    )
    |> Enum.reduce({[], []}, fn
      {:ok, {component, true}}, {built, failed} -> {[component | built], failed}
      {:ok, {component, false}}, {built, failed} -> {built, [failure(component) | failed]}
      {:exit, {component, _reason}}, {built, failed} -> {built, [failure(component) | failed]}
    end)
    |> then(fn {built, failed} -> {Enum.reverse(built), Enum.reverse(failed)} end)
  end

  defp built?(%{name: name, site: site} = component),
    do: {component, LiveViewHelpers.ensure_component_loaded(name, site)}

  defp failure(%{name: name, site: site}) do
    module = Helpers.module_name(name, site, "Component")
    %{name: name, site: site, reason: CompileFailureState.reason(module)}
  end
end
