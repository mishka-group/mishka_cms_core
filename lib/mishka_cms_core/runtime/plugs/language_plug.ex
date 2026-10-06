defmodule MishkaCmsCore.Runtime.Plugs.LanguagePlug do
  @moduledoc """
  Puts every request on an address that names the language it is answered in, and remembers which
  one the visitor is reading.

  ## The rule

  A site's pages are stored under a language — `/:lang/about`, or a literal `/fa/pricing`. An
  address that names none is not an address the site publishes at, so it is sent to one:

      /            -> /en
      /blog        -> /en/blog
      /fa/pricing  -> served, and `fa` is remembered
      /blog        -> /fa/blog          (after the line above)

  Which language a visitor is sent to is their remembered one when the site still publishes in it,
  and `MishkaCmsCore.Runtime.Languages.primary/1` otherwise — the first of the site's list. A
  remembered language the page has no edition in falls back to that same first language rather than
  to a 404: an address that does not name a language is not a request for one.

  ## What is NOT redirected

  Nothing here keeps a list of addresses to leave alone. It asks
  `MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState` whether an address exists, which is the same
  question the request itself is about to ask, so the answers cannot drift apart:

    * a path that already resolves is served as it stands — a page stored at `/no-lang` keeps its
      address, and moving it under a language would be inventing one it does not have
    * a path that resolves under neither form is left alone and 404s, or is a route Phoenix owns:
      `/auth`, `/admin/...`, `/mish-...`. They still get the locale set, so their Gettext strings are
      in the visitor's language, but their addresses are none of this module's business.

  ## Why it is told which route the CMS answers

  `:router` and `:live_view` are required, and only a request the router would hand to that LiveView
  is ever redirected. Without them, an author who published a page at `/en/auth` would take the sign
  in page down: `/auth` is a Phoenix route, `/en/auth` would resolve, and the rule above would send
  every visitor from one to the other. A static route already wins the match — this makes it win the
  language rule too.

      plug MishkaCmsCore.Runtime.Plugs.LanguagePlug,
        router: MishkaCmsWeb.Router,
        live_view: MishkaCmsWeb.RuntimeLive

  ## The redirect is a 302, deliberately

  Where a visitor is sent depends on their session, so a 301 would be cached by the browser and
  keep sending them to `/en/blog` after they had chosen Persian. A crawler, which carries no
  session, always lands on `primary/1` and reads the `hreflang` alternates
  `MishkaCmsWeb.RuntimeLive.page_head/1` puts in the head — which is how the other languages are
  discovered, rather than through this redirect.

  ## Asked in two places

  `call/2` answers an HTTP request. A LIVE navigation inside an open socket never reaches a plug, so
  `MishkaCmsWeb.RuntimeLive.handle_params/3` asks `target/3` the same question for `<.link navigate>`
  and `push_patch`. One function, so a link cannot behave one way on a fresh load and another on a
  click.
  """
  @behaviour Plug

  import Plug.Conn

  alias MishkaCmsCore.Runtime.Languages
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

    case target(conn.path_info, {name, id}, remembered) do
      {:serve, language} ->
        speaking(conn, language)

      {:redirect, path, language} ->
        if answered_by_the_cms?(conn, opts) do
          redirect_to(conn, path <> query(conn))
        else
          speaking(conn, language)
        end
    end
  end

  def call(conn, _opts), do: conn

  @doc """
  Where a request for `segments` belongs: `{:serve, language}` to answer it where it is, or
  `{:redirect, path}` to send it to an address that names a language.

  `site` is the `{name, id}` pair — the name is what the routing table is keyed by, the id is what
  the language settings are keyed by. `remembered` is a language already put through
  `MishkaCmsCore.Runtime.Languages.remembered/2`, or `nil`.

      target(["fa", "pricing"], {"localhost", id}, nil)  #=> {:serve, "fa"}
      target(["blog"], {"localhost", id}, "fa")          #=> {:redirect, "/fa/blog", "fa"}
      target(["no-lang"], {"localhost", id}, nil)        #=> {:serve, "en"}
  """
  @spec target([String.t()], {String.t(), String.t()}, String.t() | nil) ::
          {:serve, String.t()} | {:redirect, String.t(), String.t()}
  def target(segments, {name, id}, remembered) do
    case Languages.leading(segments, Languages.site(id)) do
      language when is_binary(language) ->
        {:serve, language}

      nil ->
        tried = Enum.uniq([remembered, Languages.primary(id)] -- [nil])

        if published?(path(segments), name) do
          {:serve, hd(tried)}
        else
          under(segments, name, tried)
        end
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
    |> Enum.map(&{&1, path([&1 | segments])})
    |> Enum.find(fn {_language, path} -> published?(path, site) end)
    |> case do
      {language, path} -> {:redirect, path, language}
      nil -> {:serve, hd(tried)}
    end
  end

  @doc """
  The language this connection is answering in, once `call/2` has run.

  `MishkaCmsWeb.Router` hands it to `live_session` so a socket knows the language of a page whose
  own address does not name one.
  """
  @spec spoken(Plug.Conn.t()) :: String.t() | nil
  def spoken(conn), do: conn.assigns[:site_language]

  # ONE PLACE SETS THE LANGUAGE, so the assign, the session and Gettext cannot disagree. A redirect
  # passes `nil`: the request is not being answered, and the response it is sent to will set all
  # three itself.
  defp speaking(conn, nil), do: conn

  defp speaking(conn, language) do
    Gettext.put_locale(language)

    conn
    |> assign(:site_language, language)
    |> put_session(Languages.session(), language)
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

  # 302, not 301 — see the moduledoc.
  defp redirect_to(conn, path) do
    conn
    |> put_resp_header("location", path)
    |> put_resp_content_type("text/html")
    |> send_resp(302, "")
    |> halt()
  end
end
