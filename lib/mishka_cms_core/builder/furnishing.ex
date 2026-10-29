# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Builder.Furnishing do
  @moduledoc """
  What a component says it should look like the moment it is dropped — declared by whoever wrote it,
  rather than guessed by this CMS.

  ## Why this exists

  `MishkaCmsBuilder.Starter` can furnish a dropped component without being told
  anything: it reads Phoenix's own `inner_block` convention and the conventional slot names, and
  falls back to a generic line. That works, and it works for a kit this install has never seen — but
  it is inference. The word "alert" in a component's name is a guess about what the component means,
  and nobody who ships a component library should have to name things this CMS's way to get a good
  drop.

  So a component may declare its own, and a declaration always wins:

      "extra": {
        "furnishing": {
          "body": "<tr><td>Ada Lovelace</td><td>Active</td></tr>",
          "slots": [
            {"name": "header", "body": "Name"},
            {"name": "header", "body": "Status"},
            {"name": "option", "body": "First choice", "attrs": {"value": "one"}}
          ]
        }
      }

  Both keys are optional. `body` alone furnishes the content between the tags; `slots` alone
  furnishes a component whose content is a list of entries; declaring `body: ""` explicitly says "put
  nothing inside", which a spinner wants and the heuristics would otherwise override.

  ## Untrusted by construction

  This is a third party's JSON, on the same footing as the bundle itself — see
  `MishkaCmsCore.UiKit.Contract`, which is why anything malformed answers `:none` and the heuristics
  take over, rather than raising into a palette render. A slot entry that fails validation is dropped
  on its own; the rest of the furnishing stands.

  Two things it deliberately does NOT do. It does not accept a function or a module reference: a
  furnishing may travel through a `MishkaInstaller` hook payload, which is plain-map only — the
  `MishkaCmsCore.Dashboard.Widget` rule. And it does not template anything; the strings are HEEx
  fragments written verbatim, so a component that wants a random id asks for one through the ordinary
  seeding path rather than through a placeholder syntax invented here.
  """

  use GuardedStruct

  alias MishkaCmsCore.Builder.FurnishingSlot
  alias MishkaCmsCore.Builder.Literal

  guardedstruct do
    field(:body, String.t(), default: "", derives: "sanitize(trim)")
    field(:slots, list(), default: [], derives: "validate(list)")
    # WHAT THE COMPONENT ARRIVES SET TO. A body says what goes inside; this says what the thing
    # itself is. `chelekom-gallery` is a grid whose column count and gap both default to the empty
    # string, so a plain drag dropped four pictures into a one-column, gapless stack — "it only add
    # images vertically". Changing the kit's own defaults instead would re-render every published
    # page that already uses one.
    field(:attrs, map(), default: %{}, derives: "validate(map)")
    # DECLARED EMPTY IS NOT THE SAME AS DECLARED NOTHING. A kit that writes `"body": ""` is saying
    # this component arrives with nothing inside, and `chelekom-gallery-media` is exactly that: the
    # editor already draws a dashed well and the words "needs src" for a picture nobody has chosen,
    # and the grey box the furnishing used to supply sat on top of it, eating the click meant for it.
    # Without this the empty body reads as an absent one and the inference puts a starter line back.
    field(:declares_body, boolean(), default: false, derives: "validate(boolean)")
  end

  @doc """
  Reads a declared furnishing, or answers `:none` when there is none to read.

  `:none` is not a failure — most components declare nothing, and the heuristics are the answer for
  them. It is also what a malformed declaration gets, for the reason in the moduledoc.
  """
  @spec build(term()) :: {:ok, t()} | :none
  def build(declared) when is_map(declared) and map_size(declared) > 0 do
    params = %{body: body(declared), slots: [], declares_body: declares_body?(declared)}

    # `slots` and `attrs` are set AFTER the build, not through it: the builder atomizes a map's keys,
    # and these keys are a kit's words. `String.to_atom/1` on somebody else's file is how a bundle
    # fills the atom table.
    case builder(params) do
      {:ok, furnishing} ->
        {:ok, %{furnishing | slots: slots(declared), attrs: attrs(declared)}}

      _invalid ->
        :none
    end
  end

  def build(_declared), do: :none

  @doc """
  Whether a declaration says anything at all.

  A furnishing that validated but carries neither a body nor a slot is treated as absent, so a kit
  writing `"furnishing": {}` does not silently strip the content the heuristics would have given.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%{body: "", slots: [], attrs: attrs, declares_body: false})
      when map_size(attrs) == 0,
      do: true

  def empty?(_furnishing), do: false

  defp body(declared) do
    case fetch(declared, "body") do
      body when is_binary(body) -> body
      _absent -> ""
    end
  end

  defp declares_body?(declared), do: is_binary(fetch(declared, "body"))

  # A NAME IS A NAME, AND A VALUE IS DATA. The name is written into HEEx verbatim, so it has to be
  # one — anything else is a kit writing markup through a data field. The value may be a word, which
  # is written as `name="value"`, or a number, a yes/no, a list or a map, which is written as the
  # expression the component actually takes: `chelekom-filterable-gallery` holds its pictures in a list, and there
  # is no string that means one.
  #
  # `Literal.data?/1` is the test for the second kind — the same one the editor applies to anything
  # it is about to print back as source — so a value it could not print is dropped rather than
  # half-written.
  defp attrs(declared) do
    case fetch(declared, "attrs") do
      %{} = attrs ->
        for {name, value} <- attrs,
            is_binary(name),
            Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, name),
            kept = keep_value(value),
            kept != :drop,
            into: %{},
            do: {name, kept}

      _absent ->
        %{}
    end
  end

  defp keep_value(value) when is_binary(value) do
    case String.contains?(value, ~s(")) do
      true -> :drop
      false -> value
    end
  end

  # A NUMBER OR A YES/NO IS NOT A WORD. `chelekom-ring-progress` arrives at `value={72}`, and written as
  # `value="72"` it reached the component as text and its arithmetic raised.
  defp keep_value(value) when is_number(value) or is_boolean(value), do: {:expr, value}

  defp keep_value(value) when is_list(value) or is_map(value) do
    term = atomized(value)

    case Literal.data?(term) do
      true -> {:expr, term}
      false -> :drop
    end
  end

  defp keep_value(_other), do: :drop

  # AN ATOM KEY, WRITTEN THE WAY JSON CAN WRITE ONE. `chelekom-filterable-gallery` reads
  # `media.src`, so a map of string keys raises — and JSON has no atoms. `":src"` is the same
  # spelling the bundle's own `__atom_map__` envelope uses, and it is deliberate on both sides: a
  # plain `"src"` stays a string, because `chelekom-flash` really does want string keys.
  #
  # `to_existing_atom`, because this is somebody else's file: a name nothing in the system has heard
  # of is a bundle filling the atom table, and it costs that key rather than being minted.
  defp atomized(%{} = map) do
    Map.new(map, fn {key, value} -> {atom_key(key), atomized(value)} end)
  end

  defp atomized(list) when is_list(list), do: Enum.map(list, &atomized/1)
  defp atomized(value), do: value

  defp atom_key(":" <> name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> ":" <> name
  end

  defp atom_key(key), do: key

  defp slots(declared) do
    case fetch(declared, "slots") do
      slots when is_list(slots) ->
        slots |> Enum.map(&FurnishingSlot.check/1) |> Enum.flat_map(&keep/1)

      _absent ->
        []
    end
  end

  defp keep({:ok, slot}), do: [slot]
  defp keep(:error), do: []

  defp fetch(declared, key) do
    case declared do
      %{^key => value} -> value
      %{} -> Map.get(declared, String.to_existing_atom(key))
    end
  end
end
