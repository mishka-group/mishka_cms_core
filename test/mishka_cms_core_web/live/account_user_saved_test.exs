defmodule MishkaCmsCoreWeb.Test.AccountUserSavedTest do
  @moduledoc """
  Adding and editing a user from the Users page, and what the page says once its form has saved: a
  new user is created, an existing one updated.

  A master adds a master by leaving Site empty. A site's admin adds a user of its own site. Either
  way the user signs in with the password typed into the form.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  require Ash.Query

  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Runtime.States.SiteState

  @users "/admin/dashboard/account/users"

  setup %{conn: conn} do
    SiteState.clear()

    master_site = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    site_a = create_site!(name: "site-a", host: "site-a.test", active: true)

    for site <- [master_site, site_a] do
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active,
        master: site.master
      })
    end

    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    {:ok, conn: conn, site_a: site_a}
  end

  defp open_users(conn, host, user, session \\ %{}) do
    {:ok, view, _html} =
      conn
      |> Map.put(:host, host)
      |> Map.update!(:req_headers, &[{"host", host} | List.keydelete(&1, "host", 0)])
      |> Plug.Test.init_test_session(session)
      |> Plug.Conn.put_session(:master_mode, true)
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
      |> live(@users)

    view
  end

  defp new_password, do: "Pw-#{System.unique_integer([:positive])}-Aa9!"

  defp add_user(view, email, password) do
    view |> element("#add-user") |> render_click()
    submit_user_form(view, %{"email" => email}, password)
  end

  defp submit_user_form(view, fields, password) do
    view
    |> form("#user_form-form", %{
      "form" => Map.merge(fields, %{"password" => password, "password_confirmation" => password})
    })
    |> render_submit()

    render(view)
  end

  defp signs_in_with?(%User{hashed_password: hash}, password) when is_binary(hash),
    do: Bcrypt.verify_pass(password, hash)

  defp signs_in_with?(_user, _password), do: false

  defp user_by_email(email) do
    User
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one!(action: :master_read, authorize?: false)
  end

  describe "+ Add User" do
    test "a master with Site left empty adds a master", %{conn: conn} do
      view = open_users(conn, "localhost", create_user_with_permissions!(["*"]))

      password = new_password()
      html = add_user(view, "new.master@example.test", password)

      assert html =~ "User created successfully"
      assert %User{site_id: nil} = user = user_by_email("new.master@example.test")
      assert signs_in_with?(user, password)
    end

    test "a site's admin adds a user of its own site", %{conn: conn, site_a: site_a} do
      admin = create_user_with_permissions!(["*"], site_id: site_a.id)
      view = open_users(conn, "site-a.test", admin)

      password = new_password()
      html = add_user(view, "new.writer@site-a.test", password)

      assert html =~ "User created successfully"
      assert %User{site_id: site_id} = user = user_by_email("new.writer@site-a.test")
      assert site_id == site_a.id
      assert signs_in_with?(user, password)
    end

    test "a site's admin changes a user's password from the edit form", %{
      conn: conn,
      site_a: site_a
    } do
      admin = create_user_with_permissions!(["*"], site_id: site_a.id)
      writer = create_user!(site_id: site_a.id)
      view = open_users(conn, "site-a.test", admin)

      send(view.pid, {:row_action, "edit_user_modal", %{"id" => writer.id}})
      render_async(view)

      password = new_password()
      html = submit_user_form(view, %{"email" => to_string(writer.email)}, password)

      assert html =~ "User updated successfully"
      assert signs_in_with?(user_by_email(to_string(writer.email)), password)
    end

    test "opens the form empty after a user was edited", %{conn: conn, site_a: site_a} do
      view = open_users(conn, "localhost", create_user_with_permissions!(["*"]))
      other = create_user!(site_id: site_a.id)

      send(view.pid, {:row_action, "edit_user_modal", %{"id" => other.id}})
      render_async(view)
      view |> element("#user-details-modal [phx-click*='close_user_modal']") |> render_click()

      view |> element("#add-user") |> render_click()

      assert has_element?(view, "#user_form-form button[type=submit]", "Create")
      refute has_element?(view, "#user_form-form input[value='#{other.email}']")
    end
  end

  describe "the page's language" do
    test "an admin who reads the dashboard in Persian reads the page in Persian", %{
      conn: conn,
      site_a: site_a
    } do
      view =
        open_users(conn, "localhost", create_user_with_permissions!(["*"]), %{
          "admin_language" => "fa"
        })

      send(view.pid, {:form_saved, :create, create_user!(site_id: site_a.id)})

      assert render(view) =~ "[fa] User created successfully"
    end

    test "an admin who chose no language reads it in English, whatever the site speaks", %{
      conn: conn,
      site_a: site_a
    } do
      view =
        open_users(conn, "localhost", create_user_with_permissions!(["*"]), %{
          "site_language" => "fa"
        })

      send(view.pid, {:form_saved, :create, create_user!(site_id: site_a.id)})

      assert render(view) =~ "User created successfully"
    end
  end

  describe "the flash once the form has saved" do
    setup %{conn: conn, site_a: site_a} do
      view = open_users(conn, "localhost", create_user_with_permissions!(["*"]))
      {:ok, view: view, user: create_user!(site_id: site_a.id)}
    end

    test "a created user is said to be created", %{view: view, user: user} do
      send(view.pid, {:form_saved, :create, user})

      assert render(view) =~ "User created successfully"
      refute render(view) =~ "User updated successfully"
    end

    test "an updated user is said to be updated", %{view: view, user: user} do
      send(view.pid, {:form_saved, :update, user})

      assert render(view) =~ "User updated successfully"
      refute render(view) =~ "User created successfully"
    end
  end
end
