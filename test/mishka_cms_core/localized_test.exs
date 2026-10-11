defmodule MishkaCmsCore.LocalizedTest do
  @moduledoc """
  `MishkaCmsCore.Localized`: each kind of value in the reader's language, English when the
  language's data is not there, and `""` for what none of them can write.

  English ships with `Localize`, so these read no downloaded data. `async: false` — the Gettext
  locale the reader's language comes from is the test process's own, but a test sets it.
  """
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Localized

  setup do
    previous = Gettext.get_locale(MishkaCmsCore.Gettext)
    Gettext.put_locale(MishkaCmsCore.Gettext, "en")
    on_exit(fn -> Gettext.put_locale(MishkaCmsCore.Gettext, previous) end)
  end

  test "dates, times and both in a CLDR format" do
    assert Localized.date(~D[2025-07-03]) == "Jul 3, 2025"
    assert Localized.date(~D[2025-07-03], :full) == "Thursday, July 3, 2025"
    assert Localized.date(~U[2025-07-03 18:04:00Z], :MMMd) == "Jul 3"
    assert Localized.date(~N[2025-07-03 18:04:00], :yMMMM) == "July 2025"
    assert Localized.time(~T[18:04:00], :Hm) == "18:04"
    assert Localized.time(~U[2025-07-03 18:04:00Z]) == "6:04 PM"
    assert Localized.datetime(~U[2025-07-03 18:04:00Z], :MMMdHm) == "Jul 3, 18:04"
  end

  test "how long ago, in the largest unit that says it" do
    now = ~U[2025-07-03 18:00:00Z]
    ago = &Localized.ago(DateTime.add(now, &1), relative_to: now)

    assert ago.(0) == "now"
    assert ago.(-20) == "20 seconds ago"
    assert ago.(-150) == "3 minutes ago"
    assert ago.(-5 * 3600) == "5 hours ago"
    assert ago.(-86_400) == "yesterday"
    assert ago.(-3 * 86_400) == "3 days ago"
    assert ago.(2 * 86_400) == "in 2 days"

    assert Localized.ago(DateTime.add(now, -3 * 3600), relative_to: now, format: :narrow) ==
             "3h ago"

    assert Localized.ago(~N[2025-07-03 10:00:00], relative_to: ~N[2025-07-03 12:00:00]) ==
             "2 hours ago"

    assert Localized.ago(DateTime.add(now, -1500 * 86_400), relative_to: now, format: :narrow) ==
             "4y ago"
  end

  # Persian's CLDR data is downloaded into priv/localize the first time a test reads it.
  test "a count in how long ago is written in the language's own digits" do
    now = ~U[2025-07-03 18:00:00Z]

    assert Localized.ago(DateTime.add(now, -26), relative_to: now, locale: "fa") ==
             "۲۶ ثانیه پیش"

    assert Localized.ago(DateTime.add(now, -3 * 86_400), relative_to: now, locale: "fa") ==
             "۳ روز پیش"

    assert Localized.number(1284, locale: "fa") == "۱٬۲۸۴"
    assert Localized.date(~D[2025-07-03], :yMMMd, locale: "fa") == "۳ ژوئیه ۲۰۲۵"
  end

  test "numbers, short numbers and lists" do
    assert Localized.number(1284) == "1,284"
    assert Localized.number(Decimal.new("1234.5")) == "1,234.5"
    assert Localized.number(0.456, format: :percent) == "46%"
    assert Localized.compact(999) == "999"
    assert Localized.compact(8429) == "8.4K"
    assert Localized.compact(1_240_000) == "1.2M"
    assert Localized.list([]) == ""
    assert Localized.list(["French"]) == "French"
    assert Localized.list(["French", "Persian"]) == "French and Persian"
    assert Localized.list(["a", "b", "c"]) == "a, b, and c"
    assert Localized.list(["a", "b"], list_style: :or) == "a or b"
  end

  test "language names, and a sort by the language's alphabet" do
    assert Localized.language("fa") == "Persian"
    assert Localized.language("pt-BR") == "Brazilian Portuguese"
    assert Localized.language("fa-IR") == "Persian (Iran)"
    assert Localized.language("xx") == nil

    assert Localized.sort(["Persian", "french", "Ängel", "English"]) ==
             ["Ängel", "English", "french", "Persian"]
  end

  test "the reader's language is the Gettext locale, else :locale" do
    assert Localized.locale() == "en"
    assert Localized.locale(locale: "de") == "de"
    assert Localized.cldr_locale(locale: "en_US") == :en
    assert Localized.cldr_locale(locale: "pt_BR") in [:pt, :en]
  end

  test "a language CLDR does not know, or has no data for here, writes in English" do
    for locale <- ["xx", "tlh", "not a language", ""] do
      assert Localized.cldr_locale(locale: locale) == :en
      assert Localized.date(~D[2025-07-03], :medium, locale: locale) == "Jul 3, 2025"
      assert Localized.number(1284, locale: locale) == "1,284"
    end
  end

  test "a value none of them can write reads as an empty string" do
    assert Localized.date(nil) == ""
    assert Localized.date("2025-07-03") == ""
    assert Localized.time(~D[2025-07-03]) == ""
    assert Localized.datetime(~D[2025-07-03]) == ""
    assert Localized.ago(nil) == ""
    assert Localized.number("12") == ""
    assert Localized.list(nil) == ""
    assert Localized.language(nil) == nil
  end
end
