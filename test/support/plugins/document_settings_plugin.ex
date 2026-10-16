# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.DocumentSettingsPlugin do
  @moduledoc """
  Example plugin: the **Document** extension registering its own configuration via the
  `settings:register` mishka_installer hook (see `MishkaCmsCore.Test.Plugins.BlogSettingsPlugin`). Two
  extensions registering for the same hook compose — each appends its definitions to the chain.
  """
  use MishkaInstaller.Event.Hook, event: "settings:register"

  alias MishkaCmsCore.Settings

  @impl true
  def call(%{definitions: definitions} = data) do
    {:reply, %{data | definitions: definitions ++ document_settings()}}
  end

  defp document_settings do
    [
      Settings.define("document.default_format", :select,
        default: "markdown",
        options: ["markdown", "html", "heex"],
        category: "document",
        source: :extension,
        label: "Default document format"
      ),
      Settings.define("document.versions_to_keep", :integer,
        default: 20,
        category: "document",
        source: :extension,
        label: "Versions kept per document"
      ),
      Settings.define("document.public_by_default", :boolean,
        default: false,
        category: "document",
        source: :extension,
        label: "New documents are public by default"
      )
    ]
  end
end
