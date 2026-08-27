defmodule MishkaCmsCore.Accounts.User.Notices.TwoStepReminder do
  @moduledoc """
  A mishka_installer plugin on `"AuthController.Success.SignIn"`: an admin of a site that recommends
  two-step sign-in (`MishkaCmsCore.Accounts.SecondFactor.reminded?/1`), and has no authenticator, is
  sent a notification at every sign-in, linking to where it is set up. The dashboard says the same
  (`MishkaCmsCoreWeb.Live.Admin.Dashboard.Home.Index`). Registered in `MishkaCmsCore.Application`.
  """
  use MishkaInstaller.Event.Hook, event: "AuthController.Success.SignIn", initial: %{priority: 50}
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Accounts.SecondFactor
  alias MishkaCmsCore.Notify

  @impl true
  def call(%{user: %{id: user_id, site_id: site_id} = user} = data) do
    if SecondFactor.reminded?(user) do
      Notify.deliver(
        %{
          type: "cms_core:account:two_step_recommended",
          title: gettext_noop("Set up two-step sign-in"),
          body:
            gettext(
              "This site recommends signing in with a code from an authenticator app as well as your password."
            ),
          icon: "hero-shield-check",
          link: "/admin/dashboard/settings?tab=preferences",
          source: "cms_core"
        },
        users: [user_id],
        site_id: site_id
      )
    end

    {:reply, data}
  end

  def call(data), do: {:reply, data}
end
