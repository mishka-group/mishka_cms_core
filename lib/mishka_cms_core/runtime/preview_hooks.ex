defmodule MishkaCmsCore.Runtime.PreviewHooks do
  @moduledoc """
  Makes a hook named for one site work while another site's draft is being previewed.

  ## The problem this solves

  A runtime hook is registered in the browser under its site's prefix — `LocalhostClipboard`,
  `ApiMishkaToolsClipboard` — because two sites may both have a `clipboard` and they are different
  code. `MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler.browser_name/2` is the one rule that
  decides that name.

  So a template that names `LocalhostClipboard` works on the localhost site and nowhere else. On a
  published page that is correct and stays correct: the page belongs to a site, and a hook it cannot
  have is a hook it does not get.

  A DRAFT PREVIEW is a different situation. It is an editing tool, reached by an unguessable token,
  and it exists to answer "what does this look like and does it work". A master administering three
  sites opens the same page on each of them, and the one that names another site's hook answers with
  a button that draws and does nothing — `unknown hook found for "LocalhostClipboard"` in the
  console and no other sign. The preview is where that is least useful, because it is the one place
  the author is asking the question.

  ## What it does

  Reads the name the author wrote as what it is — a PREFIX and a base — and points it at the base's
  hook on the site being previewed. `LocalhostClipboard` previewed under `api-mishka-tools` becomes
  `ApiMishkaToolsClipboard`: that site's own `clipboard`, its own code, nothing borrowed.

  ## What it does not do

  It never serves another site's code, so it moves nothing across a tenant boundary — the bundle is
  still only this site's hooks and the global ones. It never invents a hook: a name whose base this
  site does not have is left exactly as written, and behaves in the preview as it will in production.
  And it touches nothing outside the preview; the stored template is not rewritten.

  Parsed rather than pattern-matched. `phx-hook` is an attribute on an element, and finding it by
  searching text would match it inside a string, a comment or an unrelated attribute. The parse only
  decides WHICH names change; each is then changed where it is written as that attribute, and every
  other byte of the template is the author's — writing the parsed tree back out re-ordered a
  component's classes and marked them `!`, which the preview's stylesheet, compiled from the stored
  template, has no rule for.
  """

  alias MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node

  @attribute "phx-hook"

  @doc """
  The template with every unresolvable hook name pointed at this site's hook of the same base.

  Returns the template unchanged when there is nothing to do, when the site is unknown, or when the
  template cannot be parsed — a preview that renders the author's markup is worth more than one that
  refuses over a hook name.
  """
  @spec resolve(String.t() | nil, map() | nil) :: String.t() | nil
  def resolve(template, site) when is_binary(template) do
    case names_for(site) do
      {[], _bases} -> template
      {registered, bases} -> rewrite(template, registered, bases)
    end
  end

  def resolve(template, _site), do: template

  # The names this site's browser bundle really registers, and the base of each — which is what an
  # unknown name has to be matched against.
  defp names_for(%{id: site_id, name: site_name}) do
    require Ash.Query

    hooks =
      MishkaCmsCore.Runtime.JsHook
      |> Ash.Query.for_read(:read_any)
      |> Ash.Query.filter(is_nil(site_id) or site_id == ^site_id)
      # `is_global` decides the prefix and is a CALCULATION — unloaded it reads as "not global", and
      # every global hook would come back under a name nothing registers.
      |> Ash.Query.load([:is_global])
      |> Ash.read!(authorize?: false, page: false)

    registered = MapSet.new(hooks, &JavaScriptCompiler.browser_name(&1, site_name))

    # Only this site's own hooks can stand in for a foreign name. A global already carries the name
    # every site uses, so a template naming one is not the case this exists for.
    bases =
      hooks
      |> Enum.reject(&(&1.site_id == nil))
      |> Enum.map(&{base_of(&1), JavaScriptCompiler.browser_name(&1, site_name)})
      # LONGEST FIRST, so `SubMenu` is not answered by `Menu` on a site that has both.
      |> Enum.sort_by(fn {base, _name} -> -String.length(base) end)

    {registered, bases}
  end

  defp names_for(_site), do: {[], []}

  defp base_of(hook),
    do: hook.name |> String.split("-") |> Enum.map(&String.capitalize/1) |> Enum.join("")

  defp rewrite(template, registered, bases) do
    case Tree.parse(template) do
      {:ok, tree} -> tree |> stand_ins(registered, bases) |> Enum.reduce(template, &retarget/2)
      _unparsed -> template
    end
  end

  defp stand_ins(tree, registered, bases) do
    tree
    |> Tree.walk()
    |> Enum.flat_map(fn node ->
      with name when is_binary(name) <- Node.attr_text(node, @attribute),
           false <- MapSet.member?(registered, name),
           replacement when is_binary(replacement) <- stand_in(name, bases) do
        [{name, replacement}]
      else
        _leave_it_alone -> []
      end
    end)
    |> Enum.uniq()
  end

  # Written as text — `phx-hook="Name"` or `'Name'` — which is the one form `Node.attr_text/2` reads.
  defp retarget({name, replacement}, template) do
    ~r/(#{@attribute}\s*=\s*["'])#{Regex.escape(name)}(["'])/
    |> Regex.replace(template, "\\g{1}#{replacement}\\g{2}")
  end

  # The author wrote `<Prefix><Base>`; this site's hook for that base is what they meant.
  defp stand_in(name, bases) do
    Enum.find_value(bases, fn {base, replacement} ->
      String.ends_with?(name, base) and name != base and replacement
    end)
  end
end
