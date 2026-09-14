defmodule MishkaCmsCore.Runtime.ExtensionKit do
  @moduledoc """
  Lets an extension ship site-facing components as a bundle, the same way the Chelekom UI kit does
  (§22, Path A).

  ## Why this is a wrapper and not a mechanism

  `MishkaCmsCore.Runtime.Handlers.UiKitHandler` already installs a `mishka.ui_kit.bundle.v3` bundle:
  idempotent upserts, archived-row protection, `defer_runtime` batching and a single
  `sync_after_bulk` at the end. An extension that ships template-shaped components — a post card, a
  tag cloud, a hero — needs exactly that and nothing more, and once its components are ordinary
  `Component` rows the palette, the inspector, the examples modal and the compiler all work with no
  editor changes at all.

  So this module is deliberately thin. It finds the extension's bundle, names it, and hands it to
  the handler. Everything that could go wrong on install is already handled one layer down.

  ## The other path

  A component that cannot be a stored template — one that streams live data — is not this. That is
  `MishkaCmsCore.Builder.PaletteEntry` on the `builder:components` hook.

  ## Shipping a bundle

  Put it at `priv/cms_components/<name>.json` in the extension, then install on setup:

      MishkaCmsCore.Runtime.ExtensionKit.install!(:mishka_blog)

  and remove it on teardown with `uninstall!/2`.
  """

  require Logger

  @dir "cms_components"

  @doc """
  The on-disk path of an extension's component bundle, or `nil` when it ships none.

  `name` defaults to the application's own name, which is the convention; pass one explicitly for an
  application shipping more than a single bundle.
  """
  @spec bundle_path(atom(), String.t() | nil) :: String.t() | nil
  def bundle_path(app, name \\ nil) do
    file = "#{name || app}.json"

    case :code.priv_dir(app) do
      {:error, _reason} -> nil
      priv -> priv |> Path.join(@dir) |> Path.join(file) |> existing()
    end
  end

  defp existing(path), do: if(File.exists?(path), do: path, else: nil)

  @doc "Whether `app` ships a component bundle."
  @spec available?(atom(), String.t() | nil) :: boolean()
  def available?(app, name \\ nil), do: not is_nil(bundle_path(app, name))

  @doc """
  Installs an extension's components.

  Returns `:noop` when the extension ships no bundle, so calling this unconditionally from an
  extension's setup is safe. `opts` are passed through to
  `MishkaCmsCore.Runtime.Handlers.UiKitHandler.install_kit!/2` — `:site_id` scopes the components to
  one tenant, and omitting it installs them globally.
  """
  @spec install!(atom(), keyword()) :: {:ok, term()} | :noop
  def install!(app, opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)

    case bundle_path(app, name) do
      nil ->
        Logger.debug(
          "[ExtensionKit] #{inspect(app)} ships no component bundle; nothing to install"
        )

        :noop

      path ->
        Logger.info("[ExtensionKit] installing #{inspect(app)} components from #{path}")
        {:ok, MishkaCmsCore.Runtime.Handlers.UiKitHandler.install_kit!(path, opts)}
    end
  end

  @doc "Removes an extension's components. `:noop` when it ships no bundle."
  @spec uninstall!(atom(), keyword()) :: {:ok, term()} | :noop
  def uninstall!(app, opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)

    case bundle_path(app, name) do
      nil -> :noop
      path -> {:ok, MishkaCmsCore.Runtime.Handlers.UiKitHandler.uninstall_kit!(path, opts)}
    end
  end
end
