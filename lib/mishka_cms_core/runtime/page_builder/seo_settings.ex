defmodule MishkaCmsCore.Runtime.PageBuilder.SeoSettings do
  @moduledoc """
  The SEO a page or a layout stores, as the builder's settings modal edits it: a Gervaz form.

  ## A resource with no table behind it

  An SEO setting is not a row anywhere. It is a `Page`'s `description`, `seo_tags` and `schema`, or
  a `Layout`'s `seo_tags`. Gervaz builds a form from an Ash RESOURCE, so this is one with no data
  layer — `Ash.DataLayer.Simple`, as `MishkaCmsCore.Runtime.PageBuilder.DesignToken` — whose `:read`
  reads the document as the actor and whose `:update` writes it back through the document's own
  action, so every policy and validation stays the document's.

  Its id names the document: `"page:<id>"` or `"layout:<id>"` (`id/2`), and `"page:draft:<id>"` or
  `"layout:draft:<id>"` for a draft of one, which the builder edits while it writes that draft.

  ## The record is the draft

  What the document stores, the add-a-tag row, whether the JSON box is open, and the head the page
  would render (`preview/1`). `change/3` is what one edit writes and `typed/2` what Save reads
  from the fields as drawn; `MishkaCmsCoreWeb.Templates.SeoForm` draws the draft and keeps the
  edited one on the form's component until Save sends `params/1`.

  ## What a page sets

    * `title` — a stored `title` tag; empty, the record's title on a page that serves records, else
      the page's own `title`;
    * `description` — the page's own `description`;
    * share image, canonical address, "hide from search engines" — stored `og:image`, `canonical`
      and `robots` tags;
    * structured data — one object of a type `MishkaCmsCore.Runtime.Seo.schema_types/0` offers,
      written in place among the page's others, or the whole of it as JSON.

  Every one of them may name a variable, `{{post.title}}`; a plugin on
  `MishkaCmsCore.Runtime.Seo.event/0` fills what the page leaves empty. A layout stores tags only.

  ## What the page shows

  A page that serves one record per address names the kind in its `extra`, `"record" => "blog:post"`
  — one of `MishkaCmsCore.Runtime.Seo.record_types/1`, which the installed extensions answer — and
  the plugin that owns the kind fills its SEO, whatever its path. The page's General tab picks it
  (`MishkaCmsCore.Runtime.Resources.Changes.SetRecordKind`); this reads it, for the variables and
  for a preview drawn with one of the kind's samples instead of placeholders, and Save leaves it as
  it is.
  """

  use Ash.Resource,
    otp_app: :mishka_cms_core,
    domain: MishkaCmsCore.Runtime,
    extensions: [MishkaGervaz.Resource]

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.{Languages, Layout, PageEditions, Seo}
  alias MishkaCmsCore.Runtime.PageBuilder.{Drafts, Helpers, Section}

  @type t :: struct()

  # The sections that store SEO, and what their form edits.
  @modes %{"page" => :page, "layout" => :tags}

  mishka_gervaz do
    form do
      identity do
        name :seo_settings
        route "/admin/dashboard/runtime/builder"
      end

      # THE DOCUMENT EXISTS BEFORE ITS SEO DOES, so the form only ever edits.
      source do
        actions do
          read :read
          update :update
        end

        access :create, false
      end

      fields do
        field :description, :textarea
        field :tags, :json
        field :schema, :json
      end

      events MishkaCmsCoreWeb.Templates.SeoForm

      presentation do
        template MishkaCmsCoreWeb.Templates.SeoForm
      end
    end
  end

  actions do
    read :read do
      primary? true
      manual fn query, _data_layer_query, context -> __MODULE__.read(query, context) end
    end

    update :update do
      primary? true
      accept [:description, :tags, :schema]
      require_atomic? false
      manual fn changeset, context -> __MODULE__.save(changeset, context) end
    end
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :description, :string, public?: true
    attribute :tags, {:array, :map}, public?: true, default: []
    attribute :schema, {:array, :map}, public?: true, default: []

    # The draft's own state, never written anywhere.
    attribute :mode, :atom, public?: true, constraints: [one_of: [:page, :tags]]
    attribute :document, :term, public?: true
    attribute :type, :string, public?: true
    attribute :fields, :term, public?: true
    attribute :json, :string, public?: true
    attribute :json_error, :string, public?: true
    attribute :adding, :term, public?: true
    attribute :advanced, :boolean, public?: true, default: false
    attribute :layout_tags, :term, public?: true
    attribute :head, :term, public?: true
    attribute :base, :string, public?: true
    attribute :restricted, :boolean, public?: true, default: false
    attribute :vars, :term, public?: true
    attribute :record_driven, :boolean, public?: true, default: false
    attribute :record, :string, public?: true
    attribute :record_types, :term, public?: true
    attribute :sample, :term, public?: true
    attribute :view, :string, public?: true
    attribute :image_manual, :boolean, public?: true, default: false
    attribute :stars, :term, public?: true
  end

  @doc """
  Which form a section's SEO is: `:page` where its resource stores `schema` and `seo_tags`, `:tags`
  where it stores `seo_tags` alone (a layout), `nil` where it stores neither.
  """
  @spec mode(String.t()) :: :page | :tags | nil
  def mode(section), do: Map.get(@modes, section)

  @doc "The id of a document's SEO: `\"page:<id>\"`, or `\"page:draft:<id>\"` for a draft."
  @spec id(String.t(), map()) :: String.t()
  def id(section, %resource{id: id}) do
    if resource == Drafts.resource(section),
      do: section <> ":draft:" <> id,
      else: section <> ":" <> id
  end

  @doc """
  The `:read` action: the document the id names, read as the actor, as its draft — none for an
  unknown section, a document the actor may not read, or a query that names no id.
  """
  @spec read(Ash.Query.t(), map()) :: {:ok, [t()]}
  def read(query, context) do
    actor = Map.get(context, :actor)

    with %Ash.Filter{} = filter <- query.filter,
         {:ok, id} <- Ash.Filter.fetch_simple_equality_predicate(filter, :id),
         {section, resource, document_id} <- document(id),
         mode when not is_nil(mode) <- mode(section),
         {:ok, opts} <- Section.read_opts(resource, actor),
         {:ok, document} <- Ash.get(resource, document_id, opts) do
      {:ok, [draft(section, document, actor)]}
    else
      _nothing -> {:ok, []}
    end
  end

  defp document(id) do
    case String.split(id, ":", parts: 3) do
      [section, "draft", draft_id] -> {section, Drafts.resource(section), draft_id}
      [section, document_id] -> {section, Section.resource(section), document_id}
      _unknown -> :error
    end
  end

  @doc """
  The `:update` action: the draft's `description`, `seo_tags` and `schema` written through the
  document's own update action, as the actor — `MishkaCmsCore.Runtime.PageBuilder.Helpers.save_section/5`,
  the write every save in the editor takes. The saved document comes back as the record's `document`.
  """
  @spec save(Ash.Changeset.t(), map()) :: {:ok, t()} | {:error, term()}
  def save(%{data: %{document: document} = data} = changeset, context) do
    resource = document.__struct__

    fields =
      data.mode
      |> stored(changeset)
      |> Map.merge(%{"id" => document.id, "site_id" => document.site_id})

    case Helpers.save_section(resource, &Ash.get(resource, &1, &2), fields, context.actor) do
      {:ok, saved} -> {:ok, %{data | document: saved}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stored(:page, changeset) do
    %{
      "description" => changeset |> Ash.Changeset.get_attribute(:description) |> filled(),
      "seo_tags" => Ash.Changeset.get_attribute(changeset, :tags),
      "schema" => Ash.Changeset.get_attribute(changeset, :schema)
    }
  end

  defp stored(:tags, changeset),
    do: %{"seo_tags" => Ash.Changeset.get_attribute(changeset, :tags)}

  @doc "What Save sends the `:update` action for `seo`."
  @spec params(t()) :: map()
  def params(%{mode: :page} = seo) do
    %{
      "description" => seo.description,
      "tags" => written(seo.tags),
      "schema" => seo.schema
    }
  end

  def params(seo), do: %{"tags" => written(seo.tags)}

  defp written(tags) do
    for %{tag: tag, attrs: attrs, content: content} <- tags,
        is_binary(tag),
        do: %{"tag" => tag, "attrs" => attrs, "content" => content}
  end

  # THE DRAFT a document opens with: what it stores, and the head it renders.
  defp draft(section, document, actor) do
    mode = mode(section)

    __MODULE__
    |> struct(
      id: id(section, document),
      mode: mode,
      document: document,
      tags: Seo.stored_tags(Map.get(document, :seo_tags)),
      adding: nil,
      advanced: false,
      json_error: nil,
      restricted: false,
      vars: Seo.variables(),
      record_driven: false,
      sample: nil,
      view: "google",
      stars: nil
    )
    |> page_draft(document, actor)
    |> preview()
  end

  defp page_draft(%{mode: :page} = seo, document, actor) do
    schema = for %{} = object <- List.wrap(document.schema), do: object
    {type, fields} = managed_schema(schema)

    %{
      seo
      | description: document.description || "",
        schema: schema,
        type: type,
        fields: fields,
        json: schema_json(schema),
        layout_tags: layout_tags(document, actor),
        record: Seo.record_of(document.extra),
        record_types: Seo.record_types(document.site_id),
        image_manual: manual?(Seo.tag_value(seo.tags, "og:image"))
    }
  end

  defp page_draft(seo, _document, _actor), do: seo

  @doc """
  `seo` with the head its page would render, asked of `MishkaCmsCore.Runtime.Seo.resolve/2` with
  the draft in place of the stored fields; a dynamic page's plugin answers with its own variables
  there too. A layout has no head of its own and is returned as it is.
  """
  @spec preview(t()) :: t()
  def preview(%{mode: :page, document: document} = seo) do
    params = sample_params(seo)
    language = Map.get(params, Languages.capture()) || preview_language(document)
    base = Seo.base(host(document))

    page = %{
      title: document.title,
      path: document.path,
      section: Map.get(document, :section),
      language: language,
      language_group_id: Map.get(document, :language_group_id),
      timestamp: Map.get(document, :updated_at),
      content: Map.get(document, :content),
      seo: %{description: seo.description, meta_tags: seo.tags, schema: seo.schema}
    }

    restricted = Seo.noindex?(document.permissions, document.extra)

    head =
      Seo.resolve(page,
        site_id: document.site_id,
        url: Seo.absolute(preview_path(document.path, language, params), base),
        params: params,
        record: seo.record,
        base: base,
        restricted?: restricted,
        layers: [seo.layout_tags, seo.tags],
        stand_ins: params == %{}
      )

    own = plugin_vars(head.var_docs)

    %{
      seo
      | head: head,
        base: base,
        restricted: restricted,
        vars: Enum.uniq_by(Seo.variables() ++ own, & &1.key),
        record_driven: is_binary(seo.record) or own != [] or captures_record?(document.path),
        stars: stars(head.schema)
    }
  end

  def preview(seo), do: seo

  @doc """
  `seo` after one edit, its head drawn again. `params` are the form's fields as drawn and `target`
  the one that changed (`["seo", "add"]`), which decides what else the edit writes — picking a tag
  to add starts its row, picking a structured-data type writes its object, typing JSON replaces the
  schema.
  """
  @spec change(t(), map(), [String.t()]) :: t()
  def change(seo, params, target), do: seo |> edit(params, target) |> preview()

  defp edit(seo, params, ["seo", "sample"]),
    do: %{typed(seo, params) | sample: pick_sample(seo, params["sample"])}

  defp edit(seo, params, ["seo", "noindex" | _]),
    do: seo |> typed(params) |> put_noindex(params["noindex"] == "true")

  defp edit(seo, params, ["seo", "add"]),
    do: seo |> typed(params) |> Map.put(:adding, start_adding(params["add"]))

  defp edit(%{mode: :page} = seo, params, ["seo", "type"]),
    do: seo |> typed(params) |> put_schema_type(params["type"])

  defp edit(%{mode: :page} = seo, params, ["seo", "fields" | _]),
    do: seo |> typed(params) |> put_schema_fields(Map.get(params, "fields", %{}))

  defp edit(%{mode: :page} = seo, params, ["seo", "faq" | _]),
    do: seo |> typed(params) |> put_schema_fields(%{"questions" => indexed(params["faq"])})

  defp edit(%{mode: :page} = seo, params, ["seo", "json"]),
    do: seo |> typed(params) |> put_json(params["json"] || "")

  defp edit(seo, params, _typed), do: seo |> typed(params) |> keep_adding(params)

  @doc """
  `seo` with the fields every edit sends as they are drawn: the description, and the title, share
  image and canonical address, each of which is one stored tag — a value writes it, a blank removes
  it, an absent field leaves it.
  """
  @spec typed(t(), map()) :: t()
  def typed(%{mode: :page} = seo, params) do
    %{seo | description: text_param(params, "description", seo.description)}
    |> put_basic("title", params["title"])
    |> put_basic("og:image", params["image"])
    |> put_basic("canonical", params["canonical"])
  end

  def typed(seo, _params), do: seo

  @doc "`seo` with the add-a-tag row written as a stored tag, when the row is complete."
  @spec add_tag(t()) :: t()
  def add_tag(%{adding: %{tag: %{} = tag}} = seo),
    do: preview(%{seo | tags: Seo.put_tag(seo.tags, tag), adding: nil})

  def add_tag(seo), do: seo

  @doc "`seo` without the stored tag at `index`."
  @spec remove_tag(t(), String.t()) :: t()
  def remove_tag(seo, index) do
    case index(index) do
      at when at >= 0 -> preview(%{seo | tags: List.delete_at(seo.tags, at)})
      _unknown -> seo
    end
  end

  @doc "`seo` with one more, empty, question."
  @spec add_question(t()) :: t()
  def add_question(seo) do
    questions = questions(seo) ++ [%{"question" => "", "answer" => ""}]
    preview(put_schema_fields(seo, %{"questions" => questions}))
  end

  @doc "`seo` without the question at `index`."
  @spec remove_question(t(), String.t()) :: t()
  def remove_question(seo, index) do
    case index(index) do
      at when at >= 0 ->
        questions = List.delete_at(questions(seo), at)
        preview(put_schema_fields(seo, %{"questions" => questions}))

      _unknown ->
        seo
    end
  end

  @doc "`seo` with the Advanced section opened, or closed."
  @spec toggle_advanced(t()) :: t()
  def toggle_advanced(seo), do: %{seo | advanced: not seo.advanced}

  @doc "The kind of record `seo` shows, as its `record_types` describe it; `nil` for none."
  @spec record_type(t()) :: map() | nil
  def record_type(%{record: record, record_types: types}) when is_binary(record),
    do: Enum.find(List.wrap(types), &(&1.id == record))

  def record_type(_none), do: nil

  @doc "`seo` previewed in `view`: `\"google\"`, `\"x\"` or `\"facebook\"`."
  @spec put_view(t(), String.t()) :: t()
  def put_view(seo, view) when view in ["google", "x", "facebook"], do: %{seo | view: view}
  def put_view(seo, _unknown), do: seo

  @doc "`seo` with the share image's address field shown, or hidden."
  @spec toggle_image_manual(t()) :: t()
  def toggle_image_manual(seo), do: %{seo | image_manual: not seo.image_manual}

  @doc "`seo` without a share image of its own: each record's, or none, again."
  @spec clear_image(t()) :: t()
  def clear_image(seo), do: preview(%{seo | tags: Seo.drop_tag(seo.tags, "og:image")})

  defp pick_sample(seo, index) do
    with %{samples: samples} <- record_type(seo),
         at when at >= 0 <- index(index) do
      Enum.at(samples, at)
    else
      _none -> nil
    end
  end

  defp sample_params(%{sample: %{params: %{} = params}}), do: params
  defp sample_params(_no_sample), do: %{}

  # An address a person typed — a variable, another site's picture — rather than a Media file.
  defp manual?(value) when is_binary(value), do: not String.starts_with?(value, "/")
  defp manual?(_none), do: false

  # The rating a search result may draw as stars: the first object of a type that can have them,
  # whose `aggregateRating` resolved to a number out of 5.
  defp stars(schema) do
    starred = for type <- Seo.schema_types(), type.stars?, do: type.type

    Enum.find_value(List.wrap(schema), fn json ->
      with {:ok, %{"@type" => type, "aggregateRating" => %{} = rating}} <- Jason.decode(json),
           true <- type in starred,
           {value, ""} when value > 0 and value <= 5 <-
             Float.parse(to_string(rating["ratingValue"])) do
        %{value: value, count: rating["ratingCount"]}
      else
        _no_stars -> nil
      end
    end)
  end

  defp text_param(params, key, current) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _absent -> current
    end
  end

  defp put_basic(seo, id, value) when is_binary(value) do
    case String.trim(value) do
      "" -> %{seo | tags: Seo.drop_tag(seo.tags, id)}
      value -> %{seo | tags: Seo.put_tag(seo.tags, catalog_tag(id, value))}
    end
  end

  defp put_basic(seo, _id, _absent), do: seo

  defp put_noindex(seo, true),
    do: %{seo | tags: Seo.put_tag(seo.tags, catalog_tag("robots", "noindex, nofollow"))}

  defp put_noindex(seo, false), do: %{seo | tags: Seo.drop_tag(seo.tags, "robots")}

  defp catalog_tag(id, value, needs \\ %{}) do
    entry = Enum.find(Seo.catalog(), &(&1.id == id))
    Seo.stored_tag(entry.tag, Map.merge(entry.attrs, needs), value)
  end

  # THE ADD ROW: the tag chosen, and the value it will be written with — its catalog default to
  # begin with. `:tag` is what Add writes, nil until the row is complete.
  defp start_adding("custom"),
    do: with_tag(%{id: "custom", value: "", values: [], needs: %{}, kind: "name", key: ""})

  defp start_adding(id) when is_binary(id) do
    case Enum.find(Seo.catalog(), &(&1.id == id)) do
      nil ->
        nil

      entry ->
        with_tag(%{
          id: id,
          value: entry.default,
          values: directives(entry.default),
          needs: Map.new(entry.needs, &{&1, ""}),
          kind: nil,
          key: ""
        })
    end
  end

  defp start_adding(_none), do: nil

  defp keep_adding(%{adding: %{} = adding} = seo, params) do
    values =
      case params["add_values"] do
        list when is_list(list) -> Enum.reject(list, &(&1 == ""))
        _absent -> adding.values
      end

    needs =
      case params["add_needs"] do
        %{} = needs -> Map.merge(adding.needs, Map.take(needs, Map.keys(adding.needs)))
        _absent -> adding.needs
      end

    adding = %{
      adding
      | value: text_param(params, "add_value", adding.value),
        values: values,
        needs: needs,
        kind: text_param(params, "custom_kind", adding.kind),
        key: text_param(params, "custom_key", adding.key)
    }

    %{seo | adding: with_tag(adding)}
  end

  defp keep_adding(seo, _params), do: seo

  defp with_tag(adding), do: Map.put(adding, :tag, adding_tag(adding))

  defp adding_tag(%{id: "custom", kind: kind, key: key, value: value}) do
    case {String.trim(key), String.trim(value)} do
      {"", _value} -> nil
      {_key, ""} -> nil
      {key, value} when kind == "rel" -> Seo.stored_tag("link", %{"rel" => key}, value)
      {key, value} when kind == "property" -> Seo.stored_tag("meta", %{"property" => key}, value)
      {key, value} -> Seo.stored_tag("meta", %{"name" => key}, value)
    end
  end

  defp adding_tag(%{id: id} = adding) do
    entry = Enum.find(Seo.catalog(), &(&1.id == id))
    needs = Map.new(adding.needs, fn {key, value} -> {key, String.trim(value)} end)

    value =
      case entry.multiple? do
        true -> entry.values |> Enum.filter(&(&1 in adding.values)) |> Enum.join(", ")
        false -> String.trim(adding.value)
      end

    if value == "" or Enum.any?(needs, fn {_key, need} -> need == "" end),
      do: nil,
      else: catalog_tag(id, value, needs)
  end

  defp directives(value), do: value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  # THE TYPE PICKER EDITS ONE OBJECT, the first of a type `Seo.schema_types/0` offers, in place among
  # whatever else the page's schema holds.
  defp managed_schema(schema), do: Enum.find_value(schema, {"", %{}}, &Seo.schema_values/1)

  defp managed_index(schema), do: Enum.find_index(schema, &Seo.schema_values/1)

  defp put_schema_type(seo, type) do
    case Enum.find(Seo.schema_types(), &(&1.type == type)) do
      nil ->
        write_managed(%{seo | type: "", fields: %{}}, nil)

      known ->
        fields = schema_defaults(known)
        write_managed(%{seo | type: type, fields: fields}, Seo.schema_object(type, fields))
    end
  end

  defp schema_defaults(%{faq?: true}), do: %{"questions" => [%{"question" => "", "answer" => ""}]}
  defp schema_defaults(known), do: Map.new(known.fields, &{&1.key, &1.default})

  defp put_schema_fields(%{type: ""} = seo, _fields), do: seo

  defp put_schema_fields(seo, fields) do
    fields = Map.merge(seo.fields, fields)

    current =
      case managed_index(seo.schema) do
        nil -> %{}
        at -> Enum.at(seo.schema, at)
      end

    write_managed(%{seo | fields: fields}, Seo.schema_object(seo.type, fields, current))
  end

  defp write_managed(seo, object) do
    schema =
      case {managed_index(seo.schema), object} do
        {nil, nil} -> seo.schema
        {nil, object} -> seo.schema ++ [object]
        {at, nil} -> List.delete_at(seo.schema, at)
        {at, object} -> List.replace_at(seo.schema, at, object)
      end

    %{seo | schema: schema, json: schema_json(schema), json_error: nil}
  end

  defp questions(seo), do: Map.get(seo.fields, "questions", [])

  # `seo[faq][0][question]` arrives as a map keyed by position.
  defp indexed(%{} = rows) do
    rows
    |> Enum.sort_by(fn {index, _row} -> index(index) end)
    |> Enum.map(fn {_index, row} -> Map.take(row, ["question", "answer"]) end)
  end

  defp indexed(_no_rows), do: []

  defp index(index) when is_binary(index) do
    case Integer.parse(index) do
      {at, ""} -> at
      _not_a_number -> -1
    end
  end

  defp index(index) when is_integer(index), do: index
  defp index(_unknown), do: -1

  # THE ADVANCED BOX IS THE WHOLE SCHEMA. Valid JSON replaces the draft's schema and the type picker
  # follows it; anything else is kept as typed, with the reason, and Save refuses it.
  defp put_json(seo, json) do
    case json |> String.trim() |> decode_schema() do
      {:ok, schema} ->
        {type, fields} = managed_schema(schema)
        %{seo | schema: schema, type: type, fields: fields, json: json, json_error: nil}

      {:error, message} ->
        %{seo | json: json, json_error: message}
    end
  end

  defp decode_schema(""), do: {:ok, []}
  defp decode_schema(text), do: text |> Jason.decode() |> typed_schema()

  defp typed_schema({:ok, list}) when is_list(list) do
    if Enum.all?(list, &typed_object?/1),
      do: {:ok, list},
      else: {:error, gettext("Each object needs an \"@type\", such as \"Article\".")}
  end

  defp typed_schema({:ok, _not_a_list}),
    do: {:error, gettext("Write a list of objects: [ { \"@type\": … } ].")}

  defp typed_schema({:error, _reason}), do: {:error, gettext("This is not valid JSON.")}

  defp typed_object?(%{"@type" => type}) when is_binary(type) and type != "", do: true
  defp typed_object?(_other), do: false

  defp schema_json(schema) do
    case Jason.encode(schema, pretty: true) do
      {:ok, json} -> json
      {:error, _reason} -> "[]"
    end
  end

  defp filled(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp filled(_no_text), do: nil

  defp layout_tags(%{layout_id: id}, actor) when is_binary(id) do
    with {:ok, opts} <- Section.read_opts(Layout, actor),
         {:ok, %{seo_tags: tags}} <- Ash.get(Layout, id, Keyword.delete(opts, :load)) do
      Seo.stored_tags(tags)
    else
      _unreadable -> []
    end
  end

  defp layout_tags(_document, _actor), do: []

  defp host(%{site: %{host: host}}) when is_binary(host), do: host

  defp host(%{site_id: site_id}) when is_binary(site_id) do
    case MishkaCmsCore.Runtime.States.SiteState.get(site_id) do
      {:ok, %{host: host}} -> host
      _unknown -> nil
    end
  end

  defp host(_global), do: nil

  # The language the preview is drawn in: the first the page answers in.
  defp preview_language(document) do
    document |> PageEditions.served_languages(document.site_id) |> List.first() ||
      document.language || Languages.primary(document.site_id)
  end

  # The address drawn: the language, then a sample's captures, and `{slug}` for one it has none of.
  defp preview_path(path, language, params) when is_binary(path) do
    known = Map.put(params, Languages.capture(), language)

    segments =
      path
      |> String.split("/", trim: true)
      |> Enum.map(fn
        <<mark, name::binary>> when mark in [?:, ?*] ->
          filled(Map.get(known, name)) || "{#{name}}"

        segment ->
          segment
      end)

    "/" <> Enum.join(segments, "/")
  end

  defp preview_path(_no_path, _language, _params), do: nil

  # A path that captures more than its language serves a record per address.
  defp captures_record?(path) when is_binary(path) do
    captures = [":" <> Languages.capture(), "*" <> Languages.capture()]

    path
    |> String.split("/", trim: true)
    |> Enum.any?(&(String.starts_with?(&1, [":", "*"]) and &1 not in captures))
  end

  defp captures_record?(_no_path), do: false

  defp plugin_vars(docs) do
    Enum.flat_map(List.wrap(docs), fn
      %{} = doc ->
        case doc_text(doc, :key) do
          nil ->
            []

          key ->
            [%{key: key, label: doc_text(doc, :label) || key, help: doc_text(doc, :help) || ""}]
        end

      _not_a_doc ->
        []
    end)
  end

  defp doc_text(doc, key) do
    case Map.get(doc, key, Map.get(doc, Atom.to_string(key))) do
      value when is_binary(value) and value != "" -> value
      _no_text -> nil
    end
  end
end
