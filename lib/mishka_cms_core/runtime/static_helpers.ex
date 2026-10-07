defmodule MishkaCmsCore.Runtime.StaticHelpers do
  @moduledoc """
  `MishkaCmsCore.Runtime.LiveViewHelpers` for the surfaces that render a template to a STRING.

  ## Why a second module rather than a flag

  Calling a stateful component produces a `%Phoenix.LiveView.Component{}`, which only a LiveView's
  diff turns into HTML — asked for iodata it raises:

      ** (ArgumentError) cannot convert component … to HTML.
      A component must always be returned directly as part of a LiveView template.

  Four surfaces render a runtime template to a string and then hand the string somewhere that is not
  a LiveView: the admin's Preview tab and its version previews
  (`MishkaCmsCore.Runtime.RuntimePreview`), the palette's card thumbnails
  (`MishkaCmsCore.Runtime.PageBuilder.CardPreview`), the examples encoder, and the public
  draft-preview URL. Before this, a page holding a live component gave every one of them that
  message instead of a picture.

  **Which one a template gets is decided by the CALLER's import list, not by the template.**
  `LiveViewCompiler.render_template/2` builds its own eval environment, and that environment is our
  code rather than a generated module — so swapping the import there fixes all four at once, and
  nothing a kit or an author writes can reach past it. A compiled page module imports the live
  `LiveViewHelpers` and is unaffected: a published page IS a LiveView and must get the real thing.

  ## What a reader sees instead

  The component's own markup in its cold state — `mount/1`, then the compiler's `update_many/1`,
  then `render/1` as the ordinary arity-1 function it is. Real markup, real size, real styling, with
  `@myself` nil so `phx-target` renders away. That is the same picture the builder's canvas draws,
  and for the same reason: a preview is a picture of a page, and a picture does not respond to
  clicks.

  ## Everything else is the same module

  This delegates the rest of the public surface rather than reimplementing it. The eval environment
  imports the whole module, so a function missing here is a function a template can no longer call —
  which is how a preview surface breaks silently.
  """

  alias MishkaCmsCore.Runtime.{ContentComponents, LiveViewHelpers}

  @doc """
  A runtime component, rendered as markup rather than as something LiveView will run.

  The signature `component/1` on purpose: the template says `<.component component_name="…"/>` and
  does not know, or need to know, which environment it was evaluated in.
  """
  defdelegate component(assigns), to: LiveViewHelpers, as: :static_component

  @doc """
  The captcha a form asks, as the same markup — a preview draws its box, which nothing fills.
  See `MishkaCmsCore.Captcha.Widget.captcha/1`.
  """
  defdelegate captcha(assigns), to: MishkaCmsCore.Captcha.Widget

  @doc "The same, from a name/site pair with extra assigns merged — `LiveViewHelpers.component/3`'s shape."
  def component(name, site, assigns \\ %{}) do
    LiveViewHelpers.static_component(Map.merge(assigns, %{component_name: name, site: site}))
  end

  @doc "Builds the runtime module for `name`/`site` if it is not loaded, and says whether it is."
  defdelegate ensure_component_loaded(name, site), to: LiveViewHelpers

  @doc """
  `LiveViewHelpers.rich_content/1` as markup: a stateful component a marker names is drawn cold, and
  a marker the published page draws nothing for says why in its place.
  """
  def rich_content(assigns), do: ContentComponents.draw(assigns, :static)

  @doc """
  The same renderer under its own name, for a template that calls `static_component/1` directly.

  `component/1` above is the name a runtime template uses; this is here because the eval environment
  imports the whole module and a function missing from it is one a template can no longer call.
  """
  defdelegate static_component(assigns), to: LiveViewHelpers

  @doc """
  A word in the language the preview is answering in — `LiveViewHelpers.t/2`. Missing here, a page
  that calls `t("…")` previewed as "Preview unavailable" while the published page rendered it.
  """
  defdelegate t(key, bindings \\ []), to: LiveViewHelpers
end
