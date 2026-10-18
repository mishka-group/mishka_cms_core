# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

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

  import MishkaCmsCore.Test.Factory
  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.Compilers.ModuleCompiler
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.PageUpload
  alias MishkaCmsCore.Runtime.ShareCard
  alias MishkaCmsCore.Test.Files
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

  defp attachment(accept), do: %{"name" => "attachment", "accept" => accept}

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
          %{"name" => "  ", "accept" => ".txt"},
          %{"accept" => "image/*"},
          %{"name" => "kept", "accept" => ".txt"}
        ])

      assert [%{name: :kept}] = module.__page_uploads__()
    end

    # `allow_upload/3` RAISES on a name already registered, which would take the whole page down on
    # mount rather than the one row that was written twice.
    test "two declarations of the same name keep the first" do
      module =
        compile!([
          %{"name" => "doc", "accept" => ".txt", "max_entries" => 3},
          %{"name" => "doc", "accept" => ".pdf"}
        ])

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
      assert opts[:accept] == []
      assert opts[:auto_upload] == false
    end

    test "accept is read against what a visitor may upload, as dotted extensions" do
      assert PageUpload.options(%{accept: "image/*, .pdf"})[:accept] ==
               [".png", ".jpg", ".jpeg", ".gif", ".webp", ".pdf"]

      assert PageUpload.options(%{accept: ["application/pdf", ".CSV"]})[:accept] == [
               ".pdf",
               ".csv"
             ]

      assert PageUpload.options(%{accept: ""})[:accept] == []
    end
  end

  describe "a page that accepts a file" do
    test "registers the upload and renders a live file input", %{site_id: site_id} do
      {:ok, _view, html} = mount!(compile!([attachment(".txt")]), site_id)

      assert html =~ "phx-hook=\"Phoenix.LiveFileUpload\"",
             "the page did not render a live file input — @uploads was not registered"
    end

    # THE ROUND TRIP. Not "the socket has an UploadConfig" but a file that went up the channel, was
    # consumed on submit, and can be read back off disk in its site's own folder.
    test "takes a file up the channel and stores it in its site's folder on submit", %{
      site_id: site_id,
      forms: forms
    } do
      {:ok, view, _html} = mount!(compile!([attachment(".txt")]), site_id)

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
      {:ok, view, _html} = mount!(compile!([attachment(".txt")]), site_id)

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
      module = compile!([attachment(".txt")])
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
      module = compile!([attachment(".txt")])
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
      {:ok, view, _html} = mount!(compile!([attachment(".txt")]), nil)

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

  # A VISITOR'S FILE IS SERVED BACK FROM THE SITE'S OWN ORIGIN, so what is stored has to be what the
  # declaration says it is: an HTML or SVG file given a picture's name and type is a script that runs
  # with the session of whoever opens its link.
  describe "what a declaration may take" do
    test "accept is required: a declaration without a usable one is not compiled" do
      module =
        compile!([
          %{"name" => "none"},
          %{"name" => "blank", "accept" => " , "},
          %{"name" => "markup", "accept" => "image/svg+xml, .html, .svg, .xml, .js"},
          %{"name" => "anything", "accept" => "*/*"},
          %{"name" => "kept", "accept" => ".svg, .png"}
        ])

      assert [%{name: :kept}] = module.__page_uploads__()
    end

    test "HTML, SVG, XML and script files are never among the types a visitor may upload" do
      for extension <- ~w(html htm xhtml svg svgz xml js mjs php exe sh) do
        refute extension in PageUpload.allowed_types(), "#{extension} must not be uploadable"

        assert PageUpload.allowed_extensions(".#{extension}") == [],
               ".#{extension} was taken as an upload type"
      end

      for type <-
            ~w(text/html image/svg+xml application/xml text/javascript application/javascript) do
        assert PageUpload.allowed_extensions(type) == [], "#{type} was taken as an upload type"
        assert PageUpload.unsupported(type) == [type]
      end
    end

    test "a group of types is the allowed ones of the group" do
      assert PageUpload.allowed_extensions("image/*") == ~w(png jpg jpeg gif webp)
      assert PageUpload.allowed_extensions("text/*") == ~w(txt csv)
      assert PageUpload.allowed_extensions("application/pdf, .DOCX") == ~w(pdf docx)
      assert PageUpload.allowed_extensions(["image/png", " .gif "]) == ~w(png gif)
    end

    test "the words that name nothing are told apart from the ones that do" do
      assert PageUpload.unsupported("image/*, .svg, .pdf, text/html") == [".svg", "text/html"]
      assert PageUpload.unsupported("image/*") == []
      assert PageUpload.unsupported(nil) == []
    end

    # `accept_option!/1` of LiveView raises for a type it does not know, which took the whole page
    # down on mount. Nothing outside the allow-list reaches it now.
    test "options never hands LiveView a type it would raise on" do
      for accept <- [".nosuchtype", "made/up", "image/*, .svg", nil, ""] do
        assert is_list(PageUpload.options(%{accept: accept})[:accept])
      end
    end
  end

  describe "what is stored is what the first bytes say" do
    setup %{site_id: site_id} do
      %{site_id: site_id, log: nil}
    end

    # THE ATTACK. An SVG with a script, named and typed as a PNG: LiveView takes it because it only
    # reads the name and the type the browser sent.
    test "a script given a picture's name and type is not stored", %{
      site_id: site_id,
      forms: forms
    } do
      {:ok, view, _html} = mount!(compile!([attachment("image/*")]), site_id)

      for {name, type, content} <- [
            {"logo.png", "image/png", Files.svg()},
            {"photo.jpg", "image/jpeg", Files.html()},
            {"cover.gif", "image/gif", Files.script()}
          ] do
        file =
          file_input(view, "#attach-form", :attachment, [
            %{name: name, content: content, type: type}
          ])

        render_upload(file, name)
      end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          view |> element("#attach-form") |> render_submit(%{"attach" => %{"note" => "x"}})
        end)

      refute File.exists?(forms), "nothing should have been written for the three files"
      assert log =~ "was not stored"
      assert log =~ "none of the types this upload takes"
    end

    test "a real picture is stored as the kind it is, not as the name or type it came with", %{
      site_id: site_id,
      forms: forms
    } do
      {:ok, view, _html} = mount!(compile!([attachment("image/*")]), site_id)

      file =
        file_input(view, "#attach-form", :attachment, [
          %{name: "logo.png", content: Files.png(), type: "image/png"}
        ])

      render_upload(file, "logo.png")
      view |> element("#attach-form") |> render_submit(%{"attach" => %{"note" => "x"}})

      assert [stored] = File.ls!(forms)
      assert String.ends_with?(stored, ".png")
      assert File.read!(Path.join(forms, stored)) == Files.png()
    end

    test "a PNG that says it is an SVG is stored as a PNG", %{site_id: site_id, forms: forms} do
      register(PageFormDestination)
      Process.register(self(), PageFormDestination.probe())
      {:ok, view, _html} = mount!(compile!([attachment(".png,.svg")]), site_id)

      file =
        file_input(view, "#attach-form", :attachment, [
          %{name: "logo.png", content: Files.png(), type: "image/svg+xml"}
        ])

      render_upload(file, "logo.png")
      view |> element("#attach-form") |> render_submit(%{"attach" => %{"note" => "x"}})

      assert [stored] = File.ls!(forms)
      assert String.ends_with?(stored, ".png")
      refute stored =~ "svg"

      assert_receive {:page_form_submitted, %{values: %{attachment: [%{"type" => "image/png"}]}}}
    end

    test "the extension is one the declaration takes: a JPEG named .jpeg is .jpg when only .jpg is taken",
         %{site_id: site_id, forms: forms} do
      {:ok, view, _html} = mount!(compile!([attachment(".jpg")]), site_id)

      file =
        file_input(view, "#attach-form", :attachment, [
          %{name: "Photo.JPEG", content: Files.jpeg(), type: "image/jpeg"}
        ])

      render_upload(file, "Photo.JPEG")
      view |> element("#attach-form") |> render_submit(%{"attach" => %{"note" => "x"}})

      assert [stored] = File.ls!(forms)
      assert String.ends_with?(stored, ".jpg")
    end

    test "a real picture is refused by an upload that takes only PDFs", %{
      site_id: site_id,
      forms: forms
    } do
      {:ok, view, _html} = mount!(compile!([attachment(".pdf")]), site_id)

      file =
        file_input(view, "#attach-form", :attachment, [
          %{name: "scan.pdf", content: Files.png(), type: "application/pdf"}
        ])

      render_upload(file, "scan.pdf")

      ExUnit.CaptureLog.capture_log(fn ->
        view |> element("#attach-form") |> render_submit(%{"attach" => %{"note" => "x"}})
      end)

      refute File.exists?(forms)
    end

    test "a page typed as .txt is stored as text and nothing else", %{
      site_id: site_id,
      forms: forms
    } do
      {:ok, view, _html} = mount!(compile!([attachment(".txt")]), site_id)

      file =
        file_input(view, "#attach-form", :attachment, [
          %{name: "page.txt", content: Files.html(), type: "text/plain"}
        ])

      render_upload(file, "page.txt")
      view |> element("#attach-form") |> render_submit(%{"attach" => %{"note" => "x"}})

      assert [stored] = File.ls!(forms)
      assert String.ends_with?(stored, ".txt")
    end

    # LiveView itself turns an HTML file away when the declaration takes only text.
    test "a file the declaration does not take never reaches the page", %{
      site_id: site_id,
      forms: forms
    } do
      {:ok, view, _html} = mount!(compile!([attachment(".txt")]), site_id)

      file =
        file_input(view, "#attach-form", :attachment, [
          %{name: "evil.html", content: Files.html(), type: "text/html"}
        ])

      assert {:error, [[_ref, :not_accepted]]} = render_upload(file, "evil.html")

      view |> element("#attach-form") |> render_submit(%{"attach" => %{"note" => "x"}})
      refute File.exists?(forms)
    end
  end

  # THE ROUND TRIP A BROWSER MAKES: a visitor uploads through the page, and the address that comes
  # back is requested from the endpoint, which serves `/uploads` with `Plug.Static` and the headers
  # `ShareCard.static_headers/1` adds.
  describe "what the endpoint answers for a stored file" do
    test "is a download that no browser will run", %{site_id: site_id, dir: dir} do
      {:ok, view, _html} = mount!(compile!([attachment(".txt")]), site_id)

      file =
        file_input(view, "#attach-form", :attachment, [
          %{name: "notes.txt", content: "plain notes", type: "text/plain"}
        ])

      register(PageFormDestination)
      Process.register(self(), PageFormDestination.probe())

      render_upload(file, "notes.txt")
      view |> element("#attach-form") |> render_submit(%{"attach" => %{"note" => "x"}})

      assert_receive {:page_form_submitted, %{values: %{attachment: [%{"url" => url}]}}}

      opts =
        Plug.Static.init(at: "/uploads", from: dir, headers: {ShareCard, :static_headers, []})

      conn = Plug.Test.conn(:get, url) |> Plug.Static.call(opts)

      assert conn.status == 200
      assert conn.resp_body == "plain notes"
      assert Plug.Conn.get_resp_header(conn, "content-disposition") == ["attachment"]
      assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert Plug.Conn.get_resp_header(conn, "content-security-policy") == ["sandbox"]
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/plain"]
    end
  end

  # THE SAME RULE AT THE ACTION BOUNDARY every writer passes: an author is told when the page is
  # saved, and not by a page that fails to show its upload field.
  describe "saving a page that declares uploads" do
    setup do
      %{site: create_site!()}
    end

    defp save(site, uploads) do
      Page
      |> Ash.Changeset.for_create(
        :master_create,
        %{
          site_id: site.id,
          title: "Uploads",
          path: "/uploads-#{System.unique_integer([:positive])}",
          template: "<p>x</p>",
          uploads: uploads
        },
        authorize?: false,
        context: %{page_code: :package}
      )
      |> Ash.create()
    end

    test "stores a declaration that names the types it takes", %{site: site} do
      assert {:ok, page} = save(site, [%{name: "cv", accept: "image/*, .pdf"}])
      assert [%{name: "cv", accept: "image/*, .pdf"}] = Enum.map(page.uploads, &Map.new(&1))
    end

    test "refuses a declaration with no accept", %{site: site} do
      for accept <- [nil, "", "  ,  "] do
        assert {:error, error} = save(site, [%{name: "cv", accept: accept}])
        assert Exception.message(error) =~ "needs Accepted Types", inspect(accept)
      end
    end

    test "refuses a declaration whose types a visitor may never send", %{site: site} do
      for accept <- [".svg", "image/svg+xml", ".html, .pdf", "text/html", "*/*", ".js"] do
        assert {:error, error} = save(site, [%{name: "cv", accept: accept}])
        message = Exception.message(error)

        assert message =~ "can never be uploaded",
               "#{accept} was saved"
      end
    end

    test "refuses the same declaration on an update", %{site: site} do
      {:ok, page} = save(site, [%{name: "cv", accept: ".pdf"}])

      assert {:error, error} =
               page
               |> Ash.Changeset.for_update(
                 :master_update,
                 %{uploads: [%{name: "cv", accept: ".svg"}]},
                 authorize?: false,
                 context: %{page_code: :package}
               )
               |> Ash.update()

      assert Exception.message(error) =~ "can never be uploaded"
    end
  end
end
