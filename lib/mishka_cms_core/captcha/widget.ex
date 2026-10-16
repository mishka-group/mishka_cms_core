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

  ## An extension's own form

  `for` names the form the way the action checking the token names it. The sign-in pages and the
  settings page's test use the strings below; an extension's form passes its own atom, the one its
  action hands `MishkaCmsCore.Accounts.CaptchaCheck`:

      prepare &MishkaCmsCore.Accounts.CaptchaCheck.prepare(&1, &2, :newsletter)

      <.captcha form={@form} for={:newsletter} tenant={site_id()} />

  ## Asked only once the form is sent

  A form that wants no check in the visitor's way until they press its button draws none at first.
  Its action refuses the first send with `reason: :missing`
  (`MishkaCmsCore.Accounts.CaptchaCheck.refusal/1`), and from then on the form draws the check with
  `deferred`:

      <.captcha :if={@asked?} form={@form} for={:newsletter} tenant={site_id()} deferred />

  `deferred` tells the hook the visitor has already sent the form once: it sends it again by itself
  as soon as the check gives a token — when a widget is solved, or at once for a score — so the
  visitor presses the button once.
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

  attr :for, :any,
    required: true,
    doc:
      "Which form it is, as the action checking it names it: one of #{@forms |> Map.keys() |> Enum.map_join(", ", &inspect/1)}, or an extension's own form as an atom."

  attr :tenant, :string, default: nil, doc: "The site the form signs into; `nil` for a master's."
  attr :id, :string, default: nil, doc: "Defaults to `captcha-<for>`."

  attr :deferred, :boolean,
    default: false,
    doc:
      "The form has been sent once already: the check sends it again by itself once it gives a token."

  attr :class, :any, default: nil

  def captcha(assigns) do
    form = form_name(assigns.for)

    assigns =
      assign(assigns,
        id: assigns.id || "captcha-#{form}",
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
      data-deferred={@deferred && "true"}
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

  @doc "The form `for` names: one of the strings above, or an extension's atom as it is."
  @spec form_name(String.t() | atom()) :: atom()
  def form_name(name) when is_binary(name), do: Map.fetch!(@forms, name)
  def form_name(name) when is_atom(name) and not is_nil(name), do: name
end
