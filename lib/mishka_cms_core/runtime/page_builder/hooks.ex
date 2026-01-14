defmodule MishkaCmsCore.Runtime.PageBuilder.Hooks do
  @moduledoc """
  The runtime JS hooks an element can be attached to, and the two attributes that attach it.

  ## Why a picker and not a code box

  `MishkaCmsCore.Runtime.PageBuilder.Interactions` covers what a page usually wants — toggle a class,
  show something, hide something — with no code at any point. What it cannot do is anything else, and
  the answer to "anything else" is a hook: real JavaScript, written on the JS hooks page, compiled
  into the site's bundle and registered with LiveView.

  Writing one stays there. This only *selects* from what is already in the bundle, which is the whole
  reason it needs no gate of its own: it grants nothing the actor did not already have, it removes
  the step where they hand-type `phx-hook` into Advanced and get the capitalisation wrong.

  ## The two attributes

  `phx-hook` names the hook, and LiveView **requires a unique DOM id** on any element carrying one —
  a hook on an element with no id silently never mounts, which is a bad afternoon. So attaching one
  mints an id when the element has none, and the picker says so rather than leaving it to be
  discovered.

  The name written is `JavaScriptCompiler.browser_name/2`'s, not the row's: a global hook called
  `collapse` registers as `GlobalCollapse` and a site's own as `<Site>Collapse`. Asking the compiler
  is what keeps the two from drifting.
  """

  alias MishkaCmsCore.Builder.Events
  alias MishkaCmsCore.Runtime.JsHook

  require Ash.Query

  @doc """
  Every hook this site can attach, its own and the globals, as `%{name:, hook:, description:}`.

  `name` is what goes in `phx-hook`; `hook` is the row's own name, which is what the JS hooks page
  calls it and therefore what a reader is looking for.
  """
  @spec available(map() | nil, String.t() | nil, String.t() | nil) :: [map()]
  def available(actor, site_id, site_name) do
    actor
    |> rows(site_id)
    |> Enum.filter(& &1.active)
    |> Enum.filter(&offerable?(&1, site_name))
    |> Enum.map(&entry(&1, site_name))
    |> Enum.sort_by(& &1.name)
  end

  # A SITE'S HOOK NEEDS THE SITE'S NAME, because that is what its browser name is built from — and a
  # GLOBAL document has no site to take one from. Offering one anyway asked the compiler to prefix a
  # name with nothing, which raised on the way into the editor and took the whole component section
  # down with it.
  #
  # Leaving them out is also the honest answer: a global component is used on every site, so a hook
  # belonging to one of them could not be relied on there.
  defp offerable?(row, nil), do: is_nil(row.site_id)
  defp offerable?(_row, _site_name), do: true

  defp entry(row, _site_name) do
    %{
      name: row.name,
      hook: row.name,
      description: row.description,
      global?: is_nil(row.site_id)
    }
  end

  @doc """
  Every hook the picker offers: this site's, the globals, and whatever a plugin contributes through
  `builder:js_hooks`.

  ONE LIST FOR THE PICKER AND FOR `known?/4`, which is the whole point of naming it — the same
  `Interactions.registry/0` and `Conditions.registry/0` are. The picker read the appended list and
  `known?/4` read `available/3`, so every hook an extension contributed was offered and then refused
  on Apply.
  """
  @spec registry(map() | nil, String.t() | nil, String.t() | nil) :: [map()]
  def registry(actor, site_id, site_name),
    do: Events.collect_appended(:js_hooks, available(actor, site_id, site_name))

  @doc """
  Whether `name` is a hook the picker is entitled to write.

  The picker writes the name into the document, so a stale option — a hook archived in another tab —
  must not be written as though it existed.
  """
  @spec known?(map() | nil, String.t() | nil, String.t() | nil, String.t()) :: boolean()
  def known?(actor, site_id, site_name, name),
    do: actor |> registry(site_id, site_name) |> Enum.any?(&(&1.name == name))

  # `is_global` IS A CALCULATION AND MUST BE LOADED. `JavaScriptCompiler.browser_name/2` branches on
  # it, and an unloaded calculation is `%Ash.NotLoaded{}` — which is truthy, so every hook came back
  # named `Global…`. A site's own hook would then be written into `phx-hook` under a name nothing
  # registers, and would silently never mount. Caught in the browser, where two rows called
  # `clipboard` both offered `GlobalClipboard`.
  #
  # A DOCUMENT WITH NO SITE HAS ONLY THE GLOBALS TO BE OFFERED, whoever is reading — which is the
  # same answer `offerable?/2` arrives at, and saying it here keeps the untenanted read below from
  # being asked for "every site's".
  defp rows(actor, nil), do: globals(actor)

  # A MASTER READS EVERY SITE'S, so the site has to be said in the QUERY. Picking it out of what came
  # back only works if everything came back, and `:master_read` is paginated: past the page's twenty
  # rows the site's own hooks were dropped, the picker went short, and `known?/4` then refused a name
  # that was perfectly real. `:read_any` is what makes pagination optional — `:master_read` raises on
  # `page: false` — and it is the read `Tokens` already makes for the same reason. The same scoping
  # `Classes` and `ElementCss` do.
  defp rows(%{site_id: nil} = actor, site_id) do
    JsHook
    |> Ash.Query.load(:is_global)
    |> Ash.Query.filter(is_nil(site_id) or site_id == ^site_id)
    |> Ash.Query.for_read(:read_any, %{}, actor: actor)
    |> Ash.read(page: false)
    |> listed()
  end

  # A TENANT'S OWN ROWS ARE SCOPED BY ASH, and `global? true` only makes the tenant optional — it
  # does not fold the globals in — so they are fetched on their own. WITHOUT a tenant, which is the
  # part that was wrong: Ash adds `site_id == ^tenant` to any read carrying one, so a tenanted read
  # filtered to `is_nil(site_id)` asked for two things at once and could only ever answer with
  # nothing. A site admin was never offered a single global hook, whatever `available/3` promised.
  #
  # The two are disjoint by construction — one read is `site_id == ^tenant`, the other
  # `is_nil(site_id)` — so there is nothing to de-duplicate.
  defp rows(actor, site_id) do
    own =
      JsHook
      |> Ash.Query.load(:is_global)
      |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: site_id)
      |> Ash.read()
      |> listed()

    own ++ globals(actor)
  end

  defp globals(actor) do
    JsHook
    |> Ash.Query.load(:is_global)
    |> Ash.Query.filter(is_nil(site_id))
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.read()
    |> listed()
  end

  defp listed({:ok, %Ash.Page.Offset{results: rows}}), do: rows
  defp listed({:ok, rows}) when is_list(rows), do: rows
  defp listed(_error), do: []
end
