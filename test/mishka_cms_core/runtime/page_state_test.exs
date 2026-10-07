defmodule MishkaCmsCore.Runtime.PageStateTest do
  @moduledoc """
  A page's starting state, from the row to the socket.

  A database page could not read `@count` before an event had assigned it, so templates worked
  around it with defaults in every expression or helpers handed `assigns`, which LiveView cannot
  change-track. `Page.state` declares the assigns a page
  starts with; these pin what the compiler makes of it, what the runtime does with it on a mount, a
  switch to another page and an edit while the page is open, and which names a row may not use.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.PageBuilder.CodeCheck
  alias MishkaCmsCore.Runtime.PageState

  defp compile(state, opts \\ []) do
    module = Module.concat(__MODULE__, "P#{System.unique_integer([:positive])}")

    %{
      title: "state",
      path: "/state",
      site: "site",
      page_module: module,
      template: Keyword.get(opts, :template, ~S|<p id="count">{@count}</p>|),
      events: [],
      infos: [],
      state: state,
      helpers: Keyword.get(opts, :helpers, [])
    }
    |> LiveViewCompiler.build_assigns()
    |> LiveViewCompiler.build_page_state()
    |> LiveViewCompiler.build_page_forms()
    |> LiveViewCompiler.build_event_handlers()
    |> LiveViewCompiler.build_info_handlers()
    |> LiveViewCompiler.build_renders()
    |> LiveViewCompiler.build_helpers()
    |> LiveViewCompiler.create_module_ast()
    |> Code.compile_quoted()

    module
  end

  # A row read back holds atom keys where the column is typed and string keys where it is not.
  defp pairs(entries),
    do: Enum.map(entries, &{&1[:name] || &1["name"], &1[:code] || &1["code"]})

  defp socket(assigns \\ %{}),
    do: %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :__changed__, %{})}

  describe "what the compiler emits" do
    test "the values, worked out for each mount, and the keys as a literal" do
      module =
        compile(
          [
            %{name: "count", code: "0"},
            %{name: "roles", code: "roles()"},
            %{name: "opened_at", code: "System.unique_integer([:positive])"}
          ],
          helpers: [%{name: "roles", args: "", code: ~S|["a", "b"]|}]
        )

      assert module.__page_state_keys__() == [:count, :roles, :opened_at]
      assert %{count: 0, roles: ["a", "b"], opened_at: first} = module.__page_state__()
      assert %{opened_at: second} = module.__page_state__()
      refute first == second, "each visitor gets a fresh value"
    end

    test "a page that declares none answers an empty map and no keys" do
      module = compile([], template: "<p>hi</p>")

      assert module.__page_state__() == %{}
      assert module.__page_state_keys__() == []
    end

    test "the template reads @count from the first render, with change tracking" do
      module = compile([%{name: "count", code: "41 + 1"}])
      assigns = Map.merge(PageState.of(module), %{__changed__: nil, flash: %{}})

      html =
        assigns |> module.render() |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

      assert html =~ ~s(<p id="count">42</p>)
    end

    test "a name that is not one is skipped rather than minted" do
      module = compile([%{name: "Bad Name", code: "1"}, %{name: "ok", code: "2"}], template: "x")

      assert module.__page_state_keys__() == [:ok]
    end
  end

  describe "the runtime" do
    setup do
      %{
        a: compile([%{name: "count", code: "0"}, %{name: "only_a", code: ":a"}]),
        b: compile([%{name: "count", code: "100"}])
      }
    end

    test "a mount starts the page with its state", %{a: a} do
      socket = PageState.assign_initial(socket(), a)

      assert socket.assigns.count == 0
      assert socket.assigns.only_a == :a
    end

    test "the same page keeps the visitor's values", %{a: a} do
      socket = socket() |> PageState.assign_initial(a) |> Phoenix.Component.assign(:count, 7)

      assert PageState.switch(socket, a, a).assigns.count == 7
    end

    test "another page starts from its own state, and nothing of the last one travels", %{
      a: a,
      b: b
    } do
      socket =
        socket()
        |> PageState.assign_initial(a)
        |> Phoenix.Component.assign(:count, 7)
        |> PageState.switch(a, b)

      assert socket.assigns.count == 100
      assert socket.assigns.only_a == nil
    end

    test "an edit adds the new keys and leaves the visitor's values alone", %{a: a} do
      socket = socket(%{count: 7})
      socket = PageState.fill_missing(socket, a)

      assert socket.assigns.count == 7
      assert socket.assigns.only_a == :a
    end

    test "a module compiled before state existed is read as none" do
      assert PageState.of(String) == %{}
      assert PageState.keys(String) == []
      assert PageState.assign_initial(socket(), String) == socket()
    end
  end

  describe "the check an author sees" do
    test "a broken value is reported on the State tab, with its name" do
      {:error, [fault | _rest]} =
        CodeCheck.check(%{template: "x", state: [%{name: "count", code: "1 +"}]})

      assert fault.tab == :state
      assert fault.name == "count"
    end

    test "an empty value is reported before it can start the page with nil" do
      {:error, [fault | _rest]} =
        CodeCheck.check(%{template: "x", state: [%{name: "count", code: "  "}]})

      assert fault.tab == :state
      assert CodeCheck.message(fault) =~ "no code"
    end

    test "a value that calls a helper the page does not have is caught" do
      assert {:error, [_fault | _rest]} =
               CodeCheck.check(%{template: "x", state: [%{name: "roles", code: "roles()"}]})
    end
  end

  # PUBLISHING A DRAFT WRITES ITS FIELDS OVER THE LIVE PAGE, so a draft that did not carry `state`
  # would publish the page back to none.
  describe "a draft" do
    test "carries the page's state, and publishing it keeps the state", %{} do
      site = create_site!()
      master = create_user_with_permissions!(["*"])

      page =
        create_page!(site_id: site.id, template: "<p>x</p>", state: [%{name: "count", code: "3"}])

      {:ok, draft} =
        MishkaCmsCore.Runtime.PageBuilder.Drafts.save_as(
          "page",
          page,
          nil,
          "<p>Sitting</p>",
          master,
          nil,
          "Sitting",
          nil
        )

      assert pairs(draft.state) == [{"count", "3"}]

      draft
      |> Ash.Changeset.for_update(:publish, %{}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      published = Ash.get!(Page, page.id, action: :master_get, authorize?: false)

      assert published.template == "<p>Sitting</p>"

      assert pairs(published.state) == [{"count", "3"}]
    end
  end

  describe "the names a row may use" do
    setup do
      %{site: create_site!()}
    end

    defp save(site, state) do
      Page
      |> Ash.Changeset.for_create(
        :master_create,
        %{
          site_id: site.id,
          title: "State",
          path: "/state-#{System.unique_integer([:positive])}",
          template: "<p>x</p>",
          state: state
        },
        authorize?: false,
        context: %{page_code: :package}
      )
      |> Ash.create()
    end

    test "a free, well-formed name is stored", %{site: site} do
      assert {:ok, page} = save(site, [%{name: "count", code: "0"}])
      assert [%{name: "count", code: "0"}] = Enum.map(page.state, &Map.take(&1, [:name, :code]))
    end

    for name <- ["page", "flash", "csp_nonce", "current_user", "uploads"] do
      test "#{name} is refused: the runtime already sets it", %{site: site} do
        assert {:error, error} = save(site, [%{name: unquote(name), code: "0"}])
        assert Exception.message(error) =~ "already sets"
      end
    end

    for name <- ["Count", "1st", "my-count", "__count", ""] do
      test "#{inspect(name)} is refused: it is not an assign name", %{site: site} do
        assert {:error, _error} = save(site, [%{name: unquote(name), code: "0"}])
      end
    end

    test "a name given twice is refused", %{site: site} do
      assert {:error, error} =
               save(site, [%{name: "count", code: "0"}, %{name: "count", code: "1"}])

      assert Exception.message(error) =~ "twice"
    end
  end
end
