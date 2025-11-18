defmodule MishkaCmsCore.PluginHooksTest do
  @moduledoc """
  The reusable plugin-hook notifier this library adds to its resources really does dispatch
  `cms_core:<resource>:after_<action>` when the real Ash action runs — asserted end to end through the
  live `MishkaInstaller` event engine, not by inspecting the notifier.

  Each extension proves the same for its own resources; see `MishkaDocument.PluginHooksTest`.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaInstaller.Event.{Event, EventHandler}

  alias MishkaCmsCore.Test.Plugins.{
    AccountsUserAfterRegister,
    AuthAccountWithheld,
    CorePageAfterCreate
  }

  @probes [
    {CorePageAfterCreate, "cms_core:page:after_create"},
    {AccountsUserAfterRegister, "cms_core:user:after_register_with_password"},
    {AuthAccountWithheld, "auth:account:withheld"}
  ]

  setup do
    Process.register(self(), :__plugin_hook_probe__)

    for {module, event} <- @probes, do: register_plugin(module, event)

    on_exit(fn ->
      for {module, _event} <- @probes, do: Event.unregister(:name, module, false)
    end)

    :ok
  end

  test "content: page :create dispatches cms_core:page:after_create" do
    page = create_page!()
    id = page.id

    assert_receive {:core_page_after_create, ^id, _meta}, 5000
  end

  test "accounts: user registration dispatches cms_core:user:after_register_with_password" do
    user = create_user!()
    id = user.id

    assert_receive {:accounts_user_after_register, ^id, _meta}, 5000
  end

  describe "auth:account:withheld" do
    # A notification's `actor` is an account its recipient reaches through another resource.
    setup do
      site = create_site!()
      author = create_user!(site_id: site.id)
      recipient = create_user!(site_id: site.id)

      notification =
        MishkaCmsCore.Notify.Notification
        |> Ash.Changeset.for_create(
          :deliver,
          %{type: "test:caused", title: "Caused", user_id: recipient.id, actor_id: author.id},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.create!()

      {:ok, site: site, recipient: recipient, notification: notification}
    end

    test "is announced when the account's site and permissions are held back from a caller", %{
      site: site,
      recipient: recipient,
      notification: notification
    } do
      Ash.load!(notification, [actor: [:site, :permissions]], actor: recipient, tenant: site.id)

      assert_receive {:account_withheld, withheld}, 5000
      assert Enum.sort(withheld) == [:permissions, :site]
    end

    test "is not announced for an admin, who is held back nothing", %{
      site: site,
      notification: notification
    } do
      admin = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)

      Ash.load!(notification, [actor: [:site, :permissions]], actor: admin, tenant: site.id)

      refute_receive {:account_withheld, _withheld}, 200
    end
  end

  defp register_plugin(module, event) do
    {:ok, _} =
      Event.write(%{
        name: module,
        event: event,
        extension: :mishka_installer,
        status: :started
      })

    :ok = EventHandler.do_compile(event, :start, false)
  end
end
