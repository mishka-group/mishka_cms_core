# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.SettingsLive do
  @moduledoc """
  The CMS settings admin page: a left rail of category tabs and a content panel whose fields are
  rendered dynamically from `MishkaCmsCore.Settings` definitions, one input per setting by its
  `type`. The markup lives in the co-located `settings_live.html.heex`.

  Settings are multitenant (see `MishkaCmsCore.Runtime.Setting`). A **master** admin picks a scope —
  "Global" (the value for every site) or a specific site — from the header; a **tenant** admin is
  locked to their own site. Each setting declares a `scope`: `:global` settings are editable only in
  the Global view (shown read-only to a site), `:master` settings are Global-only and hidden from a
  site entirely, `:site` settings only in a site view, and `:both` (a global default a site may
  override) in either, and one declared `editable?: false` is read-only to everyone. A setting is
  shown to whoever may write it (`MishkaCmsCore.Settings.writable?/2`): its declared `permission`, or
  `admin:dashboard:setting` when it declares none. A tab left with nothing to show is not drawn, so a
  dashboard admin without the setting area sees their own Preferences alone.

  Saving goes through `Settings.put_as/4`, which carries the admin as the Ash actor so
  `MishkaCmsCore.Runtime.Setting`'s own policies decide which site's row they may write. Scope is
  encoded as `nil` for the Global view and a site uuid for a specific site's view, and `write_scope/1`
  clamps a tenant to their own site — but that clamp is a convenience, not the boundary: a submitted
  scope that is not theirs is refused by the resource whether or not the page catches it first.

  A save only writes what actually changed, and only fields the browser sent (an unticked checkbox
  being the one thing whose absence is meaningful), so editing one input on a crowded tab costs one
  write and one broadcast instead of one per field on the tab.

  The page is live for everyone watching it: `MishkaCmsCore.Runtime.Setting` publishes every write to
  `"setting:updated"`, which the page subscribes to. A master acts on all of it; a tenant discards
  the writes belonging to sites other than its own (`reaches?/2`), so a neighbour's save never moves
  their page. A broadcast is also ignored while the viewer is mid-edit (`dirty?`), so someone else's
  save never clobbers unsaved input.

  Settings are drawn in the order they are declared. A named `:group` is one section, where its first
  setting stands; settings with no group form runs between the named groups, which have no heading.
  A group whose settings declare `collapsed: true` (`MishkaCmsCore.Settings.define/3`) is drawn as a
  closed accordion titled by the group, whatever its settings hold. It opens by itself only when a
  setting in it was refused by the last save (`open_group?/2`), so the message under the field is
  in view, and once drawn it stays as the admin left it, through every later change of the page. A
  refused value is said under its field, whatever the tab.

  A `:secret` setting (a provider's API key) is never drawn back: its field is empty, says the
  last four characters of what is stored, and a save that leaves it empty keeps the stored one. The
  Email tab adds a test email to any address, through the scope's provider, and the email history
  (`MishkaCmsCore.Mail.Delivery`).

  The SEO tab adds the Redraw share cards buttons (`MishkaCmsCoreWeb.Live.Admin.Components.ShareCardRedraw`)
  for whoever may change the site's logo: every share card of the scope — every active site in
  Global — and each producer's own, one row for each producer that answers
  `MishkaCmsCore.Runtime.ShareCard.targets_event/0`.

  See `MishkaCmsCore.Settings` and `MishkaCmsCore.Runtime.Setting`.
  """
  use MishkaCmsCore.ExtensionLiveView

  alias MishkaCmsCore.Accounts.AuthGate
  alias MishkaCmsCore.Captcha
  alias MishkaCmsCore.Captcha.Widget
  alias MishkaCmsCore.Mail
  alias MishkaCmsCore.Runtime.ShareCard
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Settings
  alias MishkaCmsCoreWeb.Live.Admin.Components.{MediaField, SecurityCards, ShareCardRedraw}
  alias Phoenix.LiveView.JS

  @badge_class "rounded-md border px-[7px] py-0.5 text-[9px] font-bold uppercase tracking-[0.08em]"

  @input_class "w-full rounded-xl border border-[#ecebe6] bg-[#faf9f6] text-[13.5px] font-medium text-[#1b1a18] outline-none transition focus:border-[#c3c1f0] focus:bg-white focus:shadow-[0_0_0_3px_rgba(91,87,214,0.1)] disabled:cursor-not-allowed disabled:bg-[#f2f1ec] disabled:text-[#9a978f]"

  @category_meta %{
    "general" =>
      {gettext_noop("General"), gettext_noop("Basic system settings and preferences"),
       "hero-shield-check"},
    "security" =>
      {gettext_noop("Security"),
       gettext_noop("Sign-in limits, closing sign-in or registration, and who still gets in"),
       "hero-lock-closed"},
    "notifications" =>
      {gettext_noop("Notifications"), gettext_noop("Alert preferences and channels"), "hero-bell"},
    "email" =>
      {gettext_noop("Email"), gettext_noop("Provider, sender, test email and history"),
       "hero-envelope"},
    "seo" =>
      {gettext_noop("SEO"), gettext_noop("Search engines, robots.txt and the sitemap"),
       "hero-magnifying-glass"},
    "data_backup" =>
      {gettext_noop("Data & Backup"), gettext_noop("Data management and backups"),
       "hero-circle-stack"},
    "blog" =>
      {gettext_noop("Blog"), gettext_noop("Blog extension settings"), "hero-document-text"},
    "document" =>
      {gettext_noop("Documents"), gettext_noop("Document extension settings"), "hero-folder"},
    "sidebar" =>
      {gettext_noop("Sidebar"), gettext_noop("Order and hide the admin navigation"),
       "hero-bars-3"},
    "preferences" =>
      {gettext_noop("Preferences"), gettext_noop("Your personal settings — only you see these"),
       "hero-user-circle"}
  }

  @impl true
  def mount(_params, _session, socket) do
    # Re-aggregate definitions: an extension's `settings:register` plugin may finish registering
    # AFTER the boot-time load ran, so refresh here (rare, admin-only page) to surface it reliably.
    Settings.load_definitions()
    user = socket.assigns[:current_user]
    master? = master?(user)

    {:ok,
     socket
     |> assign(page_title: gettext("Settings"))
     |> assign(master?: master?, categories: categories(user), active_tab: nil)
     |> assign(security_cards: SecurityCards.collect())
     |> assign(scopes: scope_options(master?))
     |> assign(active_scope: if(master?, do: nil, else: user.site_id))
     |> assign(can_redraw_cards?: can_redraw_cards?(user))
     |> subscribe_settings()}
  end

  # `"setting:updated"` carries EVERY write — global rows and all sites' — so one subscription is the
  # whole feed and `reaches?/2` decides what this viewer may act on. The resource's per-site topic
  # (`"setting:{uuid}:updated"`) is a strict subset of this one, so subscribing to it as well would
  # only deliver a tenant's own writes twice.
  defp subscribe_settings(socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "setting:updated")

    socket
  end

  # Personal "Preferences" always sits last; a tab whose every setting is permission-gated away or
  # out of scope never renders at all.
  defp categories(user) do
    {prefs, others} =
      Settings.definitions()
      |> Enum.filter(&(permitted?(&1, user) and in_reach?(&1, user)))
      |> Enum.map(& &1.category)
      |> Enum.uniq()
      |> Enum.split_with(&(&1 == "preferences"))

    others ++ prefs
  end

  defp permitted?(definition, user), do: Settings.writable?(definition, user)

  # A tenant's scope is its own site for good, so what no site sees is out of its reach; a master
  # (`site_id` nil) may switch to any scope; anybody else reaches nothing.
  defp in_reach?(definition, %{site_id: site_id}) when is_binary(site_id),
    do: field_visibility(definition.scope, site_id) != :hidden

  defp in_reach?(_definition, %{site_id: nil}), do: true
  defp in_reach?(_definition, _nobody), do: false

  # The active tab lives in the URL (`?tab=<category>`) so a tab is linkable/bookmarkable and the
  # back button works. An unknown/absent tab falls back to the first category.
  @impl true
  def handle_params(params, _uri, socket) do
    categories = socket.assigns.categories
    tab = if params["tab"] in categories, do: params["tab"], else: List.first(categories)
    {:noreply, select_tab(socket, tab)}
  end

  @impl true
  def handle_event("switch_scope", %{"scope" => scope}, %{assigns: %{master?: true}} = socket) do
    active_scope = if scope in ["", "global"], do: nil, else: scope

    {:noreply,
     socket |> assign(active_scope: active_scope) |> select_tab(socket.assigns.active_tab)}
  end

  def handle_event("switch_scope", _params, socket), do: {:noreply, socket}

  def handle_event("validate", %{"settings" => params}, socket) do
    merged = Map.merge(socket.assigns.form.params, params)
    errors = Map.drop(socket.assigns.field_errors, Map.keys(params))

    {:noreply,
     assign(socket, dirty?: true, field_errors: errors, form: to_form(merged, as: :settings))}
  end

  # A save that would shut the admin making it out — sign them out, or leave them unable to sign in
  # again — is refused whole, judged on the tab as it will stand, before anything is written.
  def handle_event("save", %{"settings" => params}, socket) do
    scope = write_scope(socket)

    if AuthGate.locks_out?(scope, socket.assigns.current_user, pending(params, socket, scope)) do
      {:noreply,
       socket
       |> put_flash(
         :error,
         gettext(
           "This would shut you out too. Add your permission or email to Still allowed first."
         )
       )
       |> assign(form: to_form(params, as: :settings))}
    else
      save(params, socket, scope)
    end
  end

  def handle_event("clear_secret", %{"key" => key}, socket) do
    with {definition, true} <- Enum.find(socket.assigns.fields, &(elem(&1, 0).key == key)),
         {:ok, _cleared} <- write_setting(socket, definition, "", write_scope(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("The key was removed."))
       |> select_tab(socket.assigns.active_tab)}
    else
      _refused -> {:noreply, put_flash(socket, :error, gettext("The key could not be removed."))}
    end
  end

  def handle_event("send_test_email", %{"to" => to}, socket) do
    case can_mail?(socket) && Mail.send_test(write_scope(socket), to) do
      {:ok, _message_id} ->
        send_update(MishkaGervaz.Table.Web.Live, id: "mail-deliveries", gervaz_refresh: true)
        {:noreply, put_flash(socket, :info, gettext("Test email sent to %{to}.", to: to))}

      {:error, why} ->
        send_update(MishkaGervaz.Table.Web.Live, id: "mail-deliveries", gervaz_refresh: true)
        {:noreply, put_flash(socket, :error, gettext("Not sent: %{why}", why: why))}

      false ->
        {:noreply, socket}
    end
  end

  # A TEST SPENDS ITS TOKEN, passed or not, so the box asks for a fresh check either way.
  def handle_event("test_captcha", params, socket) do
    token = get_in(params, ["captcha", "captcha_token"])
    socket = push_event(socket, "mishka:captcha:reset", %{})

    case can_test_captcha?(socket) && Captcha.test(write_scope(socket), token, %{remote_ip: nil}) do
      {:ok, text} -> {:noreply, put_flash(socket, :info, text)}
      {:error, text} -> {:noreply, put_flash(socket, :error, text)}
      false -> {:noreply, socket}
    end
  end

  def handle_event("reset", _params, socket) do
    values =
      Map.new(socket.assigns.fields, fn {definition, _} ->
        {definition.key, definition.default}
      end)

    {:noreply, assign(socket, dirty?: true, form: to_form(values, as: :settings))}
  end

  @doc """
  A setting changed somewhere. The global `setting:updated` topic carries EVERY site's writes, so a
  tenant drops the ones outside its reach (`reaches?/2`) rather than re-reading for a site it cannot
  see. A refresh is also skipped mid-edit so a broadcast never clobbers unsaved input.
  """
  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{topic: "setting:" <> _} = broadcast, socket) do
    if socket.assigns.dirty? or !reaches?(socket, broadcast),
      do: {:noreply, socket},
      else: {:noreply, select_tab(socket, socket.assigns.active_tab)}
  end

  # A security card changed what the others show — two-step turned on, say, so recovery codes can be
  # made now. See `SecurityCards`.
  def handle_info(:account_security_changed, socket) do
    SecurityCards.refresh(socket.assigns.security_cards)
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # A master reaches every site; a tenant reaches the global rows (`site_id` nil) and its own only.
  # A payload without a resolvable site (a hand-sent broadcast, a plugin ping) is always let through.
  defp reaches?(%{assigns: %{master?: true}}, _broadcast), do: true

  defp reaches?(socket, %{payload: %{data: %{site_id: site_id}}}) when not is_nil(site_id),
    do: site_id == socket.assigns.current_user.site_id

  defp reaches?(_socket, _broadcast), do: true

  defp select_tab(socket, nil) do
    assign(socket,
      active_tab: nil,
      fields: [],
      form: to_form(%{}, as: :settings),
      field_errors: %{},
      secret_hints: %{},
      dirty?: false,
      attention: %{},
      captcha_test_id: nil,
      share_card_producers: []
    )
  end

  defp select_tab(socket, tab) do
    fields = visible_fields(socket, tab)

    values =
      Map.new(fields, fn {definition, _editable} ->
        {definition.key, read_value(socket, definition)}
      end)

    assign(socket,
      active_tab: tab,
      fields: fields,
      field_groups: group_fields(fields),
      form: to_form(values, as: :settings),
      field_errors: %{},
      secret_hints: secret_hints(socket, fields),
      dirty?: false,
      attention: attention_map(socket),
      captcha_test_id: captcha_test_id(socket, tab),
      share_card_producers: share_card_producers(socket, tab)
    )
  end

  # The producers whose cards the SEO tab may redraw one by one: whoever answers the targets event.
  defp share_card_producers(socket, "seo") do
    if socket.assigns.can_redraw_cards?,
      do: ShareCard.producers(socket.assigns.active_scope),
      else: []
  end

  defp share_card_producers(_socket, _tab), do: []

  # THE TEST BOX IS DRAWN AFRESH for each scope and each change of its provider or keys: the hook
  # owns the box (`phx-update="ignore"`), so another configuration needs another element.
  defp captcha_test_id(socket, "security") do
    case Captcha.browser(socket.assigns.active_scope, :test, Gettext.get_locale()) do
      nil -> nil
      browser -> "captcha-test-#{:erlang.phash2({socket.assigns.active_scope, browser})}"
    end
  end

  defp captcha_test_id(_socket, _tab), do: nil

  # The captcha test is the captcha settings' own: whoever may change those may use it.
  defp can_test_captcha?(socket),
    do:
      Settings.writable?(
        Settings.definition("security.captcha.provider"),
        socket.assigns.current_user
      )

  # What the page may say about a stored secret: its last four characters, never more — or that it
  # can no longer be read (`MishkaCmsCore.Settings.secret_hint/2`).
  defp secret_hints(socket, fields) do
    for {%{type: :secret} = definition, _editable} <- fields,
        into: %{},
        do: {definition.key, Settings.secret_hint(definition.key, socket.assigns.active_scope)}
  end

  # Redrawing the share cards is the card settings' own: whoever may change the site's logo may.
  defp can_redraw_cards?(user) do
    case Settings.definition("site.logo") do
      nil -> false
      definition -> Settings.writable?(definition, user)
    end
  end

  # What a producer is called: its application's description, else its name.
  defp producer_label(producer) do
    Enum.find_value(Application.loaded_applications(), producer, fn {app, description, _vsn} ->
      Atom.to_string(app) == producer and description != [] and List.to_string(description)
    end)
  end

  # The test email and the history are the email settings' own: whoever may change those may use them.
  defp can_mail?(socket),
    do: Settings.writable?(Settings.definition("mailer.provider"), socket.assigns.current_user)

  # A tab is flagged while any setting it shows still holds a placeholder default the admin is
  # expected to replace (`attention_on_default` — see `MishkaCmsCore.Settings.define/3`), or a key
  # the server can no longer read.
  defp attention_map(socket) do
    Map.new(socket.assigns.categories, &{&1, attention?(socket, &1)})
  end

  # A KEY THE SERVER CAN NO LONGER READ flags its tab too: whatever used it has stopped.
  defp attention?(socket, category) do
    socket
    |> visible_fields(category)
    |> Enum.any?(fn {definition, _editable} ->
      (definition.attention_on_default and read_value(socket, definition) == definition.default) or
        (definition.type == :secret and
           Settings.secret_hint(definition.key, socket.assigns.active_scope) == :unreadable)
    end)
  end

  defp secret_placeholder(last) when is_binary(last),
    do: gettext("Saved, ends in %{last} — type a new one to replace it", last: last)

  defp secret_placeholder(:unreadable),
    do: gettext("Saved with an older server key — type it again")

  defp secret_placeholder(nil), do: gettext("Not set")

  # `:user` scope reads/writes the current user's own value (Preferences tab); everything else uses
  # the active site/global scope.
  # A stored secret never goes into the form: the field starts empty, and empty keeps it.
  defp read_value(_socket, %{type: :secret}), do: ""

  defp read_value(%{assigns: %{active_scope: site_id}}, %{resolve: :own} = definition)
       when is_binary(site_id),
       do: Settings.get_own(definition.key, definition.default, site_id)

  defp read_value(socket, %{scope: :user} = definition),
    do: Settings.get_user(definition.key, socket.assigns.current_user.id, definition.default)

  # A site's own value for a setting whose global value is OR-ed with it: showing the global one
  # there would offer a switch that, turned off and saved, changes nothing.
  defp read_value(%{assigns: %{active_scope: site_id}}, %{resolve: :any} = definition)
       when is_binary(site_id),
       do: Settings.get_own(definition.key, definition.default, site_id)

  defp read_value(socket, definition),
    do: Settings.get(definition.key, definition.default, socket.assigns.active_scope)

  # Whether the global value holds an OR-ed setting on for the site in view, whatever the site set.
  defp held_globally?(%{resolve: :any} = definition, site_id) when is_binary(site_id),
    do: Settings.get(definition.key, definition.default) == true

  defp held_globally?(_definition, _scope), do: false

  # Split the visible fields into `{section, fields}` in the order they are declared. A section is
  # `{:group, name}` for a named group — one section, where its first field stands, however far
  # apart its fields are declared — or `{:ungrouped, n}` for a run of fields with no group, which
  # a named group's field ends: a tab that declares title, logo, a group, then more ungrouped
  # fields draws two runs around the group, numbered from 1 in the order they are drawn.
  defp group_fields(fields) do
    fields
    |> Enum.reduce([], &place_field/2)
    |> Enum.map(fn {section, fields} -> {section, Enum.reverse(fields)} end)
    |> Enum.reverse()
  end

  defp place_field({%{group: nil}, _} = field, [{{:ungrouped, _} = run, fields} | sections]),
    do: [{run, [field | fields]} | sections]

  defp place_field({%{group: nil}, _} = field, sections),
    do: [{{:ungrouped, Enum.count(sections, &run?/1) + 1}, [field]} | sections]

  defp place_field({%{group: group}, _} = field, sections) do
    section = {:group, group}

    if List.keymember?(sections, section, 0) do
      Enum.map(sections, fn
        {^section, fields} -> {section, [field | fields]}
        other -> other
      end)
    else
      [{section, [field]} | sections]
    end
  end

  defp run?({{:ungrouped, _}, _fields}), do: true
  defp run?({{:group, _}, _fields}), do: false

  # The sections and fields shown beside the tab's values as they stand on screen — a provider's
  # fields while it is the one chosen (`MishkaCmsCore.Settings.visible?/2`); a section left empty
  # goes too.
  defp shown_groups(field_groups, values) do
    for {section, fields} <- field_groups,
        shown =
          Enum.filter(fields, fn {definition, _editable} ->
            Settings.visible?(definition, values)
          end),
        shown != [],
        do: {section, shown}
  end

  # A named group is an accordion while any setting shown in it declares `collapsed: true`; a run
  # of ungrouped settings is never one.
  defp collapsible?({:group, _group}, fields),
    do: Enum.any?(fields, fn {definition, _editable} -> definition.collapsed == true end)

  defp collapsible?({:ungrouped, _n}, _fields), do: false

  # Whether an accordion is drawn open: the last save refused one of its settings, so the message
  # under the field is not hidden. It is the first draw only; the browser keeps what the admin did.
  defp open_group?(fields, errors),
    do: Enum.any?(fields, fn {definition, _editable} -> Map.has_key?(errors, definition.key) end)

  defp section_title({:group, group}), do: Settings.text(group)
  defp section_title({:ungrouped, _n}), do: nil

  # A section's id names the scope as well, so another site's view draws its own closed or open
  # rather than keeping the one the admin left in the last. The first run of ungrouped settings
  # is `settings-ungrouped`, the next `settings-ungrouped-2`.
  defp group_id({:ungrouped, 1}, _scope), do: "settings-ungrouped"
  defp group_id({:ungrouped, n}, _scope), do: "settings-ungrouped-#{n}"

  defp group_id({:group, group}, scope) do
    slug =
      group
      |> group_name()
      |> String.downcase()
      |> then(&Regex.replace(~r/[^\p{L}\p{N}]+/u, &1, "-"))
      |> String.trim("-")

    "settings-group-#{slug}-#{scope || "global"}"
  end

  defp group_name({msgid, _bindings}), do: msgid
  defp group_name(msgid), do: msgid

  # What this viewer may see in `tab`: whether they may write the setting gates it entirely, then the
  # active scope decides editable vs read-only vs gone (`field_visibility/2`).
  defp visible_fields(socket, tab) do
    tab
    |> Settings.definitions()
    |> Enum.filter(&permitted?(&1, socket.assigns.current_user))
    |> Enum.flat_map(fn definition ->
      case field_visibility(definition.scope, socket.assigns.active_scope) do
        :hidden -> []
        visibility -> [{definition, visibility == :editable and definition.editable?}]
      end
    end)
  end

  defp field_visibility(:master, nil), do: :editable
  defp field_visibility(:master, _site_id), do: :hidden
  defp field_visibility(:site, nil), do: :hidden
  defp field_visibility(:global, site_id) when not is_nil(site_id), do: :readonly
  defp field_visibility(_scope, _active), do: :editable

  # A per-field badge telling the admin the reach of each setting: only them, this site, or everyone.
  # THE SCOPE A SAVE HERE WRITES, which is what the badge says — read from the scope in view, not
  # from the scopes a setting allows: everything edited in the Global view is Global's, and in a
  # site's view only the settings a site may hold are "This site".
  defp reach(%{scope: :user}, _active), do: :user
  defp reach(_definition, nil), do: :global
  defp reach(%{scope: scope}, _site) when scope in [:global, :master], do: :global
  defp reach(_definition, _site), do: :site

  defp scope_badge_label(definition, active), do: definition |> reach(active) |> reach_label()

  defp reach_label(:user), do: gettext("Just for you")
  defp reach_label(:global), do: gettext("Global")
  defp reach_label(:site), do: gettext("This site")

  defp scope_badge_class(definition, active), do: definition |> reach(active) |> reach_class()

  defp reach_class(:user), do: "border-[#cdeadb] bg-[#e6f6ee] text-[#177a53]"
  defp reach_class(:global), do: "border-[#eceae4] bg-[#f2f1ec] text-[#8a877f]"
  defp reach_class(:site), do: "border-[#f0e2c4] bg-[#fbf1df] text-[#a5691a]"

  # A FIELD NOT SHOWN IS NOT SAVED: the form sends nothing for it, and a missing switch would read as
  # off. A provider's keys stay as they were while another provider is chosen.
  defp save(params, socket, scope) do
    values = Map.merge(socket.assigns.form.params, params)

    results =
      Enum.flat_map(socket.assigns.fields, fn
        {definition, true} ->
          if Settings.visible?(definition, values),
            do: submitted(params, definition, socket, scope),
            else: []

        {_definition, false} ->
          []
      end)

    if Enum.all?(results, &match?({:ok, _}, &1)) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Settings saved."))
       |> select_tab(socket.assigns.active_tab)}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("Some settings could not be saved."))
       |> assign(field_errors: refused(results), form: to_form(params, as: :settings))}
    end
  end

  # The settings whose submitted value `Settings.cast/2` refused, by key.
  defp refused(results),
    do: for({:error, key} <- results, is_binary(key), into: %{}, do: {key, true})

  # What the tab would hold once saved, as `MishkaCmsCore.Accounts.AuthGate.pending()`.
  defp pending(params, socket, scope) do
    values = Map.merge(socket.assigns.form.params, params)

    for {definition, true} <- socket.assigns.fields,
        Settings.visible?(definition, values),
        {:ok, raw} <- [raw(params, definition)],
        {:ok, value} <- [Settings.cast(definition, raw)],
        into: %{},
        do: {{scope, definition.key}, value}
  end

  defp raw(params, %{type: :boolean, key: key}), do: {:ok, Map.get(params, key)}
  defp raw(params, %{key: key}), do: Map.fetch(params, key)

  defp submitted(params, %{type: :boolean} = definition, socket, scope),
    do: [store(socket, definition, Map.get(params, definition.key), scope)]

  defp submitted(params, definition, socket, scope) do
    case Map.fetch(params, definition.key) do
      {:ok, raw} -> [store(socket, definition, raw, scope)]
      :error -> []
    end
  end

  defp store(socket, definition, raw, scope) do
    case Settings.cast(definition, raw) do
      {:ok, value} -> write_unchanged(socket, definition, value, scope)
      :error -> {:error, definition.key}
    end
  end

  defp write_unchanged(socket, definition, value, scope) do
    if read_value(socket, definition) == value,
      do: {:ok, value},
      else: write_setting(socket, definition, value, scope)
  end

  defp write_setting(socket, %{scope: :user} = definition, value, _scope),
    do: Settings.put_user(definition.key, value, socket.assigns.current_user.id)

  defp write_setting(socket, definition, value, scope),
    do:
      Settings.put_as(socket.assigns.current_user, definition.key, value,
        site_id: scope,
        category: definition.category,
        source: definition.source,
        editable?: definition.editable?
      )

  defp write_scope(%{assigns: %{master?: true, active_scope: scope}}), do: scope
  defp write_scope(%{assigns: %{current_user: %{site_id: site_id}}}), do: site_id

  defp scope_options(false), do: []

  # Every site, a switched-off one included: its settings are still the master's to manage.
  defp scope_options(true) do
    sites = Enum.map(SiteState.stream(%{}), &{site_label(&1), &1.id})
    [{gettext("Global"), nil} | sites]
  end

  defp site_label(%{name: name, active: false}), do: gettext("%{name} (inactive)", name: name)
  defp site_label(%{name: name}), do: name

  defp scope_label(scope, scopes) do
    case Enum.find(scopes, fn {_label, value} -> value == scope end) do
      {label, _} -> label
      nil -> gettext("this site")
    end
  end

  defp master?(%{site_id: nil}), do: true
  defp master?(_), do: false

  defp field_name(definition), do: "settings[#{definition.key}]"

  # A picture chosen in Media Manager, or cleared, reaches the form as the field's own change does.
  defp pick(key), do: &JS.push("validate", value: %{"settings" => %{key => &1}})

  defp dom_id(key), do: String.replace(key, ".", "-")

  defp field_label(%{global_label: label}, nil) when not is_nil(label), do: Settings.text(label)
  defp field_label(definition, _scope), do: Settings.text(definition.label) || definition.key

  defp option_value({_label, value}), do: value
  defp option_value(value), do: value

  defp option_label({label, _value}), do: Settings.text(label)
  defp option_label(value) when is_binary(value), do: Settings.text(value)
  defp option_label(value), do: value

  defp html_input_type(:integer), do: "number"
  defp html_input_type(_), do: "text"

  # A `:list` is typed as the comma-separated text `Settings.cast/2` splits again. Handed to the
  # attribute as a list, HEEx would join it with spaces, and the save would read one entry.
  defp input_value(value) when is_list(value), do: Enum.join(value, ", ")
  defp input_value(value), do: value

  attr :id, :string, required: true
  attr :title, :string, default: nil
  attr :collapsible?, :boolean, default: false
  attr :open?, :boolean, default: false
  slot :inner_block, required: true

  # A group of fields under its heading; an accordion when `collapsible?`. The browser owns
  # `<details open>` after the first draw (`JS.ignore_attributes/1`), so a re-render of the form
  # never shuts what the admin opened.
  defp group_section(%{collapsible?: true} = assigns) do
    ~H"""
    <details
      id={@id}
      data-role="settings-group"
      open={@open?}
      phx-mounted={JS.ignore_attributes(["open"])}
      class="group rounded-[13px] border border-[#f0efea] bg-[#faf9f6]"
    >
      <summary class="flex cursor-pointer list-none items-center justify-between gap-3 rounded-[13px] px-[18px] py-4 outline-none focus-visible:shadow-[0_0_0_3px_rgba(91,87,214,0.18)] [&::-webkit-details-marker]:hidden">
        <span class="text-[10.5px] font-bold uppercase tracking-[0.13em] text-[#8a877f]">
          {@title}
        </span>
        <.icon
          name="hero-chevron-down"
          class="size-[14px] shrink-0 text-[#a8a5a0] transition-transform group-open:rotate-180"
        />
      </summary>
      <div class="border-t border-[#f0efea] bg-white p-[18px] rounded-b-[13px]">
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  defp group_section(assigns) do
    ~H"""
    <div id={@id} data-role="settings-section">
      <h3
        :if={@title}
        class="m-0 mb-[15px] text-[10.5px] font-bold uppercase tracking-[0.13em] text-[#a8a5a0]"
      >
        {@title}
      </h3>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp badge_class, do: @badge_class

  defp input_class, do: @input_class

  defp truthy?(value), do: value in [true, "true", "on"]

  defp category_icon(category), do: elem(meta(category), 2)
  defp category_label(category), do: category |> meta() |> elem(0) |> Settings.text()
  defp category_description(category), do: category |> meta() |> elem(1) |> Settings.text()

  defp meta(nil), do: {gettext_noop("Settings"), nil, "hero-cog-6-tooth"}

  defp meta(category) do
    Map.get(
      @category_meta,
      category,
      {Phoenix.Naming.humanize(category),
       {gettext_noop("%{category} settings"), category: Phoenix.Naming.humanize(category)},
       "hero-squares-2x2"}
    )
  end
end
