defmodule MishkaCmsCore.Runtime.Resources.Validations.PreventMasterLanguageDeletion do
  @moduledoc """
  Refuses to destroy the original edition of a translated record while translations of it are live.

  A translated record is several rows sharing a `language_group_id`, and the group's key *is* the
  original's own id — so the original is the row where `id == language_group_id`, or where there is
  no group at all, and every other row in the group points at it. Destroying the original first would
  leave those pointing at nothing, so this says no until they are gone. A translation itself is free
  to go at any time.

  It queries `changeset.resource`, so the same validation guards every resource that carries the
  pattern — `MishkaCmsCore.Runtime.Page`, `MishkaBlog.Collection`, `MishkaBlog.Tag`,
  `MishkaBlog.BlogPost`, `MishkaDocument.Workspace`, and anything added later.

  Put it on every destroy action, the archiving ones and the permanent ones:

      destroy :destroy do
        validate MishkaCmsCore.Runtime.Resources.Validations.PreventMasterLanguageDeletion
      end

      destroy :permanent_destroy do
        validate MishkaCmsCore.Runtime.Resources.Validations.PreventMasterLanguageDeletion
      end

  Both kinds wait for the same thing, a translation that is still live. An archived one is in nobody's
  way: `MishkaCmsCore.Runtime.Resources.Changes.PreventOrphanedTranslationRestore` keeps it from
  coming back under an original that is not there. To remove a whole group, destroy the translations
  first, then the original.

  It holds for every caller, `authorize?: false` included, and a check that cannot be answered
  refuses too.

  ## Plugin event

  Each refusal for live translations fires `runtime:language:delete_refused` with `%{resource, id,
  site_id, language, translations, message}`: the original, its language, the languages of its live
  translations, and the message the refusal carries.

  ## The refusal

  An `Ash.Error.Changes.InvalidAttribute` on `:language_group_id` whose message is `message/2`: the
  original's language, the languages still live, and what to do. The API returns that message as it
  is.

  The message is written in the Gettext locale of the process the action runs in, `errors` domain,
  since the language names inside it are translated too. A request with no locale reads it in
  English. Its `private_vars` hold `live_translations_of: id`, the original's id, which is how
  `MishkaCmsCore.LanguageEditions.refused_originals/1` finds it among an action's errors.
  """

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query

  alias Ash.Error.Changes.InvalidAttribute
  alias MishkaCmsCore.Runtime.Languages

  @impl true
  def init(_opts), do: {:ok, []}

  # A RECORD WITH NO GROUP IS AN ORIGINAL TOO: one stored before its resource had the column, until it
  # is given its own. A translation made of it meanwhile joins the group of its id all the same.
  @impl true
  def validate(%{data: %{id: id, language_group_id: group}} = changeset, _opts, _context)
      when group == id or is_nil(group) do
    changeset.resource
    |> Ash.Query.filter(language_group_id == ^id and id != ^id)
    |> Ash.Query.select([:language])
    |> Ash.read(tenant: changeset.data.site_id, authorize?: false, page: false)
    |> case do
      {:ok, []} ->
        :ok

      {:ok, translations} ->
        language = Map.get(changeset.data, :language)
        languages = Enum.map(translations, & &1.language)
        message = message(language, languages)
        announce(changeset, languages, message)
        {:error, refusal(id, message)}

      {:error, _reason} ->
        {:error, refusal(id, unchecked(Map.get(changeset.data, :language)))}
    end
  end

  def validate(_changeset, _opts, _context), do: :ok

  @doc """
  What refusing an original says: its own language, the languages of its live translations, and
  what to do.

      message("en", ["fr", "fa"])
      #=> "This is the original English version. Its translations in French and Persian are still
      #    live, so it can't be deleted yet. Archive or delete those translations first, then this one."
  """
  @spec message(String.t() | atom() | nil, [String.t() | atom() | nil]) :: String.t()
  def message(language, [_one] = translations) do
    sentences(
      original(language),
      dgettext(
        "errors",
        "Its %{languages} translation is still live, so it can't be deleted yet. Archive or delete that translation first, then this one.",
        languages: Languages.names(translations)
      )
    )
  end

  def message(language, translations) when is_list(translations) do
    sentences(
      original(language),
      dgettext(
        "errors",
        "Its translations in %{languages} are still live, so it can't be deleted yet. Archive or delete those translations first, then this one.",
        languages: Languages.names(translations)
      )
    )
  end

  defp unchecked(language) do
    sentences(
      original(language),
      dgettext(
        "errors",
        "Its translations could not be checked just now, so it can't be deleted yet. Try again in a moment."
      )
    )
  end

  defp original(language) do
    case Languages.name(language) do
      nil -> dgettext("errors", "This is the original version.")
      name -> dgettext("errors", "This is the original %{language} version.", language: name)
    end
  end

  defp sentences(first, second), do: first <> " " <> second

  defp announce(%{resource: resource, data: data}, languages, message) do
    MishkaInstaller.Event.Hook.call(
      "runtime:language:delete_refused",
      %{
        resource: resource,
        id: data.id,
        site_id: Map.get(data, :site_id),
        language: Map.get(data, :language),
        translations: languages,
        message: message
      },
      return: false
    )
  end

  defp refusal(id, message) do
    InvalidAttribute.exception(
      field: :language_group_id,
      message: message,
      private_vars: [live_translations_of: id]
    )
  end
end
