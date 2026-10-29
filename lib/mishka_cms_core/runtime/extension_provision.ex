# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.ExtensionProvision do
  @moduledoc """
  Gives a site everything an extension ships and it is missing: the permission names, the
  components, the sample pages, and the snippet an installed editor offers. One implementation,
  driven by a `t:manifest/0` the extension declares.

  ## Why it is here and not in each extension

  It was written twice. A `diff` of the blog's machinery against the document's reported the alias,
  the section name, the snippet name, the path constants and the prose — and not one line of logic.
  Two copies of a run that must never half-finish is two places for it to learn to.

  What an extension keeps is what only it knows: the pages it ships and what they are made of. What
  it hands over is the order those things have to happen in, and every reason behind that order.

  ## The order is the whole design

  PERMISSION NAMES FIRST, so the extension's areas can be granted from the moment anything of it is
  on a site, and a run that stops halfway still leaves them grantable. They are not the site's: a
  name is shared by every site, so the first site's run creates it and every later one finds it.
  The SYSTEM writes them, whoever runs the provision, because creating a permission name is a
  master's action (`MishkaCmsCore.Accounts.Permission`), and a site admin setting their own site up
  has to be able to finish.

  COMPONENTS BEFORE PAGES. A page names live components, and
  `MishkaCmsCore.Runtime.Resources.Validations.StatefulIds` reads their rows to decide whether two
  placements collide. It can only do that once the rows are there.

  NOTHING IS EVER UPDATED. Every step writes only what the site has no row for, so a second run adds
  whatever the extension has learned to ship since and leaves everything else — including anything
  the admin has edited — exactly as it is. An admin pressing a button called "set up" has not asked
  to lose an edit; `MishkaCmsCore.Runtime.Handlers.UiKitUpgrade` is where losing one is offered, by
  name, one row at a time.

  EVERY PAGE HANGS ON THE SITE'S FRAME. An extension's pages are drawn in the site's `site-main`
  layout, between the header and the footer every page of the site shares
  (`MishkaCmsCore.Runtime.SiteLayout`), which every site has from its first install
  (`MishkaCmsCore.Install.StarterContent`). An extension writes that layout's id into each page it
  ships (`MishkaCmsCore.Runtime.SiteLayout.layout_id/1`).

  NO PAGE MAY RAISE THE RUN. A site is unique by more than a page's address, so a site already
  holding a page called "Blog" refuses a sample page at a path nothing has taken — and left to
  `Ash.create!` that is a raise in the MIDDLE of the run: the pages after it are never written, the
  snippet is never reached, and every later run stops at the same row. `MishkaCmsCore.Runtime.PageProvision`
  is what turns that into a rename or a skip, and a line in the report either way.

  ## What the report is for

  Not the logs. The admin pressed a button and is owed the answer: what arrived, what was written
  under another name because the one it wanted was taken, and what was left alone because something
  of theirs holds it. `PageProvision.note/1` writes each of those as a sentence.

  ## The snippet belongs to the editor

  The core keeps no snippet of its own: a snippet is a row of whichever visual editor the host
  installed, offered back in that editor's list. So the run hands it over on
  `runtime:provision:snippets`, a transform event, with the payload in `t:snippet_payload/0`. The
  editor's plugin writes the row the site is missing and adds its name to `installed`; a site that
  already has it is left alone, as everything else here is.

  A WRITE THAT FAILS IS REPORTED, NOT RAISED. A plugin that raises is skipped and the event answers
  the payload it was given, which reads as "nothing to install" — so the plugin puts the reason in
  `error`, and the run raises with it, as a refused write raised here before. With no editor
  installed nothing answers, and the report says `snippets: []`.
  """

  require Ash.Query

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Install.Bootstrap
  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.PageProvision
  alias MishkaCmsCore.Runtime.Site
  alias MishkaInstaller.Event.Hook

  # Every read here is narrowed to at most the handful of rows one extension writes, so a single
  # page of results holds all of them — and asking for a page keeps this working whether the action
  # paginates by keyset, by offset, or not at all.
  @row_limit 50

  @package %{page_code: :package}

  @snippets_event "runtime:provision:snippets"

  @typedoc """
  What an extension declares about itself. `pages` and `snippet` are functions of the SITE because a
  stored `<.component>` call names the site whose component it draws, so the markup cannot be
  written until the site is known.

  `snippet` is optional — an extension with nothing to put in an editor's snippet list leaves it
  out. `permissions` is optional too: the names the extension's own areas are gated by, each with
  its description.
  """
  @type manifest :: %{
          required(:app) => atom(),
          required(:bundle_path) => String.t(),
          required(:section) => String.t(),
          required(:pages) => (map() -> [map()]),
          optional(:snippet) => %{name: String.t(), source: (String.t() -> String.t())},
          optional(:permissions) => [{String.t(), String.t()}]
        }

  @typedoc """
  What `runtime:provision:snippets` is handed, and answers with.

  `snippet.source` is already the markup for this site (the manifest's function, applied to
  `site_name`). A plugin appends the name of each snippet it wrote to `installed`, or sets `error`
  to the reason a write was refused; it never raises. `actor` is the person running the provision,
  or `nil` when the system does (the seeds, the install wizard).
  """
  @type snippet_payload :: %{
          app: atom(),
          snippet: %{name: String.t(), source: String.t()},
          site_id: String.t(),
          site_name: String.t(),
          actor: map() | nil,
          installed: [String.t()],
          error: term() | nil
        }

  @type report :: %{
          version: String.t() | nil,
          permissions: [String.t()],
          components: [String.t()],
          pages: [String.t()],
          snippets: [String.t()],
          renamed_pages: [PageProvision.renamed()],
          skipped_pages: [PageProvision.held()]
        }

  @doc """
  The names a person needs to run a provision of `manifest` — Set up, Doctor, Kit upgrade — one per
  step, each asked on its own because a required list is any-of:

    * `admin:dashboard:runtime:component` — the kit's components are written;
    * `admin:dashboard:runtime:js_hook`, `admin:dashboard:runtime:stylesheet` — when the bundle
      ships JS hooks or stylesheets, the kit writes them too;
    * `admin:dashboard:runtime:page` — the sample pages are written, and an installed editor saves
      the snippet for its page editor, which this name opens;
    * `admin:dashboard:runtime:site` — the site is read, to name the pages after it.
  """
  @spec required(manifest()) :: [String.t()]
  def required(manifest) do
    bundle = bundle(manifest)

    [
      {"admin:dashboard:runtime:component", true},
      {"admin:dashboard:runtime:js_hook", Map.get(bundle, "js_hooks", []) != []},
      {"admin:dashboard:runtime:stylesheet", Map.get(bundle, "stylesheets", []) != []},
      {"admin:dashboard:runtime:page", true},
      {"admin:dashboard:runtime:site", true}
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  @doc "Whether `actor` holds every name in `required/1`, so a provision it starts can finish."
  @spec allowed?(manifest(), map() | nil) :: boolean()
  def allowed?(manifest, actor), do: actor != nil and missing(manifest, actor) == []

  @doc "The names in `required/1` that `actor` does not hold — what a refusal says to ask for."
  @spec missing(manifest(), map() | nil) :: [String.t()]
  def missing(manifest, nil), do: required(manifest)

  def missing(manifest, actor) do
    actor = AccessPermissions.with_permissions(actor)
    Enum.reject(required(manifest), &AccessPermissions.match?(actor, %{}, permissions: [&1]))
  end

  @doc """
  Gives `site` everything `manifest` ships and it is missing, and returns what happened.

  Takes the site record or its id. Raises when the site is not there, when the actor lacks a name in
  `required/1`, or when a write is refused for any reason but a page being taken: every caller
  wants to know, and the screen says so. With no actor — the seeds, the install wizard's own run —
  the system writes.
  """
  @spec ensure!(manifest(), map() | String.t(), map(), keyword()) :: report()
  def ensure!(manifest, site, answers \\ %{}, opts \\ [])

  # THE SITE IS ASKED ABOUT FIRST, before it is read: a site admin reads no other site, so the read
  # would answer "no such site" for one that exists.
  def ensure!(manifest, site_id, answers, opts) when is_binary(site_id) do
    permitted!(manifest, actor(opts))
    own_site!(actor(opts), site_id)
    ensure!(manifest, site!(site_id, actor(opts)), answers, opts)
  end

  def ensure!(manifest, %{id: site_id, name: site_name} = site, answers, opts)
      when is_binary(site_id) and is_binary(site_name) do
    actor = actor(opts)
    permitted!(manifest, actor)
    own_site!(actor, site_id)
    version = bundle_version(manifest)
    permissions = ensure_permissions(manifest)
    components = install_missing_components(manifest, site_id, actor)

    %{created: created, renamed: renamed, skipped: skipped} =
      site_id
      |> PageProvision.missing(moved(pages(manifest, site, actor), answers),
        stamp: {manifest.app, version},
        actor: actor,
        # THE ACTION THE WRITE WILL USE, so the plan compares the attributes as that action stores
        # them: a tenant admin's page goes through `:create`, which takes `site_id` from the tenant
        # rather than from the attributes.
        action: create_action(actor)
      )
      |> PageProvision.create(&write_page!(&1, actor))

    snippets = install_missing_snippet(manifest, site_id, site_name, actor)

    %{
      # WHAT THIS RUN WAS, not what it added. A second run that finds everything already there adds
      # nothing and is still an install at this version — which is what the site is then recorded as
      # having, and what a later upgrade compares against.
      version: version,
      permissions: permissions,
      components: components,
      pages: Enum.map(created, & &1.path),
      snippets: snippets,
      renamed_pages: renamed,
      skipped_pages: skipped
    }
  end

  @doc "The sample pages as this checkout ships them, as the attribute maps a page create takes."
  @spec pages(manifest(), map() | String.t(), map() | nil) :: [map()]
  def pages(manifest, site, actor \\ nil)

  def pages(manifest, site_id, actor) when is_binary(site_id) do
    own_site!(actor, site_id)
    pages(manifest, site!(site_id, actor), actor)
  end

  def pages(manifest, %{id: site_id, name: site_name} = site, _actor)
      when is_binary(site_id) and is_binary(site_name) do
    # `section` AND `site_id` ARE PUT ON HERE, not left to the extension. The section cannot then
    # disagree with what the manifest declares, and the site cannot be forgotten — a page created
    # without one is refused by the action, in the middle of a run, which is the failure this whole
    # module is shaped to avoid.
    # AND MARKED AS ANSWERING EVERY LANGUAGE. An extension's pages hold no prose — they hold
    # components that read the captured language and fetch that language's rows — so one page
    # answers every language its site publishes, which is what `/fa/blog` has always done. Saying so
    # is what keeps the rule that stops `/fa/about` serving English from taking these down with it:
    # see `MishkaCmsCore.Runtime.PageProvision.serves_all_languages?/1`.
    Enum.map(manifest.pages.(site), fn attrs ->
      attrs
      |> Map.put(:section, manifest.section)
      |> Map.put(:site_id, site_id)
      |> PageProvision.serving_all_languages()
    end)
  end

  @doc """
  The pages of a run with the addresses the admin asked for.

  A page whose PATH something else holds is the one thing a run cannot answer on its own: the
  address is taken, and only the admin knows whether to move ours or theirs. `answers` is what they
  said, either way:

    * `%{"paths" => %{"/:lang/blog" => "/:lang/journal"}}` moves one page;
    * `%{"prefix" => "/mish"}` moves every page of the extension under one segment, which is the
      answer when a site has its own `/blog` and wants ours somewhere else entirely. The segment
      goes after a leading `:lang`, which only the first segment can be: `/:lang/blog` moves to
      `/:lang/mish/blog`.

  A prefix is applied first and a named path wins over it, so an admin can move the lot and then
  place one of them by hand. A page moved to a path that captures no `lang` answers in its own
  language alone (`MishkaCmsCore.Runtime.PageProvision.serving_all_languages/1`).
  """
  @spec moved([map()], map()) :: [map()]
  def moved(pages, answers) when map_size(answers) == 0, do: pages

  def moved(pages, answers) do
    prefix = answers |> Map.get("prefix", "") |> to_string() |> String.trim() |> String.trim("/")
    named = Map.get(answers, "paths", %{})

    Enum.map(pages, fn page ->
      moved =
        case Map.get(named, page.path) do
          asked when is_binary(asked) and asked != "" -> asked
          _not_named -> prefixed(page.path, prefix)
        end

      page |> Map.put(:path, moved) |> still_answering()
    end)
  end

  defp still_answering(page) do
    if PageProvision.serves_all_languages?(page),
      do: PageProvision.serving_all_languages(page),
      else: page
  end

  defp prefixed(path, ""), do: path
  defp prefixed("/:lang", prefix), do: "/:lang/" <> prefix
  defp prefixed("/:lang/" <> rest, prefix), do: "/:lang/" <> prefix <> "/" <> rest
  defp prefixed(path, prefix), do: "/" <> prefix <> path

  @doc "The component names the extension's bundle ships, read off the bundle itself."
  @spec component_names(manifest()) :: [String.t()]
  def component_names(manifest), do: bundle(manifest) |> Map.get("components", []) |> names()

  @doc """
  The bundle version the pages are stamped with.

  It is the KIT's version rather than the extension's: the pages and the components are one release
  together — a page drawing a component the site has not got renders an error where the block should
  be — and the kit is what `MishkaCmsCore.Runtime.Handlers.UiKitUpgrade` already versions.
  """
  @spec bundle_version(manifest()) :: String.t() | nil
  def bundle_version(manifest), do: bundle(manifest) |> Map.get("version")

  @doc "The paths of the sample pages, in the order they are created."
  @spec page_paths(manifest(), map() | String.t(), map() | nil) :: [String.t()]
  def page_paths(manifest, site, actor \\ nil),
    do: manifest |> pages(site, actor) |> Enum.map(& &1.path)

  # ---------------------------------------------------------------------------
  @doc """
  Creates the names `manifest` lists under `permissions:` that are not stored yet, as the system, and
  returns the ones it created. `ensure!/4` runs it first.
  """
  @spec ensure_permissions(manifest()) :: [String.t()]
  def ensure_permissions(%{permissions: [_ | _] = permissions}) do
    {:ok, %{created: created}} = Bootstrap.ensure_permissions(permissions)
    Enum.map(created, & &1.name)
  end

  def ensure_permissions(_manifest), do: []

  # ---------------------------------------------------------------------------
  # Components
  # ---------------------------------------------------------------------------

  defp install_missing_components(manifest, site_id, actor) do
    case component_names(manifest) -- existing_component_names(manifest, site_id, actor) do
      [] ->
        []

      missing ->
        {:ok, _installed} =
          UiKitHandler.install_kit!(manifest.bundle_path,
            site_id: site_id,
            selection: %{components: missing},
            actor: actor
          )

        missing
    end
  end

  # AN ARCHIVED ROW COUNTS AS PRESENT. The installer skips one rather than reviving it, so naming it
  # here would report an install that did not happen — and an admin who archived a component said
  # what they wanted.
  defp existing_component_names(manifest, site_id, actor) do
    names = component_names(manifest)

    {archived, archived_opts} = archived_read(actor)

    for {action, opts} <- [{:read_any, reading(actor)}, {archived, archived_opts}],
        row <-
          Component
          |> Ash.Query.for_read(action, %{}, opts)
          |> Ash.Query.filter(name in ^names and site_id == ^site_id)
          |> Ash.Query.select([:name])
          |> rows(actor),
        uniq: true,
        do: row.name
  end

  # THE ARCHIVED ROWS, AND THE ONE READ AN ACTOR'S ROLE DOES CHANGE. `:master_archived` refuses a
  # tenant actor outright — see `MishkaCmsCore.Runtime.Resources.Validations.TenantContext` — so the
  # site's own admin reads its own `:archived` under its tenant, which answers with the same rows
  # for the only site they can be provisioning.
  defp archived_read(nil), do: {:master_archived, [authorize?: false]}
  defp archived_read(%{site_id: nil} = actor), do: {:master_archived, [actor: actor]}

  defp archived_read(%{site_id: site_id} = actor),
    do: {:archived, [actor: actor, tenant: site_id]}

  # ---------------------------------------------------------------------------
  # Pages
  # ---------------------------------------------------------------------------

  # WHO IS WRITING THIS PAGE, and therefore which action writes it. Nobody — the wizard, the seeds —
  # keeps the system path, because there is no session to write as. A master writes the master
  # action with the site named, as they do everywhere else. A tenant admin writes their OWN site's
  # action under its tenant, so the site the page lands on is Ash's answer rather than this
  # module's: with `authorize?: false` and `:master_create` it was neither.
  #
  # THE MARKUP IS THE EXTENSION'S, not typed by whoever pressed the button, so the write says it is a
  # package's — see `MishkaCmsCore.Runtime.Resources.Validations.CodeChange`.
  defp write_page!(attrs, nil) do
    Page
    |> Ash.Changeset.for_create(:master_create, attrs, authorize?: false, context: @package)
    |> Ash.create!()
  end

  defp write_page!(attrs, %{site_id: nil} = actor) do
    Page
    |> Ash.Changeset.for_create(:master_create, attrs, actor: actor, context: @package)
    |> Ash.create!()
  end

  defp write_page!(%{site_id: site_id} = attrs, actor) do
    Page
    |> Ash.Changeset.for_create(:create, Map.delete(attrs, :site_id),
      actor: actor,
      tenant: site_id,
      context: @package
    )
    |> Ash.create!()
  end

  # ---------------------------------------------------------------------------
  # The snippet
  # ---------------------------------------------------------------------------

  # THE SOURCE IS RENDERED HERE, so what crosses the hook is data: a plugin sees the markup this site
  # gets, never the extension's function.
  defp install_missing_snippet(
         %{snippet: %{name: name, source: source}} = manifest,
         site_id,
         site_name,
         actor
       ) do
    payload = %{
      app: manifest.app,
      snippet: %{name: name, source: source.(site_name)},
      site_id: site_id,
      site_name: site_name,
      actor: actor,
      installed: [],
      error: nil
    }

    case Hook.call(@snippets_event, payload) do
      %{error: nil, installed: installed} when is_list(installed) ->
        installed

      # RAISED, as the `Ash.create!` this replaced did: a refused write is one every caller wants
      # to know about, and the screen says so.
      %{error: reason} when not is_nil(reason) ->
        raise "the snippet #{name} could not be saved: #{inspect(reason)}"

      _no_answer ->
        []
    end
  end

  defp install_missing_snippet(_no_snippet, _site_id, _site_name, _actor), do: []

  # ---------------------------------------------------------------------------
  # Reading
  # ---------------------------------------------------------------------------

  # sobelow_skip ["Traversal.FileModule"]
  # `bundle_path` comes from the extension's manifest, code the host ships, not from a request.
  defp bundle(manifest), do: manifest.bundle_path |> File.read!() |> Jason.decode!()

  defp names(components), do: Enum.map(components, & &1["name"])

  defp site!(site_id, actor) do
    Site
    |> Ash.Query.for_read(:get_any, %{}, reading(actor))
    |> Ash.Query.filter(id == ^site_id)
    |> Ash.read_one!()
    |> case do
      nil -> raise ArgumentError, "there is no site #{inspect(site_id)} to provision"
      site -> site
    end
  end

  defp rows(query, actor) do
    case Ash.read!(query, reading(actor) ++ [page: [limit: @row_limit]]) do
      %{results: found} -> found
      found when is_list(found) -> found
    end
  end

  # SEE `MishkaCmsCore.Runtime.PageProvision`'s own `reading/1`, which says why the read action does
  # not change with the actor while the write action does.
  defp reading(nil), do: [authorize?: false]
  defp reading(actor), do: [actor: actor]

  defp actor(opts), do: Keyword.get(opts, :actor)

  # A SITE ADMIN PROVISIONS THEIR OWN SITE AND NO OTHER. The dashboard's `chosen_site/2` already
  # answers with theirs whatever the form said, so this can only fire for a caller that went around
  # it — and it fires rather than letting the two halves disagree: the tenant READ is scoped to the
  # actor's own site, which is what keeps another site's rows away from them, while the tenant WRITE
  # takes the site it is given. Told to do both at once, the read would answer with nothing, the
  # plan would call every address free, and the write would meet a unique index instead.
  defp own_site!(%{site_id: theirs}, site_id) when is_binary(theirs) and theirs != site_id do
    raise ArgumentError,
          "a site admin may only provision their own site, not #{inspect(site_id)}"
  end

  defp own_site!(_actor, _site_id), do: :ok

  # REFUSED BEFORE THE FIRST WRITE, not in the middle: a run that stops after the components and
  # before the pages leaves a site half set up, and every step's name is known before it starts.
  defp permitted!(_manifest, nil), do: :ok

  defp permitted!(manifest, actor) do
    case missing(manifest, actor) do
      [] ->
        :ok

      names ->
        raise ArgumentError,
              "setting up an extension needs #{Enum.join(names, ", ")}, which you do not hold"
    end
  end

  defp create_action(nil), do: :master_create
  defp create_action(%{site_id: nil}), do: :master_create
  defp create_action(_tenant_admin), do: :create
end
