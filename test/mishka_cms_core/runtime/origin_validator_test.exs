# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.OriginValidatorTest do
  @moduledoc """
  Reading a host or an address out of what a request or a setting carries.

  Cutting a header at the first colon turned `[::1]:4000` into `[`, and `String.starts_with?(value,
  "http")` took a domain such as `httpbin.example.com` for an address; `URI.parse/1` answers both.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.OriginValidator

  @moduletag :unit

  describe "host_name/1" do
    test "is the host without its port" do
      assert OriginValidator.host_name("example.com") == "example.com"
      assert OriginValidator.host_name("example.com:4000") == "example.com"
      assert OriginValidator.host_name("localhost:4000") == "localhost"
    end

    test "reads an IPv6 host whole" do
      assert OriginValidator.host_name("[::1]:4000") == "::1"
      assert OriginValidator.host_name("[2001:db8::1]") == "2001:db8::1"
    end

    test "is nil for a header that names no host" do
      assert OriginValidator.host_name("") == nil
      assert OriginValidator.host_name(":4000") == nil
      assert OriginValidator.host_name(nil) == nil
    end
  end

  describe "web_url?/1" do
    test "accepts an http or https address with a host" do
      assert OriginValidator.web_url?("https://example.com")
      assert OriginValidator.web_url?("http://example.com:8080/a?b=c")
    end

    test "refuses a domain that only starts with http, and anything that is not a web address" do
      for value <- [
            "httpbin.example.com",
            "http",
            "https://",
            "ftp://example.com",
            "javascript:alert(1)",
            "//example.com",
            "/path",
            "https://example.com\n",
            " https://example.com",
            "",
            nil
          ] do
        refute OriginValidator.web_url?(value), inspect(value)
      end
    end
  end

  describe "is_loopback_host/1" do
    require OriginValidator

    test "is localhost, a name under .localhost, 127.0.0.1 and ::1" do
      for host <- ["localhost", "site-a.localhost", "a.b.localhost", "127.0.0.1", "::1"] do
        assert OriginValidator.is_loopback_host(host), host
      end
    end

    test "is no other host, however close its name" do
      for host <- [
            "evil-localhost.com",
            "localhost.evil.com",
            "evillocalhost",
            "notlocalhost",
            ".localhost",
            "localhost.",
            "127.0.0.2",
            "::2",
            "site.com",
            "",
            nil,
            :localhost
          ] do
        refute OriginValidator.is_loopback_host(host), inspect(host)
      end
    end

    test "works in a guard" do
      loopback? = fn
        host when OriginValidator.is_loopback_host(host) -> true
        _host -> false
      end

      assert loopback?.("site-b.localhost")
      refute loopback?.("localhost.evil.com")
    end
  end

  describe "request_origin/1" do
    test "reads a bare origin as scheme, host and port" do
      assert OriginValidator.request_origin("https://site.com") ==
               {:ok, {"https", "site.com", 443}}

      assert OriginValidator.request_origin("https://site.com:443") ==
               {:ok, {"https", "site.com", 443}}

      assert OriginValidator.request_origin("http://site.com") == {:ok, {"http", "site.com", 80}}

      assert OriginValidator.request_origin("http://localhost:3000") ==
               {:ok, {"http", "localhost", 3000}}

      assert OriginValidator.request_origin("http://[::1]:3000") == {:ok, {"http", "::1", 3000}}

      assert OriginValidator.request_origin("HTTPS://SITE.COM") ==
               {:ok, {"https", "site.com", 443}}
    end

    test "is :error for anything but a bare origin" do
      for value <- [
            "null",
            "",
            "   ",
            "https://site.com/",
            "https://site.com/path",
            "https://site.com?x=1",
            "https://site.com#x",
            "https://user@site.com",
            "https://user:pw@site.com",
            "https://site.com:abc",
            "https://site.com:",
            "https://site.com:0",
            "https://site.com:65536",
            "https://site.com:-1",
            "https://site.com:+443",
            "https://site.com\n",
            "https://site.com\r\nx-injected: 1",
            "https://si te.com",
            "https://%73ite.com",
            "https://site.com, https://other.com",
            "site.com",
            "//site.com",
            "ftp://site.com",
            "javascript://site.com",
            "https://",
            nil,
            42
          ] do
        assert OriginValidator.request_origin(value) == :error, inspect(value)
      end
    end
  end

  describe "serialize/1" do
    test "writes an origin the way a browser does" do
      assert OriginValidator.serialize({"https", "site.com", 443}) == "https://site.com"
      assert OriginValidator.serialize({"http", "site.com", 80}) == "http://site.com"
      assert OriginValidator.serialize({"https", "site.com", 8443}) == "https://site.com:8443"
      assert OriginValidator.serialize({"http", "site.com", 443}) == "http://site.com:443"
      assert OriginValidator.serialize({"http", "::1", 3000}) == "http://[::1]:3000"
    end

    test "is what request_origin/1 reads back" do
      for value <- ["https://site.com", "http://localhost:5173", "http://[::1]:3000"] do
        assert {:ok, origin} = OriginValidator.request_origin(value)
        assert OriginValidator.serialize(origin) == value
      end
    end
  end

  # Every row of the table in `MishkaCmsCore.Runtime.Plugs.ApiCorsPlug`'s moduledoc.
  describe "site_origins/1" do
    defp allows?(site, value) do
      {:ok, origin} = OriginValidator.request_origin(value)
      origin in OriginValidator.site_origins(site)
    end

    @table [
      {%{host: "site.com"}, ["https://site.com"],
       ["http://site.com", "https://site.com:8443", "https://sub.site.com"]},
      {%{host: "site-a.localhost"}, ["https://site-a.localhost", "http://site-a.localhost"],
       ["http://site-a.localhost:3000"]},
      {%{host: "api.com", frontend_domain: "app.example.com"}, ["https://app.example.com"],
       ["http://app.example.com", "https://app.example.com:3000"]},
      {%{host: "api.com", frontend_domain: "app.example.com:3000"},
       ["https://app.example.com:3000"],
       ["http://app.example.com:3000", "https://app.example.com"]},
      {%{host: "api.com", frontend_domain: "localhost:5173"},
       ["https://localhost:5173", "http://localhost:5173"], ["http://localhost:5174"]},
      {%{host: "api.com", frontend_domain: "https://app.example.com:8443"},
       ["https://app.example.com:8443"],
       ["http://app.example.com:8443", "https://app.example.com"]},
      {%{host: "api.com", allowed_origins: ["https://partner.com"]},
       ["https://partner.com", "https://partner.com:443"],
       ["http://partner.com", "https://partner.com:8443"]},
      {%{host: "api.com", allowed_origins: ["http://other.com:8080/"]}, ["http://other.com:8080"],
       ["https://other.com:8080", "http://other.com"]}
    ]

    test "allows what the moduledoc table says, and not what it says it does not" do
      for {site, allowed, denied} <- @table do
        for value <- allowed, do: assert(allows?(site, value), "#{value} for #{inspect(site)}")
        for value <- denied, do: refute(allows?(site, value), "#{value} for #{inspect(site)}")
      end
    end

    test "a loopback host also allows http, on the scheme's own port" do
      for host <- ["localhost", "site-a.localhost", "site-b.localhost", "127.0.0.1"] do
        assert allows?(%{host: host}, "http://#{host}"), host
        assert allows?(%{host: host}, "https://#{host}"), host
        refute allows?(%{host: host}, "http://#{host}:3000"), host
      end
    end

    test "a host that only looks like localhost does not allow http" do
      for host <- ["evil-localhost.com", "localhost.evil.com"] do
        refute allows?(%{host: host}, "http://#{host}"), host
        assert allows?(%{host: host}, "https://#{host}"), host
        refute allows?(%{host: "site.com", frontend_domain: host}, "http://#{host}"), host
      end
    end

    test "is the same origins whatever the case or spaces they were written with" do
      site = %{
        host: " Site.COM ",
        frontend_domain: "App.Example.com",
        allowed_origins: [" HTTPS://Partner.com "]
      }

      assert Enum.sort(OriginValidator.site_origins(site)) == [
               {"https", "app.example.com", 443},
               {"https", "partner.com", 443},
               {"https", "site.com", 443}
             ]
    end

    test "a value that is not a domain or an origin allows nothing" do
      for value <- [
            "https://partner.com:abc",
            "https://user@partner.com",
            "https://part ner.com",
            "ftp://partner.com",
            "partner.com",
            "",
            nil
          ] do
        assert OriginValidator.site_origins(%{allowed_origins: [value]}) == [], inspect(value)
      end

      for value <- ["app.example.com:abc", "http:foo", "user@app.example.com", "", nil] do
        assert OriginValidator.site_origins(%{frontend_domain: value}) == [], inspect(value)
      end
    end

    test "a site with nothing written allows nothing" do
      assert OriginValidator.site_origins(%{}) == []
      assert OriginValidator.site_origins(%{host: nil, allowed_origins: nil}) == []
    end
  end

  describe "site_path?/1" do
    test "accepts a path on the site" do
      assert OriginValidator.site_path?("/uploads/a.png")
      assert OriginValidator.site_path?("/")
    end

    test "refuses the forms a browser reads as another site's address" do
      for value <- [
            "//evil.example/a.png",
            "/\\evil.example/a.png",
            "/a\nb",
            "uploads/a.png",
            "",
            nil
          ] do
        refute OriginValidator.site_path?(value), inspect(value)
      end
    end
  end
end
