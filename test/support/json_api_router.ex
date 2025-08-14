defmodule MishkaCmsCore.TestJsonApiRouter do
  @moduledoc """
  The JSON:API surface these tests call, assembled for this extension alone.

  The CMS's own `MishkaCmsWeb.AshJsonApiRouter` mounts every domain in the system; this one mounts the
  three this library cannot be exercised without.
  """

  use AshJsonApi.Router,
    domains: [MishkaCmsCore.Runtime],
    open_api: "/open_api"
end
