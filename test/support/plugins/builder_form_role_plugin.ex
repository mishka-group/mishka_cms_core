defmodule MishkaCmsCore.Test.Plugins.BuilderFormRolePlugin do
  @moduledoc """
  A plugin that names a component's part in a form when its markup cannot: every component whose
  name starts with `prefix/0` is called a Send button, and every one starting with `bogus/0` is
  answered with something that is not a role at all.

  Scoped to its own prefixes so the rest of the suite, which runs beside it, is untouched.
  """
  use MishkaInstaller.Event.Hook, event: "builder:form:role"

  @prefix "acme-plugin-"

  @bogus "acme-bogus-"

  @doc "The name prefix this plugin calls a Send button."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "The name prefix this plugin answers with a role that does not exist."
  @spec bogus() :: String.t()
  def bogus, do: @bogus

  @impl true
  def call(%{entry: %{name: @prefix <> _rest}} = payload),
    do: {:reply, %{payload | role: :submit}}

  def call(%{entry: %{name: @bogus <> _rest}} = payload), do: {:reply, %{payload | role: :shiny}}
  def call(payload), do: {:reply, payload}
end
