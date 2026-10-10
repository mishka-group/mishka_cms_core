defmodule MishkaCmsCore.Test.ShareCardHostLive do
  @moduledoc """
  A stand-in for an edit modal holding `MishkaCmsCoreWeb.Live.Admin.Components.ShareCardField`, so
  the panel can be driven through `Phoenix.LiveViewTest.live_isolated/3` with a real socket: the
  session names the site (`"site_id"`) and either the `"target"` or the `"record"` with
  `"target_of"`, as the page builder and the admin adapter hand them.
  """
  use Phoenix.LiveView

  alias MishkaCmsCoreWeb.Live.Admin.Components.ShareCardField

  @impl true
  def mount(_params, session, socket),
    do:
      {:ok,
       assign(socket,
         site_id: session["site_id"],
         target: session["target"],
         record: session["record"],
         target_of: target_of(session["target_of"])
       )}

  defp target_of("page"), do: &{:page, &1.id}
  defp target_of("none"), do: fn _record -> nil end
  defp target_of(nil), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component
      module={ShareCardField}
      id="share"
      site_id={@site_id}
      target={@target}
      record={@record}
      target_of={@target_of}
    />
    """
  end
end
