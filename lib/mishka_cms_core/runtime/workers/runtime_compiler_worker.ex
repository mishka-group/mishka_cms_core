# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker do
  @moduledoc false
  use Oban.Worker, queue: :default
  require Ash.Query
  require Logger

  alias MishkaCmsCore.Runtime.Compilers.{
    TailwindCompiler,
    JavaScriptCompiler,
    ModuleCompiler,
    SitemapCompiler
  }

  import MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler,
    only: [compile_or_return_module: 5]

  alias MishkaCmsCore.Runtime.States.{WebRunTimeMetaDataState, SiteState, CompileFailureState}
  alias MishkaCmsCore.Runtime.Handlers.BootHandler
  alias MishkaCmsCore.Runtime.Compilers.Helpers

  # A SWITCHED-OFF SITE IS NOT BUILT BEHIND ITS PURGE. Switching it back on runs
  # `BootHandler.compile_site/2`, which rebuilds every part of it from the database, edits made in
  # between included, so a create, update, restore or asset build for it now would only put back
  # what the purge took away. A removal still runs, so nothing it cleans up is left behind.
  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    cond do
      for_another_instance?(job) -> {:snooze, snooze_seconds(job)}
      builds_for_inactive_site?(args) or stale?(args) -> :ok
      true -> run(job)
    end
  end

  # A JOB THAT NAMES AN INSTANCE IS BUILT ON IT. A bundle job carries the `"boot_id"` of the
  # instance that inserted it (`BootHandler.asset_job/4`), because what it builds goes into that
  # instance's own `AssetsState`, from the template files on that instance's disk. A deploy that
  # starts the next instance beside the old one shares one database, so one Oban queue, and either
  # instance may take the job. One that is not this instance's is snoozed, for 1 second and twice as
  # long each time up to a minute, so the instance it names takes it.
  #
  # Snoozed only while it is younger than `@claim_window`, the same half hour the app's
  # `Oban.Lifeline` waits (`rescue_after`) before it takes an instance that holds a job for gone. An
  # older one belongs to an instance that is gone — a deploy whose new instance stopped — and is
  # built wherever it is taken, as a job with no `"boot_id"` is, and one taken by an instance that
  # has none.
  @claim_window :timer.minutes(30)
  @snooze_seconds [1, 2, 4, 8, 16, 32]
  @longest_snooze 60

  defp for_another_instance?(%Oban.Job{
         args: %{"boot_id" => boot_id},
         inserted_at: %DateTime{} = inserted_at
       })
       when is_binary(boot_id) do
    own = BootHandler.boot_id()

    is_binary(own) and boot_id != own and
      DateTime.diff(DateTime.utc_now(), inserted_at, :millisecond) < @claim_window
  end

  defp for_another_instance?(_job), do: false

  defp snooze_seconds(%Oban.Job{meta: meta}) do
    snoozed = if is_map(meta), do: Map.get(meta, "snoozed", 0), else: 0
    Enum.at(@snooze_seconds, snoozed, @longest_snooze)
  end

  # A SITEMAP BUILD HAS TEN MINUTES, so one that never ends cannot hold the `:sitemaps` queue for
  # good; it is retried as a job that raised. Every other job runs as long as it needs.
  @impl Oban.Worker
  def timeout(%Oban.Job{
        args: %{
          "resource" => "MishkaCmsCore.Runtime.Handlers.BootHandler",
          "data" => %{"type" => "sitemap"}
        }
      }),
      do: :timer.minutes(10)

  def timeout(_job), do: :infinity

  @building ["create", "update", "unarchive"]

  defp builds_for_inactive_site?(%{"action" => action, "data" => %{"site_id" => site_id}})
       when action in @building and is_binary(site_id),
       do: match?({:ok, %{active: false}}, SiteState.get(site_id))

  defp builds_for_inactive_site?(%{
         "resource" => "MishkaCmsCore.Runtime.Handlers.BootHandler",
         "data" => %{"site_name" => site_name}
       }),
       do: match?({:ok, %{active: false}}, SiteState.get_by_name(site_name))

  defp builds_for_inactive_site?(_args), do: false

  # A JOB CARRIES THE ROW AS IT WAS SAVED, and one that runs late would write that copy over a newer
  # one: a job a stopped node left `executing` — a seed script that exited mid-job — is rescued by
  # `Oban.Lifeline` half an hour later, after the next save's own job already built the row, and its
  # old template replaced the new one, classes and all. The stored row's `updated_at` decides; a job
  # whose row is gone, or whose copy carries no time, runs as before.
  @row_resources %{
    "MishkaCmsCore.Runtime.Page" => MishkaCmsCore.Runtime.Page,
    "MishkaCmsCore.Runtime.Layout" => MishkaCmsCore.Runtime.Layout,
    "MishkaCmsCore.Runtime.ErrorPage" => MishkaCmsCore.Runtime.ErrorPage,
    "MishkaCmsCore.Runtime.Component" => MishkaCmsCore.Runtime.Component,
    "MishkaCmsCore.Runtime.JsHook" => MishkaCmsCore.Runtime.JsHook,
    "MishkaCmsCore.Runtime.Stylesheet" => MishkaCmsCore.Runtime.Stylesheet
  }

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  defp stale?(%{
         "action" => action,
         "resource" => resource,
         "data" => %{"id" => id, "updated_at" => saved}
       })
       when action in @building and is_binary(id) and is_binary(saved) do
    with {:ok, module} <- Map.fetch(@row_resources, resource),
         {:ok, uuid} <- Ecto.UUID.dump(id),
         {:ok, saved_at, _offset} <- DateTime.from_iso8601(saved),
         {:ok, %{rows: [[%NaiveDateTime{} = stored]]}} <-
           Ecto.Adapters.SQL.query(
             @repo,
             "SELECT updated_at FROM #{AshPostgres.DataLayer.Info.table(module)} WHERE id = $1",
             [uuid]
           ) do
      NaiveDateTime.before?(DateTime.to_naive(saved_at), stored)
    else
      _cannot_tell -> false
    end
  end

  defp stale?(_args), do: false

  defp run(%Oban.Job{args: %{"resource" => "MishkaCmsCore.Runtime.Page"} = args}) do
    %{"action" => action, "data" => page} = args

    case resolve_site(page) do
      :skip ->
        :ok

      {:ok, site_name, site_id} ->
        page_module = Helpers.module_name(page["id"], site_name, "Page")

        result =
          run_lifecycle("Page", action, page["id"], site_name, fn ->
            apply_module_lifecycle(action, page, page_module, "page", "Page")
          end)

        run_asset_compiler(site_name, site_id, "css")
        run_asset_compiler(site_name, site_id, "sitemap")
        result
    end
  end

  defp run(%Oban.Job{args: %{"resource" => "MishkaCmsCore.Runtime.Layout"} = args}) do
    %{"action" => action, "data" => layout} = args

    case resolve_site(layout) do
      :skip ->
        :ok

      {:ok, site_name, site_id} ->
        layout_module = Helpers.module_name(layout["id"], site_name, "Layout")

        result =
          run_lifecycle("Layout", action, layout["id"], site_name, fn ->
            apply_module_lifecycle(action, layout, layout_module, "layout", "Layout")
          end)

        # A layout's robots `noindex` hides its pages from the sitemap
        # (`MishkaCmsCore.Runtime.PageEditions.indexable/1`).
        if is_nil(site_id) do
          BootHandler.create_assets_compilation_jobs("css")
          BootHandler.create_assets_compilation_jobs("sitemap")
        else
          run_asset_compiler(site_name, site_id, "css")
          run_asset_compiler(site_name, site_id, "sitemap")
        end

        result
    end
  end

  defp run(%Oban.Job{args: %{"resource" => "MishkaCmsCore.Runtime.ErrorPage"} = args}) do
    %{"action" => action, "data" => error} = args

    case resolve_site(error) do
      :skip ->
        :ok

      {:ok, site_name, site_id} ->
        error_module = Helpers.module_name(error["id"], site_name, "ErrorPage")

        result =
          run_lifecycle("ErrorPage", action, error["id"], site_name, fn ->
            apply_module_lifecycle(action, error, error_module, "error", "ErrorPage")
          end)

        run_asset_compiler(site_name, site_id, "css")
        result
    end
  end

  defp run(%Oban.Job{args: %{"resource" => "MishkaCmsCore.Runtime.Component"} = args}) do
    %{"action" => action, "data" => com} = args

    case resolve_site(com) do
      :skip ->
        :ok

      {:ok, site_name, site_id} ->
        com_module = Helpers.module_name(com["name"], site_name, "Component")

        result =
          run_lifecycle("Component", action, com["id"], site_name, fn ->
            apply_component_lifecycle(action, com, com_module)
          end)

        # THE SHARED BASE IS LEFT ALONE, because no component is in it. It holds the host shell,
        # `app.css`, and the global JS hooks and stylesheet rows — the things no reachability walk
        # can find. Dropping it here forced a full recompile of all of that on every save of every
        # component in a kit, for a change that cannot touch any of it.
        #
        # Every SITE still rebuilds, because a global component may be reached from any of them. That
        # is broader than necessary and deliberately so: deciding per site means asking whether the
        # component is in that site's closure, and a site wrongly skipped serves a page with missing
        # rules until something unrelated touches it.
        if is_nil(site_id),
          do: BootHandler.create_assets_compilation_jobs("css"),
          else: run_asset_compiler(site_name, site_id, "css")

        result
    end
  end

  defp run(%Oban.Job{args: %{"resource" => "MishkaCmsCore.Runtime.JsHook"} = args}) do
    %{"action" => action, "data" => hook} = args

    case resolve_site(hook) do
      :skip ->
        :ok

      {:ok, site_name, site_id} ->
        if action in ["create", "unarchive"] and !hook["active"] do
          :ok
        else
          if purge?(action, hook),
            do: BootHandler.delete_template_file(template_site(hook), "js_hook", hook["name"])

          if is_nil(site_id) do
            TailwindCompiler.delete_shared_base_css()
            JavaScriptCompiler.delete_shared_base_js()
            BootHandler.create_js_hooks_template()
            BootHandler.create_assets_compilation_jobs()
          else
            create_js_hooks_template_run_js_compiler(site_id, site_name)
          end
        end

        :ok
    end
  end

  defp run(%Oban.Job{args: %{"resource" => "MishkaCmsCore.Runtime.Stylesheet"} = args}) do
    %{"action" => action, "data" => sheet} = args

    case resolve_site(sheet) do
      :skip ->
        :ok

      {:ok, site_name, site_id} ->
        if action in ["create", "unarchive"] and !sheet["active"] do
          :ok
        else
          if is_nil(site_id) do
            TailwindCompiler.delete_shared_base_css()
            BootHandler.create_assets_compilation_jobs("css")
          else
            run_asset_compiler(site_name, site_id, "css")
          end
        end

        :ok
    end
  end

  defp run(%Oban.Job{
         args: %{
           "resource" => "MishkaCmsCore.Runtime.Handlers.BootHandler",
           "data" => %{"site_name" => site_name, "type" => "asset"}
         }
       }) do
    JavaScriptCompiler.compile_and_store(site_name)
    TailwindCompiler.compile_and_store(site_name)
  end

  defp run(%Oban.Job{
         args: %{
           "resource" => "MishkaCmsCore.Runtime.Handlers.BootHandler",
           "data" => %{"site_name" => site_name, "type" => "css"}
         }
       }) do
    TailwindCompiler.compile_and_store(site_name)
  end

  defp run(%Oban.Job{
         args: %{
           "resource" => "MishkaCmsCore.Runtime.Handlers.BootHandler",
           "data" => %{"site_name" => site_name, "type" => "js"}
         }
       }) do
    JavaScriptCompiler.compile_and_store(site_name)
  end

  defp run(%Oban.Job{
         args: %{
           "resource" => "MishkaCmsCore.Runtime.Handlers.BootHandler",
           "data" => %{"site_name" => site_name, "type" => "sitemap"}
         }
       }) do
    # A site no longer cached, or gone while it was built, has nothing to build, as
    # `resolve_site/1`'s `:skip`.
    case SitemapCompiler.compile_and_store(site_name) do
      {:error, :no_site} -> :ok
      built -> built
    end
  end

  defp run(%Oban.Job{args: _args}) do
    # TODO: We should log this why it happends
    :ok
  end

  defp create_js_hooks_template_run_js_compiler(site_id, site_name) do
    try do
      query =
        MishkaCmsCore.Runtime.JsHook
        |> Ash.Query.for_read(:for_tenant_with_globals, %{site_id: site_id}, authorize?: false)
        |> Ash.Query.filter(active == true)
        |> Ash.Query.load([:site])
        |> Ash.Query.sort(priority: :desc, inserted_at: :asc)

      js_hooks_count = Ash.count!(query, authorize?: false)

      if js_hooks_count == 0 do
        :ok
      else
        {batch_size, chunk_size} = BootHandler.get_optimal_batch_config(js_hooks_count)

        failed_compilations =
          query
          |> Ash.stream!(batch_size: batch_size)
          |> Stream.chunk_every(chunk_size)
          |> Stream.flat_map(fn chunk ->
            chunk
            |> Task.async_stream(
              fn js_hook ->
                # Create .template file for JS hook
                BootHandler.create_template_file(
                  js_hook.site && js_hook.site.name,
                  "js_hook",
                  js_hook.name,
                  js_hook.content
                )

                nil
              end,
              max_concurrency: System.schedulers_online(),
              ordered: false,
              timeout: 15_000
            )
            |> Enum.map(fn
              {:ok, nil} -> nil
              {:exit, reason} -> {:js_hook_creation_exit, reason}
            end)
            |> Enum.reject(&is_nil/1)
          end)
          |> Enum.to_list()

        if failed_compilations == [] do
          :ok
        else
          {:error, {:js_hook_processing_failed, failed_compilations}}
        end
      end
    rescue
      error ->
        {:error, error}
    end

    site_name
    |> BootHandler.asset_job(site_id, "asset")
    |> Oban.insert()
  end

  defp run_asset_compiler(site_name, site_id, type) do
    site_name
    |> BootHandler.asset_job(site_id, type)
    |> Oban.insert()
  end

  @doc """
  Writes the record's template file — the text the CSS closure walks and Tailwind scans.

  Written for every ACTIVE record whether or not a module is built for it, because a lazy page,
  layout or component still contributes classes to its site's stylesheet and has to do so *before*
  the request that renders it. Tying this to the compile is what used to leave a lazy record's
  classes out of the bundle entirely.
  """
  def create_template(data, resource, template \\ nil) do
    BootHandler.create_template_file(
      template_site(data),
      resource,
      data["name"],
      template_content(data, resource, template)
    )
  end

  defp template_content(_data, _resource, template) when is_binary(template), do: template
  defp template_content(data, "error", nil), do: BootHandler.build_error_template_content(data)

  defp template_content(data, "component", nil),
    do: BootHandler.build_component_class_content(data)

  defp template_content(data, _resource, nil), do: BootHandler.build_resource_class_content(data)

  @doc """
  Compiles the record's module now, leaving the template file alone.

  Only ever called once `compile?/3` has said the record earns a module — see
  `apply_module_lifecycle/5` and `apply_component_lifecycle/3`.
  """
  def compile_module(module, action, data, resource) do
    case resolve_site(data) do
      :skip ->
        :ok

      {:ok, site_name, site_id} ->
        identifier = if(resource == "component", do: data["name"], else: data["path"])
        update_flag = if(action == "update", do: :update, else: :new)

        with {:ok, _module} <-
               compile_or_return_module(module, identifier, site_name, site_id, update_flag),
             do: :ok
    end
  end

  # Compiles or purges a module-backed resource (Page, Layout, ErrorPage) for its
  # active/precompile state. Purging also drops the routing entry so a
  # deactivated/deleted record stops resolving (→ 404 → ErrorPage) rather than
  # being recompiled on the next visitor request.
  @doc false
  def apply_module_lifecycle(action, data, module, resource, section) do
    cond do
      purge?(action, data) ->
        ModuleCompiler.unload(module)
        WebRunTimeMetaDataState.delete(data["id"])
        BootHandler.delete_template_file(template_site(data), resource, data["name"])
        Logger.info("Purged #{section} module: #{inspect(module)}")
        :ok

      data["active"] ->
        save_metadata(data, section)
        create_template(data, resource)

        if compile?(action, data, Helpers.loaded?(module)),
          do: compile_module(module, action, data, resource),
          else: :ok

      true ->
        :ok
    end
  end

  # THE SAME TWO-HALVES RULE A PAGE FOLLOWS, minus routing: a component has no path and no metadata
  # entry. Its template is written whenever it is active, so the site's CSS covers it; its module is
  # built here only when `precompile` says so, and otherwise by the first render that names it
  # (`MishkaCmsCore.Runtime.LiveViewHelpers.component/1`). Its name is remembered in `SiteState`
  # while it is active, which is what a marker in stored content is checked against. Purging unloads
  # the module and removes the template and the name.
  @doc false
  def apply_component_lifecycle(action, com, module) do
    cond do
      purge?(action, com) ->
        ModuleCompiler.unload(module)
        BootHandler.delete_template_file(template_site(com), "component", com["name"])
        SiteState.delete_component(com["site_id"], com["name"])
        Logger.info("Purged Component module: #{inspect(module)}")
        :ok

      com["active"] ->
        # The render path remembers a component it could not resolve so it stops asking the database
        # on every render. This is the event that makes the answer stale — the component now exists,
        # is switched on, or has been edited — so the memory goes.
        CompileFailureState.clear(module)
        create_template(com, "component")
        SiteState.put_component(com["site_id"], com["name"])

        if compile?(action, com, Helpers.loaded?(module)),
          do: compile_module(module, action, com, "component"),
          else: :ok

      true ->
        :ok
    end
  end

  @doc """
  What a bulk write owes each component row it wrote — a kit installed or upgraded, every row written
  with `defer_runtime` so no job ran for it — once the batch has committed and
  `BootHandler.compile_components/1` has written every template and built every precompiled module
  that was not built yet: the rest of what a single save of the row does
  (`apply_component_lifecycle/3` on `"update"`).

  A row switched off is purged. For one that is on, the memory of its name as unresolvable goes, and
  a module a render had already built — lazy or precompiled — is built again from the new row;
  `compile_components/1` passes over a loaded module, so without this it kept the old row's code
  until the node restarted.

  `data` is the row as a job carries it: `"name"`, `"site_id"` and `"active"`.
  """
  @spec refresh_after_bulk(map()) :: :ok | {:error, term()}
  def refresh_after_bulk(%{"name" => name} = data) do
    case resolve_site(data) do
      :skip ->
        :ok

      {:ok, site_name, _site_id} ->
        module = Helpers.module_name(name, site_name, "Component")

        if data["active"],
          do: rebuild_loaded(module, data),
          else: apply_component_lifecycle("update", data, module)
    end
  end

  defp rebuild_loaded(module, data) do
    CompileFailureState.clear(module)

    if Helpers.loaded?(module),
      do: compile_module(module, "update", data, "component"),
      else: :ok
  end

  # True when a record should be unloaded and de-routed — destroyed, or updated
  # into an inactive state.
  @doc false
  def purge?(action, data) do
    action == "destroy" or (action == "update" and !data["active"])
  end

  # True when an active record should be (re)compiled now: create/unarchive only
  # when precompiled; update when its module is already loaded (keep it fresh) or
  # it was just flagged precompiled (force-precompile at runtime).
  @doc false
  def compile?(action, data, module_loaded?) do
    cond do
      action in ["create", "unarchive"] -> data["precompile"] == true
      action == "update" -> module_loaded? or data["precompile"] == true
      true -> false
    end
  end

  defp save_metadata(data, section) do
    case resolve_site(data) do
      :skip ->
        :ok

      {:ok, site_name, _site_id} ->
        atomized = MishkaCmsCore.Runtime.Helpers.atomize_keys(data)

        WebRunTimeMetaDataState.save(%{
          id: atomized.id,
          site: site_name,
          path: atomized.path,
          title: atomized.name,
          created_at: atomized.updated_at,
          section: section,
          priority: atomized.priority,
          # THE BOOT PASS'S ANSWER, from the same function, over the row as it was stored.
          language:
            MishkaCmsCore.Runtime.PageProvision.routing_language(%{
              extra: data["extra"],
              language: data["language"]
            })
        })
    end
  end

  # Site name used for the template file path: the site's name for a tenant
  # record, nil for a global one (global templates live in a shared dir).
  defp template_site(data) do
    case resolve_site(data) do
      {:ok, _name, nil} -> nil
      {:ok, name, _id} -> name
      :skip -> nil
    end
  end

  # Resolves a record's site from the in-memory `SiteState` (ETS, O(1)) — never
  # the database. A nil `site_id` is a genuine global record → {:ok, "Global",
  # nil}. A `site_id` absent from `SiteState` means the site is archived/deleted
  # (live sites are always cached), so the record has nowhere to compile → :skip.
  @doc false
  def resolve_site(data) do
    case data["site_id"] do
      nil ->
        {:ok, "Global", nil}

      site_id ->
        case SiteState.get!(site_id) do
          %{name: name} -> {:ok, name, site_id}
          nil -> :skip
        end
    end
  end

  # Runs a resource's compile/purge work inside a telemetry span. An `{:error, _}`
  # is logged and returned so Oban retries while the caller still runs the
  # per-site asset recompile; an unexpected raise propagates to telemetry and
  # Oban (whose job args carry resource/action/id/site_id) for logging and retry.
  defp run_lifecycle(resource, action, id, site, fun) do
    # Mark this Oban job process so a module compile it triggers does NOT emit the
    # lazy-compile telemetry — worker compiles are already captured by Oban activity.
    Process.put(:runtime_compile_via_oban, true)
    metadata = %{resource: resource, action: action, id: id, site: site}

    MishkaInstaller.Event.Hook.call("runtime:before_compile", metadata, return: false)

    :telemetry.span([:mishka_cms, :runtime, :workers, :lifecycle], metadata, fn ->
      result = fun.()

      MishkaInstaller.Event.Hook.call("runtime:after_compile", %{args: metadata, result: result},
        return: false
      )

      case result do
        {:error, reason} ->
          Logger.error(
            "[RuntimeCompilerWorker] #{resource} #{action} failed " <>
              "id=#{inspect(id)} site=#{inspect(site)} reason=#{inspect(reason)}"
          )

          {{:error, reason}, Map.put(metadata, :status, :error)}

        _ok ->
          {:ok, Map.put(metadata, :status, :ok)}
      end
    end)
  end
end
