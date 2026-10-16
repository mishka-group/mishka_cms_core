# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.ErrorStatus do
  @moduledoc """
  What one entry of a site's Error Page answers for: an HTTP status code (`404`, `500`, …) or
  `:offline`, the page an offline site shows its visitors.

  `:offline` is not an HTTP code. The page it names is answered as a 503 by
  `MishkaCms.Plugs.MaintenanceGate`, at whatever address the visitor asked for, and when a site has
  no such entry the gate draws its built-in page instead.

  It is the `status` field's type on `MishkaCmsCore.Runtime.ErrorPage` and
  `MishkaCmsCore.Runtime.ErrorPageDraft`, so both store the same thing: a code stays a JSON number,
  `:offline` is stored as `"offline"` and read back as the atom.

  `parse/1` is the same reading for everything else that is handed a status as text — the builder's
  `?status=`, the preview's error-code picker, the Code tab's `<!-- offline -->` markers.
  """
  use Ash.Type
  use Gettext, backend: MishkaCmsCore.Gettext

  @offline :offline

  # The codes the Error Page form offers, beside `:offline`. A request that fails is answered with
  # one of these; their labels are Plug's own reason phrases.
  @client_codes [400, 401, 402, 403, 404, 405, 406, 407, 408, 409, 410, 411, 412, 413, 414, 415] ++
                  [416, 417, 418, 421, 422, 423, 424, 425, 426, 428, 429, 431, 451]
  @server_codes [500, 501, 502, 503, 504, 505, 506, 507, 508, 510, 511]

  @reasons %{
    400 => gettext_noop("Bad Request"),
    401 => gettext_noop("Unauthorized"),
    402 => gettext_noop("Payment Required"),
    403 => gettext_noop("Forbidden"),
    404 => gettext_noop("Not Found"),
    405 => gettext_noop("Method Not Allowed"),
    406 => gettext_noop("Not Acceptable"),
    407 => gettext_noop("Proxy Authentication Required"),
    408 => gettext_noop("Request Timeout"),
    409 => gettext_noop("Conflict"),
    410 => gettext_noop("Gone"),
    411 => gettext_noop("Length Required"),
    412 => gettext_noop("Precondition Failed"),
    413 => gettext_noop("Request Entity Too Large"),
    414 => gettext_noop("Request-URI Too Long"),
    415 => gettext_noop("Unsupported Media Type"),
    416 => gettext_noop("Requested Range Not Satisfiable"),
    417 => gettext_noop("Expectation Failed"),
    418 => gettext_noop("I'm a teapot"),
    421 => gettext_noop("Misdirected Request"),
    422 => gettext_noop("Unprocessable Content"),
    423 => gettext_noop("Locked"),
    424 => gettext_noop("Failed Dependency"),
    425 => gettext_noop("Too Early"),
    426 => gettext_noop("Upgrade Required"),
    428 => gettext_noop("Precondition Required"),
    429 => gettext_noop("Too Many Requests"),
    431 => gettext_noop("Request Header Fields Too Large"),
    451 => gettext_noop("Unavailable For Legal Reasons"),
    500 => gettext_noop("Internal Server Error"),
    501 => gettext_noop("Not Implemented"),
    502 => gettext_noop("Bad Gateway"),
    503 => gettext_noop("Service Unavailable"),
    504 => gettext_noop("Gateway Timeout"),
    505 => gettext_noop("HTTP Version Not Supported"),
    506 => gettext_noop("Variant Also Negotiates"),
    507 => gettext_noop("Insufficient Storage"),
    508 => gettext_noop("Loop Detected"),
    510 => gettext_noop("Not Extended"),
    511 => gettext_noop("Network Authentication Required")
  }

  @type t :: integer() | :offline

  @doc "The status of the page an offline site shows."
  @spec offline() :: :offline
  def offline, do: @offline

  @doc """
  A status from whatever spelled it, or `nil` when it names none.

      iex> MishkaCmsCore.Runtime.ErrorStatus.parse("404")
      404
      iex> MishkaCmsCore.Runtime.ErrorStatus.parse("offline")
      :offline
      iex> MishkaCmsCore.Runtime.ErrorStatus.parse("teapot")
      nil
  """
  @spec parse(term()) :: t() | nil
  def parse(status) when is_integer(status), do: status
  def parse(@offline), do: @offline
  def parse("offline"), do: @offline

  def parse(status) when is_binary(status) do
    case Integer.parse(String.trim(status)) do
      {code, ""} -> code
      _not_a_status -> nil
    end
  end

  def parse(_status), do: nil

  @doc """
  Whether a list of Error Page entries holds the `:offline` one, however its status was spelled.
  """
  @spec offline_entry?([map()]) :: boolean()
  def offline_entry?(entries) when is_list(entries),
    do: Enum.any?(entries, &(parse(Map.get(&1, :status) || Map.get(&1, "status")) == @offline))

  @doc """
  The choices the Error Page form offers, `:offline` first, then the client and server error codes
  by group, in the shape a Gervaz `:select` takes.
  """
  @spec choices() :: [{String.t(), String.t() | [{String.t(), integer()}]}]
  def choices do
    [
      {gettext_noop("Offline (the page an offline site shows)"), "offline"},
      {gettext_noop("Client errors"), for(code <- @client_codes, do: {code_label(code), code})},
      {gettext_noop("Server errors"), for(code <- @server_codes, do: {code_label(code), code})}
    ]
  end

  @doc "A status as a person reads it: `404 · Not Found`, or `Offline`."
  @spec label(t()) :: String.t()
  def label(@offline), do: gettext("Offline")

  def label(code) when code in @client_codes or code in @server_codes,
    do: gettext("%{code} · %{reason}", code: code, reason: reason(code))

  def label(code), do: to_string(code)

  defp code_label(code), do: "#{code} · #{@reasons[code]}"

  defp reason(code), do: Gettext.gettext(MishkaCmsCore.Gettext, Map.fetch!(@reasons, code))

  @impl Ash.Type
  def storage_type(_constraints), do: :string

  @impl Ash.Type
  def cast_input(nil, _constraints), do: {:ok, nil}
  def cast_input("", _constraints), do: {:ok, nil}

  def cast_input(value, _constraints) do
    case parse(value) do
      nil -> :error
      status -> {:ok, status}
    end
  end

  @impl Ash.Type
  def cast_stored(nil, _constraints), do: {:ok, nil}
  def cast_stored(value, constraints), do: cast_input(value, constraints)

  @impl Ash.Type
  def dump_to_native(nil, _constraints), do: {:ok, nil}
  def dump_to_native(code, _constraints) when is_integer(code), do: {:ok, code}
  def dump_to_native(@offline, _constraints), do: {:ok, "offline"}
  def dump_to_native(_value, _constraints), do: :error

  @impl Ash.Type
  def generator(_constraints),
    do: StreamData.one_of([StreamData.member_of([404, 500]), StreamData.constant(@offline)])
end
