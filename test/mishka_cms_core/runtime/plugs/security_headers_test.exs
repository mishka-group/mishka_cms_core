defmodule MishkaCmsWeb.Runtime.Plugs.SecurityHeadersTest do
  @moduledoc """
  The policy is only worth having if it says what it is meant to say, and a header nobody looks at
  drifts. These pin the two decisions that took evidence to make.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias MishkaCmsWeb.Runtime.Plugs.SecurityHeaders

  setup do
    previous = Application.get_env(:mishka_cms, SecurityHeaders)
    on_exit(fn -> Application.put_env(:mishka_cms, SecurityHeaders, previous || []) end)
    :ok
  end

  defp run(path, opts \\ []) do
    Application.put_env(:mishka_cms, SecurityHeaders, opts)
    :get |> conn(path) |> SecurityHeaders.call([])
  end

  defp csp(conn) do
    case get_resp_header(conn, "content-security-policy") ++
           get_resp_header(conn, "content-security-policy-report-only") do
      [value | _rest] -> value
      [] -> nil
    end
  end

  describe "the mode decides which header carries the policy" do
    # A policy is a guess until a browser has checked it against real pages, so nothing is enforced
    # until somebody says so.
    test "report-only by default" do
      conn = run("/about")

      assert [_policy] = get_resp_header(conn, "content-security-policy-report-only")
      assert get_resp_header(conn, "content-security-policy") == []
    end

    test "enforcing when asked" do
      conn = run("/about", csp: :enforce)

      assert [_policy] = get_resp_header(conn, "content-security-policy")
      assert get_resp_header(conn, "content-security-policy-report-only") == []
    end

    test "off means neither" do
      conn = run("/about", csp: :off)

      assert get_resp_header(conn, "content-security-policy") == []
      assert get_resp_header(conn, "content-security-policy-report-only") == []
    end
  end

  describe "the mode can differ by audience" do
    # Enforced where it has been checked, reported where it has not. A public page is the side
    # facing the internet and was verified in a browser; the editor was not.
    test "public enforces while admin reports" do
      opts = [csp: [public: :enforce, admin: :report_only]]

      assert [_policy] = run("/about", opts) |> get_resp_header("content-security-policy")
      assert run("/about", opts) |> get_resp_header("content-security-policy-report-only") == []

      assert [_policy] =
               run("/admin/dashboard", opts)
               |> get_resp_header("content-security-policy-report-only")

      assert run("/admin/dashboard", opts) |> get_resp_header("content-security-policy") == []
    end

    test "a bare atom still means both" do
      assert [_policy] =
               run("/about", csp: :enforce) |> get_resp_header("content-security-policy")

      assert [_policy] =
               run("/admin/dashboard", csp: :enforce)
               |> get_resp_header("content-security-policy")
    end

    test "an audience with no entry reports rather than enforcing" do
      conn = run("/admin/dashboard", csp: [public: :enforce])

      assert [_policy] = get_resp_header(conn, "content-security-policy-report-only")
    end
  end

  describe "styles: elements are strict, attributes are not" do
    # `'unsafe-inline'` in a plain `style-src` permits both at once. The split closes the dangerous
    # half — an injected `<style>` can carry selectors and read a token a character at a time — while
    # leaving open the half an author's own `style` attribute needs, which carries none.
    test "a <style> element needs the nonce; an attribute does not" do
      policy = csp(run("/about"))

      assert policy =~ "style-src-elem 'self' 'nonce-"
      assert policy =~ "style-src-attr 'unsafe-inline'"
      refute policy =~ "style-src-elem 'self' 'unsafe-inline'"
    end

    # Safari does not implement the split, and there it is the permissive value or no styling at all.
    test "the un-split directive stays as the fallback for browsers without -elem/-attr" do
      assert csp(run("/about")) =~ "style-src 'self' 'unsafe-inline'"
    end
  end

  describe "an author's own inline style" do
    # The page builder lets an author put `style` on their own content, so this directive is a
    # decision about what the CMS offers rather than housekeeping. One switch drives the header and
    # the warning the inspector shows beside the field — a warning that can disagree with the policy
    # is worse than none.
    test "permitted by default, because the editor offers the attribute" do
      assert SecurityHeaders.inline_style_allowed?()
      assert csp(run("/about")) =~ "style-src-attr 'unsafe-inline'"
    end

    test "refused when a deployment says so" do
      policy = csp(run("/about", inline_style: :forbid))

      refute SecurityHeaders.inline_style_allowed?()
      assert policy =~ "style-src-attr 'none'"
      refute policy =~ "'unsafe-inline'"
    end

    # Safari reads the un-split directive, so a deployment that closed attributes must not find them
    # open again there.
    test "the fallback directive closes with it" do
      [fallback] = Regex.run(~r/style-src '[^;]+/, csp(run("/about", inline_style: :forbid)))

      assert fallback =~ "'none'"
      refute fallback =~ "'unsafe-inline'"
    end
  end

  describe "the nonce" do
    # The layout marks its own inline scripts with this. A nonce that did not reach the template, or
    # one reused between requests, is the same as having none.
    test "is assigned for the template to read" do
      conn = run("/about")

      assert is_binary(conn.assigns.csp_nonce)
      assert SecurityHeaders.nonce(conn) == conn.assigns.csp_nonce
      assert csp(conn) =~ "'nonce-#{conn.assigns.csp_nonce}'"
    end

    test "is different every request" do
      refute run("/about").assigns.csp_nonce == run("/about").assigns.csp_nonce
    end

    # One nonce per RESPONSE. It used to live in the session cookie for the whole visit; a page now
    # carries its own into its LiveView through `CspNonce.session/1`, so nothing is stored here.
    test "is not kept in the session, so one visit's responses never share it" do
      first = :get |> conn("/about") |> init_test_session(%{}) |> SecurityHeaders.call([])
      second = :get |> conn("/about") |> init_test_session(%{}) |> SecurityHeaders.call([])

      assert get_session(first, "csp_nonce") == nil
      refute first.assigns.csp_nonce == second.assigns.csp_nonce
    end

    test "is what `csp_nonce/0` answers while the response renders" do
      conn = run("/about")

      assert MishkaCmsCore.Runtime.CspNonce.current() == conn.assigns.csp_nonce
      assert MishkaCmsCore.Runtime.LiveViewHelpers.csp_nonce() == conn.assigns.csp_nonce
    end

    test "reads nil rather than raising where the plug never ran" do
      assert SecurityHeaders.nonce(%{}) == nil
      assert SecurityHeaders.nonce(nil) == nil
    end
  end

  describe "two audiences" do
    # The admin's `style-src` has to admit 'unsafe-inline' because the page builder's in-browser
    # Tailwind writes a <style> element on every keystroke, and it offers no nonce.
    test "the admin allows Google Fonts nowhere and inline styles everywhere" do
      policy = csp(run("/admin/dashboard"))

      assert policy =~ "style-src 'self' 'unsafe-inline'"
      refute policy =~ "fonts.googleapis.com"
    end

    test "a public page allows the font stylesheet it actually loads" do
      policy = csp(run("/about"))

      assert policy =~ "https://fonts.googleapis.com"
      assert policy =~ "font-src 'self' data: https://fonts.gstatic.com"
    end
  end

  describe "framing" do
    # DENY forbids framing by ANY page, same-origin included — and the editor's canvas is a
    # same-origin iframe. It only ever worked because a dev-only dependency deleted the header.
    test "same-origin framing is allowed, because the canvas is an iframe" do
      conn = run("/admin/dashboard")

      assert get_resp_header(conn, "x-frame-options") == ["SAMEORIGIN"]
      assert csp(conn) =~ "frame-ancestors 'self'"
    end
  end

  # WHAT AN AUTHOR'S OWN PAGE IS ALLOWED TO POINT AT. `img-src` conceded this for pictures long ago;
  # `media-src` was never named, so `<video>` and `<audio>` fell back to `default-src 'self'` and any
  # external clip was refused outright — "Loading media from 'https://…/flower.mp4' violates the
  # following Content Security Policy directive: default-src 'self'".
  describe "an author's own media" do
    test "a video from the web is allowed, the same way a picture is" do
      policy = csp(run("/about"))

      [media] = Regex.run(~r/media-src [^;]+/, policy)

      assert media =~ "https:"
      assert media =~ "blob:", "a file being previewed before it is saved"
      assert media =~ "data:"
      assert media =~ "'self'"
    end

    test "and in the editor too, which is where the page is built" do
      [media] = Regex.run(~r/media-src [^;]+/, csp(run("/admin/dashboard")))
      assert media =~ "https:"
    end

    # Naming it would make the policy look more permissive than it is: a page served over https
    # refuses plain http media as mixed content whatever the CSP says.
    test "but not over plain http" do
      [media] = Regex.run(~r/media-src [^;]+/, csp(run("/about")))
      refute media =~ " http:"
    end
  end

  describe "dev-only origins" do
    test "a websocket origin never reaches script-src" do
      policy = csp(run("/about", dev_origins: ["http://localhost:4007", "ws://localhost:4007"]))

      [script] = Regex.run(~r/script-src [^;]+/, policy)
      [connect] = Regex.run(~r/connect-src [^;]+/, policy)

      assert script =~ "http://localhost:4007"
      refute script =~ "ws://localhost:4007"
      assert connect =~ "ws://localhost:4007"
    end

    # A dev tool serves a stylesheet as well as a script — `live_debugger`, which this was written
    # for, served both from port 4007. Omitting them from `style-src-elem` blocked the stylesheet and
    # its floating button rendered as a column of stacked words on every page. The dependency is gone
    # and nothing configures `dev_origins` now, so these two pass an origin in explicitly: the
    # mechanism has to keep working for whatever tool needs it next.
    test "a dev origin reaches the style directives too" do
      policy = csp(run("/about", dev_origins: ["http://localhost:4007", "ws://localhost:4007"]))

      [elem] = Regex.run(~r/style-src-elem [^;]+/, policy)
      [fallback] = Regex.run(~r/style-src '[^;]+/, policy)

      assert elem =~ "http://localhost:4007"
      refute elem =~ "ws://localhost:4007"
      assert fallback =~ "http://localhost:4007"
    end

    test "nothing is added when none are configured" do
      policy = csp(run("/about", []))

      refute policy =~ "localhost:4007"
    end
  end
end
