defmodule MishkaCmsCore.MailTest do
  @moduledoc """
  `MishkaCmsCore.Mail`: one email, from the site it is for, through that site's own provider —
  the key sealed in Settings, no borrowing between scopes, the plugin seams, the queue, and Resend
  answered by a `Req.Test` stub instead of the network.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory
  import Swoosh.TestAssertions

  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use Oban.Testing, repo: @repo

  require Ash.Query

  alias MishkaCmsCore.Mail
  alias MishkaCmsCore.Mail.{Delivery, Provider}
  alias MishkaCmsCore.Mail.Workers.DeliverWorker
  alias MishkaCmsCore.Runtime.Setting
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Settings
  alias MishkaInstaller.Event.{Event, EventHandler}

  @key "mailer.resend.api_key"

  defmodule ResendStub do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "mail:deliver:before"

    @impl true
    def call(%{email: email} = data),
      do:
        {:reply,
         %{
           data
           | email: Swoosh.Email.put_private(email, :client_options, plug: {Req.Test, __MODULE__})
         }}
  end

  defmodule Suppress do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "mail:deliver:before"

    @impl true
    def call(data), do: {:reply, :halt, Map.put(data, :suppress, true)}
  end

  setup do
    snapshot = SettingsState.snapshot()
    Settings.load_definitions()

    site = create_site!(name: "acme", host: "acme.test", active: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    on_exit(fn ->
      SettingsState.restore(snapshot)
      SiteState.delete(site.id)
    end)

    %{site: site}
  end

  defp register(module, event) do
    {:ok, _} =
      Event.write(%{name: module, event: event, extension: :mishka_installer, status: :started})

    :ok = EventHandler.do_compile(event, :start, false)

    on_exit(fn ->
      Event.unregister(:name, module, false)
      EventHandler.do_compile(event, :start, false)
    end)
  end

  defp use_req_client do
    previous = Application.get_env(:swoosh, :api_client)
    Application.put_env(:swoosh, :api_client, Swoosh.ApiClient.Req)
    on_exit(fn -> Application.put_env(:swoosh, :api_client, previous) end)
  end

  defp resend!(site_id, key) do
    {:ok, _} = Settings.put("mailer.provider", "resend", site_id: site_id)
    {:ok, _} = Settings.put(@key, key, site_id: site_id)
  end

  defp email(site_id, to \\ "ada@example.com"),
    do: Mail.email(site_id, to: to, subject: "Hello", html: "<p>Hi</p>", text: "Hi")

  defp delivery!(id, site_id), do: Ash.get!(Delivery, id, authorize?: false, tenant: site_id)

  describe "a provider key in Settings" do
    test "is stored sealed, and only secret/2 opens it", %{site: site} do
      {:ok, _} = Settings.put(@key, "re_live_abcdef123456", site_id: site.id)

      row =
        Setting
        |> Ash.Query.filter(key == ^@key and site_id == ^site.id)
        |> Ash.read_one!(authorize?: false)

      refute inspect(row.value) =~ "re_live_abcdef123456"
      refute Settings.get_own(@key, nil, site.id) =~ "re_live"
      assert Settings.secret(@key, site.id) == "re_live_abcdef123456"
      assert Settings.secret_hint(@key, site.id) == "3456"
    end

    test "never reaches a request or event log" do
      params = %{"settings" => %{@key => "re_live_abcdef123456", "mailer.from" => "a@b.test"}}

      assert %{"settings" => %{@key => "[FILTERED]", "mailer.from" => "a@b.test"}} =
               Phoenix.Logger.filter_values(params)
    end

    test "is never borrowed: a site without its own reads none, whatever the installation holds",
         %{
           site: site
         } do
      {:ok, _} = Settings.put(@key, "re_installation_key_0001", site_id: nil)

      assert Settings.secret(@key, nil) == "re_installation_key_0001"
      assert Settings.secret(@key, site.id) == nil
    end
  end

  describe "the registry" do
    test "lists the core's providers as plugins, with Resend's own settings on the Email tab" do
      ids = Enum.map(Provider.offered(), & &1.id())

      assert "resend" in ids
      assert "dev_mailbox" in ids

      keys = Enum.map(Settings.definitions("email"), & &1.key)
      assert ["mailer.provider", "mailer.from" | _] = keys
      assert @key in keys
      assert %{type: :secret, resolve: :own} = Settings.definition(@key)
    end
  end

  describe "deliver/2" do
    test "sends from the site's own sender and records it", %{site: site} do
      {:ok, _} = Settings.put("mailer.from", "hello@acme.test", site_id: site.id)
      {:ok, _} = Settings.put("mailer.from_name", "Acme", site_id: site.id)
      {:ok, _} = Settings.put("mailer.reply_to", "help@acme.test", site_id: site.id)

      assert {:ok, %Delivery{} = delivery} =
               Mail.deliver(email(site.id), site_id: site.id, purpose: "welcome")

      assert_email_sent(
        from: {"Acme", "hello@acme.test"},
        to: "ada@example.com",
        subject: "Hello",
        reply_to: "help@acme.test"
      )

      assert %{status: :sent, purpose: "welcome", recipient: "ada@example.com"} =
               delivery!(delivery.id, site.id)
    end

    test "a site that set no address sends from its own domain, not the installation's", %{
      site: site
    } do
      {:ok, _} = Settings.put("mailer.from", "owner@installation.test", site_id: nil)

      Mail.deliver(email(site.id), site_id: site.id, purpose: "welcome")

      assert_email_sent(fn email -> assert elem(email.from, 1) == "noreply@acme.test" end)
    end

    test "an unset sender shows empty, and Global sends from the master site's domain" do
      {:ok, _} = Settings.put("mailer.from", "", site_id: nil)

      assert Settings.definition("mailer.from").default == ""
      assert "noreply@" <> _domain = Mail.from_address(nil)
      refute Mail.from_address(nil) == "noreply@example.com"
    end

    test "a site that chose no provider sends nothing, and says why", %{site: site} do
      {:ok, _} = Settings.put("mailer.provider", "none", site_id: site.id)

      assert {:error, :not_configured} =
               Mail.deliver(email(site.id), site_id: site.id, purpose: "welcome")

      refute_email_sent()

      assert [%{status: :not_configured, error: error}] =
               Ash.read!(Delivery, authorize?: false, tenant: site.id)

      assert error =~ "No email provider"
    end

    test "a site on Resend without its own key sends nothing, though the installation has one", %{
      site: site
    } do
      use_req_client()
      register(ResendStub, "mail:deliver:before")
      resend!(nil, "re_installation_key_0001")
      {:ok, _} = Settings.put("mailer.provider", "resend", site_id: site.id)

      Req.Test.stub(ResendStub, fn _conn -> flunk("Resend was called without the site's key") end)

      assert {:error, :not_configured} =
               Mail.deliver(email(site.id), site_id: site.id, purpose: "welcome")

      assert [%{status: :not_configured, error: error}] =
               Ash.read!(Delivery, authorize?: false, tenant: site.id)

      assert error =~ "missing its key"
    end

    test "a plugin on mail:deliver:before can stop an email", %{site: site} do
      register(Suppress, "mail:deliver:before")

      assert {:ok, :suppressed} =
               Mail.deliver(email(site.id), site_id: site.id, purpose: "welcome")

      refute_email_sent()
      assert [] = Ash.read!(Delivery, authorize?: false, tenant: site.id)
    end
  end

  describe "Resend" do
    setup %{site: site} do
      use_req_client()
      register(ResendStub, "mail:deliver:before")
      resend!(site.id, "re_site_key_abcdef1234")
      :ok
    end

    test "posts with the site's key and the idempotency key, and keeps the message id", %{
      site: site
    } do
      Req.Test.stub(ResendStub, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == [
                 "Bearer re_site_key_abcdef1234"
               ]

        assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["password_reset/abc"]
        Req.Test.json(conn, %{"id" => "msg_0001"})
      end)

      assert {:ok, delivery} =
               Mail.deliver(email(site.id),
                 site_id: site.id,
                 purpose: "password_reset",
                 idempotency_key: "password_reset/abc"
               )

      assert %{status: :sent, provider: "resend", message_id: "msg_0001"} =
               delivery!(delivery.id, site.id)
    end

    test "records what Resend refused, in its own words", %{site: site} do
      Req.Test.stub(ResendStub, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{
          "statusCode" => 403,
          "name" => "validation_error",
          "message" => "The acme.test domain is not verified."
        })
      end)

      {:ok, delivery} = Mail.deliver(email(site.id), site_id: site.id, purpose: "welcome")

      assert %{status: :failed, error: "403: The acme.test domain is not verified."} =
               delivery!(delivery.id, site.id)
    end

    test "a test email goes to any address and is recorded", %{site: site} do
      Req.Test.stub(ResendStub, fn conn -> Req.Test.json(conn, %{"id" => "msg_test"}) end)

      assert {:ok, "msg_test"} = Mail.send_test(site.id, "delivered@resend.dev")
      assert {:error, "That is not an email address."} = Mail.send_test(site.id, "nobody")

      assert [%{purpose: "test", status: :sent, recipient: "delivered@resend.dev"}] =
               Ash.read!(Delivery, authorize?: false, tenant: site.id)
    end

    test "retry?/1 retries what may pass later and nothing else" do
      resend = MishkaCmsCore.Mail.Providers.Resend

      assert resend.retry?({429, %{"name" => "rate_limit_exceeded"}})
      assert resend.retry?({503, %{"name" => "service_unavailable"}})
      assert resend.retry?({409, %{"name" => "concurrent_idempotent_requests"}})
      assert resend.retry?(%Req.TransportError{reason: :timeout})
      refute resend.retry?({429, %{"name" => "daily_quota_exceeded"}})
      refute resend.retry?({403, %{"name" => "validation_error"}})
      refute resend.retry?({401, %{"name" => "restricted_api_key"}})
    end
  end

  describe "the queue" do
    setup %{site: site} do
      Application.put_env(:mishka_cms_core, :env_test?, false)
      on_exit(fn -> Application.put_env(:mishka_cms_core, :env_test?, true) end)
      %{site: site}
    end

    test "a job carries the email sealed and no key, and sends it when it runs", %{site: site} do
      link = "https://acme.test/auth/password-reset/secret-token/"

      email =
        Mail.email(site.id, to: "ada@example.com", subject: "Reset", html: link, text: link)

      assert {:ok, delivery} = Mail.deliver(email, site_id: site.id, purpose: "password_reset")
      refute_email_sent()

      assert [job] = all_enqueued(worker: DeliverWorker)
      refute inspect(job.args) =~ "secret-token"
      assert job.args["delivery_id"] == delivery.id

      assert :ok = perform_job(DeliverWorker, job.args)
      assert_email_sent(subject: "Reset")
      assert %{status: :sent, attempts: 1} = delivery!(delivery.id, site.id)
    end

    test "a failure Resend may get past is retried, then the last attempt fails the delivery", %{
      site: site
    } do
      use_req_client()
      register(ResendStub, "mail:deliver:before")
      resend!(site.id, "re_site_key_abcdef1234")

      Req.Test.stub(ResendStub, fn conn ->
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"name" => "service_unavailable"})
      end)

      {:ok, delivery} = Mail.deliver(email(site.id), site_id: site.id, purpose: "welcome")
      [job] = all_enqueued(worker: DeliverWorker)

      assert {:error, _retry} = perform_job(DeliverWorker, job.args, attempt: 1)
      assert %{status: :queued, attempts: 1} = delivery!(delivery.id, site.id)

      assert {:cancel, _given_up} = perform_job(DeliverWorker, job.args, attempt: 5)
      assert %{status: :failed} = delivery!(delivery.id, site.id)
    end
  end
end
