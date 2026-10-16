# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Install.Extensions do
  @moduledoc """
  Which extensions can install themselves onto a site, and the one call that asks one to.

  ## There is no registry here, because there already is one

  An earlier draft of this invented a second event to ask "who is installable?". It was not needed:
  `MishkaInstaller.Event.Event` IS that registry. A plugin subscribing to `installer:extension:install`
  has already told the installer it exists, under which OTP app, at which priority, depending on
  which other events, and whether an operator has switched it off — all persisted, all read back
  with one call.

  So SUBSCRIBING IS DECLARING. `installable/0` reads the records; nothing is kept in sync by hand,
  and an extension that is not installed cannot appear in a list it never registered with.

  What each record carries, and what we do NOT write ourselves:

  | we need | the record's field |
  | --- | --- |
  | which extension | `:extension`, the OTP app |
  | what to call it on screen | `:extra`, below |
  | the order to offer them in | `:priority` |
  | switched off everywhere | `:status` |
  | one extension before another | `:depends`, with cycles already refused |

  ## `:extra` is the only shape we define

  `Event.register/3` takes it from the plugin's own `initial:` and re-reads it on every upgrade, so
  a label changed in a new release reaches installs that registered under the old one:

      use MishkaInstaller.Event.Hook,
        event: "installer:extension:install",
        initial: %{
          priority: 50,
          extra: [%{label: "Blog", summary: "Posts, categories, tags and their pages", fields: []}]
        }

  `fields` is `[]` for an extension that needs nothing asked, and a list of
  `%{name:, label:, type:, required?:}` for one that does — the installer draws them and hands the
  answers back in `install/4`.

  ## Installing

  `install/4` fires the event once. Every subscribed plugin sees it and ignores a `key` that is not
  its own; the one whose key it is appends its report to `:reports`. That is the plain
  `MishkaInstaller` transform chain — the payload goes out, comes back, and what came back is what
  the screen shows.

  ## The payload

      %{
        site_id: "…",   # the site to install onto
        key: "…",       # whose install this is; a plugin ignores any other
        answers: %{},   # what the operator typed for this extension's own `fields`
        reports: [],    # where the plugin whose key it is appends its report
        ask: :install,  # or `:status`: "is it already here?", writing only the extension's
                        # permission names when it is
        actor: user     # OR `nil`
      }

  `:actor` IS PART OF THE CONTRACT, not a convenience. A plugin must hand it to whatever writes —
  `MishkaCmsCore.Runtime.ExtensionProvision.ensure!/4` takes it as `actor:` — so the rows land under
  the resource's own policy and the version history says who asked for them. `nil` means there is no
  session behind the call, which is true of the installer wizard and of the dev seeds, and those
  write as the system. The extension's permission names are the one exception: a name is shared by
  every site and creating one is a master's action, so the system writes them whoever asked.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  require Logger

  alias MishkaCmsCore.Runtime.PageProvision
  alias MishkaCmsCore.Settings
  alias MishkaInstaller.Event.Event
  alias MishkaInstaller.Event.Hook

  @event "installer:extension:install"

  # A plugin the operator has switched off, or one the installer is holding because something it
  # depends on is not running, is not offered — `Hook.call/2` would not reach it either, and a row in
  # a picker that does nothing when ticked is worse than no row.
  @offerable [:registered, :started, :restarted]

  @typedoc """
  One extension that can install itself. `key` is the OTP app as a string, which is what
  `install/4` is given back and what a plugin matches on.
  """
  @type entry :: %{
          key: String.t(),
          app: atom(),
          plugin: module(),
          label: String.t(),
          summary: String.t(),
          fields: [map()],
          status: atom(),
          priority: integer()
        }

  @doc "The event an extension subscribes to in order to be installable."
  @spec event() :: String.t()
  def event, do: @event

  @doc """
  Every extension registered against the event, whatever its status, in the order they are offered.

  Use `offered/0` for the list a picker should draw; this one is for a screen that has to explain
  why something is missing from it.
  """
  @spec installable() :: [entry()]
  def installable do
    :event
    |> Event.get(@event)
    |> List.wrap()
    |> Enum.map(&entry/1)
    |> Enum.sort_by(&{&1.priority, &1.label})
  end

  @doc "The extensions a picker should draw — `installable/0` without the ones nothing would reach."
  @spec offered() :: [entry()]
  def offered, do: Enum.filter(installable(), &(&1.status in @offerable))

  @doc """
  Asks the extension named by `key` to install itself onto `site_id`, and returns what it did.

  `answers` are the values the operator typed for the extension's own `fields`, empty for one that
  asked for none. The return is the extension's report — `%{permissions:, components:, pages:,
  snippets:, renamed_pages:, skipped_pages:}` — or `{:error, reason}` when no plugin answered to that key, so
  a caller can say "nothing installed it" rather than "it worked and did nothing".
  """
  @spec install(String.t(), String.t() | atom(), map(), map() | nil) ::
          {:ok, PageProvision.report() | map()} | {:error, term()}
  def install(site_id, key, answers \\ %{}, actor \\ nil) when is_binary(site_id) do
    payload = %{
      site_id: site_id,
      key: to_string(key),
      answers: answers,
      reports: [],
      ask: :install,
      # WHO PRESSED IT, carried to the extension that does the writing. The installer's own wizard
      # runs before there is a user and sends nothing; a dashboard sends the session's, and every
      # row the extension writes is then written as them.
      actor: actor
    }

    case @event |> Hook.call(payload) |> reports(payload) do
      [%{error: message}] ->
        # A PLUGIN THAT CAUGHT ITS OWN FAILURE STILL FAILED. It rescues so that one extension cannot
        # take the installer down with it, and says so in the report — which a caller must read as a
        # refusal, or a screen says "installed" over a site that got half of it.
        {:error, {:extension_failed, message}}

      [report] ->
        # MARKED AFTER IT RAN, and only when it ran. A site whose install raised keeps looking like
        # what it is — not set up — so its menu goes on offering to finish rather than opening a
        # dashboard onto pages that are not there.
        mark_installed!(site_id, key, Map.get(report, :version), actor)

        {:ok, report}

      [] ->
        {:error, :no_plugin_answered}

      [_ | _] = many ->
        # TWO PLUGINS ANSWERING TO ONE KEY is a mistake in whichever of them took a name that is not
        # its app's, and taking the first would hide it. The install already happened — both of them
        # ran — so this says so rather than pretending one did.
        Logger.error("[Installer] #{length(many)} plugins answered to #{inspect(key)}")
        {:error, {:several_plugins_answered, length(many)}}
    end
  end

  @doc """
  The settings an extension's `settings:register` plugin should add so its own tab carries both of
  the per-site answers this module reads.

      Settings.definitions() ++ Extensions.settings(:mishka_blog, "blog")

  There are two of them and they are not the same question:

    * `<app>.installed` is STATE — the version this site was set up at, or blank for a site that
      never was. It is what decides whether the extension's menu opens on its dashboard or on its
      installer, so it is not editable: an admin typing a version into it would claim an install
      that never happened. `mark_installed!/4` writes it.
    * `<app>.active` is a PREFERENCE — the switch that hides the extension from this site. Off is
      not an uninstall: nothing is deleted, the menu is simply not drawn, and switching it back on
      brings everything back.

  Per-site, because both answers are: one site may run the blog and another never want it.

  The switch takes the setting area, as a setting declaring no permission of its own does. The
  install record is written by the admin who ran the install, and setting a site up takes the site
  area (`MishkaCmsCore.Runtime.ExtensionProvision.required/1`), so it takes the site area or the
  setting area; the settings page shows it read-only, to them alone.
  """
  @spec settings(atom(), String.t()) :: [map()]
  def settings(app, category) do
    [
      Settings.define("#{app}.installed", :string,
        category: category,
        scope: :site,
        editable?: false,
        permission: ["admin:dashboard:runtime:site", "admin:dashboard:setting"],
        # `:extension`, NOT the app name. `MishkaCmsCore.Runtime.Setting` constrains `source` to
        # `[:core, :extension, :plugin]`, and a value outside it is refused by the resource — which
        # the settings screen reports only as "some settings could not be saved".
        source: :extension,
        label: gettext_noop("Set up at version"),
        description:
          gettext_noop(
            "Blank until this site has been set up. Written by the installer, not by hand."
          )
      ),
      Settings.define("#{app}.active", :boolean,
        category: category,
        scope: :site,
        default: true,
        permission: "admin:dashboard:setting",
        source: :extension,
        label: gettext_noop("Active on this site"),
        description:
          gettext_noop(
            "Off hides this extension's menu and stops its pages being served here. Nothing is deleted — switch it back on and everything returns."
          )
      )
    ]
  end

  @doc """
  Records that `site_id` has been set up with `app`, at `version`.

  Written after the install rather than before it, so a run that failed halfway leaves the site
  looking like what it is — not set up — and the menu keeps offering to finish the job.
  """
  @spec mark_installed!(String.t(), atom() | String.t(), String.t() | nil, map() | nil) :: :ok
  def mark_installed!(site_id, app, version, actor \\ nil) do
    recorded(
      actor,
      write_installed(actor, "#{app}.installed", version || "unknown", site_id),
      app,
      site_id
    )
  end

  # THE WIZARD STILL RAISES, because it always did: `Settings.put/3` writes with `authorize?: false`
  # and a refusal there is a broken deployment, not a decision — and the wizard is the one caller
  # that can still do something about it.
  defp recorded(nil, result, _app, _site_id) do
    {:ok, _setting} = result
    :ok
  end

  # AN ADMIN'S CLICK DOES NOT. `Settings.put_as/4` goes through policies and can genuinely answer
  # `{:error, _}`, and this runs AFTER the extension has already written its components and its
  # pages — raising would take an install that worked down with it, outside every rescue on the way.
  # The site goes on looking un-set-up until `found_already?/2` finds the pages and records it,
  # which is the case that function exists for.
  defp recorded(_actor, {:ok, _setting}, _app, _site_id), do: :ok

  defp recorded(_actor, {:error, reason}, app, site_id) do
    Logger.error(
      "[Installer] #{app} installed on #{site_id} but could not be recorded: #{inspect(reason)}"
    )

    :ok
  end

  # THE SETTINGS FAÇADE ALREADY HAS BOTH DOORS — see `MishkaCmsCore.Settings.put_as/4`, which picks
  # the master or the tenant action from the actor. Writing the system one for an admin's own click
  # was the whole of what was wrong here: the row said a site was set up and nothing said who.
  defp write_installed(nil, key, value, site_id), do: Settings.put(key, value, site_id: site_id)

  defp write_installed(actor, key, value, site_id),
    do: Settings.put_as(actor, key, value, site_id: site_id)

  @doc """
  The version `site_id` was set up with, or `nil` for a site that never was.
  """
  @spec installed_version(String.t(), atom() | String.t()) :: String.t() | nil
  def installed_version(site_id, app) do
    case Settings.get("#{app}.installed", nil, site_id) do
      version when is_binary(version) and version != "" -> version
      _never -> nil
    end
  end

  @doc """
  Whether `site_id` already has `app` — which is what sends an admin to the dashboard rather than
  the installer.

  ## The record is not the only evidence

  A site set up by this installer carries the setting. EVERY SITE THAT EXISTED BEFORE IT DOES NOT —
  it has the extension's components and pages and no record of how they got there, because nothing
  wrote one. Asking the setting alone would show the installer to every site already running the
  blog, which is the opposite of what it is for.

  So a site with no record is ASKED, on the same event the install runs on: the plugin knows its own
  pages and answers whether they are there. An answer of yes is then written down, so the question
  is asked once per site rather than on every render.
  """
  @spec installed?(String.t(), atom() | String.t()) :: boolean()
  def installed?(site_id, app) do
    case installed_version(site_id, app) do
      version when is_binary(version) -> true
      nil -> found_already?(site_id, app)
    end
  end

  # WHAT THE EXTENSION SAYS ABOUT THE SITE, asked through the event rather than guessed here: only
  # the extension knows what "already there" means for it, and core naming its pages would be core
  # naming the extension.
  defp found_already?(site_id, key) do
    payload = %{site_id: site_id, key: to_string(key), answers: %{}, reports: [], ask: :status}

    case @event |> Hook.call(payload) |> reports(payload) do
      [%{installed?: true} | _rest] ->
        mark_installed!(site_id, key, "unknown")
        true

      _not_there ->
        false
    end
  end

  @doc """
  Whether `app` is switched on for `site_id` — `true` unless somebody turned it off.

  A site that has never been set up is still ACTIVE: the switch says whether the extension is
  wanted here, and a site that wants it but has not run the installer is exactly who the installer
  screen is for.
  """
  @spec active?(String.t(), atom() | String.t()) :: boolean()
  def active?(site_id, app), do: Settings.get("#{app}.active", true, site_id) != false

  @doc """
  Whether the settings key `key` is an extension's `active?/2` switch, as `settings/2` declares it.
  """
  @spec active_key?(String.t()) :: boolean()
  def active_key?(key), do: String.ends_with?(key, ".active")

  # WHAT CAME BACK, OR WHAT WENT OUT. A plugin answering with something that is not the payload —
  # a bare atom, a list, nothing at all — must leave the caller where it started rather than take
  # the screen down with a `BadMapError`, which is the convention every other event caller in this
  # codebase already follows.
  defp reports(%{reports: reports}, _sent) when is_list(reports), do: reports

  defp reports(other, sent) do
    Logger.error("[Installer] #{@event} answered #{inspect(other)}, expected the payload back")
    Map.fetch!(sent, :reports)
  end

  defp entry(record) do
    extra = record |> Map.get(:extra) |> List.wrap() |> List.first() || %{}
    app = Map.get(record, :extension)

    %{
      key: to_string(app),
      app: app,
      plugin: Map.get(record, :name),
      label: field(extra, :label) || humanise(app),
      summary: field(extra, :summary) || "",
      fields: extra |> field(:fields) |> List.wrap(),
      status: Map.get(record, :status),
      priority: Map.get(record, :priority) || 100
    }
  end

  # An `:extra` written in a plugin's `initial:` is an ordinary map, but it has been through Mnesia
  # and a struct builder on the way here, so it is read for either kind of key rather than assumed.
  defp field(extra, key) when is_map(extra),
    do: Map.get(extra, key) || Map.get(extra, to_string(key))

  defp field(_extra, _key), do: nil

  # A LABEL IS NOT REQUIRED. An extension that registers without one is still installable, and
  # `mishka_blog` reads better in a list than a blank.
  defp humanise(nil), do: gettext("Unnamed extension")

  defp humanise(app) do
    app
    |> to_string()
    |> String.replace_prefix("mishka_", "")
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
