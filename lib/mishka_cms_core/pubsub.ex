# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.PubSub do
  @moduledoc """
  PubSub name module for the MishkaCMS system.

  This module serves as both the PubSub process name and a loadable module
  so that compile-time verifiers (e.g., MishkaGervaz) can confirm its existence.

  Started by `MishkaCmsCore.Application`, first among its children, as:

      {Phoenix.PubSub, name: MishkaCmsCore.PubSub}

  `:mishka_cms_core` is a dependency of every extension and of the host, so it is running before
  any extension's application starts. A host or a test helper does not start it again: a second
  child of the same name fails its supervisor's start.
  """
end
