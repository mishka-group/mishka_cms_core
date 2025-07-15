defmodule MishkaCmsCore.PubSub do
  @moduledoc """
  PubSub name module for the MishkaCMS system.

  This module serves as both the PubSub process name and a loadable module
  so that compile-time verifiers (e.g., MishkaGervaz) can confirm its existence.

  Started in the main application supervisor as:

      {Phoenix.PubSub, name: MishkaCmsCore.PubSub}
  """
end
