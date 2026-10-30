# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Factory do
  @moduledoc """
  Fixtures for this library's suite and an extension's: sites, users, permissions, and the runtime
  records (components, layouts, pages, error pages, JS hooks, media) that everything else is built
  on.

  These are the same wrappers the CMS's factory exposes. They ship in `lib` so an extension's suite
  imports them instead of re-stating them, since a dependency cannot reach into another project's
  `test/support`. The generators behind them are `MishkaCmsCore.Dev.Generator`.

  Records are tenant-scoped, so each wrapper pops `:site_id` and passes it as the Ash tenant; a
  `nil` tenant means the global row.
  """

  import MishkaCmsCore.Dev.Generator, except: [generate: 1, generate: 2]
  import Ash.Generator, only: [generate: 1]

  alias MishkaCmsCore.Runtime.Compilers.{Helpers, ModuleCompiler}
  alias MishkaCmsCore.Runtime.States.CompileFailureState

  require Ash.Query

  def create_site!(overrides \\ []) do
    overrides
    |> site()
    |> generate()
  end

  # Component factory
  #
  # THE ROW GOES WITH THE TEST, THE MODULE BUILT FROM IT DOES NOT. A module is named from the
  # component's name and its site's name, so the next test to make a site and a component of the
  # same names would be handed this one, built for a site that no longer exists — which
  # `MishkaCmsCore.Runtime.LiveViewHelpers` refuses to draw. The module, and a failure remembered
  # for it, go when the test does.
  def create_component!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)

    component =
      overrides
      |> component(site_id)
      |> generate()

    component.name
    |> Helpers.module_name(site_name(site_id), "Component")
    |> forget_on_exit()

    component
  end

  @doc """
  A component module put by hand at the name the compilers would have built for `name` on `site` (a
  site, or `nil` for a global one), drawing `html` — for a test about the canvas rather than the
  compile pipeline.

  It answers the site it stands for as a compiled one does, since
  `MishkaCmsCore.Runtime.LiveViewHelpers` draws a module only for its own site, and it goes when the
  test does.
  """
  # sobelow_skip ["DOS.StringToAtom", "XSS.Raw"]
  # Test support: `name` and `html` are the calling test's literals, and the module is built for that
  # test and unloaded when it exits.
  def define_component!(name, site, html) do
    module = Helpers.module_name(name, site && site.name, "Component")
    site_id = site && site.id

    ModuleCompiler.unload(module)

    Module.create(
      module,
      quote do
        def __component_information__([:private, :site_id]), do: unquote(site_id)
        def __component_information__(_path), do: []
        # sobelow_skip ["DOS.StringToAtom", "XSS.Raw"]
        def unquote(String.to_atom(name))(_assigns), do: Phoenix.HTML.raw(unquote(html))
      end,
      Macro.Env.location(__ENV__)
    )

    forget_on_exit(module)
  end

  @doc """
  The same cleanup `create_component!/1` registers, for a name the component only takes during the
  test — a rename builds a second module, under the new name.
  """
  def forget_component_on_exit(name, site_id \\ nil) do
    name
    |> Helpers.module_name(site_name(site_id), "Component")
    |> forget_on_exit()
  end

  @doc """
  An `attrs` declaration holding one of every option shape the Chelekom kit ships, for a test about
  what a save keeps.

  Defaults of `nil`, `""`, `false`, `true`, `0`, `1.0` and `[]`; `values` that include `nil`, as
  `chelekom-button`'s `type` does; `editor`; and `default_struct` on a struct attribute. Rows are
  string-keyed, as a row read back from the database is. `every_option_template/0` reads each one.
  """
  def every_option_shape do
    [
      %{
        "name" => "type",
        "type" => "any",
        "opts" => %{
          "default" => nil,
          "doc" => "Specifies the type of the element",
          "values" => ["button", "submit", "reset", nil]
        }
      },
      %{
        "name" => "size",
        "type" => "string",
        "opts" => %{"default" => "large", "values" => ["small", "large"]}
      },
      %{"name" => "icon", "type" => "string", "opts" => %{"default" => nil, "editor" => "icon"}},
      %{"name" => "label", "type" => "string", "opts" => %{"default" => ""}},
      %{"name" => "full_width", "type" => "boolean", "opts" => %{"default" => false}},
      %{"name" => "pill", "type" => "boolean", "opts" => %{"default" => true}},
      %{"name" => "step", "type" => "integer", "opts" => %{"default" => 0}},
      %{"name" => "precision", "type" => "float", "opts" => %{"default" => 1.0}},
      %{"name" => "items", "type" => "list", "opts" => %{"default" => []}},
      %{
        "name" => "on_show",
        "type" => "struct",
        "struct_name" => "Phoenix.LiveView.JS",
        "opts" => %{"default_struct" => true}
      }
    ]
  end

  @doc """
  A template reading every attribute `every_option_shape/0` declares, so a default lost on the way
  raises `KeyError` the first time the component renders without that attribute.
  """
  def every_option_template do
    ~s|<button type={@type} class={[@size, @label]} data-icon={@icon} data-full={to_string(@full_width)} data-pill={to_string(@pill)} data-step={@step} data-precision={@precision} data-items={length(@items)} phx-click={@on_show}>go</button>|
  end

  defp forget_on_exit(module) do
    ExUnit.Callbacks.on_exit({__MODULE__, module}, fn ->
      ModuleCompiler.unload(module)
      CompileFailureState.clear(module)
    end)

    module
  end

  defp site_name(nil), do: nil

  defp site_name(site_id),
    do: Ash.get!(MishkaCmsCore.Runtime.Site, site_id, action: :get_any, authorize?: false).name

  @chelekom MishkaCmsCore.Runtime.Handlers.UiKitHandler.default_bundle_path()

  @doc """
  The named rows of the Chelekom kit this library ships, as palette entries (`name`, `attrs`,
  `slots`, `template`), in the order asked. The bundle is 12 MB, so call it from `setup_all`.
  """
  # sobelow_skip ["Traversal.FileModule"]
  # The path is the bundle `UiKitHandler.default_bundle_path/0` names, never one from a request.
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

  # Redirect factory — a rule is always a site's own.
  def create_redirect!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    site_id = site_id || create_site!().id

    overrides
    |> redirect(site_id)
    |> generate()
  end

  @doc """
  `rows` of `resource`, written in one bulk create through its `:create` action under `tenant` (`nil`
  for global rows), as a fixture: for a suite that needs more rows than one page of a read holds,
  where a create per row costs seconds. Each row is the action's input, and nothing is compiled.
  """
  def create_many!(resource, rows, tenant \\ nil) do
    rows
    |> Ash.bulk_create!(resource, :create,
      tenant: tenant,
      authorize?: false,
      context: %{page_code: :package},
      return_records?: true,
      return_errors?: true,
      stop_on_error?: true
    )
    |> Map.fetch!(:records)
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
