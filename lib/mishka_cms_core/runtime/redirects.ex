defmodule MishkaCmsCore.Runtime.Redirects do
  @moduledoc """
  The redirect rules of each site, answered on the request that asks for an old address.

  `MishkaCmsCore.Runtime.Redirect` is the table and `MishkaCmsCore.Runtime.States.RedirectsState`
  the ETS copy every request reads; this module is what stands between them and the rest of the
  system — the form both addresses are stored in, the rule that a chain of redirects never comes
  back on itself, and the answer a matching request gets.

  ## Where a redirect is answered

  `MishkaCmsCore.Runtime.Plugs.SiteLookupPlug` calls `redirect/2` the moment the request's site is
  known, before the session is touched and before any page is resolved, so a rule answers every
  address the `:browser` pipeline reaches — a page that moved, and a file `Plug.Static` did not find,
  which falls through to the router's catch-all.

  A live navigation inside an open socket reaches no plug; `lookup/3` answers it the same way, for
  the LiveView that serves the site's pages to ask in `handle_params/3`.

  ## The event

  A request answered by a rule is heard on `web:request:redirected`, with the conn already carrying
  its status and `location` and `meta: %{site:, from:, to:, status:}`. A plugin may change the conn,
  the `location` included, or halt it to answer the request itself.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  import Plug.Conn

  require Ash.Query

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.Redirect
  alias MishkaCmsCore.Runtime.States.{RedirectsState, SiteState}
  alias MishkaInstaller.Event.Hook

  @statuses [
    {301, dgettext_noop("mishka_gervaz", "301 Moved permanently")},
    {302, dgettext_noop("mishka_gervaz", "302 Found")},
    {307, dgettext_noop("mishka_gervaz", "307 Temporary")},
    {308, dgettext_noop("mishka_gervaz", "308 Permanent")}
  ]

  @doc "The statuses a rule may answer with."
  @spec statuses() :: [301 | 302 | 307 | 308]
  def statuses, do: Enum.map(@statuses, &elem(&1, 0))

  @doc "The name of `status` in the reader's language, such as `301 Moved permanently`."
  @spec status_label(pos_integer()) :: String.t()
  def status_label(status) do
    case List.keyfind(@statuses, status, 0) do
      {^status, label} -> Gettext.dgettext(MishkaCmsCore.Gettext, "mishka_gervaz", label)
      nil -> to_string(status)
    end
  end

  @doc """
  The statuses as `{label, value}` pairs for a select, each label in the reader's language.
  """
  @spec status_options() :: [{String.t(), pos_integer()}]
  def status_options, do: Enum.map(statuses(), &{status_label(&1), &1})

  @doc "Whether `status` tells a browser and a search engine the move is for good: 301 and 308."
  @spec permanent?(pos_integer()) :: boolean()
  def permanent?(status), do: status in [301, 308]

  @doc """
  Whether `user` writes redirect rules from the dashboard: it holds
  `admin:dashboard:runtime:redirect`, or a name above it. Which site's rules it writes is the
  resource's policies' question.
  """
  @spec writes?(map() | nil) :: boolean()
  def writes?(user) when is_map(user),
    do:
      AccessPermissions.match?(AccessPermissions.with_permissions(user), %{},
        permissions: ["admin:dashboard:runtime:redirect"]
      )

  def writes?(_user), do: false

  @doc """
  The address a rule answers, as it is stored and matched: one leading `/`, no scheme or host, no
  query or fragment, no empty segment and so no trailing `/` but the root's, and every `%XX` escape
  decoded. `:error` for what cannot be an address on a site: an empty value, whitespace or a control
  character, a scheme other than `http` or `https`, or an escape that decodes to invalid UTF-8.

      normalize_path("https://mishka.tools/images/blog/a.jpg?w=1") #=> {:ok, "/images/blog/a.jpg"}
      normalize_path("old-page/")                                  #=> {:ok, "/old-page"}
      normalize_path("/fa/%D8%A8%D9%84%D8%A7%DA%AF")               #=> {:ok, "/fa/بلاگ"}
      normalize_path("/a b")                                       #=> :error
  """
  @spec normalize_path(String.t()) :: {:ok, String.t()} | :error
  def normalize_path(value) when is_binary(value) do
    value = String.trim(value)

    with true <- value != "" and String.valid?(value) and not spaced?(value),
         %URI{scheme: scheme, path: path} when scheme in [nil, "http", "https"] <-
           URI.parse(value),
         key = key(path || "/"),
         true <- String.valid?(key) do
      {:ok, key}
    else
      _not_an_address -> :error
    end
  end

  @doc """
  Where a rule may send a visitor, trimmed: a path on the site (`/x`, with a query or a fragment if
  it has one) or an absolute `http(s)` URL with a host. `:error` for anything else — `//host`
  included, which a browser reads as another host.
  """
  @spec normalize_target(String.t()) :: {:ok, String.t()} | :error
  def normalize_target(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" or not String.valid?(value) or spaced?(value) -> :error
      site_path?(value) -> {:ok, value}
      absolute?(value) -> {:ok, value}
      true -> :error
    end
  end

  # The CMS's own addresses: the dashboard, the APIs and LiveView's connection. A rule on one would
  # send whoever manages the site — and the editor's own socket — somewhere else.
  @reserved ["/admin", "/api", "/live", "/phoenix"]

  @doc "Whether `path` (normalized) is one of the CMS's own addresses, which no rule may take."
  @spec reserved?(String.t()) :: boolean()
  def reserved?(path),
    do: Enum.any?(@reserved, &(path == &1 or String.starts_with?(path, &1 <> "/")))

  @doc """
  The change every create and update of `MishkaCmsCore.Runtime.Redirect` runs: `from_path` through
  `normalize_path/1` and `to` through `normalize_target/1`, each only when it is being written. A
  value neither accepts is refused on its field, and so is a `from_path` that `reserved?/1`.
  """
  @spec normalize(Ash.Changeset.t(), map()) :: Ash.Changeset.t()
  def normalize(changeset, _context) do
    changeset
    |> normalize_field(
      :from_path,
      &normalize_path/1,
      dgettext_noop("errors", "Enter an address on this site, such as /old-page.")
    )
    |> normalize_field(
      :to,
      &normalize_target/1,
      dgettext_noop(
        "errors",
        "Enter a path on this site starting with /, or a full http:// or https:// address."
      )
    )
    |> refuse_reserved()
  end

  defp refuse_reserved(changeset) do
    case Ash.Changeset.fetch_change(changeset, :from_path) do
      {:ok, path} when is_binary(path) ->
        if reserved?(path),
          do:
            Ash.Changeset.add_error(changeset,
              field: :from_path,
              message:
                dgettext_noop(
                  "errors",
                  "This address belongs to the CMS itself (/admin, /api, /live) and cannot be redirected."
                )
            ),
          else: changeset

      _not_written ->
        changeset
    end
  end

  defp normalize_field(changeset, field, normalizer, message) do
    case Ash.Changeset.fetch_change(changeset, field) do
      {:ok, value} when is_binary(value) ->
        case normalizer.(value) do
          {:ok, normalized} -> Ash.Changeset.force_change_attribute(changeset, field, normalized)
          :error -> Ash.Changeset.add_error(changeset, field: field, message: message)
        end

      _not_written ->
        changeset
    end
  end

  @doc """
  The validation every create and update of `MishkaCmsCore.Runtime.Redirect` runs: a rule that will
  be served refuses a target that is its own source, and a target the site's other active rules lead
  back from — to the source or to any address already on the way. A rule leaving the site, or for a
  host `MishkaCmsCore.Runtime.States.SiteState` gives another site, ends the chain.

  Checked when the rule is written active, or restored, and when its addresses or its `active`
  change — as the action runs, not while a form is being typed. The other rules are read with the
  action's own actor, tenant and authorization, so a check the system runs reads as the system.
  """
  @spec no_loop(Ash.Changeset.t(), map()) :: :ok | {:error, keyword()}
  def no_loop(changeset, context) do
    from = Ash.Changeset.get_attribute(changeset, :from_path)
    to = Ash.Changeset.get_attribute(changeset, :to)

    if is_binary(from) and is_binary(to) and served?(changeset) and loop_question?(changeset) do
      site_id = Ash.Changeset.get_attribute(changeset, :site_id)

      rule = %{
        site_id: site_id,
        id: Ash.Changeset.get_attribute(changeset, :id),
        opts: Ash.Scope.to_opts(context, tenant: site_id)
      }

      case local_path(site_id, to) do
        {:ok, ^from} ->
          {:error,
           field: :to,
           message: dgettext_noop("errors", "A redirect cannot send an address to itself.")}

        {:ok, target} ->
          follow(target, target, MapSet.new([from]), rule)

        :external ->
          :ok
      end
    else
      :ok
    end
  end

  defp served?(changeset), do: Ash.Changeset.get_attribute(changeset, :active) == true

  defp loop_question?(changeset) do
    changeset.action.name in [:unarchive, :master_unarchive] or
      Enum.any?([:from_path, :to, :active], &Ash.Changeset.changing_attribute?(changeset, &1))
  end

  # Walks the site's active rules from `target`, one read per step, until one leaves the site, none
  # matches, or an address comes round again.
  defp follow(target, path, seen, rule) do
    if MapSet.member?(seen, path) do
      {:error,
       field: :to,
       message:
         dgettext_noop(
           "errors",
           "This would make a loop: the redirects from %{target} come back to %{path}."
         ),
       vars: [target: target, path: path]}
    else
      case next(path, rule) do
        {:ok, %Redirect{to: to}} -> step(target, local_path(rule.site_id, to), seen, path, rule)
        {:ok, nil} -> :ok
        {:error, _error} = error -> error
      end
    end
  end

  defp step(target, {:ok, path}, seen, from, rule),
    do: follow(target, path, MapSet.put(seen, from), rule)

  defp step(_target, :external, _seen, _from, _rule), do: :ok

  defp next(path, %{id: id, opts: opts}) do
    Redirect
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(from_path == ^path and active == true)
    |> other_than(id)
    |> Ash.read_one(opts)
  end

  defp other_than(query, nil), do: query
  defp other_than(query, id), do: Ash.Query.filter(query, id != ^id)

  # WHERE A TARGET LANDS, as an address of the rule's own site: a path is one, and so is an absolute
  # URL whose host resolves to the same site. Any other host is `:external`.
  defp local_path(site_id, target) do
    if site_path?(target) do
      normalize_path(target)
    else
      %URI{host: host, path: path} = URI.parse(target)

      case SiteState.get_by_host(host) do
        {:ok, %{id: ^site_id}} -> normalize_path(path || "/")
        _another_site -> :external
      end
    end
  end

  @doc """
  The rule `site_id` serves for `request_path`, as `{location, status}` — the target with the
  request's `query_string` added when it has none of its own — or `nil`. Read from
  `MishkaCmsCore.Runtime.States.RedirectsState`, with no query.
  """
  @spec lookup(String.t(), String.t(), String.t()) :: {String.t(), pos_integer()} | nil
  def lookup(site_id, request_path, query_string) do
    case RedirectsState.lookup(site_id, key(request_path)) do
      {to, status} -> {location(to, query_string), status}
      nil -> nil
    end
  end

  @doc """
  Answers `conn` with the redirect `site` serves for its path, if any: the rule's status, the
  `location` from `lookup/3`, and a halt. A conn no rule matches is returned untouched.

  A plugin on `web:request:redirected` hears every one first — see the moduledoc.
  """
  @spec redirect(Plug.Conn.t(), %{id: String.t()}) :: Plug.Conn.t()
  def redirect(conn, %{id: site_id} = site) do
    case lookup(site_id, conn.request_path, conn.query_string) do
      {location, status} -> answer(conn, site, location, status)
      nil -> conn
    end
  end

  defp answer(conn, site, location, status) do
    conn =
      conn
      |> put_status(status)
      |> put_resp_header("location", location)
      |> then(
        &Hook.call("web:request:redirected", &1,
          meta: %{site: site, from: conn.request_path, to: location, status: status}
        )
      )

    if conn.halted do
      conn
    else
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(conn.status, "")
      |> halt()
    end
  end

  # THE KEY A PATH IS STORED AND LOOKED UP UNDER. Escapes are decoded with no raise: a `%` that is not
  # followed by two hex digits stays as it is, and bytes that are not UTF-8 make a key no rule has.
  defp key(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&decode/1)
    |> case do
      [] -> "/"
      segments -> "/" <> Enum.join(segments, "/")
    end
  end

  defp decode(segment),
    do:
      Regex.replace(~r/%([0-9A-Fa-f]{2})/, segment, fn _escape, hex ->
        <<String.to_integer(hex, 16)>>
      end)

  # A LOCATION IS SENT AS ASCII. A path written with Persian letters is escaped byte by byte, and an
  # escape already in it is kept as it is.
  defp location(to, query_string) do
    uri = URI.parse(to)

    uri =
      if is_nil(uri.query) and query_string != "", do: %{uri | query: query_string}, else: uri

    uri
    |> URI.to_string()
    |> URI.encode(&(&1 in 0x21..0x7E))
  end

  defp site_path?("//" <> _rest), do: false
  defp site_path?("/" <> _rest), do: true
  defp site_path?(_target), do: false

  defp absolute?(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        host != ""

      _other ->
        false
    end
  end

  defp spaced?(value), do: Regex.match?(~r/[\s\p{Cc}]/u, value)
end
