defmodule MishkaCmsCore.Runtime.States.CardPreviewStateTest do
  @moduledoc """
  The cache behind the palette's hover preview, and the plugin that empties it.

  The invalidation is the part worth a test. A preview is markup a component's module produced, so a
  recompiled component makes every cached preview a possible lie — and a stale preview is the worst
  kind of wrong, because it looks right: the author sees the component they just edited still drawn
  the old way and concludes the edit did not take.
  """
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Runtime.PageBuilder.CardPreviewInvalidator
  alias MishkaCmsCore.Runtime.States.CardPreviewState
  alias MishkaInstaller.Event.{Event, EventHandler}

  @moduletag :unit

  setup do
    CardPreviewState.drop_all()
    on_exit(&CardPreviewState.drop_all/0)
    :ok
  end

  describe "what it holds" do
    test "a preview comes back as it went in" do
      CardPreviewState.put("<p>x</p>", nil, {:ok, "<b>drawn</b>"})

      assert CardPreviewState.get("<p>x</p>", nil) == {:ok, "<b>drawn</b>"}
    end

    test "a refusal is held too" do
      CardPreviewState.put("<p>x</p>", nil, {:error, "needs an id"})

      assert CardPreviewState.get("<p>x</p>", nil) == {:error, "needs an id"}
    end

    test "asking for something it has never seen is not an error" do
      assert CardPreviewState.get("<p>never</p>", nil) == nil
    end

    # The key is the template, so a preset that changes the drop changes the preview.
    test "two templates are two entries" do
      CardPreviewState.put("<p>a</p>", nil, {:ok, "a"})
      CardPreviewState.put("<p>b</p>", nil, {:ok, "b"})

      assert CardPreviewState.size() == 2
    end

    test "and one template under two sites is two entries" do
      CardPreviewState.put("<p>a</p>", nil, {:ok, "global"})
      CardPreviewState.put("<p>a</p>", "shop", {:ok, "shop"})

      assert CardPreviewState.get("<p>a</p>", nil) == {:ok, "global"}
      assert CardPreviewState.get("<p>a</p>", "shop") == {:ok, "shop"}
    end
  end

  describe "forgetting" do
    test "one site's previews go without touching another's" do
      CardPreviewState.put("<p>a</p>", "shop", {:ok, "shop"})
      CardPreviewState.put("<p>a</p>", "blog", {:ok, "blog"})

      CardPreviewState.drop("shop")

      assert CardPreviewState.get("<p>a</p>", "shop") == nil
      assert CardPreviewState.get("<p>a</p>", "blog") == {:ok, "blog"}
    end

    test "everything goes at once when it has to" do
      CardPreviewState.put("<p>a</p>", "shop", {:ok, "shop"})
      CardPreviewState.put("<p>b</p>", nil, {:ok, "global"})

      CardPreviewState.drop_all()

      assert CardPreviewState.size() == 0
    end
  end

  describe "the plugin that empties it when a component is recompiled" do
    setup do
      {:ok, _} =
        Event.write(%{
          name: CardPreviewInvalidator,
          event: "runtime:after_module_compile",
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile("runtime:after_module_compile", :start, false)
      on_exit(fn -> Event.unregister(:name, CardPreviewInvalidator, false) end)
      :ok
    end

    # The announcement the compiler already makes — this reacts to it exactly as an extension would.
    test "a compiled module empties the cache" do
      CardPreviewState.put("<p>a</p>", nil, {:ok, "drawn the old way"})

      MishkaInstaller.Event.Hook.call(
        "runtime:after_module_compile",
        %{module: SomeCompiledModule},
        return: false
      )

      assert eventually(fn -> CardPreviewState.size() == 0 end)
    end
  end

  # The announcement is fire-and-forget by design, so the assertion waits for the effect rather than
  # for a reply — without a sleep, which would pass on a slow machine and fail on a fast one.
  defp eventually(check, attempts \\ 200)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    case check.() do
      true -> true
      false -> eventually(check, attempts - 1)
    end
  end
end
