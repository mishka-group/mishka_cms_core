defmodule MishkaCmsCore.Runtime.PageUploadTest do
  @moduledoc """
  A page that accepts a file, from a declaration an author writes rather than Elixir.

  ## The gap this closes

  `allow_upload/3` is a `Phoenix.LiveView` function and the page compiler emitted no `mount/3`, so
  `@uploads` never existed on a compiled page. That left `chelekom-file-field`'s live mode — the one
  stateful capability the UI kit already shipped — with nothing to be handed, and a live component
  could not supply it either, because `allow_upload/3` is not one of a `Phoenix.LiveComponent`'s
  functions.

  ## What is driven here

  The real compiler builds the page module, a host LiveView mounts it the way
  `MishkaCmsWeb.RuntimeLive` does — `PageUpload.allow/2` after the module is assigned, then the
  page's own `render/1` and `handle_event/3` — and `Phoenix.LiveViewTest`'s `file_input/4` and
  `render_upload/2` push a real file through the real channel. The submit goes through
  `MishkaCmsCore.Runtime.PageForm.submit/5`, the same path a visitor's press of the button takes,
  and the file is then read off disk.

  ## Why a host and not the page module itself

  A compiled page is not a LiveView: it supplies `render/1` and `handle_event/3` to one.
  `MishkaCmsWeb.RuntimeLive` is that one and lives in the host application, out of this suite's
  reach, so `Host` below is the same three lines of it that matter here — and it calls exactly the
  function RuntimeLive calls, rather than a test-only path.

  `<.live_file_input upload={@uploads.attachment} />` is written out rather than drawn through
  `chelekom-file-field` because installing a 136-component kit to reach one tag would make this a
  test of the installer. It is the exact call the kit's live branch makes.

  `async: false` — the destination directory is application config.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.Compilers.ModuleCompiler
  alias MishkaCmsCore.Runtime.PageUpload
  alias MishkaCmsCore.Test.Plugins.PageFormDestination
  alias MishkaInstaller.Event.{Event, EventHandler}

  @moduletag :integration

  @template """
  <main>
    <.form
      :let={f}
      for={assigns[:attach_form]}
      as={:attach}
      id="attach-form"
      phx-change="attach_validate"
      phx-submit="attach_submit"
      data-success="Got it."
    >
      <.input field={f[:note]} type="text" label="Note" />
      <.live_file_input upload={@uploads.attachment} />
      <button type="submit">Send</button>
    </.form>
  </main>
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "page_upload_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:mishka_cms_core, :page_upload_dir, dir)

    on_exit(fn ->
      Application.delete_env(:mishka_cms_core, :page_upload_dir)
      File.rm_rf(dir)
    end)

    site_id = Ecto.UUID.generate()
    %{dir: dir, site_id: site_id, forms: Path.join([dir, site_id, "forms"])}
  end

  defp compile!(uploads, template \\ @template) do
    module = :"Elixir.PageUploadPage#{System.unique_integer([:positive])}"

    ast =
      LiveViewCompiler.build_module(%{
        title: "Attach",
        page_module: module,
        template: template,
        events: [],
        uploads: uploads
      })

    {:ok, ^module, _diagnostics} = ModuleCompiler.compile_module(ast)
    module
  end

  defmodule Host do
    use Phoenix.LiveView

    # The lines of `MishkaCmsWeb.RuntimeLive` this test is about: assign the site and the page
    # module, register whatever it declares, then let it draw itself and answer its own events.
    def mount(_params, session, socket) do
      page_module = session["page_module"]

      {:ok,
       socket
       |> Phoenix.Component.assign(
         current_site: session["current_site"],
         page_module: page_module
       )
       |> MishkaCmsCore.Runtime.PageUpload.allow(page_module)}
    end

    def render(assigns), do: assigns.page_module.render(assigns)

    def handle_event(name, params, socket),
      do: socket.assigns.page_module.handle_event(name, params, socket)
  end

  defp mount!(module, site_id) do
    site = site_id && %{id: site_id}

    live_isolated(Phoenix.ConnTest.build_conn(), Host,
      session: %{"page_module" => module, "current_site" => site}
    )
  end

  defp register(module) do
    {:ok, _} =
      Event.write(%{
        name: module,
        event: "page:form:submitted",
        extension: :mishka_installer,
        status: :started
      })

    :ok = EventHandler.do_compile("page:form:submitted", :start, false)
    on_exit(fn -> Event.unregister(:name, module, false) end)
  end

  describe "what the compiler wrote onto the page" do
    test "a declaration becomes an entry on __page_uploads__/0" do
      module = compile!([%{"name" => "attachment", "accept" => "image/*", "max_entries" => 2}])

      assert [%{name: :attachment, accept: "image/*", max_entries: 2}] = module.__page_uploads__()
    end

    # A NAME IS THE ONE THING A DECLARATION CANNOT DO WITHOUT, and a page is saved from a form where
    # a half-filled row is one keystroke away.
    test "a declaration with no usable name is dropped rather than compiled" do
      module =
        compile!([
          %{"name" => "  "},
          %{"accept" => "image/*"},
          %{"name" => "kept"}
        ])

      assert [%{name: :kept}] = module.__page_uploads__()
    end

    # `allow_upload/3` RAISES on a name already registered, which would take the whole page down on
    # mount rather than the one row that was written twice.
    test "two declarations of the same name keep the first" do
      module = compile!([%{"name" => "doc", "max_entries" => 3}, %{"name" => "doc"}])

      assert [%{name: :doc, max_entries: 3}] = module.__page_uploads__()
    end

    test "a page that declares nothing still answers, and registers nothing" do
      module = compile!([], "<main>nothing here</main>")

      assert module.__page_uploads__() == []
      assert {:ok, _view, html} = mount!(module, Ecto.UUID.generate())
      assert html =~ "nothing here"
    end
  end

  # A PUBLISHED PAGE IS A FORM ANYBODY CAN POST TO. What a declaration says about size and count is
  # a request, and the ceilings are not the author's to raise.
  describe "the ceilings" do
    test "a declaration asking for more than a public page may have is clamped" do
      %{entries: entries, file_size: file_size} = PageUpload.ceilings()

      opts = PageUpload.options(%{max_entries: 5000, max_file_size: 2_000_000_000})

      assert opts[:max_entries] == entries
      assert opts[:max_file_size] == file_size
    end

    test "a declaration asking for less than the ceiling gets what it asked for" do
      opts = PageUpload.options(%{max_entries: 2, max_file_size: 1_000_000})

      assert opts[:max_entries] == 2
      assert opts[:max_file_size] == 1_000_000
    end

    test "a declaration that says nothing gets one file and a sane size" do
      opts = PageUpload.options(%{})

      assert opts[:max_entries] == 1
      assert opts[:max_file_size] > 0
      assert opts[:accept] == :any
      assert opts[:auto_upload] == false
    end

    test "accept is split the way allow_upload/3 wants it" do
      assert PageUpload.options(%{accept: "image/*, .pdf"})[:accept] == ["image/*", ".pdf"]
      assert PageUpload.options(%{accept: ""})[:accept] == :any
    end
  end

  describe "a page that accepts a file" do
    test "registers the upload and renders a live file input", %{site_id: site_id} do
      {:ok, _view, html} = mount!(compile!([%{"name" => "attachment"}]), site_id)

      assert html =~ "phx-hook=\"Phoenix.LiveFileUpload\"",
             "the page did not render a live file input — @uploads was not registered"
    end

    # THE ROUND TRIP. Not "the socket has an UploadConfig" but a file that went up the channel, was
    # consumed on submit, and can be read back off disk in its site's own folder.
    test "takes a file up the channel and stores it in its site's folder on submit", %{
      site_id: site_id,
      forms: forms
    } do
      {:ok, view, _html} =
        mount!(compile!([%{"name" => "attachment", "accept" => ".txt"}]), site_id)

      file =
        file_input(view, "#attach-form", :attachment, [
          %{name: "notes.txt", content: "the file a visitor attached", type: "text/plain"}
        ])

      assert render_upload(file, "notes.txt") =~ "attach-form"

      html =
        view
        |> element("#attach-form")
        |> render_submit(%{"attach" => %{"note" => "with a file"}})

      assert html =~ "Got it.", "the submit was not accepted"

      assert [stored] = File.ls!(forms)
      assert File.read!(Path.join(forms, stored)) == "the file a visitor attached"

      assert String.ends_with?(stored, ".txt"),
             "the extension came from the entry's declared type"
    end

    # THE CLIENT'S NAME IS NEVER PART OF THE PATH. It is visitor input that would become a filename,
    # which is where `../../etc/passwd` gets in.
    test "a visitor's filename does not reach the filesystem", %{site_id: site_id, forms: forms} do
      {:ok, view, _html} = mount!(compile!([%{"name" => "attachment"}]), site_id)

      file =
        file_input(view, "#attach-form", :attachment, [
          %{
            name: "../../../../../../tmp/escaped.txt",
            content: "nope",
            type: "text/plain"
          }
        ])

      render_upload(file, "../../../../../../tmp/escaped.txt")

      view |> element("#attach-form") |> render_submit(%{"attach" => %{"note" => "x"}})

      assert [stored] = File.ls!(forms)
      refute stored =~ "escaped"
      refute stored =~ ".."
      refute File.exists?("/tmp/escaped.txt")
    end

    # THE DESCRIPTOR TRAVELS WITH WHAT WAS TYPED, read off the submission a receiving plugin is
    # handed. With nothing receiving it the log names the fields only, never what the visitor sent.
    test "the file travels with what was typed, as one submission", %{site_id: site_id} do
      register(PageFormDestination)
      Process.register(self(), PageFormDestination.probe())
      module = compile!([%{"name" => "attachment"}])
      {:ok, view, _html} = mount!(module, site_id)

      file =
        file_input(view, "#attach-form", :attachment, [
          %{name: "cv.txt", content: "hello", type: "text/plain"}
        ])

      render_upload(file, "cv.txt")

      view
      |> element("#attach-form")
      |> render_submit(%{"attach" => %{"note" => "read this"}})

      assert_receive {:page_form_submitted, %{values: values}}
      assert values.note == "read this"

      assert [%{"name" => "cv.txt", "type" => "text/plain", "size" => 5, "url" => url}] =
               values.attachment

      assert String.starts_with?(url, "/uploads/#{site_id}/forms/")
    end

    test "with nothing receiving a submission, the log names its fields and not what was typed",
         %{
           site_id: site_id
         } do
      module = compile!([%{"name" => "attachment"}])
      {:ok, view, _html} = mount!(module, site_id)

      file =
        file_input(view, "#attach-form", :attachment, [
          %{name: "cv.txt", content: "hello", type: "text/plain"}
        ])

      render_upload(file, "cv.txt")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          view
          |> element("#attach-form")
          |> render_submit(%{"attach" => %{"note" => "read this"}})
        end)

      assert log =~ "fields: note, attachment"
      refute log =~ "read this"
      refute log =~ "cv.txt"
    end

    test "a page with no site stores nothing", %{dir: dir} do
      {:ok, view, _html} = mount!(compile!([%{"name" => "attachment"}]), nil)

      file =
        file_input(view, "#attach-form", :attachment, [
          %{name: "cv.txt", content: "hello", type: "text/plain"}
        ])

      render_upload(file, "cv.txt")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          view |> element("#attach-form") |> render_submit(%{"attach" => %{"note" => "x"}})
        end)

      assert File.ls!(dir) == []
      assert log =~ "was not stored: the page has no site"
    end
  end
end
