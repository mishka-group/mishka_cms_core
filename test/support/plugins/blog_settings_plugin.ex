# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.BlogSettingsPlugin do
  @moduledoc """
  Example plugin: the **Blog** extension registering its own configuration into the CMS settings
  store via the `settings:register` mishka_installer hook — exactly how a real extension contributes
  its settings without touching core. It appends to the running definition list (so it composes with
  every other registrar), and the values are then read everywhere with `MishkaCmsCore.Settings.get/2`.
  """
  use MishkaInstaller.Event.Hook, event: "settings:register"

  alias MishkaCmsCore.Settings

  @impl true
  def call(%{definitions: definitions} = data) do
    {:reply, %{data | definitions: definitions ++ blog_settings()}}
  end

  defp blog_settings do
    [
      Settings.define("blog.posts_per_page", :integer,
        default: 10,
        category: "blog",
        source: :extension,
        label: "Posts per page",
        description: "How many posts to show on a blog index page."
      ),
      Settings.define("blog.allow_comments", :boolean,
        default: true,
        category: "blog",
        source: :extension,
        label: "Allow comments"
      ),
      Settings.define("blog.moderate_comments", :boolean,
        default: false,
        category: "blog",
        source: :extension,
        label: "Hold comments for moderation before they appear"
      )
    ]
  end
end
