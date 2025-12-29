defmodule MishkaCmsCore.Builder.Events do
  @moduledoc """
  The page builder's plugin surface — every section of the editor is a `MishkaInstaller` hook, and
  the core ships as the seeded first participant of its own events (ADR-14).

  Extending the editor means registering a plugin, not patching core. A blog extension adds a
  "Post binding" inspector section, a brand-lint plugin adds an audit check, an agency adds a Studio
  tab — all through the same events the core itself uses, which is what keeps those seams honest:
  if a core section can be expressed as a contribution, an extension's can too.

  ## The three shapes, following the conventions already in this codebase

    * **Registries** are accumulators. The payload carries a seeded list a plugin appends to — never
      `[]`, always the core set first — and `Enum.uniq_by/2` keeps the first declaration, so a plugin
      can add but never silently redefine a core entry. Precedent: `sidebar:menus`.
    * **Transforms** pass the value itself and honour the return, so a plugin can rewrite or veto.
      Precedent: `runtime:compile:css`.
    * **Announcements** pass a summary map with `return: false`. Precedent: `runtime:site:after_purge`.

  ## Catalog

  Every row below has a call site. A documented event with nothing firing it is worse than no event
  at all — the author writes the plugin, registers it, and watches nothing happen — so this table and
  `registries/0` are kept in step with the code, and an event that loses its last caller is removed.

  ### Registries — the seeded list a plugin appends to

  | Event | Payload | Fired from |
  |---|---|---|
  | `builder:components` | `%{entries: [PaletteEntry]}` | the Components palette |
  | `builder:blocks` | `%{blocks: [Block]}` | the Blocks palette |
  | `builder:elements` | `%{elements: [Element]}` | the Elements palette |
  | `builder:inspector:sections` | `%{sections: [Section]}` | the Inspector |
  | `builder:rails` | `%{tabs: [Tab]}` | the right-hand rail |
  | `builder:studio:tabs` | `%{tabs: [Tab]}` | Studio |
  | `builder:canvas:toolbar` | `%{actions: [Action]}` | the canvas toolbar — pressed, it announces `builder:canvas:toolbar:invoked` |
  | `builder:commands` | `%{commands: [Command]}` | the command palette |
  | `builder:audit:checks` | `%{checks: [Check]}` | the Audit rail |
  | `builder:page_starters` | `%{structures: [Starter]}` | the empty-page picker |
  | `builder:icon:libraries` | `%{libraries: [Library]}` | the icon picker |
  | `builder:interactions` | `%{actions: [Action]}` | the Interactions section — see `MishkaCmsCore.Builder.Action` |
  | `builder:conditions` | `%{rules: [Rule]}` | the Show-when section — see `MishkaCmsCore.Runtime.PageBuilder.Conditions` |
  | `builder:js_hooks` | `%{hooks: [Hook]}` | the hook picker |
  | `builder:mention:sources` | `%{sources: [Source]}` | @-mentions in review notes |

  ### Transforms — the value itself, and the return is honoured

  | Event | Payload |
  |---|---|
  | `builder:node:before_<op>` | the validated `Op` + `meta` |
  | `builder:save:before` / `builder:publish:before` | `%{tree, serialized, resource_id, section}` |
  | `builder:serialize` | the serialized HEEx string |
  | `builder:tree:render` | `%{tree, record}` |
  | `builder:history:query` | `%{query, source_type, source_id, branch_id}` |
  | `builder:containment` | `%{allowed?, reason, parent, child, tree, components}` |
  | `builder:preview:document` | `%{html, resource, record_id, site_id, note}` |
  | `builder:examples` | `%{examples, entry, site_id}` |
  | `builder:preset:choices` | `%{choices, site_id}` |
  | `builder:token:before_set` | `%{value, token, scope, error}` |
  | `builder:ai:before_ask` | `%{prompt, section, node_id, error}` |
  | `builder:form:role` | `%{role, entry}` |
  | `page:form:submitted` | `%{form, values, page, site_id, handled}` |

  `builder:form:role` carries a component's INFERRED part in a form (`:wrapper`, `:field`,
  `:submit`, `:none`, …) and the palette entry it was read from; answer another role to change it.
  A kit's own `extra.form` declaration never passes through it. See `form_role/2`.

  `page:form:submitted` is the one row here that fires from a published page rather than from the
  editor, and the one whose plugins WRITE. A plugin that stored the submission answers with
  `handled: true`, and a page reads that to tell a form with a destination from one whose values
  reached nobody. It is declared here so the editor's Forms audit group and the runtime read one
  catalog; `form_destination?/0` answers by reading the registration rather than by sending the seam
  a made-up payload to see what happens to it.

  ### Gates — `{:error, message}` refuses, and the editor says so

  | Event | Payload |
  |---|---|
  | `builder:draft:before_save` | `%{section, resource_id, site_id, actor_id, error}` |
  | `builder:review:before_comment` | `%{body, type, section, node_id, parent_comment_id, error}` |
  | `builder:code:before_apply` | `%{source, section, resource_id, site_id, actor_id, error}` |
  | `builder:class:before_save` | `%{name, css, site_id, error}` |
  | `builder:element_css:before_save` | `%{node_id, css, owner, site_id, error}` |

  ### Announcements — `return: false`, nothing waits on them

  | Event | Payload |
  |---|---|
  | `builder:session:after_open` / `after_close` | `%{token, section, resource_id, site_id, actor_id}` |
  | `builder:node:after_<op>` | `%{op, node_id, parent_id}` |
  | `builder:save:after` / `builder:publish:after` | `%{record_id, section, stage}` |
  | `builder:draft:after_save` | `%{section, resource_id, site_id, actor_id}` |
  | `builder:review:after_comment` | `%{id, body, type, node_id, reply?, section, source_id, site_id, actor_id}` |
  | `builder:element_css:after_save` | `%{node_id, css, owner, site_id, actor_id, stage}` |
  | `builder:canvas:toolbar:invoked` | `%{action, node_id, token}` |
  | `builder:form:after_rename` | `%{node_id, from, to, token, change, submit, section, resource_id, site_id, actor_id}` |
  | `builder:form:after_customize` | `%{node_id, event, kind, section, resource_id, site_id, actor_id}` |
  | `builder:form:after_create` | `%{node_id, seed, token, how, section, resource_id, site_id, actor_id}` |
  | `builder:form:after_setting` | `%{node_id, seed, setting, value, section, resource_id, site_id, actor_id}` |

  `builder:canvas:toolbar:invoked` is the half of the toolbar registry that makes the button do
  something. A descriptor's `run` is read by `builder:interactions` alone, so a toolbar entry has no
  dispatch of its own; pressing one announces here instead, with the element it was pressed on and
  the session token the plugin applies its own ops through. See `toolbar_invoked/1`.

  `builder:interactions` is the one to read first if you are adding a feature rather than a list
  entry, because it is the registry that had to grow from a list into a contract:
  `MishkaCmsCore.Builder.Action` is what an action's `run` module implements, and it is the shape to
  copy — the entry says what boxes the panel should draw for it, whether it runs on the client or
  the server, what it writes into the document and how to read that back.

  A plugin registers exactly as the dashboard widgets do:

      use MishkaInstaller.Event.Hook, event: "builder:audit:checks", initial: %{priority: 50}

      def call(%{checks: checks} = payload) do
        {:reply, %{payload | checks: checks ++ [MyCheck.descriptor()]}}
      end
  """

  require Logger
  require MishkaCmsCore.Runtime.PageBuilder.Strict

  alias MishkaCmsCore.Runtime.PageBuilder.Strict

  alias MishkaCmsCore.Builder.Descriptor

  alias MishkaInstaller.Event.ModuleStateCompiler

  @form_submitted "page:form:submitted"

  @form_roles [:none | Enum.map(MishkaCmsCore.Builder.FormRole.roles(), &String.to_atom/1)]

  @registries %{
    components: {"builder:components", :entries},
    blocks: {"builder:blocks", :blocks},
    elements: {"builder:elements", :elements},
    inspector_sections: {"builder:inspector:sections", :sections},
    rails: {"builder:rails", :tabs},
    studio_tabs: {"builder:studio:tabs", :tabs},
    canvas_toolbar: {"builder:canvas:toolbar", :actions},
    commands: {"builder:commands", :commands},
    audit_checks: {"builder:audit:checks", :checks},
    page_starters: {"builder:page_starters", :structures},
    icon_libraries: {"builder:icon:libraries", :libraries},
    interactions: {"builder:interactions", :actions},
    conditions: {"builder:conditions", :rules},
    js_hooks: {"builder:js_hooks", :hooks},
    mention_sources: {"builder:mention:sources", :sources}
  }

  @doc "Every registry event name the builder exposes, for documentation and tests."
  @spec registries() :: %{atom() => {String.t(), atom()}}
  def registries, do: @registries

  @doc """
  Collects a registry: fires its event with `seed` already in the payload and returns the resulting
  list, de-duplicated by `key` and sorted by `priority`.

  The core's own entry wins a collision, whichever way the plugin assembled its answer — see
  `kept/4`, which is where that stopped being a convention and became a rule.

  A plugin that returns something unusable leaves the seed untouched rather than emptying the
  editor — a broken extension must not be able to take a rail or the palette down.
  """
  @spec collect(atom(), list()) :: list()
  def collect(registry, seed) when is_map_key(@registries, registry) do
    {event, key} = Map.fetch!(@registries, registry)

    event
    |> MishkaInstaller.Event.Hook.call(Map.put(%{}, key, seed))
    |> contributed(key, seed, event)
    |> kept(seed, event, &Descriptor.key/1)
    |> Enum.sort_by(&{Descriptor.priority(&1), Descriptor.key(&1)})
  end

  # THE SEED GOES BACK IN FRONT BEFORE ANYTHING IS DROPPED.
  #
  # "A plugin can add but never silently redefine a core entry" is what every registry here promises,
  # and it was only true of plugins that append. The payload goes out with the seed in it and comes
  # back as whatever the plugin returned, and `uniq_by` keeps the FIRST — so a plugin that returns
  # its own entries AHEAD of the seed replaces a core entry under a core key, keeping its label.
  # Harmless-looking for a palette card. Not harmless for an interaction, where the entry carries the
  # module a published page calls: a contribution keyed `say` would have put its own module into the
  # `handle_event` compiled into every page an author had already built with core's Show a message.
  #
  # Prepending the seed costs one concatenation and makes the sentence in the moduledoc true for
  # every registry at once, whichever way a plugin assembles its answer. The collision is logged
  # rather than swallowed, because the accidental version — an author reusing a core key to sort
  # themselves first — is otherwise impossible to diagnose.
  defp kept(contributed, seed, event, key_of) do
    taken = MapSet.new(seed, key_of)

    for entry <- contributed, MapSet.member?(taken, key_of.(entry)), not seeded?(seed, entry) do
      Logger.warning(
        "[Builder] #{event} contributed #{inspect(key_of.(entry))}, which the core already " <>
          "defines — the core entry is the one used"
      )
    end

    seed |> Enum.concat(contributed) |> Enum.uniq_by(key_of)
  end

  defp seeded?(seed, entry), do: Enum.any?(seed, &(&1 == entry))

  # MATCHED, NOT REACHED INTO. This did `Map.get(payload, key)`, and a plugin that answered with
  # anything but a map — a list, a bare atom, a string — took that call down with a `BadMapError`
  # and the editor's rail, palette or command list with it. The convention every other caller in
  # this codebase already follows is to match the shape and fall back to the seed, which is the
  # difference between a broken extension being inert and a broken extension white-screening the
  # editor.
  defp contributed(%{} = payload, key, seed, event) do
    case Map.get(payload, key) do
      list when is_list(list) ->
        list

      other ->
        Strict.violation!(
          "Builder.Events.collect/2",
          "#{event} answered #{inspect(other)} under :#{key}, expected a list"
        )

        seed
    end
  end

  defp contributed(other, _key, seed, event) do
    Strict.violation!(
      "Builder.Events.collect/2",
      "#{event} answered #{inspect(other)}, which is not a payload map"
    )

    seed
  end

  @doc """
  Collects a registry whose ORDER IS THE POINT, appending what plugins contribute to the end.

  The shape above covers a registry of descriptors, where `priority` decides the order and every
  entry carries a `key`. Some of the editor's lists are not that: the Blocks and Elements libraries,
  the page starters and the icon libraries are curated, ordered lists identified by `:id` — or, for
  icon libraries, bare modules. Running those through `collect/2` would sort them by
  `Descriptor.key/1`, which for an entry with no `:key` is `inspect/1` of the whole map: the list
  comes back in alphabetical order of its own inspected contents, silently rearranging a library
  somebody curated.

  So the seed keeps its order and contributions arrive after it, de-duplicated so a plugin can add
  but not silently replace — which `kept/4` enforces rather than trusting. Same event system, same
  `MishkaInstaller.Event.Hook.call/2`; a different promise about order.
  """
  @spec collect_appended(atom(), list()) :: list()
  def collect_appended(registry, seed) when is_map_key(@registries, registry) do
    {event, key} = Map.fetch!(@registries, registry)

    event
    |> MishkaInstaller.Event.Hook.call(Map.put(%{}, key, seed))
    |> contributed(key, seed, event)
    |> kept(seed, event, &entry_id/1)
  end

  # `:id` is what these lists identify their entries by; a module is its own identity.
  defp entry_id(%{id: id}), do: id
  defp entry_id(%{"id" => id}), do: id
  defp entry_id(%{key: key}), do: key
  defp entry_id(other), do: other

  @doc """
  One entry of `collect_appended(registry, seed)` by id, or `nil`. An entry that is not a map is no
  entry — a contribution of the wrong shape stays inert here rather than travelling.

  A PLUGIN'S CARD IS A CARD. The Blocks and Elements palettes and the empty-page chooser draw the
  merged list and are handed an id back by the click, and each resolved it in its core library
  alone — so a card an extension contributed was drawn and then could not be found: the palette
  answered "that element is no longer on the page", and the chooser, which has no error to show,
  said nothing at all. `:interactions` and `:conditions` never had this, because each owns a merged
  `registry/0` and asks THAT; here the core library is the only accessor there is.

  `seed` is the list the caller rendered, because the two passes have to agree. Fired with `[]` the
  payload breaks the promise this module makes to every plugin — "never `[]`, always the core set
  first" — so a plugin written to that promise answers the click differently than it answered the
  render. With the seed in, core's own entries answer here too and the caller needs no second
  lookup, while `kept/4` still gives a shared id to the core. Once per placement, which is a
  gesture, not a keystroke.
  """
  @spec fetch(atom(), list(), term()) :: term() | nil
  def fetch(registry, seed, id) when is_map_key(@registries, registry) do
    registry
    |> collect_appended(seed)
    |> Enum.find(&(is_map(&1) and entry_id(&1) == id))
  end

  @doc """
  Fires a transform event and returns the (possibly rewritten) payload. The plugin's return is
  honoured; anything that is not a map of the same shape is discarded in favour of the original.
  """
  @spec transform(String.t(), map()) :: map()
  def transform(event, payload) when is_map(payload) do
    case MishkaInstaller.Event.Hook.call(event, payload) do
      %{} = returned ->
        returned

      # A PLUGIN THAT RETURNED THE WRONG SHAPE IS INERT, and used to be inert silently — its rewrite
      # discarded, its author with no way to find out except by noticing nothing happened. Production
      # still carries on with the original; development says whose plugin, which event, and what came
      # back instead.
      other ->
        Strict.violation!(
          "Builder.Events.transform/2",
          "#{event} answered #{inspect(other)}, which is not a payload map"
        )

        payload
    end
  end

  @doc """
  Fires a veto-capable gate. A plugin refuses by putting a message under `:error` in the payload it
  returns; anything else lets the action through.
  """
  @spec gate(String.t(), map()) :: :ok | {:error, String.t()}
  def gate(event, payload) do
    case transform(event, payload) do
      %{error: nil} ->
        :ok

      %{error: message} when is_binary(message) ->
        {:error, message}

      # A GATE THAT MEANT TO REFUSE AND ANSWERED THE WRONG SHAPE LETS EVERYTHING THROUGH. This is the
      # seam content lint, broken-link checks and schema validation hang off, so a plugin with a
      # shape bug silently authorises every save and reports nothing.
      other ->
        Strict.violation!(
          "Builder.Events.gate/2",
          "#{event} answered #{inspect(other)}, expected a map carrying :error"
        )

        :ok
    end
  end

  @doc "Fires an announcement. Never blocks and never consults the return."
  @spec announce(String.t(), map(), keyword()) :: :ok
  def announce(event, payload, meta \\ []) do
    MishkaInstaller.Event.Hook.call(event, payload, meta: Map.new(meta), return: false)
    :ok
  end

  @doc "Announces that an editing session opened."
  @spec session_opened(map()) :: :ok
  def session_opened(session) do
    announce("builder:session:after_open", %{
      token: session.token,
      section: session.section,
      resource_id: session.resource_id,
      site_id: session.site_id,
      actor_id: session.actor_id
    })
  end

  @doc "Announces that an editing session closed."
  @spec session_closed(map()) :: :ok
  def session_closed(session) do
    announce("builder:session:after_close", %{
      token: session.token,
      section: session.section,
      resource_id: session.resource_id,
      site_id: session.site_id,
      actor_id: session.actor_id
    })
  end

  @doc """
  The transform seam every node mutation passes through. A plugin may rewrite the op or veto it by
  setting `:error`; the session applies whatever comes back.
  """
  @spec before_node(atom(), map(), map()) :: {:ok, map()} | {:error, String.t()}
  def before_node(kind, op, meta) do
    payload = transform("builder:node:before_#{kind}", %{op: op, meta: meta, error: nil})

    case payload do
      %{error: message} when is_binary(message) ->
        {:error, message}

      %{op: rewritten} ->
        {:ok, rewritten}

      other ->
        Strict.violation!(
          "Builder.Events.before_node/3",
          "builder:node:before_#{kind} answered #{inspect(other)}, expected a map carrying :op"
        )

        {:ok, op}
    end
  end

  @doc "Announces a completed node mutation."
  @spec after_node(atom(), map()) :: :ok
  def after_node(kind, summary), do: announce("builder:node:after_#{kind}", summary)

  # ─ Every other section of the editor, in the three shapes above. Each is a named function rather
  #   than a bare event string so a call site reads as what it is, and so the catalog and the code
  #   cannot drift apart.

  @doc """
  The timeline's read, before it runs.

  A query rather than the loaded rows, deliberately: the sheet pages, and a plugin that dropped rows
  after the read would leave a page of twenty showing twelve with no way to ask for the rest. Scoping
  in SQL keeps the count and the page honest, and costs nothing on a table this size.

  A plugin that answers with anything but a query leaves the read as it was.
  """
  @spec history_query(Ash.Query.t(), map()) :: Ash.Query.t()
  def history_query(query, meta) do
    "builder:history:query"
    |> transform(Map.merge(meta, %{query: query}))
    |> Map.get(:query)
    |> case do
      %Ash.Query{} = scoped -> scoped
      _other -> query
    end
  end

  @doc "Before a draft is written. A plugin refuses by setting `:error`."
  @spec before_draft_save(map()) :: :ok | {:error, String.t()}
  def before_draft_save(payload),
    do: gate("builder:draft:before_save", Map.put_new(payload, :error, nil))

  @doc "After a draft was written."
  @spec after_draft_save(map()) :: :ok
  def after_draft_save(summary), do: announce("builder:draft:after_save", summary)

  @doc "Before a review note is written. A plugin refuses by setting `:error`."
  @spec before_comment(map()) :: :ok | {:error, String.t()}
  def before_comment(payload),
    do: gate("builder:review:before_comment", Map.put_new(payload, :error, nil))

  @doc "After a review note was written."
  @spec after_comment(map()) :: :ok
  def after_comment(summary), do: announce("builder:review:after_comment", summary)

  @doc "Before hand-written source is applied to the document. A plugin refuses by setting `:error`."
  @spec before_code_apply(map()) :: :ok | {:error, String.t()}
  def before_code_apply(payload),
    do: gate("builder:code:before_apply", Map.put_new(payload, :error, nil))

  @doc "Before a design token is set. A plugin may normalise the value or refuse it."
  @spec before_token_set(map()) :: {:ok, term()} | {:error, String.t()}
  def before_token_set(payload) do
    case transform("builder:token:before_set", Map.put_new(payload, :error, nil)) do
      %{error: message} when is_binary(message) -> {:error, message}
      %{value: value} -> {:ok, value}
      _other -> {:ok, payload.value}
    end
  end

  @doc "Before a saved class is written. A plugin refuses by setting `:error`."
  @spec before_class_save(map()) :: :ok | {:error, String.t()}
  def before_class_save(payload),
    do: gate("builder:class:before_save", Map.put_new(payload, :error, nil))

  @doc "Before an element's own CSS is written. A plugin refuses by setting `:error`."
  @spec before_element_css(map()) :: :ok | {:error, String.t()}
  def before_element_css(payload),
    do: gate("builder:element_css:before_save", Map.put_new(payload, :error, nil))

  @doc "After an element's own CSS was written."
  @spec after_element_css(map()) :: :ok
  def after_element_css(summary), do: announce("builder:element_css:after_save", summary)

  @doc """
  A canvas toolbar action a plugin contributed was pressed, on `node_id`, in the session `token`
  names.

  The core's own five are handled where they are — two document ops, two rail openers and the layout
  panel — so nothing of the core's arrives here. Everything else the registry offers does, because a
  toolbar descriptor has no `run` dispatch: the button used to fall through to "duplicate the
  element", which is the one thing no plugin asked for.

  An announcement rather than a transform: the plugin's work IS the effect, and it does that work
  through the token, the same funnel the editor's own ops go down.
  """
  @spec toolbar_invoked(map()) :: :ok
  def toolbar_invoked(summary), do: announce("builder:canvas:toolbar:invoked", summary)

  @doc """
  A form was renamed from the Inspector: `from` and `to` are its seeds, `token` the token its event
  names carry (`nil` for untagged names), `change` and `submit` its new event names.
  """
  @spec form_renamed(map()) :: :ok
  def form_renamed(summary), do: announce("builder:form:after_rename", summary)

  @doc """
  A form's event was customized in the Code window: its default code (`event`, of `kind`
  `:validate` or `:submit`) was added to the Handlers tab, not stored yet.
  """
  @spec form_customized(map()) :: :ok
  def form_customized(summary), do: announce("builder:form:after_customize", summary)

  @doc """
  A form was made in the editor: `how` is `:started` (a field dropped with no form around it),
  `:wired` (a kit form that arrived working), `:moved` (a field moved into a new form) or `:fixed`
  (the audit's Fix made it, or made it work). `seed` and `token` are its name and the token in its
  event names.
  """
  @spec form_created(map()) :: :ok
  def form_created(summary), do: announce("builder:form:after_create", summary)

  @doc """
  A working form's setting was changed from the Inspector's Form panel: `setting` is `:how`
  (`value` `:typing` or `:send`) or `:address` (`value` the web address its answers are sent to
  once checked, `nil` when removed). `seed` is the form's name.
  """
  @spec form_setting(map()) :: :ok
  def form_setting(summary), do: announce("builder:form:after_setting", summary)

  @doc """
  The assembled preview document, before it is shown.

  Fires wherever a preview is built — the editor's own preview, and the Preview tab on every runtime
  modal — so a plugin that has to appear inside a preview (an overlay, a grid, a locale banner) has
  one place to put it. Returning anything but a string leaves the document as it was.
  """
  @spec preview_document(String.t(), map()) :: String.t()
  def preview_document(html, meta) do
    "builder:preview:document"
    |> transform(Map.merge(meta, %{html: html}))
    |> Map.get(:html)
    |> case do
      document when is_binary(document) -> document
      _other -> html
    end
  end

  @doc """
  Before the assistant is asked. A plugin may rewrite the prompt or refuse it.

  This is where prompt handling belongs for anything that wants a say — a house style, a redaction
  pass, a refusal.
  """
  @spec before_ask(map()) :: {:ok, String.t()} | {:error, String.t()}
  def before_ask(payload) do
    case transform("builder:ai:before_ask", Map.put_new(payload, :error, nil)) do
      %{error: message} when is_binary(message) -> {:error, message}
      %{prompt: prompt} when is_binary(prompt) -> {:ok, prompt}
      _other -> {:ok, payload.prompt}
    end
  end

  @doc """
  The core's containment verdict, after it has been reached.

  A plugin may tighten it — refuse a placement the core allows — but never loosen one the core
  refused, because the core's rule is what keeps a document renderable.
  """
  @spec containment(boolean(), map()) :: {:ok, boolean(), String.t() | nil}
  def containment(false = _core_allows, _meta), do: {:ok, false, nil}

  def containment(true, meta) do
    case transform("builder:containment", Map.merge(meta, %{allowed?: true, reason: nil})) do
      %{allowed?: false, reason: reason} -> {:ok, false, reason}
      _allowed -> {:ok, true, nil}
    end
  end

  @doc """
  A component's inferred part in a form, before the editor uses it. A plugin answers another role
  under `:role`; anything that is not `:none` or a `MishkaCmsCore.Builder.FormRole` role leaves
  the inferred one.

      use MishkaInstaller.Event.Hook, event: "builder:form:role"

      def call(%{entry: %{name: "acme-send"}} = payload), do: {:reply, %{payload | role: :submit}}
      def call(payload), do: {:reply, payload}
  """
  @spec form_role(atom(), map()) :: atom()
  def form_role(role, entry) do
    case transform("builder:form:role", %{role: role, entry: entry}) do
      %{role: answered} when answered in @form_roles -> answered
      _unchanged -> role
    end
  end

  @doc "A component's examples, before the wizard shows them."
  @spec examples(list(), map()) :: list()
  def examples(examples, meta) do
    case transform("builder:examples", Map.merge(meta, %{examples: examples})) do
      %{examples: list} when is_list(list) -> list
      _other -> examples
    end
  end

  @doc "The preset choices offered for a component's attributes."
  @spec preset_choices(map(), map()) :: map()
  def preset_choices(choices, meta) do
    case transform("builder:preset:choices", Map.merge(meta, %{choices: choices})) do
      %{choices: rewritten} when is_map(rewritten) -> rewritten
      _other -> choices
    end
  end

  @doc """
  The save gate — the seam content lint, broken-link checks and schema validation hang off. A veto
  surfaces to the editor as a flash and an inline error, and nothing is written.
  """
  @spec before_save(map()) :: :ok | {:error, String.t()}
  def before_save(payload), do: gate("builder:save:before", Map.put_new(payload, :error, nil))

  @doc "The publish gate, same contract as `before_save/1`."
  @spec before_publish(map()) :: :ok | {:error, String.t()}
  def before_publish(payload),
    do: gate("builder:publish:before", Map.put_new(payload, :error, nil))

  @doc "Announces a completed save."
  @spec after_save(map()) :: :ok
  def after_save(summary), do: announce("builder:save:after", summary)

  @doc "Announces a completed publish."
  @spec after_publish(map()) :: :ok
  def after_publish(summary), do: announce("builder:publish:after", summary)

  @doc """
  Hands a visitor's form submission to whoever stores it.

  The payload carries `form` (the form's param name), `values` (the cast map, keyed by the fields
  the form declares), `page` and `site_id`. A plugin that took it answers with `handled: true`;
  anything else means the values reached nobody, which the page logs by form and field names only,
  and which the editor's `form-no-destination` note reports.

      use MishkaInstaller.Event.Hook, event: "page:form:submitted"

      def call(payload) do
        {:reply, %{payload | handled: true}}
      end
  """
  @spec form_submitted(map()) :: :handled | :unhandled
  def form_submitted(payload) do
    case transform(@form_submitted, Map.put_new(payload, :handled, false)) do
      %{handled: true} -> :handled
      _unhandled -> :unhandled
    end
  end

  @doc "Whether anything is registered to store page form submissions."
  @spec form_destination?() :: boolean()
  def form_destination?, do: listening?(@form_submitted)

  @doc """
  Whether `event` has a started plugin behind it.

  Reads the compiled dispatch module rather than firing the event, so asking the question about a
  seam whose plugins write something cannot itself cause a write. An event nobody ever registered on
  has no dispatch module at all, which is the same answer.
  """
  @spec listening?(String.t()) :: boolean()
  def listening?(event) do
    module = ModuleStateCompiler.module_event_name(event)

    Code.ensure_loaded?(module) and function_exported?(module, :initialize, 0) and
      module.initialize().plugins != []
  end

  @doc """
  The serialization transform — the AST-level sibling of the runtime's `runtime:compile:css`. A
  plugin receives the generated HEEx and may return a rewritten string.
  """
  @spec serialize(String.t(), map()) :: String.t()
  def serialize(heex, meta) do
    case transform("builder:serialize", %{heex: heex, meta: meta}) do
      %{heex: rewritten} when is_binary(rewritten) -> rewritten
      _payload -> heex
    end
  end
end
