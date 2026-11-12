# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

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

  ## What a rule answers

  A rule's `kind` says what the visitor gets, as the answer `lookup/3` gives:

    * `:redirect` — `{:redirect, location, status}`: sent to `to` with 301, 302, 307 or 308.
    * `:rewrite` — `{:rewrite, path, 200}`: the address stays in the browser and `path`, one of the
      site's own, is served at it. A media file under `/uploads/<site_id>/media/` is sent by
      `redirect/2` the way the endpoint serves it; any other path is a page, which the LiveView that
      serves the site's pages resolves in place of the address asked for. The target is served as it
      is, never looked up again, so a rewrite cannot loop.
    * `:gone` — `{:gone, nil, 410}` and `:not_found` — `{:not_found, nil, 404}`: the site's error
      page with that status.

  A request whose page is rewritten goes on through the pipeline with its target in
  `conn.private[:mishka_cms_rewrite]`, so `MishkaCmsCore.Runtime.Plugs.LanguagePlug` leaves the
  address it asked for where it is.

  ## The event

  Every answer a rule gives passes through `web:request:redirected` before it is served, with
  `meta: %{site_id:, path:, query:}` — the address as the request asked it. A target is only ever
  the stored row's: nothing the request carries — its query values, its `Host` — becomes a
  `location`, and a path on the site takes the visitor's query string as its query alone. A plugin returns the
  answer to serve: the same one, another in the same shape (a redirect turned into a 410, a target
  of its own), or `nil` to serve none, so the request goes on to its page. Only a request a rule
  names reaches it; an extension that adds rules of its own writes them as
  `MishkaCmsCore.Runtime.Redirect` rows, which are served from memory like every other.

  ## A record that moved

  An address no rule names may still be a record's old one: a post asked for under a category it is
  no longer filed in. When the address resolves to a page
  (`MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState.resolve_all/2`) whose kind of record the
  plugin that names it declared with `moves: true` (`MishkaCmsCore.Runtime.Seo.records_event/0`),
  `moved_event/0` is asked with `nil` and `meta: %{site_id:, site:, page:, record:, params:, path:,
  query:}`: the site's name, the page as memory holds it, its kind of record, what its pattern
  captured, and the address as the request asked it. A plugin returns `{to, status}`, a path on the
  site and 301, 302, 307 or 308, to send the visitor there, or `nil` (handed on unchanged) to let the
  page answer. The answer is served as a rule's: checked with `safe_target?/1`, given the request's
  query string when it has none, passed through `web:request:redirected`, sent by `redirect/2` and
  followed by a live navigation through `lookup/3`. An answer that points at the address itself is
  dropped.

  The page and the kinds are read from memory, and a page of a kind that does not move never asks,
  so a request pays for the event only where an extension wants it.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  import Plug.Conn

  require Ash.Query

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.ErrorsExceptions.NotFoundError
  alias MishkaCmsCore.Runtime.{Media, Redirect, Seo, SiteAvailability}
  alias MishkaCmsCore.Runtime.States.{RedirectsState, SiteState, WebRunTimeMetaDataState}
  alias MishkaInstaller.Event.Hook

  @statuses [
    {301, dgettext_noop("mishka_gervaz", "301 Moved permanently")},
    {302, dgettext_noop("mishka_gervaz", "302 Found")},
    {307, dgettext_noop("mishka_gervaz", "307 Temporary")},
    {308, dgettext_noop("mishka_gervaz", "308 Permanent")}
  ]

  @kinds [
    {:redirect, dgettext_noop("mishka_gervaz", "Redirect")},
    {:rewrite, dgettext_noop("mishka_gervaz", "Rewrite")},
    {:gone, dgettext_noop("mishka_gervaz", "Gone (410)")},
    {:not_found, dgettext_noop("mishka_gervaz", "Not found (404)")}
  ]

  @moved_event "runtime:page:moved"

  @doc "The event a plugin answers a record's old address on, as the moduledoc describes."
  @spec moved_event() :: String.t()
  def moved_event, do: @moved_event

  @doc "What a rule may answer: `:redirect`, `:rewrite`, `:gone` or `:not_found`."
  @spec kinds() :: [:redirect | :rewrite | :gone | :not_found]
  def kinds, do: Enum.map(@kinds, &elem(&1, 0))

  @doc "The name of `kind` in the reader's language."
  @spec kind_label(atom()) :: String.t()
  def kind_label(kind) do
    case List.keyfind(@kinds, kind, 0) do
      {^kind, label} -> Gettext.dgettext(MishkaCmsCore.Gettext, "mishka_gervaz", label)
      nil -> to_string(kind)
    end
  end

  @doc "The kinds as `{label, value}` pairs for a select, each label in the reader's language."
  @spec kind_options() :: [{String.t(), atom()}]
  def kind_options, do: Enum.map(kinds(), &{kind_label(&1), &1})

  @doc """
  The kind the admin form holds now, `:redirect` until one is chosen — what decides which of its
  fields it shows. `state` is the form's gervaz state.
  """
  @spec form_kind(map()) :: atom()
  def form_kind(%{form: %Phoenix.HTML.Form{} = form}) do
    case Phoenix.HTML.Form.input_value(form, :kind) do
      kind when is_atom(kind) and not is_nil(kind) ->
        kind

      kind when is_binary(kind) and kind != "" ->
        Enum.find(kinds(), :redirect, &(to_string(&1) == kind))

      _none ->
        :redirect
    end
  end

  def form_kind(_state), do: :redirect

  @doc """
  Whether the admin form's "Match a query string" box is ticked, which is what shows its `from_query`
  field. `state` is the form's gervaz state.
  """
  @spec form_match_query?(map()) :: boolean()
  def form_match_query?(%{form: %Phoenix.HTML.Form{} = form}),
    do: Phoenix.HTML.Form.input_value(form, :match_query) in [true, "true"]

  def form_match_query?(_state), do: false

  @doc """
  The admin form once opened: a rule that already has a `from_query` starts with the "Match a query
  string" box ticked.
  """
  @spec tick_match_query(Phoenix.HTML.Form.t(), map()) :: Phoenix.HTML.Form.t()
  def tick_match_query(
        %Phoenix.HTML.Form{source: %AshPhoenix.Form{data: %{from_query: query}}} = form,
        _state
      )
      when is_binary(query) and query != "" do
    AshPhoenix.Form.update_params(form, &Map.put(&1, "match_query", "true"))
  end

  def tick_match_query(form, _state), do: form

  @doc """
  The admin form's save params with `from_query` emptied when the "Match a query string" box was
  unticked, so a rule stops matching its query.
  """
  @spec clear_unmatched_query(map()) :: map()
  def clear_unmatched_query(%{"form" => %{"match_query" => "false"} = values} = params),
    do: %{params | "form" => Map.put(values, "from_query", "")}

  def clear_unmatched_query(params), do: params

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
         {:ok, _parsed} <- value |> URI.encode(&(&1 in 0x21..0x7E)) |> URI.new(),
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
  The query string a rule answers, as it is stored and matched: a leading `?` dropped, every
  parameter decoded, and the parameters in order, joined with `&`. `nil` for none.

  `*` as the value — `p=*` — is a rule's wildcard: it answers that parameter with any value, at its
  own path, when no rule on the exact query does. A wildcard is a rule's whole query.

      normalize_query("?page_id=7")   #=> "page_id=7"
      normalize_query("p=1&cat=%33")  #=> "cat=3&p=1"
      normalize_query("p=*")          #=> "p=*"
      normalize_query("")             #=> nil
  """
  @spec normalize_query(String.t() | nil) :: String.t() | nil
  def normalize_query(nil), do: nil

  def normalize_query(value) when is_binary(value) do
    case value |> String.trim() |> String.trim_leading("?") |> query_pairs() do
      [] -> nil
      pairs -> joined(pairs)
    end
  end

  # At most this many parameters of a request are each tried as a rule's query.
  @query_pairs 20

  defp query_pairs(query) do
    query
    |> URI.query_decoder()
    |> Enum.take(@query_pairs)
    |> Enum.reject(fn {key, _value} -> key == "" end)
    |> Enum.sort()
  rescue
    _malformed -> []
  end

  defp joined(pairs), do: Enum.map_join(pairs, "&", fn {key, value} -> key <> "=" <> value end)

  @doc """
  Where a rule may send a visitor, trimmed: a path on the site (`/x`, with a query or a fragment if
  it has one) or an absolute `http(s)` URL with a host. `:error` for anything `safe_target?/1`
  refuses.
  """
  @spec normalize_target(String.t()) :: {:ok, String.t()} | :error
  def normalize_target(value) when is_binary(value) do
    value = String.trim(value)
    if safe_target?(value), do: {:ok, value}, else: :error
  end

  @doc """
  Whether `target` is somewhere a visitor may be sent, asked when a rule is saved and again when
  its answer is built. Both `target` and its `URI.decode/1` form must hold no whitespace, control
  character or `\\` (which a browser reads as `/`), and must parse with `URI.new/1` as the same one
  of:

    * a path on the site — no scheme, no host, no userinfo, one leading `/` (`//host` is another
      host to a browser);
    * a full address — `http` or `https`, a host, and no userinfo (`http://good.com@evil.com` goes
      to `evil.com`).

  So `/%2F%2Fevil.com`, `/%5Cevil.com`, `javascript:` and `data:` are all refused.

      safe_target?("/fa/blog?page=2")         #=> true
      safe_target?("https://docs.example.com") #=> true
      safe_target?("//evil.com")              #=> false
      safe_target?("http://good.com@evil.com") #=> false
  """
  @spec safe_target?(String.t()) :: boolean()
  def safe_target?(target) when is_binary(target) do
    with true <- target != "" and String.valid?(target),
         {:ok, decoded} <- decoded(target),
         true <- clean?(target) and clean?(decoded),
         shape when shape != :error <- shape(target) do
      shape(decoded) == shape
    else
      _refused -> false
    end
  end

  def safe_target?(_target), do: false

  defp decoded(value) do
    decoded = URI.decode(value)
    if String.valid?(decoded), do: {:ok, decoded}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp clean?(value), do: not spaced?(value) and not String.contains?(value, "\\")

  # `URI.new/1` refuses what is not ASCII, and a path on the site may be written in Persian letters,
  # so they are escaped for the parse alone.
  defp shape(value) do
    case value |> URI.encode(&(&1 in 0x21..0x7E)) |> URI.new() do
      {:ok, %URI{scheme: nil, host: nil, userinfo: nil, path: "/" <> rest}} ->
        if String.starts_with?(rest, "/"), do: :error, else: :local

      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        :external

      _refused ->
        :error
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
  Where a rewrite may serve from: a path on the site with no query or fragment, none of the CMS's
  own (`reserved?/1`), as `normalize_path/1` writes it. `:error` for anything else, a full address
  included: a rewrite never fetches from another host.

      rewrite_target("/fa/blog/hello")  #=> {:ok, "/fa/blog/hello"}
      rewrite_target("https://x.com/a") #=> :error
      rewrite_target("/admin")          #=> :error
  """
  @spec rewrite_target(String.t()) :: {:ok, String.t()} | :error
  def rewrite_target(value) when is_binary(value) do
    with {:ok, "/" <> _ = target} <- normalize_target(value),
         %URI{query: nil, fragment: nil} <- URI.parse(target),
         {:ok, path} <- normalize_path(target),
         false <- reserved?(path) do
      {:ok, path}
    else
      _not_the_sites_own -> :error
    end
  end

  @doc """
  The change every create and update of `MishkaCmsCore.Runtime.Redirect` runs: `from_path` through
  `normalize_path/1` and `from_query` through `normalize_query/1`, each only when it is being
  written, and `to` by the rule's `kind` — `normalize_target/1` for a redirect, `rewrite_target/1`
  for a rewrite, and none for a 410 or a 404. A value these refuse is refused on its field, and so
  is a `from_path` that `reserved?/1` and a wildcard among other parameters.
  """
  @spec normalize(Ash.Changeset.t(), map()) :: Ash.Changeset.t()
  def normalize(changeset, _context) do
    changeset
    |> normalize_query_field()
    |> normalize_field(
      :from_path,
      &normalize_path/1,
      dgettext_noop("errors", "Enter an address on this site, such as /old-page.")
    )
    |> normalize_to(Ash.Changeset.get_attribute(changeset, :kind))
    |> refuse_reserved()
  end

  defp normalize_to(changeset, :redirect) do
    normalize_field(
      changeset,
      :to,
      &normalize_target/1,
      dgettext_noop(
        "errors",
        "Enter a path on this site starting with /, or a full http:// or https:// address."
      )
    )
  end

  # A REWRITE'S TARGET IS CHECKED WHENEVER THE RULE IS, so a redirect turned into one cannot keep a
  # target on another host.
  defp normalize_to(changeset, :rewrite) do
    case Ash.Changeset.get_attribute(changeset, :to) do
      to when is_binary(to) ->
        case rewrite_target(to) do
          {:ok, path} ->
            Ash.Changeset.force_change_attribute(changeset, :to, path)

          :error ->
            Ash.Changeset.add_error(changeset,
              field: :to,
              message:
                dgettext_noop(
                  "errors",
                  "A rewrite serves a page or a media file of this site: enter its path, starting with /, with no query. The CMS's own addresses cannot be served."
                )
            )
        end

      _none ->
        changeset
    end
  end

  defp normalize_to(changeset, _gone_or_not_found),
    do: Ash.Changeset.force_change_attribute(changeset, :to, nil)

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

  defp normalize_query_field(changeset) do
    case Ash.Changeset.fetch_change(changeset, :from_query) do
      {:ok, value} ->
        value |> normalize_query() |> put_query(changeset)

      :error ->
        changeset
    end
  end

  defp put_query(query, changeset) when is_binary(query) do
    case String.split(query, "&") do
      [_one] ->
        Ash.Changeset.force_change_attribute(changeset, :from_query, query)

      pairs ->
        if Enum.any?(pairs, &String.ends_with?(&1, "=*")),
          do:
            Ash.Changeset.add_error(changeset,
              field: :from_query,
              message:
                dgettext_noop(
                  "errors",
                  "A wildcard such as p=* is a rule's whole query: write it alone."
                )
            ),
          else: Ash.Changeset.force_change_attribute(changeset, :from_query, query)
    end
  end

  defp put_query(nil, changeset),
    do: Ash.Changeset.force_change_attribute(changeset, :from_query, nil)

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
  The validation every create and update of `MishkaCmsCore.Runtime.Redirect` runs on where a rule
  that will be served lands.

  A redirect refuses a target that is its own source, and a target the site's other active
  redirects lead back from — to the source or to any address already on the way. A rule leaving the
  site, or for a host `MishkaCmsCore.Runtime.States.SiteState` gives another site, ends the chain.
  A rewrite refuses its own address, and a file that is not one of its site's media files
  (`MishkaCmsCore.Runtime.Media.storage_paths/2`); it is served without being looked up again, so
  it never takes part in a chain.

  Checked when the rule is written active, or restored, and when its addresses, its `kind` or its
  `active` change — as the action runs, not while a form is being typed. The other rules are read
  with the action's own actor, tenant and authorization, so a check the system runs reads as the
  system.
  """
  @spec check_target(Ash.Changeset.t(), map()) :: :ok | {:error, keyword()}
  def check_target(changeset, context) do
    from = Ash.Changeset.get_attribute(changeset, :from_path)
    to = Ash.Changeset.get_attribute(changeset, :to)

    if is_binary(from) and is_binary(to) and served?(changeset) and target_question?(changeset) do
      site_id = Ash.Changeset.get_attribute(changeset, :site_id)

      rule = %{
        site_id: site_id,
        id: Ash.Changeset.get_attribute(changeset, :id),
        opts: Ash.Scope.to_opts(context, tenant: site_id)
      }

      lands(
        Ash.Changeset.get_attribute(changeset, :kind),
        local_path(site_id, to),
        from,
        Ash.Changeset.get_attribute(changeset, :from_query),
        to,
        rule
      )
    else
      :ok
    end
  end

  # WHERE THE TARGET LANDS decides what is asked. A rule on a query sends its address on without that
  # query, so it loops only on a target that carries a query it answers back; the rules on paths
  # alone are never asked by the address it lands on.
  defp lands(:rewrite, {:ok, from}, from, nil, _to, _rule), do: itself()

  defp lands(:rewrite, {:ok, "/uploads/" <> _ = path}, _from, _query, _to, rule) do
    case Media.storage_paths(path, rule.site_id) do
      {:ok, _paths} ->
        :ok

      :error ->
        {:error,
         field: :to,
         message:
           dgettext_noop(
             "errors",
             "A rewritten file must be one of this site's media files, under /uploads/<site>/media/."
           )}
    end
  end

  defp lands(:rewrite, _target, _from, _query, _to, _rule), do: :ok

  defp lands(:redirect, {:ok, from}, from, nil, _to, _rule), do: itself()

  defp lands(:redirect, {:ok, from}, from, query, to, _rule) do
    if query in query_candidates(URI.parse(to).query || ""), do: itself(), else: :ok
  end

  defp lands(:redirect, {:ok, _target}, _from, query, _to, _rule) when is_binary(query), do: :ok

  defp lands(:redirect, {:ok, target}, from, nil, _to, rule),
    do: follow(target, target, MapSet.new([from]), rule)

  defp lands(:redirect, :external, _from, _query, _to, _rule), do: :ok

  defp itself,
    do:
      {:error,
       field: :to,
       message: dgettext_noop("errors", "A redirect cannot send an address to itself.")}

  defp served?(changeset), do: Ash.Changeset.get_attribute(changeset, :active) == true

  defp target_question?(changeset) do
    changeset.action.name in [:unarchive, :master_unarchive] or
      Enum.any?(
        [:from_path, :from_query, :to, :kind, :active],
        &Ash.Changeset.changing_attribute?(changeset, &1)
      )
  end

  # Walks the site's active redirects from `target`, one read per step, until one leaves the site, none
  # matches, or an address comes round again.
  defp follow(target, path, seen, rule) do
    if MapSet.member?(seen, path) do
      {:error,
       field: :to,
       message:
         dgettext_noop(
           "errors",
           "This would make a loop: the redirects from %{target} come back to %{address}."
         ),
       target: target,
       address: path}
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
    |> Ash.Query.filter(
      from_path == ^path and is_nil(from_query) and kind == :redirect and active == true
    )
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

  @typedoc "What a rule answers a request with — see the moduledoc."
  @type answer ::
          {:redirect, String.t(), 301 | 302 | 307 | 308}
          | {:rewrite, String.t(), 200}
          | {:gone, nil, 410}
          | {:not_found, nil, 404}

  @doc """
  The answer `site_id` serves for `request_path` and `query_string` (with no `?`), or `nil`. Read
  from `MishkaCmsCore.Runtime.States.RedirectsState`, with no query, then passed through
  `web:request:redirected` — see the moduledoc.

  A request with a query string asks first for a rule on its whole query, then on each of its
  parameters (`p=123` among `p=123&utm_source=x`), then on each parameter's wildcard (`p=*`), and a
  redirect sends it to that rule's target as written. Otherwise the rule on the path alone answers,
  and a redirect's target takes the request's `query_string` when it has none of its own. A request
  with no query string asks for the path alone.

      lookup(site.id, "/old", "page=2")  #=> {:redirect, "/new?page=2", 301}
      lookup(site.id, "/", "p=55")       #=> {:rewrite, "/fa/blog/hello", 200}
      lookup(site.id, "/retired", "")    #=> {:gone, nil, 410}
      lookup(site.id, "/about", "")      #=> nil
  """
  @spec lookup(String.t(), String.t(), String.t()) :: answer() | nil
  def lookup(site_id, request_path, query_string) do
    path = key(request_path)

    case answer(by_query(site_id, path, query_string), "") ||
           answer(RedirectsState.lookup(site_id, path, nil), query_string) ||
           answer(moved(site_id, path, request_path, query_string), query_string) do
      nil ->
        nil

      answer ->
        Hook.call("web:request:redirected", answer,
          meta: %{site_id: site_id, path: request_path, query: query_string}
        )
    end
  end

  defp moved(site_id, path, request_path, query_string) do
    with {:ok, %{name: site}} <- SiteState.get(site_id),
         [{%{section: "Page", record: record} = page, captured} | _rest] <-
           WebRunTimeMetaDataState.resolve_all(path, site),
         true <- Seo.moves?(record),
         {to, status} when is_binary(to) <-
           Hook.call(@moved_event, nil,
             meta: %{
               site_id: site_id,
               site: site,
               page: page,
               record: record,
               params: captured,
               path: request_path,
               query: query_string
             }
           ),
         true <- status in statuses() and normalize_path(to) != {:ok, path} do
      {:redirect, to, status}
    else
      _stays -> nil
    end
  end

  defp by_query(_site_id, _path, ""), do: nil

  defp by_query(site_id, path, query_string) do
    query_string
    |> query_candidates()
    |> Enum.find_value(&RedirectsState.lookup(site_id, path, &1))
  end

  # THE QUERIES A REQUEST'S QUERY STRING ASKS FOR, the exact ones before the wildcards: its whole
  # query, each of its parameters, then each parameter's `key=*`.
  defp query_candidates(query_string) do
    pairs = query_pairs(query_string)

    [pairs | Enum.map(pairs, &[&1])]
    |> Enum.concat(Enum.map(pairs, fn {key, _value} -> [{key, "*"}] end))
    |> Enum.reject(&(&1 == []))
    |> Enum.map(&joined/1)
    |> Enum.uniq()
  end

  # THE TARGET IS ASKED AGAIN AS THE ANSWER IS BUILT, so a row written past the resource — by hand, by
  # an import — still sends nobody to another host.
  defp answer(nil, _query_string), do: nil

  defp answer({:redirect, to, status}, query_string) do
    if safe_target?(to), do: {:redirect, location(to, query_string), status}
  end

  defp answer({:rewrite, to, _status}, _query_string) do
    case rewrite_target(to) do
      {:ok, ^to} -> {:rewrite, to, 200}
      _refused -> nil
    end
  end

  defp answer({:gone, _to, _status}, _query_string), do: {:gone, nil, 410}
  defp answer({:not_found, _to, _status}, _query_string), do: {:not_found, nil, 404}

  @doc """
  Answers `conn` with what `site` serves for its address, if anything, from `lookup/3`:

    * a redirect — its status and `location`, halted;
    * a rewritten media file — the file, sent as the endpoint sends `/uploads`, halted; a file that
      is not there is the site's 404;
    * a rewritten page — the conn goes on, with the target in `conn.private[:mishka_cms_rewrite]`;
    * a 410 or a 404 — the site's error page with that status, raised in a `Plug.Conn.WrapperError`
      that carries this conn, so `render_errors` draws the site's own page.

  A file, a 410 and a 404 are answered only while the site is open
  (`MishkaCmsCore.Runtime.SiteAvailability.state/1`); on an offline site the conn goes on, for the
  gate that answers an offline site to answer it. A `GET` or `HEAD` whose path has an empty segment,
  `//about/`, and is none of the CMS's own addresses (`reserved?/1`), is first sent with a 301 to the same path with each `//` made one `/`, `/about/`, its
  query kept; the target always starts with a single `/`, so `//evil.com` is `/evil.com` on this
  site. A conn no rule matches is returned untouched.
  """
  @spec redirect(Plug.Conn.t(), %{required(:id) => String.t(), optional(atom()) => term()}) ::
          Plug.Conn.t()
  def redirect(conn, %{id: site_id}) do
    case single_slashed(conn) || lookup(site_id, conn.request_path, conn.query_string) do
      nil -> conn
      {:redirect, location, status} -> moved(conn, location, status)
      answer -> served(conn, site_id, answer)
    end
  end

  # AN ADDRESS WITH AN EMPTY SEGMENT (`//about/`) is sent to the one with each `//` made `/`, its
  # trailing `/` and query kept: a path that starts with one `/`, with a backslash escaped, which a
  # browser reads as `/`, so never another host. The CMS's own addresses (`reserved?/1`) are left to
  # their own guards.
  defp single_slashed(%Plug.Conn{method: method, request_path: path} = conn)
       when method in ["GET", "HEAD"] do
    if String.contains?(path, "//") and not reserved?(key(path)),
      do: {:redirect, (collapsed(path) <> queried(conn.query_string)) |> escaped(), 301}
  end

  defp single_slashed(_conn), do: nil

  defp collapsed(path) do
    case String.split(path, "/", trim: true) do
      [] -> "/"
      segments -> "/" <> Enum.join(segments, "/") <> trailing(String.ends_with?(path, "/"))
    end
  end

  defp trailing(true), do: "/"
  defp trailing(false), do: ""

  defp queried(""), do: ""
  defp queried(query), do: "?" <> query

  defp escaped(location), do: URI.encode(location, &(&1 in 0x21..0x7E and &1 != ?\\))

  defp moved(conn, location, status) do
    conn
    |> put_resp_header("location", location)
    |> put_resp_content_type("text/html")
    |> send_resp(status, "")
    |> halt()
  end

  defp served(conn, site_id, {:rewrite, "/uploads/" <> _ = to, _status}) do
    case {SiteAvailability.state(site_id), media_file(to, site_id)} do
      {:open, {:ok, segments}} -> file(conn, segments)
      {:open, :error} -> refuse!(conn, 404)
      _closed -> conn
    end
  end

  defp served(conn, _site_id, {:rewrite, to, _status}),
    do: put_private(conn, :mishka_cms_rewrite, to)

  defp served(conn, site_id, {_gone_or_not_found, _to, status}) do
    if SiteAvailability.state(site_id) == :open, do: refuse!(conn, status), else: conn
  end

  # SERVED BY `Plug.Static` AS THE ENDPOINT SERVES `/uploads`, with its ETag, its content type and its
  # 304, from the target's own path. The rule was refused unless the target is one of its site's
  # media files.
  # `no-cache` and not the endpoint's day: a cache keeps the file under the address asked for, and
  # asks again with its ETag each time, so a rule pointed at another file, or turned into a 410, is
  # answered at once.
  @static Plug.Static.init(
            at: "/",
            from: {Media, :static_dir, []},
            only: ~w(uploads),
            cache_control_for_etags: "public, no-cache"
          )

  # ASKED AGAIN AS THE FILE IS SENT, with no disk read: the target is a file in the site's own media
  # folder, and climbs out of it through no `.` or `..`.
  defp media_file(to, site_id) do
    case String.split(to, "/", trim: true) do
      ["uploads", ^site_id, "media" | [_ | _] = inner] = segments ->
        if Enum.any?(inner, &(&1 in [".", ".."])), do: :error, else: {:ok, segments}

      _another_folder ->
        :error
    end
  end

  defp file(conn, segments) do
    case Plug.Static.call(%{conn | path_info: segments}, @static) do
      %Plug.Conn{halted: true} = served -> served
      _missing -> refuse!(conn, 404)
    end
  end

  # NO CACHE KEEPS IT, so the address answers again the moment the rule is changed or removed.
  defp refuse!(conn, status) do
    raise Plug.Conn.WrapperError,
      conn: put_resp_header(conn, "cache-control", "no-store"),
      kind: :error,
      reason: %NotFoundError{message: "Not found", plug_status: status},
      stack: []
  end

  # THE KEY A PATH IS STORED AND LOOKED UP UNDER, decoded and in NFC as a page's path is
  # (`MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState.canonical_path/1`). Escapes are decoded
  # with no raise: a `%` that is not followed by two hex digits stays as it is, and bytes that are
  # not UTF-8 make a key no rule has.
  defp key(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&decode/1)
    |> case do
      [] -> "/"
      segments -> "/" <> Enum.join(segments, "/")
    end
    |> nfc()
  end

  defp decode(segment),
    do:
      Regex.replace(~r/%([0-9A-Fa-f]{2})/, segment, fn _escape, hex ->
        <<String.to_integer(hex, 16)>>
      end)

  defp nfc(key) do
    case String.valid?(key) do
      true -> String.normalize(key, :nfc)
      false -> key
    end
  end

  # A LOCATION IS THE STORED TARGET, SENT AS ASCII. A path written with Persian letters is escaped
  # byte by byte, and an escape already in it is kept as it is. Only a path on the site takes the
  # visitor's query, as its query and nothing else; a full address leaves exactly as it was stored.
  defp location(to, query_string) do
    to
    |> URI.parse()
    |> with_query(site_path?(to), query_string)
    |> URI.to_string()
    |> URI.encode(&(&1 in 0x21..0x7E))
  end

  defp with_query(%URI{query: nil} = uri, true, query_string) when query_string != "",
    do: %{uri | query: query_string}

  defp with_query(uri, _site_path?, _query_string), do: uri

  defp site_path?("//" <> _rest), do: false
  defp site_path?("/" <> _rest), do: true
  defp site_path?(_target), do: false

  defp spaced?(value), do: Regex.match?(~r/[\s\p{Cc}]/u, value)
end
