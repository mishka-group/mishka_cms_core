# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Forms.ComponentSubmit do
  @moduledoc """
  The submit handler for a component's form — the inspector's Configuration tab and the builder's
  Interface tab are both this form.

  It keeps what the form cannot show. A component's `attrs` and `slots` are declarations, and the
  form draws each one's options as a few controls — Required, Default, Doc. A declaration holds more
  than that, and holds values those controls cannot draw:

    * keys with no control at all — `values`, `editor`, `default_struct`, a slot's `validate_attrs`;
    * values a text box draws as nothing — `nil`, `false`, `true`, `[]` — or as a string — `0`,
      `1.0`.

  Saved as the controls sent them back, a save rewrote the declaration from what was on screen. A
  rename of `chelekom-button` declared `attr :type` with no default, and the first page that left
  `type` unset raised `key :type not found`.

  So once `MishkaGervaz.Form.Web.Events.SubmitHandler.Default` has parsed the params, every row
  named like a row the record already declares gets back what the form did not change:

    * in an option map (a `:key_map` sub-field), each key with no control, and each key whose control
      came back exactly as it was drawn;
    * in a list of rows (a `:key_list` sub-field — a slot's own attributes), each row that came back
      exactly as it was drawn, whole. Those rows are drawn flat while the record keeps `required` and
      `doc` under `opts`, and half of one would say both.

  Which fields and keys those are is read from the form's own declaration. A control the author did
  change is theirs, a blank included; a row they renamed or added is new.
  """

  use MishkaGervaz.Form.Web.Events.SubmitHandler

  alias MishkaCmsCore.Runtime.Helpers
  alias MishkaGervaz.Form.Types.Field.KeyMap

  def transform_params(state, params) do
    record = state.form && state.form.data

    state.static.fields
    |> Enum.flat_map(&declared_rows/1)
    |> Enum.reduce(super(state, params), fn {field, subs}, acc ->
      keep_field(acc, to_string(field), subs, stored(record, field))
    end)
  end

  # A nested field whose rows hold an option map or a list of rows, with the control each key of
  # those is drawn as.
  defp declared_rows(%{type: :nested, name: name} = field) do
    field
    |> Map.get(:nested_fields, [])
    |> List.wrap()
    |> Enum.filter(&(&1.type in [:key_map, :key_list]))
    |> Enum.map(&{to_string(&1.name), &1.type, controls(&1)})
    |> case do
      [] -> []
      subs -> [{name, subs}]
    end
  end

  defp declared_rows(_field), do: []

  defp controls(sub_field), do: Map.new(KeyMap.keys(sub_field), &{to_string(&1.name), &1.type})

  defp stored(%{} = record, field), do: record |> Map.get(field) |> by_name()
  defp stored(_record, _field), do: %{}

  defp by_name(rows) when is_list(rows) do
    rows
    |> Helpers.stringify_keys()
    |> Enum.filter(&(is_map(&1) and not is_struct(&1)))
    |> Map.new(&{&1["name"], &1})
  end

  defp by_name(_rows), do: %{}

  defp keep_field(params, _field, _subs, stored) when map_size(stored) == 0, do: params

  defp keep_field(params, field, subs, stored) do
    case Map.fetch(params, field) do
      {:ok, rows} -> Map.put(params, field, each_row(rows, &keep_row(&1, subs, stored)))
      :error -> params
    end
  end

  # The rows arrive as a list or as the index-keyed map a form posts.
  defp each_row(rows, fun) when is_list(rows), do: Enum.map(rows, fun)

  defp each_row(%{} = rows, fun) when not is_struct(rows),
    do: Map.new(rows, fn {index, row} -> {index, fun.(row)} end)

  defp each_row(rows, _fun), do: rows

  defp keep_row(%{} = row, subs, stored) do
    case Map.fetch(stored, row["name"]) do
      {:ok, was} -> Enum.reduce(subs, row, &keep_sub(&2, &1, was))
      :error -> row
    end
  end

  defp keep_row(row, _subs, _stored), do: row

  defp keep_sub(row, {key, :key_map, controls}, was) do
    case {Map.get(row, key) || %{}, Map.get(was, key)} do
      {%{} = sent, %{} = held} -> Map.put(row, key, keep_options(sent, held, controls))
      _unreadable -> row
    end
  end

  defp keep_sub(row, {key, :key_list, controls}, was) do
    case {Map.get(row, key), by_name(Map.get(was, key))} do
      {sent, held} when is_list(sent) and map_size(held) > 0 ->
        Map.put(row, key, Enum.map(sent, &keep_whole(&1, held, controls)))

      _nothing_held ->
        row
    end
  end

  defp keep_options(sent, held, controls) do
    Enum.reduce(held, sent, fn {key, value}, acc ->
      case Map.fetch(controls, key) do
        :error -> Map.put(acc, key, value)
        {:ok, type} -> keep_if_untouched(acc, key, value, posted(type, value))
      end
    end)
  end

  defp keep_if_untouched(sent, key, value, untouched) do
    case Map.fetch(sent, key) == untouched do
      true -> Map.put(sent, key, value)
      false -> sent
    end
  end

  defp keep_whole(%{} = sent, held, controls) do
    case Map.fetch(held, sent["name"]) do
      {:ok, was} -> if sent == drawn_row(was, controls), do: was, else: sent
      :error -> sent
    end
  end

  defp keep_whole(sent, _held, _controls), do: sent

  # The row an untouched key list sends back for `was`.
  defp drawn_row(was, controls) do
    for {key, type} <- controls,
        {:ok, value} <- [posted(type, Map.get(was, key))],
        into: %{},
        do: {key, value}
  end

  # WHAT AN UNTOUCHED CONTROL SENDS BACK for `value`, once Gervaz has parsed it: `{:ok, parsed}`, or
  # `:error` for a key it drops as blank. A toggle is on or dropped; a number box is cast back to a
  # number; any other control sends the text its `value` attribute was drawn with.
  defp posted(type, value) when type in [:toggle, :checkbox],
    do: if(value in [true, "true", "on"], do: {:ok, true}, else: :error)

  defp posted(:number, value) when is_number(value), do: {:ok, value}

  defp posted(_type, value) do
    text = drawn(value)
    if String.trim(text) == "", do: :error, else: {:ok, text}
  end

  # `value={…}` as HEEx writes it and a browser reads it back. `nil` and `false` leave the attribute
  # out and `true` writes it bare, so all three read as "". A list is written as its strings run
  # together. A map cannot be written into an attribute at all.
  defp drawn(value) when is_binary(value), do: value
  defp drawn(value) when is_boolean(value) or is_nil(value), do: ""
  defp drawn(value) when is_atom(value), do: Atom.to_string(value)
  defp drawn(value) when is_integer(value), do: Integer.to_string(value)
  defp drawn(value) when is_float(value), do: Float.to_string(value)

  defp drawn(value) when is_list(value),
    do: if(Enum.all?(value, &is_binary/1), do: Enum.join(value), else: "")

  defp drawn(_value), do: ""
end
