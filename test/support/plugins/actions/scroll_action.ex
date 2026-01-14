defmodule MishkaCmsCore.Test.Plugins.Actions.ScrollAction do
  @moduledoc """
  Test action: a package's CLIENT verb, written the way the docs say to write one.

  One box, one `Phoenix.LiveView.JS` command as a term, one `read/2` so it round-trips. Nothing in
  core knows this exists — it reaches the panel through `builder:interactions`.
  """
  use MishkaCmsCore.Builder.Action

  alias MishkaCmsCore.Builder.Action

  @doc "The descriptor the plugin contributes."
  @spec descriptor() :: map()
  def descriptor do
    action(
      key: "acme_scroll",
      label: "Scroll to it",
      priority: 90,
      description: "Slides the page down to whatever this is aimed at."
    )
  end

  @impl true
  def needs(_action), do: [text("offset", "Offset", placeholder: "80")]

  @impl true
  def write(_action, context, values),
    do:
      {:dispatch, ["acme:scroll"], [to: Action.aim(context), detail: %{offset: values["offset"]}]}

  @impl true
  def read(_action, {:dispatch, ["acme:scroll"], opts}) do
    case opts[:detail] do
      %{offset: offset} when is_binary(offset) -> {:ok, %{"offset" => offset}}
      _not_ours -> :no
    end
  end

  def read(_action, _command), do: :no
end
