# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.BuilderJsHookPlugin do
  @moduledoc """
  Test plugin: contributes a JS hook through `builder:js_hooks`.

  A contributed hook is registered in the site's bundle by whoever contributes it, so the entry is
  only what the picker draws — the browser name, the name a reader knows it by, and whether it is a
  global. It exists because the picker offered these and Apply refused every one of them: the picker
  read the appended list and `Hooks.known?/4` read the site's rows alone.
  """
  use MishkaInstaller.Event.Hook, event: "builder:js_hooks"

  @hook %{
    name: "AcmeLightbox",
    hook: "acme-lightbox",
    description: "Opens an image in a lightbox.",
    global?: true
  }

  @impl true
  def call(%{hooks: hooks} = payload), do: {:reply, %{payload | hooks: hooks ++ [@hook]}}
  def call(payload), do: {:reply, payload}

  @doc "The hook this plugin contributes, so tests can assert against it directly."
  @spec hook() :: map()
  def hook, do: @hook
end
