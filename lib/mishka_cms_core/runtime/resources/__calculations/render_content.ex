# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Calculations.RenderContent do
  @moduledoc """
  A reusable calculation that exposes a **plugin-transformable rendered version** of a content field —
  the Ash-idiomatic equivalent of the WordPress `the_content` / Joomla `onContentPrepare` filter.

  Add it as a calculation over the source attribute you display:

      calculations do
        calculate :rendered_content, :string,
          {MishkaCmsCore.Runtime.Resources.Calculations.RenderContent, source: :content}
      end

  Then **load `:rendered_content`** wherever you display the content (admin grid column, JSON API field,
  a future public article view) instead of the raw attribute. For each record it calls
  `"<app>:<resource>:render_<source>"` with `%{html: raw, record: record}`; a plugin returns
  `%{html: transformed}` (shortcodes, oEmbed, related-posts, ToC, syntax-highlight, SEO injection…).
  With no plugin registered the raw value is returned unchanged.

  > It runs at **display/load time**, so plugins must be pure and cheap (operate on already-fetched data;
  > never fetch a remote oEmbed here — precompute + cache, only string-substitute at render).

  See `MishkaInstaller.Event.Hook`.
  """
  use Ash.Resource.Calculation

  @impl true
  def init(opts) do
    if is_atom(opts[:source]) and !is_nil(opts[:source]),
      do: {:ok, opts},
      else: {:error, "#{inspect(__MODULE__)} requires a :source attribute, e.g. source: :content"}
  end

  @impl true
  def load(_query, opts, _context), do: [opts[:source]]

  @impl true
  def calculate(records, opts, context) do
    source = opts[:source]

    Enum.map(records, fn record ->
      raw = Map.get(record, source)
      event = "#{prefix(record.__struct__)}:render_#{source}"

      case MishkaInstaller.Event.Hook.call(event, %{html: raw, record: record},
             meta: %{actor: context.actor}
           ) do
        %{html: transformed} -> transformed
        _ -> raw
      end
    end)
  end

  defp prefix(resource) do
    segments = Module.split(resource)
    app = segments |> List.first() |> Macro.underscore() |> String.replace_prefix("mishka_", "")
    "#{app}:#{segments |> List.last() |> Macro.underscore()}"
  end
end
