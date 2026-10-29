# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.ComponentCopy do
  @moduledoc """
  A new component made from an existing one — the inspector modal's Duplicate.

  The copy is written through the resource's own `:master_create` or `:create`, chosen by the actor:
  `:master_create` for one with no site, `:create` in the actor's site. Nothing is
  inserted around them, so a copy is validated, signed, versioned, broadcast and compiled exactly
  like a component somebody typed in — and refused the same way: to an actor who may not write the
  component, and, for one carrying `helpers`, while the deployment's `:page_code` switch is off.

  ## What a copy keeps, and what it does not

  Every attribute the create action accepts is carried over, read from the action rather than listed
  here, so a field added to the resource is copied without anyone remembering this module. Five
  things are not the source's to pass on:

    * **The name.** `copy_name/1` — `<name>-copy-<4 characters>`.
    * **The kit.** `extra.ui_kit`, `extra.ui_kit_version` and `extra.ui_kit_digest` go, and
      `extra.copied_from` names the source instead. All three are one stamp —
      `MishkaCmsCore.Runtime.Handlers.UiKitUpgrade` writes them together and reads them together —
      and a copy that kept the fingerprint would be claiming to be what a kit installed. A copy of
      `chelekom-button` still starts with `chelekom-`, and
      `MishkaCmsCore.Runtime.Handlers.UiKitHandler` purges by that prefix on an uninstall or a
      `cleanup: true` reinstall — through `:master_permanent_destroy`, which leaves no archive and
      no version. `copied_from` is what it reads to leave a user's copy alone.
    * **`required`.** It says the CMS cannot run without the component, which is true of the kit's
      icon and of nobody's copy of it.
    * **`precompile`.** A copy is built by the first render that names it, not at every boot.
    * **Its elements' classes.** See below.

  ## A copy stays where its source is

  A master copies any row into the source's own scope: a global row makes a global copy, a site's
  row a copy in that site. A site copies only its own rows. A shared row copied into a site would be
  a fork its examples cannot find — they say `site="Global"` — so that is refused rather than
  guessed at.

  ## It names itself

  A component's examples are real invocations, `<.component component_name="chelekom-card" …/>`,
  and so is the occasional template that renders itself. Copied verbatim, the copy's Preview tab and
  the builder's Examples modal would draw the ORIGINAL. Every exact `component_name="<source>"` in
  the template, the body, the examples and anything under `extra` is rewritten to the copy's name.
  The closing quote is part of the match, so `chelekom-button-group` is not a reference to
  `chelekom-button`; a computed `component_name={@name}` is not rewritten.

  ## Its elements are its own

  Every minted `pb-xxxxxxxx` class in the copied text is swapped for a fresh one and the source's
  CSS for those classes is written under the new ones in the copy's own row — the shared
  `MishkaCmsCore.Runtime.Authoring.ElementScopes`, which says what a kept class costs.
  """

  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.Authoring.ElementScopes

  @marker "-copy-"
  @suffix_length 4
  @attempts 3

  # The resource and the database both refuse a name over 100 characters.
  @base_length 100 - byte_size(@marker) - @suffix_length

  # The builder's section for a component, which is what its element CSS row is named after.
  @section "component"
  @copy %{page_code: :copy}

  @doc """
  Copy `source` as `actor`, trying a fresh name when the last one was taken.

  `:names` is the candidates to try, in order; by default three from `copy_name/1`. Only a taken
  name moves on to the next one — any other refusal is returned as it came.

  Returns the resource's own `{:ok, copy}` / `{:error, error}`, or `{:error, :out_of_scope}` when
  the actor is a site and `source` is not that site's.
  """
  @spec duplicate(Component.t(), map() | nil, keyword()) ::
          {:ok, Component.t()} | {:error, term()}
  def duplicate(%Component{} = source, actor, opts \\ []) do
    opts
    |> Keyword.get_lazy(:names, fn ->
      Enum.map(1..@attempts, fn _ -> copy_name(source.name) end)
    end)
    |> attempt(source, actor)
  end

  @doc """
  `<name>-copy-<suffix>`: four lowercase base32 characters, the base cut so the whole stays within
  100 characters.

  Already in the form the resource's `slugify(:name)` stores, so the name the self-references are
  rewritten to is the name the row is saved under.
  """
  @spec copy_name(String.t()) :: String.t()
  def copy_name(name) do
    base = name |> Slug.slugify() |> to_string() |> String.slice(0, @base_length)
    Slug.slugify(base <> @marker <> suffix())
  end

  defp suffix do
    3
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(case: :lower, padding: false)
    |> binary_part(0, @suffix_length)
  end

  defp attempt([name | rest], source, actor),
    do: source |> create(name, actor) |> retry_when_taken(rest, source, actor)

  defp retry_when_taken({:error, error} = refused, rest, source, actor) do
    case rest != [] and name_taken?(error) do
      true -> attempt(rest, source, actor)
      false -> refused
    end
  end

  defp retry_when_taken(created, _rest, _source, _actor), do: created

  # A TAKEN NAME IS THE ONE REFUSAL ANOTHER NAME ANSWERS. The data layer reports
  # `unique_name_per_site` as an error on `:name` marked `constraint_type: :unique`; anything else —
  # the code gate, a template that no longer compiles — would be refused again under every name.
  defp name_taken?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &unique_name_violation?/1)

  defp name_taken?(_error), do: false

  defp unique_name_violation?(%Ash.Error.Changes.InvalidAttribute{field: :name} = error),
    do: Keyword.get(error.private_vars || [], :constraint_type) == :unique

  defp unique_name_violation?(_error), do: false

  # THE ACTOR GOES ON THE CHANGESET, NOT ONLY ON THE CALL: `Validations.CodeChange` runs while the
  # changeset is built and asks who is writing. A copy
  # writes its source's template, which nobody typed, so only its helpers are stopped while the
  # deployment's `:page_code` switch is off.
  defp create(source, name, %{site_id: nil} = actor) do
    {attributes, scopes} = attributes(source, name)

    Component
    |> Ash.Changeset.for_create(
      :master_create,
      Map.put(attributes, :site_id, source.site_id),
      actor: actor,
      context: @copy
    )
    |> ElementScopes.carry_css(@section, source, scopes, actor)
    |> Ash.create(actor: actor)
  end

  defp create(%{site_id: site_id} = source, name, %{site_id: site_id} = actor)
       when is_binary(site_id) do
    {attributes, scopes} = attributes(source, name)

    Component
    |> Ash.Changeset.for_create(:create, attributes,
      tenant: site_id,
      actor: actor,
      context: @copy
    )
    |> ElementScopes.carry_css(@section, source, scopes, actor)
    |> Ash.create(actor: actor)
  end

  defp create(_source, _name, _actor), do: {:error, :out_of_scope}

  # THE NAME IS REWRITTEN BEFORE THE CLASSES ARE READ. A component may itself be called
  # `pb-deadbeef`, and its `component_name="pb-deadbeef"` is a name, not an element.
  defp attributes(source, name) do
    from = reference(source.name)
    to = reference(name)

    extra =
      (source.extra || %{})
      |> Map.drop(["ui_kit", "ui_kit_version", "ui_kit_digest"])
      |> Map.put("copied_from", source.id)

    {named, scopes} =
      [template: source.template, body: source.body, examples: source.examples, extra: extra]
      |> Map.new(fn {field, value} ->
        {field, ElementScopes.rewrite(value, &String.replace(&1, from, to))}
      end)
      |> ElementScopes.rescope()

    attributes =
      Component
      |> Ash.Resource.Info.action(:create)
      |> Map.fetch!(:accept)
      |> then(&Map.take(source, &1))
      |> Map.merge(%{name: name, required: false, precompile: false})
      |> Map.merge(named)

    {attributes, scopes}
  end

  defp reference(name), do: ~s(component_name="#{name}")
end
