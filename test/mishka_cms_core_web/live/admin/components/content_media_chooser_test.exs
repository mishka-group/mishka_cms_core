# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

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
  alias MishkaCmsCore.Test.Files

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
         folder: session["folder"],
         opened: 0
       )}
    end

    # The form the chooser is drawn in, opened again.
    def handle_info(:reopen, socket),
      do: {:noreply, Phoenix.Component.update(socket, :opened, &(&1 + 1))}

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
          opened={@opened}
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
      do: {:ok, assign(socket, user: session["user"], site_id: session["site_id"], opened: 0)}

    def handle_info(:reopen, socket),
      do: {:noreply, Phoenix.Component.update(socket, :opened, &(&1 + 1))}

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
          opened={@opened}
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
        %{name: "cover.png", content: Files.png() <> "cover bytes", type: "image/png"}
      ])

    render_upload(file, "cover.png")
    render_async(view, @await)

    [media] = Ash.read!(Media, tenant: ctx.site.id, authorize?: false)

    assert media.type == :images
    assert File.read!(Path.join(ctx.dir, media.relative_path)) == Files.png() <> "cover bytes"
    assert has_element?(view, "#chooser-file-#{media.id}")
  end

  test "a master's upload goes to the record's site", ctx do
    master = create_user_with_permissions!(["*"])
    view = open(%{ctx | user: master}, %{})

    file =
      file_input(view, "#chooser-upload", :file, [
        %{name: "logo.png", content: Files.png() <> "logo bytes", type: "image/png"}
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
        %{name: name, content: Files.png(), type: "image/png"}
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

  describe "Load more" do
    test "brings the next files after the first 48, newest first, until there are none", ctx do
      files = for i <- 1..50, do: picture!(ctx.site, "pic-#{i}-#{ctx.n}")
      view = open(ctx, %{})

      shown = fn -> Enum.count(files, &has_element?(view, "#chooser-file-#{&1.id}")) end

      assert shown.() == 48
      assert has_element?(view, "#chooser-more", "Load more")

      view |> element("#chooser-more") |> render_click()
      render_async(view, @await)

      assert shown.() == 50
      refute has_element?(view, "#chooser-more")
    end

    test "keeps to the search", ctx do
      covers = for i <- 1..49, do: picture!(ctx.site, "cover-#{i}-#{ctx.n}")
      logo = picture!(ctx.site, "logo-#{ctx.n}")

      view = open(ctx, %{})
      view |> element("#chooser-query") |> render_keyup(%{"value" => "cover"})
      render_async(view, @await)
      view |> element("#chooser-more") |> render_click()
      render_async(view, @await)

      assert Enum.all?(covers, &has_element?(view, "#chooser-file-#{&1.id}"))
      refute has_element?(view, "#chooser-file-#{logo.id}")
      refute has_element?(view, "#chooser-more")
    end
  end

  describe "browsing by folder" do
    setup ctx do
      photos = create_media_category!(site_id: ctx.site.id, name: "photos")
      year = create_media_category!(site_id: ctx.site.id, name: "2024", parent_id: photos.id)
      theirs = create_media_category!(site_id: ctx.other.id, name: "theirs")

      %{photos: photos, year: year, theirs: theirs}
    end

    defp filed!(site, name, folder),
      do: create_media!(site_id: site.id, type: :images, name: name, media_category_id: folder.id)

    test "All media lists every folder's files and the top folders; a folder, its own and the way back",
         ctx do
      loose = picture!(ctx.site, "loose-#{ctx.n}")
      in_photos = filed!(ctx.site, "in-photos-#{ctx.n}", ctx.photos)
      in_year = filed!(ctx.site, "in-year-#{ctx.n}", ctx.year)
      shown? = fn view, file -> has_element?(view, "#chooser-file-#{file.id}") end

      view = open(ctx, %{})

      assert Enum.all?([loose, in_photos, in_year], &shown?.(view, &1))
      assert has_element?(view, "#chooser-trail-root[aria-current=page]", "All media")
      assert has_element?(view, "#chooser-open-#{ctx.photos.id}", "photos")
      refute has_element?(view, "#chooser-open-#{ctx.year.id}")
      refute has_element?(view, "#chooser-open-#{ctx.theirs.id}")

      view |> element("#chooser-open-#{ctx.photos.id}") |> render_click()
      render_async(view, @await)

      assert shown?.(view, in_photos)
      refute shown?.(view, loose)
      refute shown?.(view, in_year)
      assert has_element?(view, "#chooser-trail-#{ctx.photos.id}[aria-current=page]", "photos")
      assert has_element?(view, "#chooser-open-#{ctx.year.id}", "2024")

      view |> element("#chooser-open-#{ctx.year.id}") |> render_click()
      render_async(view, @await)
      assert shown?.(view, in_year)
      refute shown?.(view, in_photos)

      view |> element("button#chooser-trail-#{ctx.photos.id}") |> render_click()
      render_async(view, @await)
      assert shown?.(view, in_photos)
      refute shown?.(view, in_year)

      view |> element("button#chooser-trail-root") |> render_click()
      render_async(view, @await)
      assert Enum.all?([loose, in_photos, in_year], &shown?.(view, &1))
    end

    test "Load more keeps to the folder open", ctx do
      inside = for i <- 1..50, do: filed!(ctx.site, "inside-#{i}-#{ctx.n}", ctx.photos)
      outside = picture!(ctx.site, "outside-#{ctx.n}")

      view = open(ctx, %{})
      view |> element("#chooser-open-#{ctx.photos.id}") |> render_click()
      render_async(view, @await)
      view |> element("#chooser-more") |> render_click()
      render_async(view, @await)

      assert Enum.all?(inside, &has_element?(view, "#chooser-file-#{&1.id}"))
      refute has_element?(view, "#chooser-file-#{outside.id}")
      refute has_element?(view, "#chooser-more")
    end

    test "a master browses the record's site's folders", ctx do
      master = create_user_with_permissions!(["*"])
      view = open(%{ctx | user: master}, %{})

      assert has_element?(view, "#chooser-open-#{ctx.photos.id}")
      refute has_element?(view, "#chooser-open-#{ctx.theirs.id}")
    end
  end

  describe "where an upload goes" do
    defp upload(view, name) do
      view
      |> file_input("#chooser-upload", :file, [
        %{name: name, content: Files.png(), type: "image/png"}
      ])
      |> render_upload(name)

      render_async(view, @await)
    end

    defp choose_folders(view) do
      view |> element("#chooser-change-folder") |> render_click()
      render_async(view, @await)
    end

    defp uploaded(site), do: Ash.read!(Media, tenant: site.id, authorize?: false)

    test "says the opener's folder, and lists the site's folders by path to pick another", ctx do
      photos = create_media_category!(site_id: ctx.site.id, name: "photos")
      year = create_media_category!(site_id: ctx.site.id, name: "2024", parent_id: photos.id)
      theirs = create_media_category!(site_id: ctx.other.id, name: "theirs")

      view = open(ctx, %{"folder" => "blog"})
      assert has_element?(view, "#chooser-destination-name", "blog")

      choose_folders(view)

      refute has_element?(view, "#chooser-folder option[value=''][selected]")

      assert has_element?(view, "#chooser-folder option[value=default][selected]", "blog")
      assert has_element?(view, "#chooser-folder option[value='#{year.id}']", "photos / 2024")
      assert has_element?(view, "#chooser-folder option[value=new]")
      refute has_element?(view, "#chooser-folder option[value='#{theirs.id}']")

      view |> element("#chooser-folder") |> render_change(%{"folder" => year.id})
      assert has_element?(view, "#chooser-destination-name", "photos / 2024")

      upload(view, "one.png")
      assert [%{media_category_id: id}] = uploaded(ctx.site)
      assert id == year.id
    end

    test "No folder files it at the top, and makes no folder", ctx do
      view = open(ctx, %{"folder" => "blog"})
      choose_folders(view)
      view |> element("#chooser-folder") |> render_change(%{"folder" => ""})

      assert has_element?(view, "#chooser-destination-name", "No folder")

      upload(view, "one.png")
      assert [%{media_category_id: nil}] = uploaded(ctx.site)

      assert Ash.read!(MishkaCmsCore.Runtime.MediaCategory,
               tenant: ctx.site.id,
               authorize?: false
             ) ==
               []
    end

    test "a new folder is made on the record's site, and the upload goes into it", ctx do
      master = create_user_with_permissions!(["*"])

      for {user, site} <- [{ctx.user, ctx.site}, {master, ctx.other}] do
        view = open(%{ctx | user: user, site: site}, %{"site_id" => site.id})
        choose_folders(view)
        view |> element("#chooser-folder") |> render_change(%{"folder" => "new"})
        assert has_element?(view, "#chooser-folder-name")

        view |> element("#chooser-folder-form") |> render_submit(%{"name" => "Team Photos"})
        assert has_element?(view, "#chooser-destination-name", "team-photos")

        upload(view, "one.png")

        [folder] =
          Ash.read!(MishkaCmsCore.Runtime.MediaCategory, tenant: site.id, authorize?: false)

        assert folder.name == "team-photos"
        assert folder.site_id == site.id
        assert [%{media_category_id: id}] = uploaded(site)
        assert id == folder.id
      end
    end

    test "a name taken beside it, or none, is refused and says so", ctx do
      create_media_category!(site_id: ctx.site.id, name: "covers")
      view = open(ctx, %{})
      choose_folders(view)
      view |> element("#chooser-folder") |> render_change(%{"folder" => "new"})

      view |> element("#chooser-folder-form") |> render_submit(%{"name" => "  "})
      assert render(view) =~ "Name the folder first."

      view |> element("#chooser-folder-form") |> render_submit(%{"name" => "covers"})
      assert render(view) =~ "its name may be taken here"
      assert has_element?(view, "#chooser-folder-name")
    end
  end

  describe "the form it is in, opened again" do
    test "draws it closed again, as its opener asks", ctx do
      own = picture!(ctx.site, "own-#{ctx.n}")
      view = open(ctx, %{"library" => :closed})

      view |> element("#chooser-browse") |> render_click()
      render_async(view, @await)
      view |> element("#chooser-query") |> render_keyup(%{"value" => "own"})
      render_async(view, @await)
      assert has_element?(view, "#chooser-file-#{own.id}")

      send(view.pid, :reopen)
      render_async(view, @await)

      assert has_element?(view, "#chooser-browse", "Choose from Media Manager")
      refute has_element?(view, "#chooser-file-#{own.id}")

      view |> element("#chooser-browse") |> render_click()
      render_async(view, @await)
      assert view |> element("#chooser-query") |> render() =~ ~s(value="")
    end

    test "drops a picture field's pick the form has not taken", ctx do
      own = picture!(ctx.site, "own-#{ctx.n}")

      {:ok, view, _html} =
        live_isolated(Phoenix.ConnTest.build_conn(), FieldHost,
          session: %{"user" => ctx.user, "site_id" => ctx.site.id}
        )

      view |> element("#cover-media-library-browse") |> render_click()
      render_async(view, @await)
      view |> element("#cover-media-library-file-#{own.id}") |> render_click()
      assert has_element?(view, "#cover-media-pick-1")

      send(view.pid, :reopen)
      render_async(view, @await)

      refute has_element?(view, "[id^=cover-media-pick-]")
      assert has_element?(view, "#cover-media-library-browse")
    end
  end
end
