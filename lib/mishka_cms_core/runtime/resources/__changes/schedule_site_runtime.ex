defmodule MishkaCmsCore.Runtime.Resources.Changes.ScheduleSiteRuntime do
  @moduledoc """
  Owns the runtime side of a Site `:create` / `:update` / `:destroy` (archive):
  keeps `SiteState` in sync **and** recompiles or purges the site's dependent
  parts (Pages, Layouts, ErrorPages, Components, JsHooks, Stylesheets).

  On success it classifies the transition from the changeset (old name/active vs
  new) and, on the `:maintenance` queue (so it never starves the live `:modules`
  queue), enqueues `SiteRuntimeWorker`:

    * **rename** (name changed) → purge the OLD-name artifacts, recompile under the new name
    * **deactivate** (active → false) / **archive** → purge the parts (free RAM)
    * **activate** / **unarchive** → recompile the parts
    * host/mode/priority/etc. change, or create → just update `SiteState`; a host change also
      rebuilds the site's sitemap, every address of which is on that host
    * create → also **provision**, which gives the new site its sign-in pages, unless the
      changeset context carries `auth_pages: :inline` (the caller writes them itself)

  Under `config :mishka_cms_core, env_test?: true` nothing is enqueued.

  `:permanent_destroy` is skipped here — that's owned by `ScheduleSiteTeardown`.
  The old name is read from the changeset's pre-image, the only place the DB no
  longer has it after a rename.

  See `MishkaCmsCore.Runtime.Workers.SiteRuntimeWorker` and
  `MishkaCmsCore.Runtime.Handlers.{SiteRuntime, BootHandler}`.
  """
  use Ash.Resource.Change

  alias MishkaCmsCore.Runtime.Compilers.SitemapCompiler
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.Workers.SiteRuntimeWorker

  @impl true
  def change(changeset, _opts, _context) do
    if changeset.action.name == :permanent_destroy do
      changeset
    else
      Ash.Changeset.after_transaction(changeset, &finalize/2)
    end
  end

  defp finalize(changeset, {:ok, record} = result) do
    do_finalize(changeset, record)
    result
  end

  defp finalize(changeset, :ok) do
    if changeset.action.type == :destroy, do: archive(changeset.data)
    :ok
  end

  defp finalize(_changeset, other), do: other

  defp do_finalize(changeset, record) do
    case changeset.action.type do
      :create -> create(changeset, record)
      :destroy -> archive(record)
      _ -> handle_update(changeset, record)
    end
  end

  defp create(changeset, record) do
    save_state(record)
    provision(changeset, record)
  end

  # A NEW SITE GETS ITS SIGN-IN PAGES FROM A JOB, so the create answers at once. A caller that
  # writes them itself says so with `auth_pages: :inline`.
  defp provision(%{context: %{auth_pages: :inline}}, _record), do: :ok

  defp provision(_changeset, record),
    do: enqueue(record.id, record.name, record.name, "provision")

  defp archive(record) do
    SiteState.delete(record.id)
    enqueue(record.id, record.name, record.name, "purge")
  end

  defp handle_update(changeset, record) do
    save_state(record)

    case classify(changeset.action.name, changeset.data.name, changeset.data.active, record) do
      :rename -> enqueue(record.id, record.name, changeset.data.name, "rename")
      :deactivate -> enqueue(record.id, record.name, record.name, "purge")
      :activate -> enqueue(record.id, record.name, record.name, "recompile")
      :unarchive -> enqueue(record.id, record.name, record.name, "recompile")
      :other -> rehost(changeset.data.host, record)
    end
  end

  # EVERY ADDRESS IN A SITEMAP IS ON THE SITE'S HOST. `SiteState` is saved just before, so the job
  # is enqueued for the site as it now is.
  defp rehost(host, %{host: host}), do: :ok
  defp rehost(_old_host, record), do: SitemapCompiler.schedule(record.id)

  defp classify(:unarchive, _old_name, _old_active, _record), do: :unarchive

  defp classify(_name, old_name, _old_active, %{name: new_name}) when old_name != new_name,
    do: :rename

  defp classify(_name, _old_name, true, %{active: false}), do: :deactivate
  defp classify(_name, _old_name, false, %{active: true}), do: :activate
  defp classify(_name, _old_name, _old_active, _record), do: :other

  # A SITE MADE MASTER TAKES THE FLAG FROM THE ONE THAT HAD IT in the cache too, as `:set_as_master`
  # did in the database: the cache is what decides which address masters sign in on.
  defp save_state(record) do
    SiteState.save(%{
      id: record.id,
      name: record.name,
      host: record.host,
      priority: record.priority,
      active: record.active,
      master: record.master,
      mode: record.mode,
      frontend_domain: record.frontend_domain,
      allowed_origins: record.allowed_origins
    })

    if record.master, do: SiteState.set_master(record.id)
  end

  defp enqueue(site_id, site_name, old_name, transition) do
    if !Application.get_env(:mishka_cms_core, :env_test?, false) do
      %{
        "site_id" => site_id,
        "site_name" => site_name,
        "old_name" => old_name,
        "transition" => transition
      }
      |> SiteRuntimeWorker.new(
        meta: %{slug: slug(site_id, transition)},
        unique: [fields: [:worker, :meta], keys: [:slug], states: [:available, :scheduled]],
        replace: [available: [:args], scheduled: [:args]]
      )
      |> Oban.insert()
    end
  end

  # A PROVISION KEEPS A SLOT OF ITS OWN, so a rename or a purge enqueued while it waits does not
  # replace it.
  defp slug(site_id, "provision"), do: "site_provision:#{site_id}"
  defp slug(site_id, _transition), do: "site_runtime:#{site_id}"
end
