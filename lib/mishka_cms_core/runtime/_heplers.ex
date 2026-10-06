defmodule MishkaCmsCore.Runtime.Helpers do
  # The application this library is installed into: its priv holds the assets the compilers read,
  # and its esbuild profile is the one they run. Named by configuration, never hardcoded.
  @host_app Application.compile_env!(:mishka_cms_core, :host_app)

  @doc """
  Returns the path to the static temporary directory.
  """
  def static_temp_dir(extra_path \\ []) do
    case :code.priv_dir(@host_app) do
      {:error, _} -> Path.join(["priv", "static", "temp"] ++ extra_path)
      priv_dir -> Path.join([priv_dir, "static", "temp"] ++ extra_path)
    end
  end

  @doc """
  Recursively turns a map's string keys into atoms, for keys that are already atoms somewhere.

  A key the code names anywhere — `"template"`, `"attrs"`, `"__atom_map__"` — is written as a literal
  in some module, so its atom exists and the key is converted. A key nobody names stays a binary, so
  a caller walking free-form data gets `%{"whatever" => …}` and one matching `%{template: …}` still
  matches.

  Atoms are never garbage collected and the VM stops at about a million of them. These maps are
  JSONB columns with no schema over their keys — a component's `extra`, an attr's `opts`, a page's
  `content` — so converting every key would let whoever authors a document grow a table nothing
  empties. Converting only the keys that already exist cannot add to it at all.
  """
  def atomize_keys(map) when is_map(map) and not is_struct(map) do
    for {k, v} <- map, into: %{}, do: {known_key(k), atomize_keys(v)}
  end

  def atomize_keys(list) when is_list(list) do
    for item <- list, do: atomize_keys(item)
  end

  def atomize_keys(value), do: value

  defp known_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp known_key(key), do: key

  @doc """
  Recursively converts all atom keys in a map to strings.
  Handles nested structures including maps and lists.
  Useful for JSON serialization or when atom keys need to be strings.
  """
  def stringify_keys(map) when is_map(map) and not is_struct(map) do
    for {k, v} <- map, into: %{} do
      {if(is_atom(k), do: Atom.to_string(k), else: k), stringify_keys(v)}
    end
  end

  def stringify_keys(list) when is_list(list) do
    for item <- list, do: stringify_keys(item)
  end

  def stringify_keys(value), do: value

  def get_public_attributes(resource) do
    resource |> Ash.Resource.Info.attributes() |> Enum.filter(& &1.public?) |> Enum.map(& &1.name)
  end

  def take_public_attributes(resource, media) when is_map(media) do
    get_public_attributes(resource)
    |> then(&Map.take(media, &1))
  end

  def take_public_attributes(resource, media) when is_list(media) do
    Enum.map(media, &take_public_attributes(resource, &1))
  end

  @doc """
  Row-action visibility predicate for resources whose records can be either
  global (`site_id == nil`) or tenant-owned (`site_id` is set).

  Returns `true` when the action should be shown to the current user:

    * Master users always see the action.
    * Tenant users only see the action when the record is tenant-owned
      (i.e. `site_id` is set). Global records are master-only.

  Combine with `state.archive_status` to build a full `visible` function:

      action :edit,
        type: :edit,
        visible: fn record, state ->
          state.archive_status == :active and
            MishkaCmsCore.Runtime.Helpers.master_or_tenant_owned?(record, state)
        end
  """
  @spec master_or_tenant_owned?(map(), map()) :: boolean()
  def master_or_tenant_owned?(record, state) do
    Map.get(state, :master_user?, false) or !is_nil(Map.get(record, :site_id))
  end

  # Who writes each runtime type's records from the dashboard: its own section, or code, which
  # writes all six. The names the type's data asks for before a write.
  @dashboard_writers %{
    "page" => ["admin:dashboard:runtime:page", "admin:dashboard:code"],
    "layout" => ["admin:dashboard:runtime:layout", "admin:dashboard:code"],
    "component" => ["admin:dashboard:runtime:component", "admin:dashboard:code"],
    "error_page" => ["admin:dashboard:runtime:error_page", "admin:dashboard:code"],
    "js_hook" => ["admin:dashboard:runtime:js_hook", "admin:dashboard:code"],
    "stylesheet" => ["admin:dashboard:runtime:stylesheet", "admin:dashboard:code"]
  }

  @doc """
  The dashboard names whose holders write `type`'s records: its own section and
  `admin:dashboard:code`. `type` is one of `page`, `layout`, `component`, `error_page`, `js_hook`
  and `stylesheet`; any other has none.
  """
  @spec writers(String.t() | nil) :: [String.t()]
  def writers(type), do: Map.get(@dashboard_writers, type, [])

  @doc """
  Whether the reader of a Gervaz table or form (`state.current_user`) writes `type`'s records from
  the dashboard: it holds one of `writers/1`.

  Combine with `master_or_tenant_owned?/2` so a list stays readable to every dashboard admin while
  only a writer is offered its writes:

      visible fn record, state ->
        state.archive_status == :active and
          MishkaCmsCore.Runtime.Helpers.master_or_tenant_owned?(record, state) and
          MishkaCmsCore.Runtime.Helpers.writes?(state, "page")
      end
  """
  @spec writes?(map(), String.t() | nil) :: boolean()
  def writes?(%{current_user: user}, type) when is_map(user),
    do:
      MishkaCmsCore.Accounts.Checks.AccessPermissions.match?(
        MishkaCmsCore.Accounts.Checks.AccessPermissions.with_permissions(user),
        %{},
        permissions: writers(type)
      )

  def writes?(_state, _type), do: false
end
