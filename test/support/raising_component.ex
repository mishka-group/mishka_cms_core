# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.RaisingComponent do
  @moduledoc """
  A function component that raises while it renders — the thing the canvas has to survive.

  It has to be a REAL compiled function component, not a database row, because the failure being
  tested only happens where a database row cannot reach it: `apply/3` returns a `%Rendered{}` whose
  dynamic half is a closure, and the raise happens when LiveView invokes that closure inside its own
  diff. A row whose module was never compiled never gets that far — it takes the runtime's
  "failed to render" branch instead, which is a different thing and already handled.

  Nothing about this component is missing or malformed. It declares its one attribute, it has a
  default, and it renders fine with a value that names an atom that exists. It is exactly the case a
  pre-render check cannot catch.
  """
  use Phoenix.Component

  attr(:tone, :string, default: "calm", doc: "an atom name — anything else raises")

  def boom(assigns) do
    ~H"""
    <div data-tone={String.to_existing_atom(@tone)}>steady</div>
    """
  end

  attr(:tone, :string, default: "calm")

  @doc """
  Leaves by `throw` rather than by raising — which `rescue` does not catch.
  """
  def tossed(assigns) do
    ~H"""
    <div data-tone={throw(:no_thanks)}>steady</div>
    """
  end

  attr(:tone, :string, default: "calm")

  @doc """
  Calls a GenServer that is not there, which `exit`s — the likeliest of the three in a component
  that talks to anything, and the one that used to take the whole canvas with it.
  """
  def departed(assigns) do
    ~H"""
    <div data-tone={GenServer.call(:a_server_that_is_not_running, :hello)}>steady</div>
    """
  end
end
