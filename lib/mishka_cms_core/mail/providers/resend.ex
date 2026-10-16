# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Mail.Providers.Resend do
  @moduledoc """
  [Resend](https://resend.com) as an email provider, through Swoosh's own `Swoosh.Adapters.Resend`.

  Each scope keeps its own API key (`mailer.resend.api_key`, a `:secret` setting). Resend refuses a
  "from" address on a domain the account has not verified; `onboarding@resend.dev` sends without
  one, but only to the account owner's own address.

  The idempotency key `MishkaCmsCore.Mail.deliver/2` was given goes in the `Idempotency-Key`
  header, so a retry after a timeout is answered from Resend's memory instead of sending twice.
  Worth retrying: a rate limit, a request already in flight with the same key, Resend's own errors
  and transport failures. Not worth it: a bad or restricted key, an unverified domain, a refused
  address, a used-up daily or monthly quota.
  """

  use MishkaCmsCore.Mail.Provider, id: "resend", label: "Resend", priority: 10

  @key "mailer.resend.api_key"

  @impl true
  def settings do
    [
      secret(@key, gettext_noop("Resend API key"),
        group: "Resend",
        description:
          gettext_noop(
            "Create one in Resend with sending access only, limited to this site's domain. It starts with re_. Stored sealed and never shown again."
          )
      )
    ]
  end

  @impl true
  def ready?(site_id), do: is_binary(Settings.secret(@key, site_id))

  @impl true
  def deliver(email, site_id, opts) do
    case Settings.secret(@key, site_id) do
      nil ->
        {:error, :not_ready}

      api_key ->
        email
        |> idempotent(opts[:idempotency_key])
        |> MishkaCmsCore.Mailer.deliver(adapter: Swoosh.Adapters.Resend, api_key: api_key)
        |> case do
          {:ok, %{id: id}} -> {:ok, id}
          {:ok, _answer} -> {:ok, nil}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def retry?({429, %{"name" => quota}})
      when quota in ["daily_quota_exceeded", "monthly_quota_exceeded"],
      do: false

  def retry?({429, _body}), do: true
  def retry?({409, %{"name" => "concurrent_idempotent_requests"}}), do: true
  def retry?({status, _body}) when is_integer(status) and status >= 500, do: true
  def retry?({status, _body}) when is_integer(status), do: false
  def retry?(:not_ready), do: false
  def retry?(_transport), do: true

  defp idempotent(email, key) when is_binary(key),
    do: Swoosh.Email.put_provider_option(email, :idempotency_key, key)

  defp idempotent(email, _none), do: email
end
