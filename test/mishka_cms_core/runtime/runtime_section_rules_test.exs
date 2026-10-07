defmodule MishkaCmsCore.Runtime.RuntimeSectionRulesTest do
  @moduledoc """
  Who writes each runtime section, on each surface.

  Pages, layouts, components, error pages, stylesheets and JS hooks carry code. Each is created,
  updated, destroyed and restored — its code included — by a holder of its own section or of code,
  `admin:<surface>:runtime:<type>` or `admin:<surface>:code`, and by the wildcards above them.
  Another section writes none of it, and a name of one surface writes nothing on the other. A draft
  is written as its document is. What the builder generates into a stylesheet is written by any
  builder's type.

  Sites, media, translations, redirects and the Activity log carry no code: their own section writes
  them, and reads the log. Code writes none of them.

  Every write runs on a site of its own, since a site holds one error page.
  """
  use MishkaCmsCore.DataCase, async: false

  require Ash.Query

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Activity.ActivityEntry

  alias MishkaCmsCore.Runtime.{
    Component,
    ErrorPage,
    ErrorPageDraft,
    JsHook,
    Languages,
    Layout,
    LayoutDraft,
    MediaCategory,
    Page,
    PageDraft,
    Redirect,
    Site,
    Stylesheet,
    Translation
  }

  alias MishkaCmsCore.Runtime.States.TranslationsState

  @moduletag :capture_log

  @api %{shared: %{admin_surface: :api}}
  @builder %{page_code: :builder}
  @helper %{"name" => "money", "args" => "cents", "code" => "cents / 100"}
  @handler %{"name" => "save", "code" => "{:noreply, socket}"}

  # The six code-bearing types: the section that writes each on either surface, and another section.
  @types [
    {Page, "admin:dashboard:runtime:page", "admin:api:runtime:page",
     "admin:dashboard:runtime:layout", "admin:api:runtime:layout"},
    {Layout, "admin:dashboard:runtime:layout", "admin:api:runtime:layout",
     "admin:dashboard:runtime:component", "admin:api:runtime:component"},
    {Component, "admin:dashboard:runtime:component", "admin:api:runtime:component",
     "admin:dashboard:runtime:error_page", "admin:api:runtime:error_page"},
    {ErrorPage, "admin:dashboard:runtime:error_page", "admin:api:runtime:error_page",
     "admin:dashboard:runtime:stylesheet", "admin:api:runtime:stylesheet"},
    {Stylesheet, "admin:dashboard:runtime:stylesheet", "admin:api:runtime:stylesheet",
     "admin:dashboard:runtime:js_hook", "admin:api:runtime:js_hook"},
    {JsHook, "admin:dashboard:runtime:js_hook", "admin:api:runtime:js_hook",
     "admin:dashboard:runtime:page", "admin:api:runtime:page"}
  ]

  for {resource, own, api_own, other, api_other} <- @types do
    describe "#{inspect(resource)}" do
      for {names, surface, writes?} <- [
            {[own], :dashboard, true},
            {["admin:dashboard:code"], :dashboard, true},
            {["admin:dashboard:runtime:*"], :dashboard, true},
            {["admin:dashboard:*"], :dashboard, true},
            {[other], :dashboard, false},
            {[api_own, "admin:api:code"], :dashboard, false},
            {[api_own], :api, true},
            {["admin:api:code"], :api, true},
            {["admin:api:runtime:*"], :api, true},
            {["admin:api:*"], :api, true},
            {[api_other], :api, false},
            {[own, "admin:dashboard:code"], :api, false}
          ] do
        @resource resource
        @names names
        @surface surface
        @expected if(writes?, do: :allowed, else: :refused)

        test "#{Enum.join(names, " + ")} on the #{surface}: a create, the details, a destroy and a restore are #{@expected}" do
          assert as(@names, @surface, fn _site, opts ->
                   create(@resource, plain(@resource), opts)
                 end) ==
                   @expected

          assert as(@names, @surface, &edit(system!(@resource, &1), details(@resource), &2)) ==
                   @expected

          assert as(@names, @surface, &destroy(system!(@resource, &1), &2)) == @expected

          if restorable?(@resource) do
            assert as(@names, @surface, &restore(versioned!(@resource, &1), &2)) == @expected
          end
        end

        test "#{Enum.join(names, " + ")} on the #{surface}: code is #{@expected}" do
          assert as(@names, @surface, fn _site, opts ->
                   create(@resource, coded(@resource), opts)
                 end) ==
                   @expected

          assert as(@names, @surface, &edit(system!(@resource, &1), recoded(@resource), &2)) ==
                   @expected
        end
      end
    end
  end

  # A DRAFT IS WRITTEN AS ITS DOCUMENT IS.
  @drafts [
    {PageDraft, "admin:dashboard:runtime:page", "admin:api:runtime:page",
     "admin:dashboard:runtime:layout"},
    {LayoutDraft, "admin:dashboard:runtime:layout", "admin:api:runtime:layout",
     "admin:dashboard:runtime:page"},
    {ErrorPageDraft, "admin:dashboard:runtime:error_page", "admin:api:runtime:error_page",
     "admin:dashboard:runtime:page"}
  ]

  for {draft, own, api_own, other} <- @drafts do
    describe "#{inspect(draft)}" do
      for {names, surface, writes?} <- [
            {[own], :dashboard, true},
            {["admin:dashboard:code"], :dashboard, true},
            {[other], :dashboard, false},
            {[api_own], :dashboard, false},
            {[api_own], :api, true},
            {["admin:api:code"], :api, true},
            {[own], :api, false}
          ] do
        @draft draft
        @names names
        @surface surface
        @expected if(writes?, do: :allowed, else: :refused)

        test "#{Enum.join(names, " + ")} on the #{surface}: a draft's label and a destroy are #{@expected}" do
          assert as(@names, @surface, &edit(draft!(@draft, &1), %{label: "renamed"}, &2)) ==
                   @expected

          assert as(@names, @surface, &destroy(draft!(@draft, &1), &2)) == @expected
        end

        test "#{Enum.join(names, " + ")} on the #{surface}: a draft's code is #{@expected}" do
          assert as(@names, @surface, fn _site, opts -> create(@draft, coded(@draft), opts) end) ==
                   @expected
        end
      end
    end
  end

  # WHAT THE BUILDER GENERATES INTO A STYLESHEET — element CSS, reusable classes, design tokens —
  # every builder shares, so any builder's type writes it; every other stylesheet stays the
  # stylesheet section's and code's.
  describe "a stylesheet the builder writes" do
    for {names, writes?} <- [
          {["admin:dashboard:runtime:page"], true},
          {["admin:dashboard:runtime:layout"], true},
          {["admin:dashboard:runtime:component"], true},
          {["admin:dashboard:runtime:error_page"], true},
          {["admin:dashboard:runtime:stylesheet"], true},
          {["admin:dashboard:code"], true},
          {["admin:dashboard:runtime:js_hook"], false},
          {["admin:dashboard:runtime:media"], false}
        ] do
      @names names
      @expected if(writes?, do: :allowed, else: :refused)

      test "#{Enum.join(names, " + ")}: its details are #{@expected}" do
        assert as(@names, :dashboard, fn site, opts ->
                 edit(system!(Stylesheet, site), details(Stylesheet), built(opts))
               end) == @expected
      end

      test "#{Enum.join(names, " + ")}: its CSS is #{@expected}" do
        assert as(@names, :dashboard, fn _site, opts ->
                 create(Stylesheet, coded(Stylesheet), built(opts))
               end) == @expected

        assert as(@names, :dashboard, fn site, opts ->
                 edit(system!(Stylesheet, site), recoded(Stylesheet), built(opts))
               end) == @expected
      end
    end

    test "a builder's type writes no stylesheet the builder did not" do
      names = ["admin:dashboard:runtime:page"]

      assert as(names, :dashboard, &edit(system!(Stylesheet, &1), details(Stylesheet), &2)) ==
               :refused

      assert as(names, :dashboard, fn _site, opts ->
               create(Stylesheet, coded(Stylesheet), opts)
             end) ==
               :refused
    end
  end

  # SITES, MEDIA, TRANSLATIONS AND REDIRECTS ARE WRITTEN BY THEIR OWN SECTION; CODE PLAYS NO PART.
  @sections [
    {:site, "admin:dashboard:runtime:site", "admin:api:runtime:site"},
    {:media, "admin:dashboard:runtime:media", "admin:api:runtime:media"},
    {:translation, "admin:dashboard:runtime:translation", "admin:api:runtime:translation"},
    {:redirect, "admin:dashboard:runtime:redirect", "admin:api:runtime:redirect"}
  ]

  for {section, own, api_own} <- @sections do
    describe "the #{section} section" do
      for {names, surface, writes?} <- [
            {[own], :dashboard, true},
            {["admin:dashboard:runtime:*"], :dashboard, true},
            {["admin:dashboard:*"], :dashboard, true},
            {["admin:dashboard:code"], :dashboard, false},
            {["admin:dashboard:runtime:page"], :dashboard, false},
            {[api_own], :dashboard, false},
            {[api_own], :api, true},
            {["admin:api:*"], :api, true},
            {["admin:api:code"], :api, false},
            {[own], :api, false}
          ] do
        @section section
        @names names
        @surface surface
        @expected if(writes?, do: :allowed, else: :refused)

        test "#{Enum.join(names, " + ")} on the #{surface}: every write is #{@expected}" do
          for write <- writes(@section) do
            assert as(@names, @surface, write, holder_of(@section)) == @expected
          end
        end
      end
    end
  end

  describe "the Activity log" do
    for {names, surface, reads?} <- [
          {["admin:dashboard:runtime:activity"], :dashboard, true},
          {["admin:dashboard:runtime:*"], :dashboard, true},
          {["admin:dashboard:*"], :dashboard, true},
          {["admin:dashboard:code"], :dashboard, false},
          {["admin:dashboard:runtime:page"], :dashboard, false},
          {["admin:api:runtime:activity"], :dashboard, false},
          {["admin:api:runtime:activity"], :api, true},
          {["admin:api:code"], :api, false},
          {["admin:dashboard:runtime:activity"], :api, false}
        ] do
      @names names
      @surface surface
      @expected if(reads?, do: :allowed, else: :refused)

      test "#{Enum.join(names, " + ")} on the #{surface}: a read is #{@expected}" do
        assert as(@names, @surface, fn _site, opts ->
                 ActivityEntry
                 |> Ash.Query.for_read(:read, %{gervaz_filters: %{}})
                 |> Ash.Query.set_context(Keyword.get(opts, :context, %{}))
                 |> Ash.read(actor: opts[:actor], page: [offset: 0, limit: 5])
               end) == @expected
      end
    end
  end

  # `write` run as a holder of `names` — an admin of a site of its own, or a master — on `surface`,
  # given that site and the options to write with; what came back is `:allowed`, `:refused` by a
  # policy, or the result itself.
  defp as(names, surface, write, holder \\ :site_admin) do
    site = create_site!()

    actor =
      case holder do
        :site_admin -> create_user_with_permissions!(names, site_id: site.id)
        :master -> create_user_with_permissions!(names)
      end

    answer(write.(site, [actor: actor, tenant: site.id] ++ on(surface)))
  end

  defp on(:dashboard), do: []
  defp on(:api), do: [context: @api]

  defp built(opts), do: Keyword.put(opts, :context, @builder)

  defp answer({:ok, _result}), do: :allowed
  defp answer({:error, %Ash.Error.Forbidden{}}), do: :refused
  defp answer(other), do: other

  defp n, do: System.unique_integer([:positive])

  defp restorable?(resource), do: Ash.Resource.Info.action(resource, :restore_version_api) != nil

  # A record the system wrote, for a holder to change.
  defp system!(Page, site), do: create_page!(site_id: site.id)
  defp system!(Layout, site), do: create_layout!(site_id: site.id)
  defp system!(Component, site), do: create_component!(site_id: site.id)
  defp system!(ErrorPage, site), do: create_error_page!(site_id: site.id)
  defp system!(JsHook, site), do: create_js_hook!(site_id: site.id)

  defp system!(Stylesheet, site) do
    Ash.create!(Stylesheet, %{name: "s#{n()}", content: ".a { color: red; }", format: :css},
      action: :create,
      tenant: site.id,
      authorize?: false
    )
  end

  # The system writes no Elixir, so a draft it wrote carries markup alone.
  defp draft!(draft, site) do
    Ash.create!(draft, Map.delete(coded(draft), :events),
      action: :create,
      tenant: site.id,
      authorize?: false
    )
  end

  # A record with a version before its latest, and that version.
  defp versioned!(resource, site) do
    record = system!(resource, site)
    record = Ash.update!(record, details(resource), tenant: site.id, authorize?: false)

    version =
      resource
      |> Module.concat(Version)
      |> Ash.Query.filter(version_source_id == ^record.id)
      |> Ash.Query.sort(version_inserted_at: :asc)
      |> Ash.read!(authorize?: false, page: false)
      |> List.first()

    {record, version}
  end

  # A new record carrying no code; a new stylesheet or hook carries its content, which is code.
  defp plain(Page), do: %{name: "p#{n()}", title: "P", path: "/p#{n()}"}
  defp plain(Layout), do: %{name: "l#{n()}", path: "/l#{n()}"}
  defp plain(Component), do: %{name: "c#{n()}"}
  defp plain(ErrorPage), do: %{name: "e#{n()}"}
  defp plain(resource), do: coded(resource)

  # A change to no code.
  defp details(resource) when resource in [Stylesheet, JsHook], do: %{description: "d#{n()}"}
  defp details(_resource), do: %{priority: 7}

  # A new record carrying code of each kind the type holds.
  defp coded(Page),
    do: %{
      name: "p#{n()}",
      title: "P",
      path: "/p#{n()}",
      template: "<div>typed</div>",
      events: [@handler]
    }

  defp coded(Layout),
    do: %{
      name: "l#{n()}",
      path: "/l#{n()}",
      template: "<main>{@inner_content}</main>",
      helpers: [@helper]
    }

  defp coded(Component), do: %{name: "c#{n()}", template: "<b>typed</b>", helpers: [@helper]}

  defp coded(ErrorPage),
    do: %{
      name: "e#{n()}",
      root_layout_template: "<div>{@inner_content}</div>",
      error_pages: [%{"status" => 404, "template" => "<p>typed</p>"}],
      helpers: [@helper]
    }

  defp coded(Stylesheet), do: %{name: "s#{n()}", content: ".typed { color: red; }", format: :css}
  defp coded(JsHook), do: %{name: "h#{n()}", content: "console.log('typed');", format: :js}

  defp coded(PageDraft),
    do: %{
      name: "d#{n()}",
      title: "D",
      path: "/d#{n()}",
      template: "<div>typed</div>",
      events: [@handler]
    }

  defp coded(LayoutDraft),
    do: %{name: "d#{n()}", path: "/d#{n()}", template: "<main>{@inner_content}</main>"}

  defp coded(ErrorPageDraft),
    do: %{name: "d#{n()}", path: "/d#{n()}", root_layout_template: "<div>{@inner_content}</div>"}

  # Code changed on a record the system wrote.
  defp recoded(Page), do: %{template: "<div>edited</div>", events: [@handler]}
  defp recoded(Layout), do: %{template: "<section>{@inner_content}</section>"}
  defp recoded(Component), do: %{template: "<i>edited</i>", helpers: [@helper]}

  defp recoded(ErrorPage),
    do: %{error_pages: [%{"status" => 404, "template" => "<p>edited</p>"}]}

  defp recoded(Stylesheet), do: %{content: ".edited { color: blue; }"}
  defp recoded(JsHook), do: %{content: "console.log('edited');"}

  defp create(resource, attrs, opts) do
    resource
    |> Ash.Changeset.for_create(:create, attrs, opts)
    |> Ash.create()
  end

  defp edit(record, attrs, opts) do
    record
    |> Ash.Changeset.for_update(:update, attrs, opts)
    |> Ash.update()
  end

  defp destroy(record, opts) do
    record
    |> Ash.Changeset.for_destroy(:destroy, %{}, opts)
    |> Ash.destroy(return_destroyed?: true)
  end

  defp restore({record, version}, opts) do
    record.__struct__
    |> Ash.ActionInput.for_action(
      :restore_version_api,
      %{id: record.id, version_id: version.id},
      opts
    )
    |> Ash.run_action()
  end

  # WHO WRITES A SECTION'S RECORDS: a site is a master's to create, media, translations and redirects
  # a site's.
  defp holder_of(:site), do: :master
  defp holder_of(_section), do: :site_admin

  # EVERY WRITE OF A SECTION, each run by `as/4`.
  defp writes(:site) do
    [
      fn _site, opts ->
        create(Site, %{name: "s#{n()}", host: "s#{n()}.test"}, Keyword.delete(opts, :tenant))
      end,
      &edit(&1, %{priority: 3}, Keyword.delete(&2, :tenant)),
      &destroy(&1, Keyword.delete(&2, :tenant))
    ]
  end

  defp writes(:media) do
    [
      fn _site, opts -> create(MediaCategory, %{name: "m#{n()}"}, opts) end,
      &edit(create_media_category!(site_id: &1.id), %{name: "m#{n()}"}, &2),
      &destroy(create_media_category!(site_id: &1.id), &2),
      &edit(create_media!(site_id: &1.id), %{description: "d#{n()}"}, &2),
      &destroy(create_media!(site_id: &1.id), &2)
    ]
  end

  defp writes(:translation) do
    [
      &create(Translation, %{key: forgotten(&1), language: language(&1), value: "v"}, &2),
      &edit(registered!(&1), %{value: "v"}, &2),
      &destroy(registered!(&1), &2)
    ]
  end

  defp writes(:redirect) do
    [
      fn _site, opts -> create(Redirect, %{from_path: "/r#{n()}", to: "/new"}, opts) end,
      &edit(create_redirect!(site_id: &1.id), %{to: "/r#{n()}"}, &2),
      &destroy(create_redirect!(site_id: &1.id), &2)
    ]
  end

  defp language(site), do: site.id |> Languages.site() |> hd()

  defp registered!(site) do
    Ash.create!(
      Translation,
      %{key: forgotten(site), language: language(site), site_id: site.id},
      action: :register,
      authorize?: false
    )
  end

  # A word with a value reaches the translations cache, which outlives the test's rollback.
  defp forgotten(site) do
    key = "Rules #{n()}"
    language = language(site)
    on_exit(fn -> TranslationsState.put(site.id, language, key, nil) end)
    key
  end
end
