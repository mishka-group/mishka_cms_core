# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Install.CoreSeed do
  @moduledoc """
  The core's own parts on `installer:seed` (`MishkaCmsCore.Install.Seeds`), the plugin every other
  part builds on: the permissions, the master admin, the site, its languages and settings, the UI
  components, the starter content and the sign-in pages, and in development the sample data.

  | part | | installers |
  | --- | --- | --- |
  | `permissions` | required | dev, prod |
  | `master_user` | required | dev, prod |
  | `site` | required | dev, prod |
  | `languages` | required | dev, prod |
  | `settings` | required | prod |
  | `components` | ticked at the start | dev, prod |
  | `starter_content` | required | dev, prod |
  | `auth_pages` | required | dev, prod |
  | `samples` | required | dev |

  THE STARTER IS NOT A CHOICE, and neither are the sign-in pages: every page of a site, an
  extension's included, is drawn in the starter's `site-main` layout, and a site without a sign-in
  page lets nobody sign in.

  Its parts run once and first, in this order, and each one's report is merged into the foundation
  the next is handed. In production each is `MishkaCmsCore.Install.Bootstrap.run_part/4`, fed the
  installer's forms as `answers`; in development each is `MishkaCmsCore.Dev.Seeds.run_part/2`, which
  writes the dev sites and their content, or the stress volumes at `size: :stress`. Registered in
  MishkaCmsCore.Application.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  use MishkaInstaller.Event.Hook,
    event: "installer:seed",
    initial: %{
      priority: 0,
      extra: [
        %{
          id: "permissions",
          label: gettext_noop("Preparing permissions"),
          summary: gettext_noop("Every permission name an admin can be granted"),
          envs: [:dev, :prod],
          required: true
        },
        %{
          id: "master_user",
          label: gettext_noop("Creating the master admin"),
          summary: gettext_noop("The account that holds every site"),
          envs: [:dev, :prod],
          required: true
        },
        %{
          id: "site",
          label: gettext_noop("Creating the first site"),
          summary: gettext_noop("The site on the domain you typed"),
          envs: [:dev, :prod],
          required: true
        },
        %{
          id: "languages",
          label: gettext_noop("Saving the site's languages"),
          summary: gettext_noop("The languages its pages answer in"),
          envs: [:dev, :prod],
          required: true
        },
        %{
          id: "settings",
          label: gettext_noop("Applying essential settings"),
          summary: gettext_noop("The site title and the outgoing email address"),
          envs: [:prod],
          required: true
        },
        %{
          id: "components",
          label: gettext_noop("Installing UI components"),
          summary: gettext_noop("The UI-kit components the pages are built from"),
          envs: [:dev, :prod],
          default: true
        },
        %{
          id: "starter_content",
          label: gettext_noop("Adding starter content"),
          summary: gettext_noop("The theme, header, footer, layout and home page"),
          envs: [:dev, :prod],
          required: true
        },
        %{
          id: "auth_pages",
          label: gettext_noop("Adding sign-in pages"),
          summary: gettext_noop("The pages a visitor signs in and registers on"),
          envs: [:dev, :prod],
          required: true
        },
        %{
          id: "samples",
          label: gettext_noop("Adding sample data"),
          summary:
            gettext_noop("More sites, users, media, showcase pages and hooks on every dev site"),
          envs: [:dev],
          required: true
        }
      ]
    }

  alias MishkaCmsCore.Dev.Seeds, as: DevSeeds

  @impl true
  def call(%{key: "mishka_cms_core", env: :dev, part: part} = payload),
    do: reply(payload, DevSeeds.run_part(part, payload))

  def call(payload), do: {:reply, payload}

  defp reply(payload, {:ok, report}),
    do: {:reply, %{payload | reports: payload.reports ++ [report]}}
end
