defmodule MishkaCmsWeb.Runtime.Plugs.SecurityHeaders do
  @moduledoc """
  The response headers that are the same whatever was asked for, and the Content-Security-Policy,
  which is not.

  ## Two audiences, two policies

  The admin and the sites it publishes are the same application on the same origin, so the policy
  cannot be chosen by pipeline — every browser route goes through `:browser`. It is chosen by path.

  A PUBLIC page is nearly strict already: measured, a database-backed page carries one inline
  `<script>` (the theme bootstrap, which now takes a nonce) and no inline `style` at all.

  The ADMIN cannot be, and the reason is the page builder. `vendor/tailwind-browser.js` is Tailwind
  compiled to run in the browser: the reader types `px-7` into the inspector and the utility has to
  exist a frame later, which it achieves by creating a `<style>` element — precisely what
  `style-src` governs, from a library that offers no nonce. An editor that generates CSS at runtime
  and a strict `style-src` cannot both be had.

  ## Report-only first

  `:report_only` is the default because a policy is a guess until the browser has checked it against
  real pages. It sends `Content-Security-Policy-Report-Only`, which reports violations and blocks
  nothing. Move to `:enforce` once the reports are quiet:

      config :mishka_cms, #{inspect(__MODULE__)}, csp: :enforce   # or :report_only, or :off

  ## `x-frame-options` was set to DENY, and the builder is an iframe

  DENY forbids framing by ANY page, including one from the same origin — and the editor's canvas is
  a same-origin iframe of `/admin/dashboard/runtime/builder-canvas/…`. It used to work in development
  only by accident: `tidewave` (then a `only: [:dev]` dependency, plugged into the endpoint) deleted
  the header in a `before_send` callback so its own iframe survived, and took the editor's along with
  it. In production nothing deleted it. That dependency is gone, which would have returned the bug
  had this header still said DENY.

  So: `SAMEORIGIN`, and `frame-ancestors 'self'` for browsers that read CSP instead — which is all
  of them, and which is why the header is kept only for the ones that do not.
  """
  import Plug.Conn

  alias MishkaCmsCore.Captcha
  alias MishkaCmsCore.PluginEvent
  alias MishkaCmsCore.Runtime.CspNonce
  alias MishkaCmsCore.Settings

  @nonce_bytes 18

  # Anchor links to github, x.com and the rest are not fetches and CSP does not govern them. What a
  # page actually LOADS from elsewhere was measured: Google Fonts on the marketing pages, and
  # nothing else. Everything else — the compiled site CSS and JS, media, the LiveSocket — is
  # same-origin.
  @fonts_css "https://fonts.googleapis.com"
  @fonts_files "https://fonts.gstatic.com"

  # An origin a page may frame: https, a host of dot-separated labels, an optional port. No path, no
  # wildcard — a frame source names exactly the player it trusts.
  @frame_origin ~r/^https:\/\/[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(:\d{1,5})?$/

  def init(opts), do: opts

  def call(conn, _opts) do
    :telemetry.span(
      [:mishka_cms, :runtime, :plugs, :security_headers],
      %{path: conn.request_path, method: conn.method},
      fn ->
        conn = PluginEvent.call("web:request:before_response", conn)
        nonce = nonce()
        :ok = CspNonce.put(nonce)

        result =
          conn
          |> assign(:csp_nonce, nonce)
          |> put_resp_header("x-frame-options", "SAMEORIGIN")
          |> put_resp_header("x-content-type-options", "nosniff")
          |> put_resp_header("x-xss-protection", "1; mode=block")
          |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
          |> put_resp_header("permissions-policy", "geolocation=(), microphone=(), camera=()")
          |> put_csp(nonce)
          |> then(&PluginEvent.call("web:response:before_security_headers", &1))

        {result, %{}}
      end
    )
  end

  @doc """
  Whether a `style` ATTRIBUTE is permitted — the one CSP question an author can walk into.

  A nonce vouches for a `<style>` ELEMENT and there is no equivalent for an attribute, so a policy
  can only permit every one or refuse every one. The page builder lets an author put `style` on
  their own content, which makes refusing them a decision about what this CMS offers rather than
  housekeeping: the attribute does not error, it is simply ignored, and the author is left looking
  at a colour that did not apply.

  So the editor reads this back and says so beside the field. One switch drives the header and the
  warning together, because a warning that can disagree with the policy is worse than none:

      config :mishka_cms, #{inspect(__MODULE__)}, inline_style: :forbid   # or :allow

  `:allow` is the default, and is what a CMS whose editor offers the attribute should keep.
  """
  @spec inline_style_allowed?() :: boolean()
  def inline_style_allowed? do
    :mishka_cms
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:inline_style, :allow)
    |> allowed?()
  end

  defp allowed?(:forbid), do: false
  defp allowed?(_allow), do: true

  @doc """
  The nonce for this request, for a template that has to mark an inline `<script>` as ours.

  Reads the assign the plug set. `nil` when the plug did not run — a template must degrade to no
  attribute rather than to the string "nil", which would match nothing and block the script.
  """
  @spec nonce(Plug.Conn.t() | map() | nil) :: String.t() | nil
  def nonce(%Plug.Conn{assigns: assigns}), do: Map.get(assigns, :csp_nonce)
  def nonce(%{} = assigns), do: Map.get(assigns, :csp_nonce)
  def nonce(_other), do: nil

  # ONE NONCE PER RESPONSE. A LiveView keeps the one its page was served with because
  # `MishkaCmsCore.Runtime.CspNonce.session/1` signs it into that page's LiveView session — so nothing
  # is written to the cookie, and no tab can be handed another tab's nonce.
  defp nonce, do: @nonce_bytes |> :crypto.strong_rand_bytes() |> Base.encode64()

  defp put_csp(conn, nonce) do
    admin? = admin?(conn)

    case mode(admin?) do
      :off ->
        conn

      :enforce ->
        put_resp_header(conn, "content-security-policy", policy(conn, admin?, nonce))

      _report_only ->
        put_resp_header(conn, "content-security-policy-report-only", policy(conn, admin?, nonce))
    end
  end

  @doc """
  Whether every entry of `origins` is an origin `security.frame_origins` may hold:
  `https://host` or `https://host:port`, lower case, nothing after it.
  """
  @spec frame_origins?(term()) :: boolean()
  def frame_origins?(origins) when is_list(origins),
    do: Enum.all?(origins, &(is_binary(&1) and Regex.match?(@frame_origin, &1)))

  def frame_origins?(_origins), do: false

  defp policy(conn, admin?, nonce),
    do: directives(admin?, nonce, captcha_sources(conn, admin?), frame_origins(conn))

  # ENFORCED WHERE IT HAS BEEN CHECKED, REPORTED WHERE IT HAS NOT — the two do not have to move
  # together, and a public page is the side facing the internet.
  #
  #     csp: :enforce                            # both
  #     csp: [public: :enforce, admin: :report_only]
  defp mode(admin?) do
    :mishka_cms
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:csp, :report_only)
    |> case do
      modes when is_list(modes) -> Keyword.get(modes, audience(admin?), :report_only)
      one -> one
    end
  end

  defp audience(true), do: :admin
  defp audience(false), do: :public

  # WHICH POLICY, BY PATH. Admin and public share the `:browser` pipeline — `SiteLookupPlug` resolves
  # a site for both — so the pipeline cannot tell them apart and the path has to.
  defp admin?(conn), do: String.starts_with?(conn.request_path, "/admin")

  defp directives(admin?, nonce, captcha, frames) do
    [
      "default-src 'self'",
      "base-uri 'self'",
      "object-src 'none'",
      # The canvas is a same-origin iframe of the editor, and the preview modal renders into an
      # `<iframe srcdoc>`; both are 'self'.
      "frame-ancestors 'self'",
      "frame-src 'self'#{sources(captcha, :frame_src)}#{sources(%{frames: frames}, :frames)}",
      "form-action 'self'",
      # A page an author built may point at any image on the web, and the media library serves
      # data: thumbnails.
      "img-src 'self' data: blob: https:",
      # AND AT ANY VIDEO, for exactly the same reason — `<video>`, `<audio>` and the `<track>` a
      # subtitle comes from are governed by `media-src`, which was never named, so they fell back to
      # `default-src 'self'` and every external one was refused:
      #
      #     Loading media from 'https://…/flower.mp4' violates the following Content Security Policy
      #     directive: "default-src 'self'". Note that 'media-src' was not explicitly set.
      #
      # An author dropping `chelekom-video` on a page and pasting a link is an ordinary gesture, and
      # `img-src` had already conceded the point for pictures. Same shape as it, deliberately:
      # `blob:` for a file being previewed before it is saved, `data:` for an inlined clip, `https:`
      # for the web. No `http:`, because a page served over https would refuse it as mixed content
      # anyway and naming it would only make the policy look more permissive than it is.
      "media-src 'self' data: blob: https:",
      "font-src 'self' data: #{@fonts_files}",
      style_src(admin?, nonce, sources(captcha, :style_src)),
      "script-src 'self' 'nonce-#{nonce}'#{dev_origins(:http)}#{sources(captcha, :script_src)}",
      # The LiveSocket connects to a relative "/live", which is same-origin — but 'self' does not
      # cover the ws:/wss: scheme in every browser, so both are named.
      "connect-src 'self' ws: wss:#{dev_origins(:all)}#{sources(captcha, :connect_src)}"
    ]
    |> Enum.join("; ")
  end

  # THE CAPTCHA'S OWN ORIGINS, WHERE IT IS ASKED AND NOWHERE ELSE — see `MishkaCmsCore.Captcha`. A
  # site's pages carry its provider's (and the master site's carry Global's too, which the masters'
  # sign-in there asks), every one of them: the policy is written before the page is known, and a
  # sign-in form can sit on any page. Read from the settings cache, no query.
  #
  # EVERY ADMIN PAGE carries every offered provider's: the settings page's test may try any of them,
  # and it is reached by live navigation from any admin page, which keeps that page's policy.
  defp captcha_sources(_conn, true), do: Captcha.csp_sources(:all)

  defp captcha_sources(%{assigns: %{current_site: %{id: site_id} = site}}, false),
    do:
      Captcha.csp_sources(if(Map.get(site, :master) == true, do: [site_id, nil], else: [site_id]))

  defp captcha_sources(_no_site, false), do: %{}

  # THE PLAYERS A SITE LETS ITS PAGES EMBED — a video, a map — from `security.frame_origins`, the
  # site's own value, else the global one. Read from the settings cache, no query. An admin page
  # carries its site's too: the editor previews that site's pages inside it.
  defp frame_origins(%{assigns: %{current_site: %{id: site_id}}}),
    do: Settings.get("security.frame_origins", [], site_id)

  defp frame_origins(_no_site), do: Settings.get("security.frame_origins", [])

  defp sources(captcha, directive) do
    case Map.get(captcha, directive, []) do
      [] -> ""
      origins -> " " <> Enum.join(origins, " ")
    end
  end

  # ELEMENTS ARE STRICT, ATTRIBUTES ARE NOT, AND THE SPLIT IS THE WHOLE POINT.
  #
  # `'unsafe-inline'` in a plain `style-src` permits both at once — every injected `<style>` on the
  # page, bought to allow one `style="color:red"`. `style-src-elem` and `style-src-attr` separate
  # them, so the dangerous half can be closed while the harmless half stays open:
  #
  #   * `-elem`: our own stylesheets, plus a nonce. The page builder's in-browser Tailwind delivers
  #     its output through a `<style>` element and offers no nonce option, so the layout stamps one
  #     on for it — see the shim above `tailwind-browser.js` in `root.html.heex`.
  #   * `-attr`: `'unsafe-inline'`, and NOT because this app's own templates need it — they carry no
  #     `style` attribute at all any more. It is open because the page builder lets an AUTHOR put one
  #     on their own content, and `contain/2` renders kit components this repo does not own. No nonce
  #     can help there; CSP has no mechanism for an attribute, so the choice is all or none.
  #     `inline_style_allowed?/0` is that choice, and the editor reads it back to warn beside the
  #     field rather than let an author's colour vanish in silence.
  #
  # The half that matters is already shut. An injected `<style>` can carry SELECTORS —
  # `input[value^="a"] { background: url(evil/a) }` reads a token a character at a time — while an
  # attribute has none and can only restyle the element it sits on.
  #
  # `style-src` stays as the fallback for browsers that do not implement the split — Safari, at the
  # time of writing — where it is the permissive value or nothing.
  defp style_src(admin?, nonce, captcha) do
    fonts = if admin?, do: "", else: " #{@fonts_css}"
    dev = dev_origins(:http)
    attr = attr_sources()

    "style-src 'self' #{attr}#{fonts}#{dev}#{captcha}; " <>
      "style-src-elem 'self' 'nonce-#{nonce}'#{fonts}#{dev}#{captcha}; " <>
      "style-src-attr #{attr}"
  end

  defp attr_sources do
    case inline_style_allowed?() do
      true -> "'unsafe-inline'"
      false -> "'none'"
    end
  end

  # A DEV TOOL SERVING ITS CLIENT FROM ITS OWN PORT has to be named here or every page load reports a
  # violation and buries the real ones. Nothing does today — `live_debugger`, which served both a
  # script and a stylesheet from port 4007, has been removed — so this is configured empty and the
  # development policy is the production policy. The mechanism stays because the next such tool
  # should be let in deliberately, one origin at a time, rather than by widening the policy.
  #
  # A CLIENT IS NOT ONLY SCRIPT, which is why the style directives are covered too: allowing only
  # the script left `live_debugger`'s floating button rendering as an unstyled column of stacked
  # words on every page, the canvas iframe included. It looked like a bug in the tool and was a hole
  # in this policy.
  #
  # Split by scheme: a `ws://` origin in `script-src` is meaningless — nothing is ever fetched as a
  # script over a websocket — and a policy carrying values that cannot apply is a policy nobody
  # trusts enough to tighten.
  defp dev_origins(which) do
    :mishka_cms
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:dev_origins, [])
    |> Enum.filter(&keep?(which, &1))
    |> case do
      [] -> ""
      origins -> " " <> Enum.join(origins, " ")
    end
  end

  defp keep?(:all, _origin), do: true
  defp keep?(:http, origin), do: String.starts_with?(origin, "http")
end
