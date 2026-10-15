defmodule MishkaCmsCore.Runtime.ShareCardTest.ThingSeo do
  @moduledoc false
  def call(%{record: "test:thing"} = seo),
    do: {:reply, :halt, %{seo | var_docs: [%{key: "thing.title"}]}}

  def call(seo), do: {:reply, seo}
end

defmodule MishkaCmsCore.Runtime.ShareCardTest.OwnCardSeo do
  @moduledoc false
  def call(%{title: "Own card"} = seo),
    do: {:reply, %{seo | image: "/uploads/#{seo.site_id}/share/landing-own.jpg", card: false}}

  def call(seo), do: {:reply, seo}
end

defmodule MishkaCmsCore.Runtime.ShareCardTest.SweptListener do
  @moduledoc false
  use MishkaInstaller.Event.Hook,
    event: MishkaCmsCore.Runtime.ShareCard.swept_event(),
    initial: %{priority: 50}

  @impl true
  def call(data) do
    send(self(), {:swept, data})
    {:reply, data}
  end
end

defmodule MishkaCmsCore.Runtime.ShareCardTest do
  @moduledoc """
  `MishkaCmsCore.Runtime.ShareCard`: the picture a shared link to a page shows. Asked for, it is
  queued, never drawn in the request; its job draws it in a separate process, where it is then
  served; and a page's head shows it where nothing of the page's own takes its place.

  `:media_static_dir` points the files at the test's own folder; `async: false` — `AssetsState`,
  the settings cache and that folder are process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use Oban.Testing, repo: @repo

  alias MishkaCmsCore.Runtime.{PageShareCard, Seo, ShareCard}
  alias MishkaCmsCore.Runtime.ShareCardTest.{OwnCardSeo, SweptListener, ThingSeo}
  alias MishkaCmsCore.Runtime.States.{AssetsState, SettingsState, SiteState, TranslationsState}
  alias MishkaCmsCore.Runtime.Workers.{ShareCardRefreshWorker, ShareCardSweepWorker}
  alias MishkaCmsCore.Settings
  alias MishkaInstaller.Event.{Event, EventHandler}

  @base "https://cards.test"

  setup do
    dir = Path.join(System.tmp_dir!(), "share_card_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:mishka_cms_core, :media_static_dir, dir)
    snapshot = SettingsState.snapshot()

    on_exit(fn ->
      Application.delete_env(:mishka_cms_core, :media_static_dir)
      SettingsState.restore(snapshot)
      File.rm_rf(dir)
    end)

    site = create_site!(active: true)
    {:ok, _} = Settings.put("site.title", "Acme Studio", site_id: site.id)

    %{site: site, dir: dir}
  end

  describe "image/2" do
    test "queues a card the first time, once, and answers it when it is drawn", %{site: site} do
      card = %{title: "Launch week", description: "Five releases in five days.", site: "Acme"}
      key = ShareCard.key(card)

      assert ShareCard.image(site.id, card) == nil
      assert ShareCard.image(site.id, card) == nil
      assert [job] = all_enqueued(worker: ShareCard)
      assert job.args["key"] == key
      assert job.args["site_id"] == site.id

      assert :ok = perform_job(ShareCard, job.args)

      assert ShareCard.image(site.id, card) == %{
               url: "/uploads/#{site.id}/share/#{key}.jpg",
               width: 1200,
               height: 630,
               type: "image/jpeg"
             }
    end

    test "a card drawn before is found on disk, with nothing queued", %{site: site, dir: dir} do
      card = %{title: "Drawn on another node"}
      key = ShareCard.key(card)
      path = Path.join([dir, "uploads", site.id, "share", key <> ".jpg"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "jpeg")

      assert %{url: url} = ShareCard.image(site.id, card)
      assert url == "/uploads/#{site.id}/share/#{key}.jpg"
      assert all_enqueued(worker: ShareCard) == []
    end

    test "a card with no title, or no site, is nothing and queues nothing", %{site: site} do
      assert ShareCard.image(site.id, %{title: "  ", description: "only this"}) == nil
      assert ShareCard.image(nil, %{title: "No site"}) == nil
      assert all_enqueued(worker: ShareCard) == []
    end
  end

  describe "key/1" do
    test "names what the card shows, whichever way its keys and spaces are written" do
      assert ShareCard.key(%{title: "Launch  week", meta: ["Mar 3"]}) ==
               ShareCard.key(%{"title" => " Launch week ", "meta" => ["Mar 3", ""]})

      refute ShareCard.key(%{title: "Launch week"}) == ShareCard.key(%{title: "Launch day"})

      refute ShareCard.key(%{title: "Launch week"}) ==
               ShareCard.key(%{title: "Launch week", logo: "/images/new-logo.png"})
    end
  end

  describe "static_headers/1" do
    test "keeps a card a year in any cache, and adds nothing to another upload" do
      site_id = Ecto.UUID.generate()
      card = ShareCard.url(site_id, ShareCard.key(%{title: "Launch week"}))

      assert Plug.Test.conn(:get, card) |> ShareCard.static_headers() == %{
               "cache-control" => "public, max-age=31536000, immutable"
             }

      for path <- [
            "/uploads/#{site_id}/media/uncategorized/cover.png",
            "/uploads/#{site_id}/share",
            "/uploads/#{site_id}/share/nested/card.jpg",
            "/fonts/fonts.css"
          ] do
        assert Plug.Test.conn(:get, path) |> ShareCard.static_headers() == %{}, path
      end
    end
  end

  describe "the drawing" do
    test "is a 1200×630 JPEG", %{site: site} do
      card = %{
        "title" => "Introducing the share card, a title long enough to take more than one line",
        "description" => "What a link to this page shows where it is shared.",
        "eyebrow" => "Release",
        "site" => "Acme",
        "host" => "cards.test",
        "people" => [%{"name" => "Mona", "image" => nil}, %{"name" => "Shahryar"}],
        "byline" => "Core team",
        "meta" => ["Mar 3, 2025", "5 min read"]
      }

      assert {:ok, image} = drawn(site, card)
      assert {Image.width(image), Image.height(image)} == {1200, 630}
    end

    test "draws right-to-left text", %{site: site} do
      card = %{
        "title" => "معرفی میشکا چلکم",
        "site" => "میشکا",
        "people" => [%{"name" => "مونا"}]
      }

      assert {:ok, image} = drawn(site, card)
      assert Image.width(image) == 1200
    end

    test "draws the site's own pictures and leaves out what it cannot read", %{
      site: site,
      dir: dir
    } do
      folder = Path.join([dir, "uploads", site.id, "media", "covers"])
      File.mkdir_p!(folder)
      Image.write!(Image.new!(64, 64, color: :purple), Path.join(folder, "cover.png"))
      File.write!(Path.join(folder, "broken.jpg"), "not a picture at all")
      File.write!(Path.join(folder, "logo.svg"), ~s(<svg xmlns="http://www.w3.org/2000/svg"/>))

      for picture <- [
            "/uploads/#{site.id}/media/covers/cover.png",
            "/uploads/#{site.id}/media/covers/broken.jpg",
            "/uploads/#{site.id}/media/../../../etc/passwd",
            "https://elsewhere.test/cover.png"
          ] do
        card = %{
          "title" => "With a picture",
          "picture" => picture,
          "logo" => "/uploads/#{site.id}/media/covers/logo.svg",
          "people" => [%{"name" => "Mona", "image" => picture}]
        }

        assert {:ok, image} = drawn(site, card), "#{picture} was not drawn around"
        assert Image.width(image) == 1200
      end
    end
  end

  describe "a page's head" do
    test "shows the card of a public page with no image of its own, once drawn", %{site: site} do
      seo = seo(site, description: "What we make.")

      head = Seo.head(seo, base: @base, card: true)
      assert value(head, "property", "og:image") == nil
      assert [job] = all_enqueued(worker: ShareCard)

      assert job.args["card"] == %{
               "title" => "About the studio",
               "description" => "What we make.",
               "site" => "Acme Studio",
               "host" => "cards.test"
             }

      :ok = perform_job(ShareCard, job.args)
      head = Seo.head(seo, base: @base, card: true)
      url = "#{@base}/uploads/#{site.id}/share/#{job.args["key"]}.jpg"

      assert head.image == url
      assert value(head, "property", "og:image") == url
      assert value(head, "property", "og:image:width") == "1200"
      assert value(head, "property", "og:image:height") == "630"
      assert value(head, "property", "og:image:type") == "image/jpeg"
      assert value(head, "name", "twitter:card") == "summary_large_image"
      assert value(head, "name", "twitter:image") == url
      assert value(head, "name", "twitter:image:alt") == "About the studio"
    end

    test "draws what the plugin adds, over the plugin's image, with the site's logo", %{
      site: site
    } do
      {:ok, _} = Settings.put("site.logo", "/images/acme.svg", site_id: site.id)

      seo =
        seo(site,
          image: "/uploads/#{site.id}/media/a/cover.jpg",
          card: %{eyebrow: "News", people: [%{name: "Mona", image: nil}], meta: ["Mar 3"]}
        )

      head = Seo.head(seo, base: @base, card: true)

      assert head.image == "#{@base}/uploads/#{site.id}/media/a/cover.jpg"
      assert [%{args: %{"card" => card}}] = all_enqueued(worker: ShareCard)
      assert card["eyebrow"] == "News"
      assert card["people"] == [%{"name" => "Mona", "image" => nil}]
      assert card["meta"] == ["Mar 3"]
      assert card["picture"] == "/uploads/#{site.id}/media/a/cover.jpg"
      assert card["logo"] == "/images/acme.svg"
    end

    test "asks for no card when the page stores an image, is kept out of an index, the plugin says no, or nobody asked",
         %{site: site} do
      stored = [[%{tag: "meta", attrs: %{"property" => "og:image"}, content: "/own.png"}]]

      Seo.head(seo(site), base: @base, card: true, layers: stored)
      Seo.head(seo(site), base: @base, card: true, restricted?: true)
      Seo.head(seo(site, card: false, image: "/plugin.png"), base: @base, card: true)
      Seo.head(seo(site), base: @base)

      assert all_enqueued(worker: ShareCard) == []
      head = Seo.head(seo(site, card: false, image: "/plugin.png"), base: @base, card: true)
      assert head.image == "#{@base}/plugin.png"
    end

    test "names the site in the page's language when Translations has its title", %{site: site} do
      TranslationsState.put(site.id, "fa", "Acme Studio", "استودیو آکمه")

      fa = Seo.head(seo(site, language: "fa"), base: @base, card: true)
      en = Seo.head(seo(site), base: @base, card: true)

      assert value(fa, "property", "og:site_name") == "استودیو آکمه"
      assert value(en, "property", "og:site_name") == "Acme Studio"
      assert Seo.site_name(site.id, "fa") == "استودیو آکمه"

      sites = for %{args: %{"card" => card}} <- all_enqueued(worker: ShareCard), do: card["site"]
      assert Enum.sort(sites) == ["Acme Studio", "استودیو آکمه"]
    end

    test "links the site.favicon setting as the page's icon, a path on the host it is read on", %{
      site: site
    } do
      assert link(Seo.head(seo(site), base: @base), "icon") == nil

      {:ok, _} =
        Settings.put("site.favicon", "/uploads/#{site.id}/media/a/icon.png", site_id: site.id)

      assert link(Seo.head(seo(site), base: @base), "icon") ==
               "/uploads/#{site.id}/media/a/icon.png"

      {:ok, _} =
        Settings.put("site.favicon", "https://cdn.example.com/icon.png", site_id: site.id)

      assert link(Seo.head(seo(site), base: @base), "icon") == "https://cdn.example.com/icon.png"

      for refused <- [
            "//evil.example/icon.png",
            "javascript:alert(1)",
            "https://u:p@evil.example/i.png"
          ] do
        {:ok, _} = Settings.put("site.favicon", refused, site_id: site.id)
        assert link(Seo.head(seo(site), base: @base), "icon") == nil, refused
      end
    end
  end

  # A site the runtime knows, as a booted one is — `specs/2` reads its host from `SiteState`.
  defp cached!(site) do
    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: "cards.test",
        priority: site.priority,
        active: true,
        master: site.master
      })

    on_exit(fn -> SiteState.delete(site.id) end)
    site
  end

  describe "refresh/3" do
    test "queues one look a burst of saves shares, a moment later", %{site: site} do
      for _save <- 1..3, do: assert(:ok = ShareCard.refresh(site.id, {:page, "p1"}))

      assert [job] = all_enqueued(worker: ShareCardRefreshWorker)
      assert job.args == %{"site_id" => site.id, "target" => %{"page" => "p1"}, "force" => false}
      assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) == :gt
    end

    test "with force, looks now, for a record as well as a page", %{site: site} do
      target = {:record, "blog:post", %{"slug" => "hello", "lang" => "en"}}
      :ok = ShareCard.refresh(site.id, target, force: true)

      assert [job] = all_enqueued(worker: ShareCardRefreshWorker)
      assert job.args["force"]
      assert ShareCard.decode(job.args["target"]) == target
      assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) != :gt
    end
  end

  describe "specs/2" do
    setup %{site: site}, do: %{site: cached!(site)}

    test "is what a visit to the page puts on its card", %{site: site} do
      page =
        create_page!(
          site_id: site.id,
          path: "/about-#{System.unique_integer([:positive])}",
          title: "About us",
          description: "What we make.",
          language: "en"
        )

      assert [spec] = ShareCard.specs(site.id, {:page, page.id})
      assert spec.title == "About us"
      assert spec.description == "What we make."
      assert spec.site == "Acme Studio"
      assert spec.host == "cards.test"
    end

    test "leaves a page that shows records to them, and shows none for a private page", %{
      site: site
    } do
      answers!(ThingSeo)

      records =
        create_page!(site_id: site.id, path: "/things/:slug", extra: %{"record" => "test:thing"})

      private = create_page!(site_id: site.id, path: "/members", permissions: ["members:read"])

      assert ShareCard.specs(site.id, {:page, records.id}) == []
      assert ShareCard.specs(site.id, {:page, private.id}) == []

      assert [%{title: title}] =
               ShareCard.specs(site.id, {:record, "test:thing", %{"slug" => "one"}})

      assert title == records.title
      assert ShareCard.specs(site.id, {:record, "test:other", %{"slug" => "one"}}) == []
    end

    test "shows none for a record no plugin answers for: its lock cannot be read", %{site: site} do
      create_page!(site_id: site.id, path: "/things/:slug", extra: %{"record" => "test:thing"})

      assert ShareCard.specs(site.id, {:record, "test:thing", %{"slug" => "one"}}) == []
    end

    test "is nothing for a site the runtime does not know" do
      assert ShareCard.specs(Ecto.UUID.generate(), {:page, Ecto.UUID.generate()}) == []
    end
  end

  describe "the refresh job" do
    setup %{site: site} do
      site = cached!(site)
      page = create_page!(site_id: site.id, path: "/team", title: "The team", language: "en")
      %{site: site, page: page}
    end

    test "queues the card's drawing when it is not drawn, and nothing once it is", %{
      site: site,
      page: page
    } do
      args = %{site_id: site.id, target: %{"page" => page.id}, force: false}

      :ok = perform_job(ShareCardRefreshWorker, args)
      assert [draw] = all_enqueued(worker: ShareCard)
      assert [%{drawn_at: nil, title: "The team"}] = ShareCard.cards(site.id, {:page, page.id})

      :ok = perform_job(ShareCard, draw.args)
      assert [%{drawn_at: drawn_at}] = ShareCard.cards(site.id, {:page, page.id})
      assert is_integer(drawn_at)

      :ok = perform_job(ShareCardRefreshWorker, args)
      assert [^draw] = all_enqueued(worker: ShareCard)
    end

    test "with force, draws it again over the file drawn before", %{site: site, page: page} do
      [spec] = ShareCard.specs(site.id, {:page, page.id})
      :ok = perform_job(ShareCard, %{site_id: site.id, key: ShareCard.key(spec), card: spec})
      [%{url: url}] = ShareCard.cards(site.id, {:page, page.id})
      file = Path.join(Application.get_env(:mishka_cms_core, :media_static_dir), url)
      File.touch!(file, 0)

      :ok =
        perform_job(ShareCardRefreshWorker, %{
          site_id: site.id,
          target: %{"page" => page.id},
          force: true
        })

      assert [redraw] = all_enqueued(worker: ShareCard)
      :ok = perform_job(ShareCard, redraw.args)
      assert [%{drawn_at: drawn_at}] = ShareCard.cards(site.id, {:page, page.id})
      assert drawn_at > 0
    end
  end

  describe "keeping the cards a page shows" do
    setup %{site: site} do
      site = cached!(site)
      page = create_page!(site_id: site.id, path: "/team", title: "The team", language: "en")
      %{site: site, page: page}
    end

    test "a look marks the page's drawn card as shown now", %{site: site, page: page} do
      [spec] = ShareCard.specs(site.id, {:page, page.id})
      file = card_file(site, ShareCard.key(spec) <> ".jpg")
      File.touch!(file, 0)

      :ok = perform_job(ShareCardRefreshWorker, %{site_id: site.id, target: %{"page" => page.id}})

      assert mtime(file) >= System.os_time(:second) - 5
      assert all_enqueued(worker: ShareCard) == []
    end

    test "and the card a plugin drew itself, which the head names", %{site: site} do
      answers!(OwnCardSeo)
      page = create_page!(site_id: site.id, path: "/own", title: "Own card", language: "en")
      file = card_file(site, "landing-own.jpg")
      File.touch!(file, 0)

      :ok = ShareCard.look(site.id, {:page, page.id})

      assert mtime(file) >= System.os_time(:second) - 5
    end

    test "keep/2 touches only a card file of the site that is there", %{site: site} do
      file = card_file(site, "kept.jpg")
      File.touch!(file, 0)
      elsewhere = card_file(create_site!(), "kept.jpg")
      File.touch!(elsewhere, 0)

      assert :ok = ShareCard.keep(site.id, "https://cards.test/uploads/#{site.id}/share/kept.jpg")
      assert mtime(file) > 0

      for url <- [
            "/uploads/#{site.id}/share/missing.jpg",
            "/uploads/#{site.id}/share/../share/kept.jpg",
            "/uploads/#{site.id}/media/kept.jpg",
            "/uploads/#{site.id}/share/kept.png",
            "/uploads/other/share/kept.jpg",
            nil
          ],
          do: assert(:ok = ShareCard.keep(site.id, url))

      assert mtime(elsewhere) == 0
      refute File.exists?(Path.join(ShareCard.dir(site.id), "missing.jpg"))
    end
  end

  describe "the sweep" do
    setup do
      {:ok, _} =
        Event.write(%{
          name: SweptListener,
          event: ShareCard.swept_event(),
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile(ShareCard.swept_event(), :start, false)

      on_exit(fn ->
        Event.unregister(:name, SweptListener, false)
        EventHandler.do_compile(ShareCard.swept_event(), :start, false)
      end)
    end

    test "deletes the card files none of the looks since its start kept, and forgets them", %{
      site: site
    } do
      since = System.os_time(:second)
      kept = card_file(site, "kept.jpg")
      old = card_file(site, "old.jpg")
      theirs = card_file(site, "landing-old.jpg")
      unfinished = card_file(site, "half.jpg.part")
      other = card_file(site, "notes.txt")
      for file <- [old, theirs, unfinished, other], do: File.touch!(file, since - 60)
      File.touch!(kept, since)

      for key <- ~w(old kept) do
        AssetsState.save(%{
          id: site.id,
          type: "share_card:" <> key,
          value: :ready,
          hash: nil,
          updated_at: DateTime.utc_now()
        })
      end

      assert :ok = perform_job(ShareCardSweepWorker, %{site_id: site.id, since: since})

      assert File.exists?(kept) and File.exists?(other)
      refute File.exists?(old) or File.exists?(theirs) or File.exists?(unfinished)
      assert AssetsState.get_value(site.id, "share_card:old") == nil
      assert AssetsState.get_value(site.id, "share_card:kept") == :ready

      assert_received {:swept, %{site_id: site_id, removed: removed}}
      assert site_id == site.id
      assert Enum.sort(removed) == ["landing-old.jpg", "old.jpg"]
    end

    test "a site with no cards yet has nothing to delete", %{site: site} do
      assert :ok = perform_job(ShareCardSweepWorker, %{site_id: site.id, since: 0})
      assert_received {:swept, %{removed: []}}
    end

    test "runs after every other job of the queue: one a site, at the lowest priority", %{
      site: site
    } do
      {:ok, _} = Oban.insert(ShareCardSweepWorker.after_plan(site.id, 1))
      {:ok, _} = Oban.insert(ShareCardSweepWorker.after_plan(site.id, 2))

      assert [job] = all_enqueued(worker: ShareCardSweepWorker)
      assert job.priority == 9 and job.queue == "share_cards"
      assert job.args == %{"site_id" => site.id, "since" => 1}
    end
  end

  describe "the page plugin" do
    setup do
      {:ok, _} =
        Event.write(%{
          name: PageShareCard,
          event: PageShareCard.config(:__event__),
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile(PageShareCard.config(:__event__), :start, false)
      on_exit(fn -> Event.unregister(:name, PageShareCard, false) end)
    end

    test "looks at a page's card again once the page is saved", %{site: site} do
      page = create_page!(site_id: site.id, title: "Saved")

      assert [job] = all_enqueued(worker: ShareCardRefreshWorker)
      assert job.args["target"] == %{"page" => page.id}
      assert job.args["site_id"] == site.id
    end
  end

  # A plugin on the head's event answering for `test:thing`, as an extension answers for its kinds.
  defp answers!(plugin) do
    {:ok, _} =
      Event.write(%{
        name: plugin,
        event: Seo.event(),
        extension: :mishka_installer,
        status: :started
      })

    :ok = EventHandler.do_compile(Seo.event(), :start, false)

    on_exit(fn ->
      Event.unregister(:name, plugin, false)
      EventHandler.do_compile(Seo.event(), :start, false)
    end)
  end

  defp card_file(site, name) do
    file = Path.join(ShareCard.dir(site.id), name)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "jpeg")
    file
  end

  defp mtime(file), do: File.stat!(file, time: :posix).mtime

  # What `perform/1` draws for `card`, read back.
  defp drawn(site, card) do
    key = ShareCard.key(card)
    :ok = perform_job(ShareCard, %{site_id: site.id, key: key, card: card})

    [Application.get_env(:mishka_cms_core, :media_static_dir), "uploads", site.id, "share"]
    |> Path.join()
    |> Path.join(key <> ".jpg")
    |> Image.open()
  end

  defp seo(site, overrides \\ []) do
    Map.merge(
      %{
        title: "About the studio",
        description: nil,
        image: nil,
        type: "website",
        url: "#{@base}/en/about",
        language: "en",
        tags: [],
        schema: [],
        vars: %{},
        site_id: site.id
      },
      Map.new(overrides)
    )
  end

  defp value(head, key, name) do
    Enum.find_value(head.tags, fn
      {"meta", attrs} -> {key, name} in attrs && List.keyfind(attrs, "content", 0) |> elem(1)
      _other -> nil
    end)
  end

  defp link(head, rel) do
    Enum.find_value(head.tags, fn
      {"link", attrs} -> {"rel", rel} in attrs && List.keyfind(attrs, "href", 0) |> elem(1)
      _other -> nil
    end)
  end
end
