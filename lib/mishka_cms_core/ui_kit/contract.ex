defmodule MishkaCmsCore.UiKit.Contract do
  @moduledoc """
  What a component in a `mishka.ui_kit.bundle.v3` file has to look like before this CMS will install
  it.

  A bundle is a THIRD PARTY's JSON — Chelekom's today, a headless kit's or somebody's own tomorrow —
  and until this module the only check was that `components` was a list. Everything past that was
  trusted, so a component missing its template, or shipping `attrs` as an object instead of an array,
  travelled all the way into `Ash.create!` and raised there. From the installer that is a failed
  install; from the Studio's Install button it took the editor's LiveView down with it.

  The contract is deliberately about SHAPE, not content: names, types, and which fields have to be
  present for the rest of the pipeline (`UiKitCatalog`, `Inspector`, `PaletteEntry`, the runtime
  compiler) to mean anything. A kit is free to add fields this CMS has never heard of —
  `UiKitHandler` drops those at the Ash boundary — and free to leave optional ones out.

  ## What happens to a component that fails

  It is skipped and named, exactly as an unreadable bundle file already is. One malformed component
  in a kit of 136 should cost that component, not the kit.
  """

  use GuardedStruct

  guardedstruct do
    field(:name, :string,
      derives: "sanitize(trim) validate(string, not_empty, min_len=2, max_len=200)"
    )

    field(:template, :string, derives: "sanitize(trim) validate(string, not_empty)")
    field(:type, :string, default: "general", derives: "sanitize(trim, downcase)")
    field(:attrs, list(), default: [], derives: "validate(list)")
    field(:slots, list(), default: [], derives: "validate(list)")
    field(:helpers, list(), default: [], derives: "validate(list)")
    field(:dependencies, list(), default: [], derives: "validate(list)")
    field(:extra, :map, default: %{}, derives: "validate(map)")

    # THREE BOOLEANS, AND ONLY ONE OF THEM IS NEW. `precompile` and `required` have been accepted
    # from a bundle since they existed and governed by nothing, so a kit shipping `"required": "yes"`
    # reached `Ash.Type.Boolean`, raised inside the transaction `upsert_row/2` runs in, and took
    # every other component in the bundle down with it. That is the exact failure this module's
    # moduledoc exists to prevent — one malformed component should cost that component, not the kit.
    #
    # None of the three joins `@required`: a kit that says nothing about them gets the resource's own
    # defaults, and a kit written before this change installs unchanged.
    field(:stateful, :boolean, default: false, derives: "validate(boolean)")
    field(:precompile, :boolean, default: false, derives: "validate(boolean)")
    field(:required, :boolean, default: false, derives: "validate(boolean)")
  end

  @doc """
  Checks one component from a bundle.

  Returns the reason as a short atom-or-tuple rather than GuardedStruct's own error shape, because
  the caller writes it into an installer log line, not a form.
  """
  @spec check(map()) :: :ok | {:error, term()}
  def check(component) when is_map(component) do
    with :ok <- required(component),
         {:ok, _struct} <- builder(contract_fields(component)),
         :ok <- shaped(component) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      error -> {:error, error}
    end
  end

  def check(_component), do: {:error, :not_a_component}

  # A COMPONENT THAT SAYS IT KEEPS STATE AND IS SHAPED SO IT CANNOT. Both of these compile quietly
  # and fail later: a clause list is silently discarded by the stateful emitter, and a name LiveView
  # assigns itself raises inside a visitor's LiveView. The same two refusals
  # `MishkaCmsCore.Runtime.Resources.Validations.StatefulShape` makes at the action boundary — here
  # as well, because a bundle reaches `Ash.create!` inside one transaction where a raise costs every
  # other component in the kit.
  #
  # `stateful` false or absent is the overwhelming majority and is not asked anything.
  defp shaped(component) do
    case get(component, :stateful) == true do
      false -> :ok
      true -> live_shaped(component)
    end
  end

  defp live_shaped(component) do
    cond do
      clauses(component) != [] -> {:error, {:stateful_with_clauses, name_of(component)}}
      reserved(component) != [] -> {:error, {:stateful_reserved_name, hd(reserved(component))}}
      true -> :ok
    end
  end

  defp clauses(component) do
    component
    |> get(:extra)
    |> case do
      %{} = extra -> Map.get(extra, "clauses") || Map.get(extra, :clauses) || []
      _absent -> []
    end
    |> List.wrap()
  end

  defp reserved(component) do
    reserved = MishkaCmsCore.Runtime.Resources.Validations.StatefulShape.reserved_names()

    [:attrs, :slots]
    |> Enum.flat_map(&List.wrap(get(component, &1)))
    |> Enum.map(fn
      %{} = declaration ->
        to_string(Map.get(declaration, "name") || Map.get(declaration, :name) || "")

      _other ->
        ""
    end)
    |> Enum.filter(&(&1 in reserved))
  end

  # Presence is checked here rather than through the struct because an absent field and a field
  # holding rubbish are different failures, and the installer's log line wants to say which. These
  # two are what the rest of the pipeline cannot proceed without: nothing can be compiled without a
  # template, and nothing can be found without a name.
  @required [:name, :template]

  defp required(component) do
    Enum.find_value(@required, :ok, fn key ->
      case get(component, key) do
        value when is_binary(value) ->
          if String.trim(value) == "", do: {:error, {:blank, key}}, else: nil

        nil ->
          {:error, {:missing, key}}

        _other ->
          {:error, {:not_a_string, key}}
      end
    end)
  end

  @doc """
  Splits a bundle's components into the ones this CMS can install and the ones it cannot.

  Returns `{kept, rejected}` where `rejected` is `[{name_or_nil, reason}]` — enough for the caller to
  say which components were skipped and why.
  """
  @spec partition([map()]) :: {[map()], [{String.t() | nil, term()}]}
  def partition(components) when is_list(components) do
    {kept, rejected} =
      Enum.split_with(components, fn component -> check(component) == :ok end)

    {kept, Enum.map(rejected, &{name_of(&1), reason_of(&1)})}
  end

  def partition(_components), do: {[], []}

  @doc "The fields the contract governs, for anyone documenting or testing the boundary."
  @spec fields() :: [atom()]
  def fields,
    do: [
      :name,
      :template,
      :type,
      :attrs,
      :slots,
      :helpers,
      :dependencies,
      :extra,
      :stateful,
      :precompile,
      :required
    ]

  # Only the governed fields reach the builder. A kit is free to carry anything else, and passing an
  # unknown key to GuardedStruct would reject the component for the one thing the contract is
  # explicitly not about.
  defp contract_fields(component) do
    for key <- fields(),
        value = get(component, key),
        not is_nil(value),
        into: %{},
        do: {Atom.to_string(key), value}
  end

  defp get(component, key) do
    case component do
      %{^key => value} -> value
      %{} -> Map.get(component, Atom.to_string(key))
    end
  end

  defp name_of(component) when is_map(component), do: get(component, :name)
  defp name_of(_component), do: nil

  defp reason_of(component) do
    case check(component) do
      {:error, reason} -> reason
      :ok -> :ok
    end
  end
end
