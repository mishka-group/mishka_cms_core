defmodule MishkaCmsCore.Test.Notify.UserPrefTest do
  @moduledoc """
  Per-user notification opt-out (Settings → Preferences): a recipient can mute a type for THEMSELVES
  (default on) without touching the site toggle or other recipients — the fan-out honours it per row.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.{Notify, Settings}
  alias MishkaCmsCore.Notify.Notification

  defp feed(user) do
    Notification
    |> Ash.Query.for_read(:feed)
    |> Ash.read!(actor: user, tenant: user.site_id, page: false)
  end

  test "a user who opts out of a type stops receiving it; others still do" do
    site = create_site!()
    opted_out = create_user!(site_id: site.id)
    other = create_user!(site_id: site.id)

    Settings.put_user(Notify.user_setting_key("blog:post:published"), false, opted_out.id)

    Notify.deliver({:users, [opted_out.id, other.id]}, %{
      type: "blog:post:published",
      title: "New post"
    })

    assert feed(opted_out) == []
    assert [%{type: "blog:post:published"}] = feed(other)
  end

  test "get_user/put_user round-trips a per-user value, namespaced away from the global key" do
    user = create_user!(site_id: create_site!().id)

    assert Settings.get_user("x.y", user.id, :fallback) == :fallback
    Settings.put_user("x.y", false, user.id)
    assert Settings.get_user("x.y", user.id, true) == false
    # The plain (global) key is untouched.
    assert Settings.get("x.y", :global_default) == :global_default
  end
end
