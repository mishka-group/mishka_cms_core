defmodule MishkaCmsCore.Runtime.Resources.Changes.RegisterTranslationKeys do
  @moduledoc """
  Registers the keys a saved component, page or layout asks `t/1` for — in its template and in the
  code of its helpers, events and infos (`MishkaCmsCore.Runtime.Translations.source_keys/1`) — so
  they appear in the admin ready to translate.

  The runtime counterpart of `mix gettext.extract`: a component, page or layout is a database row,
  so its keys are read when it is SAVED rather than when a build runs. Each key gets a row in every
  language `MishkaCmsCore.Runtime.Translations.languages/1` names for the template's site — a
  global template's in every language any site publishes in, since it renders on all of them. See
  `MishkaCmsCore.Runtime.Translations.register/2`, which leaves an existing row, and the
  translation on it, exactly as it was.

      changes do
        change MishkaCmsCore.Runtime.Resources.Changes.RegisterTranslationKeys, on: [:create, :update]
      end

  ## After the write, and only when what asks for keys changed

  An `after_action`, so a record that fails to save registers nothing. An update that leaves the
  template and the code alone — a rename, a toggle — registers nothing either: the keys are the
  ones it already had.

  ## Not when the template has its own `t`

  A template whose helpers define a function named `t` is not importing ours, so its `t("…")` calls
  are its own business and nothing is registered for them.

  ## It never refuses a save

  Registration errors are collected and dropped. A template is the thing being saved; a key it could
  not register costs a row in the admin, which the next save or `Translations.sync/1` puts back.
  """
  use Ash.Resource.Change

  alias MishkaCmsCore.Runtime.{LiveViewHelpers, Translations}

  @impl true
  def change(changeset, _opts, _context) do
    if changeset.action_type == :create or asks_anew?(changeset) do
      Ash.Changeset.after_action(changeset, fn _changeset, record ->
        if translated?(record),
          do: :ok = Translations.register(record.site_id, Translations.source_keys(record))

        {:ok, record}
      end)
    else
      changeset
    end
  end

  defp asks_anew?(changeset) do
    changeset.resource
    |> Translations.source_fields()
    |> Enum.any?(&Ash.Changeset.changing_attribute?(changeset, &1))
  end

  # A TEMPLATE WHOSE OWN HELPERS DEFINE `t` IS NOT ASKING US. `LiveViewHelpers.imports/1` leaves our
  # `t/1` out of it, so its `t("…")` calls reach its own function — registering them would fill the
  # admin with rows nothing will ever ask for. The same function decides both, so they cannot differ.
  defp translated?(record),
    do: {:t, 1} in LiveViewHelpers.imports(Map.get(record, :helpers))
end
