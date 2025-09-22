defmodule MishkaCmsCoreWeb.AuthOverrides do
  @moduledoc """
  UI overrides for the AshAuthentication.Phoenix components the sign-in pages place — the token
  pages (`Reset`, `Confirm`, `MagicLink.SignIn`). They render inside the pages' card, so these
  overrides give each component's field/input/button/error the same Tailwind utility classes the
  hand-written forms use. Pass them as
  `overrides={[MishkaCmsCoreWeb.AuthOverrides, AshAuthentication.Phoenix.Overrides.Default]}`.

  See https://hexdocs.pm/ash_authentication_phoenix/ui-overrides.html.
  """
  use AshAuthentication.Phoenix.Overrides
  use Gettext, backend: MishkaCmsCore.Gettext

  @input "h-[46px] w-full rounded-[12px] border border-[#ecebe6] bg-[#faf9f6] px-[14px] text-[13.5px] font-medium text-[#1b1a18] outline-none placeholder:text-[#a8a5a0] focus:border-[#c3c1f0] focus:bg-white focus:shadow-[0_0_0_3px_rgba(91,87,214,0.1)]"
  @button "mt-[18px] flex h-12 w-full cursor-pointer items-center justify-center rounded-[13px] bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] text-[13.5px] font-bold text-white shadow-[0_6px_18px_rgba(79,75,204,0.3)] hover:opacity-95 disabled:cursor-not-allowed disabled:opacity-50"
  @label "text-[12px] font-semibold text-[#3a382f]"
  @field "flex flex-col gap-[7px]"

  # The defaults make each of these a full standalone PAGE — `py-12 px-4 lg:px-20 xl:px-24` around a
  # `max-w-sm lg:w-96` column. Here they are the contents of a card that already owns its width and
  # padding, so both are cleared or the form sits inset and off-centre inside it.
  override AshAuthentication.Phoenix.Components.Confirm do
    set :show_banner, false
    set :root_class, nil
    set :strategy_class, "w-full"
  end

  override AshAuthentication.Phoenix.Components.Reset do
    set :show_banner, false
    set :root_class, nil
    set :strategy_class, "w-full"
  end

  override AshAuthentication.Phoenix.Components.MagicLink.SignIn do
    set :show_banner, false
    set :root_class, nil
    set :strategy_class, "w-full"
  end

  override AshAuthentication.Phoenix.Components.Password.RegisterForm do
    set :show_banner, false
  end

  override AshAuthentication.Phoenix.Components.Password.Input do
    set :field_class, @field
    set :label_class, @label
    set :input_class, @input

    # Without this an errored field falls back to the dependency's own grey-and-red box, so one bad
    # entry breaks the card's styling.
    set :input_class_with_error, @input <> " border-[#f0dcd8]! bg-[#fdf7f6]!"
    set :submit_class, @button
    set :error_ul, "m-0 list-none p-0 text-[10.5px] font-semibold text-[#c0473d]"
    set :error_li, nil

    # Matches the wording on the sign-in pages' own forms. The SUBMIT label has no override key
    # — `Password.Input.submit/1` humanizes the action name in an `assign_new` — so the reset button
    # reads "Reset password with token". Renaming an Ash action to shape a button is the wrong trade.
    set :password_input_label, gettext_noop("Password")
    set :password_confirmation_input_label, gettext_noop("Confirm password")
  end

  # The card header already carries the title, so the component's own heading is a second one.
  override AshAuthentication.Phoenix.Components.Reset.Form do
    set :label_class, "hidden"
    set :form_class, @field
  end

  override AshAuthentication.Phoenix.Components.Confirm.Form do
    set :label_class, "hidden"
    set :form_class, @field
  end

  override AshAuthentication.Phoenix.Components.Confirm.Input do
    set :submit_class, @button
  end

  override AshAuthentication.Phoenix.Components.MagicLink.Form do
    set :label_class, "hidden"
    set :form_class, @field
  end

  override AshAuthentication.Phoenix.Components.MagicLink.Input do
    set :submit_class, @button
  end
end
