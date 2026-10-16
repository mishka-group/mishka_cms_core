# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Captcha.Widget do
  @moduledoc """
  `<.captcha>` — the captcha a form asks, drawn where the form puts it. Every runtime template can
  call it (`MishkaCmsCore.Runtime.LiveViewHelpers.imports/1`); the sign-in pages put it above their
  button:

      <.captcha form={f} for="sign_in" tenant={assigns[:current_tenant]} />

  It draws nothing while the scope asks no captcha (`MishkaCmsCore.Captcha.browser/3`). Otherwise it
  draws a box the `Captcha` hook (`assets/js/shared_hooks.js`) owns — `phx-update="ignore"`, so no
  re-render takes the provider's frame away — holding the hidden input the token goes in, named for
  the form's `captcha_token` field. A refused submit is answered with the `"mishka:captcha:reset"`
  event, and the hook asks for a fresh check: each token is good once.
  """

  use Phoenix.Component

  @forms %{
    "sign_in" => :sign_in,
    "register" => :register,
    "reset_request" => :reset_request,
    "magic_link" => :magic_link,
    "test" => :test
  }

  attr :form, :any, required: true, doc: "The form the token is sent with."

  attr :for, :string,
    required: true,
    values: Map.keys(@forms),
    doc: "Which form it is, as the action checking it names it."

  attr :tenant, :string, default: nil, doc: "The site the form signs into; `nil` for a master's."
  attr :id, :string, default: nil, doc: "Defaults to `captcha-<for>`."
  attr :class, :any, default: nil

  def captcha(assigns) do
    form = Map.fetch!(@forms, assigns.for)

    assigns =
      assign(assigns,
        id: assigns.id || "captcha-" <> assigns.for,
        field: assigns.form[:captcha_token],
        browser: MishkaCmsCore.Captcha.browser(assigns.tenant, form, Gettext.get_locale())
      )

    ~H"""
    <div
      :if={@browser}
      id={@id}
      phx-hook="Captcha"
      phx-update="ignore"
      data-provider={@browser.provider}
      data-script={@browser.script}
      data-global={@browser.global}
      data-mode={@browser.mode}
      data-options={Jason.encode!(@browser.options)}
      class={[
        if(@browser.mode == :score, do: "hidden", else: "flex min-h-[65px]"),
        @class
      ]}
    >
      <input type="hidden" name={@field.name} value="" data-captcha-token />
      <div data-captcha-box></div>
    </div>
    """
  end
end
