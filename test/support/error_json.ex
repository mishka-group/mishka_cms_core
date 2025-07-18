defmodule MishkaCmsCore.TestErrorJSON do
  @moduledoc """
  Renders an error as JSON for the standalone endpoint.

  Only exists so a failure inside a request surfaces as itself instead of Phoenix's
  "no 500 html template defined for …ErrorView", which masks the real exception.
  """

  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
