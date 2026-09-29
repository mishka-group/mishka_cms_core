defmodule MishkaCmsCore.Dev.HistorySeeds do
  @moduledoc """
  Fills a page's editing history with every state the timeline can draw, so the whole sheet can be
  looked at without waiting months for the awkward ones to occur naturally.

  Two of these states cannot be produced by using the editor at all today:

    * an **assistant** row — `MishkaCmsCore.Runtime.PageBuilder.AiBackend` has no model configured,
      and its `Echo` default deliberately makes no edits rather than pretending to;
    * a **payload dropped** row — that is what retention does to a document after months, or after
      500 changes.

  Everything is written through the resource's own actions rather than SQL, so the policies, the
  validations and the `site_id` rule all run exactly as they do in the editor. A seed that skipped
  them would be a seed that proves nothing.

  Run it from an `iex -S mix` session:

      MishkaCmsCore.Dev.HistorySeeds.seed_all()          # every page on every site
      MishkaCmsCore.Dev.HistorySeeds.seed(page_id)       # one page
      MishkaCmsCore.Dev.HistorySeeds.clear_all()         # take it all back out

  Development only. It is not called from the application's own seeds.
  """
  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Runtime.{Page, PageBuilderEvent, PageBuilderSnapshot}

  require Ash.Query

  @doc """
  Seed every active page with a full timeline. Returns how many rows were written.

  `full:` names one page that additionally gets enough ordinary edits to fill several pages of the
  sheet — that is the page to test paging and the note spoiler on. Every other page gets the ten
  states, which is what the states are for.
  """
  @spec seed_all(keyword()) :: {:ok, non_neg_integer()}
  def seed_all(opts \\ []) do
    full = Keyword.get(opts, :full)

    pages =
      Page
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.load([:site])
      |> Ash.read!(authorize?: false, page: false)
      |> Enum.filter(&(&1.active and is_nil(&1.archived_at)))

    {:ok, Enum.sum(Enum.map(pages, &seed_page(&1, &1.id == full)))}
  end

  @doc "Seed one page by id, with the ordinary edits that make it worth paging through."
  @spec seed(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def seed(page_id) do
    Page
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(id == ^page_id)
    |> Ash.Query.load([:site])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, page} -> {:ok, seed_page(page, true)}
      error -> error
    end
  end

  @doc "Remove every seeded row and the snapshots behind them."
  @spec clear_all() :: {:ok, non_neg_integer()}
  def clear_all do
    rows =
      PageBuilderEvent
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.load([:snapshot])
      |> Ash.read!(authorize?: false, page: false)

    Enum.each(rows, fn row ->
      if row.snapshot, do: Ash.destroy(row.snapshot, authorize?: false)
      Ash.destroy(row, authorize?: false)
    end)

    {:ok, length(rows)}
  end

  defp seed_page(page, full?) do
    authors = authors_for(page)
    snapshot = snapshot_of(page)

    live =
      page
      |> rows(authors, snapshot)
      |> Kernel.++(filler(full?, authors, snapshot))
      |> Enum.map(&write(&1, page, nil))

    # AND EVERY PENDING DRAFT, not just the newest. A draft's timeline shows the page's history with
    # its own changes on top, so these rows are what makes the difference between two branches
    # visible by switching — and which draft the editor resumes is its own decision, so a seed that
    # guessed at one would leave the others looking like the feature had lost their work.
    drafted =
      page
      |> pending_drafts()
      |> Enum.flat_map(fn draft ->
        page |> draft_rows(authors, snapshot) |> Enum.map(&write(&1, page, draft))
      end)

    Enum.count(live ++ drafted, &(&1 == :ok))
  end

  # A LONG NOTE, so the three-line clamp is doing something. The spoiler is CSS rather than a length
  # check, which means a seed of short notes would leave it looking like it does nothing at all.
  @long_ai_note "Rewrote the three feature cards so they read as a set: same verb-first opening, same length, and the same closing promise. I also moved the pricing sentence out of the middle card — it was the only one making a commercial claim, which made the other two look like filler beside it. The step below this one still has the old copy if you want it back."

  @long_human_note "Talked this over with the marketing team on Tuesday and we agreed the green reads as 'success' rather than 'action', which is the wrong signal on a contact form. Leaving it as it is because the launch is on Friday, but it should go back to the brand violet afterwards, and the hover state needs the same treatment."

  # ORDINARY EDITS. The ten states above are each unusual on purpose; a real page is mostly this —
  # small, repetitive, close together — and it takes enough of them for the sheet to page at all.
  defp filler(false, _authors, _snapshot), do: []

  defp filler(true, authors, snapshot) do
    ordinary = [
      {:style, :set_style, "<h1>", "font-size: 44px → 52px · base"},
      {:style, :set_style, "<h1>", "letter-spacing: -0.02em · base"},
      {:content, :set_text, "<p>", ~s("Get in touch" → "Send us a note")},
      {:style, :set_style, "<section>", "padding: 64px · md"},
      {:style, :set_style, "<section>", "background: #ffffff → #faf9f5 · base"},
      {:content, :set_attr, "<img>", ~s(alt "" → "Our team in the Tehran office")},
      {:style, :set_style, "<button>", "border-radius: 8px → 12px · base"},
      {:content, :insert, "<div>", "added inside section.contact · 4 lines"},
      {:style, :set_style, "<nav>", "display: flex → grid · lg"},
      {:content, :set_text, "<a>", ~s("Home" → "Start here")},
      {:style, :reset_styles, "<footer>", "cleared 6 properties · base"},
      {:content, :remove, "<span>", "removed from footer · 1 line"},
      {:style, :paste_styles, "<div.card>", "pasted 4 properties from div.card · base"},
      {:content, :set_attr, "<a>", ~s(target "" → "_blank")},
      {:style, :set_style, "<img>", "object-fit: cover · base"},
      {:content, :move, "<section>", "moved above section.features"},
      {:style, :set_style, "<h2>", "color: #3a382f → #1f1e1a · base"},
      {:content, :set_text, "<button>", ~s("Submit" → "Send message")},
      {:style, :set_style, "<form>", "gap: 12px → 16px · base"},
      {:content, :duplicate, "<div.card>", "duplicated after div.card · 9 lines"}
    ]

    people = [authors.human, authors.other || authors.human, authors.master]

    annotated =
      [
        %{
          minutes: 96,
          label: "Feature cards rewritten",
          kind: :content,
          op: :set_text,
          target: "<section>",
          detail: "3 headings and 3 paragraphs",
          author_type: :ai,
          author: authors.human,
          note: @long_ai_note,
          prompt: "tighten up the three feature cards so they feel consistent",
          backend: "claude-opus-5",
          snapshot_id: snapshot
        },
        %{
          minutes: 108,
          label: "Contact button colour",
          kind: :style,
          op: :set_style,
          target: "<button>",
          detail: "background: #4f4bcc → #1f9d6b · base",
          author: authors.human,
          note_author: authors.other || authors.human,
          note: @long_human_note,
          snapshot_id: snapshot
        }
      ]

    ordinary
    |> Enum.with_index()
    |> Enum.map(fn {{kind, op, target, detail}, index} ->
      %{
        minutes: 170 + index * 47,
        label: label_for(op, target),
        kind: kind,
        op: op,
        target: target,
        detail: detail,
        author: Enum.at(people, rem(index, 3)),
        snapshot_id: snapshot
      }
    end)
    |> Kernel.++(annotated)
  end

  defp label_for(:set_style, target), do: "Styled #{trim_tag(target)}"
  defp label_for(:reset_styles, target), do: "Cleared #{trim_tag(target)} styles"
  defp label_for(:paste_styles, target), do: "Pasted styles onto #{trim_tag(target)}"
  defp label_for(:set_text, target), do: "Edited #{trim_tag(target)} text"
  defp label_for(:set_attr, target), do: "Changed #{trim_tag(target)} attribute"
  defp label_for(:insert, target), do: "Inserted into #{trim_tag(target)}"
  defp label_for(:remove, target), do: "Removed #{trim_tag(target)}"
  defp label_for(:move, target), do: "Moved #{trim_tag(target)}"
  defp label_for(:duplicate, target), do: "Duplicated #{trim_tag(target)}"

  defp trim_tag(target), do: target |> String.trim_leading("<") |> String.trim_trailing(">")

  defp draft_rows(_page, authors, snapshot) do
    [
      %{
        minutes: 4,
        label: "Hero headline rewritten",
        kind: :content,
        op: :set_text,
        target: "<h1>",
        detail: ~s("Contact Us" → "Talk to us"),
        author: authors.human,
        snapshot_id: snapshot
      },
      %{
        minutes: 11,
        label: "Button colour changed",
        kind: :style,
        op: :set_style,
        target: "<button>",
        detail: "background: #4f4bcc → #1f9d6b · base",
        author_type: :ai,
        author: authors.human,
        note: "Made the call-to-action green so it stands apart from the header.",
        prompt: "make the contact button green",
        backend: "claude-opus-5",
        snapshot_id: snapshot
      },
      %{
        minutes: 26,
        label: "Set padding (base)",
        kind: :style,
        op: :set_style,
        target: "<section>",
        detail: "padding: 48px · base",
        author: authors.other || authors.human,
        snapshot_id: snapshot
      }
    ]
  end

  # ASKED, NOT TYPED. The number in that sentence is the resource's own cap, so a seed cannot drift
  # from what the editor would actually say.
  defp megabytes(author_type) do
    mb = PageBuilderSnapshot.max_bytes(author_type) / 1_048_576
    "#{:erlang.float_to_binary(mb, decimals: 1)} MB"
  end

  # Every pending draft of this page.
  defp pending_drafts(page) do
    MishkaCmsCore.Runtime.PageDraft
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(source_page_id == ^page.id and is_nil(applied_at))
    |> Ash.read!(authorize?: false, page: false)
    |> Enum.map(& &1.id)
  end

  # EVERY STATE THE TIMELINE DRAWS, oldest last so the sheet reads newest-first the way it will in
  # life. The awkward ones are here on purpose: they are the rows a reader will meet once and have to
  # understand immediately.
  defp rows(page, authors, snapshot) do
    [
      # a publish, written by the platform rather than a person
      %{
        minutes: 2,
        label: "Published #{page.name}",
        kind: :publish,
        op: :publish,
        detail: "9 elements live",
        author_type: :system,
        note:
          "Published to the live page. The changes behind this are recorded but no longer restorable.",
        snapshot_id: snapshot
      },

      # the assistant, with its own sentence, the prompt behind it, and which model
      %{
        minutes: 9,
        label: "Inserted testimonials block",
        kind: :content,
        op: :insert,
        target: "<section>",
        detail: "added after section.hero · 18 lines",
        author_type: :ai,
        author: authors.human,
        note: "Added a row of three customer quotes just below your hero image.",
        prompt: "add some social proof under the hero",
        backend: "claude-opus-5",
        snapshot_id: snapshot
      },

      # the assistant again, with a HUMAN's annotation on top of it
      %{
        minutes: 14,
        label: "Header made sticky",
        kind: :style,
        op: :set_style,
        target: "<header>",
        detail: "position: sticky · padding 20px → 14px",
        author_type: :ai,
        author: authors.human,
        note_author: authors.human,
        note:
          "Checked this on a phone — it covers the top of the hero image. Worth revisiting before the launch.",
        prompt: "make the header stick when scrolling",
        backend: "claude-opus-5",
        snapshot_id: snapshot
      },

      # ordinary human work, one of each bucket
      %{
        minutes: 31,
        label: "Set gap (base)",
        kind: :style,
        op: :set_style,
        target: "<nav>",
        detail: "gap: 20px · base",
        author: authors.human,
        snapshot_id: snapshot
      },
      %{
        minutes: 48,
        label: "Edited text",
        kind: :content,
        op: :set_text,
        target: "<h1>",
        detail: ~s("Build faster" → "Ship your best work"),
        author: authors.other || authors.human,
        snapshot_id: snapshot
      },

      # a rollback, which files under publish but must READ as a restore
      %{
        minutes: 63,
        label: "Restored",
        kind: :publish,
        op: :restore,
        detail: "the whole document, from an earlier point",
        author: authors.human,
        snapshot_id: snapshot
      },

      # net movement from undo/redo — one row for a run of steps, not one per tap
      %{
        minutes: 77,
        label: "Stepped back 5 changes",
        kind: :publish,
        op: :undo,
        detail: "net movement: 5 back",
        author: authors.human,
        snapshot_id: snapshot
      },

      # REFUSED: the document was past the size a snapshot is taken of
      %{
        minutes: 140,
        label: "Pricing table imported",
        kind: :content,
        op: :insert,
        target: "<table>",
        detail: "40 elements in one step",
        author: authors.other || authors.human,
        refused: true,
        note:
          "Snapshot not taken — the document was over the size this keeps (#{megabytes(:human)}). This change cannot be reverted from here.",
        snapshot_id: nil
      },

      # DROPPED: retention took the payload and left the row readable
      %{
        minutes: 1500,
        label: "Card padding tightened",
        kind: :style,
        op: :set_style,
        target: "<div.card>",
        detail: "padding: 18px · base",
        author: authors.human,
        note:
          "Older than this page keeps documents for. The change is recorded; it can no longer be restored.",
        snapshot_id: nil
      },

      # an author this reader may not be allowed to see, so the mask renders
      %{
        minutes: 1700,
        label: "Footer contact link swapped",
        kind: :content,
        op: :set_attr,
        target: "<a>",
        detail: ~s(href "/contact" → "/hire-us"),
        author: authors.master,
        snapshot_id: snapshot
      }
    ]
  end

  defp write(row, page, draft_id) do
    attrs =
      row
      |> Map.drop([:minutes, :author, :note_author, :snapshot_id])
      |> Map.merge(%{
        id: Ecto.UUID.generate(),
        source_type: :page,
        source_id: page.id,
        draft_id: draft_id,
        site_id: page.site_id,
        inserted_at: DateTime.add(DateTime.utc_now(), -row.minutes * 60, :second)
      })

    # `author_id` is not accepted from input by design — the action sets it from the ACTOR. A seed
    # goes the same way rather than around it, so what it produces is exactly what the editor would.
    # The restore point is a private argument for the same reason.
    PageBuilderEvent
    |> Ash.Changeset.for_create(:create, attrs,
      tenant: page.site_id,
      actor: row[:author],
      authorize?: false,
      private_arguments: %{snapshot_id: row[:snapshot_id]}
    )
    |> Ash.create(actor: row[:author], authorize?: false)
    |> case do
      {:ok, created} -> annotate(created, row)
      {:error, _reason} -> :error
    end
  end

  # The human annotation on an assistant's row is a second act by a second person, so it is written
  # the way the editor writes it: through `:annotate`, which stamps who and when.
  defp annotate(row, %{note_author: author}) when not is_nil(author) do
    row
    |> Ash.Changeset.for_update(:annotate, %{note: row.note}, actor: author, authorize?: false)
    |> Ash.update(actor: author, authorize?: false)

    :ok
  end

  defp annotate(_row, _no_annotation), do: :ok

  # One real snapshot of the page's own template, shared by every row that has one — enough for
  # Revert to do something real, without writing ten copies of the same document.
  defp snapshot_of(page) do
    with heex when is_binary(heex) <- page.template,
         {:ok, payload, size} <-
           PageBuilderSnapshot.compress(heex, PageBuilderSnapshot.max_bytes(:human)),
         {:ok, row} <-
           PageBuilderSnapshot
           |> Ash.Changeset.for_create(:create, %{payload: payload, byte_size: size},
             authorize?: false
           )
           |> Ash.create(authorize?: false) do
      row.id
    else
      _no_template -> nil
    end
  end

  # A master, somebody from the page's own site, and a third person — so the masking ladder has
  # something to hide and something to show.
  defp authors_for(page) do
    %{
      master: user_where(&is_nil(&1.site_id)),
      human: user_where(&(&1.site_id == page.site_id)) || user_where(&is_nil(&1.site_id)),
      other: second_user_where(&(&1.site_id == page.site_id))
    }
  end

  defp users do
    User
    |> Ash.Query.for_read(:read, %{}, authorize?: false)
    |> Ash.read!(authorize?: false, page: false)
  end

  defp user_where(predicate), do: users() |> Enum.filter(predicate) |> List.first()

  defp second_user_where(predicate), do: users() |> Enum.filter(predicate) |> Enum.at(1)
end
