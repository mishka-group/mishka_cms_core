# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Install.Bootstrap do
  @moduledoc """
  Runs the first-run install: creates every permission name of `permissions/0` that is missing,
  grants `"*"` to the master user (auto-confirmed, no email), creates the first (master) site,
  installs the chosen Chelekom components, writes the site's starter content — the theme, the
  header, the footer, the `site-main` layout and the home page
  (`MishkaCmsCore.Install.StarterContent.seed!/2`) — and its sign-in pages
  (`MishkaCmsCore.Install.StarterContent.ensure_auth!/1`), compiles the new site's runtime —
  exactly as a normal boot would — and flips the install flag. A name already stored is left as it
  is, so re-running after seeds is safe.

  THE STARTER IS NOT A CHOICE. Every page of a site, an extension's included, is drawn in the
  `site-main` layout (`MishkaCmsCore.Runtime.SiteLayout`), so a site without it has no frame for
  any of them; and a first install whose `/` answers nothing is a broken one. The installer's box
  says so and cannot be unticked.

  Everything runs `authorize?: false` because no privileged actor exists yet — which is why
  this is reachable only while the CMS is uninstalled (`MishkaCms.Plugs.InstallGate`).

  THE PHASES ARE PARTS on `installer:seed` (`MishkaCmsCore.Install.Seeds`): the core's own
  (`MishkaCmsCore.Install.CoreSeed`, each one `run_part/4` here) in the order above, then the
  chosen `:prod` parts of every other plugin on the new site, an extension's "pages" part through
  `MishkaCmsCore.Install.Extensions.install/4`. The compile and the install flag come last, after
  every part. The installer renders one progress row per entry of `steps/1`, so a part a plugin
  declares appears in it without a line here.

  The master user is created via the existing `register_with_password` strategy action (which mints
  the token and hashes the password); with no tenant the user stays `site_id: nil` (a master), and
  `authorize?: false` relaxes the master-creation policy. The master is confirmed in-place and the
  changeset is tagged with `mishka_install: true` so the confirmation sender skips the email (see
  `MishkaCmsCore.Accounts.User.Senders.SendNewUserConfirmationEmail`).

  Essential settings are written through the `Settings` façade with the category/source declared for
  each key in the registry, so each lands on the right tab of the settings page; unregistered keys
  are ignored.

  The site's languages (`:languages`, codes `MishkaCmsCore.Runtime.Languages.valid?/1` accepts, the
  first being the primary) are saved to the new site's own `site.languages` before any page is
  written, so every page the install writes answers each of them. A run given none leaves the site
  reading the global list. How its addresses name them (`:language_urls`, one of
  `MishkaCmsCore.Runtime.Languages.url_modes/0`) is saved beside them to its own
  `site.language_urls`; a run given none leaves the site reading the global setting.

  See `MishkaCmsCore.Install`.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}

  alias MishkaCmsCore.Install.{Seeds, StarterContent}
  alias MishkaCmsCore.Runtime.Handlers.{BootHandler, UiKitHandler}
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.Site
  alias MishkaCmsCore.Settings

  require Ash.Query

  @type params :: %{
          required(:email) => String.t(),
          required(:password) => String.t(),
          required(:site_name) => String.t(),
          required(:host) => String.t(),
          optional(:component_selection) => map(),
          optional(:languages) => [String.t()],
          optional(:language_urls) => String.t(),
          optional(:settings) => %{optional(String.t()) => term()},
          optional(:parts) => Seeds.picks(),
          optional(:answers) => %{optional(String.t()) => map()}
        }

  @permissions [
    {"*",
     "Every permission within the holder's own site. For a master that means every site. It never makes anyone a master."},
    {"admin:*", "Full admin of the dashboard and the API."},
    {"admin:dashboard:*", "Full dashboard admin: every dashboard area, every builder and code."},
    {"admin:api:*", "Full API admin: every admin JSON:API and GraphQL area, and code."},
    {"admin:dashboard:runtime:*",
     "Every runtime section on the dashboard, their code included, and opening every builder."},
    {"admin:dashboard:runtime:site",
     "The Sites screen and site data: read, create, edit and archive. A site-wide action still needs a master."},
    {"admin:dashboard:runtime:page",
     "Writing pages, their drafts and versions, their code included, and opening the page builder."},
    {"admin:dashboard:runtime:layout",
     "Writing layouts, their drafts and versions, their code included, and opening the layout builder."},
    {"admin:dashboard:runtime:component",
     "Writing components and their versions, their code included, and opening the component builder."},
    {"admin:dashboard:runtime:error_page",
     "Writing error pages, their drafts and versions, their code included, and opening the error page builder."},
    {"admin:dashboard:runtime:stylesheet", "Writing stylesheets, their CSS included."},
    {"admin:dashboard:runtime:js_hook", "Writing JS hooks, their content included."},
    {"admin:dashboard:runtime:media",
     "Writing media, media categories and their versions. Every dashboard admin reads them."},
    {"admin:dashboard:runtime:translation",
     "Writing translation rows. Every dashboard admin reads them."},
    {"admin:dashboard:runtime:redirect",
     "Writing the site's redirect rules. Every dashboard admin reads them."},
    {"admin:dashboard:runtime:head_code",
     "Writing the code a site's public pages carry in their head, and the origins it adds to the site's Content Security Policy. Masters only."},
    {"admin:dashboard:setting",
     "Writing site settings that declare no permission of their own, the extension switches and the notification toggles included."},
    {"admin:dashboard:user",
     "The Users screen: list, read, create, edit and delete the accounts of the holder's own site."},
    {"admin:dashboard:permission",
     "The Permissions screen: read the permission names, and grant or revoke permissions within what the holder holds."},
    {"admin:dashboard:runtime:activity",
     "The Activity screen, activity entries and the recent-activity widget."},
    {"admin:dashboard:code",
     "Writing pages, layouts, components, error pages, stylesheets and JS hooks, their code included, and opening every builder."},
    {"admin:dashboard:agent:receipts",
     "Reading agent receipts on the dashboard, for the areas the holder already holds."},
    {"admin:api:runtime:*",
     "Every runtime section over the admin JSON:API, their code included."},
    {"admin:api:runtime:site", "Site data over the admin JSON:API."},
    {"admin:api:runtime:page", "Writing pages over the admin JSON:API, their code included."},
    {"admin:api:runtime:layout", "Writing layouts over the admin JSON:API, their code included."},
    {"admin:api:runtime:component",
     "Writing components over the admin JSON:API, their code included."},
    {"admin:api:runtime:error_page",
     "Writing error pages over the admin JSON:API, their code included."},
    {"admin:api:runtime:stylesheet",
     "Writing stylesheets over the admin JSON:API, their CSS included."},
    {"admin:api:runtime:js_hook",
     "Writing JS hooks over the admin JSON:API, their content included."},
    {"admin:api:runtime:media", "Writing media and media categories over the admin JSON:API."},
    {"admin:api:runtime:translation", "Writing translations over the admin JSON:API."},
    {"admin:api:runtime:redirect", "Writing redirect rules over the admin JSON:API."},
    {"admin:api:user", "Accounts over the admin JSON:API."},
    {"admin:api:permission", "The permission names and the grants over the admin JSON:API."},
    {"admin:api:runtime:activity", "The activity log over the admin JSON:API."},
    {"admin:api:agent:receipts",
     "Reading agent receipts over the API, for the areas the holder already holds."},
    {"admin:api:code",
     "Writing pages, layouts, components, error pages, stylesheets and JS hooks over the admin JSON:API, their code included."}
  ]

  # AFTER EVERY PART, an extension's included: the compile turns every row the install wrote into
  # modules, and the flag closes the installer.
  @finish [
    {"compile", gettext_noop("Compiling the site runtime")},
    {"finalize", gettext_noop("Finishing up")}
  ]

  @doc """
  Every permission name the core install creates, with its description. An extension's own names
  are not here: its provision manifest ships them, and installing it creates them
  (`MishkaCmsCore.Runtime.ExtensionProvision`).
  """
  @spec permissions() :: [{String.t(), String.t()}]
  def permissions, do: @permissions

  @doc """
  Creates each name of `permissions` (the core's, `permissions/0`, when none are given) that is not
  stored yet. Returns every one of them, stored before or now, and the ones this call created. A
  stored name keeps its row and its description.
  """
  @spec ensure_permissions([{String.t(), String.t()}]) ::
          {:ok, %{stored: [Permission.t()], created: [Permission.t()]}} | {:error, term()}
  def ensure_permissions(permissions \\ @permissions) do
    names = Enum.map(permissions, &elem(&1, 0))

    with {:ok, stored} <-
           Permission
           |> Ash.Query.filter(name in ^names)
           |> Ash.read(authorize?: false, page: false) do
      held = MapSet.new(stored, & &1.name)

      permissions
      |> Enum.reject(fn {name, _description} -> MapSet.member?(held, name) end)
      |> Enum.reduce_while({:ok, []}, &create_permission/2)
      |> case do
        {:ok, created} -> {:ok, %{stored: stored ++ created, created: Enum.reverse(created)}}
        error -> error
      end
    end
  end

  defp create_permission({name, description}, {:ok, created}) do
    Permission
    |> Ash.Changeset.for_create(:create, %{name: name, description: description},
      authorize?: false
    )
    |> Ash.create()
    |> case do
      {:ok, permission} -> {:cont, {:ok, [permission | created]}}
      # ANOTHER RUN GOT THERE FIRST: two sites installing the same extension at once both find
      # a name missing, and the second create meets the unique name the first wrote.
      {:error, _error} = error -> stored_meanwhile(name, created, error)
    end
  end

  defp stored_meanwhile(name, created, error) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, %Permission{}} -> {:cont, {:ok, created}}
      _not_there -> {:halt, error}
    end
  end

  @doc """
  The ordered install rows for the chosen `parts` (`t:MishkaCmsCore.Install.Seeds.picks/0`; `nil`
  for the required and default ones), as `{row, label}`: one per part, then the compile and the
  install flag.
  """
  @spec steps(Seeds.picks()) :: [{Seeds.row(), String.t()}]
  def steps(parts \\ nil) do
    rows = Seeds.steps(:prod, parts) ++ Enum.map(@finish, fn {id, label} -> {row(id), label} end)
    Enum.map(rows, fn {row, label} -> {row, Gettext.gettext(MishkaCmsCore.Gettext, label)} end)
  end

  @doc """
  Runs the install, calling `progress` with `{row, status, detail}` as each row starts
  (`:running`), emits a line (`:log`), finishes (`:done`) or fails (`:error`). Returns
  `{:ok, %{user: user, site: site}}` or `{:error, reason}` from the first required part that failed.
  `run/1` keeps the silent behaviour for non-interactive callers (seeds, tests).

  The form fields of `params` are the core's own answers; `:answers` holds each other plugin's,
  by key, and `:parts` what was chosen. The password travels as a function returning it, so a
  plugin's crash report never prints it.
  """
  @spec run(params(), (term() -> any())) :: {:ok, %{user: map(), site: map()}} | {:error, term()}
  def run(params, progress \\ fn _ -> :ok end) do
    answers = params |> Map.get(:answers, %{}) |> Map.put(Seeds.core_key(), core_answers(params))

    case Seeds.run(:prod, Map.get(params, :parts), answers: answers, progress: progress) do
      {:ok, %{site: site, user: user}} ->
        finish(site, progress)
        {:ok, %{user: user, site: site}}

      # NO SITE AND NO MASTER means the core's own plugin is not running, and an install that wrote
      # neither must not be flagged as done.
      {:ok, _foundation} ->
        {:error, :core_parts_not_running}

      {:error, _reason} = error ->
        error
    end
  end

  defp core_answers(params) do
    params
    |> Map.drop([:parts, :answers])
    |> Map.update(:password, nil, fn password -> fn -> password end end)
  end

  defp finish(site, progress) do
    progress.({row("compile"), :running, nil})
    BootHandler.compile_site(site.id, site.name)
    progress.({row("compile"), :done, nil})

    progress.({row("finalize"), :running, nil})
    MishkaCmsCore.Install.mark_installed!()
    progress.({row("finalize"), :done, nil})
  end

  defp row(id), do: {Seeds.core_key(), id}

  @doc """
  Runs the core's production `part` (`MishkaCmsCore.Install.CoreSeed`) with the installer's
  `answers`, on the `foundation` the parts before it built, and returns what it adds to the
  foundation. `progress` takes a line for the part's row.
  """
  @spec run_part(String.t(), map(), map(), (String.t() -> any())) ::
          {:ok, map()} | {:error, term()}

  # EVERY CORE NAME, so an operator can grant a narrow admin without creating the name first. An
  # extension's names arrive with it, in its own part or when it is set up later.
  def run_part("permissions", _answers, _foundation, _progress) do
    with {:ok, %{stored: stored}} <- ensure_permissions() do
      {:ok, %{permissions: stored, star: Enum.find(stored, &(&1.name == "*"))}}
    end
  end

  def run_part("master_user", answers, foundation, _progress) do
    with {:ok, user} <- create_master_user(answers),
         :ok <- grant_permission(user, foundation.star) do
      {:ok, %{user: user, users: %{master: [user], tenant: %{}}}}
    end
  end

  def run_part("site", answers, _foundation, _progress) do
    with {:ok, site} <- create_site(answers), do: {:ok, %{site: site, sites: [site]}}
  end

  # BEFORE THE STARTER PAGES AND THE EXTENSIONS, so every page written after it answers each of
  # these languages. Fires `installer:languages:saved` with the site id and the saved list.
  def run_part("languages", %{languages: languages} = answers, %{site: site}, progress) do
    with :ok <- valid_languages(languages),
         {:ok, saved} <-
           Settings.put("site.languages", languages, site_id: site.id, category: "general"),
         :ok <- save_language_urls(answers, site) do
      MishkaInstaller.Event.Hook.call(
        "installer:languages:saved",
        %{site_id: site.id, languages: saved},
        return: false
      )

      progress.(Languages.names(saved))
      {:ok, %{}}
    end
  end

  def run_part("languages", answers, %{site: site}, _progress) do
    with :ok <- save_language_urls(answers, site), do: {:ok, %{}}
  end

  def run_part("settings", answers, _foundation, _progress) do
    apply_settings(Map.get(answers, :settings, %{}))
    {:ok, %{}}
  end

  def run_part("components", answers, _foundation, progress) do
    selection = Map.get(answers, :component_selection, %{})
    components = Map.get(selection, :components, [])

    if components != [],
      do:
        progress.(
          ngettext(
            "Installing %{count} component…",
            "Installing %{count} components…",
            length(components)
          )
        )

    install_components(selection)

    if components != [],
      do:
        progress.(
          ngettext(
            "%{count} component installed",
            "%{count} components installed",
            length(components)
          )
        )

    {:ok, %{}}
  end

  # BEFORE THE COMPILE, because that is what turns the rows just written into modules and a
  # stylesheet, and before the extensions, whose pages hang on the layout it writes. Always: see
  # "The starter is not a choice" above. An install migrating its own content replaces the home
  # page; the frame is what every page of it is drawn in.
  def run_part("starter_content", answers, %{site: site}, progress) do
    # THE NAME AS TYPED. `Site :create` slugifies it, so the row says `acme-docs` where the user
    # wrote "Acme Docs" — the tenant key, and not what belongs in the header of their first page.
    report = StarterContent.seed!(site, brand: answers[:site_name])

    progress.(
      ngettext(
        "%{pages} page, %{components} components",
        "%{pages} pages, %{components} components",
        length(report.pages),
        pages: length(report.pages),
        components: length(report.components)
      )
    )

    {:ok, %{}}
  end

  # A SITE WITH NO SIGN-IN PAGE LETS NOBODY SIGN IN, its master included. Before the compile, which
  # turns them into modules, and after the settings, whose languages decide which built-in words are
  # written.
  def run_part("auth_pages", _answers, %{site: site}, progress) do
    report = StarterContent.ensure_auth!(site)

    progress.(
      gettext("%{pages} sign-in pages, %{translations} translated words",
        pages: length(report.pages),
        translations: report.translations
      )
    )

    {:ok, %{}}
  end

  defp valid_languages(languages) do
    if Languages.valid?(languages), do: :ok, else: {:error, {:invalid_languages, languages}}
  end

  defp save_language_urls(%{language_urls: mode}, site) do
    with {:ok, mode} <- language_urls(mode),
         {:ok, _saved} <-
           Settings.put("site.language_urls", mode, site_id: site.id, category: "general"),
         do: :ok
  end

  defp save_language_urls(_params, _site), do: :ok

  defp language_urls(mode) do
    if mode in Languages.url_modes(),
      do: {:ok, mode},
      else: {:error, {:invalid_language_urls, mode}}
  end

  defp create_master_user(%{email: email, password: secret}) do
    password = if is_function(secret, 0), do: secret.(), else: secret

    User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{email: email, password: password, password_confirmation: password},
      authorize?: false
    )
    |> Ash.Changeset.set_context(%{mishka_install: true})
    |> Ash.Changeset.force_change_attribute(:confirmed_at, DateTime.utc_now())
    |> Ash.create()
  end

  defp grant_permission(user, permission) do
    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, permission.id)
    |> Ash.create!(authorize?: false)

    :ok
  end

  # `auth_pages: :inline` — the `:auth_pages` step writes the sign-in pages, so no job is enqueued.
  defp create_site(%{site_name: name, host: host}) do
    Site
    |> Ash.Changeset.for_create(:create, %{name: name, host: host, master: true},
      authorize?: false,
      context: %{auth_pages: :inline}
    )
    |> Ash.create()
  end

  defp install_components(selection) when map_size(selection) == 0, do: :ok
  defp install_components(%{components: []}), do: :ok

  # A per-kit selection — `%{"chelekom" => %{components: […]}}` — installs each named kit and nothing
  # else. A flat one is the single-kit shape the installer used before more than one existed, and
  # goes to Chelekom.
  defp install_components(%{components: _components} = selection) do
    UiKitHandler.install_chelekom!(site_id: nil, selection: selection)
    :ok
  end

  defp install_components(by_kit) do
    UiKitHandler.install_kits!(Map.keys(by_kit), site_id: nil, selection: by_kit)
    :ok
  end

  defp apply_settings(settings) when map_size(settings) == 0, do: :ok

  defp apply_settings(settings) do
    by_key = Map.new(Settings.definitions(), &{&1.key, &1})

    Enum.each(settings, fn {key, value} ->
      case Map.get(by_key, key) do
        nil ->
          :ok

        definition ->
          Settings.put(key, value, category: definition.category, source: definition.source)
      end
    end)
  end
end
