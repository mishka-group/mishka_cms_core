defmodule MishkaCmsCore.Test.Plugins.BuilderPageStarterPlugin do
  @moduledoc """
  An extension contributing a starting structure to the empty-page chooser — an agency's house shape
  beside the core's four.

  It exists to prove the card the chooser draws is a card that works: the click comes back as an id,
  and resolving that id against the core list alone made an extension's button the one control in
  the editor that does nothing at all — no structure, no error, no flash.

  Registered by the test that needs it rather than by the application, so a normal boot pays nothing.
  """
  use MishkaInstaller.Event.Hook, event: "builder:page_starters", initial: %{priority: 70}

  @structure %{
    id: "agency-split",
    title: "Wide and rail",
    description: "A wide band with a narrow rail beside it.",
    columns: 2,
    template: ~s(<div class="mx-auto w-full max-w-6xl px-6 py-12">
  <div class="grid grid-cols-[2fr_1fr] gap-6">
    <div class="min-h-[160px] rounded-lg border border-dashed border-slate-300 p-6"></div>
    <div class="min-h-[160px] rounded-lg border border-dashed border-slate-300 p-6"></div>
  </div>
</div>)
  }

  @doc "The starter this plugin contributes."
  @spec structure() :: map()
  def structure, do: @structure

  @impl true
  def call(%{structures: structures} = payload),
    do: {:reply, %{payload | structures: structures ++ [@structure]}}

  def call(payload), do: {:reply, payload}
end
