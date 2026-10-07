defmodule MishkaCmsCore.Runtime.States.RedirectsStateTest do
  @moduledoc """
  The ETS copy of `MishkaCmsCore.Runtime.Redirect` every request is answered from.

  What it holds — each site's active, unarchived rules, keyed by site and address — and how it stays
  equal to the table: loaded whole by `refresh/0`, the same pass `init/1` runs at boot, and kept
  current between loads off the resource's own broadcasts, with no query of its own. A rule that
  moved, was switched off, archived or deleted leaves its old address behind it.

  The cache is process-global, not sandboxed. Every rule here belongs to a site of its own test, so
  no other test can match it.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.{Redirect, Redirects}
  alias MishkaCmsCore.Runtime.States.RedirectsState
  alias MishkaCmsCore.Test.Plugins.RedirectStateChanged
  alias MishkaInstaller.Event.{Event, EventHandler}

  @moduletag :integration

  # A WRITE REACHES THE CACHE AS A MESSAGE sent from the test process itself, so once the state has
  # answered a call from here it has worked through every broadcast this test sent before it.
  defp settled, do: _handled = :sys.get_state(RedirectsState)

  defp create!(site, attrs, opts \\ []) do
    redirect =
      Ash.create!(
        Redirect,
        attrs,
        Keyword.merge([action: :create, tenant: site.id, authorize?: false], opts)
      )

    settled()
    redirect
  end

  defp edit!(redirect, attrs) do
    redirect = Ash.update!(redirect, attrs, tenant: redirect.site_id, authorize?: false)
    settled()
    redirect
  end

  setup do
    {:ok, site: create_site!(), other: create_site!()}
  end

  test "a saved rule is served under its site and address", %{site: site} do
    create!(site, %{from_path: "/images/blog/a.jpg", to: "/uploads/a.jpg", status: 308})

    assert RedirectsState.lookup(site.id, "/images/blog/a.jpg") == {"/uploads/a.jpg", 308}
    assert RedirectsState.lookup(site.id, "/images/blog/b.jpg") == nil
  end

  test "another site's rule never answers", %{site: site, other: other} do
    create!(other, %{from_path: "/old", to: "/new"})

    assert RedirectsState.lookup(site.id, "/old") == nil
    assert RedirectsState.lookup(other.id, "/old") == {"/new", 301}
  end

  test "an update moves the rule: the old address is let go, the new one served", %{site: site} do
    redirect = create!(site, %{from_path: "/old", to: "/new"})
    edit!(redirect, %{from_path: "/older", to: "/newer", status: 302})

    assert RedirectsState.lookup(site.id, "/old") == nil
    assert RedirectsState.lookup(site.id, "/older") == {"/newer", 302}
  end

  test "a rule switched off is let go, and served again when switched on", %{site: site} do
    redirect = create!(site, %{from_path: "/old", to: "/new"})

    redirect = edit!(redirect, %{active: false})
    assert RedirectsState.lookup(site.id, "/old") == nil

    edit!(redirect, %{active: true})
    assert RedirectsState.lookup(site.id, "/old") == {"/new", 301}
  end

  test "an archived rule is let go, a restored one served, a deleted one gone", %{site: site} do
    redirect = create!(site, %{from_path: "/old", to: "/new"})

    :ok = Ash.destroy(redirect, tenant: site.id, authorize?: false)
    settled()
    assert RedirectsState.lookup(site.id, "/old") == nil

    {:ok, archived} =
      Ash.get(Redirect, redirect.id, action: :get_archived, tenant: site.id, authorize?: false)

    restored = Ash.update!(archived, %{}, action: :unarchive, authorize?: false)
    settled()
    assert RedirectsState.lookup(site.id, "/old") == {"/new", 301}

    :ok = Ash.destroy(restored, action: :permanent_destroy, authorize?: false)
    settled()
    assert RedirectsState.lookup(site.id, "/old") == nil
  end

  # Broadcasts from two nodes can arrive in either order: here the new rule's create lands before
  # the archive of the rule that held its address.
  test "an address freed by an archived rule stays the new rule's when the archive arrives late",
       %{
         site: site
       } do
    first = create!(site, %{from_path: "/old", to: "/first"})

    {:ok, _held_back} =
      Ash.destroy(first, tenant: site.id, authorize?: false, return_notifications?: true)

    create!(site, %{from_path: "/old", to: "/second"})
    assert RedirectsState.lookup(site.id, "/old") == {"/second", 301}

    send(RedirectsState, %Phoenix.Socket.Broadcast{
      topic: "redirect:destroyed",
      event: "destroyed",
      payload: %Ash.Notifier.Notification{resource: Redirect, data: first}
    })

    settled()
    assert RedirectsState.lookup(site.id, "/old") == {"/second", 301}
  end

  test "the boot load reads the active, unarchived rules from the database", %{site: site} do
    # Written with their notifications handed back rather than sent, so only a read can find them.
    quiet = [return_notifications?: true]

    {:ok, _served, _notifications} =
      Ash.create(Redirect, %{from_path: "/served", to: "/new"},
        action: :create,
        tenant: site.id,
        authorize?: false,
        return_notifications?: true
      )

    {:ok, _off, _notifications} =
      Ash.create(Redirect, %{from_path: "/off", to: "/new", active: false},
        action: :create,
        tenant: site.id,
        authorize?: false,
        return_notifications?: true
      )

    {:ok, archived, _notifications} =
      Ash.create(Redirect, %{from_path: "/archived", to: "/new"},
        action: :create,
        tenant: site.id,
        authorize?: false,
        return_notifications?: true
      )

    {:ok, _notifications} =
      Ash.destroy(archived, [tenant: site.id, authorize?: false] ++ quiet)

    assert RedirectsState.lookup(site.id, "/served") == nil

    :ok = RedirectsState.refresh()

    assert RedirectsState.lookup(site.id, "/served") == {"/new", 301}
    assert RedirectsState.lookup(site.id, "/off") == nil
    assert RedirectsState.lookup(site.id, "/archived") == nil
  end

  describe "runtime:state:redirect:changed" do
    setup do
      Process.register(self(), :__plugin_hook_probe__)

      {:ok, _} =
        Event.write(%{
          name: RedirectStateChanged,
          event: "runtime:state:redirect:changed",
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile("runtime:state:redirect:changed", :start, false)
      on_exit(fn -> Event.unregister(:name, RedirectStateChanged, false) end)
      :ok
    end

    test "hears a rule kept and a rule let go", %{site: site} do
      redirect = create!(site, %{from_path: "/old", to: "/new"})
      id = redirect.id
      assert_receive {:redirect_changed, :save, ^id}, 5000

      :ok = Ash.destroy(redirect, tenant: site.id, authorize?: false)
      settled()
      assert_receive {:redirect_changed, :delete, ^id}, 5000
    end
  end

  test "an address is looked up the way it is stored, however the request spelled it", %{
    site: site
  } do
    create!(site, %{from_path: "/fa/%D8%A8%D9%84%D8%A7%DA%AF/", to: "/fa/blog"})

    assert Redirects.lookup(site.id, "/fa/%D8%A8%D9%84%D8%A7%DA%AF", "") == {"/fa/blog", 301}
    assert Redirects.lookup(site.id, "/fa/بلاگ/", "") == {"/fa/blog", 301}
    assert Redirects.lookup(site.id, "//fa//بلاگ", "page=2") == {"/fa/blog?page=2", 301}
  end
end
