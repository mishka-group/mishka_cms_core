# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Plugs.LanguagePlug do
  @moduledoc """
  Answers every request in the language its address names, sends one whose address is not the
  site's form of it to the one that is, and remembers which language the visitor is reading.

  ## The rule

  A site's pages are stored under a language — `/:lang/about`, or a literal `/fa/pricing` — and
  `site.language_urls` (`MishkaCmsCore.Runtime.Languages.url_mode/1`) says how a public address
  names it. Only the FIRST segment is ever read as a language.

  With no prefix for the primary language (`"prefix_others"`, the default), the address decides
  and nothing about the visitor does:

      /blog        -> served in the primary language, as /en/blog would have been
      /fa/blog     -> served, and `fa` is remembered
      /en/blog     -> 301 /blog            (en is the primary language)
      /            -> served in the primary language, whatever the session says

  With a prefix for every language (`"prefix_all"`):

      /fa/pricing  -> served, and `fa` is remembered
      /blog        -> 302 /fa/blog         (after the line above)
      /no-lang     -> served in its page's own language, when a page is stored there

  Which language `"prefix_all"` sends a visitor to is their remembered one when the site still
  publishes in it, and `MishkaCmsCore.Runtime.Languages.primary/1` otherwise — the first of the
  site's list. A remembered language the page has no edition in falls back to that same first
  language rather than to a 404: an address that does not name a language is not a request for one.

  ## What is NOT redirected

  Nothing here keeps a list of addresses to leave alone. It asks
  `MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState` whether an address exists, which is the same
  question the request itself is about to ask, so the answers cannot drift apart:

    * a path that already resolves is served as it stands — a page stored at `/no-lang` keeps its
      address, and moving it under a language would be inventing one it does not have
    * a path that resolves under neither form is left alone and 404s
    * a route Phoenix owns — `/admin/...`, `/api/...`, an asset bundle, `/mish-...` — is neither
      moved nor remembered: it is answered in the visitor's remembered language, else the site's
      first, so its Gettext strings are in the language they were reading, and the language a
      visitor reads pages in is the last page's, never the admin's or a stylesheet's. The admin keeps
      its own, `MishkaCmsCore.Runtime.Languages.admin_session/0`.

  ## Why it is told which route the CMS answers

  `:router` and `:live_view` are required, and only a request the router would hand to that LiveView
  is ever redirected, or remembered. Without them, an author who published a page at `/en/admin`
  would take a Phoenix route down: `/admin` would resolve under a language, and the rule above would
  send every visitor from one to the other. A static route already wins the match — this makes it
  win the language rule too.

      plug MishkaCmsCore.Runtime.Plugs.LanguagePlug,
        router: MishkaCmsWeb.Router,
        live_view: MishkaCmsWeb.RuntimeLive

  ## 301 or 302

  The primary language's prefix is dropped with a 301: `/en/blog` is `/blog` for every visitor, so a
  browser and a crawler may keep that answer. Sending an address with no language to one is a 302:
  where a visitor goes depends on their session, and a 301 would be cached by the browser and keep
  sending them to `/en/blog` after they had chosen Persian. A crawler, which carries no session,
  always lands on `primary/1` and reads the `hreflang` alternates
  `MishkaCmsWeb.RuntimeLive.page_head/1` puts in the head.

  ## Asked in two places

  `call/2` answers an HTTP request. A LIVE navigation inside an open socket never reaches a plug, so
  `MishkaCmsWeb.RuntimeLive.handle_params/3` asks `target/3` the same question for `<.link navigate>`
  and `push_patch`. One function, so a link cannot behave one way on a fresh load and another on a
  click.
  """
  @behaviour Plug

  import Plug.Conn

  alias MishkaCmsCore.Runtime.{Languages, PageEditions}
  alias MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState

  @section "Page"

  @impl Plug
  def init(opts) do
    for key <- [:router, :live_view], is_nil(opts[key]) do
      raise ArgumentError, "#{inspect(__MODULE__)} needs :#{key} — see its @moduledoc"
    end

    opts
  end

  @impl Plug
  def call(%Plug.Conn{assigns: %{current_site: %{name: name, id: id}}} = conn, opts) do
    remembered = conn |> get_session(Languages.session()) |> Languages.remembered(id)

    if answered_by_the_cms?(conn, opts) do
      case target(conn.path_info, {name, id}, remembered) do
        {:serve, language} -> speaking(conn, language)
        {:redirect, path, status} -> redirect_to(conn, path <> query(conn), status)
      end
    else
      reading(conn, remembered || Languages.primary(id))
    end
  end

  def call(conn, _opts), do: conn

  @doc """
  Where a request for `segments` belongs: `{:serve, language}` to answer it where it is, or
  `{:redirect, path, status}` to send it to the site's form of its address — `301` for a primary
  language's prefix the site leaves off, `302` for a language chosen for the visitor.

  `site` is the `{name, id}` pair — the name is what the routing table is keyed by, the id is what
  the language settings are keyed by. `remembered` is a language already put through
  `MishkaCmsCore.Runtime.Languages.remembered/2`, or `nil`.

      # site.languages ["en", "fa"], site.language_urls "prefix_others"
      target(["fa", "pricing"], {"localhost", id}, nil) #=> {:serve, "fa"}
      target(["en", "blog"], {"localhost", id}, nil)    #=> {:redirect, "/blog", 301}
      target(["blog"], {"localhost", id}, "fa")         #=> {:serve, "en"}

      # site.language_urls "prefix_all"
      target(["blog"], {"localhost", id}, "fa")         #=> {:redirect, "/fa/blog", 302}
  """
  @spec target([String.t()], {String.t(), String.t()}, String.t() | nil) ::
          {:serve, String.t()} | {:redirect, String.t(), 301 | 302}
  def target(segments, {name, id}, remembered) do
    [primary | _others] = languages = Languages.site(id)

    case {Languages.url_mode(id), Languages.leading(segments, languages)} do
      {"prefix_others", ^primary} ->
        unprefixed(segments, id, primary)

      {_mode, language} when is_binary(language) ->
        {:serve, language}

      {"prefix_others", nil} ->
        {:serve, primary}

      {"prefix_all", nil} ->
        prefixed(segments, {name, id}, Enum.uniq([remembered, primary] -- [nil]))
    end
  end

  # THE PRIMARY LANGUAGE'S ADDRESS IS THE ONE WITHOUT IT. A path that makes no address — one that
  # spells a capture — is left to 404 where it is.
  defp unprefixed(segments, site_id, primary) do
    case Languages.url(path(segments), %{}, site_id) do
      nil -> {:serve, primary}
      path -> {:redirect, path, 301}
    end
  end

  defp prefixed(segments, {name, id}, tried) do
    case WebRunTimeMetaDataState.resolve(path(segments), name) do
      {:ok, %{section: @section} = page, captured} ->
        {:serve, PageEditions.language(page, captured, id)}

      _not_a_page ->
        under(segments, name, tried)
    end
  end

  # THE REMEMBERED LANGUAGE FIRST, THE SITE'S OWN AFTER IT. A visitor who once chose Persian and
  # then asks for an address with no language would otherwise be sent to a Persian page that does
  # not exist — the home page has an English edition and no Persian one — and land on a 404 that a
  # visitor with no session at all does not get. Falling back to the site's first language is what
  # a reader wants and what every multilingual CMS does; an address that NAMES a language is never
  # touched by this, so `/fa/about` still 404s when nobody wrote it.
  defp under(segments, site, tried) do
    tried
    |> Enum.map(&path([&1 | segments]))
    |> Enum.find(&published?(&1, site))
    |> case do
      nil -> {:serve, hd(tried)}
      path -> {:redirect, path, 302}
    end
  end

  @doc """
  The language this connection is answering in, once `call/2` has run.

  `MishkaCmsWeb.Router` hands it to `live_session` so a socket knows the language of a page whose
  own address does not name one.
  """
  @spec spoken(Plug.Conn.t()) :: String.t() | nil
  def spoken(conn), do: conn.assigns[:site_language]

  # ONE PLACE SETS THE LANGUAGE, so the assign, the session and Gettext cannot disagree. Only an
  # address the CMS answers is a page the visitor reads, so only that one is remembered.
  defp speaking(conn, language),
    do: conn |> reading(language) |> put_session(Languages.session(), language)

  defp reading(conn, language) do
    Gettext.put_locale(language)
    assign(conn, :site_language, language)
  end

  # A LIVE ROUTE KEEPS ITS VIEW IN THE METADATA, not in `:plug_opts` — that one holds the live
  # ACTION, which is `nil` for a route declared without one. Comparing against it matched nothing,
  # so nothing was ever redirected; `:plug_opts` is still read for a plain plug route.
  defp answered_by_the_cms?(conn, opts) do
    case Phoenix.Router.route_info(opts[:router], conn.method, conn.path_info, conn.host) do
      %{phoenix_live_view: {view, _action, _opts, _meta}} -> view == opts[:live_view]
      %{plug_opts: plug_opts} -> plug_opts == opts[:live_view]
      _no_route -> false
    end
  end

  # ONLY A PAGE. A layout or an error page is in the same table under its own section, and neither is
  # an address a visitor may be sent to.
  defp published?(path, site) do
    match?({:ok, %{section: @section}, _captured}, WebRunTimeMetaDataState.resolve(path, site))
  end

  defp path([]), do: "/"
  defp path(segments), do: "/" <> Enum.join(segments, "/")

  defp query(%Plug.Conn{query_string: ""}), do: ""
  defp query(%Plug.Conn{query_string: query}), do: "?" <> query

  defp redirect_to(conn, path, status) do
    conn
    |> put_resp_header("location", path)
    |> put_resp_content_type("text/html")
    |> send_resp(status, "")
    |> halt()
  end
end
