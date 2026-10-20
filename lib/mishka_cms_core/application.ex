# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @dashboard_widgets [
    MishkaCmsCore.Dashboard.Widgets.OverviewMetrics,
    MishkaCmsCore.Dashboard.Widgets.SiteOverview,
    MishkaCmsCore.Dashboard.Widgets.RuntimeHealth,
    MishkaCmsCore.Dashboard.Widgets.RecentActivity,
    MishkaCmsCore.Dashboard.Widgets.UsersSummary,
    MishkaCmsCore.Dashboard.Widgets.QuickActions,
    MishkaCmsCore.Dashboard.Widgets.CmsStatus
  ]

  @doc """
  The core dashboard widget plugins. Each is supervised so it self-registers on the
  `dashboard:widgets` event once `mishka_installer` is ready (the plugin retries until then), and
  `MishkaCmsCore.Dashboard.WidgetSettings` walks this same list to register each widget's own
  settings with the Settings page — so the two can never disagree about which widgets exist.
  """
  @spec dashboard_widgets() :: [module()]
  def dashboard_widgets, do: @dashboard_widgets

  # Notification producer plugins — each reacts to an existing `<app>:<resource>:after_<action>`
  # event and hands off to `MishkaCmsCore.Notify.deliver/3`.
  @notify_producers [
    MishkaCmsCore.Notify.Producers.PermissionsChanged
  ]

  # Cache coherence as a plugin rather than a call wired into the compiler: the core participates in
  # its own events (ADR-14), so this reacts to `runtime:after_module_compile` exactly as an extension
  # would.
  @cache_plugins [
    MishkaCmsCore.Runtime.PageBuilder.CardPreviewInvalidator
  ]

  # A page's share card refreshed after the page is saved, on `cms_core:page:after_save` — the same
  # event an extension's plugin would listen on (`MishkaCmsCore.Runtime.ShareCard`) — and the
  # share-card queue scaled when its Share-card workers setting is saved, on
  # `cms_core:setting:after_save` (`MishkaCmsCore.Runtime.ShareCardQueue`). Every card of a site is
  # looked at again when its address, name, logo or name's translation changes, and the core answers
  # `runtime:share_card:targets` with its pages (`MishkaCmsCore.Runtime.ShareCard.redraw_all/2`).
  @share_card_plugins [
    MishkaCmsCore.Runtime.PageShareCard,
    MishkaCmsCore.Runtime.ShareCardQueue,
    MishkaCmsCore.Runtime.PageShareCardTargets,
    MishkaCmsCore.Runtime.SiteShareCards,
    MishkaCmsCore.Runtime.SettingShareCards,
    MishkaCmsCore.Runtime.TranslationShareCards
  ]

  # What is kept of a site's icons dropped when its App icon or Favicon setting is saved, on
  # `cms_core:setting:after_save`, and when the media file either names is replaced, on
  # `cms_core:media:after_save` (`MishkaCmsCore.Runtime.SiteIcon`).
  @site_icon_plugins [
    MishkaCmsCore.Runtime.SettingSiteIcons,
    MishkaCmsCore.Runtime.MediaSiteIcons
  ]

  # `settings:register` plugins — the core widgets' settings under the General tab, and every
  # sidebar entry's position/visibility switches under the Sidebar tab.
  @settings_plugins [
    MishkaCmsCore.Dashboard.WidgetSettings,
    MishkaCmsCore.Sidebar.MenuSettings
  ]

  # Account notices as plugins on the sign-in events they answer: the account is emailed when its
  # two-step sign-in is turned off and when one of its recovery codes is used, and an admin of a
  # site that recommends two-step sign-in is reminded at each sign-in until it has one.
  @account_notices [
    MishkaCmsCore.Accounts.User.Notices.SecondFactorTurnedOff,
    MishkaCmsCore.Accounts.User.Notices.RecoveryCodeUsed,
    MishkaCmsCore.Accounts.User.Notices.TwoStepReminder
  ]

  # `mail:providers` plugins — the email providers a site can pick on the Email tab. An extension
  # adds one the same way (see `MishkaCmsCore.Mail.Provider`).
  @mail_providers [
    MishkaCmsCore.Mail.Providers.Resend,
    MishkaCmsCore.Mail.Providers.DevMailbox
  ]

  # `captcha:providers` plugins — the captchas a site can pick on the Security tab. An extension adds
  # one the same way (see `MishkaCmsCore.Captcha.Provider`).
  @captcha_providers [
    MishkaCmsCore.Captcha.Providers.Turnstile,
    MishkaCmsCore.Captcha.Providers.Recaptcha,
    MishkaCmsCore.Captcha.Providers.HCaptcha
  ]

  # `auth:providers` plugins — the services a site can sign in with, under Sign-in methods on the
  # Security tab (see `MishkaCmsCore.Accounts.SignInProvider`).
  @sign_in_providers [
    MishkaCmsCore.Accounts.SignInProviders.Google,
    MishkaCmsCore.Accounts.SignInProviders.GitHub
  ]

  # THE REGISTRY EVERY PLUGIN BELOW REGISTERS IN, WHEN THE LIBRARY DID NOT START IT ITSELF.
  # `MishkaInstaller.Application` picks its own supervision tree in a COMPILE-TIME branch on
  # `MishkaInstaller.__information__().env`, and that reads an exported `MIX_ENV` BEFORE the
  # `:project_env` our config sets. So whether the Mnesia registry exists comes down to whether
  # `MIX_ENV` happened to be exported in the shell that built `deps/` — one `MIX_ENV=test mix
  # deps.update` flips it, and nothing in this repo changes.
  #
  # It is not merely late when it is missing. Every plugin's `handle_continue` sits in
  # `:mnesia.wait_for_tables/2` for six seconds, so whoever brings Mnesia up afterwards stops it
  # first and kills all of them at once — eleven deaths is past any supervisor's restart intensity,
  # and the extension's whole plugin tree goes down with them, silently, before the first test runs.
  #
  # Started here, ahead of the first plugin, because `:mishka_cms_core` is a dependency of every
  # extension and of the host: its application starts before theirs in every environment. Whatever
  # the library did start is left to it.
  @installer_children [
    MishkaInstaller.Installer.CompileHandler,
    MishkaInstaller.Event.EventHandler,
    MishkaInstaller.MnesiaRepo
  ]

  @doc """
  Every mishka_installer plugin the core ships, and exactly the plugins `start/2` supervises. A plugin
  left out of it never registers, so the event it listens on never reaches it.
  """
  @spec plugins() :: [module()]
  def plugins,
    do:
      @dashboard_widgets ++
        @notify_producers ++
        @settings_plugins ++
        @cache_plugins ++
        @share_card_plugins ++
        @site_icon_plugins ++
        @mail_providers ++ @captcha_providers ++ @sign_in_providers ++ @account_notices

  @doc """
  The parts of `mishka_installer`'s own tree this application has to supervise, in the library's
  order — none of them when the library's compiled-in branch supervises them itself.
  """
  @spec installer_children() :: [module()]
  def installer_children,
    do: @installer_children -- MishkaInstaller.Application.supervised_children()

  @impl true
  def start(_type, _args) do
    :ok = MishkaCmsCore.Runtime.Handlers.BootHandler.new_boot_id()

    children =
      installer_children() ++
        [{AshAuthentication.Supervisor, [otp_app: :mishka_cms_core]}] ++ plugins()

    MishkaCmsCore.Activity.Sources.Oban.attach()
    MishkaCmsCore.Activity.Sources.RuntimeCompile.attach()
    MishkaCmsCore.PluginRegistrations.attach()
    MishkaCmsCore.Runtime.Compilers.SitemapCompiler.attach()
    :ok = MishkaCmsCore.Runtime.LiveViewHelpers.carry_into_tasks()

    opts = [strategy: :one_for_one, name: MishkaCmsCore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
