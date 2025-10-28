defmodule MishkaCmsCore.Runtime.PageBuilder.CodeSignature do
  @moduledoc """
  An HMAC over each stored snippet, so code that did not come through this application does not run.

  ## What it buys, and it is one thing

  Every future arbitrary-database-write bug in this CMS — an injection, a mis-scoped Ash action, a
  restored dump somebody tampered with — currently ends in remote code execution, because whatever is
  in `events`, `infos` or `helpers` is compiled into the module that serves the site. With signing
  on, such a write produces code that **does not run**: the signature will not match, and the
  compiler emits an inert clause instead.

  It is not a permission check and does not replace one. The resource's policies decide who may
  write; this decides whether what is stored was written by this application at all.

  ## The page still renders

  A snippet whose signature is missing or wrong is replaced by a clause that does nothing, and the
  rest of the document compiles and serves as normal. The alternative — refusing to compile — turns
  a tampered helper into a site-wide outage, which hands whoever tampered with it a better outcome
  than they had.

  ## The cost, stated plainly

  **A database restored into another environment runs no page code until it is re-signed.** The key
  is per-deployment, so a production dump loaded into staging carries signatures staging cannot
  verify. That is the feature working, and it will read as a bug the first time somebody hits it —
  `mix mishka.resign_code` is the answer, and the log line says so by name.

  ## Off unless a key is configured

  No key, no signing and no verification: `enabled?/0` is false, and everything behaves exactly as it
  did before this module existed. A deployment opts in by setting one, which is the only way to add
  this to an existing database without every page stopping at once.

      config :mishka_cms_core, :code_signing_key, System.get_env("CODE_SIGNING_KEY")
  """

  require Logger

  @doc """
  Whether this deployment signs and verifies stored code.

  False when no key is configured, which is the default and which makes every other function here a
  no-op — an existing database keeps working until somebody deliberately turns this on.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: key() not in [nil, ""]

  @doc """
  The signature for one snippet's code, or `nil` when signing is off.

  Normalized first, because a save that only changes indentation must not invalidate the signature
  and, more importantly, because the compiler has to compute the same digest from the same text —
  `\\r\\n` from a paste and trailing spaces from an editor are the two ways that goes wrong.
  """
  @spec sign(String.t() | nil) :: String.t() | nil
  def sign(code) when is_binary(code) do
    case enabled?() do
      false -> nil
      true -> :hmac |> :crypto.mac(:sha256, key(), normalize(code)) |> Base.encode16(case: :lower)
    end
  end

  def sign(_code), do: nil

  @doc """
  Whether `signature` is this deployment's signature for `code`.

  Answers true when signing is off — with no key there is nothing to verify, and the compiler must
  behave exactly as it did before. Compared in constant time, because a signature is a secret-derived
  value and a byte-at-a-time comparison leaks where it stopped matching.
  """
  @spec valid?(String.t() | nil, String.t() | nil) :: boolean()
  def valid?(code, signature)

  def valid?(code, signature) when is_binary(code) do
    case {enabled?(), signature} do
      {false, _any} -> true
      {true, signature} when is_binary(signature) -> constant_time?(sign(code), signature)
      {true, _missing} -> false
    end
  end

  def valid?(_code, _signature), do: false

  @doc """
  One snippet with its signature attached — what the resources store.

  A map with string keys keeps whatever it had; the key is added under the same kind of key the map
  already uses, so a snippet that arrived from JSON:API and one that arrived from the editor come out
  looking the same.
  """
  @spec put(map()) :: map()
  def put(%{} = snippet) do
    case {enabled?(), code_of(snippet)} do
      {false, _code} -> snippet
      {_on, nil} -> snippet
      {true, code} -> place(snippet, sign(code))
    end
  end

  def put(snippet), do: snippet

  @doc """
  Whether a stored snippet carries a signature this deployment made — what the compiler asks before
  it turns the snippet into a clause.
  """
  @spec trusted?(map()) :: boolean()
  def trusted?(%{} = snippet), do: valid?(code_of(snippet), signature_of(snippet))
  def trusted?(_snippet), do: false

  @doc false
  # Said once, in the words somebody who has just restored a dump needs to read.
  def warn_untrusted(kind, name) do
    Logger.warning(
      "[CodeSignature] #{kind} #{inspect(name)} is not signed for this deployment and will do " <>
        "nothing. If this database came from elsewhere, re-sign it; if it did not, treat it as " <>
        "code somebody put there another way."
    )
  end

  # \r\n from a paste and trailing spaces from an editor are the two ways the same code produces two
  # digests. Nothing else is touched: indentation inside a line is part of what was written.
  defp normalize(code) do
    code
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.join("\n")
    |> String.trim_trailing("\n")
  end

  # `Map.get/2` RATHER THAN `snippet[:code]`. A snippet is a plain map for `events` and `infos`, and a
  # `%MishkaCmsCore.Runtime.Resources.Embeddeds.Helper{}` for `helpers` — and a struct does not
  # implement Access, so the bracket form raised the moment a deployment configured a key and saved
  # anything carrying helpers. Every one of the four signed resources, on the next write.
  defp code_of(snippet), do: Map.get(snippet, :code) || Map.get(snippet, "code")
  defp signature_of(snippet), do: Map.get(snippet, :signature) || Map.get(snippet, "signature")

  # A STRUCT ONLY TAKES A FIELD IT DECLARES, and a signature written where there is no field for it
  # is lost between here and the column — `trusted?/1` would then answer false for a snippet this
  # deployment had just signed, which is a page whose helpers all went inert on the next save.
  # `Helper` declares one now, so a helper signs like any other snippet; a struct that does not is
  # returned unchanged rather than quietly given something it cannot keep.
  defp place(%_struct{} = snippet, signature) do
    case Map.has_key?(snippet, :signature) do
      true -> Map.put(snippet, :signature, signature)
      false -> snippet
    end
  end

  defp place(snippet, signature) do
    case Map.has_key?(snippet, "code") do
      true -> Map.put(snippet, "signature", signature)
      false -> Map.put(snippet, :signature, signature)
    end
  end

  defp key, do: Application.get_env(:mishka_cms_core, :code_signing_key)

  defp constant_time?(nil, _given), do: false

  defp constant_time?(expected, given) when byte_size(expected) == byte_size(given),
    do: :crypto.hash_equals(expected, given)

  defp constant_time?(_expected, _given), do: false
end
