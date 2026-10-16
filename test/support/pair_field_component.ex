# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.PairFieldComponent do
  @moduledoc """
  A field component that binds by `name` and `value` rather than by a `%Phoenix.HTML.FormField{}` —
  the documented fallback, and the one shape the installed kit never exercises.

  All 23 of Chelekom's fields take a `FormField` struct, so the editor only ever writes
  `field={f[:email]}` for them and the pair path is never taken. A kit on the fallback gets
  `name={f[:email].name}` and `value={f[:email].value}` written instead, and those two expressions
  must arrive as the two STRINGS they name — not as the whole struct, which renders as
  `protocol Phoenix.HTML.Safe not implemented` and red-boxes the node on the surface the form is
  authored on.

  It has to be a REAL compiled function component: the canvas reads `__components__/0` for a
  component's declared attributes, and calls it through `apply/3`, which is the path where the
  synthesised binding is handed over.

  `name` carries no default on purpose, which is what makes a dropped binding load-bearing rather
  than cosmetic.
  """
  use Phoenix.Component

  attr(:name, :string, doc: "the input name, which a form field's `.name` supplies")
  attr(:value, :string, default: nil)

  def text(assigns) do
    ~H"""
    <input type="text" name={@name} value={@value} />
    """
  end
end
