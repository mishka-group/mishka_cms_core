# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Localized do
  @moduledoc """
  Dates, times, "how long ago", numbers, lists and language names written the way the reader's
  language writes them — its month and weekday names, digits, separators, word order and plural
  forms — from Unicode CLDR, through `Localize`. Nothing here is translated by hand.

  The language is the calling process's Gettext locale (`MishkaCmsCore.Gettext`): the admin's on
  a dashboard, the page's on a site. `:locale` names another.

      Localized.date(~D[2025-07-03])                          #=> "Jul 3, 2025"
      Localized.date(~D[2025-07-03], :MMMd, locale: "de")     #=> "3. Juli"
      Localized.ago(DateTime.add(DateTime.utc_now(), -150))   #=> "3 minutes ago"
      Localized.number(1284, locale: "fa")                    #=> "۱٬۲۸۴"
      Localized.compact(8429)                                 #=> "8.4K"
      Localized.list(["French", "Persian"])                   #=> "French and Persian"

  A format is a CLDR one: `:short`, `:medium`, `:long` or `:full`, or a skeleton such as `:yMMMd`
  (`Jul 3, 2025`), `:MMMd` (`Jul 3`), `:yMMMM` (`July 2025`), `:MMMEd` (`Thu, Jul 3`), `:MMMdHm`
  (`Jul 3, 18:04`) or `:Hm` (`18:04`), which each language writes in its own order.

  ## A language's data

  English ships with `Localize`. Another language is read from the cache directory the host
  configures (`config :localize, otp_app: ...`), downloaded there the first time it is asked for
  where the host allows it (`allow_runtime_locale_download`), and kept in `:persistent_term` from
  then on. A language whose data is not there writes in English, never in CLDR's bare root forms.

  Nothing here raises: a value none of these functions can write reads as `""`.
  """

  @fallback :en

  @doc """
  The language the reader reads in: `:locale` when given, else the Gettext locale of the calling
  process.
  """
  @spec locale(keyword()) :: String.t() | atom()
  def locale(opts \\ []),
    do: Keyword.get_lazy(opts, :locale, fn -> Gettext.get_locale(MishkaCmsCore.Gettext) end)

  @doc """
  The CLDR locale `locale/1` is written in: its own when its data is there — loaded once,
  downloaded first where the host allows it — else English. An unknown language is English too.

      cldr_locale(locale: "pt_BR") #=> :pt
      cldr_locale(locale: "xx")    #=> :en
  """
  @spec cldr_locale(keyword()) :: atom()
  def cldr_locale(opts \\ []) do
    with {:ok, %{cldr_locale_id: id}} when id not in [:und, nil] <-
           opts |> locale() |> Localize.validate_locale(),
         :ok <- Localize.Locale.load_and_store(id),
         {:ok, ^id} <- Localize.Locale.get(id, [:name]) do
      id
    else
      _no_data -> @fallback
    end
  end

  @doc """
  A date — of a `Date`, `DateTime` or `NaiveDateTime` — in `format`, `:medium` by default.

      date(~D[2025-07-03])         #=> "Jul 3, 2025"
      date(~D[2025-07-03], :full)  #=> "Thursday, July 3, 2025"
  """
  @spec date(term(), atom() | String.t(), keyword()) :: String.t()
  def date(value, format \\ :medium, opts \\ [])

  def date(%struct{} = value, format, opts) when struct in [Date, DateTime, NaiveDateTime],
    do: write(&Localize.Date.to_string/2, value, format, opts)

  def date(_no_date, _format, _opts), do: ""

  @doc """
  A time of day — of a `Time`, `DateTime` or `NaiveDateTime` — in `format`, `:short` by default:
  `6:04 PM` in English, `18:04` in German.
  """
  @spec time(term(), atom() | String.t(), keyword()) :: String.t()
  def time(value, format \\ :short, opts \\ [])

  def time(%struct{} = value, format, opts) when struct in [Time, DateTime, NaiveDateTime],
    do: write(&Localize.Time.to_string/2, value, format, opts)

  def time(_no_time, _format, _opts), do: ""

  @doc """
  A date and time — of a `DateTime` or `NaiveDateTime` — in `format`, `:medium` by default.

      datetime(~U[2025-07-03 18:04:00Z], :MMMdHm) #=> "Jul 3, 18:04"
  """
  @spec datetime(term(), atom() | String.t(), keyword()) :: String.t()
  def datetime(value, format \\ :medium, opts \\ [])

  def datetime(%struct{} = value, format, opts) when struct in [DateTime, NaiveDateTime],
    do: write(&Localize.DateTime.to_string/2, value, format, opts)

  def datetime(_no_datetime, _format, _opts), do: ""

  @doc """
  How long ago `value` was, or how long until it is — `now`, `5 seconds ago`, `3 hours ago`,
  `yesterday`, `last month`, `in 2 days` — in the largest unit that says it.

  Options: `:format` — `:standard` (default), `:short` (`3 hr. ago`) or `:narrow` (`3h ago`);
  `:relative_to` — the moment it is measured from, now by default.
  """
  @spec ago(term(), keyword()) :: String.t()
  def ago(value, opts \\ [])

  def ago(%struct{} = value, opts) when struct in [DateTime, NaiveDateTime, Date] do
    locale = cldr_locale(opts)

    case Localize.DateTime.Relative.to_parts(value,
           relative_to: Keyword.get_lazy(opts, :relative_to, fn -> now(value) end),
           format: Keyword.get(opts, :format, :standard),
           locale: locale
         ) do
      {:ok, parts} -> Enum.map_join(parts, &ago_part(&1, locale))
      {:error, _cannot} -> ""
    end
  end

  def ago(_no_moment, _opts), do: ""

  # CLDR's relative patterns hold the count as plain digits; it is written in the language's own.
  defp ago_part(%{type: :integer, value: digits}, locale) do
    case Integer.parse(String.replace(digits, ~r/\D/u, "")) do
      {count, ""} -> number(count, locale: locale)
      _not_a_count -> digits
    end
  end

  defp ago_part(%{value: text}, _locale), do: text

  defp now(%DateTime{}), do: DateTime.utc_now()
  defp now(%NaiveDateTime{}), do: NaiveDateTime.utc_now()
  defp now(%Date{}), do: Date.utc_today()

  @doc """
  A number with the language's digits and separators: `1,284` in English, `1.284` in German,
  `۱٬۲۸۴` in Persian. Other options are `Localize.Number.to_string/2`'s, such as
  `format: :percent` or `fractional_digits: 1`.
  """
  @spec number(term(), keyword()) :: String.t()
  def number(value, opts \\ [])

  def number(value, opts) when is_number(value) or is_struct(value, Decimal),
    do: write(&Localize.Number.to_string/2, value, Keyword.put(opts, :locale, cldr_locale(opts)))

  def number(_not_a_number, _opts), do: ""

  @doc """
  A number shortened as the language shortens it: `8.4K`, `1.2M` in English, `1,2 Mio.` in German.
  """
  @spec compact(term(), keyword()) :: String.t()
  def compact(value, opts \\ []), do: number(value, Keyword.put(opts, :format, :short))

  @doc """
  Phrases joined as the language joins a list: `a, b, and c` in English, `a, b und c` in German.
  `list_style: :or` joins with "or".
  """
  @spec list([String.t()], keyword()) :: String.t()
  def list(items, opts \\ [])

  def list(items, opts) when is_list(items),
    do: write(&Localize.List.to_string/2, items, Keyword.put(opts, :locale, cldr_locale(opts)))

  def list(_not_a_list, _opts), do: ""

  @doc """
  `strings` in the language's alphabetical order — accents, case and its own letters where it puts
  them (CLDR collation).
  """
  @spec sort([String.t()], keyword()) :: [String.t()]
  def sort(strings, opts \\ []) when is_list(strings),
    do: Localize.Collation.sort(strings, locale: cldr_locale(opts))

  @doc """
  The name of the language `code` names, in the reader's language: `language("fa")` is `Persian`
  in English and `فارسی` in Persian. A region is the language's own name where CLDR has one —
  `pt-BR` is `Brazilian Portuguese` — and in brackets where it has none, `fa-IR` is
  `Persian (Iran)`. `nil` for a code CLDR does not know.
  """
  @spec language(String.t(), keyword()) :: String.t() | nil
  def language(code, opts \\ [])

  def language(code, opts) when is_binary(code) do
    case Localize.Locale.LocaleDisplay.display_name(code,
           locale: cldr_locale(opts),
           language_display: :dialect
         ) do
      {:ok, name} -> name
      {:error, _unknown} -> nil
    end
  end

  def language(_no_code, _opts), do: nil

  defp write(fun, value, format, opts) when is_atom(format) or is_binary(format),
    do: write(fun, value, format: format, locale: cldr_locale(opts))

  defp write(fun, value, opts) do
    case fun.(value, opts) do
      {:ok, text} -> text
      {:error, _cannot} -> ""
    end
  end
end
