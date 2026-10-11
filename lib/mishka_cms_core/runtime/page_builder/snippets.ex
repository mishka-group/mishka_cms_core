defmodule MishkaCmsCore.Runtime.PageBuilder.Snippets do
  @moduledoc """
  The Studio's snippet list, over `MishkaCmsCore.Runtime.Snippet`.

  What the panel needs beyond the stored row — how many blocks a snippet holds, how big it is, what
  colour its swatch is — is DERIVED from the markup here rather than stored beside it, so a snippet
  can never claim three blocks while holding one.

  Saving takes a serialised subtree. `MishkaCmsCore.Runtime.PageBuilder.EditorSession` already knows
  how to cut one out (`Tree.subtree/2` + `Serializer.to_heex/1`) for the clipboard; a snippet is that
  same string kept past the session.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Localized
  alias MishkaCmsCore.Runtime.PageBuilder.Section
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.Snippet

  # The prototype's own palette, kept because the point of the swatch is to tell two rows apart at a
  # glance and a per-name hash does that without anyone choosing a colour.
  @tints ~w(#eef1fd #f3eefd #eefaf4 #fdf4ee #fdeef4 #eef8fd)

  @sections [:page, :layout, :error_page, :component]

  @doc """
  The snippets one editor should offer: this site's plus the global ones, for this section, filtered
  by the Studio's chip. Read as `opts[:actor]`, who sees only the sections whose builder they may
  open.

  `filter` is `"all"`, `"page"` or `"global"` — the chips as they are written in the panel.
  """
  @spec list(map()) :: [map()]
  def list(opts) do
    section = section(opts[:section])
    document_id = uuid(opts[:document_id])

    Snippet
    |> Ash.Query.for_read(
      :for_editor,
      %{site_id: uuid(opts[:site_id]), section: section, document_id: document_id},
      actor: opts[:actor]
    )
    |> Ash.read(page: [limit: 200])
    |> case do
      {:ok, %{results: rows}} -> rows
      {:ok, rows} when is_list(rows) -> rows
      {:error, _reason} -> []
    end
    |> Enum.filter(&keep?(&1, opts[:filter]))
    |> Enum.map(&describe/1)
  end

  @doc """
  Saves `source` under `name`, as `opts[:actor]`.

  Refuses markup that does not parse: a snippet that cannot be inserted is worse than no snippet,
  because the failure surfaces later and somewhere else. A master names the site (`nil` offers it to
  every site); a site user saves into their own site.
  """
  @spec save(map()) :: {:ok, map()} | {:error, term()}
  def save(opts) do
    with {:ok, actor} <- someone(opts[:actor]),
         {:ok, name} <- named(opts[:name]),
         {:ok, source} <- parseable(opts[:source]) do
      %{
        name: name,
        source: source,
        section: section(opts[:section]),
        scope: scope(opts[:scope]),
        document_id: uuid(opts[:document_id]),
        site_id: uuid(opts[:site_id])
      }
      |> create(actor)
      |> case do
        {:ok, snippet} -> {:ok, describe(snippet)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Deletes one snippet by id, as `actor`.

  A site user may delete only its own site's snippets: not a global one, and not another site's.
  The id alone is not authority, because it travels in a `phx-value-id` that anyone can type — a
  snippet the actor cannot read is `{:error, :not_found}`, whether it is gone or someone else's.
  """
  @spec delete(String.t(), map() | nil) :: :ok | {:error, term()}
  def delete(id, actor) do
    case readable(id, actor) do
      {:ok, snippet} -> destroy_if_allowed(snippet, actor)
      :none -> {:error, :not_found}
    end
  end

  @doc """
  One snippet's markup, or `nil` — what the insert path needs and nothing more.

  Read as `actor`: a site user inserts its own site's snippets and the global ones, which is what
  `list/1` offers it. Another site's stays invisible.
  """
  @spec source(String.t(), map() | nil) :: String.t() | nil
  def source(id, actor) do
    case readable(id, actor) do
      {:ok, snippet} -> snippet.source
      :none -> nil
    end
  end

  @doc "The editor sections a snippet can belong to."
  @spec sections() :: [atom()]
  def sections, do: @sections

  @doc """
  One stored snippet as the panel draws it.

  Public because the Studio's list is a Gervaz table now: the table hands its template Ash records,
  and every value the row shows beyond `name` is read off `source` rather than stored beside it. One
  derivation site, whether the caller came through `list/1` or through the table.
  """
  @spec row(struct()) :: map()
  def row(snippet), do: describe(snippet)

  defp someone(nil), do: {:error, :forbidden}
  defp someone(actor), do: {:ok, actor}

  defp readable(_id, nil), do: :none

  defp readable(id, actor) do
    case Ash.get(Snippet, id, action: :get_any, actor: actor) do
      {:ok, snippet} -> {:ok, snippet}
      {:error, _reason} -> :none
    end
  end

  # A MASTER NAMES THE SITE, A TENANT IS ONE — the split every `global? true` resource makes.
  defp create(attrs, %{site_id: nil} = actor) do
    Snippet
    |> Ash.Changeset.for_create(:master_create, attrs, actor: actor)
    |> Ash.create()
  end

  defp create(attrs, %{site_id: site_id} = actor) do
    Snippet
    |> Ash.Changeset.for_create(:create, Map.delete(attrs, :site_id),
      actor: actor,
      tenant: site_id
    )
    |> Ash.create()
  end

  # A master deletes anything it can read. A site user deletes only its own site's, and a global
  # snippet gets its own refusal: it belongs to EVERY site rather than to another one.
  defp destroy_if_allowed(snippet, %{site_id: nil} = actor),
    do: snippet |> Ash.Changeset.for_destroy(:master_destroy, %{}, actor: actor) |> destroyed()

  defp destroy_if_allowed(%{site_id: nil}, _actor), do: {:error, :shared_with_every_site}

  defp destroy_if_allowed(%{site_id: site_id} = snippet, %{site_id: site_id} = actor),
    do:
      snippet
      |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor, tenant: site_id)
      |> destroyed()

  defp destroy_if_allowed(_snippet, _actor), do: {:error, :forbidden}

  defp destroyed(changeset) do
    case Ash.destroy(changeset) do
      :ok -> :ok
      {:ok, _record} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The panel's row: what it stores, plus what it can only know by reading the markup.
  defp describe(snippet) do
    %{
      id: snippet.id,
      name: snippet.name,
      source: snippet.source,
      scope: scope_label(snippet),
      scope_type: scope_type(snippet),
      section: snippet.section,
      blocks: blocks(snippet.source),
      size: size(snippet.source),
      tint: tint(snippet.name),
      when: ago(snippet.inserted_at)
    }
  end

  defp keep?(_snippet, filter) when filter in [nil, "", "all"], do: true
  defp keep?(snippet, "page"), do: snippet.scope == :page
  defp keep?(snippet, "global"), do: snippet.scope == :shared
  defp keep?(_snippet, _filter), do: true

  defp scope_label(%{site_id: nil}), do: gettext("All sites")
  defp scope_label(%{scope: :page}), do: gettext("This page")
  defp scope_label(_snippet), do: gettext("Shared")

  defp scope_type(%{site_id: nil}), do: "global"
  defp scope_type(%{scope: :page}), do: "page"
  defp scope_type(_snippet), do: "site"

  # Relative rather than a timestamp: what a snippet list is read for is "the one I saved just now",
  # and nobody looks up a snippet by the minute they saved it.
  defp ago(nil), do: gettext("just now")

  defp ago(at) do
    if DateTime.diff(DateTime.utc_now(), at) < 2_592_000,
      do: Localized.ago(at, format: :narrow),
      else: Localized.date(at, :yMMMd)
  end

  # Top-level nodes, which is what "3 blocks" means to someone looking at the canvas — not every
  # descendant, and not the text inside them.
  defp blocks(source) do
    case Tree.parse(source) do
      {:ok, tree} -> length(tree.roots)
      _other -> 0
    end
  end

  defp size(source) do
    bytes = byte_size(source)

    cond do
      bytes < 1024 -> "#{bytes} B"
      bytes < 1024 * 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{Float.round(bytes / 1024 / 1024, 1)} MB"
    end
  end

  defp tint(name) do
    Enum.at(@tints, :erlang.phash2(name, length(@tints)))
  end

  defp named(name) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, :name_required}
      trimmed -> {:ok, String.slice(trimmed, 0, 120)}
    end
  end

  defp named(_name), do: {:error, :name_required}

  defp parseable(source) when is_binary(source) do
    trimmed = String.trim(source)

    case trimmed != "" and Tree.parse(trimmed) do
      {:ok, %Tree{roots: [_first | _rest]}} -> {:ok, trimmed}
      {:ok, %Tree{}} -> {:error, :nothing_to_save}
      false -> {:error, :nothing_to_save}
      _other -> {:error, :unparseable}
    end
  end

  defp parseable(_source), do: {:error, :nothing_to_save}

  defp section(section) when section in @sections, do: section

  defp section(section) when is_binary(section) do
    case Section.to_atom(section) do
      {:ok, atom} -> atom
      :error -> :page
    end
  end

  defp section(_section), do: :page

  defp scope(:page), do: :page
  defp scope("page"), do: :page
  defp scope(_scope), do: :shared

  defp uuid(value) when is_binary(value) and value != "", do: value
  defp uuid(_value), do: nil
end
