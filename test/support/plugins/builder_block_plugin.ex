defmodule MishkaCmsCore.Test.Plugins.BuilderBlockPlugin do
  @moduledoc """
  An extension contributing a whole section to the Blocks library, in a category of its own.

  It exists to prove the merged list behaves like one list: the contribution answers the search box
  and the category chips exactly as a built-in block does, and its category gets a chip to reach it
  by. Merging AFTER the filtering gave it neither — it showed under every filter at once.
  """
  use MishkaInstaller.Event.Hook, event: "builder:blocks", initial: %{priority: 70}

  @block %{
    id: "commerce-testimonial-wall",
    title: "Testimonial wall",
    category: "social-proof",
    description: "A grid of customer quotes.",
    template: ~s(<section class="py-16"><blockquote>They loved it.</blockquote></section>)
  }

  @doc "The block this plugin contributes."
  @spec block() :: map()
  def block, do: @block

  @impl true
  def call(%{blocks: blocks} = payload), do: {:reply, %{payload | blocks: blocks ++ [@block]}}
  def call(payload), do: {:reply, payload}
end
