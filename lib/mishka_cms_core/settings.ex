defmodule MishkaCmsCore.Settings do
  @moduledoc """
  CMS settings — one module for the whole subject: reading and writing values, plus the registry of
  declared settings the admin page renders.

  ## Reading & writing

  Reads come from the ETS cache (`MishkaCmsCore.Runtime.States.SettingsState`) — lock-free, safe on
  every request; writes go to the durable `MishkaCmsCore.Runtime.Setting` resource and refresh the
  cache. Scalars are stored wrapped as `%{"value" => term}`. Settings are multitenant: a `site_id` of
  `nil` is the GLOBAL value (shared by every site), a `site_id` is that site's override, and a site
  read resolves **site value → global → default**.

      Settings.get("cms.offline", false)                 # global read
      Settings.get("site.title", "MishkaCMS", site_id)   # site value, falling back to global
      Settings.put("cms.offline", true)                  # global write
      Settings.put("site.title", "Acme", site_id: id)    # per-site write

  `put/3` is the trusted infra path — boot seeding and plugin registration, where there is no user
  to speak for — and it skips authorization, multitenancy and the master check together. Anything
  an admin typed goes through `put_as/4` instead, which routes to the resource's own `:set` /
  `:master_set` action with the actor attached, so `MishkaCmsCore.Runtime.Setting`'s policies decide
  which site's row they may touch.

  `put/3` holds the resource's PubSub notifications back (`return_notifications?: true`), refreshes
  the cache, and only then sends them. The order matters: subscribers of `"setting:updated"` react by
  reading the cache, so announcing the write first hands every one of them the value it replaced.

  ## Declared settings (the registry)

  A *definition* is a plain map (see `define/3`) describing a key, its input type, default, and where
  it shows on the settings page. `load_definitions/0` runs once at boot: it aggregates definitions
  from three sources, caches them in `:persistent_term`, and seeds any missing default into the store.

    1. **Core** — `core_definitions/0` below.
    2. **Extensions** — modules listed in `config :mishka_cms, :settings_providers`, each exporting a
       `definitions/0` returning a list of `define/3` maps:

           # config/config.exs
           config :mishka_cms, :settings_providers, [MishkaBlog.Settings]

           defmodule MishkaBlog.Settings do
             def definitions do
               [MishkaCmsCore.Settings.define("blog.posts_per_page", :integer,
                  default: 10, category: "blog", source: :extension, label: "Posts per page")]
             end
           end

    3. **Runtime plugins** — anything answering the `settings:register` mishka_installer hook
       (`Hook.call("settings:register", %{definitions: [...]})`).

  ## Secrets

  A `:secret` setting (a provider's API key) is stored sealed with the endpoint's
  `secret_key_base` (`Phoenix.Token.encrypt/4`), so the row, the cache, the `"setting:updated"`
  broadcast and the `cms_core:setting:after_*` plugin hooks carry only the sealed text. `get/3` hands
  back that sealed text; `secret/2` opens it, and `secret_hint/2` gives the last four characters for
  the settings page, which never draws a stored secret into a field. Rotating `secret_key_base`
  makes stored secrets unreadable, and they are entered again.

  See `MishkaCmsCore.Runtime.Setting` and `MishkaCmsCore.Runtime.States.SettingsState`.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.Setting
  alias MishkaCmsCore.Runtime.States.SettingsState

  @definitions_key {__MODULE__, :definitions}

  # The keys the page builder writes for itself, which no definition names, and the names that
  # write them: any that opens a builder.
  @builder_key_prefixes ["studio.", "builder:preset:"]
  @builder_key_permissions [
    "admin:dashboard:runtime:page",
    "admin:dashboard:runtime:layout",
    "admin:dashboard:runtime:component",
    "admin:dashboard:runtime:error_page",
    "admin:dashboard:code"
  ]

  @definition_defaults %{
    default: nil,
    label: nil,
    description: nil,
    category: "general",
    group: nil,
    source: :core,
    scope: :global,
    editable?: true,
    options: [],
    min: nil,
    max: nil,
    attention_on_default: false,
    permission: nil,
    validate: nil,
    resolve: :override,
    global_label: nil,
    visible: true
  }

  @type input_type :: :string | :text | :boolean | :integer | :select | :list | :secret
  @type scope :: :global | :site | :both | :master | :user
  @type definition :: %{
          key: String.t(),
          type: input_type(),
          default: term(),
          label: String.t() | nil,
          description: String.t() | nil,
          category: String.t(),
          group: String.t() | nil,
          source: :core | :extension | :plugin,
          scope: scope(),
          editable?: boolean(),
          options: [String.t()],
          min: integer() | nil,
          max: integer() | nil,
          attention_on_default: boolean(),
          permission: AccessPermissions.requirement() | [AccessPermissions.requirement()] | nil,
          validate: (term() -> boolean()) | nil,
          resolve: :override | :any | :own,
          global_label: String.t() | nil,
          visible: boolean() | (map() -> boolean())
        }

  @doc """
  Read a setting's scalar value from the RAM cache, or `default` if unset. With a `site_id` the read
  resolves the site's override first, then the global value, then `default`.
  """
  @spec get(String.t(), term(), term()) :: term()
  def get(key, default \\ nil, site_id \\ nil) do
    case SettingsState.get(site_id, key, :__unset__) do
      :__unset__ -> default
      %{"value" => value} -> value
      other -> other
    end
  end

  @doc """
  A site's own value for a setting, or `default` when the site holds none. Unlike `get/3` it never
  falls back to the global value — it is what the site itself set. `nil` for the site is the
  installation's own value: the global one.
  """
  @spec get_own(String.t(), term(), String.t() | nil) :: term()
  def get_own(key, default, nil), do: get(key, default)

  def get_own(key, default, site_id) when is_binary(site_id) do
    case SettingsState.get_own(site_id, key, :__unset__) do
      :__unset__ -> default
      %{"value" => value} -> value
      other -> other
    end
  end

  @doc """
  A setting's value for `site_id` the way its definition resolves it: the scope's own value for
  `resolve: :own` (see `get_own/3`), else `get/3`'s site → global → default.
  """
  @spec resolved(String.t(), term(), String.t() | nil) :: term()
  def resolved(key, default, site_id) do
    case definition(key) do
      %{resolve: :own} -> get_own(key, default, site_id)
      _other -> get(key, default, site_id)
    end
  end

  @doc """
  A `:secret` setting opened for `site_id`, resolved like `resolved/3`; `nil` when none is stored or
  it cannot be opened. See "Secrets" above.
  """
  @spec secret(String.t(), String.t() | nil) :: String.t() | nil
  def secret(key, site_id) do
    case resolved(key, nil, site_id) do
      sealed when is_binary(sealed) and sealed != "" -> unseal(sealed)
      _none -> nil
    end
  end

  @doc """
  What the settings page may say about a stored `:secret` for `site_id`: its last four characters;
  `:unreadable` when one is stored but was sealed under another `SECRET_KEY_BASE` — the server's key
  changed since — so it must be typed again; `nil` when none is stored.
  """
  @spec secret_hint(String.t(), String.t() | nil) :: String.t() | :unreadable | nil
  def secret_hint(key, site_id) do
    case resolved(key, nil, site_id) do
      sealed when is_binary(sealed) and sealed != "" ->
        case unseal(sealed) do
          nil -> :unreadable
          value -> String.slice(value, -4, 4)
        end

      _none ->
        nil
    end
  end

  @secret_salt "mishka settings secret"

  defp seal(value) when is_binary(value) and value != "",
    do: Phoenix.Token.encrypt(endpoint(), @secret_salt, value)

  defp seal(_blank), do: nil

  defp unseal(sealed) do
    case Phoenix.Token.decrypt(endpoint(), @secret_salt, sealed, max_age: :infinity) do
      {:ok, value} when is_binary(value) -> value
      _unreadable -> nil
    end
  end

  defp endpoint, do: Application.fetch_env!(:mishka_cms_core, :endpoint)

  @doc """
  Creates or updates a setting (durable), refreshes the RAM cache from the committed row, and notifies
  plugins via the `cms_core:setting:after_master_set` hook. Options: `:site_id` (default `nil` ⇒
  global; a uuid ⇒ that site's override), `:category` (default `"general"`), `:source`
  (`:core` | `:extension` | `:plugin`, default `:core`), `:description`, `:editable?` (default
  `true`). Returns `{:ok, value}` or `{:error, changeset}`.
  """
  @spec put(String.t(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def put(key, value, opts \\ []) do
    params = params(key, value, opts, Keyword.get(opts, :site_id))

    Setting
    |> Ash.Changeset.for_create(:master_set, params, authorize?: false)
    |> commit(value)
  end

  @doc """
  Writes a setting **as a user**, through the resource's own tenant/master action with the actor
  attached and authorization ON — the path every admin-facing editor takes. `put/3` stays the
  trusted infra path (boot seeding, plugin registration) and deliberately skips all three of
  authorization, multitenancy and the master check; this one skips none of them.

  A master (`site_id` nil) writes the global row or any site's, via `:master_set`. A tenant writes
  its own site's row via `:set`, and naming a different site is refused by the resource's policies
  rather than clamped here — the caller finds out it asked for something it may not have, instead
  of quietly getting something else. `opts` are `put/3`'s, where `:site_id` names the target row
  (a tenant omitting it means its own site).

  Returns `{:ok, value}` or `{:error, reason}`; anything without a `:site_id` key — `nil` included —
  is `{:error, :no_actor}`, never a silent write.
  """
  @spec put_as(map(), String.t(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def put_as(actor, key, value, opts \\ [])

  def put_as(%{site_id: nil} = actor, key, value, opts) do
    params = params(key, value, opts, Keyword.get(opts, :site_id))

    Setting
    |> Ash.Changeset.for_create(:master_set, params, actor: actor, tenant: nil)
    |> commit(value)
  end

  def put_as(%{site_id: actor_site} = actor, key, value, opts) do
    Setting
    |> Ash.Changeset.for_create(:set, params(key, value, opts, :omit),
      actor: actor,
      tenant: Keyword.get(opts, :site_id) || actor_site
    )
    |> commit(value)
  end

  def put_as(_actor, _key, _value, _opts), do: {:error, :no_actor}

  defp params(key, value, opts, site_id) do
    %{
      key: key,
      value: %{"value" => stored(definition(key), value)},
      category: Keyword.get(opts, :category, "general"),
      source: Keyword.get(opts, :source, :core),
      description: Keyword.get(opts, :description),
      editable?: Keyword.get(opts, :editable?, true)
    }
    |> then(&if site_id == :omit, do: &1, else: Map.put(&1, :site_id, site_id))
  end

  defp stored(%{type: :secret}, value), do: seal(value)
  defp stored(_definition, value), do: value

  defp commit(changeset, value) do
    changeset
    |> Ash.create(return_notifications?: true)
    |> case do
      {:ok, setting, notifications} ->
        SettingsState.refresh_key(setting.site_id, setting.key)
        Ash.Notifier.notify(notifications)
        {:ok, value}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Read a PER-USER preference (`:user` scope) — a value only that user sees, stored under a
  user-namespaced key so it never touches the site/global value. `default` when unset.
  """
  @spec get_user(String.t(), term(), term()) :: term()
  def get_user(key, user_id, default \\ nil), do: get(user_key(key, user_id), default)

  @doc "Write a per-user preference (see `get_user/3`). Returns `{:ok, value}` | `{:error, changeset}`."
  @spec put_user(String.t(), term(), term()) :: {:ok, term()} | {:error, term()}
  def put_user(key, value, user_id),
    do: put(user_key(key, user_id), value, category: "preferences", source: :core)

  defp user_key(key, user_id), do: "#{key}::u::#{user_id}"

  @doc """
  Whether `user` may see something that declares a `:permission` — a setting definition, or anything
  else carrying the field, such as a dashboard widget's descriptor.

  One entry or a list of them, where holding ANY is enough — a name, or `{:under, prefix}` for
  anyone holding anything under `prefix` (`MishkaCmsCore.Accounts.Checks.AccessPermissions`). `nil`
  and `[]` gate nothing and mean everyone who got this far. Nobody (a `nil` user) is never
  permitted, whatever is declared — an absent user is not an anonymous one with open access.
  """
  @spec permitted?(map(), map() | nil) :: boolean()
  def permitted?(%{permission: permission}, user) do
    case List.wrap(permission) do
      [] -> !is_nil(user)
      required -> AccessPermissions.match?(user, %{}, permissions: required)
    end
  end

  def permitted?(_declaration, user), do: !is_nil(user)

  @doc """
  What writing a setting takes, as a list where holding ANY entry is enough: the `:permission` its
  definition declares, or `admin:dashboard:setting` when it declares none. Takes a definition, or a
  key. A key no definition names takes `admin:dashboard:setting` too, except the builder's own —
  its Studio switches (`studio.*`) and component presets (`builder:preset:*`) — which take any name
  that opens a builder: a runtime area of a document the builder edits, or `admin:dashboard:code`.

      Settings.write_permission("site.title")          #=> ["admin:dashboard:setting"]
      Settings.write_permission("studio.lock_tokens")  #=> ["admin:dashboard:runtime:page", …]
  """
  @spec write_permission(definition() | String.t() | nil) :: [AccessPermissions.requirement()]
  def write_permission(%{permission: permission}) when permission not in [nil, []],
    do: List.wrap(permission)

  def write_permission(%{}), do: ["admin:dashboard:setting"]

  def write_permission(key) when is_binary(key) do
    case {definition(key), builder_key?(key)} do
      {nil, true} -> @builder_key_permissions
      {nil, false} -> write_permission(%{})
      {definition, _builder?} -> write_permission(definition)
    end
  end

  def write_permission(_no_key), do: write_permission(%{})

  defp builder_key?(key), do: Enum.any?(@builder_key_prefixes, &String.starts_with?(key, &1))

  @doc """
  Whether `user` may write the setting `definition` declares (`write_permission/1`). A definition of
  `scope: :user` is the user's own preference, and is theirs to write whenever they may see it
  (`permitted?/2`).
  """
  @spec writable?(definition(), map() | nil) :: boolean()
  def writable?(%{scope: :user} = definition, user), do: permitted?(definition, user)

  def writable?(definition, user),
    do: AccessPermissions.match?(user, %{}, permissions: write_permission(definition))

  @doc """
  Coerces a submitted value against the definition that declared it — the one gate both editors go
  through, so a number typed on the settings page and the same number picked in a dashboard card's
  gear are bounded identically.

  `:integer` parses and clamps to the definition's `:min`/`:max`; `:boolean` reads the form's
  `"on"`/`"true"` (and a missing checkbox as `false`); `:select` must name one of the declared
  `:options`, given either as bare values or `{label, value}` pairs; `:string`/`:text` take any
  binary; `:list` takes a list of strings or the comma-separated text the settings page sends, each
  entry trimmed and blanks and repeats dropped. Anything else — an unparsable number, a value off a
  select's list, a list holding something other than strings, an unknown type — is `:error`, and so
  is a value of the right type that the definition's `:validate` answers `false` for. Nothing is
  coerced to a silent zero or nil: a value that cannot be trusted is refused and the caller decides
  what to tell the admin.
  """
  @spec cast(definition() | map(), term()) :: {:ok, term()} | :error
  def cast(definition, value) do
    with {:ok, cast} <- cast_type(definition, value),
         do: validated(definition, cast)
  end

  defp validated(%{validate: validate}, value) when is_function(validate, 1) do
    case validate.(value) do
      true -> {:ok, value}
      _refused -> :error
    end
  end

  defp validated(_definition, value), do: {:ok, value}

  defp cast_type(%{type: :integer} = definition, value) do
    case to_integer(value) do
      {:ok, number} -> {:ok, clamp(number, Map.get(definition, :min), Map.get(definition, :max))}
      :error -> :error
    end
  end

  defp cast_type(%{type: :boolean}, value), do: {:ok, value in [true, "true", "on"]}

  defp cast_type(%{type: :select} = definition, value)
       when is_binary(value) or is_atom(value) or is_number(value) do
    definition
    |> options()
    |> Enum.find_value(:error, &(to_string(&1) == to_string(value) and {:ok, &1}))
  end

  defp cast_type(%{type: type}, value) when type in [:string, :text] and is_binary(value),
    do: {:ok, value}

  defp cast_type(%{type: :secret}, value) when is_binary(value), do: {:ok, String.trim(value)}

  defp cast_type(%{type: :list}, value) when is_binary(value),
    do: cast_type(%{type: :list}, String.split(value, ","))

  defp cast_type(%{type: :list}, value) when is_list(value) do
    case Enum.all?(value, &is_binary/1) do
      true -> {:ok, value |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()}
      false -> :error
    end
  end

  defp cast_type(_definition, _value), do: :error

  defp to_integer(value) when is_integer(value), do: {:ok, value}

  defp to_integer(value) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {number, ""} -> {:ok, number}
      _other -> :error
    end
  end

  defp to_integer(_value), do: :error

  defp clamp(number, min, _max) when is_integer(min) and number < min, do: min
  defp clamp(number, _min, max) when is_integer(max) and number > max, do: max
  defp clamp(number, _min, _max), do: number

  defp options(%{options: options}) when is_list(options) do
    Enum.map(options, fn
      {_label, value} -> value
      value -> value
    end)
  end

  defp options(_definition), do: []

  @doc "All GLOBAL settings as `%{key => scalar_value}` (from the RAM cache) — used for default seeding."
  @spec all_global() :: %{optional(String.t()) => term()}
  def all_global do
    SettingsState.all_global()
    |> Map.new(fn
      {key, %{"value" => value}} -> {key, value}
      {key, value} -> {key, value}
    end)
  end

  @doc """
  Builds a setting definition map. `opts`: `:default`, `:label`, `:description`, `:category`
  (default `"general"`, the settings-page TAB — usually the owning area/extension), `:group`
  (an optional sub-section HEADING within the tab, e.g. `"Notifications"`; nil = no heading),
  `:source` (`:core` | `:extension` | `:plugin`, default `:core`), `:scope`
  (`:global` one value for all sites, read-only to tenants | `:site` each tenant owns its own |
  `:both` a global default a site may override | `:master` global AND master-only, hidden from
  tenants; default `:global`), `:editable?` (default `true`), `:options` (choices for a `:select`),
  `:attention_on_default` (default `false`) — set it when the default is only a placeholder an admin
  is expected to replace, and the settings page marks the tab with a red dot until they do —
  `:permission` (default `nil` = `admin:dashboard:setting`; one name or a list of them, where
  holding ANY is enough) — what writing the setting takes, and who sees it on the settings page, e.g.
  `"admin:dashboard:setting:deploy"`. A `:user` setting is seen by whoever holds its `:permission`
  (everyone when `nil`) and written by its user alone. A tab whose every setting is gated away
  disappears with them — and
  `:validate` (default `nil`), a one-argument function answering whether a value `cast/2` has
  already typed may be stored, for a rule the type alone does not hold: `site.languages` is a list of
  strings, and only language codes — `:resolve` (default `:override`, a site's value replaces the
  global one), set to `:any` for a boolean whose global and site values are OR-ed, as `cms.offline`'s
  are: a site's view then shows the site's own value and says when the global one holds it on, or
  `:own` for a value each scope sets for itself and never takes from the global one, as a site's
  email provider and its key are (read it with `resolved/3`) — and
  `:global_label` (default `nil`, the `:label` everywhere), the label in the Global view when it reads
  differently there — and `:visible` (default `true`), or `fn values -> boolean end` over the tab's
  values as the admin has them on screen (key → value, typed or saved), for a field that only means
  something beside another one's choice: a provider's keys while that provider is chosen. The
  settings page draws and saves it only while it holds; see `visible?/2` and `shown_when/3`.
  """
  @spec define(String.t(), input_type(), keyword()) :: definition()
  def define(key, type, opts \\ []) do
    @definition_defaults
    |> Map.merge(Map.new(opts))
    |> Map.merge(%{key: key, type: type})
  end

  @doc """
  Whether `definition` shows beside the tab's `values` (key → value): its `:visible`, `true` by
  default.
  """
  @spec visible?(definition() | map(), map()) :: boolean()
  def visible?(%{visible: visible}, values) when is_function(visible, 1),
    do: visible.(values) == true

  def visible?(%{visible: false}, _values), do: false
  def visible?(_definition, _values), do: true

  @doc """
  `definition`, shown only while the setting `key` holds `value` — and while its own `:visible`
  holds. How a provider's fields follow the provider select: each provider's settings pass through
  it, so no provider has to say so itself.

      Settings.shown_when(definition, "mailer.provider", "resend")
  """
  @spec shown_when(definition(), String.t(), term()) :: definition()
  def shown_when(definition, key, value) do
    own = Map.get(definition, :visible, true)
    Map.put(definition, :visible, &(&1[key] == value and visible?(%{visible: own}, &1)))
  end

  @doc """
  Aggregates every definition (core + config providers + the `settings:register` hook), caches them in
  `:persistent_term`, and seeds any missing default into the store. Run once at boot; returns the
  definitions.
  """
  @spec load_definitions() :: [definition()]
  def load_definitions do
    declared = core_definitions() ++ provider_definitions() ++ plugin_definitions()
    index = Map.new(declared, &{&1.key, &1})

    ordered =
      declared
      |> Enum.map(& &1.key)
      |> Enum.uniq()
      |> Enum.map(&Map.fetch!(index, &1))

    :persistent_term.put(@definitions_key, {index, ordered})
    seed_defaults(ordered)
    ordered
  end

  @doc """
  All registered definitions, in the order they were declared — core first, then config providers,
  then runtime plugins, each key keeping the position it was first declared at while a later
  redeclaration of the same key still wins on content.

  The order is the settings page's tab order, and `handle_params` falls back to the FIRST category
  when no tab is named, so it has to be stable. It was not: the registry was a plain map and this
  returned `Map.values/1`, so both the tab order and which tab opened by default were map iteration
  order — stable only by luck, and reshuffling as soon as enough definitions were registered.
  """
  @spec definitions() :: [definition()]
  def definitions, do: elem(store(), 1)

  @doc """
  A definition's `:label`, `:description`, `:group`, `:global_label` or option label, in the reader's
  language.

  Definitions are cached at boot, before anybody's language is known, so each holds its English
  words marked with `gettext_noop/1`, and the settings page translates them as it draws them. A text
  built from another is `{msgid, bindings}`, each binding translated in turn:

      Settings.text(gettext_noop("Theme"))                                   #=> "پوسته"
      Settings.text({gettext_noop("%{label} — position"), label: "Blog"})    #=> "وبلاگ — جایگاه"
  """
  @spec text(String.t() | {String.t(), keyword() | map()} | nil) :: String.t() | nil
  def text(nil), do: nil
  def text(msgid) when is_binary(msgid), do: Gettext.gettext(MishkaCmsCore.Gettext, msgid)

  def text({msgid, bindings}) when is_binary(msgid) do
    Gettext.gettext(
      MishkaCmsCore.Gettext,
      msgid,
      Map.new(bindings, fn {k, v} -> {k, text(v)} end)
    )
  end

  @doc "Registered definitions in a category (a settings-page tab)."
  @spec definitions(String.t()) :: [definition()]
  def definitions(category), do: Enum.filter(definitions(), &(&1.category == category))

  @doc "The registered definition for a key, or `nil`."
  @spec definition(String.t()) :: definition() | nil
  def definition(key), do: store() |> elem(0) |> Map.get(key)

  @doc "The distinct categories, in first-seen order (the settings-page tabs)."
  @spec categories() :: [String.t()]
  def categories, do: definitions() |> Enum.map(& &1.category) |> Enum.uniq()

  defp core_definitions do
    [
      define("site.title", :string,
        default: "MishkaCMS",
        category: "general",
        scope: :both,
        label: gettext_noop("Site title"),
        description: gettext_noop("Shown in the browser tab and anywhere the site names itself.")
      ),
      define("site.languages", :list,
        default: MishkaCmsCore.Runtime.Languages.default(),
        validate: &MishkaCmsCore.Runtime.Languages.valid?/1,
        category: "general",
        scope: :both,
        label: gettext_noop("Languages"),
        description:
          gettext_noop(
            "The languages this site publishes in, as codes separated by commas — en, fa, ar. A page path's :lang segment answers only these. Only languages the master allows can be saved, and the ones the master requires are always included."
          )
      ),
      define("site.allowed_languages", :list,
        default: [],
        validate: &MishkaCmsCore.Runtime.Languages.codes_or_empty?/1,
        category: "general",
        scope: :master,
        label: gettext_noop("Languages sites may publish"),
        description:
          gettext_noop(
            "Codes separated by commas. Leave empty to let every site publish any language; otherwise a site can only list these, and one it lists outside them is not published."
          )
      ),
      define("site.required_languages", :list,
        default: [],
        validate: &MishkaCmsCore.Runtime.Languages.codes_or_empty?/1,
        category: "general",
        scope: :master,
        label: gettext_noop("Languages every site publishes"),
        description:
          gettext_noop(
            "Codes separated by commas. Every site publishes these, whether it lists them or not. Leave empty to require none."
          )
      )
    ] ++ email_definitions()
  end

  # THE EMAIL TAB. Which provider a scope sends through and that provider's own fields come from
  # `MishkaCmsCore.Mail.settings/0` — the registered provider plugins — and the sender is the
  # scope's own, like the provider: a site never sends as another one.
  defp email_definitions do
    [provider | provider_fields] = MishkaCmsCore.Mail.settings()

    [
      provider,
      define("mailer.from", :string,
        default: "",
        category: "email",
        group: gettext_noop("Sender"),
        scope: :both,
        resolve: :own,
        label: gettext_noop("Outgoing email \"from\" address"),
        description:
          gettext_noop(
            "Every email this site sends comes from this address, on a domain its provider has verified. Empty sends from noreply@ the site's own domain."
          ),
        attention_on_default: true
      ),
      define("mailer.from_name", :string,
        default: "",
        category: "email",
        group: gettext_noop("Sender"),
        scope: :both,
        resolve: :own,
        label: gettext_noop("Sender name"),
        description:
          gettext_noop("The name shown beside the address. Empty means the site's title.")
      ),
      define("mailer.reply_to", :string,
        default: "",
        category: "email",
        group: gettext_noop("Sender"),
        scope: :both,
        resolve: :own,
        label: gettext_noop("Reply-to address"),
        description:
          gettext_noop("Where a reply goes when it should not go to the from address. Optional.")
      )
    ] ++
      provider_fields ++
      [
        define("mailer.history_days", :integer,
          default: 30,
          min: 1,
          max: 365,
          category: "email",
          group: gettext_noop("History"),
          scope: :master,
          label: gettext_noop("Keep the email history for (days)"),
          description:
            gettext_noop("A site's older entries are deleted when it next sends an email.")
        )
      ]
  end

  defp provider_definitions do
    Application.get_env(:mishka_cms_core, :settings_providers, [])
    |> Enum.filter(&Code.ensure_loaded?/1)
    |> Enum.flat_map(& &1.definitions())
  end

  defp plugin_definitions do
    case MishkaInstaller.Event.Hook.call("settings:register", %{definitions: []}) do
      %{definitions: definitions} when is_list(definitions) -> definitions
      _ -> []
    end
  end

  defp seed_defaults(definitions) do
    existing = all_global()

    definitions
    |> Enum.filter(&(&1.scope in [:global, :both, :master]))
    |> Enum.each(fn definition ->
      if !Map.has_key?(existing, definition.key) do
        put(definition.key, definition.default,
          category: definition.category,
          source: definition.source,
          description: definition.description,
          editable?: definition.editable?
        )
      end
    end)
  end

  defp store, do: :persistent_term.get(@definitions_key, {%{}, []})
end
