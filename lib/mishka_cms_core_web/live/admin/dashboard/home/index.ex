defmodule MishkaCmsCoreWeb.Live.Admin.Dashboard.Home.Index do
  use MishkaCmsCore.ExtensionLiveView
  alias MishkaCmsCore.Dashboard.Widget

  @impl true
  def mount(_params, _session, socket) do
    all = Widget.collect(socket.assigns.current_user)
    layout = Widget.layout(socket.assigns.current_user)

    {:ok,
     socket
     |> assign(page_title: gettext("Dashboard"))
     |> assign(all_widgets: all, customize?: false, data: %{})
     |> subscribe_widgets()
     |> place(layout)
     |> load_widgets()}
  end

  @impl true
  def handle_event("toggle_customize", _params, socket) do
    {:noreply, assign(socket, customize?: !socket.assigns.customize?)}
  end

  def handle_event("reorder", %{"ids" => ids}, socket) when is_list(ids) do
    {:noreply, persist(socket, Widget.reorder(socket.assigns.widget_layout, ids))}
  end

  def handle_event("add_at", %{"id" => id, "index" => index}, socket) when is_integer(index) do
    {:noreply,
     persist(
       socket,
       Widget.add_at(socket.assigns.widget_layout, socket.assigns.all_widgets, id, index)
     )}
  end

  def handle_event("set_span", %{"id" => id, "span" => span}, socket) when span in ~w(2 4 6) do
    {:noreply,
     persist(socket, Widget.set_span(socket.assigns.widget_layout, id, String.to_integer(span)))}
  end

  @doc """
  One of a widget's own settings changed in its gear panel (`Widget.config_control/1`). Every posted
  key is re-validated against that widget's declaration by `Widget.set_config/4` — an undeclared key
  or an uncoercible value is dropped, never persisted — and only a widget the viewer actually has on
  their board can be configured. Each value lands in its own per-user Setting row, the one its
  extension registered under its own settings tab, NOT in the layout blob. The widget's load is then
  re-run with the new settings so its card updates without touching the rest of the board.
  """
  @impl true
  def handle_event("save_widget_config", %{"id" => id} = params, socket) do
    case Enum.find(socket.assigns.widgets, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      widget ->
        before = Widget.config(widget, socket.assigns.current_user, socket.assigns.widget_layout)

        params
        |> Map.drop(~w(id _target))
        |> Enum.each(fn {key, value} ->
          Widget.set_config(socket.assigns.current_user, widget, key, value)
        end)

        after_save =
          Widget.config(widget, socket.assigns.current_user, socket.assigns.widget_layout)

        if after_save == before,
          do: {:noreply, socket},
          else: {:noreply, start_load(socket, widget)}
    end
  end

  def handle_event("hide", %{"id" => id}, socket) do
    {:noreply, persist(socket, Widget.hide(socket.assigns.widget_layout, id))}
  end

  def handle_event("add", %{"id" => id}, socket) do
    {:noreply, persist(socket, Widget.add(socket.assigns.widget_layout, id))}
  end

  # "Reset" puts the board back to how it ships: the layout blob is emptied (order, hidden/added,
  # widths) AND every widget's settings go back to their declared defaults. Settings now outlive the
  # blob — they are per-user Setting rows — so clearing the blob alone would leave a reset board
  # still showing someone's tuned counts.
  def handle_event("reset", _params, socket) do
    Enum.each(socket.assigns.all_widgets, &Widget.reset_config(socket.assigns.current_user, &1))

    {:noreply, persist(socket, %{})}
  end

  @impl true
  def handle_async({:widget, id}, {:ok, data}, socket) do
    {:noreply, put_data(socket, id, {:ok, data})}
  end

  def handle_async({:widget, id}, {:exit, reason}, socket) do
    {:noreply, put_data(socket, id, {:error, reason})}
  end

  @doc """
  A resource one of the widgets publishes on changed (each widget names its own `pubsub` — see
  `MishkaCmsCore.Dashboard.Widget.topics/2`). Re-run just the widgets fed by that topic.
  """
  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{topic: topic}, socket) do
    user = socket.assigns.current_user

    {:noreply,
     socket.assigns.widgets
     |> Enum.filter(&(topic in Widget.topics(&1, user)))
     |> Enum.reduce(socket, &start_load(&2, &1))}
  end

  # The admin chrome's own hooks pass their messages through, so the board must tolerate anything.
  def handle_info(_message, socket), do: {:noreply, socket}

  defp subscribe_widgets(socket) do
    if connected?(socket) do
      for widget <- socket.assigns.all_widgets,
          topic <- Widget.topics(widget, socket.assigns.current_user),
          do: Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, topic)
    end

    socket
  end

  defp persist(socket, layout) do
    Widget.save_layout(socket.assigns.current_user, layout)

    socket
    |> place(layout)
    |> load_widgets()
  end

  defp place(socket, layout) do
    assign(socket,
      widget_layout: layout,
      widgets: Widget.arrange(socket.assigns.all_widgets, layout),
      available: Widget.available(socket.assigns.all_widgets, layout)
    )
  end

  defp load_widgets(socket) do
    Enum.reduce(socket.assigns.widgets, socket, &load_widget(&2, &1))
  end

  defp load_widget(socket, widget) do
    cond do
      Map.has_key?(socket.assigns.data, widget.id) -> socket
      !loadable?(widget) -> put_data(socket, widget.id, {:ok, %{}})
      connected?(socket) -> start_load(socket, widget)
      true -> socket
    end
  end

  # A widget with settings exports `load/2` (user + its effective config); one without keeps `load/1`
  # and never learns this feature exists.
  defp start_load(socket, widget) do
    user = socket.assigns.current_user
    config = Widget.config(widget, user, socket.assigns.widget_layout)
    {module, _} = widget.component

    fun =
      if MishkaGervaz.Helpers.exports?(module, :load, 2),
        do: fn -> module.load(user, config) end,
        else: fn -> module.load(user) end

    MishkaGervaz.Messages.start_async(socket, {:widget, widget.id}, fun)
  end

  # A WIDGET MODULE IS NAMED BY THE REGISTRY AND CALLED BY NOTHING ELSE, so under interactive code
  # loading it is not in memory when this is asked — and a bare `function_exported?/3` then says a
  # widget that has a perfectly good `load/1` has neither, which reads as "this widget has no data
  # to fetch" rather than as "it has not been loaded yet". `Widget.entry_topics/2` already loads
  # before asking, for the same reason.
  defp loadable?(widget) do
    module = elem(widget.component, 0)

    MishkaGervaz.Helpers.exports?(module, :load, 2) or
      MishkaGervaz.Helpers.exports?(module, :load, 1)
  end

  defp put_data(socket, id, value) do
    assign(socket, :data, Map.put(socket.assigns.data, id, value))
  end

  defp span_class(widget, layout), do: Widget.col_span_class(Widget.span(widget, layout))

  @doc false
  def greeting(user) do
    name = role_name(user)

    case Time.utc_now().hour do
      h when h < 12 -> gettext("Good morning, %{name}", name: name)
      h when h < 18 -> gettext("Good afternoon, %{name}", name: name)
      _ -> gettext("Good evening, %{name}", name: name)
    end
  end

  @doc false
  def date_str do
    Calendar.strftime(Date.utc_today(), "%A, %B %-d",
      day_of_week_names: &day_name/1,
      month_names: &month_name/1
    )
  end

  defp day_name(1), do: gettext("Monday")
  defp day_name(2), do: gettext("Tuesday")
  defp day_name(3), do: gettext("Wednesday")
  defp day_name(4), do: gettext("Thursday")
  defp day_name(5), do: gettext("Friday")
  defp day_name(6), do: gettext("Saturday")
  defp day_name(7), do: gettext("Sunday")

  defp month_name(1), do: gettext("January")
  defp month_name(2), do: gettext("February")
  defp month_name(3), do: gettext("March")
  defp month_name(4), do: gettext("April")
  defp month_name(5), do: gettext("May")
  defp month_name(6), do: gettext("June")
  defp month_name(7), do: gettext("July")
  defp month_name(8), do: gettext("August")
  defp month_name(9), do: gettext("September")
  defp month_name(10), do: gettext("October")
  defp month_name(11), do: gettext("November")
  defp month_name(12), do: gettext("December")

  # A user with no site_id is the master (sees every site); one bound to a site is a tenant admin;
  # anybody else is greeted without a role.
  defp role_name(%{site_id: nil}), do: gettext("master")
  defp role_name(%{site_id: site_id}) when not is_nil(site_id), do: gettext("admin")
  defp role_name(_nobody), do: gettext("there")
end
