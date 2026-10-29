# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Section do
  @moduledoc """
  What "the template" means for each of the four things the builder edits, and how to write one back.

  Three of them — page, layout and component — keep their markup in a single `template` attribute
  and need nothing special. **An error page does not.** It stores `error_pages`, a list of
  `%{status, template, layout}` entries, so "open the error page in the builder" is really "open the
  404 entry of this error page", and saving has to replace one element of that list rather than set
  a field. Without this module the error-page route would appear to work and then write a `template`
  attribute the resource does not have.

  Keeping the difference here — rather than as branches inside the LiveView — is what lets the
  editor, the canvas, the history and the save gate stay identical for all four sections.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.ErrorPage
  alias MishkaCmsCore.Runtime.ErrorStatus
  alias MishkaCmsCore.Runtime.Layout
  alias MishkaCmsCore.Runtime.Page

  @sections %{
    "page" => %{
      resource: Page,
      list: "/admin/dashboard/runtime/pages",
      label: gettext_noop("Page"),
      permissions: ["admin:dashboard:runtime:page", "admin:dashboard:code"]
    },
    "layout" => %{
      resource: Layout,
      list: "/admin/dashboard/runtime/layouts",
      label: gettext_noop("Layout"),
      permissions: ["admin:dashboard:runtime:layout", "admin:dashboard:code"]
    },
    "error-page" => %{
      resource: ErrorPage,
      list: "/admin/dashboard/runtime/error-pages",
      label: gettext_noop("Error page"),
      permissions: ["admin:dashboard:runtime:error_page", "admin:dashboard:code"]
    },
    "component" => %{
      resource: Component,
      list: "/admin/dashboard/runtime/components",
      label: gettext_noop("Component"),
      permissions: ["admin:dashboard:runtime:component", "admin:dashboard:code"]
    }
  }

  @default_status 404

  @editor_url_event "runtime:document:editor_url"

  @doc "The section names the builder can open."
  @spec names() :: [String.t()]
  def names, do: Map.keys(@sections)

  @doc "Whether `section` is one the builder knows."
  @spec known?(String.t()) :: boolean()
  def known?(section), do: Map.has_key?(@sections, section)

  @doc "Normalizes `page`, `error_page` and `error-page` to the canonical hyphenated form."
  @spec normalize(String.t() | nil | atom()) :: String.t()
  def normalize(nil), do: "page"
  def normalize(section) when is_atom(section), do: normalize(Atom.to_string(section))
  def normalize(section), do: String.replace(section, "_", "-")

  @doc """
  The underscored form — what an editing session stores and what the resources spell their sections
  with.

  ONE SECTION IS SPELLED TWO WAYS. The address says `error-page` and everything durable says
  `error_page`, and that difference was converted by hand in nine places across five modules. Three
  of them were bare `String.to_existing_atom/1` calls, which is not a conversion but a crash waiting
  for the one section whose two spellings differ — it took the builder's mount down for error pages.
  """
  @spec to_underscored(String.t() | nil | atom()) :: String.t()
  def to_underscored(section), do: section |> normalize() |> String.replace("-", "_")

  @doc """
  The section as the atom the log and the resources use, or `:error` for anything else.

  Total on purpose: the argument is often something a URL supplied.
  """
  @spec to_atom(String.t() | nil | atom()) :: {:ok, atom()} | :error
  def to_atom(section) do
    normalized = normalize(section)

    case known?(normalized) do
      true -> {:ok, normalized |> String.replace("-", "_") |> String.to_existing_atom()}
      false -> :error
    end
  end

  @doc "The same, for a section already known to be one of ours. Raises rather than inventing one."
  @spec to_atom!(String.t() | nil | atom()) :: atom()
  def to_atom!(section) do
    case to_atom(section) do
      {:ok, atom} -> atom
      :error -> raise ArgumentError, "#{inspect(section)} is not a section the builder edits"
    end
  end

  @doc "Every section as an atom — what a resource constraint or a struct's enum needs."
  @spec atoms() :: [atom()]
  def atoms, do: Enum.map(names(), &to_atom!/1)

  @doc "The Ash resource behind a section."
  @spec resource(String.t()) :: module()
  def resource(section), do: @sections |> Map.fetch!(section) |> Map.fetch!(:resource)

  @doc """
  How `actor` reads one document of `resource`, with its site loaded: `{:ok, opts}` for `Ash.get/3`,
  `:error` for a viewer who is not a user.

  A master reads across sites with `:master_get`, multitenancy bypassed. A site admin reads with
  their site as the tenant — through `:get_for_tenant_with_globals` where the resource declares it,
  because a layout or a component may belong to no site at all, and `global? true` only means the
  resource may be read WITHOUT a tenant: a tenant-scoped read still filters a site-less row out. A
  resource with no shared rows — a page, an error page — keeps the plain tenant read.
  """
  @spec read_opts(module(), map() | nil) :: {:ok, keyword()} | :error
  def read_opts(_resource, %{site_id: nil} = actor),
    do: {:ok, [action: :master_get, actor: actor, load: [:site]]}

  def read_opts(resource, %{site_id: site_id} = actor) when is_binary(site_id) do
    case Ash.Resource.Info.action(resource, :get_for_tenant_with_globals) do
      nil ->
        {:ok, [actor: actor, tenant: site_id, load: [:site]]}

      _shared ->
        {:ok,
         [action: :get_for_tenant_with_globals, actor: actor, tenant: site_id, load: [:site]]}
    end
  end

  def read_opts(_resource, _not_a_user), do: :error

  @doc "Where the section's index page lives — the builder's back link."
  @spec list_path(String.t()) :: String.t()
  def list_path(section), do: @sections |> Map.fetch!(section) |> Map.fetch!(:list)

  @doc """
  The names that open the builder on `section`, holding any one being enough: its own runtime area
  or `admin:dashboard:code`.
  """
  @spec permissions(String.t() | atom()) :: [String.t()]
  def permissions(section),
    do: @sections |> Map.fetch!(normalize(section)) |> Map.fetch!(:permissions)

  @doc "Whether `actor` may open the builder on `section` (`permissions/1`)."
  @spec allowed?(map() | nil, String.t() | atom()) :: boolean()
  def allowed?(nil, _section), do: false

  def allowed?(actor, section) do
    case to_atom(section) do
      {:ok, _known} ->
        AccessPermissions.match?(AccessPermissions.with_permissions(actor), %{},
          permissions: permissions(section)
        )

      :error ->
        false
    end
  end

  @doc """
  The visual editor's address for one document, or for making a new one when `id` is `nil` — or
  `nil` when no editor is installed.

  THE CORE DOES NOT SPELL THE EDITOR'S ADDRESSES. It asks `runtime:document:editor_url`, a transform
  whose payload is `%{section: "page" | "layout" | "component" | "error-page", id:, status:, url: nil}`,
  and the editor's own plugin answers with `url` filled in. No plugin, or one that cannot run,
  leaves `url` as `nil`, and every caller then leaves its "open in the editor" button out: the
  dashboards' create menu opens the form instead, and the inspector offers no Visual Editor.

  `status` names the error-page entry to open, as the editor's own address does.
  """
  @spec editor_url(String.t() | atom(), String.t() | nil, ErrorStatus.t() | nil) ::
          String.t() | nil
  def editor_url(section, id \\ nil, status \\ nil) do
    payload = %{section: normalize(section), id: id, status: status, url: nil}

    case MishkaInstaller.Event.Hook.call(@editor_url_event, payload, cannot_run: payload) do
      %{url: url} when is_binary(url) -> url
      _no_editor -> nil
    end
  end

  @doc "A human name for the section, used in flash messages."
  @spec label(String.t()) :: String.t()
  def label(section) do
    @sections
    |> Map.fetch!(section)
    |> Map.fetch!(:label)
    |> then(&Gettext.gettext(MishkaCmsCore.Gettext, &1))
  end

  @doc """
  The markup the editor should open for this record.

  For an error page, `opts[:status]` selects which status entry — defaulting to 404, or the first
  entry the record actually has.
  """
  @spec template(String.t(), map() | nil, keyword()) :: String.t()
  def template(_section, nil, _opts), do: ""

  def template("error-page", record, opts) do
    case entry(record, status(record, opts)) do
      nil -> ""
      %{} = entry -> entry["template"] || entry[:template] || ""
    end
  end

  def template(_section, record, _opts), do: Map.get(record, :template) || ""

  @doc """
  The status an editing SESSION is for, or `nil` for a section that has none.

  `status/2` always answers a status, because an error page always opens on one. This is the other
  question — "is a status part of what this document is?" — and for a page, a layout or a component
  the answer is no. It is what keys an editing session, so a session opened on the 404 entry is not
  handed back for the 500 one.
  """
  @spec editing_status(String.t(), map() | nil, keyword()) :: ErrorStatus.t() | nil
  def editing_status("error-page", record, opts), do: status(record, opts)
  def editing_status(_section, _record, _opts), do: nil

  @doc """
  The attribute map to hand `MishkaCmsCore.Runtime.PageBuilder.Helpers.save_section/4`, with the
  values that depend on the record left as functions of it.

  For an error page the whole `error_pages` list IS the attribute, so the write is every entry with
  one of them replaced — and an entry this session is not editing is only carried across correctly
  if the list it is copied from is the STORED one. A record read earlier is not: the builder holds
  `@record`, the snapshot its LiveView mounted on, and a tab sitting on the 404 since before the 500
  was published wrote the old 500 back over the new one, reverting a publish with nothing said. So
  the value is deferred rather than computed, and `apply_fields/2` resolves it against the row the
  write has just read and is about to update.

  Every other section sets `template` outright and never reads the record, so its value is the
  markup and nothing about it can go stale.
  """
  @spec save_fields(String.t(), String.t(), keyword()) :: %{String.t() => term()}
  def save_fields("error-page", heex, opts) do
    %{"error_pages" => fn record -> replace_entry(record, write_status(record, opts), heex) end}
  end

  def save_fields(_section, heex, _opts), do: %{"template" => heex}

  # THE STATUS THE SESSION IS ON, AND NO FALLING BACK FROM IT. `status/2` answers "which entry should
  # the editor open", and it falls back because an editor has to open on something. A write must not:
  # the entry a session is on can be gone from the record by the time it saves — the error-page form
  # edits the collection as a whole — and falling back there would land the author's markup on the
  # 404 and destroy it. `replace_entry/3` appends a status the record no longer has, which keeps the
  # work and touches nothing else. A caller with no status at all still gets the fallback.
  defp write_status(record, opts) do
    case normalize_status(opts[:status]) do
      nil -> status(record, opts)
      requested -> requested
    end
  end

  @doc """
  Resolves what `save_fields/3` deferred against `record` — the row being written, which for a
  create is `nil`.

  Values that are not functions are passed through, so a caller with fields of its own can merge
  them in before resolving.
  """
  @spec apply_fields(map(), map() | nil) :: map()
  def apply_fields(fields, record) do
    Map.new(fields, fn
      {key, build} when is_function(build, 1) -> {key, build.(record)}
      {key, value} -> {key, value}
    end)
  end

  @doc """
  The templates this record owns OTHER than the one being edited.

  Empty for every section but an error page, which keeps one template per status in a single record.
  That matters wherever something is keyed to the RECORD rather than to the status — the element-CSS
  row is, and pruning it against only the open status deleted the rules belonging to the other four.
  """
  @spec sibling_templates(String.t(), map() | nil, keyword()) :: [String.t()]
  def sibling_templates("error-page", record, opts) do
    editing = status(record, opts)

    record
    |> entries()
    |> Enum.reject(&(entry_status(&1) == editing))
    |> Enum.map(&(&1["template"] || &1[:template] || ""))
    |> Enum.reject(&(&1 == ""))
  end

  def sibling_templates(_section, _record, _opts), do: []

  @doc """
  The statuses an error-page record defines, codes in ascending order and then `:offline`. `[]` for
  every other section — the status tab strip only renders when there is something to switch between.
  """
  @spec statuses(String.t(), map() | nil) :: [ErrorStatus.t()]
  def statuses("error-page", record) do
    record
    |> entries()
    |> Enum.map(&entry_status/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  def statuses(_section, _record), do: []

  @doc """
  The statuses the builder's strip shows for a record: those it defines and the one open, which may be
  one being added. `[]` for every other section and for a document not yet written.
  """
  @spec statuses(String.t(), map() | nil, ErrorStatus.t() | nil) :: [ErrorStatus.t()]
  def statuses("error-page", record, open) when is_map(record) and not is_nil(open),
    do: "error-page" |> statuses(record) |> Enum.concat([open]) |> Enum.uniq() |> Enum.sort()

  def statuses(section, record, _open), do: statuses(section, record)

  @doc """
  The statuses an error page can hold an entry for: the offline page, then the codes the Error Pages
  offer (`MishkaCmsCore.Runtime.ErrorStatus.choices/0`). One the record lacks is added by opening it
  in the builder.
  """
  @spec offered_statuses() :: [ErrorStatus.t()]
  def offered_statuses do
    Enum.flat_map(ErrorStatus.choices(), fn
      {_group, codes} when is_list(codes) -> Enum.map(codes, &elem(&1, 1))
      {_label, status} -> [ErrorStatus.parse(status)]
    end)
  end

  @doc """
  The status the editor should open on: the requested one if the record has it or an error page can
  hold it (`offered_statuses/0`, which is how a status is added), else the first.
  """
  @spec status(map() | nil, keyword()) :: ErrorStatus.t()
  def status(record, opts) do
    available = record |> entries() |> Enum.map(&entry_status/1)
    requested = normalize_status(opts[:status])

    cond do
      requested in available -> requested
      requested in offered_statuses() -> requested
      @default_status in available -> @default_status
      available == [] -> @default_status
      true -> hd(available)
    end
  end

  defp normalize_status(status), do: ErrorStatus.parse(status)

  # An entry the form wrote before it was read back spells `offline` as text.
  defp entry_status(entry), do: ErrorStatus.parse(entry["status"] || entry[:status])

  defp entries(nil), do: []

  defp entries(record) do
    case Map.get(record, :error_pages) do
      entries when is_list(entries) -> entries
      _other -> []
    end
  end

  defp entry(record, status) do
    Enum.find(entries(record), &(entry_status(&1) == status))
  end

  # A status the record does not define yet is appended, so the editor can author a new one rather
  # than silently dropping the work.
  defp replace_entry(record, status, heex) do
    entries = Enum.map(entries(record), &stringify/1)

    case Enum.find_index(entries, &(entry_status(&1) == status)) do
      nil -> entries ++ [%{"status" => status, "template" => heex, "layout" => %{}}]
      index -> List.update_at(entries, index, &Map.put(&1, "template", heex))
    end
  end

  defp stringify(%{} = entry), do: Map.new(entry, fn {key, value} -> {to_string(key), value} end)
end
