# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.DraftPreviewAssets do
  @moduledoc """
  Temporary, isolated CSS and compiled module for a runtime preview — a draft (Page/Layout/ErrorPage)
  or a live original reached by its `preview_token` — keyed by that token in `AssetsState` (ETS),
  NEVER the live site bundle or the live page module.

  Compiled on demand (so a draft with brand-new Tailwind classes still styles correctly) via
  `TailwindCompiler.compile_preview/4`, and **purged** when the draft is published or discarded.
  Served at `/_preview/:resource/:token/css` (see `MishkaCmsWeb.DraftPreviewController`), and linked
  by `MishkaCmsWeb.DraftPreviewLive`. JS is NOT compiled per-draft — the preview is a real LiveView
  that loads the site's existing JS bundle, which already exports every active hook (a draft
  template's `phx-hook` references `JsHook` rows in that bundle), so hooks run with no extra work.
  The token records the site its assets belong to (`remember_site/2`) — the record's own, or for a
  global record the host's its CSS was compiled against — so they are handed to whoever holds the
  link, on whatever address they open it, by that site's state (`site/1`).

  A page or a layout is drawn by its compiled module (`ensure_module/2`), built by the compiler its
  site uses, so its own helpers and the live components it nests render as on the published page.
  The module is named after the token, so a draft never replaces the live one, and is compiled again
  only when the record was saved since or is opened on another site. `purge/1` unloads it with the
  CSS, and `MishkaCmsWeb.DraftPreviewLive` unloads it when the preview closes.
  """
  alias MishkaCmsCore.Runtime.{Layout, LayoutDraft, Page, PageDraft, PreviewHooks}

  alias MishkaCmsCore.Runtime.Compilers.{
    Helpers,
    LayoutCompiler,
    LiveViewCompiler,
    ModuleCompiler
  }

  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler
  alias MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler
  alias MishkaCmsCore.Runtime.States.AssetsState

  @compiled [Page, PageDraft, Layout, LayoutDraft]

  @doc """
  Compile + store the draft's temp CSS under its token if missing, or if it was compiled against
  another site. `asset_site` is an optional fallback site (the host the admin is viewing from) used
  when the draft has no site of its own — a global layout draft — so its CSS compiles against a real
  site's base. Returns `:ok` | `:error`.
  """
  def ensure_css(draft, asset_site \\ nil)

  def ensure_css(%{preview_token: token} = draft, asset_site) when is_binary(token) do
    cond do
      not AssetsState.exists?(token, "css") ->
        compile_and_store(draft, asset_site)

      site(token) == {:ok, assets_site(draft, asset_site)} ->
        :ok

      true ->
        AssetsState.delete(token, "css")
        compile_and_store(draft, asset_site)
    end
  end

  def ensure_css(_draft, _asset_site), do: :error

  @doc "Recompile + replace the draft's temp CSS (after an edit)."
  def refresh_css(draft, asset_site \\ nil), do: compile_and_store(draft, asset_site)

  @doc """
  Records the site the preview's assets under the record's token belong to: the record's own, or for
  a global record `asset_site`, the host's it is opened on.
  """
  def remember_site(%{preview_token: token} = record, asset_site) when is_binary(token) do
    site_id = assets_site(record, asset_site)

    case AssetsState.get!(token, "site") do
      %{value: ^site_id} -> :ok
      _absent_or_other -> put_site(token, site_id)
    end
  end

  def remember_site(_record, _asset_site), do: :ok

  @doc """
  The site the preview's assets under `token` belong to: `{:ok, site_id}`, `{:ok, nil}` for a global
  record opened with no site, or `:error` when no preview has been opened under it.
  """
  def site(token) when is_binary(token) do
    case AssetsState.get!(token, "site") do
      %{value: site_id} -> {:ok, site_id}
      nil -> :error
    end
  end

  def site(_token), do: :error

  @doc "Delete the draft's temp CSS, its site and its compiled module (on publish / discard)."
  def purge(%{preview_token: token} = record) when is_binary(token) do
    :ok = unload_module(record)
    AssetsState.delete(token, "site")
    AssetsState.delete(token, "css")
  end

  def purge(_draft), do: :ok

  @doc """
  The module a Page, Layout or one of their drafts is previewed with, compiled if missing or older
  than the record, against `asset_site`'s hooks. `{:ok, module}`, or `{:error, message}` when it
  does not compile.
  """
  def ensure_module(%resource{preview_token: token} = record, asset_site)
      when resource in @compiled and is_binary(token) do
    module = preview_module(record)
    revision = revision(record, asset_site)

    case current?(token, module, revision) do
      true -> {:ok, module}
      false -> compile_module(record, module, revision, asset_site)
    end
  end

  def ensure_module(_record, _asset_site), do: {:error, "Only a page or a layout is compiled."}

  @doc """
  Unloads the record's preview module. A process still drawing it keeps the old code, and the next
  `ensure_module/2` compiles it again.
  """
  def unload_module(%resource{preview_token: token} = record)
      when resource in @compiled and is_binary(token) do
    module = preview_module(record)
    AssetsState.delete(token, "module")

    # The version before this one goes first, as the code server deletes nothing while it holds two.
    #
    # ONE TRY, NOT A WAIT. A publish unloads from inside its transaction, and waiting there for a
    # preview that is compiling would hold the transaction open for that compile. That preview's
    # module stays loaded until it closes, which unloads it, and the key above is already gone, so
    # nothing serves it again.
    alone(module, 0, fn ->
      if Helpers.loaded?(module) and :code.soft_purge(module) do
        :code.delete(module)
        :code.soft_purge(module)
      end
    end)

    :ok
  end

  def unload_module(_record), do: :ok

  # ONE COMPILE OR UNLOAD OF A MODULE AT A TIME. Two previews of one record share its module, so one
  # closing would otherwise delete the version the other is loading.
  defp alone(module, retries \\ :infinity, fun),
    do: :global.trans({{__MODULE__, module}, self()}, fun, [node()], retries)

  # Asked again inside the lock: whoever held it was most likely compiling this very revision, and
  # every preview that waited would otherwise compile it again in turn.
  defp compile_module(%{preview_token: token} = record, module, revision, asset_site) do
    alone(module, fn ->
      case current?(token, module, revision) do
        true -> {:ok, module}
        false -> compile_module_alone(record, module, revision, asset_site)
      end
    end)
  end

  defp current?(token, module, revision) do
    case AssetsState.get!(token, "module") do
      %{value: ^module, hash: ^revision} -> Helpers.loaded?(module)
      _absent_or_stale -> false
    end
  end

  defp compile_module_alone(%{preview_token: token} = record, module, revision, asset_site) do
    # An earlier version still drawn by a closed preview is dropped first, or the new one cannot load.
    _ = :code.soft_purge(module)

    case record |> quoted(module, asset_site) |> ModuleCompiler.compile_module() do
      {:ok, ^module, _diagnostics} ->
        AssetsState.save(%{
          id: token,
          type: "module",
          value: module,
          hash: revision,
          updated_at: DateTime.utc_now()
        })

        {:ok, module}

      {:error, _module, {error, diagnostics}} ->
        {:error, failure(error, diagnostics)}

      {:error, error} ->
        {:error, message(error)}
    end
  end

  defp quoted(%resource{} = record, module, asset_site) when resource in [Page, PageDraft] do
    record
    |> ModuleCompilerHandler.page_params(module)
    |> Map.update!(:template, &PreviewHooks.resolve(&1, asset_site))
    |> LiveViewCompiler.build_module()
  end

  defp quoted(%resource{} = record, module, asset_site) when resource in [Layout, LayoutDraft] do
    record
    |> ModuleCompilerHandler.layout_params(module)
    |> Map.update!(:template, &PreviewHooks.resolve(&1, asset_site))
    |> LayoutCompiler.build_module()
  end

  defp preview_module(%resource{preview_token: token}) do
    kind = if resource in [Layout, LayoutDraft], do: "Layout", else: "Page"
    hash = :md5 |> :crypto.hash(token) |> Base.encode16(case: :lower)
    Module.concat([MishkaCmsCore.Runtime.Preview, hash, kind])
  end

  defp revision(record, asset_site),
    do: "#{inspect(Map.get(record, :updated_at))}:#{Map.get(asset_site || %{}, :id)}"

  # The compiler raises "cannot compile module … (errors have been logged)" and hands the sentence
  # that names the fault back as a diagnostic, as `MishkaCmsCore.Runtime.PageBuilder.CodeCheck` reads it.
  defp failure(error, diagnostics) do
    case Enum.find(diagnostics, &(&1.severity == :error)) do
      %{message: message} -> message
      nil -> message(error)
    end
  end

  defp message(error) when is_exception(error), do: Exception.message(error)
  defp message(error), do: inspect(error)

  defp compile_and_store(%{preview_token: token, id: id, name: name} = draft, asset_site) do
    site = asset_site_name(asset_site) || site_name(draft)

    case TailwindCompiler.compile_preview(site, "preview_#{id}", name, scan_content(draft)) do
      {:ok, css} ->
        :ok = put_site(token, assets_site(draft, asset_site))

        AssetsState.save(%{
          id: token,
          type: "css",
          value: css,
          hash: :crypto.hash(:md5, css) |> Base.encode16(case: :lower),
          updated_at: DateTime.utc_now()
        })

        :ok

      {:error, _reason} ->
        :error
    end
  end

  defp put_site(token, site_id) do
    AssetsState.save(%{
      id: token,
      type: "site",
      value: site_id,
      hash: nil,
      updated_at: DateTime.utc_now()
    })
  end

  defp assets_site(record, asset_site) do
    case {Map.get(record, :site_id), asset_site} do
      {site_id, _asset_site} when is_binary(site_id) -> site_id
      {nil, %{id: site_id}} -> site_id
      _no_site -> nil
    end
  end

  defp site_name(%{site: %{name: name}}) when is_binary(name), do: name
  defp site_name(_draft), do: "Global"

  defp asset_site_name(%{name: name}) when is_binary(name), do: name
  defp asset_site_name(_asset_site), do: nil

  # An error page has no single `:template` — scan every status template, each per-status `:layout`,
  # and the `:root_layout_template`, so Tailwind emits the classes they use.
  defp scan_content(%{error_pages: pages} = record) when is_list(pages) do
    status_html =
      Enum.map_join(pages, "\n", fn entry ->
        template = Map.get(entry, :template) || Map.get(entry, "template") || ""
        layout = Map.get(entry, :layout) || Map.get(entry, "layout")

        layout_template =
          case layout do
            %{} = l -> Map.get(l, :template) || Map.get(l, "template") || ""
            _ -> ""
          end

        template <> "\n" <> layout_template
      end)

    status_html <> "\n" <> (Map.get(record, :root_layout_template) || "")
  end

  # A layout draft renders its template AROUND its `:example` content, so Tailwind must scan both or
  # the example's classes go unstyled. Page drafts have no `:example`, so this is just the template.
  defp scan_content(%{template: template, example: example})
       when is_binary(example) and example != "",
       do: template <> "\n" <> example

  defp scan_content(%{template: template}) when is_binary(template), do: template

  defp scan_content(_record), do: ""
end
