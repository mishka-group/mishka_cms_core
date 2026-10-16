# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Notify.ContentSanitizeTest do
  @moduledoc """
  GuardedStruct is the pre-DB layer over Ash: it sanitizes notification content (strips HTML tags a
  producer may carry over from user text and keeps the rest as typed, trims) on write, and gives
  producers a `builder/1` to validate + sanitize a notification as a struct BEFORE calling
  `deliver/3`.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Notify
  alias MishkaCmsCore.Notify.Notification

  defp feed(user) do
    Notification
    |> Ash.Query.for_read(:feed)
    |> Ash.read!(actor: user, tenant: user.site_id, page: false)
  end

  test "content is sanitized (HTML stripped, trimmed) before it is stored" do
    site = create_site!()
    user = create_user!(site_id: site.id)

    Notify.deliver({:user, user.id}, %{
      type: "test:x",
      title: "  <b>Hello</b> there  ",
      body: "<i>the body</i>"
    })

    [n] = feed(user)
    refute n.title =~ "<"
    refute n.title =~ ">"
    assert n.title == String.trim(n.title)
    assert n.title =~ "Hello"
    refute n.body =~ "<"
  end

  test "the text is stored as typed, without its markup, and storing it again changes nothing" do
    site = create_site!()
    user = create_user!(site_id: site.id)

    Notify.deliver({:user, user.id}, %{
      type: "test:x",
      title: ~s(Tom & Jerry's <b>"cat"</b>),
      body: "<script>alert(1)</script>Hi & bye"
    })

    [n] = feed(user)
    assert n.title == ~s(Tom & Jerry's "cat")
    assert n.body == "alert(1)Hi & bye"

    Notify.deliver({:user, user.id}, %{type: "test:x", title: n.title, body: n.body})

    assert [n.title] == user |> feed() |> Enum.map(& &1.title) |> Enum.uniq()
    assert [n.body] == user |> feed() |> Enum.map(& &1.body) |> Enum.uniq()
  end

  test "builder/1 validates + sanitizes a notification before the DB" do
    assert {:ok, built} =
             Notification.builder(%{type: "blog:x", title: "  <b>Hi</b>  ", body: "b"})

    refute built[:title] =~ "<"
    assert built[:title] == String.trim(built[:title])
    assert built[:title] =~ "Hi"
  end

  test "builder/1 rejects an empty title" do
    assert {:error, _} = Notification.builder(%{type: "blog:x", title: ""})
  end
end
