# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Mail.Providers.DevMailbox do
  @moduledoc """
  The development mailbox as a provider: email goes to `MishkaCmsCore.Mailer`'s own adapter —
  `Swoosh.Adapters.Local`, read at `/dev/mailbox`, in development, and `Swoosh.Adapters.Test` in
  the test suite — and never leaves the machine.

  Offered only where `config :mishka_cms_core, :mail_dev_mailbox, true` says so, which no
  production config does.
  """

  use MishkaCmsCore.Mail.Provider,
    id: "dev_mailbox",
    label: gettext_noop("Development mailbox (/dev/mailbox)"),
    priority: 90

  @impl true
  def offered?, do: Application.get_env(:mishka_cms_core, :mail_dev_mailbox, false) == true

  @impl true
  def settings, do: []

  @impl true
  def ready?(_site_id), do: true

  @impl true
  def deliver(email, _site_id, _opts) do
    case MishkaCmsCore.Mailer.deliver(email) do
      {:ok, %{id: id}} -> {:ok, id}
      {:ok, _answer} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def retry?(_reason), do: false
end
