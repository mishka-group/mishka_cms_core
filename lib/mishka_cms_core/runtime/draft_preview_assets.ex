# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.DraftPreviewAssets do
  @moduledoc """
  Temporary, isolated CSS and compiled module for a runtime preview — a draft (Page/Layout/ErrorPage)
  or a live original reached by its `preview_token` — NEVER the live site bundle or the live page
  module.

  The CSS is compiled on every request and kept nowhere (`css/2`): the saved stylesheets, Tailwind
  over the record's own markup (so a draft with brand-new classes is styled), and a draft's own
  element CSS (`element_css`) laid over its document's row as its publish writes it. A draft's CSS
  therefore lives in the draft alone, and goes when the draft is published or deleted. Served at
  `/_preview/:resource/:token/css` (see `MishkaCmsWeb.DraftPreviewController`), and linked by
  `MishkaCmsWeb.DraftPreviewLive`. JS is NOT compiled per-draft — the preview is a real LiveView
  that loads the site's existing JS bundle, which already exports every active hook (a draft
  template's `phx-hook` references `JsHook` rows in that bundle), so hooks run with no extra work.
  The token records the site its JS belongs to in `AssetsState` (`remember_site/2`) — the record's
  own, or for a global record the host's it is opened on — so the bundle is handed to whoever holds
  the link, by that site's state (`site/1`), on an address `served_on?/2` allows.

  A page or a layout is drawn by its compiled module (`ensure_module/2`), built by the compiler its
  site uses, so its own helpers and the live components it nests render as on the published page.
  The module is named after the token, so a draft never replaces the live one, and is compiled again
  only when the record was saved since or is opened on another site. `purge/1` unloads it with the
  site, and `MishkaCmsWeb.DraftPreviewLive` unloads it when the preview closes.
  """
  alias MishkaCmsCore.Runtime.{Layout, LayoutDraft, Page, PageDraft, PreviewHooks}
  alias MishkaCmsCore.Runtime.Authoring.{Drafts, ElementCss}

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
  The preview's temporary CSS, compiled now from the record as it is, as the site's own CSS is: the
  host shell, the global and the site's saved stylesheets, the record's own markup, and a draft's
  own element CSS laid over its document's element-CSS row (`element_css`, see
  `MishkaCmsCore.Runtime.Authoring.Drafts`).

  `asset_site` is the site a record with none of its own — a global layout — is compiled against:
  the host the preview is opened on.

  NOTHING IS CACHED. A preview is opened to see the draft as it stands, so it is compiled on every
  call, a Tailwind pass of a few seconds. One record compiles one at a time: its markup is written
  to a temporary folder named after it, which a second compile alongside would delete under the
  first. Returns `{:ok, css}` or `:error`.
  """
  @spec css(map(), map() | nil) :: {:ok, String.t()} | :error
  def css(%{preview_token: token, id: id, name: name} = record, asset_site)
      when is_binary(token) do
    site = asset_site_name(asset_site) || site_name(record)
    rows = element_rows(record)

    alone({:css, id}, fn ->
      case TailwindCompiler.compile_preview(site, "preview_#{id}", name, scan_content(record),
             rows: rows
           ) do
        {:ok, css} -> {:ok, css}
        {:error, _reason} -> :error
      end
    end)
  end

  def css(_record, _asset_site), do: :error

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

  @doc """
  Whether a preview of a record of `site_id` (`nil` for a global one) may be served on the address of
  `current_site`, the site the request's host resolved to.

  The master site's address serves every site's previews, and a site's own address serves its own.
  A global record belongs to every site, so any site's address serves it. Another site's address,
  or a request no site answers for, serves nothing: a preview of site A is never shown on site B.

      served_on?(site_a_id, %{id: site_a_id, master: false})  #=> true
      served_on?(site_a_id, %{id: master_id, master: true})   #=> true
      served_on?(site_a_id, %{id: site_b_id, master: false})  #=> false
      served_on?(nil, %{id: site_b_id, master: false})        #=> true
  """
  @spec served_on?(String.t() | nil, map() | nil) :: boolean()
  def served_on?(_site_id, %{master: true}), do: true
  def served_on?(nil, %{id: id}) when is_binary(id), do: true
  def served_on?(site_id, %{id: site_id}) when is_binary(site_id), do: true
  def served_on?(_site_id, _current_site), do: false

  @doc "Delete the record's preview site and its compiled module (on publish / discard)."
  def purge(%{preview_token: token} = record) when is_binary(token) do
    :ok = unload_module(record)
    AssetsState.delete(token, "site")
  end

  def purge(_draft), do: :ok

  @doc """
  The module a Page, Layout or one of their drafts is previewed with, compiled if missing or older
  than the record, against `asset_site`'s hooks. `{:ok, module}`, or `{:error, message}` when it
  does not compile.

  A compile is the `[:mishka_cms, :runtime, :draft_preview, :compile]` span, with the `module` as its
  metadata: it starts in the calling process before it asks for the module's lock, and stops with
  the answer.
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
  # closing would otherwise delete the version the other is loading. `css/2` takes the same kind of
  # lock under `{:css, id}` for the record's temporary folder.
  defp alone(resource, retries \\ :infinity, fun),
    do: :global.trans({{__MODULE__, resource}, self()}, fun, [node()], retries)

  # Asked again inside the lock: whoever held it was most likely compiling this very revision, and
  # every preview that waited would otherwise compile it again in turn.
  defp compile_module(%{preview_token: token} = record, module, revision, asset_site) do
    :telemetry.span([:mishka_cms, :runtime, :draft_preview, :compile], %{module: module}, fn ->
      result =
        alone(module, fn ->
          case current?(token, module, revision) do
            true -> {:ok, module}
            false -> compile_module_alone(record, module, revision, asset_site)
          end
        end)

      {result, %{module: module}}
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
  # that names the fault back as a diagnostic, as `MishkaCmsCore.Runtime.Authoring.CodeCheck` reads it.
  defp failure(error, diagnostics) do
    case Enum.find(diagnostics, &(&1.severity == :error)) do
      %{message: message} -> message
      nil -> message(error)
    end
  end

  defp message(error) when is_exception(error), do: Exception.message(error)
  defp message(error), do: inspect(error)

  # A DRAFT'S OWN ELEMENT CSS, over its document's element-CSS row the way the editor's publish
  # folds it in (`ElementCss.merge/2`): a rule the draft rewrote replaces the row's, a rule it cleared
  # is gone, and the rest of the row is left as it is. Compiled in the row's place, so the preview
  # orders it as the published bundle will. A draft of a document not published yet has no row, and
  # its rules are added after the site's.
  defp element_rows(%{element_css: edits} = record) when is_map(edits) and map_size(edits) > 0 do
    owner = Drafts.element_owner(record) || "draft-#{record.id}"
    %{ElementCss.row_name(owner) => &held(&1, edits)}
  end

  defp element_rows(_record), do: %{}

  defp held(content, edits),
    do: content |> ElementCss.parse() |> ElementCss.merge(edits) |> ElementCss.css()

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
