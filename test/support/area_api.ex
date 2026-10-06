defmodule MishkaCmsCoreWeb.Test.AreaApi do
  @moduledoc """
  The three JSON:API calls an area test makes on a runtime resource — create, list, update — as a
  bearer, so the area tests of every resource read the same.

      token = AuthTestHelpers.area_token!(site, ["admin:api:runtime:layout"])
      assert AreaApi.post(path, "layout", token, %{"name" => "x", "path" => "/x"}).status == 201
  """

  import MishkaCmsCore.ConnCase, only: [make_api_request: 3]

  @doc "POSTs a new record of `type` to `path`."
  def post(path, type, token, attributes) do
    make_api_request(path, %{"type" => type, "attributes" => attributes},
      method: :post,
      headers: headers(token)
    )
  end

  @doc "GETs the list at `path`."
  def list(path, token), do: make_api_request(path, %{}, method: :get, headers: headers(token))

  @doc "PATCHes the record `id` of `type` at `path`."
  def patch(path, type, id, token, attributes) do
    make_api_request("#{path}/#{id}", %{"type" => type, "id" => id, "attributes" => attributes},
      method: :patch,
      headers: headers(token)
    )
  end

  @doc "A name no other test in the run has used."
  def unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp headers(token),
    do: [
      {"authorization", "Bearer #{token}"},
      {"content-type", "application/vnd.api+json"}
    ]
end
