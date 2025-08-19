defmodule MishkaCmsCore.Test.Factory do
  @moduledoc """
  Fixtures for this library's own suite: sites, users, permissions, and the runtime records
  (components, layouts, pages, error pages, JS hooks, media) that everything else is built on.

  These are the same wrappers the CMS's factory exposes and the ones every extension's factory
  re-states, because a path dependency cannot reach into the CMS's `test/support`. The generators
  behind them are `MishkaCmsCore.Dev.Generator`, which ships in `lib/`.

  Records are tenant-scoped, so each wrapper pops `:site_id` and passes it as the Ash tenant; a
  `nil` tenant means the global row.
  """

  import MishkaCmsCore.Dev.Generator, except: [generate: 1, generate: 2]
  import Ash.Generator, only: [generate: 1]

  def create_site!(overrides \\ []) do
    overrides
    |> site()
    |> generate()
  end

  # User factory
  def create_user!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    # User can be global (nil) or site-specific
    tenant = site_id

    overrides
    |> user(tenant)
    |> generate()
  end
end
