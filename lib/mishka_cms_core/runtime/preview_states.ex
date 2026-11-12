# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PreviewStates do
  @moduledoc """
  The states a page's preview can be drawn in: the buttons above the frame of the admin's preview
  modal (`MishkaCmsCoreWeb.Live.Admin.Components.RuntimePreviewModal`), each a set of query
  parameters the frame's address carries. The preview route hands them to the page as
  `@query_params`, as it hands a visitor's query, so a state shows what the page shows for those
  values. Preview handlers never run, so no state does anything.

  ## Where they come from

    * A page that shows a record (`MishkaCmsCore.Runtime.Seo.record_of/1`) whose address captures
      it (`/:lang/blog/:slug`) gets the `samples` its plugin names on
      `MishkaCmsCore.Runtime.Seo.records_event/0`: the latest posts, the first section. Their
      parameters are the captures, so the same choice gives "Open page" a real address.
    * Every page is asked of the plugins on `event/0`, with
      `%{site_id:, page: %{path:, extra:, record:, language:}, states: []}`. A plugin that owns the
      page appends its own and hands every other page back untouched:

          def call(%{page: %{extra: %{"newsletter_role" => "confirm"}}, states: states} = given),
            do: {:reply, %{given | states: states ++ [%{id: "invalid", label: "Invalid link", params: %{"token" => "preview"}}]}}

          def call(given), do: {:reply, given}

  A state is `%{id:, label:, params:}`: a string id and label, and string parameters. A state of
  any other shape is left out, and so is a parameter named `resource` or `token`, which the preview
  route keeps for itself. Read once, when a page's preview opens.
  """

  alias MishkaCmsCore.Runtime.Seo
  alias MishkaInstaller.Event.Hook

  @event "runtime:page:preview_states"
  @reserved ["resource", "token"]

  @type state :: %{id: String.t(), label: String.t(), params: %{String.t() => String.t()}}

  @doc "The event a plugin names the preview states of its pages on."
  @spec event() :: String.t()
  def event, do: @event

  @doc """
  The states `page` (a `MishkaCmsCore.Runtime.Page`, or a map with its `path`, `extra` and
  `language`) is previewed in on `site_id`: its record's samples first, then the plugins'. Each
  record sample is marked `record?: true`.
  """
  @spec for_page(map(), String.t() | nil) :: [map()]
  def for_page(page, site_id) do
    record = Seo.record_of(Map.get(page, :extra))

    given = %{
      site_id: site_id,
      page: %{
        path: Map.get(page, :path),
        extra: Map.get(page, :extra),
        record: record,
        language: Map.get(page, :language)
      },
      states: []
    }

    plugins =
      case Hook.call(@event, given) do
        %{states: states} when is_list(states) -> Enum.flat_map(states, &state/1)
        _not_answered -> []
      end

    (samples(record, site_id) ++ Enum.map(plugins, &Map.put(&1, :record?, false)))
    |> Enum.uniq_by(& &1.id)
  end

  defp samples(nil, _site_id), do: []

  defp samples(record, site_id) do
    case Enum.find(Seo.record_types(site_id), &(&1.id == record)) do
      %{captures: [_ | _], samples: samples} ->
        samples
        |> Enum.with_index()
        |> Enum.flat_map(fn {%{label: label, params: params}, index} ->
          state(%{id: "record-#{index}", label: label, params: params})
        end)
        |> Enum.map(&Map.put(&1, :record?, true))

      _no_samples ->
        []
    end
  end

  defp state(%{id: id, label: label, params: %{} = params})
       when is_binary(id) and id != "" and is_binary(label) and label != "" do
    [%{id: id, label: label, params: clean(params)}]
  end

  defp state(_not_a_state), do: []

  defp clean(params) do
    for {key, value} <- params,
        key = to_string(key),
        key not in @reserved,
        is_binary(value),
        into: %{},
        do: {key, value}
  end

  @doc "The state `id` names among `states`, or `nil`."
  @spec find([map()], String.t() | nil) :: map() | nil
  def find(states, id) when is_binary(id), do: Enum.find(states, &(&1.id == id))
  def find(_states, _no_id), do: nil

  @doc """
  The state a preview opens in: the first record sample, since a page that shows a record shows
  nothing without one, else none.
  """
  @spec initial([map()]) :: map() | nil
  def initial(states), do: Enum.find(states, & &1.record?)

  @doc """
  `url` with `state`'s parameters as its query string. `url` itself when there is no state, or no
  url.

      with_params("/_preview/page/t", %{params: %{"slug" => "a-post"}}) #=> "/_preview/page/t?slug=a-post"
  """
  @spec with_params(String.t() | nil, map() | nil) :: String.t() | nil
  def with_params(url, %{params: params}) when is_binary(url) and url != "" and params != %{},
    do: url <> "?" <> URI.encode_query(params)

  def with_params(url, _no_state), do: url
end
