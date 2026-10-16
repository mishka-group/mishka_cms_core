# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.ComponentCopyTest do
  @moduledoc """
  A component copied from the inspector modal's Duplicate.

  Four things are pinned here. The copy is a new component that happens to start from an old one —
  written through the resource's own create action, so its validations, its code gate and its
  version row all apply. It is NOT the kit's, NOT required and NOT precompiled, whatever its source
  was. It names ITSELF: a component's examples are `<.component component_name="…"/>` invocations
  of the component they document, and a copy whose examples still name the original previews the
  original. And its elements are its OWN: the Visual Editor's CSS is keyed on a class in the markup,
  and a copy sharing the source's classes shares the source's styling.

  See `MishkaCmsCore.Runtime.ComponentCopy`.
  """
  use MishkaCmsCore.DataCase, async: false

  require Ash.Query

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.{Component, ComponentCopy, Stylesheet}
  alias MishkaCmsCore.Runtime.PageBuilder.ElementCss

  @moduletag :integration
  @moduletag :capture_log

  @password "Password123!"
  @helper %{"name" => "shout", "args" => "word", "code" => "String.upcase(word)"}

  setup do
    site = create_site!(name: "copy-site", host: "copy-site.test", active: true)
    {:ok, site: site, master: user_with("*")}
  end

  describe "copy_name/1" do
    test "is the source's name, -copy-, and four lowercase characters" do
      assert ComponentCopy.copy_name("chelekom-badge") =~ ~r/^chelekom-badge-copy-[a-z2-7]{4}$/
    end

    test "stays within the resource's 100 characters" do
      name = ComponentCopy.copy_name(String.duplicate("a", 100))

      assert String.length(name) == 100
      assert name =~ ~r/-copy-[a-z2-7]{4}$/
    end

    # THE NAME THE REFERENCES ARE REWRITTEN TO MUST BE THE NAME THE ROW IS STORED UNDER. The
    # resource slugifies `name` on the way in, so a cut that leaves a trailing hyphen would store
    # `a-copy-…` while every example said `a--copy-…`.
    test "is already the slug the resource stores, even when the cut lands on a hyphen" do
      name =
        ComponentCopy.copy_name(String.duplicate("a", 89) <> "-" <> String.duplicate("b", 10))

      assert Slug.slugify(name) == name
      assert String.length(name) <= 100
    end

    test "is fresh each time" do
      names = for _ <- 1..5, do: ComponentCopy.copy_name("chelekom-badge")

      assert length(Enum.uniq(names)) > 1
    end
  end

  describe "a master copying a global kit component" do
    setup %{master: master} do
      source = kit_row()
      {:ok, copy} = ComponentCopy.duplicate(source, master)
      {:ok, source: source, copy: copy}
    end

    test "stays global, under a copy name", %{source: source, copy: copy} do
      assert copy.site_id == nil
      assert copy.name =~ ~r/^#{source.name}-copy-[a-z2-7]{4}$/
      refute copy.id == source.id
    end

    test "carries every attribute a component is made of", %{source: source, copy: copy} do
      for field <- [
            :description,
            :format,
            :priority,
            :attrs,
            :slots,
            :active,
            :stateful,
            :permissions,
            :type,
            :dependencies
          ] do
        assert Map.get(copy, field) == Map.get(source, field), "#{field} was not copied"
      end

      assert helper_code(copy) == helper_code(source)
      assert copy.extra["component"] == source.extra["component"]
    end

    # A copy of the kit's icon is not something the CMS cannot run without, and it is built by the
    # first render that names it rather than at every boot.
    test "is neither required nor precompiled", %{source: source, copy: copy} do
      assert source.required and source.precompile, "the fixture should be both"

      refute copy.required
      refute copy.precompile
    end

    # The kit's uninstall purges by provenance and by the kit's name prefix. The first is dropped,
    # and `copied_from` is what tells the prefix arm the row is somebody's copy.
    test "is not the kit's, and says where it came from", %{source: source, copy: copy} do
      refute Map.has_key?(copy.extra, "ui_kit")
      refute Map.has_key?(copy.extra, "ui_kit_version")
      refute Map.has_key?(copy.extra, "ui_kit_digest")
      assert copy.extra["copied_from"] == source.id
    end

    test "names itself wherever the source named itself", %{source: source, copy: copy} do
      own = ~s(component_name="#{copy.name}")
      original = ~s(component_name="#{source.name}")

      for {label, text} <- [
            template: copy.template,
            body: copy.body,
            example: hd(copy.examples),
            rich_example: hd(copy.extra["examples"])["source"],
            demo_example: hd(copy.extra["demo_examples"])["source"]
          ] do
        assert text =~ own, "the #{label} still renders the original"
        refute text =~ original, "the #{label} still renders the original"
      end
    end

    # The closing quote is part of the reference, so a component whose name merely STARTS with the
    # source's is somebody else.
    test "leaves a longer name that shares the prefix alone", %{source: source, copy: copy} do
      assert List.last(copy.examples) == List.last(source.examples)
      assert List.last(copy.examples) =~ ~s(component_name="#{source.name}-group")
    end

    test "leaves the source exactly as it was", %{source: source} do
      reread = Ash.get!(Component, source.id, action: :master_get, authorize?: false)

      assert Map.take(reread, [:name, :template, :body, :examples, :extra, :required]) ==
               Map.take(source, [:name, :template, :body, :examples, :extra, :required])
    end

    # Through the action, not around it: the copy has its own first version.
    test "has a version of its own", %{copy: copy} do
      versions =
        Component.Version
        |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
        |> Ash.Query.filter(version_source_id == ^copy.id)
        |> Ash.read!(page: false, authorize?: false)

      assert length(versions) == 1
    end
  end

  # THE VISUAL EDITOR'S CSS IS KEYED ON A CLASS IN THE MARKUP. `ElementCss` files an element's rule
  # under a minted `pb-xxxxxxxx` class, in a stylesheet row named after the document, and every row
  # is compiled into the one site stylesheet. A copy that kept the source's classes and not its row
  # was styled by the source's rules, and a rule written on the copy restyled the source.
  describe "a component styled in the Visual Editor" do
    @styled "pb-0a1b2c3d"
    @handle "pb-99998888"
    @dead "pb-deadbeef"

    setup %{master: master} do
      source =
        create_component!(
          name: "styled-#{unique()}",
          template:
            ~s(<div class="p-2 #{@styled}" data-target=".#{@handle}"><p class="#{@handle}">hi</p></div>)
        )

      {:ok, _} = ElementCss.put(master, nil, css_owner(source), @styled, "padding: 20px;")
      {:ok, _} = ElementCss.put(master, nil, css_owner(source), @handle, "color: red;")
      {:ok, rules} = ElementCss.put(master, nil, css_owner(source), @dead, "margin: 0;")
      {:ok, copy} = ComponentCopy.duplicate(source, master)

      {:ok, source: source, rules: rules, copy: copy, fresh: fresh_scopes(source, copy)}
    end

    test "gives every element a class of its own, everywhere the markup names it", %{
      source: source,
      copy: copy,
      fresh: fresh
    } do
      assert Map.keys(fresh) |> Enum.sort() == Enum.sort([@styled, @handle])
      assert fresh |> Map.values() |> Enum.all?(&(&1 =~ ~r/^pb-[a-f0-9]{8}$/))
      assert MapSet.disjoint?(MapSet.new(Map.keys(fresh)), MapSet.new(Map.values(fresh)))

      assert Enum.reduce(fresh, source.template, fn {old, new}, text ->
               String.replace(text, old, new)
             end) == copy.template
    end

    # A rule whose element is no longer in the markup is one the builder prunes on the next save; on a
    # copy it would be a rule for nothing, filed under the source's class.
    test "brings the CSS of those elements under the new classes", %{
      master: master,
      copy: copy,
      fresh: fresh
    } do
      assert ElementCss.all(master, nil, css_owner(copy)) == %{
               fresh[@styled] => "padding: 20px;",
               fresh[@handle] => "color: red;"
             }
    end

    test "is restyled without restyling the source", %{
      master: master,
      source: source,
      rules: rules,
      copy: copy,
      fresh: fresh
    } do
      {:ok, _} = ElementCss.put(master, nil, css_owner(copy), fresh[@styled], "padding: 99px;")

      assert ElementCss.all(master, nil, css_owner(source)) == rules

      assert Ash.get!(Component, source.id, action: :master_get, authorize?: false).template ==
               source.template

      refute Enum.any?(
               Map.keys(ElementCss.all(master, nil, css_owner(copy))),
               &Map.has_key?(rules, &1)
             )
    end

    test "a site's copy keeps its CSS in that site", %{site: site} do
      actor = user_with("*", site.id)

      source =
        create_component!(
          site_id: site.id,
          name: "site-styled-#{unique()}",
          template: ~s(<div class="#{@styled}">hi</div>)
        )

      {:ok, _} = ElementCss.put(actor, site.id, css_owner(source), @styled, "gap: 4px;")
      {:ok, copy} = ComponentCopy.duplicate(source, actor)

      assert ElementCss.all(actor, site.id, css_owner(copy)) == %{
               fresh_scopes(source, copy)[@styled] => "gap: 4px;"
             }
    end
  end

  describe "a component nobody styled" do
    test "writes no element CSS for its copy", %{master: master} do
      source = create_component!(name: "unstyled-#{unique()}")
      {:ok, copy} = ComponentCopy.duplicate(source, master)
      row = ElementCss.row_name(css_owner(copy))

      assert Stylesheet
             |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
             |> Ash.Query.filter(name == ^row)
             |> Ash.read!(page: [limit: 10], authorize?: false)
             |> Map.fetch!(:results) == []
    end

    # `component_name="pb-0badc0de"` is a component's name, not an element's class.
    test "names itself even when its name looks like a class", %{master: master} do
      source =
        create_component!(
          name: "pb-0badc0de",
          examples: [~s(<.component component_name="pb-0badc0de" site="Global" />)]
        )

      {:ok, copy} = ComponentCopy.duplicate(source, master)

      assert copy.examples == [~s(<.component component_name="#{copy.name}" site="Global" />)]
    end
  end

  describe "scope" do
    test "a master's copy of a site's component stays in that site", %{
      site: site,
      master: master
    } do
      source = create_component!(site_id: site.id, name: "site-row-#{unique()}")

      assert {:ok, copy} = ComponentCopy.duplicate(source, master)
      assert copy.site_id == site.id
    end

    test "a site copies its own component into itself", %{site: site} do
      source = create_component!(site_id: site.id, name: "own-row-#{unique()}")

      assert {:ok, copy} = ComponentCopy.duplicate(source, user_with("*", site.id))
      assert copy.site_id == site.id
    end

    # A shared row forked into one site is a copy whose examples say `site="Global"` and cannot find
    # it, so it is refused rather than guessed at.
    test "a site does not copy a shared component", %{site: site} do
      source = create_component!(name: "shared-row-#{unique()}")

      assert {:error, :out_of_scope} = ComponentCopy.duplicate(source, user_with("*", site.id))
      assert copies_of(source) == []
    end
  end

  # THE COMPONENT SECTION WRITES A COMPONENT'S CODE, so it copies one carrying helpers — while the
  # deployment takes author-written Elixir at all.
  describe "the code gate" do
    test "lets the component section copy helpers", %{site: site} do
      source = create_component!(site_id: site.id, name: "coded-#{unique()}", helpers: [@helper])
      actor = user_with("admin:dashboard:runtime:component", site.id)

      assert {:ok, copy} = ComponentCopy.duplicate(source, actor)
      assert helper_code(copy) == helper_code(source)
    end

    test "refuses a copy of helpers while author-written Elixir is off", %{site: site} do
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :page_code) end)
      source = create_component!(site_id: site.id, name: "coded-#{unique()}", helpers: [@helper])
      actor = user_with("admin:dashboard:runtime:component", site.id)
      Application.put_env(:mishka_cms_core, :page_code, :off)

      assert {:error, %Ash.Error.Invalid{errors: errors}} = ComponentCopy.duplicate(source, actor)

      assert Enum.any?(errors, &match?(%{field: :helpers}, &1)),
             "the refusal does not name the field that carried the code"

      assert copies_of(source) == []
    end

    test "and lets the component section copy one without", %{site: site} do
      source = create_component!(site_id: site.id, name: "plain-#{unique()}")

      assert {:ok, _copy} =
               ComponentCopy.duplicate(
                 source,
                 user_with("admin:dashboard:runtime:component", site.id)
               )
    end

    # A COPY IS A WRITE OF A COMPONENT, so it takes the component section, or code, like any other.
    test "and refuses a holder of an unrelated section", %{site: site} do
      source = create_component!(site_id: site.id, name: "plain-#{unique()}")

      assert {:error, %Ash.Error.Forbidden{}} =
               ComponentCopy.duplicate(source, user_with("admin:dashboard:runtime:page", site.id))

      assert copies_of(source) == []
    end
  end

  describe "a taken name" do
    test "moves on to the next candidate", %{master: master} do
      n = unique()
      source = create_component!(name: "taken-src-#{n}")
      taken = create_component!(name: "taken-#{n}")

      assert {:ok, copy} =
               ComponentCopy.duplicate(source, master, names: [taken.name, "fresh-#{n}"])

      assert copy.name == "fresh-#{n}"
    end

    test "on the last candidate is returned as the refusal", %{master: master} do
      n = unique()
      source = create_component!(name: "taken-src-#{n}")
      taken = create_component!(name: "taken-#{n}")

      assert {:error, %Ash.Error.Invalid{}} =
               ComponentCopy.duplicate(source, master, names: [taken.name])
    end

    # Only a taken name is worth another try. A name refused for being too short is refused on the
    # name too, and it is not the next candidate's business to paper over it.
    test "is the only refusal that tries again", %{master: master} do
      n = unique()
      source = create_component!(name: "no-retry-#{n}")

      assert {:error, %Ash.Error.Invalid{}} =
               ComponentCopy.duplicate(source, master, names: ["ab", "second-#{n}"])

      assert copies_of(source) == []
    end
  end

  defp kit_row do
    name = "chelekom-probe-#{unique()}"
    own = ~s(component_name="#{name}")

    create_component!(
      name: name,
      description: "A probe",
      template: ~s(<div class="probe"><.component #{own} site="Global" /></div>),
      body: ~s|assigns = Map.put(assigns, :self, ~s(#{own}))|,
      format: :heex,
      priority: 7,
      attrs: [%{name: "color", type: "string", opts: %{"default" => "primary"}}],
      slots: [%{name: "inner_block", opts: %{}}],
      helpers: [@helper],
      permissions: ["blog:read"],
      type: "general",
      dependencies: ["chelekom-icon"],
      required: true,
      precompile: true,
      examples: [
        ~s(<.component #{own} site="Global" color="primary" />),
        ~s(<.component component_name="#{name}-group" site="Global" />)
      ],
      extra: %{
        "ui_kit" => "chelekom",
        "ui_kit_version" => "0.0.9",
        "ui_kit_digest" => String.duplicate("a", 64),
        "component" => "probe",
        "examples" => [%{"label" => "Base", "source" => ~s(<.component #{own} site="Global" />)}],
        "demo_examples" => [
          %{"raw_source" => "<.probe />", "source" => ~s(<div><.component #{own} /></div>)}
        ]
      }
    )
  end

  # The owner the builder files a component's element CSS under.
  defp css_owner(component), do: "component-#{component.id}"

  defp fresh_scopes(source, copy) do
    [source.template, copy.template]
    |> Enum.map(&(~r/pb-[a-f0-9]{8}/ |> Regex.scan(&1) |> List.flatten() |> Enum.uniq()))
    |> Enum.zip_with(fn [old, new] -> {old, new} end)
    |> Map.new()
  end

  defp helper_code(component),
    do: Enum.map(component.helpers, &Map.take(&1, [:name, :args, :code]))

  defp copies_of(source) do
    Component
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(extra["copied_from"] == ^source.id)
    |> Ash.read!(page: [limit: 50], authorize?: false)
    |> Map.fetch!(:results)
  end

  defp unique, do: System.unique_integer([:positive])

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

  defp user_with(permission, site_id \\ nil) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "copy-#{unique()}@example.com",
          password: @password,
          password_confirmation: @password
        },
        authorize?: false
      )
      |> then(
        &if(site_id, do: Ash.Changeset.force_change_attribute(&1, :site_id, site_id), else: &1)
      )
      |> Ash.create()

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, permission!(permission).id)
    |> Ash.create!(authorize?: false)

    user
  end
end
