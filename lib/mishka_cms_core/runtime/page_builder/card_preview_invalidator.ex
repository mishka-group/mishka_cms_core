defmodule MishkaCmsCore.Runtime.PageBuilder.CardPreviewInvalidator do
  @moduledoc """
  Drops cached palette-card previews when the component they drew has been recompiled.

  A preview is markup produced by a component's module. Recompile the module and the markup can
  change — and a stale one is the worst kind of wrong, because it looks fine: the author sees the
  component they edited still drawn the old way and concludes their edit did not take.

  Hung off `runtime:after_module_compile`, which the compiler already announces, rather than a call
  wired into the compiler by hand. The core is a participant in its own events (ADR-14), so this is
  the same mechanism an extension would use to react to the same fact — see
  `MishkaCmsCore.Builder.Events`.

  It cannot tell WHICH site's previews a module belongs to without loading it, so it drops all of
  them. That is the cheap and correct trade: the cache refills at about two milliseconds an entry,
  and a compile is rare next to a hover.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:after_module_compile", initial: %{priority: 60}

  alias MishkaCmsCore.Runtime.States.CardPreviewState

  @impl true
  def call(payload) do
    CardPreviewState.drop_all()
    {:reply, payload}
  end
end
