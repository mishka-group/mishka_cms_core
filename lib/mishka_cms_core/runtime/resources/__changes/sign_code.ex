defmodule MishkaCmsCore.Runtime.Resources.Changes.SignCode do
  @moduledoc """
  Signs each stored snippet on the way in, so the compiler can tell what this application wrote.

  `MishkaCmsCore.Runtime.PageBuilder.CodeSignature` holds the rule and is off unless a key is
  configured; with no key this change is a no-op and nothing about the row changes.

  ## Why here rather than at each caller

  There are five ways code reaches these attributes — the builder, the Gervaz form, the JSON:API, a
  seed and the kit installer — and a signature applied at four of them is worth nothing, because the
  fifth is the one an attacker would use. The action boundary is the only place all five pass
  through.

  It runs on the same four resources as `Validations.CodeChange`, and after it: there is no point
  signing a write that is about to be refused.
  """

  use Ash.Resource.Change

  alias MishkaCmsCore.Runtime.PageBuilder.CodeSignature

  @code_fields [:events, :infos, :helpers]

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def change(changeset, _opts, _context) do
    case CodeSignature.enabled?() do
      false -> changeset
      true -> Enum.reduce(@code_fields, changeset, &sign_field/2)
    end
  end

  defp sign_field(field, changeset) do
    with true <- declared?(changeset.resource, field),
         true <- Ash.Changeset.changing_attribute?(changeset, field),
         entries when is_list(entries) <- Ash.Changeset.get_attribute(changeset, field) do
      Ash.Changeset.force_change_attribute(
        changeset,
        field,
        Enum.map(entries, &CodeSignature.put/1)
      )
    else
      _unchanged_or_absent -> changeset
    end
  end

  defp declared?(resource, field), do: Ash.Resource.Info.attribute(resource, field) != nil

  # NOT ATOMIC. The signature is computed from the code in this changeset, which the database cannot
  # do — and `:ok` here would let an atomic update store code with no signature at all, which the
  # compiler would then refuse to run.
  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "a signature is computed from the code being written"}
end
