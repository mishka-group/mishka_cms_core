# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.HeadCodeTest do
  @moduledoc """
  A site's head code entries, from the write to the head of its public pages: only a master holding
  the section writes one, only a published one is served, it is served from memory with no query,
  only on the pages its scope names, and an extension's tags reach the same head through
  `runtime:page:head`.

  `SiteState` is process-global; every entry here belongs to a site of its own test.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.{HeadCode, HeadCodes}
  alias MishkaCmsCore.Runtime.Handlers.BootHandler
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Plugins.{HeadCodeItems, HeadCodeOrigins}
  alias MishkaInstaller.Event.{Event, EventHandler}

  @moduletag :integration

  @plausible ~s(<script defer data-domain="mishka.tools" src="https://plausible.io/js/script.js"></script>)

  setup do
    snapshot = SiteState.snapshot()
    on_exit(fn -> SiteState.restore(snapshot) end)

    master = create_user_with_permissions!(["admin:dashboard:runtime:head_code"])
    {:ok, site: create_site!(), other: create_site!(), master: master}
  end

  defp write!(site, master, attrs) do
    Ash.create!(
      HeadCode,
      Map.merge(%{site_id: site.id, name: "Plausible", code: @plausible, published: true}, attrs),
      action: :master_create,
      actor: master
    )
  end

  # Read back as the admin's form reads it, under no tenant: a master's actions take none.
  defp fresh!(entry, master), do: Ash.get!(HeadCode, entry.id, action: :master_get, actor: master)

  defp head(site, path, page_path \\ nil),
    do: HeadCodes.head(site.id, path, %{path: page_path || path}, "n0nce")

  defp keys(items), do: items |> Enum.map(& &1.key) |> Enum.uniq()

  defp register!(plugin, event) do
    {:ok, _} =
      Event.write(%{name: plugin, event: event, extension: :mishka_installer, status: :started})

    :ok = EventHandler.do_compile(event, :start, false)
    on_exit(fn -> Event.unregister(:name, plugin, false) end)
  end

  describe "who writes an entry" do
    test "a master holding the section writes one", %{site: site, master: master} do
      entry = write!(site, master, %{origins: ["https://plausible.io"]})

      assert entry.site_id == site.id
      assert entry.origins == ["https://plausible.io"]
    end

    test "a site user is refused, whatever it holds", %{site: site} do
      admin = create_user_with_permissions!(["*"], site_id: site.id)

      assert {:error, _refused} =
               Ash.create(
                 HeadCode,
                 %{site_id: site.id, name: "x", code: @plausible},
                 action: :master_create,
                 actor: admin
               )
    end

    test "a master without the section is refused", %{site: site} do
      master = create_user_with_permissions!(["admin:dashboard:runtime:page"])

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.create(
                 HeadCode,
                 %{site_id: site.id, name: "x", code: @plausible},
                 action: :master_create,
                 actor: master
               )
    end
  end

  describe "what an entry may hold" do
    test "code that keeps no head tag is refused", %{site: site, master: master} do
      assert_raise Ash.Error.Invalid, ~r/Use script, meta, link or noscript/, fn ->
        write!(site, master, %{code: "<div>hello</div>"})
      end
    end

    test "an origin that is not https and a host is refused", %{site: site, master: master} do
      for origin <- ["http://plausible.io", "https://plausible.io/api", "plausible.io"] do
        assert_raise Ash.Error.Invalid, ~r/Each origin is https/, fn ->
          write!(site, master, %{origins: [origin]})
        end
      end
    end

    test "a scope limited to pages names at least one path", %{site: site, master: master} do
      assert_raise Ash.Error.Invalid, ~r/at least one page path/, fn ->
        write!(site, master, %{scope: :only, paths: []})
      end

      assert_raise Ash.Error.Invalid, ~r/at least one page path/, fn ->
        write!(site, master, %{scope: :only, paths: ["pricing"]})
      end
    end

    test "a site holds a limited number of entries", %{site: site, master: master} do
      for _n <- 1..HeadCodes.max_entries(), do: write!(site, master, %{published: false})

      assert_raise Ash.Error.Invalid, ~r/the most it may hold/, fn ->
        write!(site, master, %{published: false})
      end
    end
  end

  describe "the head of a public page" do
    test "a published entry reaches every page with the response's nonce", %{
      site: site,
      master: master
    } do
      entry = write!(site, master, %{origins: ["https://plausible.io"]})

      for path <- ["/", "/pricing"] do
        assert [%{tag: "script", key: key} = script] = head(site, path)
        assert key == entry.id
        assert {"src", "https://plausible.io/js/script.js"} in script.attrs
      end

      html =
        Phoenix.LiveViewTest.rendered_to_string(
          HeadCodes.tags(%{items: head(site, "/"), csp_nonce: "n0nce"})
        )

      assert html =~ ~s(nonce="n0nce")
    end

    test "a draft is not served, and publishing it serves it", %{site: site, master: master} do
      entry = write!(site, master, %{published: false})
      assert head(site, "/") == []

      entry
      |> fresh!(master)
      |> Ash.update!(%{published: true}, action: :master_update, actor: master)

      assert keys(head(site, "/")) == [entry.id]
    end

    test "an archived entry is no longer served", %{site: site, master: master} do
      entry = write!(site, master, %{})

      :ok = entry |> fresh!(master) |> Ash.destroy(action: :master_destroy, actor: master)

      assert head(site, "/") == []
    end

    test "an entry limited to one page appears on that page alone", %{site: site, master: master} do
      only = write!(site, master, %{scope: :only, paths: ["/pricing"]})

      except =
        write!(site, master, %{name: "Not on pricing", scope: :except, paths: ["/pricing"]})

      assert keys(head(site, "/pricing")) == [only.id]
      assert keys(head(site, "/about")) == [except.id]
      assert keys(head(site, "/blog/hello", "/blog/:slug")) == [except.id]
    end

    test "another site's entries never reach it", %{site: site, other: other, master: master} do
      write!(other, master, %{})

      assert head(site, "/") == []
      assert HeadCodes.origins(site.id) == []
    end

    test "a second page load reads no query", %{site: site, master: master} do
      write!(site, master, %{origins: ["https://plausible.io"]})
      handler = "head-code-#{System.unique_integer([:positive])}"
      test = self()

      :telemetry.attach(
        handler,
        [:mishka_cms_core, :repo, :query],
        fn _event, _measurements, meta, _config -> send(test, {handler, meta[:query]}) end,
        nil
      )

      try do
        assert [_script] = head(site, "/")
        assert [_script] = head(site, "/")
        assert HeadCodes.origins(site.id) == ["https://plausible.io"]
      after
        :telemetry.detach(handler)
      end

      refute_received {^handler, _query}
    end

    test "the boot loads the published entries into memory", %{site: site, master: master} do
      published = write!(site, master, %{})
      _draft = write!(site, master, %{name: "Draft", published: false})

      SiteState.delete_head_code(published)
      assert head(site, "/") == []

      :ok = BootHandler.load_head_codes()

      assert keys(head(site, "/")) == [published.id]
    end

    test "another node's write is applied from its broadcast", %{site: site} do
      entry = %{
        id: Ash.UUIDv7.generate(),
        site_id: site.id,
        name: "Remote",
        code: @plausible,
        scope: :all,
        paths: [],
        origins: [],
        published: true,
        archived_at: nil
      }

      notification = fn topic ->
        %Phoenix.Socket.Broadcast{
          topic: topic,
          payload: %Ash.Notifier.Notification{data: entry, from: nil}
        }
      end

      send(SiteState, notification.("head_code:created"))
      _handled = :sys.get_state(SiteState)
      assert keys(head(site, "/")) == [entry.id]

      send(SiteState, notification.("head_code:destroyed"))
      _handled = :sys.get_state(SiteState)
      assert head(site, "/") == []
    end
  end

  describe "an extension's head tags" do
    setup do
      register!(HeadCodeItems, "runtime:page:head")
      register!(HeadCodeOrigins, "runtime:page:head_origins")
      :ok
    end

    test "reach the head through the same rules, beside the site's own", %{
      site: site,
      master: master
    } do
      entry = write!(site, master, %{origins: ["https://plausible.io"]})
      items = head(site, "/")

      assert Enum.any?(items, &(&1.key == entry.id))
      assert Enum.any?(items, &({"name", "extension-verify"} in &1.attrs))
      refute Enum.any?(items, &(&1.tag == "iframe"))
    end

    test "are listed apart from the site's own, with the origins they declare", %{
      site: site,
      master: master
    } do
      write!(site, master, %{origins: ["https://plausible.io"]})

      assert %{items: [%{tag: "meta"} = item], origins: ["https://ext.example"]} =
               HeadCodes.from_extensions(site.id)

      assert {"name", "extension-verify"} in item.attrs

      assert Enum.sort(HeadCodes.origins(site.id)) == [
               "https://ext.example",
               "https://plausible.io"
             ]
    end
  end
end
