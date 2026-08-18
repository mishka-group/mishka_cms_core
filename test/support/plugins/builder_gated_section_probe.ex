defmodule MishkaCmsCore.Test.Plugins.BuilderGatedSectionProbe do
  @moduledoc """
  A plugin Inspector section that names who may see it — `admin:dashboard:code` — as an extension
  would.

  It proves the builder filters `builder:inspector:sections` per viewer through
  `MishkaCmsCore.Builder.Descriptor.permitted/2`: the sections the builder holds for a holder of the
  name carry it, and anyone else's do not.

  Registered by the test that needs it rather than by the application, so a normal boot pays nothing.
  """
  use MishkaInstaller.Event.Hook, event: "builder:inspector:sections", initial: %{priority: 91}

  alias MishkaCmsCore.Builder.Descriptor

  @key "gated-section"

  @doc "The key the section is registered under."
  @spec key() :: String.t()
  def key, do: @key

  @impl MishkaInstaller.Event.Hook
  def call(%{sections: sections} = payload),
    do: {:reply, %{payload | sections: sections ++ [descriptor()]}}

  def call(payload), do: {:reply, payload}

  @doc "The descriptor, gated on the dashboard's code permission."
  @spec descriptor() :: map()
  def descriptor do
    {:ok, built} =
      Descriptor.builder(%{
        key: @key,
        kind: :inspector_section,
        label: "Gated",
        priority: 91,
        permissions: ["admin:dashboard:code"]
      })

    built
  end
end
