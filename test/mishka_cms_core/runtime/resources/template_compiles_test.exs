# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.TemplateCompilesTest do
  defmodule Tracer do
    @moduledoc false
    def trace({:on_module, _bytecode, _ignore}, %{module: module}) do
      send(:persistent_term.get(__MODULE__), {:built, module})
      :ok
    end

    def trace(_event, _env), do: :ok
  end

  @moduledoc """
  Markup HEEx will not take, refused where every writer meets it.

  `Validations.PageCodeCompiles` has done this for a `Page` since it existed, which is why a page
  cannot be seeded broken. A layout, a component and an error page had nothing: the row was stored,
  `RuntimeStatus` reported `Ready`, the compile then failed into `CompileFailureState`, and the site
  went on serving the module it already had. Nobody was told at any point.

  `MishkaCmsBuilderWeb.Live.EditorSectionsTest` covers the editor's own gate. This is the other half —
  a seed, an import, the JSON API and the list page's form all write through these actions and none
  of them go anywhere near the builder.

  The three shapes below are exactly the ones that survive the tokenizer AND the serializer:
  `to_heex/1` parses every expression, so `{@a + }` is already caught; what nothing read was the
  HEEx itself.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.{Component, ErrorAddress, ErrorPage, ErrorPageDraft, Layout}

  @moduletag :integration

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  @good ~s(<section id="root"><h1>Title</h1></section>)
  @good_layout ~s(<body class="page"><main>{@inner_content}</main></body>)

  @bad_attr ~s(<section id="root"><div :foo={@a}>x</div></section>)
  @bad_for ~s(<section id="root"><div :for={@a}>x</div></section>)
  @bad_slot ~s(<section id="root"><:header>x</:header></section>)

  setup do
    {:ok, site: create_site!()}
  end

  defp entry(status, template \\ @good), do: %{status: status, template: template}

  defp write_error_page(site, attrs) do
    ErrorPage
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{name: "#{site.name} errors", path: ErrorAddress.path(site.name)}, attrs),
      tenant: site.id,
      authorize?: false,
      context: %{page_code: :package}
    )
    |> Ash.create()
  end

  defp refusals(%Ash.Error.Invalid{errors: errors}), do: Enum.map(errors, &{&1.field, &1.message})

  defp reread(error_page),
    do: Ash.get!(ErrorPage, error_page.id, tenant: error_page.site_id, authorize?: false)

  describe "a layout" do
    test "is stored when its markup compiles", %{site: site} do
      layout = create_layout!(site_id: site.id, template: @good_layout)
      assert %Layout{} = layout
      assert layout.site_id == site.id
    end

    for {name, markup} <- [
          {"an attribute HEEx does not have", @bad_attr},
          {"a :for with no generator", @bad_for},
          {"a slot entry outside a component", @bad_slot}
        ] do
      test "is refused for #{name}", %{site: site} do
        assert_raise Ash.Error.Invalid, fn ->
          create_layout!(site_id: site.id, template: unquote(markup))
        end
      end
    end

    test "and an update is refused the same way", %{site: site} do
      layout = create_layout!(site_id: site.id, template: @good_layout)

      assert {:error, %Ash.Error.Invalid{} = error} =
               layout
               |> Ash.Changeset.for_update(:update, %{template: @bad_attr}, tenant: site.id)
               |> Ash.update(authorize?: false, tenant: site.id)

      assert Exception.message(error) =~ "unsupported attribute",
             "it was refused for some other reason than the markup"
    end

    # A ROW WHOSE MARKUP PREDATES THIS MUST STAY EDITABLE. Refusing every other field on it because
    # the template is old would lock the author out of the screen the template gets fixed in.
    test "but a write that does not touch the template is not judged on it", %{site: site} do
      layout = create_layout!(site_id: site.id, template: @good_layout)

      assert {:ok, renamed} =
               layout
               |> Ash.Changeset.for_update(:update, %{description: "renamed"}, tenant: site.id)
               |> Ash.update(authorize?: false, tenant: site.id)

      assert renamed.description == "renamed"
    end
  end

  describe "a component" do
    test "is stored when its markup compiles", %{site: site} do
      component = create_component!(site_id: site.id, name: "tc-ok", template: @good)
      assert %Component{} = component
      assert component.site_id == site.id
    end

    test "is refused when it does not", %{site: site} do
      assert_raise Ash.Error.Invalid, fn ->
        create_component!(site_id: site.id, name: "tc-bad", template: @bad_attr)
      end
    end
  end

  describe "an error page" do
    test "is stored when every status compiles", %{site: site} do
      assert %ErrorPage{error_pages: [_, _]} =
               create_error_page!(
                 site_id: site.id,
                 error_pages: [
                   %{"status" => 404, "template" => @good, "layout" => %{}},
                   %{"status" => 500, "template" => @good, "layout" => %{}}
                 ]
               )
    end

    # THE FAULT NAMES ITS STATUS, because "line 1" means nothing when the reader has five documents
    # open in one record.
    test "is refused when one of them does not, and says which", %{site: site} do
      error =
        assert_raise Ash.Error.Invalid, fn ->
          create_error_page!(
            site_id: site.id,
            error_pages: [
              %{"status" => 404, "template" => @good, "layout" => %{}},
              %{"status" => 500, "template" => @bad_attr, "layout" => %{}}
            ]
          )
        end

      assert Exception.message(error) =~ "500"
    end
  end

  # ALL ENTRIES COMPILE INTO ONE MODULE, so one that calls a function nobody defines takes the 500 and
  # the offline page of its site with it.
  describe "an error page whose code does not compile" do
    @undefined "<p>{no_such_fun_xyz(1)}</p>"

    test "is refused, naming the entry and the reason", %{site: site} do
      assert {:error, error} =
               write_error_page(site, %{error_pages: [entry(404), entry(500, @undefined)]})

      assert [{:error_pages, message}] = refusals(error)
      assert message =~ "The 500 page"
      assert message =~ "no_such_fun_xyz/1"
      refute message =~ "CodeCheck"
      refute message =~ "404"
    end

    test "is refused for an entry's wrapper, the offline and the default entries alike", %{
      site: site
    } do
      for status <- [404, :offline, :default] do
        wrapped = %{status: status, template: @good, layout: %{"template" => @undefined}}

        assert {:error, error} = write_error_page(site, %{error_pages: [entry(500), wrapped]})
        assert [{:error_pages, message}] = refusals(error)
        assert message =~ "The #{status} page"
      end
    end

    test "is refused on the field the fault is in, the root layout and the helpers", %{site: site} do
      assert {:error, error} =
               write_error_page(site, %{
                 root_layout_template: "<html><%= no_such_fun_xyz(@inner_content) %></html>",
                 error_pages: [entry(404), entry(500)]
               })

      assert [{:root_layout_template, message}] = refusals(error)
      assert message =~ "no_such_fun_xyz/1"

      assert {:error, error} =
               write_error_page(site, %{
                 helpers: [%{name: "greet", args: "name", code: "no_such_fun_xyz(name)"}],
                 error_pages: [entry(404, "<p>{greet(1)}</p>"), entry(500)]
               })

      assert [{:helpers, message}] = refusals(error)
      assert message =~ "no_such_fun_xyz/1"

      assert {:error, error} =
               write_error_page(site, %{
                 helpers: [%{name: "greet", args: "name", code: "name <>"}],
                 error_pages: [entry(404)]
               })

      assert [{:helpers, message}] = refusals(error)
      assert message =~ "greet"
    end

    test "is refused on every write that can bring the code in", %{site: site} do
      stored = create_error_page!(site_id: site.id, error_pages: [entry(404)])
      broken = %{error_pages: [entry(404, @undefined)]}

      for {action, tenant} <- [update: site.id, master_update: nil] do
        assert {:error, error} =
                 stored
                 |> Ash.Changeset.for_update(action, broken, tenant: tenant, authorize?: false)
                 |> Ash.update()

        assert [{:error_pages, "The 404 page" <> _reason}] = refusals(error)
      end

      other = create_site!()

      assert {:error, error} =
               ErrorPage
               |> Ash.Changeset.for_create(
                 :master_create,
                 Map.merge(broken, %{
                   name: "broken errors",
                   path: ErrorAddress.path(other.name),
                   site_id: other.id
                 }),
                 authorize?: false
               )
               |> Ash.create()

      assert [{:error_pages, "The 404 page" <> _reason}] = refusals(error)
    end

    test "is stored as a draft, and refused when the draft is published", %{site: site} do
      stored = create_error_page!(site_id: site.id, error_pages: [entry(404)])

      draft =
        ErrorPageDraft
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: stored.name,
            path: stored.path,
            error_pages: [entry(404, @undefined)],
            source_error_page_id: stored.id
          },
          tenant: site.id,
          authorize?: false
        )
        |> Ash.create!()

      assert {:error, error} =
               draft
               |> Ash.Changeset.for_update(:publish, %{}, tenant: site.id, authorize?: false)
               |> Ash.update()

      assert Exception.message(error) =~ "The 404 page"
      assert [%{template: @good}] = reread(stored).error_pages
    end

    test "is refused when a version that holds it is restored", %{site: site} do
      stored = create_error_page!(site_id: site.id, error_pages: [entry(404)])

      [version] =
        Ash.load!(stored, :sorted_versions, tenant: site.id, authorize?: false).sorted_versions

      # As a version written before the rule holds it.
      @repo.query!(
        "UPDATE error_versions SET changes = jsonb_set(changes, '{error_pages}', $1) WHERE id = $2",
        [[%{"status" => 404, "template" => @undefined}], Ecto.UUID.dump!(version.id)]
      )

      assert {:error, error} =
               stored
               |> Ash.Changeset.for_update(:restore_version, %{version_id: version.id},
                 tenant: site.id,
                 authorize?: false
               )
               |> Ash.update()

      assert [{:error_pages, "The 404 page" <> _reason}] = refusals(error)
    end

    # THE ROW STAYS EDITABLE, as a layout does above.
    test "is not judged again by a write that does not touch its code", %{site: site} do
      stored = create_error_page!(site_id: site.id, error_pages: [entry(404)])

      @repo.query!("UPDATE error_pages SET error_pages = $1 WHERE id = $2", [
        [%{"status" => 404, "template" => @undefined}],
        Ecto.UUID.dump!(stored.id)
      ])

      assert {:ok, %{priority: 7}} =
               stored
               |> reread()
               |> Ash.Changeset.for_update(:update, %{priority: 7},
                 tenant: site.id,
                 authorize?: false
               )
               |> Ash.update()
    end

    # A template that compiles and raises only as it is drawn is stored, as a page's is.
    test "only as it is drawn is stored", %{site: site} do
      assert {:ok, _error_page} =
               write_error_page(site, %{
                 error_pages: [entry(404, "<p>{String.length(@conn)}</p>")]
               })
    end

    test "leaves no module of the check behind, compiled or not", %{site: site} do
      on_exit(fn -> Code.put_compiler_option(:tracers, []) end)
      Code.put_compiler_option(:tracers, [__MODULE__.Tracer])
      :persistent_term.put(__MODULE__.Tracer, self())

      assert {:ok, _error_page} = write_error_page(site, %{error_pages: [entry(404)]})
      assert {:error, _error} = write_error_page(site, %{error_pages: [entry(404, @undefined)]})
      assert_received {:built, module}

      refute :erlang.module_loaded(module)
      refute :erlang.check_old_code(module)
    end
  end

  # A ROOT LAYOUT IS A DIFFERENT LANGUAGE IN THE SAME RECORD. `ErrorCompiler` compiles it with
  # `EEx.compile_string/2` and the classic `Phoenix.HTML.Engine`, precisely because it relies on EEx
  # interpolation inside an attribute — which HEEx rejects and which the shipped seeds use. Judging it
  # as HEEx broke `mix seeds` on the first error page, which is how this was found.
  describe "an error page's root layout" do
    @eex_root ~S|<html><head><meta name="csrf-token" content="<%= Phoenix.Controller.get_csrf_token() %>" /></head><body><%= @inner_content %></body></html>|

    test "is EEx, and is not judged as HEEx", %{site: site} do
      assert %ErrorPage{root_layout_template: root} =
               create_error_page!(
                 site_id: site.id,
                 root_layout_template: @eex_root,
                 error_pages: [%{"status" => 404, "template" => @good, "layout" => %{}}]
               )

      assert root =~ ~S|content="<%= Phoenix.Controller.get_csrf_token() %>"|
    end

    test "while the per-status template beside it still is", %{site: site} do
      assert_raise Ash.Error.Invalid, fn ->
        create_error_page!(
          site_id: site.id,
          root_layout_template: @eex_root,
          error_pages: [%{"status" => 404, "template" => @bad_attr, "layout" => %{}}]
        )
      end
    end
  end

  # AND THE CORPUS THIS RUNS AGAINST IS REAL. Every layout, component, page and error page the seeds
  # produce passes; a validation that refused any of them would be a validation nobody could ship.
  describe "the shipped fixtures" do
    test "a factory layout, component and error page all pass", %{site: site} do
      assert create_layout!(site_id: site.id)
      assert create_component!(site_id: site.id, name: "tc-factory")
      assert create_error_page!(site_id: site.id)
    end
  end
end
