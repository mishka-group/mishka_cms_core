# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Helpers do
  @moduledoc false
  # The application this library is installed into: its priv holds the assets the compilers read,
  # and its esbuild profile is the one they run. Named by configuration, never hardcoded.
  @host_app Application.compile_env!(:mishka_cms_core, :host_app)
  @slug_changes [MishkaSlug.Change, MishkaCmsCore.Runtime.Resources.Changes.InternalName]

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

  @doc """
  `key` as the atom of its name when that atom already exists, and as it is otherwise — what
  `atomize_keys/1` does to each key. Makes no atom.

      known_key("label")
      #=> :label
      known_key("no-atom-has-this-name")
      #=> "no-atom-has-this-name"
  """
  @spec known_key(term()) :: term()
  def known_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  def known_key(key), do: key

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

  @doc """
  The slug changes `action` runs, as `{from, into, options}`: each reads `from` and writes its slug
  into `into`. A slug change is `MishkaSlug.Change`, or
  `MishkaCmsCore.Runtime.Resources.Changes.InternalName`, which is one with the internal-name options.

  `options` are the change's own, read through its `init/1` as the action does, so `slug/3` makes
  the slug the save stores. A change wrapped in another that holds it as `change:` — AshEvents wraps
  every change of a resource it records that way — is read as the change it holds. An action with no
  slug change has none.
  """
  @spec slugifiers(struct()) :: [{atom(), atom(), keyword()}]
  def slugifiers(%{changes: changes}) when is_list(changes) do
    for %{change: change} <- changes,
        {module, opts} when module in @slug_changes <- [held_change(change)] do
      {:ok, ready} = module.init(opts)
      {ready[:from], ready[:into] || ready[:from], ready}
    end
  end

  def slugifiers(_action_without_changes), do: []

  # The change itself, or — for one that wraps another as its `change:` option — the one it holds.
  defp held_change({_module, opts} = change) when is_list(opts) do
    case Keyword.get(opts, :change) do
      %{change: held} -> held_change(held)
      _not_a_wrapper -> change
    end
  end

  defp held_change(change), do: change

  @doc """
  Fills the slug of a record being created from its title, for a Gervaz form's `on_validate` hook.

  While the slug follows — it is empty, or it is the slug of the title the form held before this
  change — a change to the `from` field writes the new title's slug into `into`. A change to a field
  the slug is made with, such as the record's site or language, writes the title's slug for it too,
  so a slug made before a site was picked is remade with that site's languages. A slug the author
  typed themselves stops it following, until they empty it again. A record being updated keeps its
  slug whatever happens to the title: the slug is in the record's URL.

  The slug is made by the slug change the form's action runs on `into` (`slugifiers/1`, `slug/3`),
  read off the form's values as they are after this change, so what the author sees is what the
  save stores. A public slug keeps the scripts of the site's languages (`قیمت‌گذاری` stays
  `قیمتگذاری` on a site that publishes in Persian); an internal name keeps Latin letters only, so
  `Café قیمت` becomes `cafe`.

  A title that gives no slug leaves the slug empty and says why under the title, in the words
  `MishkaSlug.Messages.error/1` has for the reason, such as "has no letters or digits to make a slug
  from" for `😀`.

  Returns the params, or `{params, errors}` while the title gives no slug: either is the whole hook.

      hooks do
        on_validate fn params, state ->
          MishkaCmsCore.Runtime.Helpers.follow_slug(params, state, :title)
        end
      end
  """
  @spec follow_slug(map(), map(), atom(), atom()) :: map() | {map(), map()}
  def follow_slug(params, state, from, into \\ :slug)

  def follow_slug(
        %{"form" => %{} = typed} = params,
        %{
          mode: :create,
          form: %{
            source: %AshPhoenix.Form{source: %{action: %{} = action} = held} = form
          }
        } = state,
        from,
        into
      ) do
    held_params = AshPhoenix.Form.params(form)
    before = Map.get(held_params, to_string(from))
    title = Map.get(typed, to_string(from), before)
    shown = Map.get(typed, to_string(into), Map.get(held_params, to_string(into)))

    with true <- is_binary(title),
         {_from, _into, options} <- Enum.find(slugifiers(action), &match?({_, ^into, _}, &1)),
         true <- following?(shown, before, options, held) do
      typing = with_typed(held, typed, held_params)
      made = slugify(title, options, typing)

      params
      |> remade(title != before or made != slugify(title, options, held), into, made)
      |> with_reason(state, from, made)
    else
      _not_following -> params
    end
  end

  def follow_slug(params, _state, _from, _into), do: params

  defp following?(slug, _before, _options, _changeset) when slug in [nil, ""], do: true
  defp following?(slug, before, options, changeset), do: slug == slug(before, options, changeset)

  # The changeset the form held, with the attributes this change gives a new value.
  defp with_typed(changeset, typed, held_params) do
    Enum.reduce(typed, changeset, fn {name, value}, changeset ->
      case Map.get(held_params, name) != value and
             Ash.Resource.Info.attribute(changeset.resource, name) do
        %{name: attribute} -> Ash.Changeset.force_change_attribute(changeset, attribute, value)
        _unchanged_or_not_an_attribute -> changeset
      end
    end)
  end

  defp slugify(text, options, changeset) do
    case String.trim(text) do
      "" -> {:ok, ""}
      _text -> MishkaSlug.slugify(text, MishkaSlug.Change.slug_options(options, changeset))
    end
  end

  defp remade(params, false, _into, _made), do: params

  defp remade(params, true, into, {:ok, slug}),
    do: put_in(params, ["form", to_string(into)], slug)

  defp remade(params, true, into, {:error, _reason}),
    do: put_in(params, ["form", to_string(into)], "")

  defp with_reason(params, _state, _from, {:ok, _slug}), do: params

  defp with_reason(params, state, from, {:error, reason}),
    do:
      {params, Map.put(Map.get(state, :errors) || %{}, from, [MishkaSlug.Messages.error(reason)])}

  @doc """
  The slug a save of `changeset` stores for `text`, made with the `options` of one of its
  `slugifiers/1`, or `nil` when the text gives none (the save refuses it).

  The site's languages, the record's language and the column's length are read off `changeset`
  through `MishkaSlug.Change.slug_options/2`, as the change itself reads them.
  """
  @spec slug(term(), keyword(), Ash.Changeset.t()) :: String.t() | nil
  def slug(text, options, changeset) when is_binary(text) do
    case MishkaSlug.slugify(text, MishkaSlug.Change.slug_options(options, changeset)) do
      {:ok, slug} -> slug
      {:error, _no_slug} -> nil
    end
  end

  def slug(_no_text, _options, _changeset), do: nil
end
