# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.HelpersTest do
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Helpers
  alias MishkaCmsCore.TestEndpoint
  alias MishkaCmsCore.TestRouter

  describe "url/2" do
    test "a conn answers the endpoint's address followed by the path under the conn's prefix" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Map.put(:script_name, ["cms"])
        |> Plug.Conn.put_private(:phoenix_endpoint, TestEndpoint)
        |> Plug.Conn.put_private(:phoenix_router, TestRouter)

      assert Helpers.path(conn, "/admin") == "/cms/admin"
      assert Helpers.url(conn, "/admin") == TestEndpoint.url() <> "/cms/admin"
    end

    test "a socket answers the endpoint's address followed by the endpoint's path" do
      socket = %Phoenix.LiveView.Socket{endpoint: TestEndpoint, router: TestRouter}

      assert Helpers.url(socket, "/posts/1") ==
               TestEndpoint.url() <> TestEndpoint.path("/posts/1")
    end
  end

  describe "host_version/0" do
    # THE APPLICATION THE CMS IS CONFIGURED TO RUN IN, so the host's own version and not this
    # library's, wherever that is: in this suite the host is the library itself.
    test "is the version of the configured host application" do
      host_app = Application.fetch_env!(:mishka_cms_core, :host_app)

      assert Helpers.host_version() == to_string(Application.spec(host_app, :vsn))
      assert Helpers.host_version() =~ ~r/\A\d+\.\d+\.\d+/
    end
  end

  describe "address_path/1" do
    test "drops the slash at the end, and the repeated ones" do
      assert Helpers.address_path("/blog") == "/blog"
      assert Helpers.address_path("/blog/") == "/blog"
      assert Helpers.address_path("//blog//post/") == "/blog/post"
    end

    test "writes the home page as nothing, so the site's address stands alone" do
      assert Helpers.address_path("/") == ""
      assert Helpers.address_path("//") == ""
      assert Helpers.address_path("") == ""
    end

    test "keeps the query and the fragment as they are" do
      assert Helpers.address_path("/blog/?page=2") == "/blog?page=2"
      assert Helpers.address_path("/?page=2") == "?page=2"
      assert Helpers.address_path("/search/?q=a/b/&x=//") == "/search?q=a/b/&x=//"
      assert Helpers.address_path("/docs/#install/") == "/docs#install/"
    end

    test "leaves each segment as it is given" do
      assert Helpers.address_path("/fa/داستان/") == "/fa/داستان"
      assert Helpers.address_path("/a%2Fb") == "/a%2Fb"
    end
  end

  describe "url_path/1" do
    test "writes a raw and an encoded segment as one URL, never encoding an escape twice" do
      raw = Helpers.url_path("/fa/داستان-ما/")

      assert raw == "/fa/" <> URI.encode("داستان-ما", &URI.char_unreserved?/1)
      assert Helpers.url_path(raw) == raw
      assert Helpers.url_path(String.downcase(raw)) == raw
      assert raw |> URI.decode() == "/fa/داستان-ما"
    end

    test "keeps what a segment may hold as it is, and an escape of it as the character" do
      assert Helpers.url_path("/a:b@c/(x)!") == "/a:b@c/(x)!"
      assert Helpers.url_path("/a%3Ab") == "/a:b"
      assert Helpers.url_path("/a b") == "/a%20b"
    end

    test "keeps an escaped slash, question mark or percent inside its segment" do
      assert Helpers.url_path("/a%2Fb/c%3Fd/e%25f") == "/a%2Fb/c%3Fd/e%25f"
      assert Helpers.url_path("/50%/%zz") == "/50%25/%25zz"
    end

    test "keeps the slash rule, the query and the fragment of address_path/1" do
      assert Helpers.url_path("//blog//ما/?q=ما#x") == "/blog/%D9%85%D8%A7?q=ما#x"
      assert Helpers.url_path("/") == ""
    end
  end

  describe "site_url/2" do
    test "is the site's host on the endpoint's scheme and port, and the path" do
      uri = TestEndpoint.struct_url()
      origin = "#{uri.scheme}://blog.test:#{uri.port}"

      assert Helpers.site_url("blog.test", "/sitemap.xml") == origin <> "/sitemap.xml"
      assert Helpers.site_url("blog.test", "/fa/blog") == origin <> "/fa/blog"
    end

    test "ends no address in a slash, the home page being the origin alone" do
      origin = Helpers.site_url("blog.test", "")

      assert Helpers.site_url("blog.test", "/") == origin
      assert Helpers.site_url("blog.test", "/blog/") == origin <> "/blog"
      assert Helpers.site_url("blog.test", "/blog/?page=2") == origin <> "/blog?page=2"
      refute String.ends_with?(origin, "/")
    end
  end
end
