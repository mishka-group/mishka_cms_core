defmodule MishkaCmsCore.Runtime.Resources.RedirectTest do
  @moduledoc """
  `MishkaCmsCore.Runtime.Redirect`: the form both addresses are stored in, the rules a save is held
  to — a well-formed address and target, one live rule per address on a site, no rule that sends an
  address to itself or round a loop — and who reads and writes a site's rules.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.{Redirect, Redirects}
  alias MishkaCmsCore.Runtime.States.SiteState

  @moduletag :capture_log

  defp create(site, attrs, opts \\ []),
    do:
      Ash.create(
        Redirect,
        attrs,
        Keyword.merge([action: :create, tenant: site.id, authorize?: false], opts)
      )

  defp create!(site, attrs) do
    {:ok, redirect} = create(site, attrs)
    redirect
  end

  defp edit(redirect, attrs, opts \\ []),
    do:
      Ash.update(
        redirect,
        attrs,
        Keyword.merge([action: :update, tenant: redirect.site_id, authorize?: false], opts)
      )

  defp errors(%Ash.Error.Invalid{errors: errors}),
    do: Enum.map(errors, &{Map.get(&1, :field), Exception.message(&1)})

  defp refused_on?({:error, %Ash.Error.Invalid{} = error}, field),
    do: Enum.any?(errors(error), &(elem(&1, 0) == field))

  defp refused_on?(_result, _field), do: false

  defp read(action, actor, tenant) do
    Redirect
    |> Ash.Query.for_read(action, %{}, actor: actor, tenant: tenant, authorize?: true)
    |> Ash.read(page: false)
  end

  defp forbidden?({:error, %Ash.Error.Forbidden{}}), do: true
  defp forbidden?(_result), do: false

  describe "normalize_path/1" do
    test "keeps the path alone: no scheme, host, query, fragment or trailing slash" do
      assert Redirects.normalize_path("https://mishka.tools/images/blog/a.jpg?w=1#top") ==
               {:ok, "/images/blog/a.jpg"}

      assert Redirects.normalize_path("//cdn.example.com/a.jpg") == {:ok, "/a.jpg"}
      assert Redirects.normalize_path("  /old-page/  ") == {:ok, "/old-page"}
      assert Redirects.normalize_path("old-page") == {:ok, "/old-page"}
      assert Redirects.normalize_path("/a//b///") == {:ok, "/a/b"}
      assert Redirects.normalize_path("/") == {:ok, "/"}
      assert Redirects.normalize_path("https://mishka.tools") == {:ok, "/"}
    end

    test "decodes its escapes, so a browser's spelling and a typed one are the same address" do
      assert Redirects.normalize_path("/fa/%D8%A8%D9%84%D8%A7%DA%AF") == {:ok, "/fa/بلاگ"}
      assert Redirects.normalize_path("/fa/بلاگ") == {:ok, "/fa/بلاگ"}
      assert Redirects.normalize_path("/100%25") == {:ok, "/100%"}
      assert Redirects.normalize_path("/100%") == {:ok, "/100%"}
    end

    test "refuses what cannot be an address on a site" do
      for bad <- ["", "   ", "/a b", "/a\tb", "mailto:someone@example.com", "ftp://x/y", "/%FF"] do
        assert Redirects.normalize_path(bad) == :error, "#{inspect(bad)} was accepted"
      end
    end
  end

  describe "normalize_target/1" do
    test "takes a path on the site, with its query and fragment, or an absolute http(s) URL" do
      assert Redirects.normalize_target(" /new?x=1#top ") == {:ok, "/new?x=1#top"}
      assert Redirects.normalize_target("https://example.com/x") == {:ok, "https://example.com/x"}
      assert Redirects.normalize_target("http://example.com") == {:ok, "http://example.com"}
    end

    test "refuses anything else, a protocol-relative address included" do
      for bad <- ["", "new-page", "//evil.example/x", "ftp://example.com/x", "https://", "/a b"] do
        assert Redirects.normalize_target(bad) == :error, "#{inspect(bad)} was accepted"
      end
    end
  end

  describe "a save" do
    setup do
      {:ok, site: create_site!()}
    end

    test "stores both addresses as they are matched, with 301 and active by default", %{
      site: site
    } do
      redirect =
        create!(site, %{
          from_path: "https://mishka.tools/images/blog/a.jpg?w=1",
          to: " /uploads/site/media/a.jpg "
        })

      assert redirect.from_path == "/images/blog/a.jpg"
      assert redirect.to == "/uploads/site/media/a.jpg"
      assert redirect.status == 301
      assert redirect.active
      assert redirect.site_id == site.id
    end

    test "refuses a malformed address or target, each on its own field", %{site: site} do
      assert refused_on?(create(site, %{from_path: "/a b", to: "/new"}), :from_path)
      assert refused_on?(create(site, %{from_path: "/old", to: "new"}), :to)
      assert refused_on?(create(site, %{from_path: "/old", to: "//evil.example/x"}), :to)
      assert refused_on?(create(site, %{from_path: "/old", to: "javascript:alert(1)"}), :to)
    end

    # A rule on the dashboard, an API or LiveView's socket would lock the people who manage the site
    # out of it.
    test "refuses the CMS's own addresses, and only those", %{site: site} do
      for path <- [
            "/admin",
            "/admin/dashboard",
            "/api/v1/x",
            "/live",
            "/live/websocket",
            "/phoenix"
          ] do
        assert refused_on?(create(site, %{from_path: path, to: "/new"}), :from_path),
               "#{path} was accepted"
      end

      assert {:ok, _} = create(site, %{from_path: "/administrators", to: "/team"})
      assert {:ok, _} = create(site, %{from_path: "/apis", to: "/docs"})
    end

    test "refuses a status that is not a redirect's", %{site: site} do
      assert {:error, %Ash.Error.Invalid{}} =
               create(site, %{from_path: "/old", to: "/new", status: 303})

      for status <- Redirects.statuses() do
        assert {:ok, %{status: ^status}} =
                 create(site, %{from_path: "/s#{status}", to: "/new", status: status})
      end
    end

    test "an update normalises the address it writes", %{site: site} do
      redirect = create!(site, %{from_path: "/old", to: "/new"})
      assert {:ok, updated} = edit(redirect, %{from_path: "/moved/"})
      assert updated.from_path == "/moved"
    end
  end

  describe "one live rule per address" do
    test "a site refuses a second rule for an address, however it is spelled" do
      site = create_site!()
      create!(site, %{from_path: "/old", to: "/new"})

      assert {:error, %Ash.Error.Invalid{}} = create(site, %{from_path: "/old/", to: "/other"})

      assert {:error, %Ash.Error.Invalid{}} =
               create(site, %{from_path: "https://x.test/old?q=1", to: "/other"})
    end

    test "another site redirects the same address", %{} do
      create!(create_site!(), %{from_path: "/old", to: "/new"})
      assert {:ok, _redirect} = create(create_site!(), %{from_path: "/old", to: "/new"})
    end

    test "an archived rule leaves its address free" do
      site = create_site!()
      redirect = create!(site, %{from_path: "/old", to: "/new"})
      :ok = Ash.destroy(redirect, tenant: site.id, authorize?: false)

      assert {:ok, _redirect} = create(site, %{from_path: "/old", to: "/elsewhere"})
    end
  end

  describe "loops" do
    setup do
      {:ok, site: create_site!()}
    end

    test "a rule cannot send an address to itself", %{site: site} do
      assert refused_on?(create(site, %{from_path: "/a", to: "/a"}), :to)
      assert refused_on?(create(site, %{from_path: "/a", to: "/a/?utm=1"}), :to)
    end

    test "a rule that closes a chain is refused, and one that leaves it is not", %{site: site} do
      create!(site, %{from_path: "/a", to: "/b"})
      create!(site, %{from_path: "/b", to: "/c"})

      assert refused_on?(create(site, %{from_path: "/c", to: "/a"}), :to)

      create!(site, %{from_path: "/x", to: "/b"})
      assert refused_on?(create(site, %{from_path: "/c", to: "/x"}), :to)

      assert {:ok, _redirect} = create(site, %{from_path: "/c", to: "/d"})
    end

    test "an inactive rule closes no loop until it is switched on", %{site: site} do
      create!(site, %{from_path: "/a", to: "/b"})
      back = create!(site, %{from_path: "/b", to: "/a", active: false})

      assert refused_on?(edit(back, %{active: true}), :to)
    end

    test "an update that turns a rule round is refused", %{site: site} do
      create!(site, %{from_path: "/a", to: "/b"})
      second = create!(site, %{from_path: "/b", to: "/c"})

      assert refused_on?(edit(second, %{to: "/a?from=b"}), :to)
    end

    test "a full address on the site's own host is the site's path" do
      n = System.unique_integer([:positive])
      site = create_site!(name: "redirects-#{n}", host: "redirects-#{n}.test")

      :ok =
        SiteState.save(%{
          id: site.id,
          name: site.name,
          host: site.host,
          priority: 0,
          active: true
        })

      on_exit(fn -> SiteState.delete(site.id) end)

      assert refused_on?(create(site, %{from_path: "/a", to: "https://#{site.host}/a"}), :to)
      assert {:ok, _redirect} = create(site, %{from_path: "/a", to: "https://elsewhere.test/a"})
    end

    test "another site's rules play no part", %{site: site} do
      other = create_site!()
      create!(other, %{from_path: "/b", to: "/a"})

      assert {:ok, _redirect} = create(site, %{from_path: "/a", to: "/b"})
    end
  end

  describe "who manages a site's rules" do
    setup do
      site = create_site!()
      other = create_site!()

      {:ok,
       site: site,
       other: other,
       theirs: create!(other, %{from_path: "/theirs", to: "/x"}),
       ours: create!(site, %{from_path: "/ours", to: "/x"}),
       admin:
         create_user_with_permissions!(["admin:dashboard:runtime:redirect"], site_id: site.id)}
    end

    test "a site admin of the section writes its own site's rules", %{site: site, admin: admin} do
      assert {:ok, redirect} =
               create(site, %{from_path: "/new", to: "/x"}, actor: admin, authorize?: true)

      assert {:ok, redirect} = edit(redirect, %{status: 302}, actor: admin, authorize?: true)

      assert :ok =
               Ash.destroy(redirect, tenant: site.id, actor: admin, authorize?: true)
    end

    test "a site admin writes nothing on another site", %{
      other: other,
      theirs: theirs,
      admin: admin
    } do
      assert forbidden?(
               create(other, %{from_path: "/mine", to: "/x"}, actor: admin, authorize?: true)
             )

      assert forbidden?(edit(theirs, %{status: 302}, actor: admin, authorize?: true))

      assert forbidden?(Ash.destroy(theirs, tenant: other.id, actor: admin, authorize?: true))
    end

    test "a site admin reads its own site's rules and no other's", %{
      site: site,
      other: other,
      ours: ours,
      admin: admin
    } do
      assert {:ok, [read]} = read(:read, admin, site.id)
      assert read.id == ours.id

      assert {:ok, []} = read(:read, admin, other.id)
      assert {:error, _master_only} = read(:master_read, admin, nil)
    end

    test "a dashboard admin of another area reads the rules and writes none", %{
      site: site,
      ours: ours
    } do
      reader = create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: site.id)

      assert {:ok, [_ours]} = read(:read, reader, site.id)

      assert forbidden?(
               create(site, %{from_path: "/new", to: "/x"}, actor: reader, authorize?: true)
             )

      assert forbidden?(edit(ours, %{status: 302}, actor: reader, authorize?: true))
    end

    test "a visitor reads and writes nothing", %{site: site, ours: ours} do
      assert {:ok, []} = read(:read, nil, site.id)

      assert forbidden?(
               create(site, %{from_path: "/new", to: "/x"}, actor: nil, authorize?: true)
             )

      assert forbidden?(edit(ours, %{status: 302}, actor: nil, authorize?: true))
    end

    test "a master of the section manages every site's rules", %{other: other, theirs: theirs} do
      master = create_user_with_permissions!(["admin:dashboard:runtime:redirect"])

      assert {:ok, created} =
               Ash.create(Redirect, %{site_id: other.id, from_path: "/by-master", to: "/x"},
                 action: :master_create,
                 actor: master
               )

      assert created.site_id == other.id

      {:ok, theirs} = Ash.get(Redirect, theirs.id, action: :master_get, actor: master)

      assert {:ok, %{status: 307}} =
               Ash.update(theirs, %{status: 307}, action: :master_update, actor: master)

      assert {:ok, rules} = read(:master_read, master, nil)
      assert Enum.any?(rules, &(&1.id == theirs.id))
    end

    test "the cache's read is refused to every actor", %{site: site} do
      master = create_user_with_permissions!(["*"])

      create!(site, %{from_path: "/cached", to: "/x"})

      for actor <- [master, create_user_with_permissions!(["*"], site_id: site.id)] do
        assert {:ok, []} = read(:read_any, actor, nil)
      end
    end
  end
end
