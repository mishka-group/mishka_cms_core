# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.AdminIdentityFallbacksTest do
  @moduledoc """
  What the admin pages do for a viewer who is not a user.

  A master is a user whose `site_id` is nil — never the absence of a user. The router keeps every one
  of these pages behind a sign-in, so no request reaches them without a user; each page's own
  callbacks still answer a missing user with nothing, not with the master's reach. They are driven
  here directly, with a socket that carries no user, because no route can hand them one.
  """
  use MishkaCmsCore.ConnCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCoreWeb.Live.Admin.Builder.BuilderLive
  alias MishkaCmsCoreWeb.Live.Admin.Dashboard.Home.Index, as: Home

  defp socket(user),
    do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user: user, flash: %{}}}

  describe "the builder" do
    test "opens no new error page for a viewer who is not a user" do
      for nobody <- [nil, %{id: Ecto.UUID.generate()}] do
        assert {:ok, %Phoenix.LiveView.Socket{redirected: {:redirect, %{to: to}}}} =
                 BuilderLive.mount(%{"section" => "error-page"}, %{}, socket(nobody))

        assert to =~ "/admin/dashboard"
      end
    end

    test "opens no existing document for a viewer who is not a user" do
      site = create_site!()
      page = create_page!(site_id: site.id)

      assert {:ok, %Phoenix.LiveView.Socket{redirected: {:redirect, _to}}} =
               BuilderLive.mount(
                 %{"section" => "page", "id" => page.id, "site_id" => site.id},
                 %{},
                 socket(nil)
               )
    end
  end

  describe "the dashboard greeting" do
    test "calls only a site_id-nil user the master" do
      assert Home.greeting(%{site_id: nil}) =~ "master"
      assert Home.greeting(%{site_id: Ecto.UUID.generate()}) =~ "admin"

      refute Home.greeting(nil) =~ "master"
      refute Home.greeting(%{email: "someone@example.com"}) =~ "master"
    end
  end
end
