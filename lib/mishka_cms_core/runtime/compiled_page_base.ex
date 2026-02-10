defmodule MishkaCmsCore.Runtime.CompiledPageBase do
  @moduledoc """
  The default base that compiled runtime modules are built on — pages, layouts, components and error
  pages alike.

  The compilers emit `use <base>, :live_view` into every module they generate, and `<base>` is
  whatever `config :mishka_cms_core, :web_module` names. A host that has its own web entrypoint
  should point that setting at it, so runtime templates can reach the host's components and `~p`
  routes:

      config :mishka_cms_core, web_module: MyAppWeb

  Left unset, generation falls back to this module, which supplies the smallest base a HEEx template
  can render against: LiveView itself, HTML escaping, `Phoenix.LiveView.JS`, and the core components
  whatever `config :mishka_cms_core, :core_components` names. It is still short of a host's base — no
  gettext backend, no verified routes — because those are the host's to name. A template written
  against them needs the host configured.

  ## Why the core components are in the smallest base

  `MishkaCmsCore.Runtime.PageBuilder.Blocks` and
  `MishkaCmsCore.Runtime.PageBuilder.Elements` ship forms built from `<.form>` and `<.input>`, and
  `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler.render_template/2` already evaluates them against
  the same configured module — so the canvas, the preview and the published page resolve one set of
  components. Leaving them out of the base meant a form dropped from the library rendered in the
  editor and then failed to compile, on exactly the installs that have named no web module of their
  own.

  See `MishkaCmsCore.Runtime.Compilers.LayoutCompiler` and its siblings for where the base is emitted,
  and `MishkaCmsCore.Runtime.LiveViewHelpers` for the `component/1,2` the same modules import.
  """

  # Read in the module body, so changing the key recompiles this module and every generated module
  # built on it picks the new one up.
  @core_components Application.compile_env(
                     :mishka_cms_core,
                     :core_components,
                     MishkaCmsCore.CoreComponents
                   )

  defmacro __using__(:live_view) do
    core_components = @core_components

    quote do
      use Phoenix.LiveView

      import Phoenix.HTML
      import unquote(core_components)

      alias Phoenix.LiveView.JS
    end
  end

  # THE SIBLING A STATEFUL COMPONENT IS BUILT ON. Everything past the first line is identical,
  # because a live component renders the same HEEx against the same components — what differs is the
  # behaviour it implements and the lifecycle LiveView will call.
  #
  # The two `use` lines are alternatives and never both: stacking them compiles with six
  # `conflicting behaviours` warnings, `Phoenix.LiveComponent` silently wins whichever order they
  # are in, and any `on_mount` hook the `:live_view` clause brought becomes dead code.
  #
  # A host that names its own `:web_module` supplies this clause itself — `MishkaCmsWeb` already
  # does, as `live_component/0` — and this is the fallback for an install that names none.
  defmacro __using__(:live_component) do
    core_components = @core_components

    quote do
      use Phoenix.LiveComponent

      import Phoenix.HTML
      import unquote(core_components)

      alias Phoenix.LiveView.JS
    end
  end
end
