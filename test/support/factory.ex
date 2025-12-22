defmodule MishkaCmsCore.Test.Factory do
  @moduledoc """
  Fixtures for this library's own suite: sites, users, permissions, and the runtime records
  (components, layouts, pages, error pages, JS hooks, media) that everything else is built on.

  These are the same wrappers the CMS's factory exposes and the ones every extension's factory
  re-states, because a path dependency cannot reach into the CMS's `test/support`. The generators
  behind them are `MishkaCmsCore.Dev.Generator`, which ships in `lib/`.

  Records are tenant-scoped, so each wrapper pops `:site_id` and passes it as the Ash tenant; a
  `nil` tenant means the global row.
  """

  import MishkaCmsCore.Dev.Generator, except: [generate: 1, generate: 2]
  import Ash.Generator, only: [generate: 1]

  require Ash.Query

  def create_site!(overrides \\ []) do
    overrides
    |> site()
    |> generate()
  end

  # Component factory
  def create_component!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)

    overrides
    |> component(site_id)
    |> generate()
  end

  @chelekom Path.join([:code.priv_dir(:mishka_cms_core), "cms_ui_kits", "chelekom.json"])

  @doc """
  The named rows of the Chelekom kit this library ships, as palette entries (`name`, `attrs`,
  `slots`, `template`), in the order asked. The bundle is 12 MB, so call it from `setup_all`.
  """
  def chelekom_rows(names) do
    rows =
      @chelekom
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("components")
      |> Map.new(&{&1["name"], &1})

    Enum.map(names, &palette_row(Map.fetch!(rows, &1)))
  end

  defp palette_row(row),
    do: %{
      name: row["name"],
      attrs: row["attrs"] || [],
      slots: row["slots"] || [],
      template: row["template"] || ""
    }

  @doc """
  Chelekom's Form Wrapper and Simple Form copied as `wrapper` and `simple`, the Simple Form calling
  the copied wrapper and no longer requiring `for`: a pair only their markup marks as forms. `rows`
  holds both originals, as `chelekom_rows/1` answers them.
  """
  def renamed_form_pair(rows, wrapper \\ "acme-wrapper", simple \\ "acme-simple") do
    by_name = Map.new(rows, &{&1.name, &1})

    [
      %{Map.fetch!(by_name, "chelekom-form-wrapper") | name: wrapper},
      by_name
      |> Map.fetch!("chelekom-simple-form")
      |> Map.put(:name, simple)
      |> Map.update!(:template, &String.replace(&1, "chelekom-form-wrapper", wrapper))
      |> Map.update!(:attrs, &Enum.map(&1, fn attr -> optional_for(attr) end))
    ]
  end

  defp optional_for(%{"name" => "for", "opts" => opts} = attr),
    do: %{attr | "opts" => Map.put(opts, "required", false)}

  defp optional_for(attr), do: attr

  # Layout factory
  def create_layout!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    tenant = site_id

    overrides
    |> layout(tenant)
    |> generate()
  end

  # ErrorPage factory
  def create_error_page!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)

    # ErrorPage MUST have a site_id (not global)
    site_id = site_id || create_site!().id
    tenant = site_id

    overrides
    |> error_page(tenant)
    |> generate()
  end

  # JsHook factory
  def create_js_hook!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    tenant = site_id

    overrides
    |> js_hook(tenant)
    |> generate()
  end

  # Page factory
  def create_page!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    # Page MUST have a site_id (not global)
    site_id = site_id || create_site!().id
    tenant = site_id

    overrides
    |> page(tenant)
    |> generate()
  end

  # User factory
  def create_user!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    # User can be global (nil) or site-specific
    tenant = site_id

    overrides
    |> user(tenant)
    |> generate()
  end

  # Permission factory
  def create_permission!(overrides \\ []) do
    overrides
    |> permission()
    |> generate()
  end

  @doc """
  A user holding `permission_names`, returned with `:permissions` loaded so it can be used directly
  as an Ash `actor:` without a further load.

  Authorization in this CMS turns on two independent things — WHICH permissions a user holds and
  WHICH site they belong to — so most policy tests need the same three actors: a master
  (`site_id: nil`) with roles, a tenant with the same roles, and a tenant with none. Permissions are
  looked up before being created so several actors can share one named permission in a test.

      master = create_user_with_permissions!(["admin:dashboard:*"])
      tenant = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
      nobody = create_user!(site_id: site.id)
  """
  def create_user_with_permissions!(permission_names, overrides \\ []) do
    user = create_user!(overrides)
    permission_ids = Enum.map(permission_names, &find_or_create_permission!(&1).id)

    user
    |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: permission_ids},
      authorize?: false,
      tenant: user.site_id
    )
    |> Ash.update!()
    |> Ash.load!([:permissions], authorize?: false, tenant: user.site_id)
  end

  defp find_or_create_permission!(name) do
    MishkaCmsCore.Accounts.Permission
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> create_permission!(name: name)
      {:ok, permission} -> permission
    end
  end

  # MediaCategory factory
  def create_media_category!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    # MediaCategory MUST have a site_id (not global)
    site_id = site_id || create_site!().id
    tenant = site_id

    overrides
    |> media_category(tenant)
    |> generate()
  end

  # Media factory
  def create_media!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    # Media MUST have a site_id (not global)
    site_id = site_id || create_site!().id
    tenant = site_id

    overrides
    |> media(tenant)
    |> generate()
  end
end
