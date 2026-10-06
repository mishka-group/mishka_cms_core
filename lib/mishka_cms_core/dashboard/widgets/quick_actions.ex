defmodule MishkaCmsCore.Dashboard.Widgets.QuickActions do
  @moduledoc """
  Dashboard widget (a `dashboard:widgets` plugin): shortcut links into the runtime admin pages
  (pages, components, layouts, sites). Static — no data query. Anyone holding anything on the
  dashboard sees the card, and each link only when they hold its area.
  """
  use MishkaInstaller.Event.Hook, event: "dashboard:widgets", initial: %{priority: 100}
  use Gettext, backend: MishkaCmsCore.Gettext
  import Phoenix.Component

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Dashboard.Widget

  @links [
    {gettext_noop("New page"), "hero-document-plus", "/admin/dashboard/runtime/pages",
     "admin:dashboard:runtime:page"},
    {gettext_noop("New component"), "hero-puzzle-piece", "/admin/dashboard/runtime/components",
     "admin:dashboard:runtime:component"},
    {gettext_noop("New layout"), "hero-rectangle-group", "/admin/dashboard/runtime/layouts",
     "admin:dashboard:runtime:layout"},
    {gettext_noop("Manage sites"), "hero-globe-alt", "/admin/dashboard/runtime/sites",
     "admin:dashboard:runtime:site"}
  ]

  @impl true
  def call(%{widgets: widgets} = data), do: {:reply, %{data | widgets: widgets ++ [widget()]}}

  @doc "This widget's descriptor."
  @spec widget() :: Widget.t()
  def widget do
    {:ok, widget} =
      Widget.builder(%{
        id: "quick-actions",
        priority: 210,
        default_hidden: true,
        title: gettext_noop("Quick actions"),
        component: {__MODULE__, :render},
        permission: {:under, "admin:dashboard"},
        icon: "hero-rectangle-stack"
      })

    widget
  end

  def render(assigns) do
    user = assigns[:current_user]

    links =
      for {label, icon, path, permission} <- @links,
          holds?(user, permission),
          do: {Gettext.gettext(MishkaCmsCore.Gettext, label), icon, path}

    assigns = assign(assigns, links: links)

    ~H"""
    <div class="flex flex-col gap-2">
      <.link
        :for={{label, icon, path} <- @links}
        navigate={path}
        class="group flex items-center gap-2.5 rounded-lg border border-gray-200 px-3 py-2 text-sm text-gray-700 transition hover:border-indigo-200 hover:bg-indigo-50/40 hover:text-gray-900"
      >
        <span class={[icon, "size-4 shrink-0 text-gray-400 transition group-hover:text-indigo-500"]} />
        {label}
        <span class="hero-chevron-right ms-auto size-3.5 text-gray-300 transition group-hover:translate-x-0.5 group-hover:text-indigo-400 rtl:rotate-180 rtl:group-hover:-translate-x-0.5" />
      </.link>
    </div>
    """
  end

  defp holds?(user, permission),
    do: AccessPermissions.match?(user, %{}, permissions: [permission])
end
