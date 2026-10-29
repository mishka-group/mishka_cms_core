# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.BuilderLive.AssetBuildBarTest do
  @moduledoc """
  The editor's bar for a CSS or JS bundle that did not build.

  Nothing on screen says so on its own: the canvas and the live site keep the last bundle that built,
  which is right for a visitor and a trap for an author, whose change is simply not there. The bar
  says what failed and why, and links to the page that shows it beside the rows. It reads the build
  record `Helpers.record_asset_build/3` keeps, when the editor opens and on every change to it.
  """
  use MishkaCmsCore.BuilderLiveCase

  alias MishkaCmsCore.Runtime.Compilers.Helpers

  @bar ~s([id^="pb-asset-build-"])

  setup %{site: site} do
    on_exit(fn ->
      Enum.each([site.name, "__shared_base__", "abb-other"], &Helpers.forget_asset_builds/1)
    end)
  end

  defp bar_text(view),
    do: view |> element(@bar) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()

  defp bar_link(view, type),
    do:
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([id^="pb-asset-build-#{type}-"] a))
      |> LazyHTML.attribute("href")

  test "a failed CSS build is shown when the editor opens, with its reason and a link", %{
    conn: conn,
    page: page,
    site: site
  } do
    :ok =
      Helpers.record_asset_build(
        site.name,
        "css",
        {:error, "Cannot apply unknown utility class `rounde-xl`", :last_good}
      )

    {:ok, view, _html} = open_builder(conn, page)

    text = bar_text(view)
    assert text =~ "The CSS of #{site.name} did not build."
    assert text =~ "keep the last one that built"
    assert text =~ "rounde-xl"
    assert bar_link(view, "css") == ["/admin/dashboard/runtime/stylesheets"]
  end

  test "appears while the author works, and goes once a build works", %{
    conn: conn,
    page: page,
    site: site
  } do
    {:ok, view, _html} = open_builder(conn, page)
    refute has_element?(view, @bar)

    :ok = Helpers.record_asset_build(site.name, "css", {:error, "broke", :last_good})
    assert has_element?(view, @bar)

    :ok = Helpers.record_asset_build(site.name, "css", :ok)
    refute has_element?(view, @bar)
  end

  # The canvas never loads the site's JavaScript, so the bar does not say the canvas keeps it.
  test "a failed JS build names the live site and links to the hooks", %{
    conn: conn,
    page: page,
    site: site
  } do
    :ok =
      Helpers.record_asset_build(
        site.name,
        "js",
        {:error, "Could not resolve \"echarts\"", :last_good}
      )

    {:ok, view, _html} = open_builder(conn, page)

    text = bar_text(view)

    assert text =~
             "The JavaScript of #{site.name} did not build. The live site keeps the last one"

    refute text =~ "canvas"
    assert bar_link(view, "js") == ["/admin/dashboard/runtime/js-hooks"]
  end

  test "does not claim a last bundle when there was none to keep", %{
    conn: conn,
    page: page,
    site: site
  } do
    :ok = Helpers.record_asset_build(site.name, "css", {:error, "broke", :nothing})

    {:ok, view, _html} = open_builder(conn, page)

    assert bar_text(view) =~ "The CSS of #{site.name} did not build."
    refute bar_text(view) =~ "keep the last"
  end

  test "says a partial bundle is partial", %{conn: conn, page: page, site: site} do
    :ok = Helpers.record_asset_build(site.name, "css", {:error, "base broke", :partial})

    {:ok, view, _html} = open_builder(conn, page)

    assert bar_text(view) =~ "did not build completely"
  end

  # A site's failure caused by the shared base already carries the base's reason: one bar, not two.
  test "a site's own CSS failure is the only CSS bar", %{conn: conn, page: page, site: site} do
    :ok = Helpers.record_asset_build("__shared_base__", "css", {:error, "base broke", :nothing})
    :ok = Helpers.record_asset_build(site.name, "css", {:error, "shared: base broke", :partial})

    {:ok, view, _html} = open_builder(conn, page)

    assert [_one] =
             view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(~s([id^="pb-asset-build-css-"]))
             |> Enum.to_list()
  end

  # Every site's CSS starts with the shared base, so its failure is this document's too.
  test "a shared base that did not build is shown on a site's document", %{conn: conn, page: page} do
    {:ok, view, _html} = open_builder(conn, page)

    :ok = Helpers.record_asset_build("__shared_base__", "css", {:error, "base broke", :last_good})

    assert bar_text(view) =~ "The shared CSS every site starts with did not build."
    assert bar_text(view) =~ "base broke"
  end

  test "another site's failure is not this document's", %{conn: conn, page: page} do
    {:ok, view, _html} = open_builder(conn, page)

    :ok = Helpers.record_asset_build("abb-other", "css", {:error, "theirs", :last_good})

    refute has_element?(view, @bar)
  end

  # A global document is built into every site, so every site's build is its.
  test "a document no site owns hears every site", %{conn: conn} do
    layout = create_layout!(site_id: nil, template: ~s(<main>{@inner_content}</main>))
    {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

    :ok = Helpers.record_asset_build("abb-other", "css", {:error, "theirs", :last_good})

    assert bar_text(view) =~ "The CSS of abb-other did not build."
  end

  # WHERE THE LINK GOES. A row's own job only queues its bundle, so the row listens for the
  # bundle's build record and refreshes when it changes. A global row is in every bundle, so it
  # hears all of them; it used to listen on `site:Global:assets`, which nothing announces on.
  describe "the page the bar links to" do
    defp sheet!(site_id) do
      MishkaCmsCore.Runtime.Stylesheet
      |> Ash.Changeset.for_create(
        :master_create,
        %{
          name: "abb-#{System.unique_integer([:positive])}",
          kind: :custom,
          content: ".a{}",
          site_id: site_id,
          active: true
        },
        authorize?: false
      )
      |> Ash.create!()
    end

    defp open_row(conn, sheet) do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/stylesheets")
      _ = render_async(view)

      view
      |> element(~s([phx-click="expand_row"][phx-value-id="#{sheet.id}"]))
      |> render_click()

      _ = render_async(view)
      view
    end

    # The topics are what the row subscribed to, and nothing in the markup shows them; what they
    # deliver is asserted from the markup below.
    # credo:disable-for-next-line Jump.CredoChecks.AvoidSocketAssignsInTest
    defp topics(view), do: :sys.get_state(view.pid).socket.assigns.asset_topic

    test "an open site row hears its bundle's build record", %{conn: conn, site: site} do
      view = open_row(conn, sheet!(site.id))

      assert topics(view) == ["site:#{site.name}:assets", "site:#{site.name}:asset_builds"]

      :ok = Helpers.record_asset_build(site.name, "css", {:error, "row broke", :last_good})
      _ = render_async(view)

      assert render(view) =~ "Bundle build failed"
      assert render(view) =~ "row broke"
    end

    test "an open global row hears every bundle", %{conn: conn} do
      view = open_row(conn, sheet!(nil))

      assert topics(view) == ["site:__shared_base__:assets", "asset_builds"]

      :ok = Helpers.record_asset_build("abb-other", "css", {:error, "theirs broke", :last_good})
      _ = render_async(view)

      assert render(view) =~ "theirs broke"
    end
  end

  # The document and the selection are the editor session's own state, which the markup shows only in
  # part, so the test compares the state itself.
  # credo:disable-for-next-line Jump.CredoChecks.AvoidSocketAssignsInTest
  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # THE BAR TAKES NOTHING FROM THE AUTHOR. It is drawn and dropped around the document without
  # touching it.
  test "leaves the document and the selection as they were", %{conn: conn, page: page, site: site} do
    {:ok, view, _html} = open_builder(conn, page)
    before = assigns(view)

    :ok = Helpers.record_asset_build(site.name, "css", {:error, "broke", :last_good})
    assert has_element?(view, @bar)

    now = assigns(view)

    for key <- [:tree, :selection, :dirty?, :stage, :token],
        do: assert(Map.get(now, key) == Map.get(before, key), "#{key} changed")
  end
end
