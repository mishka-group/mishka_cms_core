# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.SignInProvider.Widget do
  @moduledoc """
  The buttons of the services a site signs in with, for the sign-in and registration pages: one
  link per provider the site offers (`MishkaCmsCore.Accounts.SignInProvider.available/1`), to its
  provider's request route, which sends the visitor to the provider. A site that offers none draws
  its `empty` slot instead, and no `divider`. Every runtime template can call it
  (`MishkaCmsCore.Runtime.LiveViewHelpers.imports/1`):

      <.sign_in_providers site={assigns[:current_site]}>
        <:divider><div>or with email</div></:divider>
      </.sign_in_providers>

  A master signs in on the master site's address with the master site's providers, so `site` is
  the site the page is on, never the tenant.
  """

  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Accounts.SignInProvider

  # Every class the buttons draw with, in one place: a site's stylesheet is built from its own
  # pages, which name none of these, so `classes/0` hands them to it.
  @row "grid gap-[9px] max-[620px]:gap-[7px]!"
  @columns %{1 => "grid-cols-1", 2 => "grid-cols-2", 3 => "grid-cols-3", 4 => "grid-cols-4"}
  @button "flex h-11 items-center justify-center gap-2 rounded-[12px] border border-[#ecebe6] bg-white text-[12px] font-semibold text-[#3a382f] shadow-[0_1px_2px_rgba(30,28,24,0.04)] hover:border-[#dcdbf5] hover:bg-[#faf9f6] max-[620px]:p-0!"
  @mark "flex items-center justify-center"
  @icon "size-[18px] shrink-0"
  @label "max-[620px]:hidden!"

  attr :site, :map, default: nil, doc: "The site the page is on (`@current_site`)."
  attr :id, :string, default: "auth-providers"
  attr :class, :any, default: nil

  attr :continue_with, :string,
    default: nil,
    doc: "The button's accessible name with `%{provider}` in it, in the page's language."

  slot :divider, doc: "Drawn after the buttons, only when there are any."
  slot :empty, doc: "Drawn in their place when the site offers none."

  def sign_in_providers(assigns) do
    assigns =
      assign(assigns, :providers, SignInProvider.available(site_id(assigns.site)))

    ~H"""
    {if @providers == [], do: render_slot(@empty)}
    <div :if={@providers != []} id={@id} data-role="auth-providers">
      <div class={[row(), columns(length(@providers)), @class]}>
        <a
          :for={provider <- @providers}
          id={"auth-provider-#{provider.id()}"}
          href={"/api/auth/user/provider/#{provider.id()}/request"}
          aria-label={continue_with(@continue_with, provider.label())}
          class={button()}
        >
          <span class={[mark(), provider.icon().color]}>
            <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true" class={icon()}>
              <path d={provider.icon().path} />
            </svg>
          </span>
          <span class={label()}>{provider.label()}</span>
        </a>
      </div>
      {render_slot(@divider)}
    </div>
    """
  end

  defp continue_with(text, label) when is_binary(text),
    do: String.replace(text, "%{provider}", label)

  defp continue_with(_none, label), do: gettext("Continue with %{provider}", provider: label)

  defp site_id(%{id: id}), do: id
  defp site_id(_none), do: nil

  @doc """
  Every class the buttons draw with, each provider's colour included, for whatever builds a site's
  stylesheet (`MishkaCmsCore.Runtime.Compilers.TailwindCompiler`).
  """
  @spec classes() :: String.t()
  def classes do
    Enum.join(
      [@row, @button, @mark, @icon, @label] ++
        Map.values(@columns) ++ Enum.map(SignInProvider.offered(), & &1.icon().color),
      " "
    )
  end

  defp row, do: @row
  defp button, do: @button
  defp mark, do: @mark
  defp icon, do: @icon
  defp label, do: @label

  defp columns(count), do: Map.get(@columns, count, @columns[3])
end
