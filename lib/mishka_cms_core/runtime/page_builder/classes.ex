defmodule MishkaCmsCore.Runtime.PageBuilder.Classes do
  @moduledoc """
  Named styles a site can reuse — style once, apply to twenty elements, change it in one place.

  ## Why this is not the style panel

  The inspector writes utilities ONTO an element. That is right for the one card that needs to be a
  little wider, and wrong for the twenty cards that are meant to look the same: making them match
  means repeating yourself twenty times, and changing them means finding all twenty again. What
  Bricks calls a global class is the missing half — a name you can put on many elements, holding the
  styling they share.

  ## What one compiles to

  A class is a name and a list of Tailwind utilities. All of a site's classes are written into ONE
  stylesheet row the CMS owns, regenerated whole on every change:

      @layer components {
        .card-shell { @apply rounded-xl bg-white p-6; }
      }

  Two decisions in that snippet, both load-bearing:

    * `@apply`, so a class is written in the same vocabulary as everything else in this editor. The
      row is `:custom`, which `MishkaCmsCore.Runtime.Compilers.TailwindCompiler` appends INTO the
      source Tailwind processes — not after it — so `@apply` resolves.
    * `@layer components`, so a per-element utility still wins. Without the layer, source order
      decides: the row is appended last, and `.card-shell`'s padding would quietly beat the `p-8`
      an author put on one card to make it the exception.

  ## One row, rewritten whole

  Not one row per class. A stylesheet row is a compile input and a versioned record; twenty of them
  for twenty classes would be twenty recompiles and twenty histories of something nobody thinks of
  as a document. The row is found by its reserved name, so it is recognisable in the Stylesheets
  admin — and editable there, at the cost of being rewritten the next time a class changes here.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler
  alias MishkaCmsCore.Runtime.Stylesheet

  require Ash.Query

  # WHAT THE BUILDER WRITES IT GENERATED: the stylesheet row is written by whoever may open a
  # builder, rather than by the stylesheet area alone. See `MishkaCmsCore.Runtime.Stylesheet`.
  @builder %{page_code: :builder}

  @row_name "builder-classes"
  @name_format ~r/^[a-z][a-z0-9-]{1,39}$/
  @utilities_limit 500

  @doc "The reserved stylesheet row all of a site's reusable classes live in."
  @spec row_name() :: String.t()
  def row_name, do: @row_name

  @doc """
  Every class this site has, newest last, as `%{name:, utilities:}`.

  Read back out of the compiled row rather than kept anywhere else: the stylesheet IS the record, so
  a class edited by hand on the Stylesheets page is still a class here.
  """
  @spec all(map() | nil, String.t() | nil) :: [%{name: String.t(), utilities: String.t()}]
  def all(actor, site_id) do
    case row(actor, site_id) do
      nil -> []
      %{content: content} -> parse(content)
    end
  end

  @doc """
  Adds a class or rewrites one, by name.

  A name has to be a plain CSS class — lowercase, digits and dashes — because it is written straight
  into a stylesheet, and because `.my class` and `.my<script>` are the two ways that goes wrong.
  Empty utilities delete the class rather than leaving a rule that does nothing. The class is
  compiled before it is stored, so what comes back on a typo is Tailwind's own sentence about it.
  """
  @spec put(map() | nil, String.t() | nil, String.t(), String.t()) ::
          {:ok, [map()]} | {:error, term()}
  def put(actor, site_id, name, utilities) do
    with {:ok, name} <- valid_name(name),
         {:ok, utilities} <- valid_utilities(utilities),
         :ok <- compiles(keep(name, utilities), site_id) do
      actor
      |> all(site_id)
      |> rewritten(name, utilities)
      |> write(actor, site_id)
    end
  end

  @doc "Removes a class. The elements carrying it keep the name and simply stop being styled by it."
  @spec delete(map() | nil, String.t() | nil, String.t()) :: {:ok, [map()]} | {:error, term()}
  def delete(actor, site_id, name) do
    actor
    |> all(site_id)
    |> Enum.reject(&(&1.name == name))
    |> write(actor, site_id)
  end

  @doc """
  The CSS for a set of classes.

  Public because it is the whole contract with the compiler, and the one thing worth reading to
  understand what a class becomes.
  """
  @spec css([map()]) :: String.t()
  def css([]), do: ""

  def css(classes) do
    rules = Enum.map_join(classes, "\n", &"  .#{&1.name} { @apply #{&1.utilities}; }")

    "@layer components {\n" <> rules <> "\n}\n"
  end

  defp rewritten(classes, name, utilities) do
    classes
    |> Enum.reject(&(&1.name == name))
    |> then(&(&1 ++ keep(name, utilities)))
  end

  defp keep(_name, ""), do: []
  defp keep(name, utilities), do: [%{name: name, utilities: utilities}]

  # THE CLASS IS PROVED BEFORE IT IS STORED. Tailwind v4 answers `@apply` of a utility it does not
  # know with a non-zero exit, and that exit is the WHOLE stylesheet — this write and every later
  # page, component or stylesheet write too, since each recompile re-reads the stored row. On a
  # shared document the row is global, so one typo empties the base every site is built on and a
  # single `Logger.error` is the only trace.
  #
  # THE CANDIDATE ALONE, not the row it lands in. Tailwind resolves `@apply` a rule at a time and a
  # class cannot even name a sibling — `@apply card` is "Cannot apply unknown utility class `card`"
  # — so the row around it changes nothing about whether this class compiles. Checking the row
  # would instead let one already-broken class, saved before this check existed or typed on the
  # Stylesheets page, veto every unrelated save AND the empty box that deletes it.
  #
  # `delete/3` deliberately does NOT check, for the same reason: taking a bad class out is the
  # repair, and a check there would lock the door from the inside.
  defp compiles([], _site_id), do: :ok
  defp compiles(classes, site_id), do: TailwindCompiler.verify_css(css(classes), site_id)

  defp valid_name(name) when is_binary(name) do
    case String.trim(name) =~ @name_format do
      true ->
        {:ok, String.trim(name)}

      false ->
        {:error,
         gettext("A class name is lowercase letters, digits and dashes — like card-shell.")}
    end
  end

  defp valid_name(_name), do: {:error, gettext("A class needs a name.")}

  # NOT `Tokens.sane_value/1`'s reject list, which would refuse the utilities people actually write:
  # an arbitrary value carries brackets and parens — `bg-[url('/a.png')]`,
  # `grid-cols-[repeat(2,minmax(0,1fr))]`. What is refused is what `@apply #{utilities};` cannot
  # survive. A `}` closes the rule and everything after it is loose CSS on the whole site, which is
  # the escape `ElementCss.valid_body/1` refuses for the same reason. A `;` ends the `@apply`, so
  # `parse/1` reads back less than was stored and the next save silently drops the rest. The cap is
  # for a paste of a whole stylesheet into a one-line box; Tailwind decides the rest.
  defp valid_utilities(utilities) when is_binary(utilities) do
    trimmed = String.trim(utilities)

    cond do
      String.contains?(trimmed, ["{", "}", ";"]) ->
        {:error,
         gettext("Utilities are Tailwind class names — a { } or ; belongs in this element's CSS.")}

      String.length(trimmed) > @utilities_limit ->
        {:error,
         gettext("That is over %{limit} characters for one class. Split it in two.",
           limit: @utilities_limit
         )}

      true ->
        {:ok, trimmed}
    end
  end

  defp valid_utilities(nil), do: {:ok, ""}

  defp valid_utilities(_utilities),
    do: {:error, gettext("A class is a list of Tailwind utilities.")}

  # ONE ROW, REWRITTEN WHOLE. The parse below is its inverse, so what comes back out is what a
  # reader would see on the Stylesheets page.
  defp parse(content) do
    ~r/\.([a-z][a-z0-9-]*)\s*\{\s*@apply\s+([^;}]+);/
    |> Regex.scan(content || "")
    |> Enum.map(fn [_all, name, utilities] ->
      %{name: name, utilities: String.trim(utilities)}
    end)
  end

  defp write(classes, actor, site_id) do
    case {row(actor, site_id), classes} do
      {nil, []} -> {:ok, []}
      {nil, _some} -> create(actor, site_id, classes)
      {existing, _any} -> update(actor, existing, classes)
    end
  end

  # A MASTER NAMES THE SITE, A TENANT IS ONE. `master_create` refuses a tenant context and takes
  # `site_id` as an ordinary attribute; the tenant action does the opposite and forces the value. The
  # same split every `global? true` resource in this app makes.
  defp create(%{site_id: nil} = actor, site_id, classes) do
    Stylesheet
    |> Ash.Changeset.for_create(:master_create, Map.put(attrs(classes), :site_id, site_id),
      actor: actor,
      tenant: nil,
      context: @builder
    )
    |> Ash.create()
    |> saved(classes)
  end

  defp create(actor, site_id, classes) do
    Stylesheet
    |> Ash.Changeset.for_create(:create, attrs(classes),
      actor: actor,
      tenant: site_id,
      context: @builder
    )
    |> Ash.create()
    |> saved(classes)
  end

  defp attrs(classes) do
    %{
      name: @row_name,
      description: "Reusable classes, written by the page builder",
      content: content(classes),
      kind: :custom,
      format: :css,
      active: true
    }
  end

  defp update(%{site_id: nil} = actor, existing, classes) do
    existing
    |> Ash.Changeset.for_update(:master_update, %{content: content(classes)},
      actor: actor,
      tenant: nil,
      context: @builder
    )
    |> Ash.update()
    |> saved(classes)
  end

  defp update(actor, existing, classes) do
    existing
    |> Ash.Changeset.for_update(:update, %{content: content(classes)},
      actor: actor,
      tenant: existing.site_id,
      context: @builder
    )
    |> Ash.update()
    |> saved(classes)
  end

  # A stylesheet row must have content, and deleting the last class must not therefore fail. The
  # note is what the Stylesheets page shows for a row that is doing nothing yet, and `parse/1` finds
  # no classes in it.
  defp content(classes) do
    case css(classes) do
      "" -> "/* No reusable classes on this site yet. */\n"
      css -> css
    end
  end

  defp saved({:ok, _record}, classes), do: {:ok, classes}
  defp saved({:error, reason}, _classes), do: {:error, reason}

  # SCOPED, NOT CAPPED. The reserved name is the same constant on every site and the identity is
  # `[:name, :site_id]`, so the name alone matches one row per site. Asking for one row before
  # saying which site it is for hands back whichever rows the read reached — a capped page answers
  # with two, so a third site is simply invisible — and the site's own row then reads as absent: the
  # panel empties, the next save collides with the row that is there, and a delete writes nothing.
  #
  # THE MASTER READ IS THE ONE THAT HAS TO BE TOLD: `:master_read` bypasses multitenancy, so every
  # site's row is a candidate. A tenant's read is already scoped — Ash adds `site_id == ^tenant`,
  # and `global? true` only makes the tenant optional rather than folding the globals in — so there
  # the filter restates what Ash applied anyway. It is written once, before the branch, because the
  # globals are a scope too: theirs is `is_nil(site_id)`, and `site_id == ^nil` is a comparison Ash
  # warns about precisely because it can never match.
  defp row(actor, site_id) do
    Stylesheet
    |> Ash.Query.filter(name == ^@row_name)
    |> scoped(site_id)
    |> read(actor, site_id)
  end

  defp scoped(query, nil), do: Ash.Query.filter(query, is_nil(site_id))
  defp scoped(query, site_id), do: Ash.Query.filter(query, site_id == ^site_id)

  defp read(query, %{site_id: nil} = actor, _site_id) do
    query
    |> Ash.Query.for_read(:master_read, %{}, actor: actor)
    |> Ash.read()
    |> first()
  end

  defp read(query, actor, site_id) do
    query
    |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: site_id)
    |> Ash.read()
    |> first()
  end

  # The identity leaves a scoped query at most one row to answer with. Pagination is on for the
  # master read, so what comes back is a page rather than a list.
  defp first({:ok, %Ash.Page.Offset{results: rows}}), do: first({:ok, rows})
  defp first({:ok, [row | _rest]}), do: row
  defp first({:ok, []}), do: nil
  defp first({:error, _reason}), do: nil
end
