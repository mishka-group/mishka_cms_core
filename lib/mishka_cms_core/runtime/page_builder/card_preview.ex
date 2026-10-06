defmodule MishkaCmsCore.Runtime.PageBuilder.CardPreview do
  @moduledoc """
  What a palette card looks like before you drop it — the small document shown when the pointer rests
  on a card.

  ## It previews the drop, not the component

  The source is the card's own `data-template`: the exact HEEx a drag carries, presets and all. So a
  card whose preset says "outline, small" previews outline and small, and what the preview shows is
  what the page gets. Rendering some other example of the component would be a nicer picture and a
  worse answer.

  ## Why this is cheap enough to fire on hover

  Three measurements decided the design, against the real 171-component install:

    * the rendered fragment is **757–1,826 bytes** — a whole `<.component …/>` expanded. That is what
      travels over the socket per hover;
    * rendering it costs **~2 ms warm** and 0.5–1.4 s the first time a component is asked for, which
      is its module being compiled. So the first hover is asynchronous with a placeholder and every
      later one is instant — and `MishkaCmsCore.Runtime.States.CardPreviewState` means "later" covers
      the rest of the session;
    * the CSS costs **nothing**. The site's compiled bundle is served at `/assets/css/<site>/<hash>`
      as `immutable`, and the canvas frame has already downloaded it by the time anyone hovers a
      card. The preview links the same URL and the browser answers from cache. Inlining it instead
      would have put 194 KB on every hover.

  Compare the honest alternative: `RuntimePreview.render_example/3` builds a standalone document with
  its own generated CSS — 335 KB and ~1 s each, every time. That is right for a modal somebody opened
  on purpose and wrong for something that follows the pointer.

  ## The admin's Content-Security-Policy reaches inside the frame

  A `srcdoc` document inherits the embedding page's policy, and the admin's is enforced:
  `style-src-elem 'self' 'nonce-<n>'`, with no `'unsafe-inline'`. Two consequences, both of which
  fail SILENTLY — the preview simply draws unstyled, which reads as a broken component:

    * every `<style>` this module writes carries the page's nonce, read in the LiveView process and
      passed in;
    * the frame is `sandbox="allow-same-origin"`. Under a bare `sandbox=""` the document has an
      opaque origin, `'self'` matches nothing, and the linked bundle is refused. It is granted
      same-origin and NOT `allow-scripts`: with nothing able to run inside, the origin buys the frame
      no capability, and it is also what lets the panel read the drawn height and size itself to fit.

  `RuntimePreview` cannot make the same trade — it runs Tailwind's browser build inside its frame,
  and `allow-scripts` together with `allow-same-origin` defeats the sandbox entirely — which is why
  that one inlines its CSS and this one links it.

  ## The cache holds the body, never the document

  Only the rendered markup is remembered. The surrounding document — which carries the stylesheet's
  content-hashed URL — is assembled on every read, at a cost of one string join.

  That is what makes a recompile safe. A cached DOCUMENT would keep pointing at the previous bundle's
  hash, and an immutable URL that no longer exists fails silently: the preview draws unstyled and
  looks like a broken component rather than a stale cache. Holding the body alone means a new hash is
  picked up the moment it exists, with nothing to invalidate.

  The markup itself can still go stale when a component is recompiled, which is why the cache listens
  for that and drops what changed.

  ## What it does not do

  It does not render a component that needs data — one whose template reads `@id` or another required
  attr raises, and the preview says so in the same words the Preview tab uses rather than showing a
  blank box. That is a real answer: the component needs configuring before it will draw.

  See `MishkaCmsCore.Runtime.RuntimePreview` for the heavyweight previews.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.LiveViewHelpers
  alias MishkaCmsCore.Runtime.RuntimePreview
  alias MishkaCmsCore.Runtime.States.AssetsState
  alias MishkaCmsCore.Runtime.States.CardPreviewState

  # THE WIDTH IT IS LAID OUT AT, and the panel shows it at half. Wide enough that a nav, a table or
  # a card reads as itself rather than as a column of wrapped text — and above the `md` breakpoint,
  # so a component that rearranges on a narrow screen previews the way dropping it on a desktop page
  # would look, not the way its phone layout does.
  #
  # `PbPaletteHover` scales to exactly this, so the two must agree.
  @width 760

  @needs_configuring gettext_noop("This component needs configuring before it will draw.")

  @doc """
  The preview document for `template`, as a string ready for an iframe's `srcdoc`.

  Returns `{:ok, html}`, or `{:error, message}` when the template will not render — the caller shows
  the message, because "this needs configuring first" is worth saying.
  """
  @spec document(String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def document(template, site_name, nonce \\ nil)

  def document(template, site_name, nonce) when is_binary(template) do
    case body(template, site_name) do
      {:ok, markup} -> {:ok, frame(markup, site_name, nonce)}
      {:error, message} -> {:error, translate(message)}
    end
  end

  def document(_template, _site_name, _nonce),
    do: {:error, gettext("There is nothing to preview.")}

  @doc "The width the preview is laid out at, so the caller can scale the frame to fit."
  @spec width() :: pos_integer()
  def width, do: @width

  defp body(template, site_name) do
    case CardPreviewState.get(template, site_name) do
      nil -> template |> render(site_name) |> remember(template, site_name)
      cached -> cached
    end
  end

  # FOR THE EDITOR'S SITE, as the page the card drops into will render it: that site's components and
  # the global ones, and no other site's.
  defp render(template, site_name) do
    site_name
    |> LiveViewHelpers.rendering_for(fn ->
      LiveViewCompiler.render_template(template, %{site: site_name || "Global"})
    end)
    |> case do
      markup when is_binary(markup) -> {:ok, markup}
      {:error, message} -> {:error, readable(message)}
    end
  end

  # A REFUSAL IS REMEMBERED TOO. A component that needs an `id` will need one on the next hover as
  # well, and re-rendering to be told so again costs the same second the first attempt did.
  defp remember(result, template, site_name) do
    CardPreviewState.put(template, site_name, result)
    result
  end

  # The same two layers the canvas links, in the same order and for the same reasons: the site's own
  # bundle when it has been compiled, the shared base when it has not.
  defp frame(markup, site_name, nonce) do
    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        #{stylesheet(site_name, nonce)}
        <style#{nonce_attr(nonce)}>
          html,body{margin:0;padding:0;background:transparent}
          body{width:#{@width}px;padding:14px;font-family:ui-sans-serif,system-ui,sans-serif}
    #{RuntimePreview.chrome_css()}    </style>
      </head>
      <body>#{markup}</body>
    </html>
    """
  end

  defp stylesheet(site_name, nonce) do
    case href(site_name) || href("__shared_base__") do
      nil -> "<style#{nonce_attr(nonce)}>#{inline_css(site_name)}</style>"
      link -> ~s|<link rel="stylesheet" href="#{link}" />|
    end
  end

  defp nonce_attr(nonce) when is_binary(nonce) and nonce != "", do: ~s| nonce="#{nonce}"|
  defp nonce_attr(_none), do: ""

  defp href(nil), do: nil

  defp href(id) do
    case AssetsState.get(id, "css") do
      {:ok, %{hash: hash, value: value}}
      when is_binary(hash) and hash != "" and is_binary(value) and value != "" ->
        "/assets/css/#{URI.encode_www_form(id)}/#{hash}"

      _no_hash ->
        nil
    end
  end

  # Only reached before anything has been compiled, when there is no hash to address the bundle by.
  defp inline_css(site_name) do
    case site_name && AssetsState.get_value(site_name, "css") do
      css when is_binary(css) and css != "" -> css
      _none -> AssetsState.get_value("__shared_base__", "css") || ""
    end
  end

  # The compiler's message is a raise turned into a string, so it opens with the exception module.
  # The person hovering a card wants the sentence, not the struct.
  defp readable(message) when is_binary(message) do
    message
    |> String.split("\n")
    |> List.first()
    |> String.replace(~r/^\*\* \([A-Za-z.]+\)\s*/, "")
    |> String.trim()
    |> case do
      "" -> @needs_configuring
      line -> line
    end
  end

  defp readable(_message), do: @needs_configuring

  defp translate(@needs_configuring),
    do: Gettext.gettext(MishkaCmsCore.Gettext, @needs_configuring)

  defp translate(message), do: message
end
