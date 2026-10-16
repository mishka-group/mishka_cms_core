# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Captcha.WidgetTest do
  @moduledoc """
  `<.captcha>` as a form draws it: for the sign-in pages' forms and for an extension's own, drawn
  at once or only once the form has been sent (`deferred`).
  """
  use MishkaCmsCore.DataCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Captcha.Widget
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Settings

  setup do
    snapshot = SettingsState.snapshot()
    Settings.load_definitions()

    host = "widget-#{System.unique_integer([:positive])}.test"
    site = create_site!(name: host, host: host, active: true)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: true,
        master: false
      })

    on_exit(fn ->
      SettingsState.restore(snapshot)
      SiteState.delete(site.id)
    end)

    %{site: site}
  end

  defp turnstile!(site) do
    for {key, value} <- [
          {"security.captcha.provider", "turnstile"},
          {"security.captcha.turnstile.site_key", "1x00000000000000000000AA"},
          {"security.captcha.turnstile.secret_key", "1x0000000000000000000000000000000AA"}
        ],
        do: {:ok, _} = Settings.put(key, value, site_id: site.id)
  end

  defp box(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.query("[phx-hook=Captcha]")

  defp drawn(assigns) do
    form = Phoenix.Component.to_form(%{}, as: "f")
    box(render_component(&Widget.captcha/1, Map.merge(%{form: form}, assigns)))
  end

  test "draws nothing while the site asks no captcha", %{site: site} do
    assert Enum.empty?(drawn(%{for: "sign_in", tenant: site.id}))
  end

  test "a sign-in page's form is named by its string, as before", %{site: site} do
    turnstile!(site)

    box = drawn(%{for: "sign_in", tenant: site.id})

    assert LazyHTML.attribute(box, "id") == ["captcha-sign_in"]
    assert LazyHTML.attribute(box, "data-provider") == ["turnstile"]
    assert LazyHTML.attribute(box, "data-deferred") == []
  end

  test "an extension's form is named by its own atom", %{site: site} do
    turnstile!(site)

    box = drawn(%{for: :newsletter, tenant: site.id})

    assert LazyHTML.attribute(box, "id") == ["captcha-newsletter"]
    assert LazyHTML.attribute(box, "data-provider") == ["turnstile"]
  end

  test "a string no form is named is refused, as it always was", %{site: site} do
    turnstile!(site)

    assert_raise KeyError, fn -> drawn(%{for: "newsletter", tenant: site.id}) end
  end

  test "deferred tells the hook the form was sent once already", %{site: site} do
    turnstile!(site)

    box = drawn(%{for: :newsletter, tenant: site.id, deferred: true})

    assert LazyHTML.attribute(box, "data-deferred") == ["true"]

    assert box |> LazyHTML.query("input[data-captcha-token]") |> LazyHTML.attribute("name") ==
             ["f[captcha_token]"]
  end

  test "an extension form's atom is the reCAPTCHA v3 action the check is asked for", %{site: site} do
    for {key, value} <- [
          {"security.captcha.provider", "recaptcha"},
          {"security.captcha.recaptcha.version", "v3"},
          {"security.captcha.recaptcha.site_key", "recaptcha-site-key"},
          {"security.captcha.recaptcha.secret_key", "recaptcha-secret"}
        ],
        do: {:ok, _} = Settings.put(key, value, site_id: site.id)

    [options] = drawn(%{for: :newsletter, tenant: site.id}) |> LazyHTML.attribute("data-options")

    assert Jason.decode!(options)["action"] == "newsletter"
  end
end
