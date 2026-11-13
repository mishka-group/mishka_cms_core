# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.Redactor do
  @moduledoc """
  What a receipt may hold, and the only way its evidence and errors are built.

  A receipt is read by agents and admins who may not see the data an operation touched, so it
  keeps the shape of what happened and none of the content:

    * Evidence (`observed`, `expected`, `meta`) is a map with atom keys and scalar values only:
      atoms, booleans, numbers, dates and times, UUIDs, short identifier-like strings (letters,
      digits and `_ . : - /`, at most 64 bytes, such as a status, a topic or a version) and lists of
      at most 16 atoms (field names). Anything else is dropped, never truncated: a title, a body,
      an email, a map of params, a struct, a long or spaced string. At most 16 keys are kept.
    * An error is `%{kind:, module:, at:, classes:, fields:}`: how it ended (`:error`, `:exit`,
      `:throw`), the exception module, the top stack frame as `"Mod.fun/arity"`, and for an Ash error
      the error classes and the field names it names. Never the message, which interpolates the
      values that were refused, nor the stack trace, nor the term that was thrown.
    * An actor is its id and kind (`:master`, `:user`, `:system`), never its email or name.
  """

  @max_keys 16
  @max_string 64
  @identifier ~r/\A[A-Za-z0-9_.:\-\/]+\z/
  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @typedoc "Evidence a receipt keeps: atom keys, scalar values."
  @type evidence :: %{optional(atom()) => scalar()}

  @type scalar ::
          atom()
          | boolean()
          | number()
          | String.t()
          | DateTime.t()
          | NaiveDateTime.t()
          | Date.t()
          | [atom()]

  @typedoc "A redacted error: never a message, a value or a stack trace."
  @type error :: %{
          kind: :error | :exit | :throw,
          module: module() | nil,
          at: String.t() | nil,
          classes: [module()],
          fields: [atom()]
        }

  @typedoc "Who acted, without who they are."
  @type actor :: %{id: String.t() | nil, kind: :master | :user | :system}

  @doc """
  `evidence` with every key or value a receipt may not hold dropped. `nil` stays `nil`; anything
  that is not a map or keyword list is `%{}`.
  """
  @spec evidence(map() | keyword() | nil) :: evidence() | nil
  def evidence(nil), do: nil

  def evidence(evidence) when is_list(evidence) do
    if Keyword.keyword?(evidence), do: evidence(Map.new(evidence)), else: %{}
  end

  def evidence(evidence) when is_map(evidence) and not is_struct(evidence) do
    evidence
    |> Enum.filter(fn {key, value} -> is_atom(key) and scalar?(value) end)
    |> Enum.sort()
    |> Enum.take(@max_keys)
    |> Map.new()
  end

  def evidence(_other), do: %{}

  @doc "Whether `value` is a scalar a receipt may hold (see the moduledoc)."
  @spec scalar?(term()) :: boolean()
  def scalar?(value) when is_atom(value) or is_number(value), do: true
  def scalar?(%DateTime{}), do: true
  def scalar?(%NaiveDateTime{}), do: true
  def scalar?(%Date{}), do: true

  def scalar?(value) when is_binary(value),
    do:
      byte_size(value) <= @max_string and String.valid?(value) and
        (Regex.match?(@uuid, value) or Regex.match?(@identifier, value))

  def scalar?(value) when is_list(value),
    do: length(value) <= @max_keys and Enum.all?(value, &is_atom/1)

  def scalar?(_other), do: false

  @doc """
  The redacted summary of a failure: an exception (with `kind` and its stack trace), or an error
  term an action returned, such as an `Ash.Error.Invalid`.
  """
  @spec error(:error | :exit | :throw, term(), Exception.stacktrace()) :: error()
  def error(kind, reason, stacktrace \\ []) do
    %{
      kind: kind,
      module: exception_module(kind, reason),
      at: top_frame(stacktrace),
      classes: classes(reason),
      fields: fields(reason)
    }
  end

  @doc "The field names an error term names, without their values or messages."
  @spec fields(term()) :: [atom()]
  def fields(reason) do
    reason
    |> errors()
    |> Enum.flat_map(&error_fields/1)
    |> Enum.filter(&is_atom/1)
    |> Enum.uniq()
    |> Enum.take(@max_keys)
  end

  @doc """
  The modules of the errors an error term groups, such as `Ash.Error.Changes.InvalidAttribute`:
  what kind of refusal it was, with nothing of what was refused.
  """
  @spec classes(term()) :: [module()]
  def classes(reason) do
    reason
    |> errors()
    |> Enum.map(fn
      %{__struct__: module} -> module
      _other -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(@max_keys)
  end

  @doc "An actor as a receipt keeps it: its id and whether it is a master, a site user or nobody."
  @spec actor(term()) :: actor()
  def actor(%{id: id, site_id: nil}) when is_binary(id), do: %{id: id, kind: :master}

  def actor(%{id: id, site_id: site_id}) when is_binary(id) and is_binary(site_id),
    do: %{id: id, kind: :user}

  def actor(_nobody), do: %{id: nil, kind: :system}

  @doc "A record's id when it is one a receipt may keep (a UUID or a short identifier)."
  @spec id(term()) :: String.t() | integer() | nil
  def id(value) when is_integer(value), do: value

  def id(value) when is_binary(value) do
    if scalar?(value), do: value, else: nil
  end

  def id(_other), do: nil

  defp exception_module(:error, %{__exception__: true, __struct__: module}), do: module
  defp exception_module(_kind, %{__struct__: module}) when is_atom(module), do: module
  defp exception_module(_kind, _reason), do: nil

  defp top_frame([{module, fun, arity, _location} | _rest]) when is_atom(module),
    do: "#{inspect(module)}.#{fun}/#{arity_of(arity)}"

  defp top_frame(_none), do: nil

  defp arity_of(args) when is_list(args), do: length(args)
  defp arity_of(arity), do: arity

  # An Ash error class (`Ash.Error.Invalid`, `Forbidden` ...) holds the errors it groups.
  defp errors(%{errors: errors}) when is_list(errors), do: Enum.flat_map(errors, &errors/1)
  defp errors(%{__struct__: _} = error), do: [error]
  defp errors(errors) when is_list(errors), do: Enum.flat_map(errors, &errors/1)
  defp errors(_other), do: []

  defp error_fields(%{fields: fields}) when is_list(fields), do: fields
  defp error_fields(%{field: field}) when is_atom(field), do: [field]
  defp error_fields(_error), do: []
end
