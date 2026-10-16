# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Mail do
  @moduledoc """
  Sending email, for every site through its own provider.

  A consumer — a sign-in sender, a notification channel, an extension — builds a `Swoosh.Email`
  (`email/2` fills the site's sender) and calls `deliver/2` with the site it is for. It never names a provider: each scope picks one on the settings page's Email tab
  (`mailer.provider`), and providers are `mishka_installer` plugins (`MishkaCmsCore.Mail.Provider`),
  the core's own `Resend` included.

  ## No borrowing

  Each scope sends with what it set itself: a site with no provider, or one missing its key, sends
  nothing — not even through the installation's provider. `nil` as the site is the installation's
  own scope, which sends a master's email.

  ## The path of one email

    1. `"mail:deliver:before"` — a plugin may change the email (`{:reply, %{data | email: email}}`)
       or stop it (`{:reply, :halt, Map.put(data, :suppress, true)}`). A test email passes here too.
    2. A `MishkaCmsCore.Mail.Delivery` row is written: `:queued`, or `:not_configured` with the
       reason, and `"mail:not_configured"` fires.
    3. A `MishkaCmsCore.Mail.Workers.DeliverWorker` job on the `mail` queue sends it — inline under
       `env_test?`. The job carries the email sealed (it may hold a sign-in link) and no key; inside
       the caller's transaction, a rolled-back registration takes its job with it.
    4. The provider answers: the row goes `:sent` and `"mail:delivered"` fires, or the attempt is
       retried while the provider says it may succeed, then the row goes `:failed` and
       `"mail:failed"` fires. Resend's idempotency key keeps a retry from sending twice.

  The three notices are fired with `return: false`. Every job shows on the Activity page under its
  site, and every row on the Email tab.

  ## The sender

  `email/2` fills each scope's own `mailer.from`, `mailer.from_name` and `mailer.reply_to`
  (`resolve: :own`). A site that set no address sends from `noreply@` its own domain, never from
  another site's; one that set no name sends under its title.

      Mail.email(site_id, to: "ada@example.com", subject: "Reset your password", html: "<p>…</p>", text: "…")
      |> Mail.deliver(site_id: site_id, purpose: "password_reset")

  ## History

  A site's emails older than `mailer.history_days` are deleted when it next sends one — work done
  when something changed, never on a timer.
  """

  use Ash.Domain, otp_app: :mishka_cms_core, validate_config_inclusion?: false
  use Gettext, backend: MishkaCmsCore.Gettext

  require Logger

  alias MishkaCmsCore.Mail.{Delivery, Provider}
  alias MishkaCmsCore.Mail.Workers.DeliverWorker
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Settings
  alias MishkaInstaller.Event.Hook

  resources do
    resource MishkaCmsCore.Mail.Delivery
  end

  @provider_key "mailer.provider"
  @payload_salt "mishka mail payload"
  @payload_max_age 7 * 86_400
  @error_length 300

  @doc """
  Hands `email` over for `opts[:site_id]` (`nil` for the installation). `:purpose` (required) says
  what the email is for — `"password_reset"`, `"magic_link"`, `"confirmation"`, or anything an
  extension sends; `:idempotency_key` names this one email so a retry is never sent twice.

  Returns `{:ok, delivery}` once it is queued (or sent, under `env_test?`), `{:ok, :suppressed}`
  when a plugin stopped it, `{:error, :not_configured}` when the scope has no ready provider, or
  `{:error, reason}`. It does not raise: an email is never worth failing the action that sent it.
  """
  @spec deliver(Swoosh.Email.t(), keyword()) ::
          {:ok, Delivery.t() | :suppressed} | {:error, term()}
  def deliver(%Swoosh.Email{} = email, opts) do
    site_id = Keyword.get(opts, :site_id)
    purpose = opts |> Keyword.fetch!(:purpose) |> to_string()

    case before_deliver(email, site_id, purpose) do
      :suppress -> {:ok, :suppressed}
      %Swoosh.Email{} = email -> hand_over(email, site_id, purpose, opts[:idempotency_key])
    end
  end

  @doc """
  A new email from `site_id` (`nil` for the installation), with `fields` `:to`, `:subject`, `:html`
  and `:text`, and the scope's own sender. A missing `:text` is left out, and the provider writes
  one from the HTML.
  """
  @spec email(String.t() | nil, keyword()) :: Swoosh.Email.t()
  def email(site_id, fields) do
    Swoosh.Email.new()
    |> Swoosh.Email.to(Keyword.fetch!(fields, :to))
    |> Swoosh.Email.from({from_name(site_id), from_address(site_id)})
    |> Swoosh.Email.subject(Keyword.fetch!(fields, :subject))
    |> Swoosh.Email.html_body(Keyword.get(fields, :html))
    |> put_if(&Swoosh.Email.text_body/2, Keyword.get(fields, :text))
    |> put_if(&Swoosh.Email.reply_to/2, reply_to(site_id))
  end

  @doc "The address `site_id` sends from: its own, or `noreply@` its domain — the master site's for Global."
  @spec from_address(String.t() | nil) :: String.t()
  def from_address(site_id) do
    case Settings.get_own("mailer.from", nil, site_id) do
      address when is_binary(address) and address != "" -> address
      _unset -> "noreply@" <> host(site_id)
    end
  end

  @doc "The name `site_id` sends under."
  @spec from_name(String.t() | nil) :: String.t()
  def from_name(site_id) do
    case Settings.get_own("mailer.from_name", "", site_id) do
      name when is_binary(name) and name != "" -> name
      _unset -> site_name(site_id)
    end
  end

  @doc "Where replies to `site_id`'s email go, or `nil` for the from address."
  @spec reply_to(String.t() | nil) :: String.t() | nil
  def reply_to(site_id) do
    case Settings.get_own("mailer.reply_to", "", site_id) do
      address when is_binary(address) and address != "" -> address
      _unset -> nil
    end
  end

  defp host(nil) do
    case Enum.find(SiteState.get_active_sites(), & &1.master) do
      %{id: id} -> host(id)
      nil -> "localhost"
    end
  end

  defp host(site_id) do
    case SiteState.get!(site_id) do
      %{frontend_domain: domain} when is_binary(domain) and domain != "" -> domain
      %{host: host} when is_binary(host) -> host
      _gone -> "localhost"
    end
  end

  defp put_if(email, _put, nil), do: email
  defp put_if(email, put, value), do: put.(email, value)

  @doc """
  Sends a test email to `to` for `site_id` now, through its provider, and waits for the answer:
  `{:ok, message_id}` or `{:error, why}` in words for the settings page. Recorded like any other.
  """
  @spec send_test(String.t() | nil, String.t()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def send_test(site_id, to) when is_binary(to) do
    with :ok <- address(to),
         {:ok, provider} <- provider(site_id),
         %Swoosh.Email{} = email <-
           before_deliver(test_email(site_id, String.trim(to)), site_id, "test"),
         {:ok, delivery} <- record(email, site_id, "test", provider.id(), :queued, nil) do
      case run(delivery, email, provider, nil) do
        {:ok, message_id} -> {:ok, message_id}
        {:error, reason, _final?} -> {:error, describe(reason)}
      end
    else
      :suppress -> {:error, describe(:suppressed)}
      {:error, reason} -> {:error, describe(reason)}
    end
  end

  @doc """
  The provider `site_id` sends with, ready to send: `{:ok, module}`, or `{:error, reason}` —
  `:not_configured` (none chosen), `:unknown_provider` (chosen, but its plugin is gone),
  `:cannot_run` (chosen, while the providers' plugins cannot run) or
  `:not_ready` (chosen, but missing what it needs, such as its key).
  """
  @spec provider(String.t() | nil) :: {:ok, module()} | {:error, atom()}
  def provider(site_id) do
    case Settings.get_own(@provider_key, default_provider(), site_id) do
      blank when blank in [nil, "", "none"] ->
        {:error, :not_configured}

      id ->
        with {:ok, provider} <- Provider.fetch(id) do
          if provider.ready?(site_id), do: {:ok, provider}, else: {:error, :not_ready}
        end
    end
  end

  @doc "Whether `site_id` can send email now."
  @spec configured?(String.t() | nil) :: boolean()
  def configured?(site_id), do: match?({:ok, _}, provider(site_id))

  @doc """
  The provider a scope uses until it picks one: `"none"` — no email — unless the deployment says
  otherwise (`config :mishka_cms_core, :mail_default_provider`, the development mailbox in dev).
  """
  @spec default_provider() :: String.t()
  def default_provider, do: Application.get_env(:mishka_cms_core, :mail_default_provider, "none")

  @doc """
  The settings the Email tab shows: which provider a scope uses, then every offered provider's own,
  each drawn only while its provider is the one chosen (`MishkaCmsCore.Settings.shown_when/3`).
  Part of `MishkaCmsCore.Settings`' core definitions.
  """
  @spec settings() :: [Settings.definition()]
  def settings do
    providers = Provider.offered()

    [
      Settings.define(@provider_key, :select,
        default: default_provider(),
        category: "email",
        group: gettext_noop("Delivery"),
        scope: :both,
        resolve: :own,
        label: gettext_noop("Email provider"),
        description:
          gettext_noop(
            "What this site sends its email through. A site sends with its own provider and key only, never with another site's."
          ),
        options:
          [{gettext_noop("None — no email is sent"), "none"}] ++ provider_options(providers),
        attention_on_default: default_provider() == "none"
      )
    ] ++
      Enum.flat_map(providers, fn provider ->
        Enum.map(provider.settings(), &Settings.shown_when(&1, @provider_key, provider.id()))
      end)
  end

  defp provider_options(providers), do: Enum.map(providers, &{&1.label(), &1.id()})

  @doc false
  # Runs one queued delivery: the worker's whole job, and `send_test/2`'s.
  @spec run(Delivery.t(), Swoosh.Email.t(), module(), String.t() | nil, boolean()) ::
          {:ok, String.t() | nil} | {:error, term(), boolean()}
  def run(delivery, email, provider, idempotency_key, last_attempt? \\ true) do
    opts = [idempotency_key: idempotency_key, purpose: delivery.purpose]
    attempts = delivery.attempts + 1

    case provider.deliver(email, delivery.site_id, opts) do
      {:ok, message_id} ->
        mark(delivery, %{status: :sent, message_id: message_id, error: nil, attempts: attempts})
        notice("mail:delivered", delivery, %{provider: provider.id(), message_id: message_id})
        {:ok, message_id}

      {:error, reason} ->
        final? = last_attempt? or not provider.retry?(reason)
        status = if final?, do: :failed, else: :queued
        mark(delivery, %{status: status, error: describe(reason), attempts: attempts})
        if final?, do: notice("mail:failed", delivery, %{provider: provider.id(), reason: reason})
        {:error, reason, final?}
    end
  end

  @doc false
  # The worker's way back to the row and the email it carries.
  @spec open(map()) :: {:ok, Delivery.t(), Swoosh.Email.t()} | {:error, term()}
  def open(%{"delivery_id" => id, "email" => sealed} = args) do
    with {:ok, delivery} <- Ash.get(Delivery, id, authorize?: false, tenant: args["site_id"]),
         {:ok, %Swoosh.Email{} = email} <-
           Phoenix.Token.decrypt(endpoint(), @payload_salt, sealed, max_age: @payload_max_age) do
      {:ok, delivery, email}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :unreadable}
    end
  end

  @doc """
  Deletes `site_id`'s emails older than `mailer.history_days` — every site's for `nil`, the
  installation's own sweep. Run when a site sends, by the job that sent it.
  """
  @spec prune(String.t() | nil) :: :ok
  def prune(site_id) do
    days = Settings.get("mailer.history_days", 30)

    Delivery
    |> Ash.Query.for_read(:prunable, %{before: DateTime.add(DateTime.utc_now(), -days * 86_400)},
      authorize?: false,
      tenant: site_id
    )
    |> Ash.bulk_destroy(:prune, %{}, authorize?: false, tenant: site_id, return_errors?: true)

    :ok
  end

  @doc false
  @spec not_configured(Delivery.t(), term()) :: :ok
  def not_configured(delivery, reason) do
    mark(delivery, %{status: :not_configured, error: describe(reason)})
    notice("mail:not_configured", delivery, %{reason: reason})
  end

  @doc "A purpose in words, for the history table."
  @spec purpose_label(String.t()) :: String.t()
  def purpose_label("password_reset"), do: gettext("Password reset")
  def purpose_label("magic_link"), do: gettext("Sign-in link")
  def purpose_label("confirmation"), do: gettext("Account confirmation")
  def purpose_label("test"), do: gettext("Test email")

  def purpose_label(purpose),
    do: purpose |> String.replace(["_", ":"], " ") |> String.capitalize()

  @doc "A delivery status in words."
  @spec status_label(atom()) :: String.t()
  def status_label(:sent), do: gettext("Sent")
  def status_label(:queued), do: gettext("Sending")
  def status_label(:not_configured), do: gettext("No provider")
  def status_label(_failed), do: gettext("Failed")

  @doc """
  Why a send failed, in words an admin can act on: the provider's own message where it gave one,
  cut short. Never a key: providers' error bodies do not carry one, and nothing else is shown.
  """
  @spec describe(term()) :: String.t()
  def describe(:not_configured),
    do: gettext("No email provider is set for this site.")

  def describe(:unknown_provider),
    do: gettext("The chosen email provider is not installed or was stopped.")

  def describe(:not_ready),
    do: gettext("The email provider is missing its key or settings.")

  def describe(:cannot_run),
    do: gettext("The email providers' plugins are not loaded, so nothing can be sent.")

  def describe(:invalid_address), do: gettext("That is not an email address.")
  def describe(:suppressed), do: gettext("A plugin stopped this email.")
  def describe(:from_not_set), do: gettext("No \"from\" address is set.")

  def describe({status, %{"message" => message}}) when is_integer(status),
    do: short("#{status}: #{message}")

  def describe({status, body}) when is_integer(status) and is_binary(body),
    do: short("#{status}: #{body}")

  def describe(%{__exception__: true} = error), do: short(Exception.message(error))
  def describe(reason), do: short(inspect(reason))

  defp short(text), do: String.slice(text, 0, @error_length)

  defp hand_over(email, site_id, purpose, idempotency_key) do
    case provider(site_id) do
      {:ok, provider} ->
        with {:ok, delivery} <-
               record(email, site_id, purpose, provider.id(), :queued, nil) do
          dispatch(delivery, email, provider, idempotency_key)
        end

      {:error, reason} ->
        with {:ok, delivery} <-
               record(email, site_id, purpose, nil, :not_configured, describe(reason)),
             do: notice("mail:not_configured", delivery, %{reason: reason})

        Logger.warning("Email not sent: #{reason} (site #{inspect(site_id)}, purpose #{purpose})")

        {:error, :not_configured}
    end
  end

  defp dispatch(delivery, email, provider, idempotency_key) do
    case Application.get_env(:mishka_cms_core, :env_test?, false) do
      true ->
        _answer = run(delivery, email, provider, idempotency_key)
        {:ok, delivery}

      false ->
        %{
          "delivery_id" => delivery.id,
          "site_id" => delivery.site_id,
          "purpose" => delivery.purpose,
          "idempotency_key" => idempotency_key,
          "email" => Phoenix.Token.encrypt(endpoint(), @payload_salt, email)
        }
        |> DeliverWorker.new()
        |> Oban.insert()
        |> case do
          {:ok, _job} -> {:ok, delivery}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp before_deliver(email, site_id, purpose) do
    case Hook.call("mail:deliver:before", %{email: email, site_id: site_id, purpose: purpose}) do
      %{suppress: true} -> :suppress
      %{email: %Swoosh.Email{} = changed} -> changed
      _unchanged -> email
    end
  end

  defp record(email, site_id, purpose, provider, status, error) do
    Delivery
    |> Ash.Changeset.for_create(
      :record,
      %{
        site_id: site_id,
        purpose: purpose,
        recipient: recipients(email),
        subject: email.subject,
        provider: provider,
        status: status,
        error: error
      },
      authorize?: false,
      tenant: site_id
    )
    |> Ash.create(authorize?: false)
  end

  defp mark(delivery, changes) do
    delivery
    |> Ash.Changeset.for_update(:mark, changes, authorize?: false, tenant: delivery.site_id)
    |> Ash.update(authorize?: false)
  end

  defp notice(event, delivery, extra) do
    Hook.call(
      event,
      Map.merge(
        %{delivery_id: delivery.id, site_id: delivery.site_id, purpose: delivery.purpose},
        extra
      ),
      return: false
    )

    :ok
  end

  defp recipients(%Swoosh.Email{to: to}) do
    to
    |> List.wrap()
    |> Enum.map_join(", ", fn
      {_name, address} -> address
      address -> to_string(address)
    end)
  end

  defp address(to) do
    case Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, String.trim(to)) do
      true -> :ok
      false -> {:error, :invalid_address}
    end
  end

  defp test_email(site_id, to) do
    name = site_name(site_id)

    email(site_id,
      to: to,
      subject: gettext("Test email from %{site}", site: name),
      html:
        "<p>" <>
          gettext(
            "This is a test email from %{site}. If you can read it, email is set up and working.",
            site: name
          ) <> "</p>",
      text:
        gettext(
          "This is a test email from %{site}. If you can read it, email is set up and working.",
          site: name
        )
    )
  end

  @doc false
  @spec site_name(String.t() | nil) :: String.t()
  def site_name(nil), do: Settings.get("site.title", "Mishka CMS")

  def site_name(site_id) do
    case SiteState.get!(site_id) do
      %{name: name} -> Settings.get("site.title", name, site_id)
      _gone -> Settings.get("site.title", "Mishka CMS")
    end
  end

  defp endpoint, do: Application.fetch_env!(:mishka_cms_core, :endpoint)
end
