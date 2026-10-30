# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.CodeAccessTest do
  @moduledoc """
  Who may write code by hand, and when this deployment takes it.

  Code is Elixir (`events`, `infos`, `helpers`), hand-written HEEx (`template`,
  `root_layout_template`, an error page's status templates), and browser code (a JS hook's or a
  stylesheet's `content`). Whoever may write the record writes its code; the deployment's
  `:page_code` switch, enforced at the action boundary, stops the Elixir and the typed HEEx for
  everyone.
  """
  use MishkaCmsCore.DataCase, async: false

  require Ash.Query

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.Authoring.CodeAccess
  alias MishkaCmsCore.Runtime.Authoring.PageStarter

  @moduletag :integration
  @moduletag :capture_log

  @password "Password123!"
  @handler [%{"name" => "save", "code" => "{:noreply, socket}"}]
  @api %{shared: %{admin_surface: :api}}

  setup do
    site = create_site!(name: "code-gate", host: "code-gate.test", active: true)
    on_exit(fn -> Application.delete_env(:mishka_cms_core, :page_code) end)
    {:ok, site: site}
  end

  defp permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, %Permission{} = permission} ->
        permission

      _none ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: name, description: name}, authorize?: false)
        |> Ash.create!()
    end
  end

  defp user_with(permissions, site_id \\ nil) do
    email = "#{System.unique_integer([:positive])}@example.com"

    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> then(fn cs -> (site_id && Ash.Changeset.set_tenant(cs, site_id)) || cs end)
      |> Ash.create()

    for permission <- List.wrap(permissions) do
      UserPermission
      |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:user_id, user.id)
      |> Ash.Changeset.force_change_attribute(:permission_id, permission!(permission).id)
      |> Ash.create!(authorize?: false)
    end

    Ash.load!(user, [permissions: [:name]], authorize?: false)
  end

  defp page_create(actor, site, attrs, opts \\ []) do
    MishkaCmsCore.Runtime.Page
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{name: "p#{System.unique_integer([:positive])}", title: "Page"},
        Map.put_new(attrs, :path, "/p#{System.unique_integer([:positive])}")
      ),
      Keyword.merge([actor: actor, tenant: site.id], opts)
    )
    |> Ash.create()
  end

  defp page_update(page, actor, site, attrs, opts \\ []) do
    page
    |> Ash.Changeset.for_update(
      :update,
      attrs,
      Keyword.merge([actor: actor, tenant: site.id], opts)
    )
    |> Ash.update()
  end

  defp code_error?({:error, error}), do: Exception.message(error) =~ CodeAccess.refusal()

  defp code_error?(_result), do: false

  # WHOEVER WRITES THE RECORD WRITES ITS CODE: the page area needs no code name of its own.
  describe "Elixir through the resource" do
    test "a holder of the page area writes it", %{site: site} do
      actor = user_with("admin:dashboard:runtime:page", site.id)

      assert {:ok, page} = page_create(actor, site, %{template: "<div>x</div>", events: @handler})
      assert [%{name: "save"}] = page.events

      assert {:ok, updated} =
               page_update(page, actor, site, %{
                 events: [%{"name" => "other", "code" => "{:noreply, socket}"}]
               })

      assert [%{name: "other"}] = updated.events
    end

    test "a full dashboard admin writes it", %{site: site} do
      actor = user_with("admin:dashboard:*", site.id)

      assert {:ok, page} = page_create(actor, site, %{template: "<div>x</div>", events: @handler})
      assert [%{name: "save"}] = page.events
    end

    test "creating a page with no code and no template is not code", %{site: site} do
      actor = user_with("admin:dashboard:runtime:page", site.id)

      assert {:ok, page} = page_create(actor, site, %{})
      assert page.events in [nil, []]
      assert page.template == PageStarter.blank(:page)
    end

    test "an actor nobody established is refused, even with authorization skipped", %{site: site} do
      assert code_error?(
               MishkaCmsCore.Runtime.Page
               |> Ash.Changeset.for_create(
                 :master_create,
                 %{
                   name: "anon",
                   title: "Anon",
                   path: "/anon",
                   template: "<div>x</div>",
                   site_id: site.id,
                   helpers: helpers()
                 },
                 authorize?: false
               )
               |> Ash.create()
             )
    end

    test "the system's own template, with no actor and no authorization, is let through", %{
      site: site
    } do
      assert {:ok, page} =
               MishkaCmsCore.Runtime.Page
               |> Ash.Changeset.for_create(
                 :create,
                 %{name: "system", title: "S", path: "/system", template: "<div>seeded</div>"},
                 tenant: site.id,
                 authorize?: false
               )
               |> Ash.create()

      assert page.template == "<div>seeded</div>"
    end

    test "over the API, by the API's page area", %{site: site} do
      actor = user_with("admin:api:runtime:page", site.id)

      assert {:ok, page} =
               page_create(actor, site, %{template: "<div>x</div>", events: @handler},
                 context: @api
               )

      assert [%{name: "save"}] = page.events
    end
  end

  # A template is executable — `<%= System.cmd(…) %>` in HEEx runs — and whoever writes the record
  # types it.
  describe "a template typed by hand" do
    test "is written by a holder of the page area", %{site: site} do
      actor = user_with("admin:dashboard:runtime:page", site.id)

      assert {:ok, page} = page_create(actor, site, %{template: "<div>typed</div>"})
      assert page.template == "<div>typed</div>"

      assert {:ok, %{template: "<div>again</div>"}} =
               page_update(page, actor, site, %{template: "<div>again</div>"})
    end

    test "on a layout, a component and an error page, by their own areas", %{site: site} do
      actor =
        user_with(
          [
            "admin:dashboard:runtime:layout",
            "admin:dashboard:runtime:component",
            "admin:dashboard:runtime:error_page"
          ],
          site.id
        )

      assert {:ok, _layout} =
               MishkaCmsCore.Runtime.Layout
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "typed-layout",
                   path: "/typed-layout",
                   template: "<main>{@inner_content}</main>"
                 },
                 actor: actor,
                 tenant: site.id
               )
               |> Ash.create()

      assert {:ok, _component} =
               MishkaCmsCore.Runtime.Component
               |> Ash.Changeset.for_create(:create, %{name: "typed-c", template: "<b>typed</b>"},
                 actor: actor,
                 tenant: site.id
               )
               |> Ash.create()

      assert {:ok, _error_page} =
               [site_id: site.id]
               |> create_error_page!()
               |> Ash.Changeset.for_update(
                 :update,
                 %{error_pages: [%{"status" => 404, "template" => "<p>typed</p>"}]},
                 actor: actor,
                 tenant: site.id
               )
               |> Ash.update()
    end
  end

  describe "drafts" do
    test "a draft's template and code are written by the page area", %{site: site} do
      actor = user_with("admin:dashboard:runtime:page", site.id)

      assert {:ok, draft} =
               draft_create(actor, site, %{template: "<div>typed</div>", events: @handler})

      assert [%{"name" => "save"}] = draft.events
    end

    # Publishing copies what the draft holds; the check ran when the draft was written.
    test "publishing a draft onto a new page copies its template and its Elixir", %{site: site} do
      actor = user_with("admin:dashboard:runtime:page", site.id)

      {:ok, draft} =
        draft_create(actor, site, %{template: "<div>drafted</div>", events: @handler})

      assert {:ok, _published} =
               draft
               |> Ash.Changeset.for_update(:publish, %{}, actor: actor, tenant: site.id)
               |> Ash.update()

      page =
        MishkaCmsCore.Runtime.Page
        |> Ash.Query.filter(path == ^draft.path)
        |> Ash.read_one!(tenant: site.id, authorize?: false)

      assert page.template == "<div>drafted</div>"
      assert [%{name: "save"}] = page.events
    end

    test "publishing needs the page area", %{site: site} do
      writer = user_with("admin:dashboard:runtime:page", site.id)
      {:ok, draft} = draft_create(writer, site, %{template: "<div>x</div>"})

      assert {:error, %Ash.Error.Forbidden{}} =
               draft
               |> Ash.Changeset.for_update(:publish, %{},
                 actor: user_with("admin:dashboard:runtime:layout", site.id),
                 tenant: site.id
               )
               |> Ash.update()
    end
  end

  # The server does not run a hook's JavaScript or a sheet's CSS, so neither the code name nor the
  # deployment switch has a say: the record's area writes its content.
  describe "browser code" do
    test "a JS hook's content is written by the js_hook area", %{site: site} do
      area = user_with("admin:dashboard:runtime:js_hook", site.id)

      assert {:ok, %{content: "console.log(1)"}} = hook_create(area, site, "console.log(1)")
    end

    test "a stylesheet's content is written by the stylesheet area", %{site: site} do
      area = user_with("admin:dashboard:runtime:stylesheet", site.id)

      assert {:ok, %{content: ".a { color: red; }"}} =
               sheet_create(area, site, ".a { color: red; }")
    end

    test "the deployment switch does not stop it", %{site: site} do
      Application.put_env(:mishka_cms_core, :page_code, :off)
      area = user_with("admin:dashboard:runtime:js_hook", site.id)

      assert {:ok, _hook} = hook_create(area, site, "console.log(2)")
    end
  end

  # A deployment that does not want author-written server code turns it off in ONE place.
  describe "the deployment switch" do
    setup do
      Application.put_env(:mishka_cms_core, :page_code, :off)
      :ok
    end

    test "off refuses even a super admin's Elixir", %{site: site} do
      refute CodeAccess.enabled?()

      assert {:error, error} = page_create(user_with("*"), site, %{events: @handler})
      assert Exception.message(error) =~ "turned off on this deployment"
    end

    test "off refuses one handler replacing another", %{site: site} do
      page = create_page!(site_id: site.id, events: @handler)

      assert {:error, error} =
               page_update(page, user_with("admin:dashboard:runtime:page", site.id), site, %{
                 events: [%{"name" => "other", "code" => "{:noreply, socket}"}]
               })

      assert Exception.message(error) =~ "turned off on this deployment"
    end

    test "off refuses a template typed by hand, on every document", %{site: site} do
      actor = user_with("*")

      for {resource, attrs} <- [
            {MishkaCmsCore.Runtime.Page,
             %{name: "t", title: "T", path: "/t", template: "<div>typed</div>"}},
            {MishkaCmsCore.Runtime.Layout,
             %{name: "tl", path: "/tl", template: "<main>{@inner_content}</main>"}},
            {MishkaCmsCore.Runtime.Component, %{name: "tc", template: "<b>typed</b>"}}
          ] do
        assert {:error, error} =
                 resource
                 |> Ash.Changeset.for_create(:create, attrs, actor: actor, tenant: site.id)
                 |> Ash.create()

        assert Exception.message(error) =~ "turned off on this deployment", inspect(resource)
      end

      assert {:error, error} =
               [site_id: site.id]
               |> create_error_page!()
               |> Ash.Changeset.for_update(
                 :update,
                 %{error_pages: [%{"status" => 404, "template" => "<p>typed</p>"}]},
                 actor: actor,
                 tenant: site.id
               )
               |> Ash.update()

      assert Exception.message(error) =~ "turned off on this deployment"
    end

    test "off refuses a component's and a layout's helpers", %{site: site} do
      actor = user_with("*")

      for {resource, attrs} <- [
            {MishkaCmsCore.Runtime.Component, %{name: "coded-component"}},
            {MishkaCmsCore.Runtime.Layout, %{name: "coded-layout", path: "/coded-layout"}}
          ] do
        assert {:error, error} =
                 resource
                 |> Ash.Changeset.for_create(:create, Map.put(attrs, :helpers, helpers()),
                   actor: actor,
                   tenant: site.id
                 )
                 |> Ash.create()

        assert Exception.message(error) =~ "turned off on this deployment", inspect(resource)
      end
    end

    test "off lets a copy write its source's template and refuses its Elixir", %{site: site} do
      actor = user_with("admin:dashboard:runtime:page", site.id)

      assert {:ok, _copied} =
               page_create(actor, site, %{template: "<div>copied</div>"},
                 context: %{page_code: :copy}
               )

      assert code_error?(
               page_create(actor, site, %{template: "<div>x</div>", helpers: helpers()},
                 context: %{page_code: :copy}
               )
             )
    end

    test "off lets the builder's fork carry its source's code", %{site: site} do
      actor = user_with("admin:dashboard:runtime:page", site.id)

      assert {:ok, draft} =
               draft_create(actor, site, %{template: "<div>built</div>", events: @handler},
                 context: %{page_code: :fork}
               )

      assert [%{"name" => "save"}] = draft.events
      assert code_error?(draft_create(actor, site, %{template: "<div>typed</div>"}))
    end

    # A write with no actor is the system's own: its template was typed by nobody.
    test "off lets the system's own template through and refuses its Elixir", %{site: site} do
      seeded = fn attrs ->
        n = System.unique_integer([:positive])

        MishkaCmsCore.Runtime.Page
        |> Ash.Changeset.for_create(
          :create,
          Map.merge(%{name: "s#{n}", title: "S", path: "/s#{n}"}, attrs),
          tenant: site.id,
          authorize?: false
        )
        |> Ash.create()
      end

      assert {:ok, %{template: "<div>seeded</div>"}} = seeded.(%{template: "<div>seeded</div>"})
      assert code_error?(seeded.(%{template: "<div>x</div>", helpers: helpers()}))
    end

    test "off lets a package install what it ships", %{site: site} do
      assert {:ok, page} =
               page_create(user_with("*"), site, %{template: "<div>x</div>", events: @handler},
                 context: %{page_code: :package}
               )

      assert [%{name: "save"}] = page.events
    end

    test "off still publishes a draft written before it was turned off", %{site: site} do
      Application.delete_env(:mishka_cms_core, :page_code)
      actor = user_with("admin:dashboard:runtime:page", site.id)

      {:ok, draft} =
        draft_create(actor, site, %{template: "<div>drafted</div>", events: @handler})

      Application.put_env(:mishka_cms_core, :page_code, :off)

      assert {:ok, _published} =
               draft
               |> Ash.Changeset.for_update(:publish, %{}, actor: actor, tenant: site.id)
               |> Ash.update()
    end

    # It stops code being WRITTEN; the pages already serving keep their code.
    test "off still lets a page that already holds code be edited elsewhere", %{site: site} do
      page = create_page!(site_id: site.id, events: @handler)

      assert {:ok, updated} = page_update(page, user_with("*"), site, %{title: "Edited"})
      assert updated.events == page.events, "the code it already had is untouched"
    end

    test "on is the default" do
      Application.delete_env(:mishka_cms_core, :page_code)
      assert CodeAccess.enabled?()
    end
  end

  defp helpers, do: [%{"name" => "shout", "args" => "text", "code" => "String.upcase(text)"}]

  defp draft_create(actor, site, attrs, opts \\ []) do
    n = System.unique_integer([:positive])

    MishkaCmsCore.Runtime.PageDraft
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{name: "d#{n}", title: "Draft", path: "/d#{n}"}, attrs),
      Keyword.merge([actor: actor, tenant: site.id], opts)
    )
    |> Ash.create()
  end

  defp hook_create(actor, site, content) do
    MishkaCmsCore.Runtime.JsHook
    |> Ash.Changeset.for_create(
      :create,
      %{name: "h#{System.unique_integer([:positive])}", content: content, format: :js},
      actor: actor,
      tenant: site.id
    )
    |> Ash.create()
  end

  defp sheet_create(actor, site, content) do
    MishkaCmsCore.Runtime.Stylesheet
    |> Ash.Changeset.for_create(
      :create,
      %{name: "s#{System.unique_integer([:positive])}", content: content, format: :css},
      actor: actor,
      tenant: site.id
    )
    |> Ash.create()
  end
end
