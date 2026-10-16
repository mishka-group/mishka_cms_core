# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.ContentComponentSlotArg do
  @moduledoc """
  Test plugin for `runtime:render:before_content_component`'s slot meta. A marker written with
  `probe="seen"` gets as its `title` what reached it: the nearest component's `render_slot` value's
  `tag` (`none` when nothing did), then every value's `tag`, nearest first, then the marker's own
  uncast `label` — `outer|outer|x`. A marker written with `probe="drop"` has its `label` taken out
  of `attrs`. Every other marker is answered as it came.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:render:before_content_component"

  @impl true
  def call(%{attrs: attrs} = data, %{marker_attrs: %{"probe" => "seen"} = written} = meta) do
    nearest = (is_map(meta.slot_arg) && meta.slot_arg[:tag]) || "none"
    every = Enum.map_join(meta.slot_args, ",", & &1[:tag])

    {:reply, %{data | attrs: Map.put(attrs, :title, "#{nearest}|#{every}|#{written["label"]}")}}
  end

  def call(%{attrs: attrs} = data, %{marker_attrs: %{"probe" => "drop"}}),
    do: {:reply, %{data | attrs: Map.delete(attrs, :label)}}

  def call(data, _meta), do: {:reply, data}
end
