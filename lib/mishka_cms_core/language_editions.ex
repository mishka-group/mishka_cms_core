defmodule MishkaCmsCore.LanguageEditions do
  @moduledoc """
  How an admin list of translatable records shows one row per document rather than one per translation.

  A translated record is several rows of the same resource sharing a `language_group_id`, and the
  group's key *is* the master's own id — so the master is the row where `language_group_id == id`, and
  a record with no group at all is trivially its own master. Listing every row means listing
  "Mishka CMS" beside "میشکا سی ام اس", which is the same document twice. The list shows masters; the
  card's editions row reaches the rest.

  Searching lifts the collapse. Someone typing Persian is looking for the Persian edition, and hiding
  it behind its English master would mean their search found nothing — so a search sees every row and
  each result opens its own language.

  Applied through a table's `on_load` hook rather than its read action, because only the hook runs late
  enough to see whether a search is active — `Ash.Query.for_read/3` happens before the table's filters
  are on the query.

  The archive is never collapsed. A master can be archived only once its translations are, so an
  archive of masters would hide every archived translation behind a row with no chip for it — none of
  them could be restored or deleted by anyone who did not know to search for it.

  Which is also why a whole group is restored, or deleted for good, in one selection there —
  `MishkaCmsCore.LanguageEditions.BulkActionHandler` hands that selection's masters over first, and
  `MishkaCmsCore.Runtime.Resources.Changes.PreventOrphanedTranslationRestore` refuses a translation
  whose master did not come back with it.

  A live update is the other way a row reaches the list. The table asks its own read — this hook and
  the list's filters included — whether the row that changed belongs, so a translation arriving on
  its own is left out; `on_realtime/2` redraws its master instead, so the master's chips hold it.

  ## Usage

      hooks do
        on_load fn query, state ->
          {:cont,
           query
           |> MishkaCmsCore.LanguageEditions.scope_to_masters(state)
           |> MishkaCmsCore.LanguageEditions.load_variants(state)}
        end

        on_realtime fn notification, socket ->
          MishkaCmsCore.LanguageEditions.on_realtime(notification, socket)
        end
      end

      events do
        bulk_action MishkaCmsCore.LanguageEditions.BulkActionHandler
      end

  The resource must declare both sides of the sibling relationship — `:language_variants` for a tenant
  and `:master_language_variants` for a master, the latter reading through a tenancy-bypassing action.

  ## A delete refused for live translations

  `MishkaCmsCore.Runtime.Resources.Validations.PreventMasterLanguageDeletion` refuses to archive, or
  delete for good, an original whose translations are live. `on_delete_refused/3` turns that refusal
  into an alert with a button that archives — or deletes for good — those translations at once
  (`MishkaCmsCoreWeb.Live.Admin.Components.TranslationsRefusal`). Every table of a translated resource
  declares it, the tables whose list is not collapsed included:

      hooks do
        on_row_action_error [:delete, :permanent_destroy],
                            &MishkaCmsCore.LanguageEditions.on_delete_refused/3

        on_bulk_action_error [:archive, :permanent_destroy],
                             &MishkaCmsCore.LanguageEditions.on_delete_refused/3

        on_bulk_action_success [:archive, :permanent_destroy],
                               &MishkaCmsCore.LanguageEditions.on_delete_refused/3
      end

  `refusal/3` reads what the alert shows and `take_translations/2` does what its button does, both as
  the signed-in admin, with the actions the resource's admin table itself reads and destroys with.

  Used by `MishkaDocument.Workspace` (via `MishkaDocument.WorkspaceScope`), `MishkaBlog.Collection`
  and `MishkaCmsCore.Runtime.Page`.
  See `MishkaCmsCore.LanguageAccent` for the colour a language's chip wears.
  """

  require Ash.Query

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  alias Ash.Error.Changes.InvalidAttribute
  alias MishkaCmsCore.Accounts.Helper
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.Resources.Validations.PreventMasterLanguageDeletion
  alias MishkaCmsCoreWeb.Live.Admin.Components.TranslationsRefusal
  alias MishkaGervaz.Resource.Info.Table, as: TableInfo
  alias MishkaGervaz.Table.Web.{DataLoader, Events}
  alias MishkaGervaz.Table.Web.Events.BulkActionResult

  @doc """
  Narrows the list to master editions while it is `collapsed?/1`.

  The `on_load` contract is `fn query, state -> query`.
  """
  @spec scope_to_masters(Ash.Query.t(), map()) :: Ash.Query.t()
  def scope_to_masters(query, state) do
    if collapsed?(state),
      do: Ash.Query.filter(query, is_nil(language_group_id) or language_group_id == id),
      else: query
  end

  @doc """
  Whether the list shows one row per document: the active list, while nobody is looking for a
  translation (`expanded?/1`). The archive shows every row.
  """
  @spec collapsed?(map()) :: boolean()
  def collapsed?(%{archive_status: :archived}), do: false
  def collapsed?(state), do: not expanded?(state)

  @doc """
  Keeps a collapsed list collapsed while rows change under it — the `on_realtime` hook.

  The table puts a created or changed row in by reading that one row, so a new translation would take
  a row of its own beside its master, and the master would keep the chips it was drawn with. While
  the list is `collapsed?/1`, a change to a translation redraws its master instead — read again, so
  its chips hold the change — and takes out any row the translation had. A master's own change, and
  every change while the list is not collapsed, goes the table's way.

  The `on_realtime` contract is `fn notification, socket -> {:cont, socket} | {:halt, socket}`.
  """
  @spec on_realtime(Ash.Notifier.Notification.t(), Phoenix.LiveView.Socket.t()) ::
          {:cont | :halt, Phoenix.LiveView.Socket.t()}
  def on_realtime(%{data: record}, socket) do
    state = socket.assigns.table_state

    case collapsed?(state) and translation?(record) do
      true -> {:halt, redraw_master(socket, state, record)}
      false -> {:cont, socket}
    end
  end

  defp translation?(%{id: id, language_group_id: group}), do: not is_nil(group) and group != id
  defp translation?(_record), do: false

  # Asked of the table's own read, as any row it puts in is — so a master they may not see, one no
  # longer in the active list, or one the list's filters leave out, is not drawn.
  defp redraw_master(socket, state, record) do
    stream = state.static.stream_name
    socket = Phoenix.LiveView.stream_delete(socket, stream, record)
    master_id = record.language_group_id

    with true <- DataLoader.in_view?(state, master_id),
         %{} = master <- Events.get_record(state, master_id, :active) do
      Phoenix.LiveView.stream_insert(socket, stream, master, at: 0)
    else
      _left_out -> socket
    end
  end

  @doc """
  Whether the reader has asked to see individual translations rather than one row per document.

  Two things lift the collapse, and both mean the same thing — someone is looking *for* a translation:

  - a search, because typing Persian and being shown only its English master finds nothing;
  - a language filter, because "show me Arabic" collapsed to masters would return nothing at all,
    every master being its own group's original.
  """
  @spec expanded?(map()) :: boolean()
  def expanded?(state), do: searching?(state) or language_filtered?(state)

  @doc "Whether a language filter is currently set."
  @spec language_filtered?(map()) :: boolean()
  def language_filtered?(%{filter_values: values}) when is_map(values),
    do: filled?(Map.get(values, :language))

  def language_filtered?(_state), do: false

  @doc """
  Loads a record's sibling editions, with whatever each chip needs to read off them.

  Which relationship holds the siblings depends on who is looking: a master reaches them through the
  tenancy-bypassing one. `loads` is the nested load each variant needs — a workspace's chip reads its
  `health_metrics` to say "FA · 76%", a collection's needs nothing beyond the record itself.
  """
  @spec load_variants(Ash.Query.t(), map(), list()) :: Ash.Query.t()
  def load_variants(query, state, loads \\ [])

  def load_variants(query, state, []), do: Ash.Query.load(query, [variants_relationship(state)])

  def load_variants(query, state, loads) do
    Ash.Query.load(query, [{variants_relationship(state), loads}])
  end

  @doc "Which sibling relationship this viewer reads through."
  @spec variants_relationship(map()) :: atom()
  def variants_relationship(%{master_user?: true}), do: :master_language_variants
  def variants_relationship(_state), do: :language_variants

  @doc """
  Whether the table is currently showing search results.

  Reads whatever the table's own text filters hold rather than naming one, so the resource stays the
  place a filter is declared.
  """
  @spec searching?(map()) :: boolean()
  def searching?(%{static: %{filters: filters}, filter_values: values}) when is_map(values) do
    filters
    |> Enum.filter(&(&1.type == :text))
    |> Enum.any?(&filled?(Map.get(values, &1.name)))
  end

  def searching?(_state), do: false

  defp filled?(value) when is_binary(value), do: String.trim(value) != ""
  defp filled?(nil), do: false
  defp filled?(_value), do: true

  @doc """
  A record's sibling editions — the same document in other languages — nearest thing first.

  The variants relationship is a self-join on `language_group_id`, so it returns the record itself, and
  every ungrouped record when the group is nil. Both have to go before this is a list of siblings.
  Sorted by language so a card's chips keep their order between renders.

  `extra` builds whatever else a chip shows beyond its language — pass a function of the variant.
  """
  @spec editions(map(), (map() -> map())) :: [map()]
  def editions(record, extra \\ fn _variant -> %{} end)

  def editions(%{language_group_id: nil}, _extra), do: []

  def editions(record, extra) do
    record
    |> variants()
    |> Enum.reject(&(&1.id == record.id))
    |> Enum.map(fn variant ->
      variant
      |> extra.()
      |> Map.merge(%{id: variant.id, language: to_string(variant.language)})
    end)
    |> Enum.uniq_by(& &1.language)
    |> Enum.sort_by(& &1.language)
  end

  # Only one of the two relationships is ever loaded — which one depends on who is looking — and the
  # other arrives as `%Ash.NotLoaded{}`, which is truthy. So this picks the one that is actually a
  # list rather than the first one that is merely present.
  defp variants(record) do
    Enum.find_value([:language_variants, :master_language_variants], [], fn key ->
      case Map.get(record, key) do
        list when is_list(list) -> list
        _unloaded -> nil
      end
    end)
  end

  @doc """
  The Gervaz hook that answers a delete refused for live translations with
  `MishkaCmsCoreWeb.Live.Admin.Components.TranslationsRefusal`'s alert — see the moduledoc.

  Takes a row action's failure or a bulk action's summary. Answers `{:halt, socket}`, so no error
  flash repeats the alert, when every failure was such a refusal; the socket otherwise — a bulk that
  partly went included, so its own message still says how many did.
  """
  @spec on_delete_refused(term(), map(), Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t() | {:halt, Phoenix.LiveView.Socket.t()}
  def on_delete_refused(failure, state, socket) do
    case refused_originals(failure) do
      [] ->
        socket

      refused ->
        TranslationsRefusal.show(state.static.resource, refused)
        if only_refusals?(failure), do: {:halt, socket}, else: socket
    end
  end

  @doc """
  The originals a failed destroy was refused for because their translations are live, each with the
  refusal's own message — from an Ash error, a list of them, or a bulk action's summary.

      LanguageEditions.refused_originals(error)
      #=> [%{id: "0199…", message: "This is the original English version. …"}]
  """
  @spec refused_originals(term()) :: [%{id: String.t(), message: String.t()}]
  def refused_originals(failure) do
    failure
    |> errors()
    |> Enum.flat_map(&refused/1)
    |> Enum.uniq_by(& &1.id)
  end

  defp refused(%InvalidAttribute{private_vars: vars, message: message}) when is_list(vars) do
    case Keyword.fetch(vars, :live_translations_of) do
      {:ok, id} -> [%{id: id, message: message}]
      :error -> []
    end
  end

  defp refused(_error), do: []

  defp errors(%BulkActionResult{failed_errors: errors}), do: errors(errors)
  defp errors(errors) when is_list(errors), do: Enum.flat_map(errors, &errors/1)
  defp errors(%{errors: [_ | _] = errors}), do: errors(errors)
  defp errors(error), do: [error]

  defp only_refusals?(%BulkActionResult{status: :error} = summary), do: all_refused?(summary)
  defp only_refusals?(%BulkActionResult{}), do: false
  defp only_refusals?(failure), do: all_refused?(failure)

  defp all_refused?(failure) do
    case errors(failure) do
      [] -> false
      errors -> Enum.all?(errors, &(refused(&1) != []))
    end
  end

  @typedoc """
  An original refused for its live translations, as `actor` sees it: `translations` are the live
  ones `actor` can read, and `allowed?` says `actor` may archive — or, for an archived original,
  delete for good — every one of them. `translations` is empty once none is live any more. `title`
  is nil for an original `actor` cannot read, whose `message` is then the refusal's own.
  """
  @type original :: %{
          id: String.t(),
          site_id: String.t() | nil,
          title: String.t() | nil,
          kind: :archive | :destroy | nil,
          message: String.t(),
          translations: [struct()],
          allowed?: boolean()
        }

  @typedoc """
  What the alert shows: `kind` is `:archive` for a live original, `:destroy` for an archived one, and
  `allowed?` holds when `actor` may act on every live translation of every original, and at least
  one is live.
  """
  @type refusal :: %{
          resource: module(),
          kind: :archive | :destroy | nil,
          originals: [original()],
          allowed?: boolean()
        }

  @doc """
  Reads `refused_originals/1`'s originals and their live translations as `actor`, through the actions
  the resource's admin table reads with, and asks whether `actor` may act on each translation
  (`Ash.can/3`, validations included) with the action the table's Delete would use. A master reads
  every site; a site admin reads its own site only. With no `actor` nothing is read.
  """
  @spec refusal(module(), [%{id: String.t(), message: String.t()}], map() | nil) :: refusal()
  def refusal(resource, refused, nil), do: summarize(resource, Enum.map(refused, &unread/1))

  def refusal(resource, refused, actor) do
    scope = scope(resource, actor)

    summarize(resource, Enum.map(refused, &read_original(&1, scope)))
  end

  defp summarize(resource, originals) do
    kind = Enum.find_value(originals, & &1.kind)
    originals = Enum.filter(originals, &(&1.kind in [kind, nil]))
    actionable = Enum.filter(originals, & &1.kind)
    pending = still_refused(%{originals: actionable})

    %{
      resource: resource,
      kind: kind,
      originals: originals,
      allowed?:
        pending != [] and length(actionable) == length(originals) and
          Enum.all?(pending, & &1.allowed?)
    }
  end

  @doc """
  The originals of `refusal/3` that still have a live translation.
  """
  @spec still_refused(%{originals: [original()]}) :: [original()]
  def still_refused(%{originals: originals}), do: Enum.filter(originals, &(&1.translations != []))

  @doc """
  The originals of `refusal/3` read with no live translation left, which can be deleted now.
  """
  @spec cleared(refusal()) :: [original()]
  def cleared(%{originals: originals}),
    do: Enum.filter(originals, &(&1.kind != nil and &1.translations == []))

  defp unread(%{id: id, message: message}) do
    %{
      id: id,
      site_id: nil,
      title: nil,
      kind: nil,
      message: message,
      translations: [],
      allowed?: false
    }
  end

  defp scope(resource, actor) do
    master? = Helper.master_user?(actor)
    tenant = if master?, do: nil, else: actor.site_id

    %{
      resource: resource,
      actor: actor,
      master?: master?,
      opts: [actor: actor, tenant: tenant, authorize?: true]
    }
  end

  defp read_original(%{id: id} = refused, scope) do
    with {:ok, original} <- get_original(id, scope),
         {:ok, translations} <- live_translations(original, scope) do
      kind = if is_nil(original.archived_at), do: :archive, else: :destroy
      languages = Enum.map(translations, & &1.language)

      %{
        id: id,
        site_id: original.site_id,
        title: title(original),
        kind: kind,
        message: refusal_message(original, languages),
        translations: translations,
        allowed?: Enum.all?(translations, &may_take?(&1, destroy_action(kind, scope), scope))
      }
    else
      _unreadable -> unread(refused)
    end
  end

  defp refusal_message(_original, []),
    do:
      dgettext("mishka_gervaz", "Its translations are no longer live, so it can be deleted now.")

  defp refusal_message(original, languages),
    do: PreventMasterLanguageDeletion.message(original.language, languages)

  # THE ORIGINAL IS LIVE FOR AN ARCHIVE AND ARCHIVED FOR A DELETE FOR GOOD, and the table reads each
  # through its own action.
  defp get_original(id, %{resource: resource, master?: master?, opts: opts}) do
    [
      TableInfo.action_for(resource, :get, master?),
      TableInfo.archive_action_for(resource, :get, master?)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.find_value({:error, :not_found}, fn action ->
      case Ash.get(resource, id, Keyword.put(opts, :action, action)) do
        {:ok, original} -> {:ok, original}
        _not_here -> nil
      end
    end)
  end

  # ONLY THE ORIGINAL'S OWN GROUP ON THE ORIGINAL'S OWN SITE, never the original, never an archived
  # edition.
  defp live_translations(%{id: id, site_id: site_id}, %{resource: resource} = scope) do
    action = TableInfo.action_for(resource, :read, scope.master?)

    resource
    |> Ash.Query.for_read(action, %{}, scope.opts)
    |> Ash.Query.filter(language_group_id == ^id and id != ^id and is_nil(archived_at))
    |> on_site(site_id)
    |> read_all(scope.opts, Ash.Resource.Info.action(resource, action).pagination)
  end

  defp on_site(query, nil), do: Ash.Query.filter(query, is_nil(site_id))
  defp on_site(query, site_id), do: Ash.Query.filter(query, site_id == ^site_id)

  # A TABLE'S READ MAY REQUIRE A PAGE, which `page: false` is refused on.
  defp read_all(query, opts, %{required?: true} = pagination),
    do: read_pages(query, opts, min(pagination.max_page_size || 100, 100), 0, [])

  defp read_all(query, opts, _optional_or_none),
    do: Ash.read(query, Keyword.put(opts, :page, false))

  defp read_pages(query, opts, limit, offset, read) do
    case Ash.read(query, Keyword.put(opts, :page, limit: limit, offset: offset)) do
      {:ok, %{results: results, more?: true}} ->
        read_pages(query, opts, limit, offset + limit, read ++ results)

      {:ok, %{results: results}} ->
        {:ok, read ++ results}

      {:error, _reason} = error ->
        error
    end
  end

  defp destroy_action(:archive, %{resource: resource, master?: master?}),
    do: TableInfo.action_for(resource, :destroy, master?)

  defp destroy_action(:destroy, %{resource: resource, master?: master?}),
    do: TableInfo.archive_action_for(resource, :destroy, master?) || :permanent_destroy

  defp may_take?(translation, action, %{actor: actor, opts: opts}) do
    case Ash.can({translation, action}, actor,
           tenant: opts[:tenant],
           validate?: true,
           maybe_is: false
         ) do
      {:ok, true} -> true
      {:ok, true, _authorized} -> true
      {:ok, true, _changeset, _query} -> true
      _refused -> false
    end
  end

  defp title(record) do
    Enum.find_value([:title, :name], fn field ->
      case Map.get(record, field) do
        text when is_binary(text) and text != "" -> text
        _none -> nil
      end
    end)
  end

  @doc """
  Archives — or, for a `:destroy` refusal, deletes for good — the translations `refusal/3` showed, as
  `actor`, with the action the resource's admin table deletes with. Only the ones still live in the
  original's group on its site are touched, and never one the alert did not name.

  Each original whose translations it took fires `runtime:state:language_group:changed` with
  `%{op, key, resource, site_id, translations, languages, actor_id}`: `op` is
  `:translations_archived` or `:translations_deleted`, `key` the original's id, and `translations`
  the ids taken.
  """
  @spec take_translations(refusal(), map()) :: :ok | {:error, String.t()}
  def take_translations(%{allowed?: true, kind: kind} = refusal, actor) when not is_nil(actor) do
    scope = scope(refusal.resource, actor)
    action = destroy_action(kind, scope)

    refusal.originals
    |> Enum.map(&{&1, still_live(&1, scope)})
    |> Enum.reduce_while(:ok, fn {original, translations}, :ok ->
      case take(original, translations, kind, action, scope) do
        :ok ->
          announce_taken(refusal.resource, original, translations, kind, actor)
          {:cont, :ok}

        {:error, _message} = error ->
          {:halt, error}
      end
    end)
  end

  def take_translations(_refusal, _actor),
    do: {:error, dgettext("mishka_gervaz", "You can't archive or delete these translations.")}

  defp still_live(original, scope) do
    named = MapSet.new(original.translations, & &1.id)

    case live_translations(original, scope) do
      {:ok, live} -> Enum.filter(live, &(&1.id in named))
      {:error, _unreadable} -> []
    end
  end

  defp take(original, translations, kind, action, scope) do
    Enum.reduce_while(translations, :ok, fn translation, :ok ->
      case Ash.destroy(translation, [action: action, return_destroyed?: true] ++ scope.opts) do
        {:ok, _taken} -> {:cont, :ok}
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, not_taken(original, translation, kind, error)}}
      end
    end)
  end

  defp announce_taken(_resource, _original, [], _kind, _actor), do: :ok

  defp announce_taken(resource, original, translations, kind, actor) do
    MishkaInstaller.Event.Hook.call(
      "runtime:state:language_group:changed",
      %{
        op: if(kind == :destroy, do: :translations_deleted, else: :translations_archived),
        key: original.id,
        resource: resource,
        site_id: original.site_id,
        translations: Enum.map(translations, & &1.id),
        languages: Enum.map(translations, & &1.language),
        actor_id: Map.get(actor, :id)
      },
      return: false
    )
  end

  defp not_taken(original, %resource{} = translation, kind, error) do
    bindings = [
      language: Languages.name(translation.language),
      title: original.title,
      reasons: error |> errors() |> Enum.map_join(" ", &reason(&1, resource))
    ]

    if kind == :destroy do
      dgettext(
        "mishka_gervaz",
        "The %{language} translation of “%{title}” could not be deleted for good: %{reasons}",
        bindings
      )
    else
      dgettext(
        "mishka_gervaz",
        "The %{language} translation of “%{title}” could not be archived: %{reasons}",
        bindings
      )
    end
  end

  defp reason(%{message: message} = error, resource) when is_binary(message),
    do: MishkaGervaz.Errors.extract_error_message(error, resource)

  defp reason(error, _resource) when is_exception(error), do: Exception.message(error)
  defp reason(_error, _resource), do: dgettext("mishka_gervaz", "something went wrong.")
end
