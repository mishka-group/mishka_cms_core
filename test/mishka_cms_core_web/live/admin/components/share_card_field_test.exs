# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Components.ShareCardFieldTest do
  @moduledoc """
  `MishkaCmsCoreWeb.Live.Admin.Components.ShareCardField`, the Share image an edit modal shows: the
  card as drawn, a note when it is not drawn or there is none, and Regenerate, which queues the card
  drawn again and shows it once it is written.

  `:media_static_dir` points the files at the test's own folder; `async: false` — `SiteState`,
  `AssetsState` and that folder are process-global.
  """
  use MishkaCmsCore.ConnCase, async: false

  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use Oban.Testing, repo: @repo

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.ShareCard
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Runtime.Workers.ShareCardRefreshWorker
  alias MishkaCmsCore.Settings
  alias MishkaCmsCore.Test.ShareCardHostLive
  alias MishkaCmsCoreWeb.Live.Admin.Components.ShareCardField

  setup do
    dir = Path.join(System.tmp_dir!(), "share_field_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:mishka_cms_core, :media_static_dir, dir)
    snapshot = SettingsState.snapshot()

    site = create_site!(active: true)
    {:ok, _} = Settings.put("site.title", "Acme", site_id: site.id)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: "field.test",
        priority: site.priority,
        active: true,
        master: site.master
      })

    on_exit(fn ->
      Application.delete_env(:mishka_cms_core, :media_static_dir)
      SettingsState.restore(snapshot)
      SiteState.delete(site.id)
      File.rm_rf(dir)
    end)

    page = create_page!(site_id: site.id, path: "/field", title: "Field page", language: "en")
    %{site: site, page: page}
  end

  defp open(conn, session), do: live_isolated(conn, ShareCardHostLive, session: session)

  defp draw!(site, page) do
    [spec] = ShareCard.specs(site.id, {:page, page.id})
    :ok = perform_job(ShareCard, %{site_id: site.id, key: ShareCard.key(spec), card: spec})
  end

  test "says a card is not drawn yet, and shows it once it is", %{
    conn: conn,
    site: site,
    page: page
  } do
    session = %{"site_id" => site.id, "target" => {:page, page.id}}

    {:ok, view, _html} = open(conn, session)
    html = render_async(view)
    assert html =~ "Not drawn yet"
    assert html =~ "Field page"

    # Not drawn yet: the panel queues it, and shows it once it is written.
    assert [look] = all_enqueued(worker: ShareCardRefreshWorker, args: %{force: false})
    assert look.args["target"] == %{"page" => page.id}
    assert view |> element("#share-regenerate") |> render() =~ "Drawing…"

    draw!(site, page)
    Phoenix.LiveView.send_update(view.pid, ShareCardField, id: "share", recheck: 1)
    assert [%{url: url, drawn_at: drawn_at}] = ShareCard.cards(site.id, {:page, page.id})
    assert has_element?(view, ~s(#share-card-0 img[src="#{url}?v=#{drawn_at}"]))
    refute view |> element("#share-regenerate") |> render() =~ "Drawing…"

    {:ok, view, _html} = open(conn, session)
    html = render_async(view)

    assert [%{url: url, drawn_at: drawn_at}] = ShareCard.cards(site.id, {:page, page.id})
    assert has_element?(view, ~s(#share-card-0 img[src="#{url}?v=#{drawn_at}"]))
    refute html =~ "Not drawn yet"
  end

  test "reads a record's target in the background, and says when it shows none", %{
    conn: conn,
    site: site,
    page: page
  } do
    {:ok, view, _html} =
      open(conn, %{
        "site_id" => site.id,
        "record" => page,
        "target_of" => "page"
      })

    assert render_async(view) =~ "Field page"

    {:ok, view, _html} =
      open(conn, %{"site_id" => site.id, "record" => page, "target_of" => "none"})

    render_async(view)
    assert has_element?(view, "#share-none")
    refute has_element?(view, "#share-regenerate")
  end

  test "Regenerate queues the card drawn again, and shows the new one once it is written", %{
    conn: conn,
    site: site,
    page: page
  } do
    draw!(site, page)
    # The card drawn before, written long ago: only one written after the click counts as new.
    [%{url: url}] = ShareCard.cards(site.id, {:page, page.id})
    File.touch!(Path.join(Application.get_env(:mishka_cms_core, :media_static_dir), url), 0)

    {:ok, view, _html} = open(conn, %{"site_id" => site.id, "target" => {:page, page.id}})
    render_async(view)

    view |> element("#share-regenerate") |> render_click()

    # Saving the page queued a look of its own (`MishkaCmsCore.Runtime.PageShareCard`); this one
    # is the click's.
    assert [job] = all_enqueued(worker: ShareCardRefreshWorker, args: %{force: true})
    assert view |> element("#share-regenerate") |> render() =~ "Drawing…"

    # Looked at before the new card is written: still drawing.
    Phoenix.LiveView.send_update(view.pid, ShareCardField, id: "share", recheck: 1)
    assert view |> element("#share-regenerate") |> render() =~ "Drawing…"

    :ok = perform_job(ShareCardRefreshWorker, job.args)
    assert [redraw] = all_enqueued(worker: ShareCard)
    :ok = perform_job(ShareCard, redraw.args)

    Phoenix.LiveView.send_update(view.pid, ShareCardField, id: "share", recheck: 1)
    html = view |> element("#share-regenerate") |> render()

    refute html =~ "Drawing…"
    assert html =~ "Regenerate"
  end
end
