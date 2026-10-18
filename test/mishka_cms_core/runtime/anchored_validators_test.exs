# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.AnchoredValidatorsTest do
  @moduledoc """
  A name, a path, a package or an origin that ends in a line break is not one.

  In an Elixir regular expression `$` also matches before a final `"\\n"`, so `~r/^[a-z_]+$/` takes
  `"count\\n"`. The checks that guard an identifier written into code, a path a page is served at, a
  package fetched into `node_modules` and an origin a response is sent to are written `\\A…\\z`,
  which matches the whole string and nothing else. Each one is asked here, with its clean spelling
  beside it so that a check which now refuses everything does not pass.
  """
  use MishkaCmsCore.DataCase, async: true

  alias MishkaCmsCore.Runtime.Compilers.NpmPackages
  alias MishkaCmsCore.Runtime.PageState
  alias MishkaCmsWeb.Runtime.Plugs.SecurityHeaders
  alias MishkaCmsCore.Runtime.Resources.Validations.{DomainValidator, HookPackages, PathFormat}
  alias MishkaCmsCore.Runtime.{Page, Site}

  @moduletag :unit

  @newlines ["\n", "\r\n", "\n\n"]

  # The values as they are, where a changeset built by an action has already trimmed them: the
  # check is what is asked, not the attribute's constraints in front of it.
  defp raw_changeset(resource, attributes),
    do: %Ash.Changeset{resource: resource, data: struct(resource), attributes: attributes}

  describe "a page's state name" do
    test "ends in a line break and is refused" do
      assert PageState.valid_name?("count")

      for newline <- @newlines, do: refute(PageState.valid_name?("count" <> newline))
    end
  end

  describe "an npm package" do
    @integrity "sha512-" <> String.duplicate("A", 86) <> "=="

    defp package(overrides) do
      Map.merge(
        %{
          "name" => "left-pad",
          "version" => "1.3.0",
          "path" => "node_modules/left-pad",
          "integrity" => @integrity
        },
        overrides
      )
    end

    test "is taken with a clean name, version and hash" do
      assert NpmPackages.valid_entry?(package(%{}))
    end

    test "ends in a line break in its name, version or hash and is refused" do
      for newline <- @newlines do
        refute NpmPackages.valid_entry?(
                 package(%{"name" => "left-pad" <> newline, "path" => "node_modules/left-pad"})
               )

        refute NpmPackages.valid_entry?(package(%{"version" => "1.3.0" <> newline}))
        refute NpmPackages.valid_entry?(package(%{"integrity" => @integrity <> newline}))
      end
    end
  end

  describe "a frame origin" do
    test "is https, a host of at least two labels, an optional port, and nothing after it" do
      assert SecurityHeaders.frame_origins?(["https://player.example.com:8443"])

      for bad <- [
            "http://player.example.com",
            "https://player",
            "https://player.example.com/",
            "https://player.example.com/x",
            "https://player.example.com?x=1",
            "https://user@player.example.com",
            "https://player.example.com:",
            "https://player.example.com:port",
            "https://Player.example.com",
            "https://*.example.com"
          ] do
        refute SecurityHeaders.frame_origins?([bad]), bad
      end
    end

    test "ends in a line break and is refused" do
      assert SecurityHeaders.frame_origins?(["https://player.example.com"])

      for newline <- @newlines do
        refute SecurityHeaders.frame_origins?(["https://player.example.com" <> newline])
      end
    end
  end

  describe "a hook's module file" do
    test "ends in a line break and is refused" do
      assert HookPackages.module?(%{"file" => "util.js", "content" => "export {}"})

      for newline <- @newlines do
        refute HookPackages.module?(%{"file" => "util.js" <> newline, "content" => "export {}"})
      end
    end
  end

  describe "a site's addresses" do
    defp refused(attributes) do
      Site |> raw_changeset(attributes) |> DomainValidator.validate([], %{})
    end

    test "are taken clean" do
      assert refused(%{
               host: "example.com",
               frontend_domain: "app.example.com",
               allowed_origins: ["https://partner.example.com", "http://localhost:3000/"]
             }) == :ok
    end

    test "an allowed origin is an http(s) scheme, a host of labels and an optional port and path" do
      for good <- [
            "https://a.example.com",
            "http://localhost:3000",
            "https://a.example.com/x?y=1"
          ] do
        assert refused(%{allowed_origins: [good]}) == :ok, good
      end

      for bad <- [
            "HTTPS://a.example.com",
            "ftp://a.example.com",
            "//a.example.com",
            "a.example.com",
            "https://",
            "https://user@a.example.com",
            "https://a.example.com:port",
            "https://a b.example.com",
            "https://-bad.example.com"
          ] do
        assert {:error, field: :allowed_origins, message: _} = refused(%{allowed_origins: [bad]}),
               bad
      end
    end

    test "end in a line break and are refused" do
      for newline <- @newlines do
        assert {:error, field: :host, message: _} = refused(%{host: "example.com" <> newline})

        assert {:error, field: :frontend_domain, message: _} =
                 refused(%{frontend_domain: "app.example.com" <> newline})

        assert {:error, field: :allowed_origins, message: _} =
                 refused(%{allowed_origins: ["https://partner.example.com" <> newline]})
      end
    end
  end

  # `Page.path` is trimmed before it is validated, so the check is asked of the value as it is.
  describe "a page's path" do
    defp path_problem(path) do
      Page |> raw_changeset(%{path: path}) |> PathFormat.validate([], %{})
    end

    test "is taken clean, and refused when it ends in a line break" do
      assert path_problem("/about") == :ok
      assert path_problem("/blog/*") == :ok

      for newline <- @newlines do
        assert {:error, field: :path, message: _} = path_problem("/about" <> newline)
      end
    end
  end
end
