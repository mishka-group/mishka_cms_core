defmodule MishkaCmsCoreWeb.Runtime.PreviewStateTest do
  @moduledoc """
  The inspector modal's state machine, without a browser or a database.

  Every assertion here is about ONE property: nothing in the modal does work before somebody asks
  for it, and nothing the reader has already asked for is thrown away by work that finishes later.
  The second half is the one that bites — `build/3` returns a map based on the empty shape, so a key
  set by the click that opened the modal is lost unless `loaded/2` carries it across. It happened to
  `active_tab` once and to `config_mounted?` again, and the symptom both times was a tab that opened
  onto nothing.

  See `MishkaCmsCoreWeb.Test.RuntimeInspectorModalTest` for the same behaviour through the real page.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveViewTest

  alias MishkaCmsCoreWeb.Live.Admin.Components.RuntimePreviewModal
  alias MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers

  alias MishkaCmsCore.Runtime.{Component, ErrorPage, JsHook, Layout, Page, Stylesheet}

  # Merged onto the real shape rather than a copy of it: a copy goes stale the moment a key is added
  # to the modal, and fails as a `KeyError` from the template instead of as a behaviour.
  defp preview(overrides \\ %{}), do: Map.merge(PreviewHelpers.empty(), Map.new(overrides))

  # `:flash` is a reserved assign, so it is seeded on the struct rather than through `assign/3` —
  # these helpers report through `put_flash/3`, and a socket without the key raises before the
  # behaviour under test is reached.
  defp socket(overrides \\ %{}) do
    %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
    |> assign(:preview, preview(overrides))
  end

  describe "which resources are edited in the modal" do
    test "all six of them" do
      for resource <- [Component, Layout, Page, ErrorPage, JsHook, Stylesheet] do
        assert PreviewHelpers.has_config?(resource),
               "#{inspect(resource)} has no Configuration tab, so its table needs a second form modal"
      end
    end
  end

  describe "the tab bar" do
    test "a module-backed record is previewable and configurable" do
      html =
        render_component(&RuntimePreviewModal.modal/1, preview: preview(%{has_config?: true}))

      assert html =~ "Configuration"
      assert html =~ "Preview"
    end

    # A JS hook and a stylesheet are code, not a page: there is nothing to render in a frame, but
    # there IS a compile pipeline (their Oban jobs → the per-site bundle) and a form.
    test "a code asset is configurable but has nothing to preview" do
      html =
        render_component(&RuntimePreviewModal.modal/1,
          preview: preview(%{resource: JsHook, has_config?: true})
        )

      assert html =~ "Configuration"
      assert html =~ "Pipeline"
      refute html =~ ">Preview<"
    end
  end

  # "+ Add" opens the same modal with no record behind it, and it used to be titled "Preview" — the
  # one thing that screen is not.
  describe "the modal's title" do
    test "names the record when there is one" do
      html =
        render_component(&RuntimePreviewModal.modal/1,
          preview:
            preview(%{
              active_tab: "pipeline",
              record: %{id: "r", name: "checkout-button", path: "/x"}
            })
        )

      assert html =~ "checkout-button"
    end

    test "and names what is being created when there is not" do
      html =
        render_component(&RuntimePreviewModal.modal/1,
          preview: preview(%{resource: Layout, has_config?: true, active_tab: "configuration"})
        )

      assert html =~ "New Layout"
      refute html =~ ">Preview<"
    end

    test "and says so while the record is still being read" do
      html =
        render_component(&RuntimePreviewModal.modal/1,
          preview: preview(%{resource: Page, loading?: true, has_config?: true})
        )

      assert html =~ "Loading…"
    end
  end

  describe "the Configuration form" do
    test "is not mounted by opening the modal on another tab" do
      html =
        render_component(&RuntimePreviewModal.modal/1, preview: preview(%{has_config?: true}))

      refute html =~ "-form-wrapper",
             "the form mounted itself for a reader who only opened the inspector"
    end

    test "is mounted by visiting its tab" do
      after_click = PreviewHelpers.set_tab(socket(%{has_config?: true}), "configuration")

      assert after_click.assigns.preview.config_mounted?
    end

    test "and staying away from it does not mount it" do
      for tab <- ["overview", "preview", "code", "versions", "pipeline"] do
        refute PreviewHelpers.set_tab(socket(), tab).assigns.preview.config_mounted?,
               "the #{tab} tab mounted the edit form"
      end
    end

    # THE RECORD ARRIVES AFTER THE CLICK. The pencil opens straight on Configuration and the record
    # read is still in flight; when it lands, `build/3`'s empty-based map must not undo what the
    # click chose. Losing this mounted the form for the length of exactly one render.
    test "survives the record load landing underneath it" do
      loaded =
        %{has_config?: true, config_mounted?: true, active_tab: "configuration"}
        |> socket()
        |> PreviewHelpers.loaded({:ok, preview(%{record: %{id: "r"}, has_config?: true})})

      assert loaded.assigns.preview.config_mounted?,
             "the record load unmounted the form the pencil had just opened"

      assert loaded.assigns.preview.active_tab == "configuration"
    end
  end

  describe "the Versions tab" do
    test "reports itself loading rather than freezing the modal" do
      html =
        render_component(&RuntimePreviewModal.modal/1,
          preview:
            preview(%{
              active_tab: "versions",
              record: %{id: "r", name: "probe", path: "/p"},
              versions_loading?: true
            })
        )

      assert html =~ "animate-spin"
    end

    test "a landed page replaces the list and clears the flag" do
      landed =
        %{versions_loading?: true}
        |> socket()
        |> PreviewHelpers.versions_loaded(
          {:ok, {:versions, [:v1, :v2], 7, MapSet.new(["m"]), 2, nil}}
        )

      assert landed.assigns.preview.versions == [:v1, :v2]
      assert landed.assigns.preview.versions_total == 7
      assert landed.assigns.preview.version_masters == MapSet.new(["m"])
      assert landed.assigns.preview.versions_page == 2
      refute landed.assigns.preview.versions_loading?
    end

    test "a restore reports what happened" do
      restored =
        %{versions_loading?: true}
        |> socket()
        |> PreviewHelpers.versions_loaded(
          {:ok, {:versions, [], 0, MapSet.new(), 1, {:info, "Version restored."}}}
        )

      assert restored.assigns.flash == %{"info" => "Version restored."}
    end

    test "and a crashed read says so instead of leaving a spinner forever" do
      crashed =
        %{versions_loading?: true}
        |> socket()
        |> PreviewHelpers.versions_loaded({:exit, :boom})

      refute crashed.assigns.preview.versions_loading?
      assert crashed.assigns.flash == %{"error" => "Could not load the version history."}
    end
  end

  describe "Force compile" do
    test "is offered only where it can act" do
      offered =
        render_component(&RuntimePreviewModal.modal/1,
          preview: preview(%{force_compilable?: true})
        )

      refute render_component(&RuntimePreviewModal.modal/1, preview: preview()) =~ "Force compile"

      assert offered =~ "Force compile"
    end

    test "says so while it runs" do
      html =
        render_component(&RuntimePreviewModal.modal/1,
          preview: preview(%{force_compilable?: true, compiling?: true})
        )

      assert html =~ "Compiling…"
      assert html =~ "disabled"
    end

    # A RUNTIME MODULE HAS NO NAME THE READER KNOWS: it is `Runtime.<md5>.Component`, which
    # `inspect/1` renders as a quoted atom. The message names the kind of record instead, and the
    # Pipeline tab beside it spells the module out for anyone who wants it.
    test "a finished compile reports in the reader's terms, not the VM's" do
      done =
        %{compiling?: true}
        |> socket()
        |> PreviewHelpers.compiled({:ok, {:compiled, {:ok, SomeRuntime.Module}}})

      refute done.assigns.preview.compiling?
      assert done.assigns.flash["info"] =~ "loaded in RAM"
      refute done.assigns.flash["info"] =~ "Elixir."
    end

    # A COMPILE FAILURE IS THE POINT, NOT AN ACCIDENT. The reason the button exists is to find out
    # now rather than when a visitor does, so the reason has to reach the reader intact.
    test "a failed one reports the reason it failed" do
      failed =
        %{compiling?: true}
        |> socket()
        |> PreviewHelpers.compiled(
          {:ok, {:compiled, {:error, {:compilation_error, "undefined x"}}}}
        )

      refute failed.assigns.preview.compiling?
      assert failed.assigns.flash["error"] =~ "undefined x"
    end

    test "and a crashed one leaves no spinner behind" do
      crashed = socket(%{compiling?: true}) |> PreviewHelpers.compiled({:exit, :killed})

      refute crashed.assigns.preview.compiling?
      assert crashed.assigns.flash["error"] =~ "did not finish"
    end
  end

  describe "Duplicate" do
    @source %{id: "source-id", name: "chelekom-badge"}
    @copy %Component{name: "chelekom-badge-copy-abcd", extra: %{"copied_from" => "source-id"}}

    defp waiting,
      do: %{resource: Component, record: @source, duplicable?: true, duplicating?: true}

    test "a copy closes the modal it was asked from" do
      done = waiting() |> socket() |> PreviewHelpers.duplicated({:ok, {:ok, @copy}})

      assert done.assigns.preview == PreviewHelpers.empty()
      assert done.assigns.flash["info"] == "Duplicated as “chelekom-badge-copy-abcd”"
    end

    # THE COPY OUTLIVES THE MODAL. Closing it does not stop the write, so by the time the copy lands
    # the reader may have closed the modal, opened another record, or reopened this one — and none of
    # those is the modal that asked.
    test "and no modal opened since" do
      for opened <- [
            %{},
            %{resource: Component, record: %{id: "another-id"}, duplicable?: true},
            %{resource: Component, record: %{id: "another-id"}, duplicating?: true},
            %{resource: Component, record: @source, duplicable?: true}
          ] do
        done = opened |> socket() |> PreviewHelpers.duplicated({:ok, {:ok, @copy}})

        assert done.assigns.preview == preview(opened)
        assert done.assigns.flash["info"] == "Duplicated as “chelekom-badge-copy-abcd”"
      end
    end

    # Only the resource's own refusal carries a message written for the reader; any other gets a
    # plain sentence rather than an inspected term.
    test "any other refusal keeps the modal open and says so" do
      for refusal <- [:out_of_scope, Ash.Error.Forbidden.exception([])] do
        refused = waiting() |> socket() |> PreviewHelpers.duplicated({:ok, {:error, refusal}})

        assert refused.assigns.preview == preview(%{waiting() | duplicating?: false})
        assert refused.assigns.flash["error"] == "Could not duplicate this component."
      end
    end

    test "a crashed one keeps the modal open and leaves no spinner behind" do
      crashed = waiting() |> socket() |> PreviewHelpers.duplicated({:exit, :killed})

      assert crashed.assigns.preview == preview(%{waiting() | duplicating?: false})
      assert crashed.assigns.flash["error"] == "The duplicate did not finish."
    end
  end
end
