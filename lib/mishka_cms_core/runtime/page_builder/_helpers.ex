# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Helpers do
  @moduledoc """
  Saves a builder section through its resource's own actions.
  """

  alias MishkaCmsCore.Runtime.PageBuilder.Section

  # WHAT THE BUILDER WRITES IT GENERATED, so its template is not typed by hand; Elixir from the code
  # drawer is still code. See `MishkaCmsCore.Runtime.Resources.Validations.CodeChange`.
  @builder %{page_code: :builder}

  @doc """
  Persists a builder section (page / layout / error page) by delegating to the resource's
  own `create`/`update` actions, so the resource's `guardedstruct` validation and field
  policies stay the single source of truth (no second schema on the builder side). Create
  vs update is chosen by an `"id"` in `fields`; master vs tenant by the actor's `site_id`
  (a master has `site_id: nil` and uses the bypass `:master_*` actions). `fetch` reads the
  record for an update. Returns the resource's own `{:ok, record}` / `{:error, changeset}`.

  A field whose value is a one-argument function is one that has to be WORKED OUT FROM THE
  ROW BEING WRITTEN — an error page's `error_pages` is the whole list with one entry
  replaced — and it is resolved here, against the record this function has just read and is
  about to update, rather than by the caller against whatever copy it happens to hold. See
  `MishkaCmsCore.Runtime.PageBuilder.Section.save_fields/3`, which is what builds them.

  Pass `typed: true` when the markup was typed by hand rather than generated from the tree — the
  recovery screen's box. The write is then code, as from any form, which a deployment that turned
  code off refuses.
  """
  def save_section(resource_module, fetch, fields, actor, opts \\ []) do
    attrs = Map.drop(fields, ["id"])
    site = Map.get(actor, :site_id) || fields["site_id"]
    context = written_by(opts)

    case fields["id"] do
      id when is_binary(id) and id != "" ->
        update_section(resource_module, fetch, id, site, attrs, actor, context)

      _ ->
        create_section(resource_module, site, Section.apply_fields(attrs, nil), actor, context)
    end
  end

  # `typed: true` — the markup was typed into a box (the recovery screen), not generated from a
  # tree, so it is written as code.
  defp written_by(opts) do
    case Keyword.get(opts, :typed, false) do
      true -> %{}
      false -> @builder
    end
  end

  # THE ACTOR GOES ON THE CHANGESET, NOT ONLY ON THE CALL. Validations and changes run when the
  # changeset is BUILT, so `Ash.create(actor: …)` alone reaches them too late — every one of them saw
  # a nil actor. Nothing noticed until a validation was added that actually asks who is writing, and
  # then the editor drew the tabs, the author typed a helper, and the save silently dropped it.
  defp create_section(resource_module, _site, attrs, %{site_id: nil} = actor, context) do
    resource_module
    |> Ash.Changeset.for_create(:master_create, attrs, actor: actor, context: context)
    |> Ash.create(actor: actor)
  end

  defp create_section(resource_module, site, attrs, actor, context) do
    resource_module
    |> Ash.Changeset.for_create(:create, Map.delete(attrs, "site_id"),
      tenant: site,
      actor: actor,
      context: context
    )
    |> Ash.create(actor: actor)
  end

  # A master writes through `:master_update`, whose `TenantContext` validation requires a nil
  # tenant — and a changeset inherits the tenant its record was loaded under. Reading through the
  # tenant-scoped `fetch` therefore poisoned every master save with "Tenant context must be nil for
  # this action"; the row is read through the resource's own `:master_get` instead, which is the
  # bypass action that exists for exactly this and attaches no tenant.
  defp update_section(resource_module, _fetch, id, _site, attrs, %{site_id: nil} = actor, context) do
    with {:ok, record} <- Ash.get(resource_module, id, action: :master_get, actor: actor) do
      record
      |> Ash.Changeset.for_update(:master_update, written_attrs(attrs, record),
        actor: actor,
        context: context
      )
      |> Ash.update(actor: actor)
    end
  end

  defp update_section(_resource_module, fetch, id, site, attrs, actor, context) do
    with {:ok, record} <- fetch.(id, tenant: site, actor: actor) do
      record
      |> Ash.Changeset.for_update(:update, written_attrs(attrs, record),
        tenant: site,
        actor: actor,
        context: context
      )
      |> Ash.update(actor: actor)
    end
  end

  defp written_attrs(attrs, record),
    do: attrs |> Section.apply_fields(record) |> Map.delete("site_id")
end
