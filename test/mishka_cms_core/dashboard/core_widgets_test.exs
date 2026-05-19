defmodule MishkaCmsCore.Dashboard.CoreWidgetsTest do
  @moduledoc """
  Each core widget is its own `dashboard:widgets` plugin. These tests call each plugin's `call/1`
  (it appends its descriptor) and render it through `Widget.card/1` against the real test stores
  (Oban, the unified activity query, the users table, settings + asset caches), asserting real
  content — never the card's "could not load" failure placeholder, which is what catches a wrong
  query/field.
  """
  use MishkaCmsCore.DataCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Dashboard.Widget

  alias MishkaCmsCore.Dashboard.Widgets.{
    SiteOverview,
    UsersSummary,
    QuickActions
  }

  @widgets [
    {SiteOverview, "site-overview", "Sites"},
    {UsersSummary, "users-summary", "users total"},
    {QuickActions, "quick-actions", "New page"}
  ]

  test "every core widget plugin registers on the dashboard:widgets event" do
    ids = wait_for_widgets(5_000)

    for {_module, id, _marker} <- @widgets do
      assert id in ids, "#{id} did not register on dashboard:widgets"
    end
  end

  defp wait_for_widgets(remaining) do
    ids = registered_ids()

    cond do
      length(ids) >= length(@widgets) ->
        ids

      remaining <= 0 ->
        ids

      true ->
        Process.sleep(100)
        wait_for_widgets(remaining - 100)
    end
  end

  defp registered_ids do
    case MishkaInstaller.Event.Hook.call("dashboard:widgets", %{widgets: []}) do
      %{widgets: widgets} when is_list(widgets) -> Enum.map(widgets, & &1.id)
      _ -> []
    end
  end

  for {module, id, marker} <- @widgets do
    test "#{id}: call/1 appends a valid descriptor" do
      assert {:reply,
              %{widgets: [%Widget{id: unquote(id), component: {unquote(module), :render}}]}} =
               unquote(module).call(%{widgets: []})
    end

    test "#{id}: load + render produce real content for a master, not the failure placeholder" do
      assert_renders(unquote(module), master(), unquote(marker))
    end

    # No marker for the tenant pass: each marker is a string from the MASTER view, and a tenant
    # legitimately renders something else (site-overview, for one, shows its single site instead of
    # a fleet count). What matters here is that a tenant's scope produces a card at all.
    test "#{id}: load + render produce real content for a tenant too" do
      site = create_site!()
      assert_renders(unquote(module), tenant(site), nil)
    end
  end

  # WHO SEES EACH CARD: a card that reads one area's data names that area; a card about the whole
  # dashboard is for anyone holding anything on it.
  describe "who sees each core widget" do
    @areas [
      {UsersSummary, "admin:dashboard:user"},
      {SiteOverview, "admin:dashboard:runtime:site"}
    ]

    for {module, area} <- @areas do
      test "#{inspect(module)} is for the holders of #{area}" do
        site = create_site!()
        widget = unquote(module).widget()

        assert Widget.permitted?(widget, holder([unquote(area)], site))
        refute Widget.permitted?(widget, holder(["admin:dashboard:runtime:media"], site))

        refute Widget.permitted?(
                 widget,
                 holder([String.replace(unquote(area), "dashboard", "api")], site)
               )
      end
    end

    for module <- [QuickActions] do
      test "#{inspect(module)} is for anyone holding anything on the dashboard" do
        site = create_site!()
        widget = unquote(module).widget()

        assert Widget.permitted?(widget, holder(["admin:dashboard:runtime:media"], site))
        refute Widget.permitted?(widget, holder(["admin:api:*"], site))
        refute Widget.permitted?(widget, create_user!(site_id: site.id))
      end
    end

    test "quick actions link only to the areas the viewer holds" do
      site = create_site!()

      user = holder(["admin:dashboard:runtime:page", "admin:dashboard:runtime:site"], site)

      html =
        render_component(&Widget.card/1,
          widget: QuickActions.widget(),
          state: {:ok, %{}},
          current_user: user
        )

      assert html =~ "New page"
      assert html =~ "Manage sites"
      refute html =~ "New component"
      refute html =~ "New layout"
    end

    test "the users card counts a holder of one area among its admins" do
      site = create_site!()
      before = UsersSummary.load(holder(["admin:dashboard:user"], site)).admins

      holder(["admin:dashboard:runtime:media"], site)
      holder(["admin:api:runtime:page"], site)
      create_user_with_permissions!(["probe:role"], site_id: site.id)

      assert UsersSummary.load(holder(["admin:dashboard:user"], site)).admins == before + 3
    end
  end

  # A master is a user whose `site_id` is nil — NOT a missing user, which `Widget.scope/1` now
  # refuses outright, so these pass a real one rather than the `nil` that used to stand in for it.
  defp master, do: create_user_with_permissions!(["admin:dashboard:*"])

  defp tenant(site), do: create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)

  defp holder(names, site), do: create_user_with_permissions!(names, site_id: site.id)

  defp assert_renders(module, user, marker) do
    data = if function_exported?(module, :load, 1), do: apply(module, :load, [user]), else: %{}

    html =
      render_component(&Widget.card/1,
        widget: module.widget(),
        state: {:ok, data},
        current_user: user
      )

    refute html =~ "could not load"
    if marker, do: assert(html =~ marker)
  end
end
