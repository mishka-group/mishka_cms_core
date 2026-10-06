defmodule MishkaCmsCore.Gettext do
  @moduledoc """
  A module providing Internationalization with a gettext-based API for extensions.

  By using [Gettext](https://hexdocs.pm/gettext), your module compiles translations
  that you can use in your application. To use this Gettext backend module,
  call `use Gettext` and pass it as an option:

      use Gettext, backend: MishkaCmsCore.Gettext

      # Simple translation
      gettext("Here is the string to translate")

      # Plural translation
      ngettext("Here is the string to translate",
               "Here are the strings to translate",
               3)

      # Domain-based translation
      dgettext("errors", "Here is the error message to translate")

  See the [Gettext Docs](https://hexdocs.pm/gettext) for detailed usage.

  The messages are read from `priv/gettext`, which holds the English catalogue only: the `.pot`
  templates and `en/LC_MESSAGES/*.po`. A message with no translation in the reader's locale reads as
  its own text, interpolated. To add a language, run
  `mix gettext.merge priv/gettext --locale xx` and translate the `.po` files it creates.

  ## Marking the untranslated

  With `config :mishka_cms_core, :gettext_marks_untranslated, true` at compile time, which only the
  test configurations set, a message the locale has no translation for reads as its interpolated text
  behind the marker `"[<locale>] "`, so a test sees that a word went through Gettext in the locale of
  the reader without a `.po` for that locale:

      Gettext.put_locale(MishkaCmsCore.Gettext, "fa")
      dgettext("mishka_gervaz", "Guest") #=> "[fa] Guest"

  The marker applies to every locale except `"en"`, to plural messages, and to text with a missing
  binding, which is still reported as the default does. A message with the context `"alphabet"` is a
  sort key rather than a phrase, so it reads without the marker and with its letters in reverse
  order: a list sorted by it comes out in the reverse of the English order, which tells an order that
  follows the reader's alphabet from one that follows the code or the English text.

  Without the flag, the default Gettext behaviour is kept.
  """
  use Gettext.Backend,
    otp_app: :mishka_cms_core,
    priv: "priv/gettext"

  if Application.compile_env(:mishka_cms_core, :gettext_marks_untranslated, false) do
    @impl Gettext.Backend
    def handle_missing_translation(locale, domain, msgctxt, msgid, bindings),
      do: mark(locale, msgctxt, super(locale, domain, msgctxt, msgid, bindings))

    @impl Gettext.Backend
    def handle_missing_plural_translation(
          locale,
          domain,
          msgctxt,
          msgid,
          msgid_plural,
          n,
          bindings
        ),
        do:
          mark(
            locale,
            msgctxt,
            super(locale, domain, msgctxt, msgid, msgid_plural, n, bindings)
          )

    defp mark("en", _msgctxt, result), do: result

    defp mark(_locale, "alphabet", {:default, text}), do: {:default, String.reverse(text)}

    defp mark(locale, _msgctxt, {:default, text}), do: {:default, marked(locale, text)}

    defp mark(locale, _msgctxt, {:missing_bindings, incomplete, missing}),
      do: {:missing_bindings, marked(locale, incomplete), missing}

    defp marked(locale, text), do: "[#{locale}] " <> text
  end
end
