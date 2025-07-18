defmodule MishkaCmsCore.TestRouter do
  @moduledoc """
  The routes this library's tests drive, mirroring the two scopes the CMS puts it in.
  """

  use Phoenix.Router

  pipeline :api do
  end

  pipeline :browser do
  end
end
