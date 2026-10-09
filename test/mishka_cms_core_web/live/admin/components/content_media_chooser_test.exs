defmodule MishkaCmsCoreWeb.Test.ContentMediaChooserTest do
  @moduledoc """
  `MishkaCmsCoreWeb.Live.Admin.Components.ContentMediaChooser`, the media library the content
  editor's settings open for a picture or a video: whose files it lists, its search, and an upload
  that adds a file to the record's site.

  It is drawn here by a LiveView of its own beside the picker it answers, so it is the chooser under
  test — inside the editor's drawer it sits in a portal, where `Phoenix.LiveViewTest` does not look.
  The picker taking the answer is `MishkaCmsCoreWeb.Test.ContentEditorTest`.

  `async: false` — the media directory is application config.
  """
  use MishkaCmsCore.DataCase, async: false

  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.Media

  @moduletag :integration

  @endpoint MishkaCmsCore.TestEndpoint
  @await 5_000

  defmodule Host do
    use Phoenix.LiveView

    alias MishkaCmsCoreWeb.Live.Admin.Components.{ContentComponentPicker, ContentMediaChooser}

    def mount(_params, session, socket) do
      {:ok,
       assign(socket,
         user: session["user"],
         site_id: session["site_id"],
         accepts: session["accepts"] || :images,
         library: session["library"] || :open,
         folder: session["folder"]
       )}
    end

    def render(assigns) do
      ~H"""
      <div id="host">
        <.live_component
          module={ContentMediaChooser}
          id="chooser"
          target="picker"
          site_id={@site_id}
          current_user={@user}
          accepts={@accepts}
          library={@library}
          folder={@folder}
        />
        <.live_component
          module={ContentComponentPicker}
          id="picker"
          editor="ed"
          site_id={@site_id}
          current_user={@user}
        />
      </div>
      """
    end
  end

  # A FORM'S PICTURE FIELD, inside a form as the admin adapter draws it: the library's upload cannot
  # be a form of its own there.
  defmodule FieldHost do
    use Phoenix.LiveView

    alias MishkaCmsCoreWeb.Live.Admin.Components.MediaField

    def mount(_params, session, socket),
      do: {:ok, assign(socket, user: session["user"], site_id: session["site_id"])}

    def render(assigns) do
      ~H"""
      <form id="record-form" phx-change="validate">
        <.live_component
          module={MediaField}
          id="cover-media"
          input_id="record-cover"
          name="form[cover]"
          value="/uploads/old.png"
          field={:cover}
          form="#record-form"
          site_id={@site_id}
          current_user={@user}
          accepts={:images}
          folder="blog"
          placeholder="https://"
          disabled={false}
          debounce={300}
          class="field"
        />
      </form>
      """
    end

    def handle_event("validate", _params, socket), do: {:noreply, socket}
  end

  # The admin adapter drawing a text field, as a Gervaz form hands it one.
  defmodule AdapterHost do
    use Phoenix.LiveView

    import MishkaGervaz.Helpers, only: [dynamic_component: 1]

    def mount(_params, session, socket),
      do: {:ok, assign(socket, user: session["user"], extra: session["extra"])}

    def render(assigns) do
      ~H"""
      <form id="record-form">
        <.dynamic_component
          module={MishkaCmsCoreWeb.UIAdapters.Admin}
          function={:text_input}
          name="form[cover]"
          id="record-cover"
          value=""
          type="text"
          extra={@extra}
          field={%{field: :cover}}
          myself="#record-form"
          readonly={false}
          disabled={false}
          state={%{master_user?: false, current_user: @user, field_values: %{}}}
        />
      </form>
      """
    end
  end

  setup do
    n = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "content_media_chooser_#{n}")
    File.mkdir_p!(dir)
    Application.put_env(:mishka_cms_core, :media_static_dir, dir)

    on_exit(fn ->
      Application.delete_env(:mishka_cms_core, :media_static_dir)
      File.rm_rf(dir)
    end)

    site = create_site!(name: "chooser-#{n}", host: "chooser-#{n}.test")
    other = create_site!(name: "chooser-other-#{n}", host: "chooser-other-#{n}.test")
    user = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)

    {:ok, n: n, dir: dir, site: site, other: other, user: user}
  end

  defp open(ctx, session) do
    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), Host,
        session: Map.merge(%{"user" => ctx.user, "site_id" => ctx.site.id}, session)
      )

    render_async(view, @await)
    view
  end

  defp picture!(site, name, path \\ nil),
    do:
      create_media!(
        site_id: site.id,
        type: :images,
        name: name,
        relative_path: path || "/uploads/#{name}.png"
      )

  test "lists the site's own pictures, not another site's, nor its videos", ctx do
    own = picture!(ctx.site, "own-#{ctx.n}")
    video = create_media!(site_id: ctx.site.id, type: :videos, name: "clip-#{ctx.n}")
    theirs = picture!(ctx.other, "theirs-#{ctx.n}")

    view = open(ctx, %{})

    assert has_element?(
             view,
             "#chooser-file-#{own.id}[phx-value-url='/uploads/own-#{ctx.n}.png']"
           )

    assert has_element?(view, "#chooser-file-#{own.id} img[src='/uploads/own-#{ctx.n}.png']")
    refute has_element?(view, "#chooser-file-#{video.id}")
    refute has_element?(view, "#chooser-file-#{theirs.id}")
  end

  test "for a video, lists the videos", ctx do
    own = picture!(ctx.site, "own-#{ctx.n}")
    video = create_media!(site_id: ctx.site.id, type: :videos, name: "clip-#{ctx.n}")

    view = open(ctx, %{"accepts" => :videos})

    assert has_element?(view, "#chooser-file-#{video.id}")
    refute has_element?(view, "#chooser-file-#{own.id}")
  end

  test "a master sees the files of the record's site", ctx do
    master = create_user_with_permissions!(["*"])
    own = picture!(ctx.site, "own-#{ctx.n}")
    theirs = picture!(ctx.other, "theirs-#{ctx.n}")

    view = open(%{ctx | user: master}, %{})

    assert has_element?(view, "#chooser-file-#{own.id}")
    refute has_element?(view, "#chooser-file-#{theirs.id}")
  end

  test "searching narrows the list by name", ctx do
    cover = picture!(ctx.site, "cover-#{ctx.n}")
    logo = picture!(ctx.site, "logo-#{ctx.n}")

    view = open(ctx, %{})
    view |> element("#chooser-query") |> render_keyup(%{"value" => "COVER"})
    render_async(view, @await)

    assert has_element?(view, "#chooser-file-#{cover.id}")
    refute has_element?(view, "#chooser-file-#{logo.id}")
  end

  test "an upload adds the file to the site's library, and lists it", ctx do
    view = open(ctx, %{})

    file =
      file_input(view, "#chooser-upload", :file, [
        %{name: "cover.png", content: "cover bytes", type: "image/png"}
      ])

    render_upload(file, "cover.png")
    render_async(view, @await)

    [media] = Ash.read!(Media, tenant: ctx.site.id, authorize?: false)

    assert media.type == :images
    assert File.read!(Path.join(ctx.dir, media.relative_path)) == "cover bytes"
    assert has_element?(view, "#chooser-file-#{media.id}")
  end

  test "a master's upload goes to the record's site", ctx do
    master = create_user_with_permissions!(["*"])
    view = open(%{ctx | user: master}, %{})

    file =
      file_input(view, "#chooser-upload", :file, [
        %{name: "logo.png", content: "logo bytes", type: "image/png"}
      ])

    render_upload(file, "logo.png")
    render_async(view, @await)

    assert [%{site_id: site_id}] = Ash.read!(Media, tenant: ctx.site.id, authorize?: false)
    assert site_id == ctx.site.id
  end

  test "a file the field cannot use is refused", ctx do
    view = open(ctx, %{})

    file =
      file_input(view, "#chooser-upload", :file, [
        %{name: "notes.pdf", content: "pdf", type: "application/pdf"}
      ])

    assert {:error, [[_ref, :not_accepted]]} = render_upload(file, "notes.pdf")
    assert Ash.read!(Media, tenant: ctx.site.id, authorize?: false) == []
  end

  test "closed, it shows the upload alone, and the library once it is asked for", ctx do
    own = picture!(ctx.site, "own-#{ctx.n}")
    view = open(ctx, %{"library" => :closed})

    assert has_element?(view, "#chooser-upload")
    assert has_element?(view, "#chooser-browse")
    refute has_element?(view, "#chooser-file-#{own.id}")

    view |> element("#chooser-browse") |> render_click()
    render_async(view, @await)

    assert has_element?(view, "#chooser-file-#{own.id}")
    refute has_element?(view, "#chooser-browse")
  end

  test "given a folder, an upload is filed in it, made on the first upload", ctx do
    view = open(ctx, %{"folder" => "blog"})

    for name <- ["one.png", "two.png"] do
      view
      |> file_input("#chooser-upload", :file, [
        %{name: name, content: name, type: "image/png"}
      ])
      |> render_upload(name)

      render_async(view, @await)
    end

    [folder] =
      Ash.read!(MishkaCmsCore.Runtime.MediaCategory, tenant: ctx.site.id, authorize?: false)

    assert folder.name == "blog"
    assert is_nil(folder.parent_id)

    files = Ash.read!(Media, tenant: ctx.site.id, authorize?: false)
    assert length(files) == 2
    assert Enum.all?(files, &(&1.media_category_id == folder.id))
  end

  test "a form's picture field shows its address, and hands a pick to the form", ctx do
    own = picture!(ctx.site, "own-#{ctx.n}")

    {:ok, view, html} =
      live_isolated(Phoenix.ConnTest.build_conn(), FieldHost,
        session: %{"user" => ctx.user, "site_id" => ctx.site.id}
      )

    assert has_element?(
             view,
             "#record-form input#record-cover[name='form[cover]'][value='/uploads/old.png']"
           )

    assert has_element?(view, "#cover-media-preview img[src='/uploads/old.png']")
    assert has_element?(view, "#cover-media-library-browse")

    # The upload's own form is drawn at the end of the page, and its input names it.
    assert has_element?(view, "#record-form input[type=file][form='cover-media-library-upload']")
    assert html =~ ~s(id="cover-media-library-upload")

    view |> element("#cover-media-library-browse") |> render_click()
    render_async(view, @await)
    view |> element("#cover-media-library-file-#{own.id}") |> render_click()

    pick = view |> element("#cover-media-pick-1") |> render()
    assert pick =~ "combobox_select"
    assert pick =~ "/uploads/own-#{ctx.n}.png"
    assert pick =~ "record-form"
  end

  test "the admin adapter draws a picture field for a text field asking for one, else a text box",
       ctx do
    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), AdapterHost,
        session: %{"user" => ctx.user, "extra" => %{media: :images, folder: "blog"}}
      )

    assert has_element?(view, "#record-cover-media[data-role=media-field] input#record-cover")

    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), AdapterHost,
        session: %{"user" => ctx.user, "extra" => %{dir: "ltr"}}
      )

    assert has_element?(view, "input#record-cover[name='form[cover]']")
    refute has_element?(view, "[data-role=media-field]")
  end

  test "with no site, there is no library to choose from", ctx do
    view = open(ctx, %{"site_id" => nil})

    assert render(view) =~ "site first — files belong to a site"
    refute has_element?(view, "#chooser-upload")
  end
end
