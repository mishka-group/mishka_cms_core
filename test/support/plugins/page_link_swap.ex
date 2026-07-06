defmodule MishkaCmsCore.Test.Plugins.PageLinkSwap do
  @moduledoc """
  Test plugin for `cms_core:page:before_create`: sets the attributes a changeset carries in its
  `:link_swap` context, the way a plugin transforms a page before it is created. A changeset without
  that context passes through untouched.
  """
  use MishkaInstaller.Event.Hook, event: "cms_core:page:before_create"

  @impl true
  def call(%Ash.Changeset{context: %{link_swap: attributes}} = changeset, _meta),
    do: {:reply, Ash.Changeset.force_change_attributes(changeset, attributes)}

  def call(changeset, _meta), do: {:reply, changeset}
end
