defmodule MishkaCmsCore.Accounts.MasterUserCreationTest do
  @moduledoc """
  Only a master makes a master, and only from the admin dashboard.

  A master is an account with no site, and a user created with no tenant is one. Signing up
  (`:register_with_password`) and `:create` refuse that to everyone, a master included, so the rule
  holds for a call that reaches the action directly, not only for the routes in front of it. A new
  master is added by a master from the dashboard's Users table, which runs `:master_create`.

  The installer makes the first master with authorization off, before any master exists to ask.

  The same line runs through looking an account up: with no tenant, the lookup a password reset or a
  magic link makes finds a master and never a site's user.
  """
  use MishkaCmsCore.DataCase

  alias MishkaCmsCore.Accounts.User

  require Ash.Query

  @password "Password123!"

  defp admin(permissions, site_id) do
    permissions
    |> create_user_with_permissions!(site_id: site_id)
    |> Ash.load!([:permission_values], authorize?: false, tenant: site_id)
  end

  defp register(email, opts) do
    User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{email: email, password: @password, password_confirmation: @password},
      opts
    )
    |> Ash.create()
  end

  defp create(email, opts) do
    User
    |> Ash.Changeset.for_create(:create, %{email: email}, opts)
    |> Ash.create()
  end

  defp masters_named(email) do
    User
    |> Ash.Query.filter(email == ^email and is_nil(site_id))
    |> Ash.read!(authorize?: false)
  end

  defp by_email(email, opts) do
    User
    |> Ash.Query.for_read(:get_by_email, %{email: email}, opts)
    |> Ash.read_one(authorize?: false)
  end

  describe "a site's admin, asking with no tenant" do
    setup do
      {:ok, site: create_site!()}
    end

    test "cannot register a master, whichever admin permission it holds", %{site: site} do
      for permission <- ["admin:dashboard:*", "admin:api:*", "*"] do
        email = "made-by-#{String.replace(permission, ":", "-")}@example.com"

        assert {:error, _refused} = register(email, actor: admin([permission], site.id)),
               permission

        assert masters_named(email) == [], permission
      end
    end

    test "cannot create a master", %{site: site} do
      for permission <- ["admin:dashboard:*", "admin:api:*", "*"] do
        email = "created-by-#{String.replace(permission, ":", "-")}@example.com"

        assert {:error, _refused} = create(email, actor: admin([permission], site.id)),
               permission

        assert masters_named(email) == [], permission
      end
    end

    test "still makes users of its own site", %{site: site} do
      actor = admin(["admin:dashboard:*"], site.id)

      assert {:ok, %{site_id: site_id}} =
               register("colleague@example.com", actor: actor, tenant: site.id)

      assert site_id == site.id

      assert {:ok, %{site_id: ^site_id}} =
               create("another@example.com", actor: actor, tenant: site.id)
    end
  end

  # SIGNING UP NEVER MAKES A MASTER, whoever asks. A new master is added by a master from the admin
  # dashboard's Users table, which runs `:master_create`.
  describe "a master" do
    test "cannot register or create a master the way a user signs up" do
      for permission <- ["admin:dashboard:*", "admin:api:*", "admin:*", "*"] do
        actor = admin([permission], nil)
        slug = String.replace(permission, ~r/[:*]/, "-")

        assert {:error, _refused} = register("signed-up-#{slug}@example.com", actor: actor),
               permission

        assert {:error, _refused} = create("created-#{slug}@example.com", actor: actor),
               permission

        assert masters_named("signed-up-#{slug}@example.com") == [], permission
        assert masters_named("created-#{slug}@example.com") == [], permission
      end
    end

    test "adds a master from the dashboard's Users table" do
      actor = admin(["admin:dashboard:*"], nil)

      assert {:ok, %{site_id: nil}} =
               User
               |> Ash.Changeset.for_create(
                 :master_create,
                 %{
                   email: "added-master@example.com",
                   password: @password,
                   password_confirmation: @password
                 },
                 actor: actor
               )
               |> Ash.create()
    end

    test "still makes users of a site" do
      site = create_site!()
      actor = admin(["admin:dashboard:*"], nil)

      assert {:ok, %{site_id: site_id}} =
               register("site-member@example.com", actor: actor, tenant: site.id)

      assert site_id == site.id
    end
  end

  # A PLUGIN HEARS EVERY MASTER CREATION REFUSED, with the action, who asked and for which address.
  describe "a refused master creation" do
    alias MishkaInstaller.Event.{Event, EventHandler}

    setup do
      Process.register(self(), :__plugin_hook_probe__)
      event = "cms_core:user:master_creation_refused"
      module = MishkaCmsCore.Test.Plugins.MasterCreationRefused

      {:ok, _} =
        Event.write(%{name: module, event: event, extension: :mishka_installer, status: :started})

      :ok = EventHandler.do_compile(event, :start, false)
      on_exit(fn -> Event.unregister(:name, module, false) end)
      :ok
    end

    test "is heard on cms_core:user:master_creation_refused, and a master's creation is not" do
      site_admin = admin(["*"], create_site!().id)
      actor_id = site_admin.id

      assert {:error, _refused} = register("heard@example.com", actor: site_admin)

      assert_receive {:master_creation_refused, :register_with_password, ^actor_id,
                      "heard@example.com"}

      assert {:error, _refused} = create("heard-too@example.com", actor: site_admin)
      assert_receive {:master_creation_refused, :create, ^actor_id, "heard-too@example.com"}

      assert {:error, _refused} = register("walk-in-heard@example.com", [])

      assert_receive {:master_creation_refused, :register_with_password, nil,
                      "walk-in-heard@example.com"}

      master = admin(["admin:dashboard:*"], nil)
      master_id = master.id

      assert {:error, _refused} = register("master-asked@example.com", actor: master)

      assert_receive {:master_creation_refused, :register_with_password, ^master_id,
                      "master-asked@example.com"}

      assert {:ok, _site_user} =
               register("quiet@example.com", actor: master, tenant: create_site!().id)

      refute_receive {:master_creation_refused, _action, _actor_id, "quiet@example.com"}, 200
    end
  end

  test "a visitor with no tenant cannot register a master" do
    assert {:error, _refused} = register("walk-in@example.com", [])
    assert masters_named("walk-in@example.com") == []
  end

  test "with no tenant, the reset and magic-link lookup finds a master and no site's user" do
    site = create_site!()
    site_user = create_user!(site_id: site.id, email: "member@example.com")
    master = create_user!(email: "boss@example.com")

    assert {:ok, nil} = by_email("member@example.com", [])
    assert {:ok, %{id: master_id}} = by_email("boss@example.com", [])
    assert master_id == master.id

    assert {:ok, %{id: site_user_id}} = by_email("member@example.com", tenant: site.id)
    assert site_user_id == site_user.id
  end

  # How `MishkaCmsCore.Install.Bootstrap` makes the first master: no actor, authorization off.
  test "the installer still makes the first master" do
    assert {:ok, %{site_id: nil}} = register("first-master@example.com", authorize?: false)
  end
end
