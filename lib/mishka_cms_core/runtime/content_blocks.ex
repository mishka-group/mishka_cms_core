defmodule MishkaCmsCore.Runtime.ContentBlocks do
  @moduledoc """
  Ready-made blocks the content editor offers beside its single components: a card with its title
  and text, a timeline with its sections, a video with its source, a table with its rows — whole
  `MishkaCmsCore.Runtime.ContentComponents` markers, components inside components and slots filled
  in, so an author places one and only changes the words.

  A block names the components it is made of, and is offered only where every one of them is in the
  palette the editor shows — `available/3` — so a site without a kit's card never sees the card
  block. The sample text is in the reader's language.

  ## Events

    * `runtime:content:editor_blocks` — before the blocks are offered, with
      `%{site_id: site_id, blocks: blocks}` and `%{current_user: user}` as meta. Each block is
      `%{id, title, description, category, tree}`, `tree` a `t:MishkaCmsCore.Runtime.ContentComponents.tree/0`.
      A plugin answers the map with other `blocks` to add its own or take some away; the editor
      offers only those whose components the palette lists.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.ContentComponents
  alias MishkaInstaller.Event.Hook

  @event "runtime:content:editor_blocks"

  @typedoc "A block the editor offers, its marker written."
  @type block :: %{
          id: String.t(),
          title: String.t(),
          description: String.t(),
          category: String.t(),
          tree: ContentComponents.tree(),
          marker: String.t()
        }

  @doc """
  The blocks the editor offers on `site_id` to `actor`, given the palette's `entries`: every block
  whose components the palette lists, and whose slots those components declare, with its marker.
  """
  @spec available([ContentComponents.entry()], String.t() | nil, map() | nil) :: [block()]
  def available(entries, site_id, actor) do
    listed = Map.new(entries, &{&1.name, &1})

    %{site_id: site_id, blocks: all()}
    |> then(&Hook.call(@event, &1, meta: %{current_user: actor}))
    |> case do
      %{blocks: blocks} when is_list(blocks) -> blocks
      _unchanged -> all()
    end
    |> Enum.filter(&placeable?(&1, listed))
    |> Enum.flat_map(fn block ->
      case ContentComponents.write(block.tree) do
        marker when is_binary(marker) -> [Map.put(block, :marker, marker)]
        nil -> []
      end
    end)
  end

  @doc "Every block this module ships, before any is left out."
  @spec all() :: [map()]
  def all do
    [
      block(
        "quote",
        gettext("Quote"),
        gettext("A quotation set apart from the text."),
        "text",
        c("chelekom-blockquote", %{}, [text(gettext("Write the quotation here."))])
      ),
      block(
        "list",
        gettext("List"),
        gettext("Three points, one under the other."),
        "text",
        c("chelekom-list", %{"style" => "list-disc"}, [
          c("chelekom-li", %{}, [text(gettext("The first point"))]),
          c("chelekom-li", %{}, [text(gettext("The second point"))]),
          c("chelekom-li", %{}, [text(gettext("The third point"))])
        ])
      ),
      block(
        "table",
        gettext("Table"),
        gettext("A table with a heading row and two rows."),
        "text",
        c("chelekom-table", %{}, [
          slot("header", %{}, [text(gettext("Name"))]),
          slot("header", %{}, [text(gettext("Role"))]),
          c("chelekom-tr", %{}, [
            c("chelekom-td", %{}, [text("Ada")]),
            c("chelekom-td", %{}, [text(gettext("Engineer"))])
          ]),
          c("chelekom-tr", %{}, [
            c("chelekom-td", %{}, [text("Grace")]),
            c("chelekom-td", %{}, [text(gettext("Admiral"))])
          ])
        ])
      ),
      block(
        "callout",
        gettext("Callout"),
        gettext("A boxed note with a title."),
        "text",
        c("chelekom-alert", %{"title" => gettext("Good to know")}, [
          text(gettext("A short note the reader should not miss."))
        ])
      ),
      block(
        "card",
        gettext("Card"),
        gettext("A box with a title and a short text."),
        "layout",
        card([])
      ),
      block(
        "card-picture",
        gettext("Card with a picture"),
        gettext("A picture above a title and a short text."),
        "media",
        card([c("chelekom-card-media", %{"alt" => ""})])
      ),
      block(
        "two-columns",
        gettext("Two columns"),
        gettext("Two cards side by side."),
        "layout",
        c("chelekom-grid", %{"cols" => "two", "gap" => "medium"}, [card([]), card([])])
      ),
      block(
        "buttons",
        gettext("Buttons side by side"),
        gettext("Two links drawn as buttons, in one row."),
        "layout",
        c("chelekom-flex", %{"gap" => "small", "align" => "center"}, [
          c("chelekom-button-link", %{"href" => "#"}, [text(gettext("Read more"))]),
          c("chelekom-button-link", %{"href" => "#", "variant" => "outline"}, [
            text(gettext("Contact us"))
          ])
        ])
      ),
      block(
        "avatars",
        gettext("Avatars side by side"),
        gettext("Three pictures of people in one row."),
        "media",
        c(
          "chelekom-avatar-group",
          %{},
          for(_ <- 1..3, do: c("chelekom-avatar", %{"rounded" => "full"}))
        )
      ),
      block(
        "figure",
        gettext("Picture with a caption"),
        gettext("A picture and a line under it."),
        "media",
        c("chelekom-figure", %{}, [
          c("chelekom-image", %{"alt" => ""}),
          c("chelekom-figcaption", %{}, [text(gettext("A line about the picture"))])
        ])
      ),
      block(
        "video",
        gettext("Video"),
        gettext("A video with its file."),
        "media",
        c("chelekom-video", %{}, [slot("source", %{}, [])])
      ),
      block(
        "timeline",
        gettext("Timeline"),
        gettext("Three moments, in order."),
        "layout",
        c(
          "chelekom-timeline",
          %{},
          for(
            {title, time} <- [
              {gettext("Started"), "2024"},
              {gettext("Grew"), "2025"},
              {gettext("Today"), "2026"}
            ],
            do:
              c("chelekom-timeline-section", %{
                "title" => title,
                "time" => time,
                "description" => gettext("What happened then.")
              })
          )
        )
      ),
      block(
        "steps",
        gettext("Steps"),
        gettext("Three steps, numbered."),
        "layout",
        c(
          "chelekom-stepper",
          %{},
          for(
            step <- 1..3,
            do:
              c("chelekom-stepper-section", %{
                "step_number" => to_string(step),
                "title" => gettext("Step %{n}", n: step),
                "description" => gettext("What to do.")
              })
          )
        )
      ),
      block(
        "stats",
        gettext("Numbers"),
        gettext("Three figures with a label each."),
        "layout",
        c(
          "chelekom-stat-group",
          %{},
          for(
            {title, value} <- [
              {gettext("Readers"), "12k"},
              {gettext("Posts"), "340"},
              {gettext("Years"), "6"}
            ],
            do: c("chelekom-stat", %{"title" => title, "value" => value})
          )
        )
      ),
      block(
        "faq",
        gettext("Questions and answers"),
        gettext("Questions that open to their answers."),
        "layout",
        c(
          "chelekom-accordion",
          %{},
          for(
            n <- 1..3,
            do:
              slot("item", %{"title" => gettext("Question %{n}", n: n)}, [
                text(gettext("The answer to the question."))
              ])
          )
        )
      ),
      block(
        "tabs",
        gettext("Tabs"),
        gettext("Two tabs, each with its own text."),
        "layout",
        c("chelekom-tabs", %{}, [
          slot("tab", %{"active" => "true"}, [text(gettext("First"))]),
          slot("tab", %{}, [text(gettext("Second"))]),
          slot("panel", %{}, [text(gettext("What the first tab shows."))]),
          slot("panel", %{}, [text(gettext("What the second tab shows."))])
        ])
      )
    ]
  end

  defp card(above) do
    c(
      "chelekom-card",
      %{"padding" => "small", "rounded" => "medium"},
      above ++
        [
          c("chelekom-card-content", %{"padding" => "small"}, [
            c("chelekom-card-title", %{"title" => gettext("Card title")}),
            text(gettext("A short line that tells the reader what this is about."))
          ])
        ]
    )
  end

  defp block(id, title, description, category, {:component, tree}),
    do: %{id: id, title: title, description: description, category: category, tree: tree}

  defp c(name, attrs, parts \\ []), do: {:component, %{name: name, attrs: attrs, parts: parts}}
  defp slot(name, attrs, parts), do: {:slot, %{name: name, attrs: attrs, parts: parts}}
  defp text(text), do: {:text, text}

  # Every component in the block is listed, and every slot in it is one its component declares.
  defp placeable?(%{tree: %{name: _} = tree}, listed), do: fits?(tree, listed)
  defp placeable?(_block, _listed), do: false

  defp fits?(%{name: name, parts: parts}, listed) do
    case Map.fetch(listed, name) do
      {:ok, entry} -> Enum.all?(parts, &part_fits?(&1, entry, listed))
      :error -> false
    end
  end

  defp part_fits?({:text, _text}, _entry, _listed), do: true
  defp part_fits?({:component, tree}, _entry, listed), do: fits?(tree, listed)

  defp part_fits?({:slot, %{name: name, parts: parts}}, entry, listed) do
    Enum.any?(entry.slots, &(&1.name == name)) and
      Enum.all?(parts, &part_fits?(&1, entry, listed))
  end

  defp part_fits?(_part, _entry, _listed), do: false
end
