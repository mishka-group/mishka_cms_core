defmodule MishkaCmsCore.Builder.SectionSeamsTest do
  @moduledoc """
  The sections of the editor that had no seam, each driven by a registered plugin.

  Every test here registers a real `MishkaInstaller` plugin and compiles the event, because that is
  the only way to tell a working seam from a declared one: without a plugin listening, an event that
  fires and an event that does not are indistinguishable — both return the value unchanged.

  The last describe is the one that matters most in practice. A plugin nobody in this project wrote
  will raise one day, and when it does the editor must keep working with the value it already had.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Builder.Events
  alias MishkaCmsCore.Runtime.PageBuilder.Fields
  alias MishkaCmsCore.Runtime.PageComment

  alias MishkaCmsCore.Test.Plugins.{
    BuilderBrokenSeam,
    BuilderCommentGate,
    BuilderFormRolePlugin,
    BuilderHistoryScope,
    BuilderPreviewStamp
  }

  alias MishkaInstaller.Event.{Event, EventHandler}

  @moduletag :integration

  defp register(module, event) do
    {:ok, _} =
      Event.write(%{
        name: module,
        event: event,
        extension: :mishka_installer,
        status: :started
      })

    :ok = EventHandler.do_compile(event, :start, false)
    on_exit(fn -> Event.unregister(:name, module, false) end)
    :ok
  end

  describe "the review composer's gate" do
    setup do: register(BuilderCommentGate, "builder:review:before_comment")

    test "a plugin's house rule refuses the note, in its own words" do
      assert PageComment.refuse(%{"body" => BuilderCommentGate.refused(), "type" => "bug"}) =~
               "Say what needs doing"
    end

    test "and a note it is happy with still saves" do
      assert PageComment.refuse(%{"body" => "The gap is wrong here.", "type" => "bug"}) == nil
    end

    # The core's own rules run first, so a plugin never sees a blank note and cannot be the reason
    # one is refused — which keeps the message the author reads the most specific true one.
    test "the core's rules still come first" do
      assert PageComment.refuse(%{"body" => "  ", "type" => "bug"}) == "Write something first."
    end
  end

  describe "a component's part in a form" do
    setup do: register(BuilderFormRolePlugin, "builder:form:role")

    defp plugin_entry(extra \\ %{}) do
      Map.merge(
        %{
          name: BuilderFormRolePlugin.prefix() <> "send",
          attrs: [],
          template: ~S(<a class="btn">Send</a>)
        },
        extra
      )
    end

    test "a plugin can name a role the markup does not show" do
      assert Fields.role(plugin_entry()) == :submit
    end

    test "and the memo the editor reads carries it" do
      node = %MishkaCmsCore.Runtime.PageBuilder.Tree.Node{
        id: "n00000001",
        kind: :component,
        tag: ".component",
        attrs: [{"component_name", {:string, plugin_entry().name}}]
      }

      assert Fields.roles([node], [plugin_entry()]) == %{plugin_entry().name => :submit}
    end

    test "but never over a kit's own declaration" do
      assert Fields.role(plugin_entry(%{form: %{"role" => "wrapper"}})) == :wrapper
    end

    test "and components it does not answer for keep what their markup says" do
      assert Fields.role(%{name: "acme-card", attrs: [], template: ~S(<div>card</div>)}) == :none

      assert Fields.role(%{name: "acme-go", attrs: [], template: ~S(<button>Go</button>)}) ==
               :submit
    end

    test "an answer that is not a role leaves the inferred one" do
      entry = %{
        name: BuilderFormRolePlugin.bogus() <> "go",
        attrs: [],
        template: ~S(<button>Go</button>)
      }

      assert Fields.role(entry) == :submit
    end
  end

  describe "the preview document" do
    setup do: register(BuilderPreviewStamp, "builder:preview:document")

    test "a plugin can put something of its own inside it" do
      assert Events.preview_document("<main>page</main>", %{resource: nil}) =~
               BuilderPreviewStamp.marker()
    end

    test "and the document it was given is still all there" do
      assert Events.preview_document("<main>page</main>", %{resource: nil}) =~ "<main>page</main>"
    end
  end

  describe "the history timeline's read" do
    setup do: register(BuilderHistoryScope, "builder:history:query")

    test "a plugin can narrow it, and the sheet still pages honestly" do
      query = Ash.Query.new(MishkaCmsCore.Runtime.PageBuilderEvent)

      scoped = Events.history_query(query, %{source_type: :page, source_id: nil, branch_id: nil})

      assert %Ash.Query{} = scoped
      assert inspect(scoped.filter) =~ "kind"
    end

    test "and a plugin that answers with something else leaves the read alone" do
      query = Ash.Query.new(MishkaCmsCore.Runtime.PageBuilderEvent)

      assert Events.history_query(query, %{source_type: nil, source_id: nil, branch_id: nil})
    end
  end

  describe "a plugin that is simply broken" do
    setup do: register(BuilderBrokenSeam, "builder:preset:choices")

    # The editor's own answer survives, so the section it was heading for still draws. The author of
    # the plugin sees the crash in their logs, which is where a bug in their code belongs.
    test "does not take the section down with it" do
      choices = %{"variant" => ["default", "outline"]}

      assert Events.preset_choices(choices, %{site_id: nil}) == choices
    end

    test "and the editor keeps working afterwards" do
      Events.preset_choices(%{"a" => ["1"]}, %{site_id: nil})

      assert Events.preset_choices(%{"b" => ["2"]}, %{site_id: nil}) == %{"b" => ["2"]}
    end
  end
end
