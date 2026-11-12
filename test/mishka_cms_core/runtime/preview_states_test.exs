# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PreviewStatesTest do
  @moduledoc """
  A page's preview states: its record's samples and the states a plugin names on
  `runtime:page:preview_states`, drawn as buttons above the preview frame. The chosen one's
  parameters ride on the frame's address, and a record sample gives "Open page" a real address.
  """
  use MishkaCmsCore.DataCase, async: false

  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.{Page, PreviewStates}
  alias MishkaCmsCore.Test.Plugins.{MovingRecords, PreviewStatesProbe}
  alias MishkaCmsCoreWeb.Live.Admin.Components.RuntimePreviewModal
  alias MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers
  alias MishkaInstaller.Event.{Event, EventHandler}

  @moduletag :integration

  setup do
    site = create_site!(host: "states-#{System.unique_integer([:positive])}.test")
    forget_settings(~w(site.languages site.language_urls), [site.id])
    {:ok, _} = MishkaCmsCore.Settings.put("site.languages", ["en", "fa"], site_id: site.id)

    start_plugin!(MovingRecords, "runtime:page:records")
    start_plugin!(PreviewStatesProbe, PreviewStates.event())

    {:ok, site: site}
  end

  defp start_plugin!(plugin, event) do
    {:ok, _} =
      Event.write(%{name: plugin, event: event, extension: :mishka_installer, status: :started})

    :ok = EventHandler.do_compile(event, :start, false)
    on_exit(fn -> Event.unregister(:name, plugin, false) end)
  end

  defp page(site, overrides) do
    struct(
      Page,
      Keyword.merge(
        [
          id: Ecto.UUID.generate(),
          name: "probe",
          path: "/:lang/posts/:slug",
          language: "en",
          preview_token: "tok-states",
          active: true,
          extra: %{"record" => "test:moving"},
          site_id: site.id,
          site: site
        ],
        overrides
      )
    )
  end

  defp modal(page, states, chosen) do
    state = PreviewStates.find(states, chosen)

    render_component(&RuntimePreviewModal.modal/1,
      preview:
        PreviewHelpers.empty()
        |> Map.merge(%{
          active_tab: "preview",
          resource: Page,
          record: page,
          preview_states: states,
          preview_state: state && state.id,
          live_url: PreviewHelpers.live_url(page, Page, state)
        })
    )
  end

  describe "for_page/2" do
    test "a page that shows a record gets its samples, marked, and opens on the first", %{
      site: site
    } do
      states = PreviewStates.for_page(page(site, []), site.id)

      assert [
               %{
                 label: "Old post",
                 params: %{"slug" => "old-post", "lang" => "en"},
                 record?: true
               }
             ] =
               states

      assert PreviewStates.initial(states) == hd(states)
    end

    test "a plugin's states are kept whole, its broken ones and reserved parameters left out", %{
      site: site
    } do
      states =
        site
        |> page(path: "/:lang/confirm", extra: %{"role" => "confirm"})
        |> PreviewStates.for_page(site.id)

      assert [%{id: "confirmed", label: "Confirmed", params: params, record?: false}] = states
      assert params == %{"state" => "confirmed"}
      assert PreviewStates.initial(states) == nil
    end

    test "a page nobody names states for has none", %{site: site} do
      assert PreviewStates.for_page(page(site, path: "/about", extra: %{}), site.id) == []
    end
  end

  describe "the modal" do
    test "draws the states as buttons and frames the chosen one's parameters", %{site: site} do
      page = page(site, [])
      states = PreviewStates.for_page(page, site.id)
      html = modal(page, states, "record-0")

      assert html =~ ~s(phx-click="preview_set_state")
      assert html =~ "Old post"
      refute html =~ "As it is"
      assert html =~ ~s(src="/_preview/page/tok-states?lang=en&amp;slug=old-post")
    end

    test "a record sample gives Open page the record's own address", %{site: site} do
      page = page(site, [])
      states = PreviewStates.for_page(page, site.id)

      assert modal(page, states, "record-0") =~ "Open page"
      assert PreviewHelpers.live_url(page, Page, hd(states)) =~ "/posts/old-post"
      refute PreviewHelpers.live_url(page, Page, nil)
    end

    test "a page that needs no record can be drawn as it is", %{site: site} do
      page = page(site, path: "/:lang/confirm", extra: %{"role" => "confirm"})
      states = PreviewStates.for_page(page, site.id)

      html = modal(page, states, nil)
      assert html =~ "As it is"
      assert html =~ ~s(src="/_preview/page/tok-states")

      assert modal(page, states, "confirmed") =~
               ~s(src="/_preview/page/tok-states?preview_state=confirmed&amp;state=confirmed")
    end

    test "the frame's loading note is marked for the hook that hides it", %{site: site} do
      html = modal(page(site, []), [], nil)

      assert html =~ ~s(phx-hook="PreviewFrame")
      assert html =~ "data-preview-spinner"
    end
  end

  describe "with_params/2" do
    test "names a plugin's state on the address, never a record sample" do
      assert PreviewStates.with_params("/p", %{id: "c", record?: false, params: %{}}) ==
               "/p?preview_state=c"

      assert PreviewStates.with_params("/p", %{
               id: "record-0",
               record?: true,
               params: %{"slug" => "a"}
             }) ==
               "/p?slug=a"

      assert PreviewStates.with_params("/p", nil) == "/p"
    end
  end

  describe "set_preview_state/2" do
    test "reloads the frame in the chosen state, and an unknown one draws the page as it is", %{
      site: site
    } do
      page = page(site, [])
      states = PreviewStates.for_page(page, site.id)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          preview:
            Map.merge(PreviewHelpers.empty(), %{
              resource: Page,
              record: page,
              preview_states: states
            })
        }
      }

      chosen = PreviewHelpers.set_preview_state(socket, "record-0").assigns.preview
      assert chosen.preview_state == "record-0"
      assert chosen.live_url =~ "/posts/old-post"
      assert chosen.render_nonce == 1

      none = PreviewHelpers.set_preview_state(socket, "made-up").assigns.preview
      assert none.preview_state == nil
      assert none.live_url == nil
    end
  end
end
