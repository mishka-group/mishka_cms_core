defmodule MishkaCmsCore.Runtime.Compilers.UserClosureTest do
  @moduledoc """
  Whether a page or a layout has any use for the signed-in user, answered once when it is compiled.

  Both directions cost something, and they do not cost the same:

    * a wrong yes is two queries on one page, every time a signed-in visitor opens it;
    * a wrong no is a signed-in visitor shown a page that believes nobody is signed in, in
      production, on a page that looked right in the editor.

  So the tests below pin the boundary from both sides: the record's own source naming the visitor,
  the record handing a component the assigns it would have to be handed to read one, and everything
  the walk cannot decide ending in a yes.

  Nothing here touches the database, and that is the point of the design rather than a convenience —
  the answer is read off the record being compiled and off nothing else, so it cannot be made stale
  by editing anything else. See `MishkaCmsWeb.PageCurrentUserTest`, which pins that end to end.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias MishkaCmsCore.Runtime.Compilers.UserClosure

  describe "the record's own source" do
    test "a page that names the visitor nowhere has no use for one" do
      refute UserClosure.reads_user?(%{template: ~S(<div>{@page.title}</div>)})
    end

    test "a template reading the assign, in either spelling" do
      assert UserClosure.reads_user?(%{template: ~S(<div>{@current_user}</div>)})
      assert UserClosure.reads_user?(%{template: ~S(<div :if={assigns[:current_user]}>hi</div>)})
    end

    test "a helper, an event and an info handler each count" do
      assert UserClosure.reads_user?(%{
               template: "<div>x</div>",
               helpers: [%{code: "socket.assigns.current_user"}]
             })

      assert UserClosure.reads_user?(%{
               template: "<div>x</div>",
               events: [%{name: "go", code: "socket.assigns[:current_user]"}]
             })

      assert UserClosure.reads_user?(%{
               template: "<div>x</div>",
               infos: [%{name: ":tick", code: "@current_user"}]
             })
    end

    test "a record that is not there at all is a yes" do
      assert UserClosure.reads_user?(nil)
    end
  end

  # A runtime component is handed only the assigns its call site writes, so naming one reaches
  # nothing on its own — what matters is whether the tag hands over something the visitor could be
  # inside. See the module's own documentation for why that is the whole question.
  describe "what a template hands to a component" do
    test "a component given nothing but literals reaches no visitor" do
      refute UserClosure.reads_user?(%{
               template: ~S(<.component component_name="card" site="Global" title="Hello" />)
             })
    end

    test "a component given the caller's whole assigns" do
      assert UserClosure.reads_user?(%{
               template: ~S(<.component component_name="card" site="Global" bag={assigns} />)
             })
    end

    test "a component given the socket, which carries the same map" do
      assert UserClosure.reads_user?(%{
               template: ~S(<.component component_name="card" site="Global" sock={@socket} />)
             })
    end

    test "an expression that carries neither is not enough" do
      refute UserClosure.reads_user?(%{
               template:
                 ~S(<.component component_name={@page.title} site="Global" id={@page.id} />)
             })
    end

    # A tag inside a helper's `~H` hands over exactly what one in the template does, and the helper
    # is compiled into the same module.
    test "a component named inside a helper counts too" do
      refute UserClosure.reads_user?(%{
               template: ~S|<div>{panel(assigns)}</div>|,
               helpers: [%{code: ~S|~H"<.component component_name="card" site="Global" />"|}]
             })

      assert UserClosure.reads_user?(%{
               template: ~S|<div>{panel(assigns)}</div>|,
               helpers: [%{code: ~S|~H"<.component component_name="card" bag={assigns} />"|}]
             })
    end

    # An ordinary tag is not a runtime component, and neither is a call to a page's own helper.
    test "only a <.component> tag is asked about" do
      refute UserClosure.reads_user?(%{
               template: ~S|<div id={assigns[:id]}>{panel(assigns)}</div>|
             })
    end
  end

  describe "everything it cannot decide" do
    # `{@attrs}` is a map built while the page renders, and the caller's assigns can be inside it.
    test "a component that spreads a map of attributes" do
      assert UserClosure.reads_user?(%{template: ~S(<div><.component {@attrs} /></div>)})
    end

    test "a template that cannot be tokenised" do
      assert UserClosure.reads_user?(%{template: ~S|<div class={paint(|})
    end
  end
end
