defmodule MishkaCmsCore.Accounts.UserAccountFieldsTest do
  @moduledoc """
  Who may read an account's email, permissions, site and confirmation time.

  Any extension can reach a User through a relationship — a comment's author, a draft's creator, a
  bookmark's owner — and those relationships are what public pages and JSON:API includes are built
  from. The account fields answer only the account's owner and admins, whatever the relationship; the
  record itself, and its id, stay reachable, so a page can still say who wrote something.

  The rest of this file is what must not change: signing in, the actor read back from a token, and
  the internal loads made on that actor all keep the whole account.
  """
  use MishkaCmsCore.DataCase

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Accounts.User

  require Ash.Query

  @account_fields [:email, :confirmed_at, :site_id, :permission_values]
  @password "Password123!"
  @api %{shared: %{admin_surface: :api}}

  setup do
    site = create_site!(name: "localhost", host: "localhost", active: true, priority: 50)
    user = create_user!(email: "account.owner@example.com", site_id: site.id)

    {:ok, site: site, user: user}
  end

  # The read Ash runs when an extension loads `author`/`user`/`reporter` on its own record.
  # A relationship held back carries nothing: no site, no permissions. The fixtures give the account
  # both, so an empty answer here is the account's own being held back.
  defp withheld?(nil), do: true
  defp withheld?([]), do: true
  defp withheld?(%Ash.NotLoaded{}), do: true
  defp withheld?(%Ash.ForbiddenField{}), do: true
  defp withheld?(_loaded), do: false

  defp through_relationship(user, actor, surface \\ :dashboard) do
    User
    |> Ash.Query.for_read(:related, %{}, actor: actor)
    |> Ash.Query.set_context(%{
      accessing_from: %{source: MishkaCmsCore.Notify.Notification, name: :actor},
      shared: %{admin_surface: surface}
    })
    |> Ash.Query.filter(id == ^user.id)
    |> Ash.Query.load(:permission_values)
    |> Ash.read_one!(actor: actor, tenant: user.site_id)
  end

  describe "an account reached through a relationship" do
    test "a visitor gets the record and its id, and no account field", %{user: user} do
      seen = through_relationship(user, nil)

      assert seen.id == user.id

      for field <- @account_fields do
        assert %Ash.ForbiddenField{} = Map.get(seen, field), "#{field} reached a visitor"
      end
    end

    test "a signed-in user without an admin permission gets no one else's", %{
      user: user,
      site: site
    } do
      reader = create_user_with_permissions!(["probe:role"], site_id: site.id)
      seen = through_relationship(user, reader)

      for field <- @account_fields do
        assert %Ash.ForbiddenField{} = Map.get(seen, field), "#{field} reached another user"
      end
    end

    test "the owner gets their own", %{user: user} do
      seen = through_relationship(user, user)

      assert to_string(seen.email) == "account.owner@example.com"
      assert seen.site_id == user.site_id
      assert seen.permission_values == []
    end

    for {permission, surface} <- [
          {"admin:dashboard:user", :dashboard},
          {"admin:dashboard:*", :dashboard},
          {"admin:api:user", :api},
          {"admin:api:*", :api},
          {"*", :dashboard},
          {"*", :api}
        ] do
      test "an admin holding #{permission} gets the whole account on the #{surface}", %{
        user: user,
        site: site
      } do
        admin = create_user_with_permissions!([unquote(permission)], site_id: site.id)
        seen = through_relationship(user, admin, unquote(surface))

        assert to_string(seen.email) == "account.owner@example.com"
        assert seen.site_id == user.site_id
        assert seen.permission_values == []
      end
    end

    for {permission, surface} <- [
          {"admin:api:user", :dashboard},
          {"admin:api:*", :dashboard},
          {"admin:dashboard:user", :api},
          {"admin:dashboard:*", :api}
        ] do
      test "an admin holding #{permission} gets no account field on the #{surface}", %{
        user: user,
        site: site
      } do
        admin = create_user_with_permissions!([unquote(permission)], site_id: site.id)
        seen = through_relationship(user, admin, unquote(surface))

        for field <- @account_fields do
          assert %Ash.ForbiddenField{} = Map.get(seen, field),
                 "#{field} reached the other surface"
        end
      end
    end

    test "an admin of another area gets no account field", %{user: user, site: site} do
      admin = create_user_with_permissions!(["admin:dashboard:runtime:media"], site_id: site.id)
      seen = through_relationship(user, admin)

      for field <- @account_fields do
        assert %Ash.ForbiddenField{} = Map.get(seen, field), "#{field} reached the media area"
      end
    end

    test "an admin of another site, holding *, gets no account field", %{user: user} do
      stranger = create_user_with_permissions!(["*"], site_id: create_site!().id)
      seen = through_relationship(user, stranger)

      for field <- @account_fields do
        assert %Ash.ForbiddenField{} = Map.get(seen, field), "#{field} reached another site"
      end
    end

    test "a site's admin gets no field of a master's account", %{site: site} do
      master = create_user!(email: "a.master@example.com")
      admin = create_user_with_permissions!(["*"], site_id: site.id)
      seen = through_relationship(master, admin)

      for field <- @account_fields do
        assert %Ash.ForbiddenField{} = Map.get(seen, field), "#{field} of a master reached a site"
      end
    end

    test "a master admin gets the whole account of any site", %{user: user} do
      master = create_user_with_permissions!(["admin:dashboard:*"])
      seen = through_relationship(user, master)

      assert to_string(seen.email) == "account.owner@example.com"
      assert seen.site_id == user.site_id
    end

    # `filter_input` is how a caller's own filter arrives, `?filter[author][email]=` over JSON:API.
    test "a visitor cannot find an account by filtering on its email", %{user: user} do
      found =
        User
        |> Ash.Query.for_read(:related, %{}, actor: nil)
        |> Ash.Query.set_context(%{
          accessing_from: %{source: MishkaCmsCore.Notify.Notification, name: :actor}
        })
        |> Ash.Query.filter_input(%{email: to_string(user.email)})
        |> Ash.read!(actor: nil, tenant: user.site_id)

      assert found == []
    end
  end

  describe "an account's site and permissions, reached through a relationship" do
    # A notification's `actor` is a real relationship a signed-in user without an admin permission
    # loads on their own row: the recipient reads who caused it.
    setup %{user: user, site: site} do
      permission = create_permission!(name: "secret:role:x")

      user
      |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [permission.id]},
        authorize?: false,
        tenant: site.id
      )
      |> Ash.update!()

      recipient = create_user!(email: "recipient@example.com", site_id: site.id)

      notification =
        MishkaCmsCore.Notify.Notification
        |> Ash.Changeset.for_create(
          :deliver,
          %{type: "test:caused", title: "Caused", user_id: recipient.id, actor_id: user.id},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.create!()

      {:ok, recipient: recipient, notification: notification}
    end

    defp load_actor(notification, actor, site) do
      Ash.load!(notification, [actor: [:site, :permissions, :permission_values]],
        actor: actor,
        tenant: site.id
      ).actor
    end

    test "a signed-in user without an admin permission gets neither", %{
      recipient: recipient,
      notification: notification,
      site: site
    } do
      seen = load_actor(notification, recipient, site)

      assert withheld?(seen.site)
      assert withheld?(seen.permissions)
      assert %Ash.ForbiddenField{} = seen.permission_values
      assert %Ash.ForbiddenField{} = seen.email
    end

    test "an admin gets both", %{notification: notification, site: site} do
      admin = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
      seen = load_actor(notification, admin, site)

      assert seen.site.id == site.id
      assert Enum.map(seen.permissions, & &1.name) == ["secret:role:x"]
      assert seen.permission_values == ["secret:role:x"]
      assert to_string(seen.email) == "account.owner@example.com"
    end

    test "code that reads without authorization keeps both", %{
      notification: notification,
      site: site
    } do
      seen =
        Ash.load!(notification, [actor: [:site, :permissions]],
          authorize?: false,
          tenant: site.id
        ).actor

      assert seen.site.id == site.id
      assert Enum.map(seen.permissions, & &1.name) == ["secret:role:x"]
    end
  end

  describe "what a master's or another site's account holds, reached by a site's admin" do
    # A relationship read that names no tenant reaches accounts of every site and the masters. A
    # site's admin gets its own site's accounts whole there; a master's account and another site's
    # arrive without what they hold, since their permissions and site are not that site's to see.
    setup %{site: site} do
      secret = create_permission!(name: "secret:role:held")
      master = create_user!(email: "held.master@example.com")
      stranger = create_user!(email: "held.stranger@example.com", site_id: create_site!().id)
      colleague = create_user!(email: "held.colleague@example.com", site_id: site.id)

      for account <- [master, stranger, colleague] do
        account
        |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [secret.id]},
          authorize?: false,
          tenant: account.site_id
        )
        |> Ash.update!()
      end

      {:ok,
       master: master,
       stranger: stranger,
       colleague: colleague,
       site_admin: create_user_with_permissions!(["*"], site_id: site.id)}
    end

    defp holdings(account, actor) do
      User
      |> Ash.Query.for_read(:related, %{}, actor: actor)
      |> Ash.Query.set_context(%{
        accessing_from: %{source: MishkaCmsCore.Notify.Notification, name: :actor}
      })
      |> Ash.Query.filter(id == ^account.id)
      |> Ash.Query.load([:site, :permissions, :permissions_join_assoc])
      |> Ash.read_one!(actor: actor)
    end

    test "a site's admin gets nothing a master's account holds", ctx do
      seen = holdings(ctx.master, ctx.site_admin)

      assert seen.id == ctx.master.id
      assert withheld?(seen.permissions)
      assert withheld?(seen.permissions_join_assoc)
    end

    test "a site's admin gets nothing another site's account holds", ctx do
      seen = holdings(ctx.stranger, ctx.site_admin)

      assert seen.id == ctx.stranger.id
      assert withheld?(seen.permissions)
      assert withheld?(seen.permissions_join_assoc)
      assert withheld?(seen.site)
    end

    test "a site's admin gets what its own site's account holds", ctx do
      seen = holdings(ctx.colleague, ctx.site_admin)

      assert Enum.map(seen.permissions, & &1.name) == ["secret:role:held"]
      assert length(seen.permissions_join_assoc) == 1
      assert seen.site.id == ctx.site.id
    end

    test "a master admin gets what any account holds", ctx do
      master_admin = create_user_with_permissions!(["admin:dashboard:*"])

      for account <- [ctx.master, ctx.stranger] do
        seen = holdings(account, master_admin)

        assert Enum.map(seen.permissions, & &1.name) == ["secret:role:held"]
        assert length(seen.permissions_join_assoc) == 1
      end

      assert holdings(ctx.stranger, master_admin).site.id == ctx.stranger.site_id
    end
  end

  describe "every relationship into an account" do
    # Every public relationship into User reads through `:related`, where the account's fields
    # answer only its owner and admins, and cannot be sorted through, because Ash checks no field
    # policy on a sort through a relationship.
    test "reads through :related and sorts through nothing" do
      offenders =
        for domain <- Application.fetch_env!(:mishka_cms_core, :ash_domains),
            resource <- Ash.Domain.Info.resources(domain),
            %{destination: User, public?: true} = relationship <-
              Ash.Resource.Info.relationships(resource),
            relationship.read_action != :related or relationship.sortable?,
            do: "#{inspect(resource)}.#{relationship.name}"

      assert offenders == [],
             "these reach an account without `read_action :related` and `sortable? false`: " <>
               Enum.join(offenders, ", ")
    end

    # One that forgets its `read_action` reads the account through `:read`, and reaches nothing
    # unless an admin is asking — never the whole account.
    test "one that reads through :read reaches no account unless an admin asks", %{
      user: user,
      site: site
    } do
      reader = create_user_with_permissions!(["probe:role"], site_id: site.id)
      admin = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)

      through_read = fn actor ->
        User
        |> Ash.Query.for_read(:read, %{}, actor: actor)
        |> Ash.Query.set_context(%{
          accessing_from: %{source: MishkaCmsCore.Notify.Notification, name: :actor}
        })
        |> Ash.Query.filter(id == ^user.id)
        |> Ash.read_one(actor: actor, tenant: site.id)
      end

      refute match?({:ok, %User{}}, through_read.(nil))
      refute match?({:ok, %User{}}, through_read.(reader))
      assert {:ok, %User{id: id}} = through_read.(admin)
      assert id == user.id
    end
  end

  describe "a caller's own filter through a relationship" do
    # `?filter[author][email]=` on a public route is a filter reference through a relationship,
    # which Ash authorizes apart from any load: the account is never loaded, only matched against.
    # A notification's `actor` is a relationship a signed-in user without an admin permission
    # filters on their own rows, and an admin reading their own notification shows the same filter
    # does match.
    setup %{user: user, site: site} do
      permission = create_permission!(name: "secret:role:x")

      user =
        user
        |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [permission.id]},
          authorize?: false,
          tenant: site.id
        )
        |> Ash.update!()

      {:ok, user: user}
    end

    defp caused_by(user, recipient, site) do
      MishkaCmsCore.Notify.Notification
      |> Ash.Changeset.for_create(
        :deliver,
        %{type: "test:caused", title: "Caused", user_id: recipient.id, actor_id: user.id},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.create!()
    end

    defp feed_filtered(recipient, site, actor_filter) do
      MishkaCmsCore.Notify.Notification
      |> Ash.Query.for_read(:feed, %{}, actor: recipient, tenant: site.id)
      |> Ash.Query.filter_input(%{actor: actor_filter})
      |> Ash.read(actor: recipient, tenant: site.id, page: false)
    end

    defp account_field_filters(user, site) do
      email = to_string(user.email)

      [
        %{email: email},
        %{email: %{less_than: email <> "~"}},
        %{email: %{contains: String.slice(email, 0, 6)}},
        %{site_id: site.id}
      ]
    end

    # A withheld field reads as nil, so `is_nil` is true of every account alike: it cannot tell one
    # that confirmed from one that did not, or a master account from a site's.
    defp confirmed_and_not(site) do
      confirmed =
        create_user!(email: "confirmed.one@example.com", site_id: site.id)
        |> Ash.Changeset.for_update(:update, %{}, authorize?: false, tenant: site.id)
        |> Ash.Changeset.force_change_attribute(:confirmed_at, DateTime.utc_now())
        |> Ash.update!()

      unconfirmed = create_user!(email: "unconfirmed.one@example.com", site_id: site.id)
      refute unconfirmed.confirmed_at

      {confirmed, unconfirmed}
    end

    defp actors_matching(recipient, site, filter) do
      {:ok, found} = feed_filtered(recipient, site, filter)
      found |> Enum.map(& &1.actor_id) |> Enum.sort()
    end

    test "a signed-in user without an admin permission matches nothing on the account's fields",
         %{user: user, site: site} do
      recipient = create_user_with_permissions!(["probe:role"], site_id: site.id)
      caused_by(user, recipient, site)

      for filter <- account_field_filters(user, site) do
        assert {:ok, []} = feed_filtered(recipient, site, filter),
               "#{inspect(filter)} told a non-admin something about another account"
      end
    end

    test "a signed-in user without an admin permission cannot tell who confirmed their address",
         %{site: site} do
      reader = create_user_with_permissions!(["probe:role"], site_id: site.id)
      {confirmed, unconfirmed} = confirmed_and_not(site)
      caused_by(confirmed, reader, site)
      caused_by(unconfirmed, reader, site)
      everyone = Enum.sort([confirmed.id, unconfirmed.id])

      for is_nil? <- [true, false] do
        assert actors_matching(reader, site, %{confirmed_at: %{is_nil: is_nil?}}) in [
                 [],
                 everyone
               ]
      end
    end

    test "an admin's same filter tells them apart", %{site: site} do
      admin = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
      {confirmed, unconfirmed} = confirmed_and_not(site)
      caused_by(confirmed, admin, site)
      caused_by(unconfirmed, admin, site)

      assert actors_matching(admin, site, %{confirmed_at: %{is_nil: true}}) == [unconfirmed.id]
      assert actors_matching(admin, site, %{confirmed_at: %{is_nil: false}}) == [confirmed.id]
    end

    test "an admin's same filters match, so the ones above are held back and not just wrong",
         %{user: user, site: site} do
      admin = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
      notification = caused_by(user, admin, site)

      for filter <- account_field_filters(user, site) do
        assert {:ok, [%{id: id}]} = feed_filtered(admin, site, filter), inspect(filter)
        assert id == notification.id
      end
    end

    test "an admin's filter on what the account holds matches", %{user: user, site: site} do
      admin = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
      notification = caused_by(user, admin, site)

      for filter <- [%{permissions: %{name: "secret:role:x"}}, %{site: %{id: site.id}}] do
        assert {:ok, [%{id: id}]} = feed_filtered(admin, site, filter), inspect(filter)
        assert id == notification.id
      end
    end

    test "the user area matches on what the account holds; another area matches nothing", %{
      user: user,
      site: site
    } do
      holds = %{permissions: %{name: "secret:role:x"}}
      users_admin = create_user_with_permissions!(["admin:dashboard:user"], site_id: site.id)

      media_admin =
        create_user_with_permissions!(["admin:dashboard:runtime:media"], site_id: site.id)

      notification = caused_by(user, users_admin, site)
      caused_by(user, media_admin, site)

      assert {:ok, [%{id: id}]} = feed_filtered(users_admin, site, holds)
      assert id == notification.id
      assert {:ok, []} = feed_filtered(media_admin, site, holds)
    end

    # Ash checks no field policy on a sort through a relationship, so the order of two rows sorted on
    # an account's address would be the order of the addresses; the relationship refuses the sort.
    test "nobody sorts on an account's fields through the relationship", %{user: user, site: site} do
      admin = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
      reader = create_user_with_permissions!(["probe:role"], site_id: site.id)

      for recipient <- [reader, admin] do
        caused_by(user, recipient, site)

        assert {:error, _refused} =
                 MishkaCmsCore.Notify.Notification
                 |> Ash.Query.for_read(:read, %{}, actor: recipient, tenant: site.id)
                 |> Ash.Query.sort_input("actor.email")
                 |> Ash.read(actor: recipient, tenant: site.id)
      end
    end

    test "a signed-in user without an admin permission matches nothing on what the account holds",
         %{user: user, site: site} do
      reader = create_user_with_permissions!(["probe:role"], site_id: site.id)
      caused_by(user, reader, site)

      for filter <- [%{permissions: %{name: "secret:role:x"}}, %{site: %{id: site.id}}] do
        refute match?({:ok, [_ | _]}, feed_filtered(reader, site, filter)),
               "#{inspect(filter)} told a non-admin what another account holds"
      end
    end
  end

  describe "what keeps the whole account" do
    test "signing in returns the account with its email", %{user: user, site: site} do
      strategy = AshAuthentication.Info.strategy!(User, :password)

      assert {:ok, signed_in} =
               AshAuthentication.Strategy.action(
                 strategy,
                 :sign_in,
                 %{"email" => to_string(user.email), "password" => @password},
                 tenant: site.id
               )

      assert to_string(signed_in.email) == "account.owner@example.com"
      assert signed_in.site_id == site.id
      assert is_binary(signed_in.__metadata__.token)
    end

    test "the actor read back from a token is whole, permissions included", %{site: site} do
      holder =
        create_user_with_permissions!(["admin:api:*"],
          email: "token.holder@example.com",
          site_id: site.id
        )

      assert {:ok, actor} =
               AshAuthentication.subject_to_user(
                 AshAuthentication.user_to_subject(holder),
                 User,
                 tenant: site.id
               )

      assert to_string(actor.email) == "token.holder@example.com"
      assert actor.site_id == site.id
      assert actor.permission_values == ["admin:api:*"]
      assert AccessPermissions.match?(actor, @api, permissions: ["admin:api:*"])
    end

    test "loading the site onto the signed-in user with no actor keeps the account", %{
      user: user,
      site: site
    } do
      {:ok, actor} =
        AshAuthentication.subject_to_user(AshAuthentication.user_to_subject(user), User,
          tenant: site.id
        )

      loaded = Ash.load!(actor, :site)

      assert loaded.site.id == site.id
      assert to_string(loaded.email) == "account.owner@example.com"
      assert loaded.site_id == site.id
    end

    test "the permission check still reads an actor whose permissions were not loaded", %{
      site: site
    } do
      admin = create_user_with_permissions!(["admin:api:*"], site_id: site.id)
      bare = Ash.get!(User, admin.id, authorize?: false, tenant: site.id)

      refute Ash.Resource.loaded?(bare, :permissions)
      assert AccessPermissions.match?(bare, @api, permissions: ["admin:api:*"])
    end
  end
end
