# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.Drafts do
  @moduledoc """
  The editor's autosave: the working document written to a **draft** row, not the live one.

  ## Why drafts and not the live record

  Every write to a live runtime resource enqueues a compile job through `SendToOban`. An editor that
  saved to the live row as you worked would therefore recompile the site on every change and publish
  half-finished work to visitors. The draft resources exist precisely for this — they deliberately
  carry no `SendToOban`, so writing one is cheap and invisible until someone publishes it.

  A row belongs to the session that made it, and a session is one sitting, so the count grows with
  use. `prune/3` caps it per document — `keep/0` is the number — dropping the oldest as a new one is
  made.

  That also makes the draft the shareable preview: `/_preview/:resource/:token` already serves a
  draft by its `preview_token`, so "open in a new tab" needs no new route and no new auth story.

  Component drafts do not exist as a resource, so a component's autosave is a no-op and its Save
  button is the only persistence — reported honestly rather than silently doing nothing.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.DraftPreviewAssets
  alias MishkaCmsCore.Runtime.Authoring.Section
  alias MishkaCmsCore.Runtime.ErrorPageDraft
  alias MishkaCmsCore.Runtime.LayoutDraft
  alias MishkaCmsCore.Runtime.PageDraft

  @drafts %{
    "page" => {PageDraft, :source_page_id, "page"},
    "layout" => {LayoutDraft, :source_layout_id, "layout"},
    "error-page" => {ErrorPageDraft, :source_error_page_id, "error_page"}
  }

  # The label the automatic save writes under. It is a NAME like any other, which is what lets one
  # rule cover both: a save with no name of its own falls back to it, and every draft someone names
  # deliberately is a different row. The editor names every session, so this is only a fallback.
  @autosave_label gettext_noop("Autosave")

  # A DRAFT CARRIES ITS SOURCE'S CODE AND THE MARKUP THE BUILDER GENERATED, neither typed here, so
  # the deployment's code switch does not stop it. See
  # `MishkaCmsCore.Runtime.Resources.Validations.CodeChange`.
  @fork %{page_code: :fork}

  # HOW MANY SITTINGS A DOCUMENT KEEPS. Every editing session that changes anything now starts a row
  # of its own, so a page someone works on daily would carry a year of them — a picker nobody can
  # read and a table that only grows. Twenty is far past the point where anyone scrolls back, and
  # still leaves a fortnight of daily work to return to.
  @keep 20

  # The list actions each draft resource exposes, tenant and master. Same pair the preview modal's
  # draft picker reads, so the editor and the modal show one list rather than two views of it.
  @list_actions %{
    PageDraft => {:drafts_for_page, :master_drafts_for_page, :source_page_id},
    LayoutDraft => {:drafts_for_layout, :master_drafts_for_layout, :source_layout_id},
    ErrorPageDraft =>
      {:drafts_for_error_page, :master_drafts_for_error_page, :source_error_page_id}
  }

  @doc "The label the automatic save owns."
  @spec autosave_label() :: String.t()
  def autosave_label, do: @autosave_label

  @doc "The name to show for a draft: the automatic save's label in the caller's language, any other name as it was typed."
  @spec display_label(String.t() | nil) :: String.t() | nil
  def display_label(label) when label == @autosave_label,
    do: Gettext.gettext(MishkaCmsCore.Gettext, label)

  def display_label(label), do: label

  @doc """
  Every draft of this record, newest first — what the editor's draft picker lists.

  Returns `[]` for a section with no draft resource rather than raising, so a caller does not have to
  ask `supported?/1` first.
  """
  @spec list(String.t(), map() | nil, map()) :: [struct()]
  def list(section, record, actor)

  def list(_section, nil, _actor), do: []

  def list(section, record, actor) do
    with {:ok, {module, _source_key, _segment}} <- Map.fetch(@drafts, section),
         {:ok, {tenant_action, master_action, argument}} <- Map.fetch(@list_actions, module) do
      module
      |> query(tenant_action, master_action, argument, record.id, actor)
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
    else
      :error -> []
    end
  end

  defp query(module, _tenant, master, argument, id, %{site_id: nil} = actor),
    do: read(module, master, argument, id, actor, [])

  defp query(module, tenant, _master, argument, id, %{site_id: site_id} = actor),
    do: read(module, tenant, argument, id, actor, tenant: site_id)

  defp read(module, action, argument, id, actor, opts) do
    module
    |> Ash.Query.for_read(action, %{argument => id}, Keyword.put(opts, :actor, actor))
    |> Ash.read(page: [limit: 50])
    |> case do
      {:ok, %{results: results}} -> results
      {:ok, results} when is_list(results) -> results
      _error -> []
    end
  end

  @doc """
  The draft this record already keeps under `label`, or `nil`.

  What "a draft called X already exists" is asked with, so the editor can offer to update it instead
  of quietly making a second one with the same name.
  """
  @spec named(String.t(), map() | nil, map(), String.t()) :: struct() | nil
  def named(section, record, actor, label) when is_binary(label) do
    trimmed = String.trim(label)

    section
    |> list(record, actor)
    |> Enum.find(&(&1.label == trimmed))
  end

  def named(_section, _record, _actor, _label), do: nil

  @doc """
  Saves the document under a NAME, creating that draft or updating it.

  `draft_id` names the row to update — pass `nil` to create. Autosave has its own entry point,
  `autosave/7`, and its own label, so naming a draft never collides with it.

  `source` is the document a NEW row copies its fields from — the draft being forked or saved under
  another name, and `nil` when the save starts from the live document, which is then the source. It
  is asked for rather than defaulted for the reason `attrs/8` gives: a copy taken from the live
  record hands the author today's published fields back with a success flash. Pass only a document
  the author chose; the row the editor's own autosave made for a sitting is the live document's
  working copy, not another document to copy from.

  `status` says which of an error page's templates is being written, and is `nil` for every section
  that keeps one template — see `autosave/7` for why it is asked for rather than defaulted.
  """
  @spec save_as(
          String.t(),
          map() | nil,
          map() | nil,
          String.t(),
          map(),
          String.t() | nil,
          String.t(),
          integer() | nil
        ) ::
          {:ok, struct()} | :unsupported | {:error, term()}
  def save_as(section, record, source, heex, actor, draft_id, label, status) do
    if supported?(section) do
      section
      |> write(record, source || record, heex, actor, draft_id, String.trim(label), status)
      |> prune_after_create(draft_id, section, record, actor)
    else
      :unsupported
    end
  end

  @doc """
  Deletes a draft — what "Discard" on the resume bar does to the autosave.

  Deleting rather than ignoring is deliberate: a bar that offers to restore work you have already
  said you do not want, every time you open the page, is a bar people learn to dismiss without
  reading.
  """
  @spec discard(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def discard(section, draft_id, actor) do
    with {:ok, {module, _source_key, _segment}} <- Map.fetch(@drafts, section),
         {:ok, draft} <- fetch(module, draft_id, actor) do
      destroy(draft, actor)
    else
      :error -> {:error, :unsupported}
      error -> error
    end
  end

  # The draft's editing history is released as it goes — on the resource's own destroy events, not
  # here, because the picker's own Delete never comes through this module. An editor that keeps
  # history (the visual editor, `mishka_cms_builder`) listens on
  # `cms_core:<section>_draft:after_destroy` and `…:after_master_destroy`; with none installed the
  # draft is only deleted.
  #
  # THE ACTOR GOES ON THE CHANGESET, NOT ONLY ON THE CALL: validations run when the changeset is
  # BUILT, so `Ash.destroy(actor: …)` alone reaches them too late. `TenantContext`'s master branch
  # is the one that asks who is writing, and it saw a nil actor on every one of these.
  defp destroy(draft, %{site_id: nil} = actor),
    do:
      draft
      |> Ash.Changeset.for_destroy(:master_destroy, %{}, actor: actor)
      |> Ash.destroy(actor: actor)

  defp destroy(draft, %{site_id: site_id} = actor),
    do:
      draft
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site_id, actor: actor)
      |> Ash.destroy(actor: actor)

  @doc "Whether this section keeps drafts at all."
  @spec supported?(String.t()) :: boolean()
  def supported?(section), do: Map.has_key?(@drafts, section)

  @doc """
  The Ash resource holding a section's drafts — what the editor points its drafts table at.

  Returns `nil` for a section that keeps none, the same answer `supported?/1` gives.
  """
  @spec resource(String.t()) :: module() | nil
  def resource(section) do
    case Map.fetch(@drafts, section) do
      {:ok, {module, _source_key, _segment}} -> module
      :error -> nil
    end
  end

  @doc """
  The draft attribute pointing back at the live record — `:source_page_id` and its siblings.

  The drafts table scopes itself to one document by this key, so it has to be asked for by section
  rather than assumed.
  """
  @spec source_key(String.t()) :: atom() | nil
  def source_key(section) do
    case Map.fetch(@drafts, section) do
      {:ok, {_module, source_key, _segment}} -> source_key
      :error -> nil
    end
  end

  @doc "The `/_preview/:resource/:token` segment for a section."
  @spec preview_segment(String.t()) :: String.t() | nil
  def preview_segment(section) do
    case Map.fetch(@drafts, section) do
      {:ok, {_module, _key, segment}} -> segment
      :error -> nil
    end
  end

  @doc """
  Writes the current document to this session's draft, creating it on the first call and updating it
  afterwards.

  `label` is the name to keep. `nil` falls back to the autosave's own label, but when the editor has
  a NAMED draft open it passes that name through — otherwise the automatic save would quietly rename
  the author's draft to "Autosave" on the next keystroke.

  It takes no source to copy from, unlike `save_as/8`: a sitting with no row yet is one that started
  from the live document, and from its first write on it is the row itself that is read.

  `status` says which of an error page's templates is being written, and is `nil` for every section
  that keeps one. IT IS ASKED FOR RATHER THAN DEFAULTED because a caller who leaves it off is not
  writing nothing — `Section.save_fields/3` falls back to the 404 and replaces THAT entry, so the
  work lands on a template nobody opened and buries the one that was there. A default made that
  silent, and the one caller that took it up was "Keep it as a draft" on the way out.

  Returns `{:ok, draft}`, `:unsupported` for a section with no draft resource, or `{:error, reason}`.
  """
  @spec autosave(
          String.t(),
          map() | nil,
          String.t(),
          map(),
          String.t() | nil,
          String.t() | nil,
          integer() | nil
        ) ::
          {:ok, struct()} | :unsupported | {:error, term()}
  def autosave(section, record, heex, actor, draft_id, label, status) do
    if supported?(section) do
      section
      |> write(record, record, heex, actor, draft_id, label || @autosave_label, status)
      |> prune_after_create(draft_id, section, record, actor)
    else
      :unsupported
    end
  end

  @doc """
  Drops everything past the newest `#{@keep}` drafts of a record.

  Runs where the count can grow and nowhere else — the moment a row is CREATED — so the realtime
  save, which writes the same row over and over, costs one update and no extra read.

  Newest is by `updated_at`, so a draft someone is working in right now cannot be the one dropped:
  every change moves it back to the front of the list. A session whose row is pruned while it sits
  idle is not broken by it either — its next write finds the id gone and starts a new row, which is
  the same thing that happens when a colleague discards it from the picker.

  A published draft is never touched: `list/3` reads pending drafts only, and a row with an
  `applied_at` is the record of a publish rather than work in progress.
  """
  @spec prune(String.t(), map() | nil, map()) :: :ok
  def prune(section, record, actor) do
    section
    |> list(record, actor)
    |> Enum.drop(@keep)
    |> Enum.each(&destroy(&1, actor))

    :ok
  end

  @doc "How many drafts a document keeps."
  @spec keep() :: pos_integer()
  def keep, do: @keep

  # An update cannot push the count over the cap, so only the create path pays for the read. The
  # fallback create inside `write/7` — the one that fires when the id no longer exists — is left out
  # on purpose: it replaces a row rather than adding one, and the next session prunes anyway.
  defp prune_after_create(result, draft_id, _section, _record, _actor) when is_binary(draft_id),
    do: result

  defp prune_after_create({:ok, _draft} = result, _draft_id, section, record, actor) do
    prune(section, record, actor)
    result
  end

  defp prune_after_create(result, _draft_id, _section, _record, _actor), do: result

  # THE ROW BELONGS TO THE SESSION THAT MADE IT, not to the document. Looking one up by name meant
  # every session that opened without a `draft_id` joined the same row — so a colleague editing the
  # same page wrote over your unsaved work, and yesterday's sitting was overwritten by today's. A
  # session creates its row on the first change and writes to that id for the rest of its life.
  defp write(_section, nil, _source, _heex, _actor, _draft_id, _label, _status),
    do: :unsupported

  defp write(section, record, source, heex, actor, nil, label, status) do
    {module, source_key, _segment} = Map.fetch!(@drafts, section)

    module
    |> create_changeset(
      attrs(module, record, source, heex, source_key, label, section, status),
      record,
      actor
    )
    |> Ash.Changeset.force_change_attribute(:source_hash, source_hash(section, record, source))
    |> Ash.create(actor: actor)
  end

  # Updating an existing draft writes the template AND the label: renaming is the same gesture as
  # saving, so "save this under a different name" does not leave a stale one behind.
  #
  # THE FIELDS COME FROM THE DRAFT, not from the live record: an error page's draft holds a snapshot
  # of every status, and editing the 404 must replace that entry of the DRAFT while keeping the 500
  # the author already changed in it. Reading the live record here would put the published 500 back.
  defp write(section, record, source, heex, actor, draft_id, label, status) do
    {module, _source_key, _segment} = Map.fetch!(@drafts, section)

    case fetch(module, draft_id, actor) do
      {:ok, draft} ->
        update(
          draft,
          Map.put(template_fields(section, draft, heex, status), :label, label),
          actor
        )

      _missing ->
        write(section, record, source, heex, actor, nil, label, status)
    end
  end

  # A copy of a draft is as old as that draft; a copy of the document is as old as now.
  defp source_hash(section, record, %module{} = source) do
    if module == resource(section),
      do: Map.get(source, :source_hash),
      else: hash(section, record)
  end

  @doc """
  A fingerprint of `original`, a section's live document: `:erlang.phash2/1` of every field its draft
  carries. A draft keeps the one it was made from (`source_hash`), so a different one now means the
  original was changed since — see `original_changed?/3`.
  """
  @spec hash(String.t(), map()) :: non_neg_integer()
  def hash(section, original) do
    {module, _source_key, _segment} = Map.fetch!(@drafts, section)
    live = original.__struct__

    fields =
      for field <- Ash.Resource.Info.action(module, :create).accept,
          field != :label,
          Ash.Resource.Info.attribute(live, field),
          do: field

    :erlang.phash2(Map.take(original, fields))
  end

  @doc """
  Whether the document a pending draft was made from has changed since — a notice for its author,
  nothing more. A draft that holds no fingerprint, or was published, answers `false`.
  """
  @spec original_changed?(String.t(), map() | nil, map() | nil) :: boolean()
  def original_changed?(section, %{} = original, %{status: :draft, source_hash: hash})
      when is_integer(hash),
      do: hash(section, original) != hash

  def original_changed?(_section, _original, _draft), do: false

  @doc """
  `original_changed?/3` for a draft on its own: the document it was made from is read by its
  source id, as the system.
  """
  @spec original_changed?(struct()) :: boolean()
  def original_changed?(%module{} = draft) do
    with {section, {_module, source_key, _segment}} <-
           Enum.find(@drafts, fn {_section, {draft_module, _, _}} -> draft_module == module end),
         id when is_binary(id) <- Map.get(draft, source_key),
         {:ok, original} <-
           Ash.get(Section.resource(section), id, action: :read_any, authorize?: false) do
      original_changed?(section, original, draft)
    else
      _no_original -> false
    end
  end

  # A DRAFT CARRIES THE WHOLE OF THE DOCUMENT IT FORKS — every field its `:create` accepts. Its
  # create validates the same required fields the live resource does, so a draft with no `path` is
  # not a saveable page; and publishing a draft writes its fields back over the live record, so a
  # field the draft never took is put back to its default. It took five: publishing one from the
  # inspector's draft picker dropped the page's layout, its SEO tags, its language and its language
  # group.
  #
  # AND IT TAKES THEM FROM THE DOCUMENT BEING COPIED, which is the live record only when the save
  # starts there. Reading the record while forking a DRAFT handed back the five fields above as they
  # stand today instead of as the draft holds them — and for an error page, whose whole `error_pages`
  # list is one such field, it put the published markup back over every status but the one on screen,
  # under a "Copied to …" flash.
  #
  # THE SOURCE IS READ WHOLE, nil included, and the record is never consulted for a field the source
  # holds as nil. A copy that filled its blanks from the page would be something the source is not:
  # a page drafted while it had no layout, then given one, made a "copy" carrying a layout the draft
  # never had — and publishing the two then did different things. The required fields cannot be nil
  # in a source anyway: a draft's own create validates them, so any row that exists carries them.
  defp attrs(module, record, source, heex, source_key, label, section, status) do
    module
    |> Ash.Resource.Info.action(:create)
    |> Map.fetch!(:accept)
    |> Map.new(&{&1, Map.get(source, &1)})
    |> Map.merge(%{label: label, priority: Map.get(source, :priority) || 0})
    |> Map.merge(template_fields(section, source, heex, status))
    |> Map.put(source_key, Map.get(record, :id))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # WHERE THE SECTION KEEPS ITS MARKUP, asked of the one module that knows. Three drafts have a
  # `template` attribute; `ErrorPageDraft` has none — it mirrors its live resource and keeps
  # `error_pages`, a list of `%{status, template, layout}`. Writing `template:` at it was writing a
  # field it does not accept, so every draft of an error page failed and the editor reported a save
  # that never happened.
  #
  # `Section.save_fields/3` is the same function the live save uses, so a draft and a publish put
  # the markup in the same place by construction rather than by two lists agreeing. It defers the
  # value that has to be built out of the row being written, and `record` here is that row — the
  # draft this call has just read, or the live record the first one forks from.
  defp template_fields(section, record, heex, status) do
    section
    |> Section.save_fields(heex, status: status)
    |> Section.apply_fields(record)
    |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
  end

  defp create_changeset(module, attrs, record, %{site_id: nil} = actor) do
    Ash.Changeset.for_create(
      module,
      :master_create,
      Map.put(attrs, :site_id, Map.get(record, :site_id)),
      actor: actor,
      context: @fork
    )
  end

  defp create_changeset(module, attrs, _record, %{site_id: site_id} = actor),
    do:
      Ash.Changeset.for_create(module, :create, attrs,
        tenant: site_id,
        actor: actor,
        context: @fork
      )

  defp update(draft, attrs, %{site_id: nil} = actor),
    do:
      draft
      |> Ash.Changeset.for_update(:master_update, attrs, actor: actor, context: @fork)
      |> Ash.update(actor: actor)
      |> invalidate_preview()

  defp update(draft, attrs, %{site_id: site_id} = actor),
    do:
      draft
      |> Ash.Changeset.for_update(:update, attrs, tenant: site_id, actor: actor, context: @fork)
      |> Ash.update(actor: actor)
      |> invalidate_preview()

  # A DRAFT'S PREVIEW STYLESHEET IS COMPILED ONCE AND KEYED BY THE DRAFT'S TOKEN.
  # `DraftPreviewAssets.ensure_css/2` compiles only when that key is absent, which is what keeps
  # opening a preview cheap — and meant every edit after the first preview was rendered against the
  # stylesheet of the version before it. A utility class typed a moment ago simply had no rule, so
  # the element drew unstyled and looked exactly like a class that does not exist.
  #
  # DROPPED, NOT RECOMPILED. A Tailwind pass on every autosave would pay for a preview nobody may
  # open; `ensure_css/2` already compiles on the way in, so throwing the key away is the whole fix.
  defp invalidate_preview({:ok, draft} = result) do
    DraftPreviewAssets.purge(draft)
    result
  end

  defp invalidate_preview(other), do: other

  defp fetch(module, id, %{site_id: nil} = actor),
    do: Ash.get(module, id, action: :master_get, actor: actor)

  defp fetch(module, id, %{site_id: site_id} = actor),
    do: Ash.get(module, id, actor: actor, tenant: site_id)
end
