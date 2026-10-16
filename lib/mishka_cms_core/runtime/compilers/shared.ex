# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.Shared do
  @moduledoc """
  The pieces the four kind compilers (component, layout, page, error page) genuinely share.

  ## What is here, and what deliberately is not

  `web_module/0` and `define_import/2` were byte-identical in all four and depend on nothing about
  the module they live in, so they live here once. `component_prefetch/2` is what the page and the
  layout compiler both write into their modules.

  `make_env/0,1` looks like a fifth copy and is not one. Two things stop it moving:

    * It closes over `__ENV__`, which is **the defining module's** environment. Moving it would
      silently change which aliases and imports are in scope when a template is evaluated — the
      subtlest possible way to break rendering.
    * The four are not the same function. `LiveViewCompiler.make_env/1` *raises* when an import
      fails, because a page whose helpers are missing must not render half-broken;
      `ComponentCompiler` and `ErrorCompiler` take no arguments and hardcode their import list, and
      `LayoutCompiler` warns. Those differences are policy, not drift.

  Collapsing them would be the kind of tidying that reads well in a diff and changes behaviour, so
  each stays with its compiler.
  """

  @doc """
  The host application's web module — what a compiled runtime module does `use` on.

  Read through `Application.compile_env/3`, so changing the key recompiles this module and, through
  it, every compiler that reads it.
  """
  # Read in the module body — `Application.compile_env/3` refuses to run inside a function, and this
  # is also what records the compile-time dependency: changing the key recompiles this module, and
  # the compilers recompile with it because they call `web_module/0` in their own module bodies.
  @web_module Application.compile_env(
                :mishka_cms_core,
                :web_module,
                MishkaCmsCore.Runtime.CompiledPageBase
              )

  @spec web_module() :: module()
  def web_module, do: @web_module

  @doc """
  Adds `module` to a macro environment's imports.

  Takes the environment as an argument rather than capturing one, which is exactly why this half is
  safe to share while `make_env` is not.
  """
  @spec define_import(Macro.Env.t(), module()) :: {:ok, Macro.Env.t()} | {:error, term()}
  def define_import(env, module), do: Macro.Env.define_import(env, [], module)

  @doc """
  What a page or layout module needs to build its components before it draws them
  (`MishkaCmsCore.Runtime.ComponentPrefetch`), from the template it is compiled from and the name of
  the site it belongs to, `nil` for a global one.

  The first element defines `__component_references__/0`, what the template names, kept for the
  walk a cold render takes. The second is the call its `render/1` makes first, carrying the
  components the template names in a tag that says which copy it draws, as module names.
  """
  @spec component_prefetch(String.t() | nil, String.t() | nil) :: {Macro.t(), Macro.t()}
  def component_prefetch(template, site) do
    references = MishkaCmsCore.Runtime.Compilers.CssClosure.references(template)

    named =
      for %{name: name, site: scope} <-
            MishkaCmsCore.Runtime.Compilers.CssClosure.certain_components(references, site),
          do:
            {MishkaCmsCore.Runtime.Compilers.Helpers.module_name(name, scope, "Component"), scope}

    definition =
      quote do
        @doc false
        def __component_references__, do: unquote(Macro.escape(references))
      end

    call =
      quote do
        :ok =
          MishkaCmsCore.Runtime.ComponentPrefetch.prefetch(
            __MODULE__,
            unquote(Macro.escape(named))
          )
      end

    {definition, call}
  end

  @doc """
  The content-addressed URL of a site's compiled stylesheet, or `nil` before its first compile.

  Error pages used to inline the whole bundle in a `<style>` tag, which meant every 404 sent the
  site's entire CSS over the wire uncached — 1.5 MB per missing image, per crawler, per broken link,
  on the one response you least want to be expensive. The same bytes are already served at this URL
  with a far-future cache header, and a visitor who reached a 404 by clicking a bad link on the site
  has it in cache already.

  `nil` means the site has never compiled; the caller should fall back to inlining, because an error
  page with no styling at all is worse than a large one.
  """
  @spec site_css_href(String.t()) :: String.t() | nil
  def site_css_href(site_name) do
    case MishkaCmsCore.Runtime.States.AssetsState.hash(site_name, "css") do
      hash when is_binary(hash) and hash != "" -> "/assets/css/#{site_name}/#{hash}.css"
      _none -> nil
    end
  end

  @doc """
  The content-addressed URL of a site's compiled JavaScript, or `nil` before its first compile.

  See `site_css_href/1` — same reasoning, same fallback.
  """
  @spec site_js_href(String.t()) :: String.t() | nil
  def site_js_href(site_name) do
    case MishkaCmsCore.Runtime.States.AssetsState.hash(site_name, "js") do
      hash when is_binary(hash) and hash != "" -> "/assets/js/#{site_name}/#{hash}.js"
      _none -> nil
    end
  end
end
