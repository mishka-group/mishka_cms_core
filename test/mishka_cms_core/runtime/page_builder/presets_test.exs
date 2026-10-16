# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.PresetsTest do
  @moduledoc """
  A site's own answer to "what should this component look like when it lands".

  The reading half is what matters most: placing a component runs through here, so a settings row
  that is missing, empty or the wrong shape has to read as "no preset" rather than take the drop
  down with it.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.PageBuilder.Presets
  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings

  # The cache is process-global ETS and not sandboxed, so a key written here outlives the
  # transaction. Every key this file uses is dropped again on the way out.
  setup do
    on_exit(fn ->
      for name <- ~w(chelekom-button odd hand), do: SettingsState.delete(nil, Presets.key(name))
    end)

    :ok
  end

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        name: "chelekom-button",
        global?: true,
        attrs: [
          %{
            "name" => "variant",
            "type" => "string",
            "opts" => %{"values" => ~w(default outline shadow), "default" => "default"}
          }
        ],
        template: ~s(<button class={@variant}>x</button>),
        examples: []
      },
      overrides
    )
  end

  describe "get/2" do
    test "a component nobody has set a default for has none" do
      assert Presets.get(nil, "chelekom-button") == %{}
    end

    # PLACING A COMPONENT RUNS THROUGH HERE. A hand-edited row holding a list, a number or malformed
    # JSON must read as "no preset", not raise on the drop.
    test "a value of the wrong shape reads as none" do
      for value <- [[1, 2], 42, "not json", "[1,2]"] do
        Settings.put(Presets.key("odd"), value)
        assert Presets.get(nil, "odd") == %{}
      end
    end

    test "JSON in the row is still read, for a hand-edited setting" do
      Settings.put(Presets.key("hand"), ~s({"variant":"outline"}))
      assert Presets.get(nil, "hand") == %{"variant" => "outline"}
    end
  end

  describe "template/3" do
    test "with no preset it is the plain palette template" do
      assert Presets.template(entry(), "Global", nil) ==
               MishkaCmsCore.Builder.PaletteEntry.template(entry(), "Global")
    end

    test "with one, the choices are written into the markup" do
      Settings.put(Presets.key("chelekom-button"), %{"variant" => "outline"})

      assert Presets.template(entry(), "Global", nil) =~ ~s(variant="outline")
    end

    # A PRESET CAN ONLY SAY WHAT THE KIT UNDERSTANDS. The wizard drops an option the component does
    # not declare, so a stale preset cannot write markup nothing can render.
    test "an option the component does not have is dropped" do
      Settings.put(Presets.key("chelekom-button"), %{"variant" => "outline", "nonsense" => "yes"})

      markup = Presets.template(entry(), "Global", nil)

      assert markup =~ ~s(variant="outline")
      refute markup =~ "nonsense"
    end
  end

  describe "put/4" do
    setup do
      %{user: MishkaCmsCore.Test.Factory.create_user_with_permissions!(["*"])}
    end

    test "an empty map forgets the default rather than storing nothing", %{user: user} do
      Presets.put(user, nil, "chelekom-button", %{"variant" => "outline"})
      assert Presets.get(nil, "chelekom-button") == %{"variant" => "outline"}

      Presets.put(user, nil, "chelekom-button", %{})
      assert Presets.get(nil, "chelekom-button") == %{}
    end

    # The wizard posts every axis, including the untouched ones. Storing a blank would freeze
    # today's kit default into the site's preset.
    test "blank choices are not stored", %{user: user} do
      Presets.put(user, nil, "chelekom-button", %{"variant" => "outline", "size" => ""})

      assert Presets.get(nil, "chelekom-button") == %{"variant" => "outline"}
    end

    test "an actor with no site cannot be guessed at" do
      assert {:error, :no_actor} = Presets.put(%{}, nil, "chelekom-button", %{"variant" => "x"})
    end
  end
end
