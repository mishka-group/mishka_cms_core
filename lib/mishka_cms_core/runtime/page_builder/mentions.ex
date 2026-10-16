# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Mentions do
  @moduledoc """
  Naming somebody in a note: `@who` in the body, and the notification that follows it.

  ## The handle is the whole address

  `MishkaCmsCore.Accounts.User` has no display name — `email` is the only thing a person is called —
  so `@sara@example.com` is how Sara is named. Nothing stores a nickname; the handle is derived on
  every read and cannot drift from the account.

  The whole address rather than its local part, because a local part is not a name: this CMS is
  multi-site, and `master@one.test` and `master@two.test` are two different people who would both
  answer to `@master`. An address is the only handle that names exactly one account, and a mention
  that reaches the wrong person is worse than a mention that is long.

  A bare local part is still UNDERSTOOD — notes written before this, and anyone who types `@sara` by
  hand, still reach every Sara the writer can see. It is simply not what the picker writes.

  ## Who can be named, and who the writer is

  A TENANT may name their own site's people and nobody else. Not another site's — that would leak
  one customer's user list into another's editor — and not the masters, whose addresses belong to
  the platform rather than to any customer. The activity feed draws the same line, and
  `MishkaCmsCoreWeb.Templates.ReviewComments` draws it again on the byline and on a mention, where a
  master reads as "Master" (`master_mentions/2`).

  A MASTER may name anybody the document can reach: the site's people and the other masters. There
  is nobody a master may not see, so there is nothing to hide from them.

  The document matters too, not just the writer: a note on something SHARED has no site of its own,
  so a master's candidates there are the other masters.

  ## Where each piece runs

  `segments/1` and `handles/1` are pure, so the card can highlight a mention and the notifier can
  find one without either calling the other. `candidates/2` is the autocomplete's one query.
  `notify/2` is called from `MishkaCmsCore.Runtime.Resources.Changes.NotifyMentions`, after the row
  exists — a mention that is delivered before the note is saved points at nothing.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.PageBuilder.Section
  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Notify

  require Ash.Query

  # A handle is an address, or the local part of one. The domain is optional so a note that only says
  # `@sara` still names her; the trailing group is whatever punctuation rode along with it.
  @handle ~r/^([A-Za-z0-9._%+-]+(?:@[A-Za-z0-9.-]+\.[A-Za-z]{2,})?)(.*)$/s
  @limit 6

  @typedoc "A body cut into the parts a card draws: plain runs and the people named in them."
  @type segment :: {:text, String.t()} | {:mention, String.t()}

  @doc """
  The notification type, and the key its per-site and per-user toggles hang off.

  Public because `MishkaCmsCore.Application` registers the two Settings under it and
  `MishkaCmsCore.Notify.Delivery` checks them by the same name.
  """
  @spec notification_type() :: String.t()
  def notification_type, do: "cms_core:page_comment:mentioned"

  @doc """
  A note's body, cut into the runs a card draws.

  Splitting on whitespace rather than scanning for `@` is what keeps a quoted address out of it:
  `write to sara@example.com` is one chunk that does not START with `@`, so it stays text, while
  `@sara@example.com` is a chunk that does. Trailing punctuation rides along as text, so
  `@sara@example.com,` still names her.

      iex> alias MishkaCmsCore.Runtime.PageBuilder.Mentions
      iex> Mentions.segments("ping @sara@example.com, thanks")
      [{:text, "ping "}, {:mention, "sara@example.com"}, {:text, ", thanks"}]
  """
  @spec segments(String.t() | nil) :: [segment()]
  def segments(nil), do: []

  def segments(body) when is_binary(body) do
    ~r/(\s+)/
    |> Regex.split(body, include_captures: true)
    |> Enum.flat_map(&classify/1)
    |> Enum.reduce([], &merge/2)
    |> Enum.reverse()
  end

  defp classify("@" <> rest = chunk) do
    case Regex.run(@handle, rest) do
      [_whole, handle, ""] -> [{:mention, handle}]
      [_whole, handle, tail] -> [{:mention, handle}, {:text, tail}]
      nil -> [{:text, chunk}]
    end
  end

  defp classify(chunk), do: [{:text, chunk}]

  defp merge({:text, right}, [{:text, left} | rest]), do: [{:text, left <> right} | rest]
  defp merge({_kind, ""}, acc), do: acc
  defp merge(segment, acc), do: [segment | acc]

  @doc """
  The handles a body names, downcased and without repeats.

  Case is dropped because an address is matched case-insensitively everywhere else in this codebase
  — `Sara@x.test` and `sara@x.test` are one person, and being notified twice for writing both is not
  a feature.
  """
  @spec handles(String.t() | nil) :: [String.t()]
  def handles(body) do
    body
    |> segments()
    |> Enum.flat_map(fn
      {:mention, handle} -> [String.downcase(handle)]
      {:text, _text} -> []
    end)
    |> Enum.uniq()
  end

  @doc """
  Who `query` could mean, for the autocomplete — at most #{@limit}, nearest match first.

  A blank query offers the first few people rather than nothing, so pressing `@` is useful before
  typing anything. Matching is a prefix of the whole address, so `@mas` narrows to the masters and
  `@master@two` narrows those to one site — which is the point of naming people by address.

  `scope[:actor]` decides how far the list reaches; see "Who can be named" above.
  """
  @spec candidates(map(), String.t() | nil) :: [
          %{id: String.t(), handle: String.t(), local: String.t(), domain: String.t()}
        ]
  def candidates(scope, query) do
    needle = query |> to_string() |> String.trim() |> String.downcase()

    # AND WHOEVER ELSE AN EXTENSION CAN NAME. A team plugin that knows about groups, or an
    # integration that can @-mention a channel, contributes here rather than needing its own field.
    scope
    |> visible_users()
    |> Enum.map(&card/1)
    |> then(&MishkaCmsCore.Builder.Events.collect_appended(:mention_sources, &1))
    |> Enum.filter(&String.starts_with?(&1.handle, needle))
    |> Enum.sort_by(& &1.handle)
    |> Enum.take(@limit)
  end

  @doc """
  The handles in `bodies` that name a master and nobody on `site_id`, downcased.

  A whole address names a master when a master holds it. A bare local part does when a master's
  address starts with it and no account of `site_id` does. One read for every body; with no site,
  nothing.
  """
  @spec master_handles([String.t() | nil], String.t() | nil) :: MapSet.t()
  def master_handles(_bodies, nil), do: MapSet.new()

  def master_handles(bodies, site_id) do
    case bodies |> Enum.flat_map(&handles/1) |> Enum.uniq() do
      [] ->
        MapSet.new()

      named ->
        holders = holders(named, site_id)
        named |> Enum.filter(&names_only_a_master?(&1, holders)) |> MapSet.new()
    end
  end

  @doc """
  For each of `notes`, the handles its body names that `reader` may not see: a master's, when
  `reader` is a site user. A master reads every handle. Backs `PageComment.master_mentions`.
  """
  @spec master_mentions([map()], map() | nil) :: [[String.t()]]
  def master_mentions(notes, %{site_id: site_id}) when is_binary(site_id) do
    masked = notes |> Enum.map(& &1.body) |> master_handles(site_id)

    Enum.map(notes, fn note ->
      note.body |> handles() |> Enum.filter(&MapSet.member?(masked, &1))
    end)
  end

  def master_mentions(notes, _reader), do: Enum.map(notes, fn _note -> [] end)

  @doc """
  `body` with every mention in `masked` written as `@Master`. Everything else is kept as written.

      iex> alias MishkaCmsCore.Runtime.PageBuilder.Mentions
      iex> Mentions.mask_masters("ping @Boss@platform.test, thanks", MapSet.new(["boss@platform.test"]))
      "ping @Master, thanks"
  """
  @spec mask_masters(String.t() | nil, MapSet.t()) :: String.t() | nil
  def mask_masters(body, masked) when is_binary(body) do
    body
    |> segments()
    |> Enum.map_join(fn
      {:text, text} ->
        text

      {:mention, handle} ->
        "@" <>
          ((master_handle?(handle, masked) && MishkaCmsCore.Accounts.Helper.label(:master)) ||
             handle)
    end)
  end

  def mask_masters(body, _masked), do: body

  defp master_handle?(handle, masked), do: MapSet.member?(masked, String.downcase(handle))

  # Every account a handle could name: the masters, and the people of `site_id`.
  defp holders(handles, site_id) do
    {addresses, locals} = Enum.split_with(handles, &String.contains?(&1, "@"))

    User
    |> Ash.Query.filter(
      (is_nil(site_id) or site_id == ^site_id) and
        (email in ^addresses or
           fragment("lower(split_part(?::text, '@', 1)) = ANY(?)", email, ^locals))
    )
    |> Ash.Query.select([:email, :site_id])
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, users} ->
        Enum.map(users, &{&1.email |> to_string() |> String.downcase(), &1.site_id})

      {:error, _reason} ->
        []
    end
  end

  defp names_only_a_master?(handle, holders) do
    {masters, people} = Enum.split_with(holders, fn {_address, site_id} -> is_nil(site_id) end)

    case String.contains?(handle, "@") do
      true ->
        Enum.any?(masters, fn {address, _site} -> address == handle end)

      false ->
        Enum.any?(masters, fn {address, _site} -> local_part(address) == handle end) and
          not Enum.any?(people, fn {address, _site} -> local_part(address) == handle end)
    end
  end

  # The address, and the two halves of it the picker draws differently — the person in bold, the
  # place they are in quiet beside it, so a list of four `master@` rows is read by its domains.
  defp card(user) do
    address = user.email |> to_string() |> String.downcase()
    [local | rest] = String.split(address, "@")

    %{
      id: user.id,
      handle: address,
      email: address,
      local: local,
      domain: (rest == [] && "") || "@" <> Enum.join(rest, "@")
    }
  end

  @doc """
  Tell the people a note names that it names them.

  Nothing is delivered to the author: being notified of your own writing is noise, and it is the one
  mention that is certain to be read already. Nothing is delivered for a handle that matches nobody
  either — a typo is not an audience.

  Returns `:ok` whatever happens. A note that saved is saved; a notification centre that is down
  must not turn that into a failed write in front of the person who typed it.
  """
  @spec notify(map(), map()) :: :ok
  def notify(comment, scope \\ %{}) do
    comment
    |> recipients()
    |> deliver(comment, scope)
  end

  defp deliver([], _comment, _scope), do: :ok

  # A master reads the note as written; a site user reads a master's handle as `@Master`.
  defp deliver(users, comment, scope) do
    {masters, people} = Enum.split_with(users, &MishkaCmsCore.Accounts.Helper.master_user?/1)
    masked = master_handles([comment.body], comment.site_id)

    send_to(masters, comment.body, comment, scope)
    send_to(people, mask_masters(comment.body, masked), comment, scope)
  end

  defp send_to([], _body, _comment, _scope), do: :ok

  defp send_to(users, body, comment, scope) do
    Notify.deliver(
      %{
        type: notification_type(),
        title: gettext_noop("You were mentioned in a note"),
        body: excerpt(body),
        icon: "hero-at-symbol",
        link: link(comment, scope),
        source: "cms_core",
        metadata: %{"comment_id" => comment.id, "section" => to_string(comment.section)}
      },
      users: Enum.map(users, & &1.id),
      site_id: comment.site_id,
      actor: comment.author_id,
      # NAMING YOURSELF TELLS YOU NOTHING. `:except` is the one place that decides it — a second
      # filter over the recipients would be a rule with two homes and no way to tell which one is
      # doing the work. Rejected rather than passed straight through because a note may have no
      # author at all: an AI reviewer's has none, and `[nil]` is not an exclusion.
      except: Enum.reject([comment.author_id], &is_nil/1)
    )

    :ok
  end

  # THE AUDIENCE IS WHAT THE PICKER OFFERED. A tenant's note reaches their own site's people, a
  # master's reaches the document's site and the masters — so the writer, not the reader, decides,
  # and a tenant who types a master's address by hand still reaches nobody they could not have
  # picked. The author is looked up rather than passed because this runs from an Ash change, where
  # the only thing in hand is the row.
  defp recipients(comment) do
    handles = handles(comment.body)

    case handles do
      [] ->
        []

      _named ->
        %{site_id: comment.site_id, actor: author(comment)}
        |> visible_users()
        |> Enum.filter(&named?(&1, handles))
    end
  end

  defp author(%{author_id: id}) when is_binary(id) do
    User
    |> Ash.Query.for_read(:read, %{}, authorize?: false)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, user} -> user
      _missing -> nil
    end
  end

  # An AI reviewer's note has no author, and neither has a seed's. Nobody is not a master: such a
  # note reaches its own site's people and no further — see `reachable/3`.
  defp author(_authorless), do: nil

  # AN ADDRESS NAMES ONE ACCOUNT; a bare local part names everyone who answers to it. Both are
  # honoured — the picker writes the address, but a note typed by hand, or written before the picker
  # did, should still reach somebody.
  defp named?(user, handles) do
    address = user.email |> to_string() |> String.downcase()
    address in handles or local_part(address) in handles
  end

  defp visible_users(scope) do
    User
    |> Ash.Query.for_read(:users, %{}, authorize?: false)
    |> reachable(Map.get(scope, :site_id), Map.get(scope, :actor))
    |> Ash.Query.sort(email: :asc)
    |> Ash.read(authorize?: false, page: [limit: 200])
    |> case do
      {:ok, %{results: results}} -> results
      {:ok, results} when is_list(results) -> results
      _unavailable -> []
    end
  end

  # A TENANT REACHES THEIR OWN SITE AND STOPS. Their own site whatever the document is: a tenant
  # writing on a shared component still writes to their own people, because the note is stamped with
  # their site and nobody else will read it.
  defp reachable(query, _site_id, %{site_id: actor_site}) when is_binary(actor_site),
    do: Ash.Query.filter(query, site_id == ^actor_site)

  # A master (`site_id` nil) on something shared reaches the other masters; on a site's document,
  # that site and the masters. Anybody else — no author, an author nobody can find, anything that is
  # not a user — reaches the note's own site's people, and on something shared nobody at all.
  defp reachable(query, site_id, author) do
    case {master?(author), site_id} do
      {true, nil} -> Ash.Query.filter(query, is_nil(site_id))
      {true, site_id} -> Ash.Query.filter(query, site_id == ^site_id or is_nil(site_id))
      {false, nil} -> Ash.Query.filter(query, false)
      {false, site_id} -> Ash.Query.filter(query, site_id == ^site_id)
    end
  end

  # `MishkaCmsCore.Accounts.Helper.master_user?/1` for anything shaped like a user; anything else is
  # no master.
  defp master?(%{site_id: _site_id} = author),
    do: MishkaCmsCore.Accounts.Helper.master_user?(author)

  defp master?(_not_a_user), do: false

  defp local_part(address), do: address |> String.split("@") |> hd()

  defp excerpt(body) when is_binary(body) do
    case String.length(body) do
      length when length > 140 -> String.slice(body, 0, 140) <> "…"
      _short -> body
    end
  end

  defp excerpt(_body), do: ""

  # The editor the note was written in, opened on the document it is about. `error_page` is
  # `error-page` in a URL, which is the only place the two spellings differ.
  defp link(comment, scope) do
    section = comment.section || scope[:section] || :page

    Section.builder_path(section, comment.document_id)
  end
end
