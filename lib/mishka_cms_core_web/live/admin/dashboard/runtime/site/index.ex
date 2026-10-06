defmodule MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Site.Index do
  use MishkaCmsCore.ExtensionLiveView
  alias MishkaGervaz.Table.Web.UrlSync
  alias MishkaCmsCoreWeb.Live.Admin.Components.ActivityFeed
  alias MishkaCmsCore.Runtime.SiteHealth
  alias MishkaCmsCoreWeb.Live.Admin.Components.SiteHealthPanel
  alias MishkaCmsCore.Accounts.Helper

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  @site_modal_id "site-details-modal"

  # `config_mounted?` gates the Configuration tab's form: `MishkaGervaz.Form.Web.Live` reads the row
  # and every relation's options the moment it mounts, so mounting it with the modal charged a click
  # on the eye for an edit nobody had asked for. It flips on the first visit to that tab and stays on
  # until the modal closes, which is what keeps a half-typed field alive across a trip to Overview.
  defp default_site_modal,
    do: %{
      record: nil,
      active_tab: "overview",
      health: nil,
      loading?: false,
      form_record_id: nil,
      config_mounted?: false
    }

  # The Site form now lives inside the unified details modal's Configuration tab, so a successful
  # save / cancel closes that modal (not the old standalone form modal).
  defp close_form_modal(socket) do
    socket
    |> assign(:site_modal, default_site_modal())
    |> hide_site_modal()
  end

  defp show_site_modal(socket),
    do: exec_site_modal_js(socket, MishkaCmsCore.CoreComponents.show_modal(@site_modal_id))

  defp hide_site_modal(socket),
    do: exec_site_modal_js(socket, MishkaCmsCore.CoreComponents.hide_modal(@site_modal_id))

  defp exec_site_modal_js(socket, js),
    do: push_event(socket, "gervaz:exec-js", %{target: @site_modal_id, js: Jason.encode!(js.ops)})

  @impl true
  def mount(_params, _session, socket) do
    socket = assign_new(socket, :current_user, fn -> nil end)

    # The site-health hook must attach BEFORE ActivityFeed.setup, which halts Oban
    # broadcasts; this hook refreshes the open site's health panel from them first.
    socket =
      socket
      |> assign(:viewer_oban, oban_admin?(socket.assigns.current_user))
      |> assign(:expanded_site_id, nil)
      |> assign(:expanded_site_name, nil)
      |> assign(:failed_job_ids, MapSet.new())
      |> assign(:site_asset_topic, nil)
      |> Phoenix.LiveView.attach_hook(:site_health, :handle_info, &site_health_hook/2)

    # Site-wide feed: no `:resources` scope, so it shows every resource's logs.
    socket = ActivityFeed.setup(socket, feed_id: "system-activity")

    new_socket =
      socket
      |> assign(:page_title, gettext("Listing Sites"))
      |> assign(:show_modal, false)
      |> assign(:selected_record, nil)
      |> assign(:site_modal, default_site_modal())
      |> assign(:url_state, nil)

    {:ok, new_socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_state = UrlSync.decode(params, uri, MishkaCmsCore.Runtime.Site)
    {:noreply, assign(socket, :url_state, url_state)}
  end

  @impl true
  def handle_info({:form_saved, :create, _result}, socket) do
    {:noreply,
     socket
     |> close_form_modal()
     |> put_flash(:info, gettext("Site created successfully"))}
  end

  @impl true
  def handle_info({:form_saved, :update, _result}, socket) do
    {:noreply,
     socket
     |> close_form_modal()
     |> put_flash(:info, gettext("Site updated successfully"))}
  end

  @impl true
  def handle_info({:form_cancelled, _resource}, socket) do
    {:noreply, close_form_modal(socket)}
  end

  @impl true
  def handle_info({:show_modal, record}, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, true)
     |> assign(:selected_record, record)}
  end

  # Eye action → open the details modal on Overview; edit pencil → open on Configuration with the
  # record loaded into the form. Both load the record + its real health asynchronously.
  @impl true
  def handle_info({:row_action, "show_site_modal", %{"id" => id}}, socket),
    do: {:noreply, open_site_modal(socket, id, "overview")}

  @impl true
  def handle_info({:row_action, "edit_site_modal", %{"id" => id}}, socket),
    do: {:noreply, open_site_modal(socket, id, "configuration")}

  @impl true
  def handle_info({:put_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "site" <> _,
          payload: %Ash.Notifier.Notification{} = notification
        },
        socket
      ) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: "sites-table",
      pubsub_notification: notification
    )

    {:noreply, socket}
  end

  # Other broadcasts (other resources' notifications) are already forwarded to
  # the feed by the hook `ActivityFeed.setup/2` attached; swallow them here.
  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:expand_row, id}, socket) do
    {:noreply, load_site(socket, id)}
  end

  @impl true
  def handle_async({:load_expanded, _id}, {:ok, %{site: site, health: health}}, socket) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: "sites-table",
      expanded_html: render_panel(health, socket.assigns.viewer_oban)
    )

    {:noreply,
     socket
     |> assign(:expanded_site_name, site.name)
     |> assign(:failed_job_ids, failed_ids(health))
     |> maybe_subscribe_assets(site.name)}
  end

  def handle_async({:load_expanded, _id}, {:exit, reason}, socket) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: "sites-table",
      expanded_error: reason
    )

    {:noreply, socket}
  end

  def handle_async({:load_site_modal, _id}, {:ok, %{site: site, health: health}}, socket) do
    modal = %{socket.assigns.site_modal | record: site, health: health, loading?: false}
    {:noreply, assign(socket, :site_modal, modal)}
  end

  def handle_async({:load_site_modal, _id}, {:exit, _reason}, socket) do
    {:noreply, assign(socket, :site_modal, %{socket.assigns.site_modal | loading?: false})}
  end

  # + Add Site → open the modal on Configuration with an empty form (no Overview tab).
  @impl true
  def handle_event("site_modal_add", _params, socket) do
    {:noreply,
     socket
     |> assign(:site_modal, %{
       default_site_modal()
       | active_tab: "configuration",
         config_mounted?: true
     })
     |> show_site_modal()}
  end

  # Tab switch (also the header "Edit" button → configuration). The form's `record_id` flows from
  # `@site_modal.form_record_id` through the template, so no send_update is needed here.
  def handle_event("site_modal_set_tab", %{"tab" => tab}, socket) do
    modal = socket.assigns.site_modal

    {:noreply,
     assign(socket, :site_modal, %{
       modal
       | active_tab: tab,
         config_mounted?: modal.config_mounted? or tab == "configuration"
     })}
  end

  def handle_event("close_site_modal", _params, socket),
    do: {:noreply, socket |> assign(:site_modal, default_site_modal()) |> hide_site_modal()}

  # Master-only management actions, now buttons inside the modal (were row actions). Each runs the
  # Ash update on the open record, then reloads the modal (record + health); the table refreshes via
  # the site PubSub notification the action emits.
  def handle_event("site_activate", _params, socket),
    do: {:noreply, run_site_action(socket, :activate, gettext("Site activated"))}

  def handle_event("site_deactivate", _params, socket),
    do: {:noreply, run_site_action(socket, :deactivate, gettext("Site deactivated"))}

  def handle_event("site_set_master", _params, socket),
    do: {:noreply, run_site_action(socket, :set_as_master, gettext("Master site updated"))}

  @impl true
  def handle_event("retry_job", %{"id" => id}, socket),
    do: {:noreply, job_action(socket, id, &Oban.retry_job/1)}

  def handle_event("cancel_job", %{"id" => id}, socket),
    do: {:noreply, job_action(socket, id, &Oban.cancel_job/1)}

  def handle_event("delete_job", %{"id" => id}, socket),
    do: {:noreply, job_action(socket, id, &Oban.delete_job/1)}

  def handle_event("dismiss_failures", _params, socket) do
    Enum.each(socket.assigns.failed_job_ids, fn id ->
      with {int_id, ""} <- Integer.parse(id),
           true <- owns_job?(socket, int_id),
           do: Oban.delete_job(int_id)
    end)

    {:noreply, refresh(socket)}
  end

  defp failed_ids(health),
    do: (health.unrecovered ++ health.recovered) |> Enum.map(& &1.id) |> MapSet.new()

  # Two independent gates before any Oban write: the id must be one shown in THIS site's
  # panel AND, re-checked against the DB, the job must belong to the viewer's site (master =
  # any). The DB re-check is the real ACL boundary — it doesn't trust the rendered set, so a
  # forged or cross-tenant id is rejected regardless of what's in `failed_job_ids`.
  defp job_action(socket, id, fun) do
    with true <- MapSet.member?(socket.assigns.failed_job_ids, id),
         {int_id, ""} <- Integer.parse(id),
         true <- owns_job?(socket, int_id) do
      fun.(int_id)
      refresh(socket)
    else
      _ -> socket
    end
  end

  defp owns_job?(%{assigns: %{current_user: %{site_id: site_id}}}, int_id)
       when is_binary(site_id),
       do: job_belongs_to_site?(int_id, site_id)

  defp owns_job?(%{assigns: %{current_user: %{site_id: nil}}}, _int_id), do: true
  defp owns_job?(_socket, _int_id), do: false

  defp job_belongs_to_site?(int_id, site_id) do
    sql =
      "SELECT 1 FROM oban_jobs WHERE id = $1 " <>
        "AND COALESCE(args->>'site_id', args#>>'{data,site_id}') = $2 LIMIT 1"

    case Ecto.Adapters.SQL.query(@repo, sql, [int_id, site_id]) do
      {:ok, %{num_rows: n}} -> n > 0
      _ -> false
    end
  end

  # The `:require_oban_admin` route gate's own rule.
  defp oban_admin?(user), do: Helper.oban_admin?(user)

  defp load_site(socket, id) do
    current_user = socket.assigns.current_user

    socket
    |> assign(:expanded_site_id, id)
    |> MishkaGervaz.Messages.start_async({:load_expanded, id}, fn ->
      site = get_site(id, current_user)
      %{site: site, health: SiteHealth.compute(site)}
    end)
  end

  defp open_site_modal(socket, id, tab) do
    current_user = socket.assigns.current_user

    socket
    |> assign(:site_modal, %{
      default_site_modal()
      | active_tab: tab,
        loading?: true,
        form_record_id: id,
        config_mounted?: tab == "configuration"
    })
    |> show_site_modal()
    |> MishkaGervaz.Messages.start_async({:load_site_modal, id}, fn ->
      site = get_site(id, current_user)
      %{site: site, health: SiteHealth.compute(site)}
    end)
  end

  defp run_site_action(socket, action, flash) do
    record = socket.assigns.site_modal.record
    actor = socket.assigns.current_user

    case record && Ash.update(record, %{}, action: action, actor: actor) do
      {:ok, _updated} ->
        socket
        |> MishkaGervaz.Messages.start_async({:load_site_modal, record.id}, fn ->
          site = get_site(record.id, actor)
          %{site: site, health: SiteHealth.compute(site)}
        end)
        |> put_flash(:info, flash)

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        put_flash(socket, :error, Enum.map_join(errors, " ", &refusal(&1, record)))

      {:error, _reason} ->
        put_flash(socket, :error, gettext("Action could not be completed"))

      _ ->
        socket
    end
  end

  # The refusal's own sentence, without the breadcrumbs `Exception.message/1` puts in front of it,
  # in the reader's language — the way Gervaz words a table's error flash.
  defp refusal(%{message: message} = error, %resource{}) when is_binary(message),
    do: MishkaGervaz.Errors.extract_error_message(error, resource)

  defp refusal(error, _record), do: MishkaGervaz.Errors.extract_error_message(error)

  # Master users (`site_id` nil) read any site (`:master_get`); tenant users get only their own site
  # (`:tenant_get` filters `id == ^actor(:site_id)` and its TenantContext validation
  # requires the tenant in context). No other shape reads anything: the load exits and
  # `handle_async` clears the spinner.
  defp get_site(id, %{site_id: site_id} = actor) when is_binary(site_id),
    do:
      Ash.get!(MishkaCmsCore.Runtime.Site, id, action: :tenant_get, actor: actor, tenant: site_id)

  defp get_site(id, %{site_id: nil} = actor),
    do: Ash.get!(MishkaCmsCore.Runtime.Site, id, action: :master_get, actor: actor)

  defp refresh(%{assigns: %{expanded_site_id: nil}} = socket), do: socket
  defp refresh(%{assigns: %{expanded_site_id: id}} = socket), do: load_site(socket, id)

  # Refresh the open site on realtime signals. Match Oban jobs by site_id (per-record) or
  # site_name (asset bundle); `{:cont}` so the ActivityFeed hook still forwards them.
  defp site_health_hook(
         %Phoenix.Socket.Broadcast{event: "oban_activity", payload: %{__oban__: true, job: job}},
         socket
       ) do
    if site_match?(socket, job_site_id(job)) or name_match?(socket, job_site_name(job)),
      do: {:cont, refresh(socket)},
      else: {:cont, socket}
  end

  defp site_health_hook({tag, _hash}, socket) when tag in [:css_updated, :js_updated],
    do: {:halt, refresh(socket)}

  defp site_health_hook(_message, socket), do: {:cont, socket}

  defp site_match?(%{assigns: %{expanded_site_id: nil}}, _id), do: false
  defp site_match?(_socket, nil), do: false

  defp site_match?(%{assigns: %{expanded_site_id: open}}, id),
    do: to_string(open) == to_string(id)

  defp job_site_id(%{args: %{"site_id" => id}}) when is_binary(id), do: id
  defp job_site_id(%{args: %{"data" => %{"site_id" => id}}}) when is_binary(id), do: id
  defp job_site_id(_job), do: nil

  defp job_site_name(%{args: %{"data" => %{"site_name" => name}}}) when is_binary(name), do: name
  defp job_site_name(%{args: %{"site_name" => name}}) when is_binary(name), do: name
  defp job_site_name(_job), do: nil

  defp name_match?(%{assigns: %{expanded_site_name: nil}}, _name), do: false
  defp name_match?(_socket, nil), do: false
  defp name_match?(%{assigns: %{expanded_site_name: open}}, name), do: open == name

  defp maybe_subscribe_assets(socket, site_name) do
    topic = "site:#{site_name}:assets"

    cond do
      !Phoenix.LiveView.connected?(socket) ->
        socket

      socket.assigns.site_asset_topic == topic ->
        socket

      true ->
        if socket.assigns.site_asset_topic,
          do: Phoenix.PubSub.unsubscribe(MishkaCmsCore.PubSub, socket.assigns.site_asset_topic)

        Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, topic)
        assign(socket, :site_asset_topic, topic)
    end
  end

  defp render_panel(health, viewer_oban) do
    assigns = %{health: health, viewer_oban: viewer_oban}

    ~H"""
    <SiteHealthPanel.panel health={@health} viewer_oban={@viewer_oban} />
    """
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end
end
