defmodule MishkaCmsCore.Runtime.ContentPreviewScrubber do
  @moduledoc """
  What a content editor preview is drawn through, as an `HtmlSanitizeEx` scrubber: every element
  and attribute a component draws — a `button`, a `form`, an `svg`, a `figure`, a `dl` — less what
  runs or reaches out.

    * elements removed with what they hold: `script`, `style`, `template`, `noscript`, and the ones
      that load or change another document — `iframe`, `frame`, `frameset`, `object`, `embed`,
      `applet`, `base`, `meta`, `link`;
    * attributes removed: every event attribute (`on…`), every LiveView binding (`phx-…`), and an
      address — `href`, `src`, `srcset`, `action`, `formaction`, `poster`, … — that is not http(s),
      mail, phone or the page's own, or, for a picture's `src`, `srcset` or `poster`, a
      `data:image/…` one (a kit's sample pictures travel as those); a `style` is read through
      `HtmlSanitizeEx.Scrubber.CSS`;
    * comments removed.

  A preview is drawn inert, in a shadow root, under the admin's Content Security Policy — so a form
  it holds submits nothing, a button presses nothing, and a `style` element would be refused anyway.
  `HtmlSanitizeEx.html5/1` keeps only the elements it names, and took a button's own element away and
  left its label, a definition list's terms without the list: every setting of those components
  changed nothing in the preview.
  """

  @removed ~w(script style template noscript iframe frame frameset object embed applet base meta link)
  @addresses ~w(href src action formaction poster background cite longdesc data xlink:href)
  @schemes ~w(http https mailto tel)
  @pictures ~w(src srcset poster)

  @doc "`html` with what a preview may not carry taken out."
  @spec sanitize(String.t() | nil) :: String.t()
  def sanitize(html), do: HtmlSanitizeEx.Scrubber.scrub(html, __MODULE__)

  @doc false
  def before_scrub(html), do: String.replace(html, "<![CDATA[", "")

  @doc false
  def scrub({:comment, _children}), do: ""
  def scrub({tag, _attributes, _children}) when tag in @removed, do: ""

  def scrub({tag, attributes, children}) when is_binary(tag),
    do: {tag, Enum.flat_map(attributes, &attribute/1), children}

  def scrub({_token, _children}), do: ""
  def scrub(text) when is_binary(text), do: text
  def scrub(_other), do: ""

  defp attribute({name, value}) do
    name = String.downcase(name)

    cond do
      String.starts_with?(name, ["on", "phx-"]) ->
        []

      name in @addresses ->
        if(address?(value, name), do: [{name, value}], else: [])

      name == "srcset" ->
        if(Enum.all?(candidates(value), &address?(&1, name)), do: [{name, value}], else: [])

      name == "style" ->
        [{name, HtmlSanitizeEx.Scrubber.CSS.scrub(value)}]

      true ->
        [{name, value}]
    end
  end

  # Read as a browser reads it, which ignores spaces and control characters in a scheme. An address
  # with no scheme is the page's own — a path, a query, a fragment.
  defp address?(value, name) do
    read = value |> String.replace(~r/[\x00-\x20]/, "") |> String.downcase()

    case Regex.run(~r/\A([a-z][a-z0-9+.\-]*):/, read) do
      [_whole, "data"] -> name in @pictures and String.starts_with?(read, "data:image/")
      [_whole, scheme] -> scheme in @schemes
      nil -> true
    end
  end

  # A `data:` address holds a comma of its own, so a srcset carrying one is read whole.
  defp candidates("data:" <> _rest = srcset), do: [srcset]

  defp candidates(srcset),
    do:
      srcset |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> String.split(" ") |> hd()))
end
