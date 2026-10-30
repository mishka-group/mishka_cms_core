# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.CodeChange do
  @moduledoc """
  Refuses code written by hand when this deployment has turned it off, and Elixir from a write that
  names no actor.

  Who may write a document, its code included, is the resource's policy: the document's own runtime
  area or `admin:<surface>:code`. What this enforces at the action boundary is the deployment switch
  of `MishkaCmsCore.Runtime.Authoring.CodeAccess` — `config :mishka_cms_core, :page_code, :off`
  stops code the server runs for everybody, master included. A form, the admin JSON:API, a script
  and the builder all pass through here.

  ## What counts as code

    * **Elixir** — `events`, `infos` and `helpers`, whichever the resource declares. Code has to
      APPEAR to count: a create sets these to `[]`, and removing code is always allowed.
    * **HEEx typed by hand** — `template`, `root_layout_template`, and each template of an error
      page's `error_pages` entries. A template that changed counts, except an empty document's
      starter markup (`MishkaCmsCore.Runtime.Authoring.PageStarter.blank/1`).

  ## Who is writing, read from the changeset context

    * `page_code: :package` — a package installing what it ships (a UI kit, starter content, an
      extension's sample pages, the dev generator). Nothing is checked.
    * `page_code: :publish` — a draft being published onto its live record. Nothing is checked: the
      draft was checked when it was written.
    * `page_code: :fork` — the builder writing a draft: its source's Elixir, copied unchanged, and
      the template the builder generated. Nothing is checked.
    * `page_code: :builder` — the builder writing the template it generated from its tree. The
      template is not typed; Elixir still counts.
    * `page_code: :copy` — a record copied whole. Its template is not typed; Elixir still counts.

  A write with no actor is the system's own — a seed, a fixture, a background job. Its templates are
  let through, and its Elixir is refused.
  """

  use Ash.Resource.Validation

  alias MishkaCmsCore.Runtime.Authoring.CodeAccess
  alias MishkaCmsCore.Runtime.Authoring.PageStarter

  @template_fields [:template, :root_layout_template]

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, context) do
    case Map.get(changeset.context, :page_code) do
      exempt when exempt in [:package, :publish, :fork] -> :ok
      origin -> check(changeset, origin, whose(context))
    end
  end

  defp check(changeset, origin, actor) do
    case {CodeAccess.enabled?(), actor} do
      {true, nil} -> refuse(elixir_gained(changeset))
      {true, _actor} -> :ok
      {false, _actor} -> refuse(elixir_gained(changeset) ++ typed(changeset, origin, actor))
    end
  end

  # The system's own write, a copy and the builder's generated template are not typed by hand.
  defp typed(_changeset, _origin, nil), do: []
  defp typed(_changeset, origin, _actor) when origin in [:builder, :copy], do: []
  defp typed(changeset, _origin, _actor), do: template_gained(changeset)

  # The error is attached to the attribute that carried the code, so a form puts it under the box the
  # author typed into rather than at the top of the page.
  defp refuse([]), do: :ok
  defp refuse([field | _rest]), do: {:error, field: field, message: CodeAccess.refusal()}

  # NOT `changing_attribute?/2`: these attributes default to `[]` and a create sets every default,
  # so the question is whether code APPEARED, not whether the field was touched.
  defp elixir_gained(changeset) do
    Enum.filter(CodeAccess.fields(), fn field ->
      declared?(changeset.resource, field) and gained_code?(changeset, field)
    end)
  end

  defp gained_code?(changeset, field) do
    now = entries(Ash.Changeset.get_attribute(changeset, field))

    now != [] and now != entries(Map.get(changeset.data, field))
  end

  defp entries(value) when is_list(value), do: value
  defp entries(_value), do: []

  defp template_gained(changeset) do
    strings =
      Enum.filter(@template_fields, fn field ->
        declared?(changeset.resource, field) and new_template?(changeset, field)
      end)

    case declared?(changeset.resource, :error_pages) and new_status_template?(changeset) do
      true -> strings ++ [:error_pages]
      false -> strings
    end
  end

  defp new_template?(changeset, field) do
    now = Ash.Changeset.get_attribute(changeset, field)
    written?(now) and now != Map.get(changeset.data, field)
  end

  defp new_status_template?(changeset) do
    was = changeset.data |> Map.get(:error_pages) |> status_templates()

    changeset
    |> Ash.Changeset.get_attribute(:error_pages)
    |> status_templates()
    |> Enum.any?(&(&1 not in was))
  end

  defp status_templates(entries) when is_list(entries) do
    Enum.flat_map(entries, fn entry ->
      [value(entry, :template), entry |> value(:layout) |> value(:template)]
      |> Enum.filter(&written?/1)
    end)
  end

  defp status_templates(_entries), do: []

  defp value(%{} = map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_other, _key), do: nil

  defp written?(template) when is_binary(template),
    do: String.trim(template) != "" and template not in starters()

  defp written?(_template), do: false

  defp starters, do: [PageStarter.blank(:page), PageStarter.blank(:layout)]

  defp declared?(resource, field), do: Ash.Resource.Info.attribute(resource, field) != nil

  # NOT `actor/1` — `use Ash.Resource.Validation` imports `Ash.Expr.actor/1`, and a local of that
  # name shadows it into a compile error.
  defp whose(%{actor: actor}), do: actor
  defp whose(_context), do: nil

  # Telling "code appeared" from "code was taken away" needs the row as it was, which an atomic
  # update does not have — so the update runs the ordinary way rather than in the database.
  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "page code needs the row as it was, to tell a change from a removal"}

  @impl true
  def describe(_opts) do
    [message: "Validates that this deployment allows the code being written", vars: []]
  end
end
