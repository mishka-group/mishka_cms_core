defmodule MishkaCmsCore.Runtime.StatefulShapeTest do
  @moduledoc """
  A component that says it keeps state and is shaped so that it cannot.

  Both of these compiled quietly and failed later, somewhere the author could not connect to what
  they did — which is the shape of failure this whole feature has been trying to avoid.

    * **`extra.clauses`** — 34 of the kit's installed components dispatch through them, and the
      stateful emitter reads the template and never the clause list. The clauses were silently
      DISCARDED: a component that rendered only its base branch, with nothing said anywhere.
    * **a name LiveView owns** — `Phoenix.Component`'s `@non_assignables` is
      `[:uploads, :streams, :socket, :myself]`, it refuses `:flash` in a clause of its own, and
      assigning any of the five raises. A function component gets away with declaring one because
      nothing ever assigns it; a live component does not, whether the name is an attr or a slot, and
      the raise arrives inside a visitor's LiveView.

  Refused in three places for three different callers: the action boundary (an author, the API, a
  seed), `UiKit.Contract` (a kit bundle, where a raise inside the install transaction costs every
  other component), and the compiler itself (a row stored before any of this existed).
  """
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.Compilers.ComponentCompiler
  alias MishkaCmsCore.UiKit.Contract

  @moduletag :integration

  defp create(site, attrs) do
    Component
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{name: "shaped", template: "<div id={@id}>x</div>"}, attrs),
      tenant: site.id,
      context: %{page_code: :package}
    )
    |> Ash.create(authorize?: false)
  end

  describe "a live component that dispatches through clauses" do
    test "is refused, and told why" do
      site = create_site!()

      assert {:error, error} =
               create(site, %{stateful: true, extra: %{"clauses" => [%{"match" => "%{}"}]}})

      message = Exception.message(error)
      assert message =~ "clauses"
      assert message =~ "exactly one"
    end

    test "and a function component with clauses is not" do
      site = create_site!()

      assert {:ok, _component} = create(site, %{extra: %{"clauses" => [%{"match" => "%{}"}]}})
    end

    # THE COMPILER REFUSES IT TOO, for a row written before the validation existed. It used to
    # flatten: `build_stateful_function/1` never reads the clause list, so the component compiled
    # and rendered only its base branch.
    test "and the compiler refuses it rather than flattening it" do
      assert_raise ArgumentError, ~r/clauses/, fn ->
        ComponentCompiler.build_module(%{
          id: Ash.UUID.generate(),
          title: "flattened",
          component_module: Module.concat([__MODULE__, "F"]),
          site: "Global",
          template: "<div id={@id}>x</div>",
          attrs: [],
          slots: [],
          helpers: [],
          stateful: true,
          clauses: [%{match: "%{}"}]
        })
      end
    end

    # AND A KIT BUNDLE IS REFUSED AT THE CONTRACT, before the transaction every other component in
    # the kit is created inside.
    test "and a bundle carrying one loses that component and no other" do
      {kept, rejected} =
        Contract.partition([
          %{"name" => "acme-fine", "template" => "<div></div>"},
          %{
            "name" => "acme-live-clauses",
            "template" => "<div></div>",
            "stateful" => true,
            "extra" => %{"clauses" => [%{"match" => "%{}"}]}
          }
        ])

      assert Enum.map(kept, & &1["name"]) == ["acme-fine"]
      assert [{"acme-live-clauses", _reason}] = rejected
    end
  end

  describe "a live component declaring a name LiveView owns" do
    test "is refused for each of the five" do
      for name <- ~w(uploads streams socket myself flash) do
        site = create_site!()

        assert {:error, error} =
                 create(site, %{
                   stateful: true,
                   attrs: [%{"name" => name, "type" => "any", "opts" => %{}}]
                 }),
               "#{name} was accepted on a live component"

        assert Exception.message(error) =~ name
      end
    end

    # A SLOT IS ASSIGNED UNDER ITS NAME TOO, so it is the same refusal.
    test "is refused as a slot as well" do
      site = create_site!()

      assert {:error, error} =
               create(site, %{stateful: true, slots: [%{"name" => "streams", "opts" => %{}}]})

      assert Exception.message(error) =~ "cannot declare streams"
    end

    # A WRITE THAT MOVES ONLY THE SLOTS is a write that changed the declarations, so it is checked.
    test "and a slot added to one that is already live is refused" do
      site = create_site!()
      {:ok, component} = create(site, %{stateful: true})

      assert {:error, error} =
               component
               |> Ash.Changeset.for_update(
                 :update,
                 %{slots: [%{"name" => "streams", "opts" => %{}}]},
                 tenant: site.id
               )
               |> Ash.update(authorize?: false)

      assert Exception.message(error) =~ "cannot declare streams"
    end

    # THE COMPILER REFUSES IT TOO, for a row written around the action or before the validation
    # existed. It used to compile: the root probe never assigns, so the raise waited for `assign`
    # inside a visitor's LiveView.
    test "and the compiler refuses it rather than compiling it" do
      for name <- ~w(uploads streams socket myself flash),
          {attrs, slots} <- [
            {[%{name: name, type: "any", opts: []}], []},
            {[], [%{name: name, opts: []}]}
          ] do
        assert_raise ArgumentError, ~r/declares #{name}\./, fn ->
          ComponentCompiler.build_module(%{
            id: Ash.UUID.generate(),
            title: "reserved",
            component_module: Module.concat([__MODULE__, "R"]),
            site: "Global",
            template: "<div id={@id}>x</div>",
            attrs: attrs,
            slots: slots,
            helpers: [],
            stateful: true
          })
        end
      end
    end

    test "and the compiler still builds a function component declaring it" do
      assert {:defmodule, _meta, _module} =
               ComponentCompiler.build_module(%{
                 id: Ash.UUID.generate(),
                 title: "reserved",
                 component_module: Module.concat([__MODULE__, "S"]),
                 site: "Global",
                 template: "<div>x</div>",
                 attrs: [%{name: "uploads", type: "any", opts: []}],
                 slots: [],
                 helpers: [],
                 stateful: false
               })
    end

    # A FUNCTION COMPONENT MAY, and one does: `chelekom-file-field` declares `attr :uploads`. It is
    # also why that component can never be stateful, which is correct anyway — `allow_upload/3` is a
    # `Phoenix.LiveView` function a LiveComponent cannot call.
    test "and a function component may declare it" do
      site = create_site!()

      assert {:ok, _component} =
               create(site, %{attrs: [%{"name" => "uploads", "type" => "any", "opts" => %{}}]})
    end

    test "and a bundle carrying one loses that component" do
      {kept, rejected} =
        Contract.partition([
          %{
            "name" => "acme-live-socket",
            "template" => "<div></div>",
            "stateful" => true,
            "attrs" => [%{"name" => "socket", "type" => "any"}]
          },
          %{
            "name" => "acme-live-flash",
            "template" => "<div></div>",
            "stateful" => true,
            "attrs" => [%{"name" => "flash", "type" => "any"}]
          },
          %{
            "name" => "acme-live-streams-slot",
            "template" => "<div></div>",
            "stateful" => true,
            "slots" => [%{"name" => "streams"}]
          }
        ])

      assert kept == []

      assert [
               {"acme-live-socket", _socket},
               {"acme-live-flash", _flash},
               {"acme-live-streams-slot", _streams}
             ] = rejected
    end
  end

  # A WRITE THAT MOVES NEITHER must not be refused because of a row somebody stored before this
  # rule — otherwise the author is locked out of the screen the shape gets fixed in.
  describe "a write that touches neither" do
    test "is left alone" do
      site = create_site!()
      {:ok, component} = create(site, %{stateful: true})

      assert {:ok, _renamed} =
               component
               |> Ash.Changeset.for_update(:update, %{description: "still editable"},
                 tenant: site.id
               )
               |> Ash.update(authorize?: false)
    end
  end
end
