# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.BuilderAccess do
  @moduledoc """
  A policy check: the actor may open the builder the row's own section names — its runtime area or
  `admin:dashboard:code` (`MishkaCmsCore.Runtime.PageBuilder.Section.permissions/1`).

  Snippets, review notes and builder history each carry the section they were written in, so the
  names they need are read off the row:

      policies do
        policy action_type([:create, :read, :update, :destroy]) do
          authorize_if {MishkaCmsCore.Runtime.PageBuilder.BuilderAccess, field: :section}
        end
      end

  A create is decided by the section it writes; a read, update or destroy reaches the rows whose
  section the actor holds. The site scope of `MishkaCmsCore.Accounts.Checks.AccessPermissions`
  applies: a site user holds nothing under another site's tenant.

  ## Options

    * `:field` — the attribute holding the section (`:page`, `:layout`, `:component`,
      `:error_page`). Required.
  """
  use Ash.Policy.FilterCheck

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.PageBuilder.Section

  @impl true
  def describe(opts), do: "actor may open the builder its #{opts[:field]} names"

  @impl true
  def filter(actor, %{subject: %Ash.Changeset{action_type: :create} = changeset} = context, opts),
    do: Ash.Changeset.get_attribute(changeset, opts[:field]) in sections(actor, context)

  def filter(actor, context, opts) do
    field = Ash.Expr.ref(opts[:field])
    sections = sections(actor, context)

    expr(^field in ^sections)
  end

  @doc "The sections whose builder `actor` may open, as the atoms the builder's rows store."
  @spec sections(map() | nil, map()) :: [atom()]
  def sections(nil, _context), do: []

  def sections(actor, context) do
    actor = AccessPermissions.with_permissions(actor)

    Enum.filter(Section.atoms(), fn section ->
      AccessPermissions.match?(actor, context, permissions: Section.permissions(section))
    end)
  end
end
