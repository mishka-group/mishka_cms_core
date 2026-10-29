# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.StatefulPlacement do
  @moduledoc """
  Refuses markup that places a live component somewhere a live component cannot live.

  A stateful component compiles to a `Phoenix.LiveComponent`, and calling one produces a
  `%Phoenix.LiveView.Component{}` — a token that only a LiveView's diff knows how to turn into
  HTML. Three of the four things this runtime compiles are rendered somewhere no such diff runs, and
  each failure is worse than an error message:

    * **An error page** is served by a CONTROLLER. `MishkaCmsWeb.ErrorHTML.render/2` calls
      `page_module.render(conn, status)` and flattens the result, so the token raises — inside that
      function's own rescue, which falls back to Phoenix's plain default. The site's custom error
      page is replaced for every visitor, with a warning in the log and nothing on the screen.
    * **A layout** wraps error pages as well as pages, so it inherits that.
    * **Another component's template** is rendered by the editor's canvas inside a containment
      that forces iodata on purpose so a component's raise costs the
      component and not the author's unsaved session. A live component reached from inside another
      component's markup builds the token anyway and blows up the PARENT's containment — a red chip
      on a component the author did not touch.

  ## Where it is enforced

  At the action boundary, on the three resources that have somewhere to put markup, so the builder,
  the Gervaz form, the JSON:API, a seed, a kit installer and a version restore all meet the same
  rule. A page is the one surface that is a LiveView from end to end, so a page is not checked.

  The rule has two ends and both are held. Markup that names a component already live is refused
  when the markup is written; a component that becomes live while something already names it is
  refused when IT is written — created live, switched to live, renamed or moved to another site
  while live, or unarchived while live — with the documents that name it in the message. An archived
  document is one of those documents: unarchiving it writes none of its markup, so nothing would
  read that markup then.

  ## Every field that is compiled with the live `component/1` in reach

    * a layout — `template` and `helpers[].code`
    * an error page — each `error_pages[].template`, each `error_pages[].layout.template`,
      `root_layout_template` and `helpers[].code`
    * a component — `template`, `body`, `helpers[].code`, and in `extra` the `prelude` and each
      `clauses[].template` and `clauses[].body`

  ## How a component is found in markup

  By reading each field in the language it is compiled in, never by a pattern over the source.

  HEEx is parsed. `MishkaCmsCore.Runtime.Authoring.Tree.parse/1` is the same reader the editor
  uses, so a `component_name` inside a comment or a code sample is not a placement and a name built
  at runtime — `component_name={@which}` — is not a literal this can resolve. The template's own
  Elixir is read as well, because `{component(%{component_name: "x"})}` reaches the same function.
  Markup that will not parse is left alone: `Validations.TemplateCompiles` is what refuses that, and
  two messages for one mistake is worse than one.

  Elixir — a helper, a body, a prelude — is quoted, and a `component` call with a literal name is a
  placement, as is anything its `~H` sigils place.

  `root_layout_template` is classic EEx, compiled by `Phoenix.HTML.Engine` rather than the tag
  engine, so a `<.component>` tag in it is TEXT that reaches the visitor as written and calls
  nothing. What reaches the live function from there is an expression — `<%= component(…) %>` —
  and that is what is read.

  ## Only what this write changed

  A record whose stored markup predates this validation stays editable. Refusing every other field on
  it would lock the author out of the one screen the markup gets fixed in.
  """

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.{Component, ErrorPage, Layout}
  alias MishkaCmsCore.Runtime.Authoring.Markup
  alias MishkaCmsCore.Runtime.Authoring.Tree
  alias MishkaCmsCore.Runtime.Authoring.Tree.Node

  require Ash.Query

  # How many documents a refusal names before it counts the rest.
  @named_referrers 3

  # What a write changes when it brings a live component within reach of a name.
  @arriving [:stateful, :name, :site_id, :archived_at]

  # The unarchived rows, then the archived ones.
  @every_row [:read_any, :master_archived]

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, opts, _context) do
    with :ok <- placed(changeset, noun(opts)) do
      referenced(changeset)
    end
  end

  defp noun(opts) do
    Gettext.dgettext(
      MishkaCmsCore.Gettext,
      "errors",
      Keyword.get(opts, :noun, dgettext_noop("errors", "This"))
    )
  end

  defp placed(changeset, noun) do
    changeset.resource
    |> markup_attributes()
    |> Enum.filter(&Ash.Changeset.changing_attribute?(changeset, &1))
    |> Enum.flat_map(fn attribute ->
      for {label, name} <-
            placements(attribute, Ash.Changeset.get_attribute(changeset, attribute)),
          do: {attribute, label, name}
    end)
    |> refusal(noun)
  end

  defp refusal([], _noun), do: :ok

  defp refusal(placements, noun) do
    names = placements |> Enum.map(&elem(&1, 2)) |> Enum.uniq()

    case stateful_among(names) do
      [] ->
        :ok

      live ->
        {field, label, _name} = Enum.find(placements, &(elem(&1, 2) in live))

        {:error,
         field: field,
         message:
           Gettext.dgettext(MishkaCmsCore.Gettext, "errors", cannot_hold(live),
             location: location(label),
             noun: noun,
             names: Enum.join(live, ", ")
           )}
    end
  end

  defp cannot_hold([_one]),
    do:
      dgettext_noop(
        "errors",
        "%{location}%{noun} cannot hold %{names} — it is a live component, and a live component only runs on a page."
      )

  defp cannot_hold(_many),
    do:
      dgettext_noop(
        "errors",
        "%{location}%{noun} cannot hold %{names} — they are a live component, and a live component only runs on a page."
      )

  defp location(:template), do: ""
  defp location(:root_layout), do: dgettext("errors", "The root layout: ")
  defp location(:body), do: dgettext("errors", "The body: ")
  defp location(:prelude), do: dgettext("errors", "The prelude: ")

  defp location({:helper, name}),
    do: dgettext("errors", "The %{name} helper: ", name: to_string(name))

  defp location({:status_page, status}) when status in [nil, false],
    do: dgettext("errors", "The error page: ")

  defp location({:status_page, status}),
    do: dgettext("errors", "The %{status} page: ", status: to_string(status))

  defp location({:status_layout, status}) when status in [nil, false],
    do: dgettext("errors", "The error layout: ")

  defp location({:status_layout, status}),
    do: dgettext("errors", "The %{status} layout: ", status: to_string(status))

  defp location({:clause, index}), do: dgettext("errors", "Clause %{index}: ", index: index)

  # ONE READ FOR THE WHOLE TEMPLATE, and only when it names components at all. Multitenancy is
  # bypassed and no actor is asked, because the question is about the shape of a row rather than
  # about who may see it: a name that resolves to a live component resolves to one for everybody,
  # and the alternative is finding out by publishing.
  defp stateful_among([]), do: []

  defp stateful_among(names) do
    Component
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(name in ^names and stateful == true)
    |> Ash.Query.select([:name])
    |> Ash.read()
    |> case do
      {:ok, %{results: rows}} -> Enum.map(rows, & &1.name)
      {:ok, rows} when is_list(rows) -> Enum.map(rows, & &1.name)
      _unreadable -> []
    end
  end

  # THE OTHER END OF THE RULE. Markup is checked when it is written, so a component that becomes live
  # after something already names it would otherwise go unnoticed until an error page fell back to
  # Phoenix's default. A live component comes within reach of a name when it is created live,
  # switched to live, renamed, moved to another site or unarchived — a version restore does the first
  # two by another route — and those are the only writes that pay for the cross-table read.
  defp referenced(%{resource: Component} = changeset) do
    with true <- Ash.Changeset.get_attribute(changeset, :stateful) == true,
         field when field in @arriving <-
           Enum.find(@arriving, &Ash.Changeset.changing_attribute?(changeset, &1)),
         name when is_binary(name) <- stored_name(changeset) do
      name
      |> referrers(site_of(changeset))
      |> used_by(field, name)
    else
      _not_arriving -> :ok
    end
  end

  defp referenced(_changeset), do: :ok

  # THE SITE THE ROW WILL BELONG TO. A tenant's create stamps `site_id` from the tenant in a change
  # that runs after this validation, so until then the tenant is the site. Every other write carries
  # the row's own `site_id`, where nil is a global component whatever tenant the write came through.
  defp site_of(%{action_type: :create} = changeset),
    do: Ash.Changeset.get_attribute(changeset, :site_id) || changeset.tenant

  defp site_of(changeset), do: Ash.Changeset.get_attribute(changeset, :site_id)

  # THE NAME AS IT WILL BE STORED. `slugify(:name, into: :name)` runs in a before-action hook, after
  # every validation, so what the changeset holds here is still what the author typed — and markup
  # can only ever name the slug.
  defp stored_name(changeset) do
    case Ash.Changeset.get_attribute(changeset, :name) do
      name when is_binary(name) -> Slug.slugify(name)
      _no_name -> nil
    end
  end

  defp used_by([], _field, _name), do: :ok

  defp used_by(referrers, field, name) do
    {named, rest} = Enum.split(referrers, @named_referrers)

    {:error,
     field: field,
     message:
       Gettext.dgettext(MishkaCmsCore.Gettext, "errors", used_by_message(rest),
         name: to_string(name),
         referrers: Enum.join(named, ", "),
         others: length(rest)
       )}
  end

  defp used_by_message([]),
    do:
      dgettext_noop(
        "errors",
        "%{name} is used by %{referrers} — a live component only runs on a page."
      )

  defp used_by_message(_rest),
    do:
      dgettext_noop(
        "errors",
        "%{name} is used by %{referrers} and %{others} more — a live component only runs on a page."
      )

  # A SUBSTRING NARROWS THE READ AND THE PARSE DECIDES. The name in a comment, in a code sample or
  # inside a longer name all pass the filter, and none of them is a placement. The cast to text is
  # what lets one filter read a text column, a map and an array of maps alike; a slug carries no
  # character any of those encodings escapes.
  #
  # A site's component is reachable from that site's documents and from the global ones, which
  # resolve names in whatever site renders them; a global component is reachable from every site.
  #
  # ARCHIVED ROWS ARE READ TOO, by the action that shows them, and named as archived because the
  # lists an author would look in hide them.
  #
  # STREAMED, because both reads require pagination — `:master_archived` by offset only — and a kit's
  # icon is named by more documents than one page holds. A read that fails raises rather than
  # answering "nobody", so a write this cannot vouch for is not let through.
  defp referrers(name, site_id) do
    for resource <- [Layout, ErrorPage, Component],
        action <- @every_row,
        row <- using(resource, action, name, site_id),
        do: referrer(resource, row)
  end

  defp referrer(resource, row) do
    referrer = dgettext("errors", "%{kind} '%{name}'", kind: kind(resource), name: row.name)

    case row do
      %{archived_at: nil} -> referrer
      _archived -> dgettext("errors", "%{referrer} (archived)", referrer: referrer)
    end
  end

  defp using(resource, action, name, site_id) do
    attributes = markup_attributes(resource)

    resource
    |> Ash.Query.for_read(action, %{}, authorize?: false)
    |> Ash.Query.filter(^mentioning(attributes, name))
    |> within(site_id)
    |> Ash.Query.select([:name, :archived_at | attributes])
    |> Ash.stream!(authorize?: false, allow_stream_with: :offset)
    |> Stream.filter(&uses?(&1, attributes, name))
  end

  defp mentioning(attributes, name) do
    Enum.reduce(attributes, expr(false), fn attribute, filter ->
      expr(^filter or fragment("strpos((?)::text, ?) > 0", ^ref(attribute), ^name))
    end)
  end

  defp within(query, nil), do: query
  defp within(query, site), do: Ash.Query.filter(query, site_id == ^site or is_nil(site_id))

  defp uses?(row, attributes, name) do
    Enum.any?(attributes, fn attribute ->
      row
      |> Map.get(attribute)
      |> then(&placements(attribute, &1))
      |> Enum.any?(&(elem(&1, 1) == name))
    end)
  end

  defp kind(Layout), do: dgettext("errors", "layout")
  defp kind(ErrorPage), do: dgettext("errors", "error page")
  defp kind(Component), do: dgettext("errors", "component")

  defp markup_attributes(Layout), do: [:template, :helpers]
  defp markup_attributes(ErrorPage), do: [:root_layout_template, :error_pages, :helpers]
  defp markup_attributes(Component), do: [:template, :body, :extra, :helpers]

  # Every `{label, name}` a field places, read in the language that field is compiled in.
  defp placements(:template, template), do: labelled(:template, heex(template))

  defp placements(:root_layout_template, template),
    do: labelled(:root_layout, eex(template))

  defp placements(:body, body), do: labelled(:body, elixir(body))

  defp placements(:helpers, helpers) do
    helpers
    |> List.wrap()
    |> Enum.flat_map(&labelled({:helper, field(&1, :name)}, elixir(field(&1, :code))))
  end

  defp placements(:error_pages, entries) do
    entries
    |> List.wrap()
    |> Enum.flat_map(fn entry ->
      status = field(entry, :status)

      labelled({:status_page, status}, heex(field(entry, :template))) ++
        labelled(
          {:status_layout, status},
          entry |> field(:layout) |> field(:template) |> heex()
        )
    end)
  end

  defp placements(:extra, extra) do
    clauses =
      extra
      |> field(:clauses)
      |> List.wrap()
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {clause, index} ->
        labelled(
          {:clause, index},
          heex(field(clause, :template)) ++ elixir(field(clause, :body))
        )
      end)

    labelled(:prelude, elixir(field(extra, :prelude))) ++ clauses
  end

  defp labelled(label, names), do: Enum.map(names, &{label, &1})

  # Stored maps come back with string keys and changeset input may carry atom keys.
  defp field(%{} = map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp field(_not_a_map, _key), do: nil

  defp heex(template) when is_binary(template),
    do: tags(template) ++ Enum.flat_map(Markup.expressions(template), &elixir/1)

  defp heex(_template), do: []

  # UNPARSEABLE MARKUP IS NOT THIS VALIDATION'S BUSINESS. `TemplateCompiles` refuses it with a
  # message about what is actually wrong, and answering here as well would give the author two
  # sentences about one typo.
  defp tags(template) do
    case Tree.parse(template) do
      {:ok, tree} ->
        for node <- Tree.walk(tree),
            node.kind == :component,
            name = Node.component_name(node),
            is_binary(name),
            do: name

      _unparseable ->
        []
    end
  end

  # THE ENGINE THE ERROR COMPILER USES, so a root layout this cannot read is one that would not
  # compile either — and that failure is the compiler's to report, not this rule's.
  defp eex(template) when is_binary(template) do
    template
    |> EEx.compile_string(engine: Phoenix.HTML.Engine)
    |> called()
  rescue
    _unparseable -> []
  end

  defp eex(_template), do: []

  defp elixir(code) when is_binary(code) do
    case Code.string_to_quoted(code) do
      {:ok, quoted} -> called(quoted)
      {:error, _unparseable} -> []
    end
  end

  defp elixir(_code), do: []

  defp called(quoted) do
    {_quoted, names} =
      Macro.prewalk(quoted, [], fn node, names -> {node, names ++ call(node)} end)

    names
  end

  # `component/1` takes the assigns map and `component/2,3` take the name first. A `<.component>` tag
  # compiles to the first, and either written out by hand reaches the same function.
  defp call({:sigil_H, _meta, [{:<<>>, _parts_meta, [template]}, _modifiers]})
       when is_binary(template),
       do: heex(template)

  defp call({:component, _meta, [first | _rest]}), do: literal(first)

  defp call(
         {{:., _dot_meta, [{:__aliases__, _alias_meta, aliases}, :component]}, _meta, [first | _]}
       ) do
    case List.last(aliases) do
      :LiveViewHelpers -> literal(first)
      _other_module -> []
    end
  end

  defp call(_node), do: []

  defp literal(name) when is_binary(name), do: [name]

  defp literal({:%{}, _meta, pairs}) when is_list(pairs) do
    case List.keyfind(pairs, :component_name, 0) do
      {:component_name, name} when is_binary(name) -> [name]
      _built_at_runtime -> []
    end
  end

  defp literal(_built_at_runtime), do: []

  # A BULK WRITE THAT RAN ATOMICALLY WOULD SKIP THIS. The Gervaz table unarchives in bulk and tries
  # the atomic strategy first, so saying `:ok` here would let a live component back unread.
  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "which documents name a component is a read of other rows"}

  @impl true
  def describe(_opts),
    do: [message: "Validates that no live component is placed where one cannot run", vars: []]
end
