# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.StatefulPlacementTest do
  @moduledoc """
  Where a live component may go, and the three places it may not.

  A stateful component compiles to a `Phoenix.LiveComponent`, and calling one produces a
  `%Phoenix.LiveView.Component{}` — a token only a LiveView's diff turns into HTML. Three of the four
  things this runtime compiles are rendered where no such diff runs, and each failure is silent
  rather than loud:

    * an ERROR PAGE is served by a controller (`ErrorHTML.render/2` calls
      `page_module.render(conn, status)`), the token raises inside that function's own rescue, and
      the site's custom error page is replaced by Phoenix's plain default for every visitor
    * a LAYOUT wraps error pages, so it inherits it
    * ANOTHER COMPONENT's template is drawn by the canvas through `contain/3`, and the token blows up
      the PARENT's containment — a red chip on a component the author did not touch

  A page is a LiveView end to end, which is why a page is the one surface that may hold one.
  """
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Runtime.{Component, ErrorPage, Layout, Page}

  require Ash.Query

  @moduletag :integration

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  defp live_component!(site, name \\ "live-widget") do
    create_component!(
      name: name,
      site_id: site.id,
      stateful: true,
      template: ~s(<div id={@id} {@rest}>live</div>),
      attrs: [%{"name" => "rest", "type" => "global", "opts" => %{}}]
    )
  end

  defp calls(name),
    do: ~s(<div><.component component_name="#{name}" site="Global" id="w1" /></div>)

  defp renders(name),
    do: %{name: "badge", args: "assigns", code: ~s(~H"""\n#{calls(name)}\n""")}

  # A SERVER-RENDERED ROOT LAYOUT, shaped like the seeded one: EEx inside an attribute, which HEEx
  # refuses and the error compiler's classic engine takes.
  defp root_layout(body),
    do:
      ~s|<html><head><meta name="csrf-token" content="<%= token() %>" /></head>| <>
        ~s(<body>#{body}<%= @inner_content %></body></html>)

  defp make_live(component, tenant) do
    component
    |> Ash.Changeset.for_update(:update, %{stateful: true}, tenant: tenant, authorize?: false)
    |> Ash.update(authorize?: false)
  end

  defp refused_on?(%Ash.Error.Invalid{errors: errors}, field),
    do: Enum.any?(errors, &match?(%Ash.Error.Changes.InvalidAttribute{field: ^field}, &1))

  defp archive!(record, tenant) do
    record
    |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: tenant, authorize?: false)
    |> Ash.destroy!(return_destroyed?: true)
  end

  describe "a page" do
    test "may hold one", %{} do
      site = create_site!()
      _live = live_component!(site)

      assert {:ok, page} =
               Page
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "holds-live",
                   title: "Holds Live",
                   path: "/holds-live",
                   template: calls("live-widget")
                 },
                 tenant: site.id
               )
               |> Ash.create(authorize?: false)

      assert page.template =~ "live-widget"
    end
  end

  describe "a layout, an error page and another component" do
    test "a layout is refused, and told why" do
      site = create_site!()
      _live = live_component!(site)

      assert {:error, error} =
               Layout
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "live-layout",
                   path: "/live-layout",
                   template: ~s(<div>#{calls("live-widget")}<%= @inner_content %></div>)
                 },
                 tenant: site.id
               )
               |> Ash.create(authorize?: false)

      message = Exception.message(error)
      assert message =~ "live-widget"
      assert message =~ "only runs on a page"
    end

    test "an error page is refused" do
      site = create_site!()
      _live = live_component!(site)

      assert {:error, error} =
               ErrorPage
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "live-errors",
                   error_pages: [%{status: 404, template: calls("live-widget")}]
                 },
                 tenant: site.id
               )
               |> Ash.create(authorize?: false)

      assert Exception.message(error) =~ "live-widget"
    end

    test "and a component that reaches for another one is refused" do
      site = create_site!()
      _live = live_component!(site)

      assert {:error, error} =
               Component
               |> Ash.Changeset.for_create(
                 :create,
                 %{name: "wraps-live", template: calls("live-widget")},
                 tenant: site.id
               )
               |> Ash.create(authorize?: false)

      assert Exception.message(error) =~ "live-widget"
    end

    # THE ROOT LAYOUT IS CLASSIC EEX, so the way a live component reaches it is an expression. The
    # seeded shape — EEx inside an attribute — is one the HEEx parser refuses outright, which is why
    # it is not what reads this field.
    test "an error page's root layout is refused, read as the EEx it is" do
      site = create_site!()
      _live = live_component!(site)

      assert {:error, error} =
               ErrorPage
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "live-root",
                   root_layout_template:
                     root_layout(
                       ~s|<%= component(%{component_name: "live-widget", site: "Global", id: "w1"}) %>|
                     ),
                   error_pages: [%{status: 404, template: "<p>gone</p>"}]
                 },
                 tenant: site.id
               )
               |> Ash.create(authorize?: false)

      message = Exception.message(error)
      assert message =~ "The root layout: "
      assert message =~ "live-widget"
    end

    test "an error page's per-status layout is refused" do
      site = create_site!()
      _live = live_component!(site)

      assert {:error, error} =
               ErrorPage
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "live-status-layout",
                   error_pages: [
                     %{
                       status: 404,
                       template: "<p>gone</p>",
                       layout: %{template: ~s(#{calls("live-widget")}<%= @inner_content %>)}
                     }
                   ]
                 },
                 tenant: site.id
               )
               |> Ash.create(authorize?: false)

      message = Exception.message(error)
      assert message =~ "The 404 layout: "
      assert message =~ "live-widget"
    end

    test "a helper whose ~H renders one is refused" do
      site = create_site!()
      _live = live_component!(site)

      assert {:error, error} =
               Layout
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "helper-layout",
                   path: "/helper-layout",
                   template: "<div><%= @inner_content %></div>",
                   helpers: [renders("live-widget")]
                 },
                 tenant: site.id,
                 context: %{page_code: :package}
               )
               |> Ash.create(authorize?: false)

      message = Exception.message(error)
      assert message =~ "The badge helper: "
      assert message =~ "live-widget"
    end

    test "a component's clause is refused" do
      site = create_site!()
      _live = live_component!(site)

      assert {:error, error} =
               Component
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "clause-wraps-live",
                   template: "<div>base</div>",
                   extra: %{
                     "clauses" => [%{"match" => "assigns", "template" => calls("live-widget")}]
                   }
                 },
                 tenant: site.id
               )
               |> Ash.create(authorize?: false)

      message = Exception.message(error)
      assert message =~ "Clause 1: "
      assert message =~ "live-widget"
    end

    # THE ELIXIR A COMPONENT MODULE IS BUILT FROM. A body, a prelude and a clause's body are all
    # spliced into the module that imports the live `component/1`, and each reaches it in the ways a
    # hand-written call can: by its module, by name and site, or through a `~H` of its own.
    test "a component's body, prelude and clause body are refused" do
      site = create_site!()
      _live = live_component!(site)

      for {extra_attrs, label} <- [
            {%{
               body:
                 ~s|_badge = MishkaCmsCore.Runtime.LiveViewHelpers.component(%{component_name: "live-widget", site: "Global", id: "w1"})|
             }, "The body: "},
            {%{
               extra: %{
                 "prelude" =>
                   ~s|defp badge(assigns), do: ~H"#{String.replace(calls("live-widget"), "\"", "'")}"|
               }
             }, "The prelude: "},
            {%{
               extra: %{
                 "clauses" => [
                   %{
                     "match" => "assigns",
                     "body" => ~s|_badge = component("live-widget", "Global")|,
                     "template" => "<div>base</div>"
                   }
                 ]
               }
             }, "Clause 1: "}
          ] do
        assert {:error, error} =
                 Component
                 |> Ash.Changeset.for_create(
                   :create,
                   Map.merge(
                     %{name: "code-wraps-live", template: "<div>base</div>"},
                     extra_attrs
                   ),
                   tenant: site.id,
                   context: %{page_code: :package}
                 )
                 |> Ash.create(authorize?: false)

        message = Exception.message(error)
        assert message =~ label <> "A component cannot hold live-widget"
      end
    end

    test "and the call written out as an expression is refused like the tag" do
      site = create_site!()
      _live = live_component!(site)

      assert {:error, error} =
               Layout
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "expression-layout",
                   path: "/expression-layout",
                   template:
                     ~s|<div>{component(%{component_name: "live-widget", site: "Global", id: "w1"})}<%= @inner_content %></div>|
                 },
                 tenant: site.id
               )
               |> Ash.create(authorize?: false)

      assert Exception.message(error) =~ "live-widget"
    end
  end

  # THE OTHER END. Every test above refuses markup that names a component already live; these refuse
  # the component that becomes live while something already names it.
  describe "a component that becomes live" do
    test "is refused while a layout uses it, and the layout is named" do
      site = create_site!()
      used = create_component!(name: "used-widget", site_id: site.id)

      layout =
        create_layout!(
          name: "uses-widget",
          site_id: site.id,
          template: ~s(<div>#{calls("used-widget")}<%= @inner_content %></div>)
        )

      assert {:error, error} = make_live(used, site.id)

      message = Exception.message(error)
      assert message =~ "used-widget is used by layout '#{layout.name}'"
      assert message =~ "only runs on a page"
    end

    test "is refused while an error page uses it, and the error page is named" do
      site = create_site!()
      used = create_component!(name: "used-widget", site_id: site.id)

      error_page =
        create_error_page!(
          name: "uses-widget-errors",
          site_id: site.id,
          error_pages: [%{status: 404, template: calls("used-widget")}]
        )

      assert {:error, error} = make_live(used, site.id)

      assert Exception.message(error) =~
               "used-widget is used by error page '#{error_page.name}'"
    end

    test "is refused while another component uses it, and the component is named" do
      site = create_site!()
      used = create_component!(name: "used-widget", site_id: site.id)

      parent =
        create_component!(name: "wraps-used", site_id: site.id, helpers: [renders("used-widget")])

      assert {:error, error} = make_live(used, site.id)

      assert Exception.message(error) =~ "used-widget is used by component '#{parent.name}'"
    end

    # A root layout is a text column, a clause lives in a map and a per-status template in an array of
    # maps; the read has to find the name in all three before the parse can confirm it.
    test "wherever the document keeps the call" do
      site = create_site!()
      used = create_component!(name: "used-widget", site_id: site.id)

      rooted =
        create_error_page!(
          name: "rooted-errors",
          site_id: site.id,
          root_layout_template:
            root_layout(
              ~s|<%= component(%{component_name: "used-widget", site: "Global", id: "r1"}) %>|
            )
        )

      clausal =
        create_component!(
          name: "clausal",
          site_id: site.id,
          extra: %{"clauses" => [%{"match" => "assigns", "template" => calls("used-widget")}]}
        )

      assert {:error, error} = make_live(used, site.id)

      message = Exception.message(error)
      assert message =~ "error page '#{rooted.name}'"
      assert message =~ "component '#{clausal.name}'"
    end

    test "names three of the documents that use it and counts the rest" do
      site = create_site!()
      used = create_component!(name: "used-widget", site_id: site.id)

      for index <- 1..4 do
        create_layout!(
          name: "uses-widget-#{index}",
          site_id: site.id,
          template: ~s(<div>#{calls("used-widget")}<%= @inner_content %></div>)
        )
      end

      assert {:error, error} = make_live(used, site.id)

      assert Exception.message(error) =~ " and 1 more — a live component only runs on a page."
    end

    test "is refused when it is created live under a name something already uses" do
      site = create_site!()

      create_layout!(
        name: "waits-for-widget",
        site_id: site.id,
        template: ~s(<div>#{calls("future-widget")}<%= @inner_content %></div>)
      )

      assert {:error, error} =
               Component
               |> Ash.Changeset.for_create(
                 :create,
                 %{name: "future-widget", template: "<div>x</div>", stateful: true},
                 tenant: site.id
               )
               |> Ash.create(authorize?: false)

      assert Exception.message(error) =~ "future-widget is used by layout"
    end

    # THE NAME IT WILL BE STORED UNDER. Slugging runs after every validation, so the rename arrives
    # as typed; markup only ever names the slug.
    test "is refused when it is renamed, while live, to a name something already uses" do
      site = create_site!()

      live =
        create_component!(
          name: "renamed-live",
          site_id: site.id,
          stateful: true,
          template: ~s(<div id={@id} {@rest}>live</div>),
          attrs: [%{"name" => "rest", "type" => "global", "opts" => %{}}]
        )

      create_layout!(
        name: "waits-for-wanted",
        site_id: site.id,
        template: ~s(<div>#{calls("wanted-widget")}<%= @inner_content %></div>)
      )

      assert {:error, error} =
               live
               |> Ash.Changeset.for_update(:update, %{name: "Wanted Widget"}, tenant: site.id)
               |> Ash.update(authorize?: false)

      assert Exception.message(error) =~ "wanted-widget is used by layout"
      assert refused_on?(error, :name), "the refusal belongs on the field the author changed"
    end

    # A MOVE CHANGES WHICH `site=` REACHES IT. Site B's layout asks for the GLOBAL movable-widget,
    # which site A's is not — until it is moved to global.
    test "is refused when it is moved, while live, to where something already uses it" do
      site = create_site!()
      other = create_site!()
      movable = create_component!(name: "movable-widget", site_id: site.id)

      layout =
        create_layout!(
          name: "asks-global",
          site_id: other.id,
          template: ~s(<div>#{calls("movable-widget")}<%= @inner_content %></div>)
        )

      assert {:ok, movable} = make_live(movable, site.id)

      assert {:error, error} =
               movable
               |> Ash.Changeset.for_update(:master_update, %{site_id: nil}, authorize?: false)
               |> Ash.update(authorize?: false)

      assert Exception.message(error) =~ "movable-widget is used by layout '#{layout.name}'"
      assert refused_on?(error, :site_id)
    end

    test "reads the global documents as well as its own site's" do
      site = create_site!()
      used = create_component!(name: "used-widget", site_id: site.id)

      global =
        create_layout!(
          name: "global-uses-widget",
          template: ~s(<div>#{calls("used-widget")}<%= @inner_content %></div>)
        )

      assert is_nil(global.site_id)
      assert {:error, error} = make_live(used, site.id)

      assert Exception.message(error) =~ "used-widget is used by layout '#{global.name}'"
    end

    # A TENANT'S CREATE HAS NO `site_id` YET when this reads — the tenant is stamped on after — so
    # the tenant is what bounds the read, not "every site".
    test "created live under a tenant, is not stopped by another site's documents" do
      site = create_site!()
      other = create_site!()

      create_layout!(
        name: "elsewhere-future",
        site_id: other.id,
        template: ~s(<div>#{calls("future-widget")}<%= @inner_content %></div>)
      )

      assert {:ok, %{stateful: true}} =
               Component
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "future-widget",
                   stateful: true,
                   template: ~s(<div id={@id} {@rest}>live</div>),
                   attrs: [%{"name" => "rest", "type" => "global", "opts" => %{}}]
                 },
                 tenant: site.id
               )
               |> Ash.create(authorize?: false)
    end

    # AN ARCHIVED DOCUMENT COMES BACK WITHOUT A WRITE OF ITS MARKUP, so this is the last moment
    # anything reads it. The lists an author looks in hide archived rows, so the refusal says which.
    test "is refused while an archived document uses it, and says it is archived" do
      site = create_site!()
      used = create_component!(name: "used-widget", site_id: site.id)

      layout =
        create_layout!(
          name: "shelved-layout",
          site_id: site.id,
          template: ~s(<div>#{calls("used-widget")}<%= @inner_content %></div>)
        )

      archive!(layout, site.id)

      assert {:error, error} = make_live(used, site.id)

      assert Exception.message(error) =~
               "used-widget is used by layout '#{layout.name}' (archived)"
    end

    # AN ARCHIVED COMPONENT IS NOT ONE A NAME RESOLVES TO, so markup may name it — and unarchiving it
    # is the write that brings it back within reach.
    test "is refused when it is unarchived, while live, and something uses it" do
      site = create_site!()
      shelved = site |> live_component!("shelved-widget") |> archive!(site.id)

      layout =
        create_layout!(
          name: "names-shelved",
          site_id: site.id,
          template: ~s(<div>#{calls("shelved-widget")}<%= @inner_content %></div>)
        )

      assert {:error, error} =
               shelved
               |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
               |> Ash.update(authorize?: false)

      assert Exception.message(error) =~ "shelved-widget is used by layout '#{layout.name}'"
      assert refused_on?(error, :archived_at)
    end

    # THE TABLE'S BULK RESTORE TRIES THE ATOMIC STRATEGY FIRST, and an atomic write skips every
    # validation whose `atomic/3` answers `:ok`.
    test "and when the table unarchives it in bulk" do
      site = create_site!()
      shelved = site |> live_component!("shelved-widget") |> archive!(site.id)

      create_layout!(
        name: "names-shelved",
        site_id: site.id,
        template: ~s(<div>#{calls("shelved-widget")}<%= @inner_content %></div>)
      )

      result =
        Component
        |> Ash.Query.for_read(:archived, %{}, tenant: site.id, authorize?: false)
        |> Ash.Query.filter(id == ^shelved.id)
        |> Ash.bulk_update(:unarchive, %{},
          tenant: site.id,
          authorize?: false,
          strategy: [:atomic, :atomic_batches, :stream],
          allow_stream_with: :full_read,
          return_errors?: true
        )

      assert result.status == :error
      assert Enum.any?(result.errors, &(Exception.message(&1) =~ "shelved-widget is used by"))
    end

    test "is allowed when nothing uses it" do
      site = create_site!()
      unused = create_component!(name: "unused-widget", site_id: site.id)

      assert {:ok, %{stateful: true}} = make_live(unused, site.id)
    end

    # THE PARSE DECIDES, not the filter that narrowed the read. The name as text, in a comment and as
    # the front of a longer name all reach the parse, and none of them calls the component.
    test "a mention that is not a call is not a use" do
      site = create_site!()
      used = create_component!(name: "used-widget", site_id: site.id)

      create_layout!(
        name: "mentions-widget",
        site_id: site.id,
        template:
          ~s(<div><p>used-widget</p><%!-- used-widget --%>#{calls("used-widget-group")}<%= @inner_content %></div>)
      )

      assert {:ok, %{stateful: true}} = make_live(used, site.id)
    end

    # A SITE'S COMPONENT IS REACHED FROM ITS OWN SITE AND FROM THE GLOBAL DOCUMENTS; a global one from
    # every site.
    test "another site's documents do not stop a site's component, and do stop a global one" do
      site = create_site!()
      other = create_site!()
      scoped = create_component!(name: "scoped-widget", site_id: site.id)
      global = create_component!(name: "global-widget")

      for name <- ["scoped-widget", "global-widget"] do
        create_layout!(
          name: "elsewhere-#{name}",
          site_id: other.id,
          template: ~s(<div>#{calls(name)}<%= @inner_content %></div>)
        )
      end

      assert {:ok, %{stateful: true}} = make_live(scoped, site.id)
      assert {:error, error} = make_live(global, nil)

      assert Exception.message(error) =~
               "global-widget is used by layout 'elsewhere-global-widget'"
    end

    # A LIVE COMPONENT THAT IS ALREADY NAMED SOMEWHERE STAYS EDITABLE. The history is written to the
    # row directly, because it is one the rule no longer lets anybody make — and a form that submits
    # every field sends `stateful: true` again on each save.
    test "a write that does not make it live does not look" do
      site = create_site!()
      settled = create_component!(name: "settled-live", site_id: site.id)

      create_layout!(
        name: "names-settled",
        site_id: site.id,
        template: ~s(<div>#{calls("settled-live")}<%= @inner_content %></div>)
      )

      becomes_live!(settled)

      assert {:ok, _described} =
               Component
               |> Ash.get!(settled.id, action: :read_any, authorize?: false)
               |> Ash.Changeset.for_update(
                 :update,
                 %{description: "still editable", stateful: true},
                 tenant: site.id
               )
               |> Ash.update(authorize?: false)
    end
  end

  # A RESTORE WRITES THE MARKUP AND THE LIVE FLAG a snapshot held, which is the same write the form
  # makes — so it meets the same rule, from either end.
  describe "a version restore" do
    test "that makes a component live again while something uses it is refused" do
      site = create_site!()

      restorable =
        create_component!(
          name: "restorable-widget",
          site_id: site.id,
          template: ~s(<div id={@id} {@rest}>live</div>),
          attrs: [%{"name" => "rest", "type" => "global", "opts" => %{}}]
        )

      {:ok, restorable} = make_live(restorable, site.id)

      {:ok, restorable} =
        restorable
        |> Ash.Changeset.for_update(:update, %{stateful: false}, tenant: site.id)
        |> Ash.update(authorize?: false)

      layout =
        create_layout!(
          name: "uses-restorable",
          site_id: site.id,
          template: ~s(<div>#{calls("restorable-widget")}<%= @inner_content %></div>)
        )

      live_version = version_holding(restorable, &(&1["stateful"] == true))

      assert {:error, error} = restore(restorable, live_version, site.id)

      assert Exception.message(error) =~
               "restorable-widget is used by layout '#{layout.name}'"
    end

    test "of a layout to markup that names a component live since is refused" do
      site = create_site!()
      later = create_component!(name: "later-live", site_id: site.id)

      layout =
        create_layout!(
          name: "named-later",
          site_id: site.id,
          template: ~s(<div>#{calls("later-live")}<%= @inner_content %></div>)
        )

      {:ok, layout} =
        layout
        |> Ash.Changeset.for_update(:update, %{template: "<div><%= @inner_content %></div>"},
          tenant: site.id
        )
        |> Ash.update(authorize?: false)

      assert {:ok, _live} = make_live(later, site.id)

      naming = version_holding(layout, &(&1["template"] =~ "later-live"))

      assert {:error, error} = restore(layout, naming, site.id)
      assert Exception.message(error) =~ "A layout cannot hold later-live"
    end

    test "of an error page to markup that names a component live since is refused" do
      site = create_site!()
      later = create_component!(name: "later-live", site_id: site.id)

      error_page =
        create_error_page!(
          name: "named-later-errors",
          site_id: site.id,
          error_pages: [%{status: 404, template: calls("later-live")}]
        )

      {:ok, error_page} =
        error_page
        |> Ash.Changeset.for_update(
          :update,
          %{error_pages: [%{status: 404, template: "<p>gone</p>"}]},
          tenant: site.id
        )
        |> Ash.update(authorize?: false)

      assert {:ok, _live} = make_live(later, site.id)

      naming = version_holding(error_page, &(inspect(&1["error_pages"]) =~ "later-live"))

      assert {:error, error} = restore(error_page, naming, site.id)
      assert Exception.message(error) =~ "The 404 page: An error page cannot hold later-live"
    end
  end

  # CHOSEN BY WHAT IT HOLDS, not by being first: two versions written inside one microsecond tie on
  # their timestamp.
  defp version_holding(%resource{} = record, holds?) do
    resource
    |> Module.concat(Version)
    |> Ash.Query.for_read(:read_any)
    |> Ash.Query.filter(version_source_id == ^record.id)
    |> Ash.read!(authorize?: false)
    |> Enum.find(&holds?.(snapshot(&1)))
    |> tap(&assert(&1, "no version of #{record.name} holds what the test restores"))
  end

  defp snapshot(%{changes: changes}) when is_binary(changes), do: Jason.decode!(changes)
  defp snapshot(%{changes: changes}), do: changes

  defp restore(record, version, tenant) do
    record
    |> Ash.Changeset.for_update(:restore_version, %{version_id: version.id}, tenant: tenant)
    |> Ash.update(authorize?: false)
  end

  defp becomes_live!(component) do
    Ecto.Adapters.SQL.query!(
      @repo,
      "UPDATE components SET stateful = true WHERE id = $1",
      [Ecto.UUID.dump!(component.id)]
    )
  end

  describe "what it does not refuse" do
    test "a function component anywhere" do
      site = create_site!()
      _plain = create_component!(name: "plain-widget", site_id: site.id)

      assert {:ok, _layout} =
               Layout
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "plain-layout",
                   path: "/plain-layout",
                   template: ~s(<div>#{calls("plain-widget")}<%= @inner_content %></div>)
                 },
                 tenant: site.id
               )
               |> Ash.create(authorize?: false)
    end

    # A NAME BUILT AT RUNTIME IS NOT A LITERAL THIS CAN RESOLVE, and guessing would refuse markup
    # that is very likely fine. The canvas's own containment is what catches that case.
    test "a component whose name is an expression" do
      site = create_site!()
      _live = live_component!(site)

      assert {:ok, _layout} =
               Layout
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "dynamic-layout",
                   path: "/dynamic-layout",
                   template:
                     ~s(<div><.component component_name={@which} site="Global" id="w1" /><%= @inner_content %></div>)
                 },
                 tenant: site.id
               )
               |> Ash.create(authorize?: false)
    end

    # A TAG IN A ROOT LAYOUT CALLS NOTHING. `Phoenix.HTML.Engine` has no tag handler, so
    # `<.component …/>` reaches the visitor as the text it is written as and no token is ever built.
    # Refusing it with a live-component message would be a reason that is not true. The layout has no
    # EEx in an attribute, so read as HEEx it would parse — and be refused.
    test "a tag in an error page's root layout, which is text there" do
      site = create_site!()
      _live = live_component!(site)

      assert {:ok, _error_page} =
               ErrorPage
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "tag-root",
                   root_layout_template:
                     ~s(<html><body>#{calls("live-widget")}<%= @inner_content %></body></html>),
                   error_pages: [%{status: 404, template: "<p>gone</p>"}]
                 },
                 tenant: site.id
               )
               |> Ash.create(authorize?: false)
    end

    # AND MARKUP THAT WILL NOT PARSE IS SOMEBODY ELSE'S REFUSAL. `TemplateCompiles` says what is
    # actually wrong; two sentences about one typo is worse than one.
    test "leaves unparseable markup to the validation that is about that" do
      site = create_site!()
      _live = live_component!(site)

      assert {:error, error} =
               Layout
               |> Ash.Changeset.for_create(
                 :create,
                 %{name: "broken", path: "/broken", template: ~s(<div :foo={@a}>x</div>)},
                 tenant: site.id
               )
               |> Ash.create(authorize?: false)

      refute Exception.message(error) =~ "only runs on a page"
    end

    # AN OLD ROW STAYS EDITABLE. Refusing every other field because the stored markup predates this
    # rule would lock the author out of the screen the markup gets fixed in.
    test "a write that does not touch the markup" do
      site = create_site!()
      _plain = create_component!(name: "settled-widget", site_id: site.id)

      layout =
        create_layout!(
          site_id: site.id,
          template: ~s(<div>#{calls("settled-widget")}<%= @inner_content %></div>)
        )

      # The component becomes live AFTER the layout that names it was stored — a history the rule no
      # longer lets anybody make, so it is written to the row.
      Component
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(name == "settled-widget")
      |> Ash.read_one!()
      |> becomes_live!()

      assert {:ok, _renamed} =
               layout
               |> Ash.Changeset.for_update(:update, %{description: "still editable"},
                 tenant: site.id
               )
               |> Ash.update(authorize?: false)
    end
  end

  # THE DUPLICATE-ID RULE. `Phoenix.LiveView.Diff` raises "found duplicate ID … for component …"
  # inside whichever LiveView renders the page, where nothing contains it — so this is a rule and
  # not a finding.
  #
  # The editor's own minting does not cover it: it renames the nodes that ARRIVED and answers
  # nothing when a whole document arrives at once, which is exactly what the source window, a draft
  # restore and a seeded template do. So the page asks it of the stored markup, and this suite
  # needs no editor to hold it.
  describe "two live components under one id" do
    defp page(site, template) do
      Page
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "ids-#{System.unique_integer([:positive])}",
          title: "Ids",
          path: "/ids-#{System.unique_integer([:positive])}",
          template: template
        },
        tenant: site.id,
        context: %{page_code: :package}
      )
      |> Ash.create(authorize?: false)
    end

    defp twice(name, id_one, id_two) do
      ~s(<div><.component component_name="#{name}" site="Global" id="#{id_one}" />) <>
        ~s(<.component component_name="#{name}" site="Global" id="#{id_two}" /></div>)
    end

    test "is refused, with both named" do
      site = create_site!()
      _live = live_component!(site)

      assert {:error, error} = page(site, twice("live-widget", "same", "same"))

      message = Exception.message(error)
      assert message =~ "same"
      assert message =~ "live-widget"
      assert message =~ "give each its own"
    end

    test "and two with their own ids are fine" do
      site = create_site!()
      _live = live_component!(site)

      assert {:ok, _page} = page(site, twice("live-widget", "one", "two"))
    end

    # A FUNCTION COMPONENT SHARING AN ID IS A BAD IDEA AND NOT A CRASH, and the editor already
    # renames those. This rule is about the one that takes the page down.
    test "and two function components sharing one are not this rule's business" do
      site = create_site!()
      _plain = create_component!(name: "plain-widget", site_id: site.id)

      assert {:ok, _page} = page(site, twice("plain-widget", "same", "same"))
    end

    # `id={@row.id}` IS THE AUTHOR BINDING THE ID TO THEIR DATA, and two of them are not a
    # collision.
    test "and an expression is not a literal this can compare" do
      site = create_site!()
      _live = live_component!(site)

      template =
        ~s(<div><.component component_name="live-widget" site="Global" id={@a} />) <>
          ~s(<.component component_name="live-widget" site="Global" id={@b} /></div>)

      assert {:ok, _page} = page(site, template)
    end
  end
end
