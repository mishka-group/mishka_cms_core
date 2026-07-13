defmodule MishkaCmsCore.Runtime.States.CardPreviewState do
  @moduledoc """
  O(1) ETS cache of rendered palette-card previews, keyed by the template a card would drop.

  ## Why a cache at all

  The first render of a component costs 0.5–1.4 seconds — that is its module being compiled — and
  every later one costs about 2 ms. Without this, moving back along a row of cards would pay the
  first price again each time the pointer returned, because nothing else remembers the answer.

  Keyed on the TEMPLATE rather than the component name, because two cards for the same component
  with different presets are two different previews, and the template is the thing that actually
  differs. The site rides in the key too: the same component draws differently under two sites'
  stylesheets.

  ## Why it is a plain table and not a GenServer

  The reads are the hot path and there is nothing to serialise: a preview is a pure function of its
  key, so two processes racing to compute the same one write identical bytes. `CompileFailureState`
  is the precedent.

  ## What bounds it

  A single install ships on the order of a hundred components, each a few kilobytes rendered, so a
  full cache is measured in hundreds of kilobytes — small enough to keep for the life of the node.
  It is dropped wholesale when a site recompiles, because that is when a preview can become a lie.
  """
  use GenServer

  @table :mishka_card_previews

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The cached preview for a template under a site, or `nil`."
  @spec get(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, String.t()} | nil
  def get(template, site_name) do
    case table?() && :ets.lookup(@table, key(template, site_name)) do
      [{_key, result}] -> result
      _miss -> nil
    end
  end

  @doc "Remember a rendered preview — or a refusal, which is just as expensive to work out twice."
  @spec put(String.t(), String.t() | nil, {:ok, String.t()} | {:error, String.t()}) :: :ok
  def put(template, site_name, result) do
    if table?(), do: :ets.insert(@table, {key(template, site_name), result})
    :ok
  end

  @doc """
  Forget everything a site's stylesheet or components could have changed.

  Called when a site recompiles: a preview drawn against the old bundle is not wrong in a way anyone
  can see, which is exactly why it has to go.
  """
  @spec drop(String.t() | nil) :: :ok
  def drop(site_name) do
    if table?(), do: :ets.match_delete(@table, {{:_, site_name}, :_})
    :ok
  end

  @doc "Forget every preview, whatever site it belongs to."
  @spec drop_all() :: :ok
  def drop_all do
    if table?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  @doc "How many previews are held, for tests and for anyone measuring."
  @spec size() :: non_neg_integer()
  def size do
    case table?() && :ets.info(@table, :size) do
      count when is_integer(count) -> count
      _no_table -> 0
    end
  end

  defp key(template, site_name), do: {template, site_name}

  defp table?, do: :ets.whereis(@table) != :undefined

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end
end
