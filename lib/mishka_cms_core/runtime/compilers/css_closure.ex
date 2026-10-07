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

  ## When the answer is "everything"

  `<.component component_name={@name}>` names a component the compiler cannot know, so any template
  containing one makes the closure unsound and `for_site/1` returns `:unbounded`. Callers must
  fall back to globbing the whole directory. This is the whole safety story: an under-approximated
  closure means a component renders with no CSS at all, which is worse than a large stylesheet, and
  it would show up in production rather than in a build.

  No such reference exists in the CMS's own output today — the builder always writes the literal
  form — but a hand-written template can contain one, and it must degrade to correct-and-large
  rather than small-and-broken.

  ## Components named in stored content

  A template that draws stored content — `<.rich_content …/>` — reaches the components the
  content's markers name, which no template shows (`MishkaCmsCore.Runtime.ContentComponents`). The
  caller passes those names as `:content_components`, and such a template names exactly them, each
  resolved as a `component_name="…"` is. A site where nothing reached draws content reaches none of
  them.

  ## Usage

      iex> CssClosure.for_site("localhost")
      %{components: ["chelekom-alert", "chelekom-icon"], templates: [...], scanned: 8, dynamic: []}

  See `MishkaCmsCore.Runtime.Compilers.TailwindCompiler`, which turns the result into `@source`
  lines, and `Mix.Tasks.Mishka.Css.Closure`, which prints it.
  """

  require Logger

  @global "__global__"

  # A visitor asks for one of these by URL; nothing has to name them for them to render.
  @entry_kinds ["page", "error"]

  @typedoc """
  Everything a site's stylesheet has to be built from, or `:unbounded` when a dynamic reference
  makes the walk unsound.

  `components` are the reachable component names, for a reader. `templates` are the resolved paths
  of EVERYTHING that must be scanned — the roots, the layouts they use and the components they
  reach — because a name is not enough to point a compiler at a file: it may resolve into the
  site's own component directory or into the global one, and only the walk knows which.
  """
  @type result ::
          %{
            components: [String.t()],
            templates: [String.t()],
            scanned: non_neg_integer(),
            dynamic: [String.t()]
          }
          | :unbounded

  @doc """
  Walks a site's roots and returns every template its stylesheet has to be built from.

  A SITE'S OWN COMPONENTS ARE WALKED, NOT ASSUMED. They used to be roots: every template under the
  site's directory seeded the walk, so all of them were reachable by definition and all of them were
  scanned. On a real install that is 176 components of which the pages reference a handful, and the
  rest contributed their classes to the stylesheet every visitor downloads.

  `:unbounded` means a template names a component through an expression; the caller must scan every
  component instead.

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
    root = Keyword.get_lazy(opts, :runtime_dir, &default_runtime_dir/0)
    scopes = [site_name | Keyword.get(opts, :extra_scopes, [])]

    # WHERE A NAME IS LOOKED UP, IN ORDER. A site-scoped component shadows a global one of the same
    # name — that is how an install overrides a kit — so the site's directories are searched first.
    dirs = Enum.map(scopes ++ [@global], &component_dir(Path.join(root, &1)))

    roots = Keyword.get_lazy(opts, :roots, fn -> entry_templates(root, scopes) end)

    case walk(roots, dirs, Keyword.get(opts, :content_components, [])) do
      {:ok, templates, scanned} ->
        # The roots are part of the ANSWER, not only a source of edges: a page's own markup carries
        # classes, and so does a layout's.
        reached = Enum.sort(Enum.uniq(roots ++ templates))

        %{
          components: reached |> component_names(dirs) |> Enum.sort(),
          templates: reached,
          scanned: scanned,
          dynamic: []
        }

      {:dynamic, offenders} ->
        Logger.warning(
          "[CssClosure] #{site_name}: #{length(offenders)} template(s) name a component through " <>
            "an expression, so every component will be scanned: #{Enum.join(offenders, ", ")}"
        )

        :unbounded
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

  # Breadth-first over `component_name="…"` edges. `seen` is the answer being accumulated and also
  # the visited set, which is what stops a cycle: two components that render each other inside
  # opposite branches are legal and would otherwise loop forever.
  defp walk(roots, dirs, content) do
    Enum.reduce_while(roots, {:ok, MapSet.new(), 0}, fn path, {:ok, seen, scanned} ->
      case visit([path], dirs, content, seen, scanned) do
        {:ok, seen, scanned} -> {:cont, {:ok, seen, scanned}}
        {:dynamic, _offenders} = halt -> {:halt, halt}
      end
    end)
    |> case do
      {:ok, seen, scanned} -> {:ok, MapSet.to_list(seen), scanned}
      other -> other
    end
  end

  defp visit([], _dirs, _content, seen, scanned), do: {:ok, seen, scanned}

  defp visit([path | rest], dirs, content, seen, scanned) do
    case File.read(path) do
      {:ok, source} ->
        case dynamic_reference?(source) do
          true ->
            {:dynamic, [Path.basename(path)]}

          false ->
            {next, seen} =
              source
              |> references(content)
              |> Enum.reduce({[], seen}, fn name, {queue, seen} ->
                case resolve(name, dirs) do
                  nil -> {queue, seen}
                  template -> enqueue(template, queue, seen)
                end
              end)

            visit(next ++ rest, dirs, content, seen, scanned + 1)
        end

      # A reference to a component that was uninstalled leaves a dangling name. It is not this
      # module's job to report that — the page will raise on render — and dropping it here is the
      # same as the old glob, which also had nothing to match.
      {:error, _reason} ->
        visit(rest, dirs, content, seen, scanned)
    end
  end

  # SEEN IS PATHS, NOT NAMES. A name means nothing on its own now that it can resolve into either
  # scope; two scopes could hold the same name and only one of them is the answer.
  defp enqueue(template, queue, seen) do
    case MapSet.member?(seen, template) do
      true -> {queue, seen}
      false -> {[template | queue], MapSet.put(seen, template)}
    end
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

  @reference ~r/component_name="([^"]+)"/
  @dynamic ~r/component_name=\{/
  @draws_content ~r/<\.rich_content\b/

  defp references(source, content) do
    named = @reference |> Regex.scan(source) |> Enum.map(fn [_all, name] -> name end)

    case Regex.match?(@draws_content, source) do
      true -> Enum.uniq(named ++ content)
      false -> Enum.uniq(named)
    end
  end

  defp dynamic_reference?(source), do: Regex.match?(@dynamic, source)

  defp component_dir(scope_dir), do: Path.join(scope_dir, "component")

  defp name_of(path), do: path |> Path.basename() |> Path.rootname()

  defp templates_in(dir) do
    dir
    |> Path.join("**/*.template")
    |> Path.wildcard()
  end
end
