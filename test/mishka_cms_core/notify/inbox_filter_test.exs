defmodule MishkaCmsCore.Test.Notify.InboxFilterTest do
  @moduledoc """
  The inbox filters resolve through Ash, never raw SQL: the `read?` calculation drives the read/unread
  filter, and severity/title filter on attributes. These are the same Ash filters the Gervaz table
  applies for `filter :read?, :boolean` / `filter :severity, :select` / `filter :search, :text`.
  """
  use MishkaCmsCore.DataCase, async: false

  require Ash.Query

  alias MishkaCmsCore.Notify
  alias MishkaCmsCore.Notify.Notification

  defp titles(records), do: records |> Enum.map(& &1.title) |> Enum.sort()

  defp read!(query, user), do: Ash.read!(query, actor: user, tenant: user.site_id, page: false)

  defp mark_read(user, title) do
    Notification
    |> Ash.Query.for_read(:feed)
    |> Ash.Query.filter(title == ^title)
    |> read!(user)
    |> Enum.each(fn n ->
      n
      |> Ash.Changeset.for_update(:mark_read, %{}, actor: user, tenant: user.site_id)
      |> Ash.update!()
    end)
  end

  test "the read? calculation filters read vs unread through Ash" do
    site = create_site!()
    user = create_user!(site_id: site.id)

    Notify.deliver({:user, user.id}, %{type: "t:a", title: "still unread"})
    Notify.deliver({:user, user.id}, %{type: "t:b", title: "now read"})
    mark_read(user, "now read")

    read =
      Notification |> Ash.Query.for_read(:feed) |> Ash.Query.filter(read? == true) |> read!(user)

    unread =
      Notification |> Ash.Query.for_read(:feed) |> Ash.Query.filter(read? == false) |> read!(user)

    assert titles(read) == ["now read"]
    assert titles(unread) == ["still unread"]
  end

  test "the Status select's filter_input casts a string value to the read? boolean calc" do
    site = create_site!()
    user = create_user!(site_id: site.id)

    Notify.deliver({:user, user.id}, %{type: "t:a", title: "still unread"})
    Notify.deliver({:user, user.id}, %{type: "t:b", title: "now read"})
    mark_read(user, "now read")

    read =
      Notification
      |> Ash.Query.for_read(:feed)
      |> Ash.Query.filter_input(%{"read?" => %{"eq" => "true"}})
      |> read!(user)

    unread =
      Notification
      |> Ash.Query.for_read(:feed)
      |> Ash.Query.filter_input(%{"read?" => %{"eq" => "false"}})
      |> read!(user)

    assert titles(read) == ["now read"]
    assert titles(unread) == ["still unread"]
  end

  test "severity filters through Ash" do
    site = create_site!()
    user = create_user!(site_id: site.id)

    Notify.deliver({:user, user.id}, %{type: "t:a", title: "an info", severity: :info})
    Notify.deliver({:user, user.id}, %{type: "t:b", title: "an error", severity: :error})

    errors =
      Notification
      |> Ash.Query.for_read(:feed)
      |> Ash.Query.filter(severity == :error)
      |> read!(user)

    assert titles(errors) == ["an error"]
  end

  test "a text search filters title/body through Ash" do
    site = create_site!()
    user = create_user!(site_id: site.id)

    Notify.deliver({:user, user.id}, %{type: "t:a", title: "New comment", body: "on your post"})
    Notify.deliver({:user, user.id}, %{type: "t:b", title: "Build failed", body: "compile error"})

    hits =
      Notification
      |> Ash.Query.for_read(:feed)
      |> Ash.Query.filter(contains(title, "comment") or contains(body, "comment"))
      |> read!(user)

    assert titles(hits) == ["New comment"]
  end
end
