# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Changes.ErrorPageAddress do
  @moduledoc """
  Writes an error page's path from the site it belongs to, on every action that can set one.

  `MishkaCmsCore.Runtime.ErrorAddress` holds the rule and says why there is one: the renderer
  derives the address it looks a row up by, so a path anybody typed was a path that had to match a
  string in another module by luck, and one that did not produce an error page nothing could ever
  render.

  ## Why the action and not the form

  Because there are five ways a row arrives — the Gervaz form, the builder's essentials step, the
  JSON:API, a seed and a restore — and the form is one of them. The same reason
  `MishkaCmsCore.Runtime.Resources.Changes.SignCode` lives here.

  ## On update as well as create

  A site can be renamed, and every error page under it would quietly stop resolving. Forcing the
  address on update means the next save of an affected row repairs it, which is the only repair
  anybody would think to try. It cannot fight the author over the field either: `update` accepts no
  `site_id`, so the site this derives from is the one already on the record.

  ## Where the site id comes from

  Whichever half the action has. A tenant create is given the site as the tenant, a master create as
  an attribute, an update by the record it loaded. Nothing is derived when none of them answers —
  the action's own `present` and `TenantContext` validations are what refuse that, and this change
  refusing it too would be a second message for one mistake.
  """

  use Ash.Resource.Change

  alias MishkaCmsCore.Runtime.ErrorAddress

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def change(changeset, _opts, _context) do
    case changeset |> site_id() |> ErrorAddress.for_site() do
      nil -> changeset
      path -> Ash.Changeset.force_change_attribute(changeset, :path, path)
    end
  end

  defp site_id(changeset) do
    Ash.Changeset.get_attribute(changeset, :site_id) || changeset.data.site_id ||
      changeset.tenant
  end
end
