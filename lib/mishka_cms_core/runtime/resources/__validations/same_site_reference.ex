defmodule MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference do
  @moduledoc """
  Refuses a record that names, by id, a record of another site.

  The record named must belong to the site the record being written is stored with — on a create
  given a tenant, the tenant, unless the action bypasses multitenancy; otherwise its `site_id`; for
  a record with no site of its own (a join row), the site of the parent named in `:own` — or, with
  `shared?: true`, to no site. A record that belongs to no site names only shared records. A record
  of another site and a record that does not exist are refused with the same message, so the answer
  does not tell a caller which ids exist elsewhere. A record the site could name but that is
  archived is refused with "That <label> is archived. Restore it first."

  Checked whoever writes, the system included: the rule is about the two records, not the actor.
  Nothing is checked when the id is absent or unchanged.

  Each refusal is written in the Gettext locale of the process the action runs in, `errors` domain,
  with the `:label` translated in the same domain; a request with no locale reads it in English.

  A user is named the same way: an account of the record's site, or with `shared?: true` a master
  (a user with no site). Read users with `read_action: :related`, which reaches every account.

  `shared?: :master` also asks who writes: a record with no site is named only by a master
  (`MishkaCmsCore.Accounts.Helper.master_user?/1`) or by the system, a call with no actor made with
  `authorize?: false`. A site's user, whatever it holds and with `authorize?: false` too, gets the
  refusal a record of another site gets. Declare it with `before_action?: true`, so the one asked is
  the actor the action runs as.

  `MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation` holds a write to the caller's
  tenant and refuses shared records; this holds one record to another.

  ## The record named

  With `moves: true` and a `:label`, it guards the other end of the same links: an update may
  change the record's `site_id` only while every record naming it could still name it there. The
  records naming it are found through every `SameSiteReference` on the resources of the host's Ash
  domains, archived rows included, and through the versions that name an account as the one who
  wrote them. A record with no site of its own, or kept outside Postgres, is taken to be on another
  site. Refused with "Records outside that site still use this <label>, so it cannot move there.",
  or for a move to no site "Records that cannot use a shared <label> still use this one, so it
  cannot become shared."

  ## Options

    * `:field` — required. The attribute holding the id.
    * `:resource` — required. The resource the id names. It has a `site_id`. For an id that names
      one of several resources, `{kind_field, %{kind => resource}}`: the record's `kind_field` picks
      the resource, and a kind the map does not hold is refused. The id is then checked again when
      only the kind changes.
    * `:label` — required. What the named record is called in the message, such as `"layout"`.
    * `:shared?` — whether a record with no site may be named: `true`, `false`, or `:master` for
      only when a master or the system writes. Defaults to `false`.
    * `:read_action` — the read that reaches every site's rows. Defaults to `:read_any`. With a kind
      map, every resource in it has this read.
    * `:own` — for a record with no `site_id`: `{field, resource}` or `{field, resource, read_action}`
      naming the parent whose site the record has. Its read action defaults to `:read_any`.

  ## Usage

      validate {SameSiteReference,
                field: :layout_id, resource: MishkaCmsCore.Runtime.Layout, label: "layout",
                shared?: true}

      validate {SameSiteReference,
                field: :tag_id, resource: MyApp.Tag, label: "tag", own: {:post_id, MyApp.Post}}

      validate {SameSiteReference,
                field: :document_id,
                resource: {:section, %{page: MishkaCmsCore.Runtime.Page,
                                       layout: MishkaCmsCore.Runtime.Layout}},
                label: "document", shared?: true}

      validate {SameSiteReference,
                field: :author_id, resource: MishkaCmsCore.Accounts.User, label: "author",
                shared?: true, read_action: :related}

      validate {SameSiteReference,
                field: :user_id, resource: MishkaCmsCore.Accounts.User, label: "user",
                shared?: :master, read_action: :related},
               before_action?: true

      validate {SameSiteReference, moves: true, label: "layout"}
  """
  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ecto.Query

  alias MishkaCmsCore.Accounts.Helper

  @impl true
  def init(opts) do
    if Keyword.get(opts, :moves, false), do: init_moves(opts), else: init_link(opts)
  end

  defp init_moves(opts) do
    case Keyword.fetch(opts, :label) do
      {:ok, label} when is_binary(label) -> {:ok, [moves: true, label: label]}
      _missing -> {:error, "SameSiteReference with moves: true takes :label"}
    end
  end

  defp init_link(opts) do
    with {:ok, field} when is_atom(field) <- Keyword.fetch(opts, :field),
         {:ok, resource} <- resource(Keyword.fetch(opts, :resource)),
         {:ok, label} when is_binary(label) <- Keyword.fetch(opts, :label),
         shared? when shared? in [true, false, :master] <- Keyword.get(opts, :shared?, false) do
      {:ok,
       [
         field: field,
         resource: resource,
         label: label,
         shared?: shared?,
         read_action: Keyword.get(opts, :read_action, :read_any),
         own: own(Keyword.get(opts, :own))
       ]}
    else
      _missing ->
        {:error,
         "SameSiteReference takes :field, :resource and :label, and :shared? as true, false or :master"}
    end
  end

  defp resource({:ok, resource}) when is_atom(resource) and not is_nil(resource),
    do: {:ok, resource}

  defp resource({:ok, {kind, resources}}) when is_atom(kind) and is_map(resources),
    do: {:ok, {kind, resources}}

  defp resource(_missing), do: :error

  defp own(nil), do: nil
  defp own({field, resource}), do: {field, resource, :read_any}
  defp own({_field, _resource, _read_action} = own), do: own

  @impl true
  def validate(changeset, opts, context) do
    if opts[:moves],
      do: validate_move(changeset, opts, context),
      else: validate_link(changeset, Keyword.update!(opts, :shared?, &shared?(&1, context)))
  end

  defp shared?(:master, %{actor: nil, authorize?: false}), do: true
  defp shared?(:master, %{actor: actor}), do: Helper.master_user?(actor)
  defp shared?(shared?, _context), do: shared? == true

  defp validate_link(changeset, opts) do
    field = opts[:field]

    case {changing?(changeset, field, opts[:resource]),
          Ash.Changeset.get_attribute(changeset, field)} do
      {true, id} when not is_nil(id) ->
        site_id = own_site(changeset, opts[:own])
        target = target(changeset, opts[:resource])

        cond do
          reachable?(site_id, target, id, opts) ->
            :ok

          archived_here?(site_id, target, id, opts) ->
            refuse(
              opts,
              dgettext("errors", "That %{label} is archived. Restore it first.",
                label: noun(opts)
              )
            )

          true ->
            refuse(
              opts,
              dgettext("errors", "That %{label} is not one this site can use.", label: noun(opts))
            )
        end

      _absent_or_unchanged ->
        :ok
    end
  end

  defp changing?(changeset, field, {kind, _resources}),
    do:
      Ash.Changeset.changing_attribute?(changeset, field) or
        Ash.Changeset.changing_attribute?(changeset, kind)

  defp changing?(changeset, field, _resource),
    do: Ash.Changeset.changing_attribute?(changeset, field)

  defp target(changeset, {kind, resources}),
    do: Map.fetch(resources, Ash.Changeset.get_attribute(changeset, kind))

  defp target(_changeset, resource), do: {:ok, resource}

  defp own_site(changeset, nil) do
    if tenant_stamps_site?(changeset),
      do: tenant_site(changeset),
      else: Ash.Changeset.get_attribute(changeset, :site_id)
  end

  defp own_site(changeset, {field, resource, read_action}) do
    with id when not is_nil(id) <- Ash.Changeset.get_attribute(changeset, field),
         {:ok, %{site_id: site_id}} <-
           Ash.get(resource, id, action: read_action, authorize?: false) do
      site_id
    else
      _no_parent -> nil
    end
  end

  defp tenant_stamps_site?(
         %{action_type: :create, tenant: tenant, action: %{} = action} = changeset
       )
       when not is_nil(tenant) do
    Map.get(action, :multitenancy) not in [:bypass, :bypass_all] and
      Ash.Resource.Info.multitenancy_strategy(changeset.resource) == :attribute and
      Ash.Resource.Info.multitenancy_attribute(changeset.resource) == :site_id
  end

  defp tenant_stamps_site?(_changeset), do: false

  defp tenant_site(changeset) do
    {module, function, args} = Ash.Resource.Info.multitenancy_parse_attribute(changeset.resource)
    apply(module, function, [changeset.to_tenant | args])
  end

  defp reachable?(site_id, {:ok, resource}, id, opts) do
    case Ash.get(resource, id, action: opts[:read_action], authorize?: false) do
      {:ok, %{site_id: nil}} -> opts[:shared?]
      {:ok, %{site_id: ^site_id}} -> true
      _elsewhere_or_missing -> false
    end
  end

  defp reachable?(_site_id, :error, _id, _opts), do: false

  defp archived_here?(site_id, {:ok, resource}, id, opts) do
    case archived_site(resource, id) do
      {:archived, nil} -> opts[:shared?]
      {:archived, ^site_id} -> true
      _live_elsewhere_or_missing -> false
    end
  end

  defp archived_here?(_site_id, :error, _id, _opts), do: false

  # The reads leave archived rows out, so the row is looked up in its table.
  defp archived_site(resource, id) do
    with true <- AshArchival.Resource in Spark.extensions(resource),
         AshPostgres.DataLayer <- Ash.DataLayer.data_layer(resource),
         {:ok, key} <- Ecto.UUID.dump(id) do
      archived = column(resource, AshArchival.Resource.Info.archive_attribute!(resource))
      primary = column(resource, :id)
      site = column(resource, :site_id)

      resource
      |> rows()
      |> Ecto.Query.where([row], field(row, ^primary) == ^key)
      |> Ecto.Query.where([row], not is_nil(field(row, ^archived)))
      |> Ecto.Query.select([row], {field(row, ^site)})
      |> AshPostgres.DataLayer.Info.repo(resource, :read).one()
      |> archived_answer()
    else
      _not_archivable -> :none
    end
  end

  defp archived_answer({nil}), do: {:archived, nil}
  defp archived_answer({site}), do: {:archived, Ecto.UUID.cast!(site)}
  defp archived_answer(nil), do: :none

  defp rows(resource) do
    query = Ecto.Query.from(row in AshPostgres.DataLayer.Info.table(resource))

    case AshPostgres.DataLayer.Info.schema(resource) do
      nil -> query
      schema -> Ecto.Query.put_query_prefix(query, schema)
    end
  end

  defp column(resource, attribute), do: Ash.Resource.Info.attribute(resource, attribute).source

  defp refuse(opts, message), do: {:error, field: opts[:field], message: message}

  defp noun(opts), do: Gettext.dgettext(MishkaCmsCore.Gettext, "errors", opts[:label])

  defp validate_move(%{action_type: :update, data: record} = changeset, opts, context) do
    site_id = Ash.Changeset.get_attribute(changeset, :site_id)

    if Ash.Changeset.changing_attribute?(changeset, :site_id) and
         Enum.any?(links_into(changeset.resource, context), &still_named?(&1, record, site_id)),
       do: refuse_move(opts, site_id),
       else: :ok
  end

  defp validate_move(_changeset, _opts, _context), do: :ok

  defp refuse_move(opts, nil) do
    {:error,
     field: :site_id,
     message:
       dgettext(
         "errors",
         "Records that cannot use a shared %{label} still use this one, so it cannot become shared.",
         label: noun(opts)
       )}
  end

  defp refuse_move(opts, _site_id) do
    {:error,
     field: :site_id,
     message:
       dgettext(
         "errors",
         "Records outside that site still use this %{label}, so it cannot move there.",
         label: noun(opts)
       )}
  end

  defp links_into(target, context) do
    MishkaCmsCore.Activity.Discovery.resources()
    |> Enum.flat_map(&(declared_links(&1, target, context) ++ writer_links(&1, target)))
    |> Enum.uniq()
  end

  defp declared_links(resource, target, context) do
    for %Ash.Resource.Validation{validation: {__MODULE__, raw}} <- validations(resource),
        not Keyword.get(raw, :moves, false),
        {:ok, opts} <- [init(raw)],
        names?(opts[:resource], target),
        do: %{resource: resource, field: opts[:field], shared?: shared?(opts[:shared?], context)}
  end

  defp validations(resource) do
    Ash.Resource.Info.validations(resource) ++
      Enum.flat_map(Ash.Resource.Info.actions(resource), &Map.get(&1, :changes, []))
  end

  defp names?(target, target), do: true
  defp names?({_kind, resources}, target), do: target in Map.values(resources)
  defp names?(_other, _target), do: false

  # A version names the account that wrote it: one of the record's site, or a master.
  defp writer_links(resource, target) do
    if AshPaperTrail.Resource in Spark.extensions(resource) do
      version = AshPaperTrail.Resource.Info.version_resource(resource)

      for %{name: name, destination: ^target} <-
            AshPaperTrail.Resource.Info.belongs_to_actor(resource),
          do: %{
            resource: version,
            field: Ash.Resource.Info.relationship(version, name).source_attribute,
            shared?: true
          }
    else
      []
    end
  end

  defp still_named?(%{shared?: true}, _record, nil), do: false

  # Ids are unique across tables, so the rows naming the id are the rows naming the record.
  defp still_named?(%{resource: resource, field: field}, record, site_id) do
    with AshPostgres.DataLayer <- Ash.DataLayer.data_layer(resource),
         {:ok, key} <- Ecto.UUID.dump(record.id) do
      resource
      |> rows()
      |> Ecto.Query.where([row], field(row, ^column(resource, field)) == ^key)
      |> not_itself(resource, key, record)
      |> off_site(resource, site_id)
      |> AshPostgres.DataLayer.Info.repo(resource, :read).exists?()
    else
      _cannot_tell -> true
    end
  end

  defp not_itself(query, resource, key, %resource{}),
    do: Ecto.Query.where(query, [row], field(row, ^column(resource, :id)) != ^key)

  defp not_itself(query, _resource, _key, _record), do: query

  defp off_site(query, _resource, nil), do: query

  defp off_site(query, resource, site_id) do
    case Ash.Resource.Info.attribute(resource, :site_id) do
      %{source: site} ->
        stored = Ecto.UUID.dump!(site_id)
        Ecto.Query.where(query, [row], is_nil(field(row, ^site)) or field(row, ^site) != ^stored)

      nil ->
        query
    end
  end

  @impl true
  def has_validate?, do: true

  @impl true
  def supports(_opts), do: [Ash.Changeset]
end
