# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.CssClosure do
  @moduledoc """
  Which templates a site can actually reach, and therefore which classes its stylesheet must carry.

  A UI kit is installed once and shared by every site, so its components are written to
  `runtime/__global__/component/*.template` and the CSS compiler used to glob the whole directory.
  With Chelekom that is 251 templates and 2.1 MB — the great majority of everything the compiler
  scans — and a site that uses one alert paid for all of it on every page load.

  Reachability is decidable here, because a component reference in a runtime template is a literal:

      <.component component_name="chelekom-alert" site="localhost">

  So the reachable set is a graph walk from a site's ROOTS: the pages and error pages a visitor can
  ask for, plus the layouts those pages use. Everything else earns its place by being named. A
  component's scope decides where it may be USED, never whether its CSS ships — a global component
  reaches a site's stylesheet on exactly the same terms as one of the site's own, by that site
  rendering it.

  Components compose, so the walk is transitive: `chelekom-form-wrapper` pulls in `chelekom-error`,
  which pulls in `chelekom-icon`.

  ## Roots

  A page and an error page are roots because a visitor can ask for either directly. A LAYOUT is not:
  it is chosen by a database relation rather than named in markup, so it cannot be walked to from
  the text alone. Treating every layout as a root meant a site with thirty layouts and five pages
  scanned twenty-five it can never render, and put every GLOBAL layout into every site's stylesheet.
  `MishkaCmsCore.Runtime.Compilers.TailwindCompiler.closure_roots/2` reads `pages.layout_id` and
  passes the layouts a site's pages actually name; the default here is what a bare directory can
  know on its own, which is the pages and error pages.

  An error page needs no layout root: `BootHandler.build_error_template_content/1` already writes
  its layouts' markup into the error template itself.

  ## A component named through its own attribute

  A component may draw another it is told the name of:

      <.component component_name={@card} site={site_name()} doc={row.doc} />

  When `card` is an attribute the component declares and never assigns itself, the names it can
  take are known: its default, when that is a non-empty string, and every literal a reached caller
  writes for it — `<.component component_name="doc-workspace-list" card="doc-card" …>`. Those names
  are walked as literal references are. The component they name may hand a name on in turn, so the
  walk repeats until nothing new is reached.

  WHICH ATTRIBUTES QUALIFY IS DECIDED WHERE THE COMPONENT'S CODE IS AT HAND, when its template file
  is written: `attribute_marks/1` writes a line per attribute into the file and the walk reads it
  back, so it asks nothing of the database. `component_name={@name}` in a file with no line for
  `name` — not declared, assigned by the component's own code, read inside a helper, or a file
  written before these lines existed — is a reference the walk cannot resolve.

  ## When the answer is "everything"

  A reference the walk cannot resolve makes the closure unsound, and `for_site/2` returns
  `:unbounded`. Callers must fall back to globbing the whole directory. This is the whole safety
  story: an under-approximated closure means a component renders with no CSS at all, which is worse
  than a large stylesheet, and it would show up in production rather than in a build.

  A reference cannot be resolved when, in a reached template:

    * `component_name={…}` is any expression but `{@name}`, or `{@name}` sits in a page, a layout or
      an error page, or a `<.component>` tag names nothing and spreads `{…}`;
    * `{@name}` names an attribute the file has no line for;
    * a call to a component that names one through `name` hands `name` over as an expression
      (`card={…}`), or spreads `{…}` into the tag, or draws the component from stored content,
      whose markers an author writes — that CALLER is the template named;
    * once anything is named through an attribute, a template calls `component(…)` or
      `send_update(…)` from code, or holds a `<.component>` tag the walk cannot read.

  Each degrades to correct-and-large rather than small-and-broken.

  `reached_components/2` answers what the walk did reach either way, for a caller that needs only
  what is certainly reached — the components a site's warm job builds ahead of its visitors
  (`MishkaCmsCore.Runtime.Handlers.BootHandler.warm_components/2`).

  ## Components named in stored content

  A template that draws stored content — `<.rich_content …/>` — reaches the components the
  content's markers name, which no template shows (`MishkaCmsCore.Runtime.ContentComponents`). The
  caller passes those names as `:content_components`, and such a template names exactly them, each
  resolved as a `component_name="…"` is. A site where nothing reached draws content reaches none of
  them.

  ## Usage

      iex> CssClosure.for_site("localhost")
      %{components: ["chelekom-alert", "chelekom-icon"], templates: [...], scanned: 8, dynamic: [],
        resolved: []}

  See `MishkaCmsCore.Runtime.Compilers.TailwindCompiler`, which turns the result into `@source`
  lines, and `Mix.Tasks.Mishka.Css.Closure`, which prints it.
  """

  require Logger

  alias MishkaCmsCore.Runtime.PageBuilder.CodeReads

  @global "__global__"

  # A visitor asks for one of these by URL; nothing has to name them for them to render.
  @entry_kinds ["page", "error"]

  @reference ~r/component_name="([^"]+)"/
  @expression_name ~r/component_name\s*=\s*\{/
  @draws_content ~r/<\.rich_content\b/
  @component_tag ~r/<(?:[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)?\.component(?=[\s\/>])/
  @attribute_name ~r/\A[^\s=\/>{}"']+/
  @read_attribute ~r/\A\s*@([a-z_][A-Za-z0-9_]*[?!]?)\s*\z/
  @named_through ~r/component_name\s*=\s*\{\s*@([a-z_][A-Za-z0-9_]*[?!]?)\s*\}/
  @code_call ~r/\b(?:component|send_update(?:_after)?)\(/
  @mark ~r/<%!-- css-closure attr=([a-z_][A-Za-z0-9_]*[?!]?)(?: default="([^"\r\n]*)")? --%>/

  @typedoc """
  Everything a site's stylesheet has to be built from, or `:unbounded` when a reference the walk
  cannot resolve makes it unsound.

  `components` are the reachable component names, for a reader. `templates` are the resolved paths
  of EVERYTHING that must be scanned — the roots, the layouts they use and the components they
  reach — because a name is not enough to point a compiler at a file: it may resolve into the
  site's own component directory or into the global one, and only the walk knows which.
  `resolved` is every reached component that names a component through one of its attributes, with
  the names that attribute was found to take.
  """
  @type result ::
          %{
            components: [String.t()],
            templates: [String.t()],
            scanned: non_neg_integer(),
            dynamic: [String.t()],
            resolved: [resolved()]
          }
          | :unbounded

  @typedoc "A component, the attribute it names a component through, and every name that takes."
  @type resolved :: %{component: String.t(), attribute: String.t(), names: [String.t()]}

  @doc """
  Walks a site's roots and returns every template its stylesheet has to be built from.

  A SITE'S OWN COMPONENTS ARE WALKED, NOT ASSUMED. They used to be roots: every template under the
  site's directory seeded the walk, so all of them were reachable by definition and all of them were
  scanned. On a real install that is 176 components of which the pages reference a handful, and the
  rest contributed their classes to the stylesheet every visitor downloads.

  `:unbounded` means a reached template names a component in a way the walk cannot resolve — see
  "When the answer is everything" above. The caller must scan every component instead, and the
  templates responsible are logged.

  ## Options

    * `:runtime_dir` — the template tree to walk. Defaults to `default_runtime_dir/0`.
    * `:roots` — the templates a visitor can reach. Defaults to every page and error template in the
      site's own scopes; `TailwindCompiler.closure_roots/2` adds the layouts those pages use.
    * `:extra_scopes` — sibling scope directories to walk as roots alongside the site's own. A draft
      preview writes its unsaved template into a throwaway namespace, and that draft may be the only
      thing referencing the component being previewed — a walk over the SAVED site would miss it and
      the preview would render unstyled, which is precisely the state the author is checking.
    * `:content_components` — the component names the site's stored content uses: what a template
      that draws content names. `[]` unless given.
  """
  @spec for_site(String.t(), keyword()) :: result()
  def for_site(site_name, opts \\ []) do
    %{dirs: dirs, roots: roots, content: content} = sources(site_name, opts)

    case walk(roots, dirs, content) do
      {:ok, %{components: components, scanned: scanned, resolved: resolved}} ->
        # The roots are part of the ANSWER, not only a source of edges: a page's own markup carries
        # classes, and so does a layout's.
        reached = Enum.sort(Enum.uniq(roots ++ components))

        %{
          components: reached |> component_names(dirs) |> Enum.sort(),
          templates: reached,
          scanned: scanned,
          dynamic: [],
          resolved: resolved
        }

      {:dynamic, offenders, _known} ->
        Logger.warning(
          "[CssClosure] #{site_name}: #{length(offenders)} template(s) name a component the walk " <>
            "cannot resolve, so every component will be scanned: #{Enum.join(offenders, ", ")}"
        )

        :unbounded
    end
  end

  @typedoc """
  A component the walk reached: its name, and the `site` a `<.component>` tag names to draw it — the
  site's own name for a component of its own, `"Global"` for a global one.
  """
  @type reached :: %{name: String.t(), site: String.t()}

  @doc """
  Every component the walk is sure a site reaches, in whichever scope each was found, and whether
  that is all of them.

  The same walk as `for_site/2`, with the same options. Where `for_site/2` answers `:unbounded`,
  this still answers what the walk did reach, with `complete?: false`: a reference it cannot
  resolve may name more. A stylesheet cannot be built from that, since a component it leaves out
  renders unstyled; a caller that only needs what is certainly reached can.

      iex> CssClosure.reached_components("localhost")
      %{complete?: true, components: [%{name: "chelekom-alert", site: "Global"}]}
  """
  @spec reached_components(String.t(), keyword()) :: %{
          complete?: boolean(),
          components: [reached()]
        }
  def reached_components(site_name, opts \\ []) do
    %{root: root, dirs: dirs, roots: roots, content: content} = sources(site_name, opts)

    {complete?, components} =
      case walk(roots, dirs, content) do
        {:ok, %{components: components}} -> {true, components}
        {:dynamic, _offenders, components} -> {false, components}
      end

    %{
      complete?: complete?,
      components:
        components
        |> Enum.filter(&(Path.dirname(&1) in dirs))
        |> Enum.map(&%{name: name_of(&1), site: scope_of(&1, root)})
        |> Enum.uniq()
        |> Enum.sort_by(&{&1.site, &1.name})
    }
  end

  # WHERE A NAME IS LOOKED UP, IN ORDER. A site-scoped component shadows a global one of the same
  # name — that is how an install overrides a kit — so the site's directories are searched first.
  defp sources(site_name, opts) do
    root = Keyword.get_lazy(opts, :runtime_dir, &default_runtime_dir/0)
    scopes = [site_name | Keyword.get(opts, :extra_scopes, [])]
    dirs = Enum.map(scopes ++ [@global], &component_dir(Path.join(root, &1)))

    content =
      opts
      |> Keyword.get(:content_components, [])
      |> Enum.map(&resolve(&1, dirs))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    %{
      root: root,
      dirs: dirs,
      roots: Keyword.get_lazy(opts, :roots, fn -> entry_templates(root, scopes) end),
      content: content
    }
  end

  # `<root>/<scope>/component/<name>.template`: the scope directory is the site's name, or
  # `__global__` for a global component, whose tag names the site `"Global"`.
  defp scope_of(path, root) do
    case path |> Path.relative_to(root) |> Path.split() do
      [@global | _rest] -> "Global"
      [scope | _rest] -> scope
    end
  end

  @doc """
  The pages and error pages of `scopes` — the roots a bare directory tree can work out for itself.
  """
  @spec entry_templates(String.t(), [String.t()]) :: [String.t()]
  def entry_templates(runtime_dir, scopes) do
    for scope <- scopes,
        kind <- @entry_kinds,
        template <- templates_in(Path.join([runtime_dir, scope, kind])),
        do: template
  end

  @doc """
  Every global component, for callers that need the fallback set.
  """
  @spec all_components(keyword()) :: [String.t()]
  def all_components(opts \\ []) do
    opts
    |> Keyword.get_lazy(:runtime_dir, &default_runtime_dir/0)
    |> Path.join(@global)
    |> component_dir()
    |> templates_in()
    |> Enum.map(&name_of/1)
    |> Enum.sort()
  end

  @doc """
  The runtime template tree the compiler writes to.
  """
  @spec default_runtime_dir() :: String.t()
  def default_runtime_dir do
    MishkaCmsCore.Runtime.Compilers.TailwindCompiler.temp_dir()
    |> Path.join("runtime")
  end

  @doc """
  The lines a component's template file carries so `for_site/2` can follow
  `component_name={@name}` through `name`: one for each attribute the component's markup names a
  component through, that it declares, and that none of its code assigns or reads inside a helper.
  `""` when there are none.

      <%!-- css-closure attr=card default="doc-workspace-card" --%>

  The default is written when it is a non-empty string without a quote or a line break. Code that
  does not parse, or that assigns an attribute whose name it works out at runtime, marks nothing —
  see `MishkaCmsCore.Runtime.PageBuilder.CodeReads.assigned/1`.

  `component` is the component's row, or the same record decoded from a job, with string keys.
  `MishkaCmsCore.Runtime.Handlers.BootHandler.build_component_class_content/1` writes the lines into
  the file.
  """
  @spec attribute_marks(map()) :: String.t()
  def attribute_marks(component) do
    extra = field(component, :extra)
    clauses = extra |> field(:clauses) |> List.wrap()
    markup = [field(component, :template) | Enum.map(clauses, &field(&1, :template))]

    helpers = component |> field(:helpers) |> List.wrap() |> Enum.map(&field(&1, :code))
    bodies = [field(component, :body) | helpers] ++ Enum.map(clauses, &field(&1, :body))
    code = [field(extra, :prelude) | bodies]

    # A `{@name}` INSIDE A HELPER READS THAT FUNCTION'S ASSIGNS, which are whatever its caller built
    # — not necessarily the component's attributes at all.
    named = attribute_reads(markup) -- attribute_reads(code)

    with [_ | _] <- named,
         {:ok, assigned} <- assigned(field(extra, :prelude), bodies) do
      declared = declared(field(component, :attrs))

      named
      |> Enum.filter(&(Map.has_key?(declared, &1) and not MapSet.member?(assigned, &1)))
      |> Enum.map_join("\n", &mark(&1, Map.fetch!(declared, &1)))
    else
      _nothing_to_mark -> ""
    end
  end

  # THE WALK REPEATS UNTIL NOTHING NEW IS REACHED. One pass follows every edge out of what is reached
  # so far. A name an attribute takes is an edge only once a caller handing it over has been reached,
  # and the component it names may hand a name on in turn. Every set only grows, so it settles — and
  # a cycle, two components that render each other inside opposite branches, settles with it.
  defp walk(roots, dirs, content) do
    settle(%{roots: roots, dirs: dirs, content: content, read: %{}, components: [], names: %{}})
  end

  defp settle(state) do
    state = read(state.roots ++ state.components, state)
    edges = edges(state)
    names = names(edges, state)
    components = edges |> Enum.map(fn {_from, _how, to} -> to end) |> Enum.uniq() |> Enum.sort()

    case components == state.components and names == state.names do
      true -> settled(edges, state)
      false -> settle(%{state | components: components, names: names})
    end
  end

  # EACH FILE IS READ ONCE, however many passes reach it. SEEN IS PATHS, NOT NAMES: a name means
  # nothing on its own now that it can resolve into either scope; two scopes could hold the same name
  # and only one of them is the answer.
  defp read(paths, state) do
    Enum.reduce(paths, state, fn path, state ->
      case Map.has_key?(state.read, path) do
        true -> state
        false -> %{state | read: Map.put(state.read, path, summary(path, state.dirs))}
      end
    end)
  end

  defp summary(path, dirs) do
    case File.read(path) do
      {:ok, source} ->
        summarize(source, Path.dirname(path) in dirs, dirs)

      # A reference to a component that was uninstalled leaves a dangling name. It is not this
      # module's job to report that — the page will raise on render — and dropping it here is the
      # same as the old glob, which also had nothing to match.
      {:error, _reason} ->
        :missing
    end
  end

  defp summarize(source, component?, dirs) do
    tags = component_tags(source)
    calls = for {:ok, attributes} <- tags, found = call(attributes, dirs), found.target, do: found
    refs = for(%{target: {:attribute, name}} <- calls, do: name) |> Enum.uniq()

    %{
      named:
        @reference |> Regex.scan(source) |> Enum.map(fn [_all, name] -> name end) |> paths(dirs),
      calls: calls,
      refs: refs,
      # A page, a layout and an error page declare no attributes, so nothing they hold is a mark.
      marks: if(component?, do: marks(source), else: %{}),
      dynamic?:
        Enum.any?(calls, &(&1.target == :dynamic)) or
          length(Regex.scan(@expression_name, source)) > length(attribute_calls(calls)),
      opaque?: :error in tags or Regex.match?(@code_call, source),
      draws_content?: Regex.match?(@draws_content, source)
    }
  end

  defp attribute_calls(calls), do: Enum.filter(calls, &match?(%{target: {:attribute, _}}, &1))

  # `{from, how, to}`: `how` is the call that hands `to` its attributes, `:named` for a name written
  # outside a `<.component>` tag, or `:content` for a component drawn from stored content.
  defp edges(state) do
    for path <- state.roots ++ state.components,
        %{} = summary <- [Map.get(state.read, path)],
        edge <- edges_of(path, summary, state),
        do: edge
  end

  defp edges_of(path, summary, state) do
    named = for to <- summary.named, do: {path, :named, to}

    called =
      for call <- summary.calls, to <- targets(call.target, path, state), do: {path, call, to}

    drawn =
      case summary.draws_content? do
        true -> for to <- state.content, do: {path, :content, to}
        false -> []
      end

    named ++ called ++ drawn
  end

  defp targets({:path, to}, _from, _state), do: [to]

  defp targets({:attribute, name}, from, state),
    do: state.names |> Map.get({from, name}, []) |> paths(state.dirs)

  defp targets(:dynamic, _from, _state), do: []

  # WHAT EACH ATTRIBUTE CAN BE: its default, and every literal a reached call hands over for it. An
  # empty string names nothing.
  defp names(edges, state) do
    defaults =
      for path <- state.components,
          %{} = summary <- [Map.get(state.read, path)],
          {name, default} <- resolvable(summary),
          is_binary(default) and default != "",
          do: {{path, name}, default}

    handed =
      for {_from, %{given: given}, to} <- edges,
          %{} = summary <- [Map.get(state.read, to)],
          {name, _default} <- resolvable(summary),
          {:literal, value} <- [Map.get(given, name)],
          value != "",
          do: {{to, name}, value}

    (defaults ++ handed)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {key, values} -> {key, values |> Enum.uniq() |> Enum.sort()} end)
  end

  # The attributes a template names a component through and has a mark for, with their defaults.
  defp resolvable(summary) do
    for name <- summary.refs, Map.has_key?(summary.marks, name), do: {name, summary.marks[name]}
  end

  defp settled(edges, state) do
    case offenders(edges, state) do
      [] ->
        {:ok,
         %{
           components: state.components,
           scanned: Enum.count(state.read, fn {_path, summary} -> is_map(summary) end),
           resolved: resolved(state)
         }}

      offenders ->
        {:dynamic, offenders, state.components}
    end
  end

  defp offenders(edges, state) do
    reached =
      for path <- state.roots ++ state.components,
          %{} = summary <- [Map.get(state.read, path)],
          do: {path, summary}

    through_attributes? = Enum.any?(reached, fn {_path, summary} -> summary.refs != [] end)

    own = for {path, summary} <- reached, unresolved?(summary, through_attributes?), do: path

    # THE CALLER IS NAMED, not the component: the component is sound, and it is the call that hands
    # it a name nobody can read.
    handing =
      for {from, how, to} <- edges,
          %{} = summary <- [Map.get(state.read, to)],
          names = Enum.map(resolvable(summary), &elem(&1, 0)),
          names != [] and hands_unread?(how, names),
          do: from

    (own ++ handing) |> Enum.map(&Path.basename/1) |> Enum.uniq() |> Enum.sort()
  end

  defp unresolved?(summary, through_attributes?) do
    summary.dynamic? or
      Enum.any?(summary.refs, &(not Map.has_key?(summary.marks, &1))) or
      (summary.opaque? and through_attributes?)
  end

  defp hands_unread?(:named, _names), do: false
  defp hands_unread?(:content, _names), do: true
  defp hands_unread?(%{spread?: true}, _names), do: true

  defp hands_unread?(%{given: given}, names),
    do: Enum.any?(names, &match?({:expression, _source}, Map.get(given, &1)))

  defp resolved(state) do
    for path <- state.components,
        %{} = summary <- [Map.get(state.read, path)],
        {name, _default} <- resolvable(summary),
        do: %{
          component: name_of(path),
          attribute: name,
          names: Map.get(state.names, {path, name}, [])
        }
  end

  defp paths(names, dirs) do
    names |> Enum.map(&resolve(&1, dirs)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  # FIRST HIT WINS, and `dirs` arrives in shadowing order — the site's own component directories
  # before the global one.
  defp resolve(name, dirs) do
    Enum.find_value(dirs, fn dir ->
      path = Path.join(dir, name <> ".template")
      if File.exists?(path), do: path
    end)
  end

  # `templates` holds roots as well as components now, and a page is not a component. Membership of
  # a component directory is what separates them, and it is the same set the walk resolved against.
  defp component_names(templates, dirs) do
    templates
    |> Enum.filter(fn path -> Path.dirname(path) in dirs end)
    |> Enum.map(&name_of/1)
    |> Enum.uniq()
  end

  # A call reaches a component by its literal name, by an attribute it was handed, or by an
  # expression the walk cannot read — or names nothing, when the tag has no `component_name`.
  defp call(attributes, dirs) do
    given = for {name, value} <- attributes, into: %{}, do: {name, value}
    spread? = :spread in attributes

    %{
      target: target(Map.get(given, "component_name"), spread?, dirs),
      given: given,
      spread?: spread?
    }
  end

  defp target({:literal, name}, _spread?, dirs) do
    case resolve(name, dirs) do
      nil -> nil
      path -> {:path, path}
    end
  end

  defp target({:expression, source}, _spread?, _dirs) do
    case Regex.run(@read_attribute, source) do
      [_all, name] -> {:attribute, name}
      nil -> :dynamic
    end
  end

  # A TAG THAT SPREADS A MAP AND NAMES NOTHING names whatever that map holds.
  defp target(nil, true, _dirs), do: :dynamic
  defp target(_nothing, _spread?, _dirs), do: nil

  # Every `<.component …>` opening tag, as its attributes or `:error` when it cannot be read.
  defp component_tags(source) do
    for [{start, length}] <- Regex.scan(@component_tag, source, return: :index) do
      offset = start + length
      source |> binary_part(offset, byte_size(source) - offset) |> attributes([])
    end
  end

  # ONE OPENING TAG, attribute by attribute, up to the `>` that ends it — which is why an expression
  # is stepped over by its braces rather than matched by a pattern: `:if={@total > 0}` holds a `>`.
  defp attributes(<<char, rest::binary>>, found) when char in ~c" \t\r\n",
    do: attributes(rest, found)

  defp attributes("/>" <> _rest, found), do: {:ok, found}
  defp attributes(">" <> _rest, found), do: {:ok, found}

  defp attributes("{" <> rest, found) do
    case expression(rest) do
      {:ok, _source, rest} -> attributes(rest, [:spread | found])
      :error -> :error
    end
  end

  defp attributes(source, found) do
    case Regex.run(@attribute_name, source) do
      [name] ->
        size = byte_size(name)

        source
        |> binary_part(size, byte_size(source) - size)
        |> String.trim_leading()
        |> value(name, found)

      nil ->
        :error
    end
  end

  defp value("=" <> rest, name, found), do: rest |> String.trim_leading() |> given(name, found)
  defp value(rest, name, found), do: attributes(rest, [{name, :bare} | found])

  defp given("\"" <> rest, name, found), do: quoted(rest, "\"", name, found)
  defp given("'" <> rest, name, found), do: quoted(rest, "'", name, found)

  defp given("{" <> rest, name, found) do
    case expression(rest) do
      {:ok, source, rest} -> attributes(rest, [{name, {:expression, source}} | found])
      :error -> :error
    end
  end

  defp given(_unreadable, _name, _found), do: :error

  defp quoted(rest, delimiter, name, found) do
    case :binary.split(rest, delimiter) do
      [value, rest] -> attributes(rest, [{name, {:literal, value}} | found])
      [_unterminated] -> :error
    end
  end

  defp expression(source) do
    case closing(source, 0, 0) do
      {:ok, at} ->
        {:ok, binary_part(source, 0, at), binary_part(source, at + 1, byte_size(source) - at - 1)}

      :error ->
        :error
    end
  end

  # WHERE AN EXPRESSION'S BRACES CLOSE, in bytes. A string is stepped over whole, interpolations and
  # all, so a brace inside one counts for nothing.
  defp closing(<<"}", _rest::binary>>, 0, at), do: {:ok, at}
  defp closing(<<"}", rest::binary>>, depth, at), do: closing(rest, depth - 1, at + 1)
  defp closing(<<"{", rest::binary>>, depth, at), do: closing(rest, depth + 1, at + 1)

  defp closing(<<delimiter, rest::binary>>, depth, at) when delimiter in ~c"\"'" do
    case string_end(rest, delimiter, 0) do
      {:ok, size} ->
        closing(binary_part(rest, size, byte_size(rest) - size), depth, at + 1 + size)

      :error ->
        :error
    end
  end

  defp closing(<<_char, rest::binary>>, depth, at), do: closing(rest, depth, at + 1)
  defp closing(<<>>, _depth, _at), do: :error

  defp string_end(<<"\\", _escaped, rest::binary>>, delimiter, at),
    do: string_end(rest, delimiter, at + 2)

  defp string_end(<<"\#{", rest::binary>>, delimiter, at) do
    case closing(rest, 0, 0) do
      {:ok, inner} ->
        rest
        |> binary_part(inner + 1, byte_size(rest) - inner - 1)
        |> string_end(delimiter, at + 3 + inner)

      :error ->
        :error
    end
  end

  defp string_end(<<delimiter, _rest::binary>>, delimiter, at), do: {:ok, at + 1}
  defp string_end(<<_char, rest::binary>>, delimiter, at), do: string_end(rest, delimiter, at + 1)
  defp string_end(<<>>, _delimiter, _at), do: :error

  defp marks(source) do
    for match <- Regex.scan(@mark, source), into: %{} do
      case match do
        [_all, name, default] -> {name, default}
        [_all, name] -> {name, nil}
      end
    end
  end

  defp attribute_reads(sources) do
    for source <- sources,
        is_binary(source),
        [_all, name] <- Regex.scan(@named_through, source),
        uniq: true,
        do: name
  end

  # A HELPER IS A FUNCTION BODY, compiled inside `def … do … end`, so a body-level `rescue` is legal
  # in one and is read the same way here. The prelude is module-level code and is read as it is.
  defp assigned(prelude, bodies) do
    sources =
      for(source <- [prelude], is_binary(source), do: source) ++
        for(body <- bodies, is_binary(body), do: "def a do\n#{body}\nend")

    Enum.reduce_while(sources, {:ok, MapSet.new()}, fn source, {:ok, found} ->
      case CodeReads.assigned(source) do
        {:ok, written} -> {:cont, {:ok, MapSet.union(found, written)}}
        :unknown -> {:halt, :unknown}
      end
    end)
  end

  # A default that cannot be read off the declaration leaves the attribute unmarked.
  defp declared(attrs) do
    for attr <- List.wrap(attrs),
        name = field(attr, :name),
        is_binary(name),
        {:ok, default} <- [default(field(attr, :opts))],
        into: %{},
        do: {name, default}
  end

  defp default(nil), do: {:ok, nil}
  defp default(opts) when is_map(opts) or is_list(opts), do: {:ok, field(opts, :default)}
  defp default(_unreadable), do: :error

  defp mark(name, default) when is_binary(default) and default != "" do
    case String.contains?(default, ["\"", "\n", "\r"]) do
      true -> "<%!-- css-closure attr=#{name} --%>"
      false -> ~s|<%!-- css-closure attr=#{name} default="#{default}" --%>|
    end
  end

  defp mark(name, _no_default), do: "<%!-- css-closure attr=#{name} --%>"

  # Boot reads Ash structs, the compile worker the same record decoded from a job with string keys,
  # and an attribute's `opts` may be a keyword list.
  defp field(%{} = map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field([{_key, _value} | _rest] = list, key) do
    case List.keyfind(list, key, 0) || List.keyfind(list, Atom.to_string(key), 0) do
      {_key, value} -> value
      nil -> nil
    end
  end

  defp field(_other, _key), do: nil

  defp component_dir(scope_dir), do: Path.join(scope_dir, "component")

  defp name_of(path), do: path |> Path.basename() |> Path.rootname()

  defp templates_in(dir) do
    dir
    |> Path.join("**/*.template")
    |> Path.wildcard()
  end
end
