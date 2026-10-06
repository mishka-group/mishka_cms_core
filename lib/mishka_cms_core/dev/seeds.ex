defmodule MishkaCmsCore.Dev.Seeds do
  @moduledoc """
  Dev and stress seeds for MishkaCmsCore resources.

  Returns a map with foundation data so extension seeds can build on top:
    %{
      sites: [site, ...],
      users: %{master: [user, ...], tenant: %{site_id => [user, ...]}},
      permissions: [permission, ...]
    }

  Seeds run from any caller (a `mix run` script or a LiveView). `Ash.Generator.sequence`
  walks the process's `$ancestors` and calls `Process.info/2`, which raises on a
  registered-NAME (atom) ancestor such as a LiveView's Socket; the ancestor chain is
  pruned to pids before generating so the generators work from any caller.

  Site-scoped JS hook names are slugified to lowercase-dashed; the JS compiler prepends
  the site name in PascalCase at compile time, so `console-logger` on the `localhost`
  site becomes the `LocalhostConsoleLogger` Phoenix LiveView hook identifier.

  ## What a seeded site is made of

  `MishkaCmsCore.Install.StarterContent` first — the theme, the header, the footer, the layout, the
  home, about, contact and privacy pages a stranger's first install gets, and the sign-in pages
  every site gets — and then the pages that
  site exists to demonstrate, out of its own module: `MishkaCmsCore.Dev.LocalhostPages`,
  `MishkaCmsCore.Dev.SiteAPages`, `MishkaCmsCore.Dev.SiteBPages`. Running the production starter
  here is what keeps it exercised; a path nobody opens is a path nobody has seen.

  Every address written is in the `/:lang` path mode (`MishkaCmsCore.Runtime.Languages`) and none of
  them is one this application's own router answers — `/blog` reaches the database, `/mish-blog` is
  the hand-written page.

  ## A DEV SEED IS RUN AGAIN

  Reseeding is how a developer picks up whatever the seeds have learned to write since — the media
  set is the current example — without dropping the database they have been working in, and it is
  the only way anyone exercises this file after changing it. `mix ecto.reset` is the alternative,
  and it throws that developer's own work away and signs everyone out.

  So every step here CREATES ONLY WHAT IS MISSING. It asks what the site already holds before it
  writes, leaves a row it recognises exactly as it is — an admin may have edited it — and counts a
  row they ARCHIVED as present as well, because archiving it is what they said about it. That is
  `MishkaBlog.Provision`'s rule, and it is the one the whole file follows: nothing below updates.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.Dev.Generator

  require Ash.Query

  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Dev.SeedMedia
  alias MishkaCmsCore.Install.{Bootstrap, StarterContent}

  alias MishkaCmsCore.Runtime.{
    Component,
    JsHook,
    Languages,
    Layout,
    Page,
    PageDraft,
    PageEditions,
    PageProvision,
    Setting,
    Site
  }

  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler
  alias MishkaCmsCore.Settings

  # THREE SITES A BROWSER ON THIS MACHINE CAN REALLY OPEN. `mishka.tools` and `api.mishka.tools`
  # resolve to public IPs, so every page seeded onto them was unreachable from the machine that
  # seeded them — and `site_a` cannot be a host at all, because a `_` is not legal in a domain.
  # `*.localhost` resolves to the loopback in Chromium and Firefox without any setup; curl and some
  # OS resolvers want an `/etc/hosts` line, which `dev_seed/1` prints.
  #
  # EACH ONE NAMES ITS OWN PAGES MODULE. A page names THIS site's components and THIS site's hooks
  # by name, so the list cannot be shared — see `MishkaCmsCore.Dev.LocalhostPages`.
  @site_configs [
    %{
      name: "localhost",
      host: "localhost",
      mode: :hybrid,
      master: true,
      priority: 0,
      languages: ["en", "fa"],
      pages: MishkaCmsCore.Dev.LocalhostPages
    },
    %{
      name: "site-a",
      host: "site-a.localhost",
      mode: :hybrid,
      master: false,
      priority: 1,
      languages: ["en", "fr"],
      pages: MishkaCmsCore.Dev.SiteAPages
    },
    %{
      name: "site-b",
      host: "site-b.localhost",
      mode: :hybrid,
      master: false,
      priority: 2,
      languages: ["en"],
      pages: MishkaCmsCore.Dev.SiteBPages
    }
  ]

  @hosts_hint "  -> Add to /etc/hosts for curl: 127.0.0.1 site-a.localhost site-b.localhost"

  # ONE ACCOUNT PER ROLE AN END-TO-END RUN SIGNS IN AS, on every site, at `<role>@<site>.test`: the
  # site's full admin, a user holding nothing, and one narrow admin per core area a check has to be
  # seen refusing and allowing. An extension's roles are its own dev seed's (`seed_role_accounts/2`),
  # since its names exist only once it is installed.
  @site_roles [
    {"admin", ["*"]},
    {"viewer", []},
    {"builder", ["admin:dashboard:runtime:page"]},
    {"developer", ["admin:dashboard:code"]},
    {"accounts", ["admin:dashboard:user", "admin:dashboard:permission"]},
    {"api", ["admin:api:*"]}
  ]

  # THE ONE GLOBAL LAYOUT, and the only one the dev seed writes. Three invented layouts per site
  # used to be generated with random names, a nested `<body>` and links to pages that do not exist;
  # what a developer could not see anywhere was a layout belonging to NO site, which is what a page
  # on `global-plain` demonstrates.
  @global_layout_name "global-plain"

  @global_layout_template ~S"""
  <div class="min-h-dvh bg-ground font-sans text-ink antialiased">
    <div :if={@flash != %{}} id="global-flash" class="mx-auto w-full max-w-[720px] px-6 pt-6">
      <p
        :for={{kind, message} <- @flash}
        id={"global-flash-#{kind}"}
        phx-click="lv:clear-flash"
        phx-value-key={kind}
        class="cursor-pointer rounded-[10px] border border-line bg-white px-4 py-3 text-[13px] font-medium"
      >
        {message}
      </p>
    </div>
    {@inner_content}
  </div>
  """

  # THE DEMO ROOT LAYOUT, on localhost's error page only. A site may replace the document its error
  # pages are drawn in, and the banner is how a developer sees that it happened;
  # `MishkaCmsCore.Install.StarterContent` writes the one a real site gets.
  @localhost_error_root_layout String.replace(
                                 StarterContent.error_root_layout(),
                                 ~S|<body class="antialiased">|,
                                 ~S|<body class="antialiased">
    <div class="bg-emerald-600 text-white text-center text-sm font-semibold py-2 tracking-wide">
      ✦ Custom Root Layout active — HTTP <%= @status %>
    </div>|
                               )

  @doc """
  Creates realistic dev seed data: 3 sites a browser on this machine can open, fixed users per site,
  real Unix-style permissions, the production starter content, the dev showcase pages, media and JS
  hooks.
  """
  def dev_seed(progress \\ fn _ -> :ok end) do
    announce("==> [MishkaCmsCore] Seeding core data...")
    log = fn line -> progress.({:core, :log, line}) end

    log.(gettext("Creating permissions…"))
    permissions = seed_permissions()
    permission_map = Map.new(permissions, fn p -> {p.name, p} end)

    log.(gettext("Creating sites…"))
    sites = seed_sites()
    localhost_site = Enum.find(sites, fn s -> s.host == "localhost" end)
    announce(@hosts_hint)

    log.(gettext("Creating users…"))
    # `users.master` is handed to every extension's seed as the masters: users whose `site_id` is
    # nil and nobody else. A fixed user of a site goes with that site's users.
    {fixed_masters, fixed_site_users} =
      localhost_site
      |> seed_fixed_users(permission_map)
      |> Enum.split_with(&is_nil(&1.site_id))

    master_users = seed_master_users(3, permission_map)
    all_master_users = fixed_masters ++ master_users

    site_users =
      Enum.reduce(fixed_site_users, seed_site_users(sites, permission_map), fn user, acc ->
        Map.update(acc, user.site_id, [user], &(&1 ++ [user]))
      end)

    # BEFORE THE PAGES, because the pages are made OF it. The showcase templates call
    # `chelekom-tabs`, `chelekom-table` and their siblings; a page seeded before the kit exists
    # resolves each of those to nothing and renders the red "Component failed to render!" box
    # instead. This is also why the install lives here, where `priv/repo/dev_seeds.exs` reaches it
    # too: it calls `dev_seed/1` directly.
    log.(gettext("Installing every UI-kit component — the sample pages are built from them…"))
    ensure_ui_kits!(log)

    log.(gettext("Creating the global layout & hooks…"))
    global_layout = seed_global_layout()
    seed_global_js_hooks()

    log.(gettext("Creating per-site content (theme, components, layout, pages, media)…"))

    Enum.each(sites, fn site ->
      config = config_for(site)

      # BEFORE THE PAGES, because a page is written out of this library: the team page asks
      # `MishkaCmsCore.Dev.SeedMedia` what pictures the site has, and a page written first is a page
      # with none — silently, since "no picture" is also what a fresh install answers.
      seed_media(site.id)
      seed_languages(site, config)

      # THE PRODUCTION STARTER, RUN IN DEV. Every dev site gets the theme, the two site components,
      # the `site-main` layout, the four plain pages and the error page a stranger's first install
      # gets — so that path is exercised on every reseed instead of only on somebody else's machine.
      starter = StarterContent.seed!(site, starter_opts(site, config))
      announce_pages(starter)

      # THE SIGN-IN PAGES EVERY SITE GETS, and the built-in words of each language it publishes in
      # — after the languages above, which decide that.
      site |> StarterContent.ensure_auth!() |> announce_pages()

      # A site seeded before the Error Page had an offline entry gets it on the next run.
      if StarterContent.ensure_offline_entry(site) == :added,
        do: announce("  -> Added the offline page to #{site.name}'s error page")

      seed_pages(site, config, %{main: starter.layout_id, plain: global_layout.id}, site_users)
      seed_page_draft(site)
      seed_js_hooks(site.id, 2)
    end)

    announce("==> [MishkaCmsCore] Done.")

    %{
      sites: sites,
      users: %{master: all_master_users, tenant: site_users},
      permissions: permissions
    }
  end

  defp config_for(%{host: host}), do: Enum.find(@site_configs, &(&1.host == host))

  # THE HOME COMES FROM THE SITE, not from the installer. A developer's first click lands on `/:lang`,
  # and the plain page a stranger's first install opens on is the one thing a dev site must not
  # answer with — see `MishkaCmsCore.Dev.LocalhostPages.home/0`. `localhost` brings its about page
  # too, with a section hidden from visitors to open in the builder (`LocalhostPages.about/0`).
  defp starter_opts(%{host: "localhost"}, config),
    do: [
      root_layout_template: @localhost_error_root_layout,
      nav: config.pages.nav(),
      templates: %{"Home" => config.pages.home(), "About" => config.pages.about()}
    ]

  defp starter_opts(_site, config),
    do: [nav: config.pages.nav(), templates: %{"Home" => config.pages.home()}]

  # THE LANGUAGES ARE A SETTING, and every `/:lang` page answers only in the ones it names — see
  # `MishkaCmsCore.Runtime.Languages`.
  #
  # ASKED OF THE ROW, not of `Settings.get/3`: a site with no list of its own reads the global one,
  # so the façade can never answer "this site has none" and a run would either write over a
  # developer's edit every time or never write at all.
  defp seed_languages(%{id: site_id}, %{languages: languages}) do
    own? =
      Setting
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(key == "site.languages" and site_id == ^site_id)
      |> Ash.exists?(authorize?: false)

    unless own? do
      Settings.put("site.languages", languages, site_id: site_id, category: "general")
    end
  end

  @doc """
  The optional extension seed categories the installer's dev step can layer on top of the core
  foundation — only those whose seed module is actually loaded. The core data (sites, users,
  permissions, components, …) is always seeded by `run/1`, so it is not listed here.
  """
  @spec categories() :: [%{key: atom(), label: String.t(), module: module()}]
  def categories do
    [
      %{key: :blog, label: "Mishka Blog", module: MishkaBlog.Dev.Seeds},
      %{key: :document, label: "Mishka Document", module: MishkaDocument.Dev.Seeds}
    ]
    |> Enum.filter(&Code.ensure_loaded?(&1.module))
  end

  @doc """
  The ordered seed phases for `selected`, as `{id, label}` — one progress row per phase (the installer
  renders these as a live checklist). Always starts with `:core`, which installs every UI-kit
  component too; the extension seeds are added when selected.
  """
  @spec steps([atom()]) :: [{atom(), String.t()}]
  def steps(selected) do
    extensions =
      categories() |> Enum.filter(&(&1.key in selected)) |> Enum.map(&{&1.key, &1.label})

    [{:core, gettext_noop("Seeding core data (sites, users, permissions, UI kits, content)")}] ++
      extensions
  end

  @doc """
  Runs the dev seed for local development: the core foundation, every UI-kit component and the
  content (always), plus — when chosen — the extension seeds per site (mirrors
  `priv/repo/dev_seeds.exs`). For DEV ONLY — never in production. `progress` is called with
  `{phase, status, detail}` so the installer can show a live checklist. Returns the core foundation
  map.
  """
  @spec run([atom()], (term() -> any())) :: map()
  def run(selected \\ [], progress \\ fn _ -> :ok end) do
    prune_ancestors_to_pids()

    progress.({:core, :running, nil})
    core = dev_seed(progress)
    progress.({:core, :done, nil})

    categories()
    |> Enum.filter(&(&1.key in selected))
    |> Enum.each(fn %{key: key, module: module} ->
      progress.({key, :running, nil})
      section = fn line -> progress.({key, :log, line}) end

      Enum.each(core.sites, fn site ->
        users = core.users.master ++ Map.get(core.users.tenant, site.id, [])
        module.dev_seed(site.id, users, section)
      end)

      progress.({key, :done, nil})
    end)

    core
  end

  # EVERY COMPONENT OF EVERY KIT, with nothing to choose: a dev database is where all of them get
  # tried. No kit ships with the CMS, so one this server has not downloaded yet is downloaded first,
  # the way the installer finds it; a file already there is kept, a developer's own export included.
  #
  # INSTALLED ONCE PER KIT, like every other step here. A kit this database already holds is left as
  # it is, so a rerun upserts nothing.
  defp ensure_ui_kits!(log) do
    Enum.each(UiKitHandler.download_missing(), fn failure ->
      log.(
        gettext("%{label} (%{tag}) could not be downloaded: %{reason}",
          label: failure.label,
          tag: failure.tag,
          reason: failure.reason
        )
      )
    end)

    case UiKitHandler.available_kits() |> Enum.reject(&kit_installed?/1) |> Enum.map(& &1.name) do
      [] -> :already_installed
      names -> UiKitHandler.install_kits!(names, site_id: nil)
    end
  end

  defp kit_installed?(%{name: name}) do
    Component
    |> Ash.Query.for_read(:read_any)
    |> Ash.Query.filter(extra["ui_kit"] == ^name and is_nil(site_id))
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> false
      {:ok, _component} -> true
      _error -> false
    end
  end

  defp prune_ancestors_to_pids do
    Process.put(:"$ancestors", Enum.filter(Process.get(:"$ancestors", []), &is_pid/1))
  end

  @doc """
  Stress seed: creates `count` sites with proportional data per site.
  """
  def stress_seed(opts \\ []) do
    site_count = Keyword.get(opts, :sites, 3000)
    layouts_per_site = Keyword.get(opts, :layouts_per_site, 20)
    error_pages_per_site = Keyword.get(opts, :error_pages_per_site, 3)
    hooks_per_site = Keyword.get(opts, :hooks_per_site, 10)
    media_categories_per_site = Keyword.get(opts, :media_categories_per_site, 10)
    media_per_site = Keyword.get(opts, :media_per_site, 100)
    master_users = Keyword.get(opts, :master_users, 10)
    tenant_users = Keyword.get(opts, :tenant_users, 20)

    announce("==> [MishkaCmsCore] Stress seeding #{site_count} sites...")

    _permissions = seed_permissions()
    sites = seed_stress_sites(site_count)
    _master_users = seed_stress_master_users(master_users)
    _tenant_users = seed_stress_tenant_users(sites, tenant_users)

    Enum.each(sites, fn site ->
      seed_layouts(site.id, layouts_per_site)
      seed_error_pages(site.id, error_pages_per_site)
      seed_js_hooks(site.id, hooks_per_site)
      seed_stress_media(site.id, media_categories_per_site, media_per_site)
    end)

    announce("==> [MishkaCmsCore] Stress seed done.")
    :ok
  end

  # THE SAME NAMES THE INSTALL CREATES (`MishkaCmsCore.Install.Bootstrap.permissions/0`), only the
  # ones missing, so a seed run after the install wizard adds nothing twice. Every name a seeded
  # account holds is one of them.
  defp seed_permissions do
    announce("  -> Creating permissions...")

    {:ok, %{stored: stored}} = Bootstrap.ensure_permissions()
    stored
  end

  # THE SCOPE IS HALF THE QUESTION. A master account and a site's own account are two different
  # rows — `users_unique_email_index` is on `(site_id, email)`, and `EnforceMasterEmailSeparation`
  # refuses only a master an address a site holds, so a site's registration or an admin's
  # `:tenant_create` can put a seeded address on a site while the master account of that name is
  # still there. Asked without a scope, this read then saw two rows, `read_one` answered an error,
  # the error read as "not there", and the seed went on to create the master account it already had
  # and died on the separation rule instead. With the scope it is the row the create would write, and
  # the identity guarantees there is at most one of those.
  defp existing_user(email, site_id) do
    User
    |> Ash.Query.filter(email == ^email)
    |> scoped(site_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %User{} = user} -> user
      _absent -> nil
    end
  end

  defp create_user(email, site_id) do
    attrs = [email: email, password: "Password123!", password_confirmation: "Password123!"]

    case site_id do
      nil -> attrs |> user() |> Ash.Generator.generate()
      id -> attrs |> user(id) |> Ash.Generator.generate()
    end
  end

  defp assign_permission(user_id, permission) do
    MishkaCmsCore.Accounts.UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user_id)
    |> Ash.Changeset.force_change_attribute(:permission_id, permission.id)
    |> Ash.create!(authorize?: false)
  end

  # `none@example.com` HOLDS NOTHING, as its name says. An earlier seed granted it `*`; a database
  # seeded then keeps that grant, because a second run never takes away what is there.
  defp seed_fixed_users(localhost_site, permission_map) do
    announce("  -> Creating fixed users (master@example.com with *, none@example.com)...")

    fixed = [
      %{email: "master@example.com", site_id: nil, names: ["*"]},
      %{email: "none@example.com", site_id: localhost_site.id, names: []}
    ]

    # THE PERMISSIONS ARE ASSIGNED EITHER WAY. `UserPermission`'s `:assign` is an upsert on
    # `(user_id, permission_id)`, so a user who already holds one keeps the one row they have, and a
    # run that died between creating the account and granting it finishes the job on the next one
    # rather than leaving a `master@example.com` nobody can sign in as anything with.
    Enum.map(fixed, fn %{email: email, site_id: site_id, names: names} ->
      account = existing_user(email, site_id) || create_user(email, site_id)
      Enum.each(names, &assign_permission(account.id, Map.fetch!(permission_map, &1)))
      account
    end)
  end

  # Find-or-create for the same reason `seed_permissions/0` is: the install wizard bootstraps the
  # first site (usually `localhost`) before the dev-seed step runs, so creating it again collides on
  # the unique host and takes the whole seed down with it.
  defp seed_sites do
    announce("  -> Creating #{length(@site_configs)} sites...")

    Enum.map(@site_configs, fn config ->
      existing =
        Site
        |> Ash.Query.filter(host == ^config.host)
        |> Ash.read_one(authorize?: false)

      case existing do
        {:ok, %Site{} = site} ->
          site

        _absent ->
          create_site_from_config(config)
      end
    end)
  end

  # `auth_pages: :inline` — `dev_seed/1` writes the sign-in pages itself, so no job is enqueued.
  defp create_site_from_config(config) do
    Site
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: config.name,
        host: config.host,
        mode: config.mode,
        master: config.master,
        active: true,
        priority: config.priority,
        allowed_origins: []
      },
      authorize?: false,
      context: %{auth_pages: :inline}
    )
    |> Ash.create!()
  end

  defp seed_master_users(count, permission_map) do
    announce("  -> Creating #{count} master users (all with * permission)...")
    star_perm = Map.fetch!(permission_map, "*")

    Enum.map(1..count, fn i ->
      email = "master#{i}@example.com"
      account = existing_user(email, nil) || create_user(email, nil)
      assign_permission(account.id, star_perm)
      account
    end)
  end

  # ONE ACCOUNT PER ROLE AND SITE, AT ADDRESSES ANYONE CAN TYPE. The emails used to carry a slice of
  # the site's own uuid — `tenant1_21893b89@example.com` — so nobody could sign in without reading
  # the database first, and no end-to-end run could know an account before it had seeded one. The
  # roles are `@site_roles`: `admin@<site>.test` holds `*` on its own site, `viewer@<site>.test`
  # holds nothing, and the rest each hold one narrow area, which is what every permission check
  # needs to be seen working.
  #
  # `.test` RATHER THAN THE HOST ITSELF: `admin@localhost` is refused as an address — no dot — and a
  # rule that held for two of the three sites and not the third is worse than one nobody has to
  # remember. It is the TLD reserved for exactly this.
  defp seed_site_users(sites, permission_map) do
    announce("  -> Creating #{Enum.map_join(@site_roles, ", ", &elem(&1, 0))} per site...")

    Map.new(sites, &{&1.id, role_accounts(&1, @site_roles, permission_map)})
  end

  @doc """
  One account per role on `site_id`, at `<role>@<site>.test`, holding the role's names — for an
  extension's dev seed, after installing it has created its names. An account already there is
  reused and granted what it is missing.
  """
  @spec seed_role_accounts(String.t(), [{String.t(), [String.t()]}]) :: [User.t()]
  def seed_role_accounts(site_id, roles) do
    site = Ash.get!(Site, site_id, authorize?: false)
    names = roles |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq()

    permission_map =
      MishkaCmsCore.Accounts.Permission
      |> Ash.Query.filter(name in ^names)
      |> Ash.read!(authorize?: false, page: false)
      |> Map.new(&{&1.name, &1})

    role_accounts(site, roles, permission_map)
  end

  defp role_accounts(site, roles, permission_map) do
    Enum.map(roles, fn {role, names} ->
      email = "#{role}@#{site.name}.test"
      account = existing_user(email, site.id) || create_user(email, site.id)
      Enum.each(names, &assign_permission(account.id, Map.fetch!(permission_map, &1)))
      account
    end)
  end

  # TOPPED UP TO `count`, NOT CREATED `count` TIMES. A layout carries no name the seed chooses — the
  # generator invents one — so there is nothing to recognise a particular row by, and "already
  # there" can only be a number: a site that has as many as this asks for gets none, and a site that
  # has fewer gets the difference. A stress run's sites are new, so for them the difference is still
  # all of them.
  defp seed_layouts(site_id, count) do
    Enum.each(1..(count - held_count(Layout, site_id))//1, fn _i ->
      dev_layout_with_tenant([], site_id)
      |> Ash.Generator.generate()
    end)
  end

  # ONE GLOBAL LAYOUT, found by name like everything else here, so a second run reuses the row a page
  # is already hanging on rather than adding another.
  defp seed_global_layout do
    case global_layout() do
      nil ->
        [
          name: @global_layout_name,
          path: "/global/layouts/plain",
          description: "A layout belonging to no site — any site's page may hang on it.",
          template: @global_layout_template,
          format: :heex,
          priority: 0,
          active: true,
          precompile: false
        ]
        |> layout()
        |> Ash.Generator.generate()

      layout ->
        layout
    end
  end

  defp global_layout do
    Layout
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(name == ^@global_layout_name)
    |> scoped(nil)
    |> rows(1)
    |> List.first()
  end

  # WHAT A SECOND RUN RECOGNISES A PAGE BY is every identity its row has, which
  # `MishkaCmsCore.Runtime.PageProvision` reads off the resource rather than this file naming them.
  # A site that already answers at `/:lang/pricing` keeps whatever it answers with, and a page NAMED
  # `pricing` at an address of its own — which `unique_path_per_site` cannot see and
  # `unique_name_per_site` refuses — is answered by writing this file's page under the next free
  # name. Left to the generator that name was a raise in the middle of the run, and the rest of this
  # site's seed never happened.
  #
  # AND BOTH OF THE THINGS A RERUN CANNOT PASS OVER IN SILENCE ARE SAID — see `announce_pages/1`.
  defp seed_pages(site, config, layouts, site_users) do
    wanted =
      site.id
      |> SeedMedia.images()
      |> config.pages.pages()
      |> Enum.map(&Map.put(&1, :layout_id, layout_id(&1, layouts)))

    site.id
    |> PageProvision.missing(wanted, action: :create)
    |> PageProvision.create(&seed_page(&1, site.id))
    |> announce_pages()

    seed_page_translations(site, wanted, site_users)
  end

  # EVERY PAGE THIS SITE ANSWERS IN `/:lang` MODE ALSO EXISTS IN THE SITE'S OTHER LANGUAGES, as a
  # real sibling row in the same language group — `MishkaCmsCore.Runtime.PageEditions.translate/4`
  # is how a translation is really made, and this calls it rather than a second mechanism of its own.
  #
  # ONLY A LANGUAGE THE SITE ITSELF NAMES, read off the setting rather than off this file's own
  # `@site_configs` — a developer may have changed it, and `/:lang` answers no language its site has
  # not been given (`MishkaCmsCore.Runtime.Languages`). `site-b` names only `["en"]`, so it is asked
  # for zero other languages and none of its pages get a sibling.
  #
  # A PAGE WITH A LITERAL PATH is left alone — no `:lang` or `*lang` capture means nothing here
  # would swap, so `Languages.captures?/1` is the same filter that keeps the no-language demo page
  # (`MishkaCmsCore.Dev.LocalhostPages.pages/1`) from being given a translation it asked not to have.
  #
  # CHECKED AGAINST THE ROW, not against whether this run just wrote it, so a reseed offers a
  # translation to a page an earlier run created before this file learned to write one.
  defp seed_page_translations(site, wanted, site_users) do
    case Languages.site(site.id) -- ["en"] do
      [] ->
        :ok

      languages ->
        admin = site_admin(site_users, site.id)
        by_path = Map.new(wanted, &{&1.path, &1})

        wanted
        |> Enum.filter(&(Languages.captures?(&1.path) and Map.has_key?(&1, :translations)))
        |> Enum.map(& &1.path)
        |> masters(site.id)
        |> Enum.each(&translate_page(&1, by_path, languages, site.id, admin))
    end
  end

  defp site_admin(site_users, site_id) do
    site_users
    |> Map.fetch!(site_id)
    |> Enum.find(&String.starts_with?(to_string(&1.email), "admin@"))
  end

  defp masters(paths, site_id) do
    Page
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(path in ^paths)
    |> scoped(site_id)
    |> rows(200)
  end

  # ONLY A LANGUAGE THIS PAGE WAS ACTUALLY WRITTEN IN. A sibling carrying the English text under a
  # Persian address is not a translation — it is the same page served twice, and the language
  # switcher offering it is a lie. So a page is translated when its definition says what it says in
  # that language, and passed over when it does not.
  defp translate_page(master, by_path, languages, site_id, admin) do
    written = by_path |> Map.fetch!(master.path) |> Map.get(:translations, %{})

    # WRITTEN EVERY RUN, NOT ONLY THE FIRST. Skipping a sibling that merely EXISTS leaves whatever an
    # earlier run put there — and an earlier run put the English text under a Persian address. A
    # reseed is how a developer takes a correction, so the text is written again and the row
    # converges; creating it is the only part that has to happen once.
    for language <- languages, translation = Map.get(written, language) do
      master
      |> edition!(language, site_id, admin)
      |> write!(translation, master, site_id, admin)
    end

    :ok
  end

  # THE SIBLING THIS SITE ALREADY HAS, OR A NEW ONE. Asked of the group rather than of the path, so a
  # translation an admin moved is still found and written to rather than duplicated beside itself.
  defp edition!(master, language, site_id, admin) do
    Page
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(language_group_id == ^master.language_group_id and language == ^language)
    |> scoped(site_id)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> translate!(master, language, PageEditions.translation_path(master, language), admin)
      existing -> existing
    end
  end

  defp translate!(master, language, path, admin) do
    case PageEditions.translate(master, language, path, admin) do
      {:ok, translation} ->
        translation

      {:error, reason} ->
        raise "seeding the #{language} translation of #{master.path} failed: #{inspect(reason)}"
    end
  end

  # A TRANSLATION IS BORN INACTIVE AND HOLDING THE ORIGINAL'S TEXT — `PageEditions.translate/4` says
  # why: until somebody edits it, it is the English page under a Persian address. This IS that edit.
  # The seed writes what the definition says in that language and then publishes it.
  #
  # AS ACTIVE AS ITS MASTER, NOT SIMPLY ACTIVE. `/:lang/coming-soon` ships inactive on purpose — it
  # is what an unpublished page looks like — and an earlier version of this published its Persian
  # sibling regardless, so `/en/coming-soon` 404'd while `/fa/coming-soon` answered. The demo was
  # exactly inverted.
  defp write!(page, translation, master, site_id, admin) do
    attrs =
      translation
      |> Map.take([:name, :title, :description, :template])
      |> Map.put(:active, master.active)

    page
    |> Ash.Changeset.for_update(:update, attrs, actor: admin, tenant: site_id)
    |> Ash.update!()
  end

  # THE LAYOUT IS THE PAGE'S OWN CHOICE, and three of them are worth seeding: this site's
  # `site-main`, the GLOBAL `global-plain`, and none at all — which is what a page meant to be
  # embedded somewhere else wants.
  defp layout_id(page, layouts), do: Map.get(layouts, Map.get(page, :layout, :main))

  defp seed_page(page_config, site_id) do
    [
      name: page_config.name,
      title: page_config.title,
      path: page_config.path,
      section: page_config.section,
      template: page_config.template,
      description: page_config.description,
      format: page_config.format,
      priority: 0,
      extra: %{},
      content: %{},
      seo_tags: [],
      schema: [],
      events: Map.get(page_config, :events, []),
      infos: Map.get(page_config, :infos, []),
      uploads: Map.get(page_config, :uploads, []),
      resource_links: [],
      helpers: [],
      permissions: [],
      active: Map.get(page_config, :active, true),
      layout_id: page_config.layout_id,
      site_id: site_id
    ]
    |> page(site_id)
    |> Ash.Generator.generate()
  end

  # AN EDIT WAITING TO BE PUBLISHED. The builder's draft picker is the one part of the editor a
  # fresh seed left with nothing in it, so the thing it is for — opening somebody's unpublished work
  # beside the live page — could not be seen without making one by hand first.
  #
  # A DRAFT CARRIES THE WHOLE OF THE PAGE IT FORKS, every field the create accepts, because
  # publishing writes the draft's fields back over the live row: a field the draft never took is put
  # back to its default when it is published. `MishkaCmsCore.Runtime.PageSamples` forks a page the
  # same way and for the same reason.
  defp seed_page_draft(%{host: "localhost", id: site_id}) do
    with page when not is_nil(page) <- drafted_page(site_id),
         false <- has_draft?(page) do
      PageDraft
      |> Ash.Changeset.for_create(:master_create, draft_attrs(page), authorize?: false)
      |> Ash.create!()
    end

    :ok
  end

  defp seed_page_draft(_site), do: :ok

  defp drafted_page(site_id) do
    Page
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(path == "/:lang/pricing")
    |> scoped(site_id)
    |> rows(1)
    |> List.first()
  end

  defp has_draft?(page) do
    PageDraft
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(source_page_id == ^page.id)
    |> Ash.exists?(authorize?: false)
  end

  defp draft_attrs(page) do
    PageDraft
    |> Ash.Resource.Info.action(:create)
    |> Map.fetch!(:accept)
    |> then(&[:site_id | &1])
    |> Map.new(&{&1, Map.get(page, &1)})
    |> Map.merge(%{
      label: "Half-price week",
      template: String.replace(page.template, ">Pricing<", ">Pricing, half price<"),
      source_page_id: page.id,
      priority: page.priority || 0
    })
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # A page written under another name is there, but not under the name this file asks for, and a
  # developer looking for `pricing` in the page list would not find it; a page left alone at an
  # address the site does not answer is not there at all, and no later run will write it. The rest —
  # every page on every rerun — is the site answering where it should, and announcing those would
  # bury both.
  defp announce_pages(%{renamed: renamed, skipped: skipped} = report) do
    announce_provision(renamed, skipped)
    report
  end

  defp announce_pages(%{renamed_pages: renamed, skipped_pages: skipped} = report) do
    announce_provision(renamed, skipped)
    report
  end

  defp announce_provision(renamed, skipped) do
    Enum.each(renamed, &announce("  -> Named #{PageProvision.note(&1)}"))

    skipped
    |> Enum.reject(&PageProvision.answered?/1)
    |> Enum.each(&announce("  -> No page at #{PageProvision.note(&1)}"))
  end

  defp seed_error_pages(site_id, count) do
    Enum.each(1..count, fn _i ->
      dev_error_page([], site_id)
      |> Ash.Generator.generate()
    end)
  end

  @site_js_hooks [
    %{
      name: "console-logger",
      description: "Logs lifecycle events and click interactions to the browser console.",
      priority: 10,
      content: ~S"""
      export default {
        mounted() {
          console.log("[ConsoleLogger] mounted on", this.el.id || this.el.tagName);
          this.handleClick = (event) => {
            console.log("[ConsoleLogger] click", {
              id: this.el.id,
              target: event.target.tagName,
              at: new Date().toISOString()
            });
          };
          this.el.addEventListener("click", this.handleClick);
        },
        destroyed() {
          console.log("[ConsoleLogger] destroyed", this.el.id);
          this.el.removeEventListener("click", this.handleClick);
        }
      };
      """
    },
    %{
      name: "clipboard",
      description:
        "Copies text to clipboard on click. Reads from `data-clipboard-text` or element text.",
      priority: 20,
      content: ~S"""
      export default {
        mounted() {
          this.handleClick = async (event) => {
            event.preventDefault();
            const text = this.el.dataset.clipboardText || this.el.textContent.trim();
            try {
              await navigator.clipboard.writeText(text);
              const original = this.el.dataset.originalLabel || this.el.innerText;
              this.el.dataset.originalLabel = original;
              this.el.innerText = "Copied!";
              setTimeout(() => { this.el.innerText = original; }, 1500);
            } catch (err) {
              console.error("[Clipboard] copy failed", err);
            }
          };
          this.el.addEventListener("click", this.handleClick);
        },
        destroyed() {
          this.el.removeEventListener("click", this.handleClick);
        }
      };
      """
    }
  ]

  @global_js_hooks [
    %{
      name: "simple-console-logger",
      description: "Global page-init logger. Prints a boot message when the element mounts.",
      priority: 5,
      content: ~S"""
      export default {
        mounted() {
          console.log("[SimpleConsoleLogger] page initialized — hook active on", this.el.id || "unnamed element");
        },
        destroyed() {
          console.log("[SimpleConsoleLogger] element removed", this.el.id);
        }
      };
      """
    }
  ]

  # THE NAME IS THE HOOK, in the database (`unique_name_per_site`) and in the browser alike: it is
  # what `JavaScriptCompiler.browser_name/2` turns into the `phx-hook` a page names. So a site that
  # has `console-logger` keeps the code it has, and a second run only fills in whichever of the two
  # are not there.
  defp seed_js_hooks(site_id, _count) do
    create_js_hooks(@site_js_hooks, site_id)
  end

  defp seed_global_js_hooks do
    announce("  -> Creating #{length(@global_js_hooks)} global JS hook(s)...")

    create_js_hooks(@global_js_hooks, nil)
  end

  defp create_js_hooks(hooks, site_id) do
    held = held_names(JsHook, site_id, Enum.map(hooks, & &1.name))

    hooks
    |> Enum.reject(&MapSet.member?(held, &1.name))
    |> Enum.each(fn hook ->
      [
        name: hook.name,
        description: hook.description,
        content: hook.content,
        format: :js,
        priority: hook.priority,
        active: true,
        permissions: []
      ]
      |> js_hook(site_id)
      |> Ash.Generator.generate()
    end)
  end

  # FILES, NOT ROWS DESCRIBING FILES. Every media row here used to be invented — a name, a random
  # size and a path like `/uploads/images/3.jpg` that nothing had ever written — so the library drew
  # its type glyph in place of every thumbnail, the builder's media sheet offered pictures that
  # answered 404 wherever a page used one, and a seeded site could not show what a media library
  # looks like with media in it. `MishkaCmsCore.Dev.SeedMedia` copies the files the repository ships
  # into this site's uploads the way an upload lands, and each row describes its own copy.
  #
  # NOTHING STORED IS TWO DIFFERENT ANSWERS, which is why the set is asked about as well as the
  # install. `install/1` returns the rows THIS run wrote, and on a second run that is legitimately
  # `[]` — the library is complete, not empty. Reading the one as the other told the developer who
  # reseeded to pick up new pictures that they had none, once per site.
  defp seed_media(site_id) do
    case {MishkaCmsCore.Dev.SeedMedia.files(), MishkaCmsCore.Dev.SeedMedia.install(site_id)} do
      {[], _stored} -> announce("  -> No dev seed media files found — the library is empty.")
      {_files, []} -> announce("  -> Media library already complete — nothing added.")
      {_files, stored} -> announce("  -> Stored #{length(stored)} media file(s).")
    end
  end

  # THE STRESS SEED WRITES NO FILES. It exists to put a hundred rows per site in front of the
  # pagination and the filters, and a hundred real files per site — three hundred thousand of them
  # at the default site count — is not a thing to write to a developer's disk. The rows therefore
  # carry paths nothing answers, which is what the admin's type glyph is the fallback for; a run
  # that wants pictures is the dev seed above.
  defp seed_stress_media(site_id, category_count, media_count) do
    category_names = [
      "Images",
      "Videos",
      "Documents",
      "Icons",
      "Logos",
      "Banners",
      "Thumbnails",
      "Backgrounds",
      "Avatars",
      "Infographics"
    ]

    categories =
      Enum.map(1..category_count, fn i ->
        [
          name:
            "#{Enum.at(category_names, rem(i - 1, length(category_names)))} #{String.slice(site_id, 0, 6)}",
          description: "Media category #{i}"
        ]
        |> media_category(site_id)
        |> Ash.Generator.generate()
      end)

    types = [
      {:images, "jpg"},
      {:images, "png"},
      {:videos, "mp4"},
      {:documents, "pdf"},
      {:documents, "docx"}
    ]

    Enum.each(1..media_count, fn i ->
      cat = Enum.random(categories)
      {type, format} = Enum.random(types)

      [
        name: "media_#{i}_#{String.slice(site_id, 0, 6)}",
        type: type,
        size: :rand.uniform(10_000_000),
        format: format,
        relative_path: "/uploads/#{type}/#{i}.#{format}",
        featured: rem(i, 10) == 0,
        dimensions: %{},
        description: "Dev media file #{i}",
        media_category_id: cat.id
      ]
      |> media(site_id)
      |> Ash.Generator.generate()
    end)
  end

  defp seed_stress_sites(count) do
    announce("  -> Creating #{count} sites...")

    Enum.map(1..count, fn i ->
      dev_site(name: "stress-site-#{i}", host: "stress-site-#{i}.mishka.tools")
      |> Ash.Generator.generate()
    end)
  end

  defp seed_stress_master_users(count) do
    announce("  -> Creating #{count} master users...")

    Enum.map(1..count, fn i ->
      [
        email: "stressmaster#{i}@example.com",
        password: "Password123!",
        password_confirmation: "Password123!"
      ]
      |> user()
      |> Ash.Generator.generate()
    end)
  end

  defp seed_stress_tenant_users(sites, per_site) do
    announce("  -> Creating #{per_site} tenant users per site...")

    Enum.reduce(sites, %{}, fn site, acc ->
      users =
        Enum.map(1..per_site, fn i ->
          [
            email: "stresstenant#{i}_#{String.slice(site.id, 0, 8)}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!"
          ]
          |> user(site.id)
          |> Ash.Generator.generate()
        end)

      Map.put(acc, site.id, users)
    end)
  end

  # ---------------------------------------------------------------------------
  # What is already there
  # ---------------------------------------------------------------------------

  # WHICH OF `names` THIS SCOPE ALREADY HOLDS, ARCHIVED ROWS INCLUDED, read once for a step rather
  # than once for every row in it.
  #
  # Two actions, because one read cannot answer for both: `:read_any` carries AshArchival's filter
  # and `:master_archived` is the one action excluded from it. An archived row counts as present
  # deliberately — writing beside it would hand back the row an admin threw away, and the unique
  # indexes are partial on `archived_at IS NULL`, so nothing else would stop that happening.
  #
  # Both bypass the tenant, which is what lets the same pair answer for a site and for the global
  # rows (`site_id` nil) this seed also writes. Both are read to the LAST page, because one page is
  # not the whole answer: `names` bounds the live rows — the name is unique per site — but the
  # unique indexes are partial on `archived_at IS NULL`, so one name can have any number of archived
  # rows behind it, and enough of them crowded another name off a page sized by the names asked
  # about. That name looked absent and was written again, which is the duplication this whole
  # section exists to stop. `page: false` is not the shortcut: these actions require a page.
  #
  # ASKED UNDER THE NAME THE ROW IS STORED WITH, not the one the seed wrote. Every create action on
  # these resources carries `slugify(:name, into: :name)`, so the name in the database is the slug of
  # what was handed to it — the same correction
  # `MishkaCmsCore.Runtime.Resources.Validations.StatefulPlacement` makes when it asks about a
  # component. The answer comes back in the caller's spelling, because that is what the caller has to
  # compare against.
  defp held_names(resource, site_id, names) do
    stored = Map.new(names, &{Slug.slugify(&1), &1})

    [:read_any, :master_archived]
    |> Enum.flat_map(fn action ->
      resource
      |> Ash.Query.for_read(action, %{}, authorize?: false)
      |> Ash.Query.filter(name in ^Map.keys(stored))
      |> scoped(site_id)
      |> Ash.Query.select([:name])
      |> rows(map_size(stored))
    end)
    |> MapSet.new(&Map.fetch!(stored, &1.name))
  end

  # Counted rather than listed, for the steps whose rows carry no name this seed chose and whose
  # "already there" can only be a number.
  defp held_count(resource, site_id) do
    [:read_any, :master_archived]
    |> Enum.map(fn action ->
      resource
      |> Ash.Query.for_read(action, %{}, authorize?: false)
      |> scoped(site_id)
      |> Ash.count!(authorize?: false)
    end)
    |> Enum.sum()
  end

  defp rows(_query, 0), do: []

  defp rows(query, limit) do
    query
    |> Ash.read!(authorize?: false, page: [limit: limit])
    |> every_page()
  end

  # A PAGE THAT CARRIED SOMETHING is what earns the next one. `Ash.page/2` answers a keyset page with
  # no results with itself, so a page claiming `more?` over nothing would be asked for its successor
  # for ever; this clause cannot match it, and the read stops on whatever it has.
  defp every_page(%{results: [_first | _rest] = found, more?: true} = page),
    do: found ++ every_page(Ash.page!(page, :next))

  defp every_page(%{results: found}), do: found
  defp every_page(found) when is_list(found), do: found

  # `site_id == ^nil` is not `is_nil(site_id)` — `Ash.Query.Operator.Eq` answers nil for a nil side,
  # which reaches Postgres as `= NULL` and matches no row at all. A global row would then look
  # missing every time and be written again on every run.
  defp scoped(query, nil), do: Ash.Query.filter(query, is_nil(site_id))
  defp scoped(query, site_id), do: Ash.Query.filter(query, site_id == ^site_id)

  @doc """
  Prints a seeding progress line, unless `config :mishka_cms_core, seed_announce: false`.

  Public because every extension seeds through its own `Dev.Seeds` and they all need the same switch —
  a suite that turned it off for the core seeder but still had extensions writing straight to stdout
  would fill the test output with progress it cannot silence.
  """
  def announce(message) do
    if Application.get_env(:mishka_cms_core, :seed_announce, true), do: IO.puts(message)
  end
end
