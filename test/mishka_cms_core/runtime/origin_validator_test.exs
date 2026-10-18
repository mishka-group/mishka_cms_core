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
