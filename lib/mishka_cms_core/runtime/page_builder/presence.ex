# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Presence do
  @moduledoc """
  Who else is in this editing session — real `Phoenix.Presence` on the session's own PubSub topic.

  The prototype drew three hardcoded avatars (JD, AB, CD). That is worse than showing none: it tells
  an author their colleagues are watching when nobody is, and it hides the one case that actually
  matters — two people editing the same page, where the editor is last-write-wins at the op level.

  Tracking costs nothing here because the topic already exists: both LiveViews of a session are
  subscribed to it for document updates, so presence rides along.
  """
  use Phoenix.Presence,
    otp_app: :mishka_cms_core,
    pubsub_server: MishkaCmsCore.PubSub

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Accounts.Helper
  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession

  @doc """
  Announces a user as editing `token`. Safe to call with no user — an anonymous mount tracks nothing.

  The entry carries the user's id, initials and whether it is a master, never its email.
  """
  @spec join(String.t(), map() | nil) :: {:ok, binary()} | {:error, term()} | :ignore
  def join(_token, nil), do: :ignore

  def join(token, user) do
    track(self(), EditorSession.topic(token), user.id, %{
      id: user.id,
      master?: Helper.master_user?(user),
      initials: initials(user),
      at: System.system_time(:second)
    })
  end

  @doc "Everyone currently in the session, one entry per person however many tabs they have open."
  @spec editors(String.t()) :: [map()]
  def editors(token) do
    token
    |> EditorSession.topic()
    |> list()
    |> Enum.map(fn {_id, %{metas: [meta | _rest]}} -> meta end)
    |> Enum.sort_by(& &1.at)
  end

  @doc """
  Everyone except `user` — the avatars worth showing, since your own presence is not news.

  A master's avatar reads the first letter of `MishkaCmsCore.Accounts.Helper.label(:master)`, "M",
  unless `user` is a master too.
  """
  @spec others(String.t(), map() | nil) :: [map()]
  def others(token, nil), do: token |> editors() |> Enum.map(&seen_by(&1, nil))

  def others(token, user) do
    token
    |> editors()
    |> Enum.reject(&(&1.id == user.id))
    |> Enum.map(&seen_by(&1, user))
  end

  defp seen_by(%{master?: true} = editor, viewer) do
    case Helper.master_user?(viewer) do
      true -> editor
      false -> %{editor | initials: String.first(Helper.label(:master))}
    end
  end

  defp seen_by(editor, _viewer), do: editor

  @doc ~S"""
  Two letters for an avatar chip, from the local part of an email: `"ada.love@x.com"` gives `"AL"`.

  An address is an `Ash.CiString`, not a binary, so it is stringified rather than guarded on —
  guarding on `is_binary/1` silently produced "?" for every real user.
  """
  @spec initials(map()) :: String.t()
  def initials(%{email: email}) when not is_nil(email) do
    email
    |> to_string()
    |> String.split("@")
    |> hd()
    |> String.split(~r/[._\-+]/, trim: true)
    |> Enum.map(&String.first/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(2)
    |> Enum.map_join(&String.upcase/1)
    |> fallback()
  end

  def initials(_user), do: "?"

  defp fallback(""), do: "?"
  defp fallback(initials), do: initials

  @doc ~S"""
  A display name for a review byline: the local part of the address, `"Someone"` with no user.

  Accounts carry no separate name field, so the address is what there is. The domain is dropped
  because a comment thread reads better as "ada.love" than as a full address.
  """
  @spec display_name(map() | nil) :: String.t()
  def display_name(%{email: email}) when not is_nil(email) do
    email |> to_string() |> String.split("@") |> hd() |> named()
  end

  def display_name(_user), do: gettext("Someone")

  defp named(""), do: gettext("Someone")
  defp named(name), do: name
end
