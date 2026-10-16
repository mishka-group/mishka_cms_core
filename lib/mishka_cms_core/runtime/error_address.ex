# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.ErrorAddress do
  @moduledoc """
  The one path a site's error pages are served from, and the row sitting at it.

  ## It is not a path anybody chooses

  A page is reached by its path, so its path is a decision. An error page is not: nothing routes to
  it. When a request fails, `MishkaCmsWeb.ErrorHTML.render/2` works out an address from the site it
  is answering for and looks the row up by exactly that — so an error page stored at any other path
  compiles, appears in the list, reports itself healthy, and is never rendered for anything.

  That made the Path box on the error-page form the one field in the admin where typing the truth
  was luck. This module is the rule it was missing, and the rule is the renderer's own:

      /mishka-cms/errors/<site name>

  ## One per site, and the database already said so

  `ErrorPage` carries a `unique_path_per_site` identity. Once the path is the site's own, a second
  error page for that site is a second row at the same path, which is refused — so "a site has one
  error page" stops being a convention nobody enforced and becomes the shape of the table. `find/1`
  is how the admin asks for the one that is already there instead of offering to make another.

  ## Why the site is read rather than passed

  Because the callers have different halves of it. A tenant create knows the site id and nothing
  else; a master create knows the id it was given; an update knows only what is on the record. Each
  one reading the name for itself would be three places to get a stale answer, so they all ask here
  with the id they have.
  """

  alias MishkaCmsCore.Runtime.ErrorPage
  alias MishkaCmsCore.Runtime.Site

  require Ash.Query

  @prefix "/mishka-cms/errors/"

  @doc """
  The address a site's error pages answer at.

      iex> MishkaCmsCore.Runtime.ErrorAddress.path("localhost")
      "/mishka-cms/errors/localhost"
  """
  @spec path(String.t()) :: String.t()
  def path(site_name) when is_binary(site_name), do: @prefix <> site_name

  @doc """
  The address for a site id, or `nil` when the site cannot be read.

  `nil` is the honest answer and not a failure: a create that has not been told which site yet has
  no address to derive, and the action's own `present`/`TenantContext` validations are what say so.
  """
  @spec for_site(term()) :: String.t() | nil
  def for_site(site_id) when is_binary(site_id) do
    case Ash.get(Site, site_id, action: :get_any, authorize?: false) do
      {:ok, %{name: name}} when is_binary(name) -> path(name)
      _unreadable -> nil
    end
  end

  def for_site(_site_id), do: nil

  @doc """
  The error page a site already has, or `nil`.

  Read with multitenancy bypassed and no actor, because the question is about the table rather than
  about who is asking: the admin needs the same answer for a master choosing this site and for the
  tenant who lives in it, and "there is already one, here it is" is not a disclosure either of them
  could not make by trying to create one.
  """
  @spec find(term()) :: struct() | nil
  def find(site_id) when is_binary(site_id) do
    ErrorPage
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site_id and is_nil(archived_at))
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read()
    |> case do
      {:ok, [record | _rest]} -> record
      {:ok, %{results: [record | _rest]}} -> record
      _none -> nil
    end
  end

  def find(_site_id), do: nil
end
