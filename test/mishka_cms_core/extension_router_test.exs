# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.ExtensionRouterTest.Alpha.Routes do
  @moduledoc "A stand-in extension whose routes are the ones the calling test process put."
  @behaviour MishkaCmsCore.ExtensionRouter

  @impl true
  def routes(type), do: Process.get({__MODULE__, type}, [])
end

defmodule MishkaCmsCore.ExtensionRouterTest.Beta.Routes do
  @moduledoc "A second stand-in extension, to claim what the first already claimed."
  @behaviour MishkaCmsCore.ExtensionRouter

  @impl true
  def routes(type), do: Process.get({__MODULE__, type}, [])
end

defmodule MishkaCmsCore.ExtensionRouterTest do
  @moduledoc """
  What an extension's `:api` and `:public` routes may claim: a router listing one that would take
  the host's addresses, every address, or another extension's route does not compile, and says which
  extension and route it refused.

  `async: false`: the last test compiles a router against a changed `:extensions` setting.
  """
  use ExUnit.Case, async: false

  alias MishkaCmsCore.ExtensionRouter
  alias MishkaCmsCore.ExtensionRouterTest.{Alpha, Beta}

  defp listed(ext, type, routes), do: Process.put({Module.concat(ext, Routes), type}, routes)

  defp route(path, verb \\ :get), do: {verb, path, __MODULE__, :show}

  defp refusal(type, ext \\ Alpha) do
    error = assert_raise CompileError, fn -> ExtensionRouter.__routes__([Alpha, Beta], type) end
    assert error.description =~ inspect(ext)
    error.description
  end

  defp mounts(type), do: ExtensionRouter.__routes__([Alpha, Beta], type)

  describe "routes(:api)" do
    test "refuses every path that starts with a segment the host answers" do
      for prefix <- ExtensionRouter.host_prefixes() do
        listed(Alpha, :api, [route("/#{prefix}/feed")])
        assert refusal(:api) =~ "GET /#{prefix}/feed"
      end
    end

    test "takes a path whose first segment only begins like a host segment" do
      listed(Alpha, :api, [route("/admins/feed"), route("/api-feed"), route("/authors.json")])
      assert [{Alpha, [_, _, _]}, {Beta, []}] = mounts(:api)
    end

    test "refuses `/` and a path that starts with a capture" do
      for path <- ["/", "/:slug", "/:slug/feed", "/*rest", "/:other/feed"] do
        listed(Alpha, :api, [route(path)])
        assert refusal(:api) =~ path
      end
    end

    test "takes the language capture followed by a fixed segment" do
      listed(Alpha, :api, [route("/:lang/feed"), route("/:lang/feed/:kind/*chain")])
      assert [{Alpha, [_, _]}, {Beta, []}] = mounts(:api)
    end

    test "refuses the language capture alone, before a capture, or before a host segment" do
      for path <- ["/:lang", "/:lang/:slug", "/:lang/*rest", "/:lang/auth/sign-in", "/*lang/feed"] do
        listed(Alpha, :api, [route(path)])
        assert refusal(:api) =~ path
      end
    end

    test "refuses the verb and path another extension already lists, whatever its captures are named" do
      listed(Alpha, :api, [route("/feed/:a")])
      listed(Beta, :api, [route("/feed/:b")])

      description = refusal(:api, Beta)
      assert description =~ "GET /feed/:a"
      assert description =~ "GET /feed/:b"
    end

    test "refuses a duplicate inside one extension, and a capture prefix named differently" do
      listed(Alpha, :api, [route("/sitemap-:a.xml"), route("/sitemap-:b.xml")])
      assert refusal(:api) =~ "/sitemap-:b.xml"
    end

    test "takes one path under two verbs, and a capture beside a rest capture" do
      listed(Alpha, :api, [route("/hook", :post), route("/hook"), route("/feed/:kind/:key")])
      listed(Beta, :api, [route("/feed/:kind/*chain")])
      assert [{Alpha, [_, _, _]}, {Beta, [_]}] = mounts(:api)
    end

    test "refuses a `:live` route" do
      listed(Alpha, :api, [{:live, "/feed", __MODULE__, :index}])
      assert refusal(:api) =~ "routes(:public)"

      listed(Alpha, :api, [{:live, "/feed", __MODULE__, :index, as: :feed}])
      assert refusal(:api) =~ "LIVE /feed"
    end
  end

  describe "routes(:public)" do
    test "takes a host segment and a `:live` route" do
      listed(Alpha, :public, [
        route("/admin/language", :put),
        route("/_preview/doc-example/:kind/:id/:index"),
        {:live, "/gallery", __MODULE__, :index}
      ])

      assert [{Alpha, [_, _, _]}, {Beta, []}] = mounts(:public)
    end

    test "refuses `/`, a leading capture and a duplicate" do
      for path <- ["/", "/:slug", "/:lang/:slug"] do
        listed(Alpha, :public, [route(path)])
        assert refusal(:public) =~ path
      end

      listed(Alpha, :public, [route("/robots.txt")])
      listed(Beta, :public, [route("/robots.txt")])
      assert refusal(:public, Beta) =~ "GET /robots.txt"
    end
  end

  test "leaves the admin lists alone" do
    listed(Alpha, :admin, [{:live, "/", __MODULE__, :index}])
    listed(Beta, :admin, [{:live, "/", __MODULE__, :index}])
    assert [{Alpha, [_]}, {Beta, [_]}] = mounts(:admin)
  end

  test "a router mounting a refused route does not compile" do
    extensions = Application.get_env(:mishka_cms_core, :extensions)
    on_exit(fn -> Application.put_env(:mishka_cms_core, :extensions, extensions) end)
    Application.put_env(:mishka_cms_core, :extensions, [Alpha])
    listed(Alpha, :api, [route("/auth/feed")])

    router =
      quote do
        defmodule MishkaCmsCore.ExtensionRouterTest.RefusedRouter do
          use Phoenix.Router
          import Phoenix.LiveView.Router
          import MishkaCmsCore.ExtensionRouter

          scope "/" do
            extension_routes(:api)
          end
        end
      end

    error = assert_raise CompileError, fn -> Code.compile_quoted(router) end
    assert error.description =~ "MishkaCmsCore.ExtensionRouterTest.Alpha"
    assert error.description =~ "GET /auth/feed"
  end
end
