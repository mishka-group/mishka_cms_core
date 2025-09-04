defmodule MishkaCmsCoreWeb.Templates.VersionHistory do
  @moduledoc """
  The version-history modal's body and footer, shared by every admin page that has one.

  A collection, a post, a blogger, a team and a tag all keep AshPaperTrail history and all show it
  the same way: a list of versions, each with when it happened, which action wrote it, who by, and
  which fields it touched — plus a preview that opens the changes in place and a Restore beside it.
  Only the record differs, so only the record's page owns the modal shell and the head; everything
  inside it is this module.

  ## The event contract

  `panel/1` renders buttons, not callbacks — the page must handle four events, which is the set the
  existing pages already implement:

    * `"toggle_version_preview"` with `phx-value-version-id`
    * `"restore_version"` with `phx-value-version-id`
    * `"versions_prev_page"` and `"versions_next_page"`

  Pair it with `MishkaCmsCore.CoreComponents.modal/1` given `padding_class="p-0"` and
  `MishkaCmsCoreWeb.Templates.CardChrome.modal_head/1`, the way
  `MishkaBlogWeb.Live.Admin.Dashboard.Post.Index` does.
  """
  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  alias MishkaCmsCore.Accounts.Helper

  @doc """
  Chip colours for the action a version came from.

  PaperTrail stores the resource's own action name, so a master's edit arrives as `:master_update`
  and a publish as `:publish`. Anything unrecognised reads neutral rather than colourless — the
  earlier version of this map covered only `:create`/`:update`/`:destroy`, which left most real
  badges unstyled.
  """
  @spec action_color(atom()) :: String.t()
  def action_color(action) when action in [:create, :master_create],
    do: "bg-[#e6f6ee] text-[#177a53]"

  def action_color(action) when action in [:update, :master_update],
    do: "bg-[#eef1fc] text-[#3a5bc4]"

  def action_color(action) when action in [:destroy, :master_destroy],
    do: "bg-[#fbe9e7] text-[#b3433a]"

  def action_color(action) when action in [:publish, :master_publish],
    do: "bg-[#e6f6ee] text-[#177a53]"

  def action_color(action) when action in [:unpublish, :master_unpublish],
    do: "bg-[#fbf1df] text-[#a5691a]"

  def action_color(action) when action in [:unarchive, :master_unarchive],
    do: "bg-[#eeedfb] text-[#5b57d6]"

  def action_color(_action), do: "bg-[#f2f1ec] text-[#6d6a63]"

  @doc """
  The word a version's chip shows for the action that wrote it. An action this does not name shows
  as it is stored.
  """
  @spec action_label(atom()) :: String.t() | atom()
  def action_label(:create), do: gettext("create")
  def action_label(:master_create), do: gettext("master_create")
  def action_label(:update), do: gettext("update")
  def action_label(:master_update), do: gettext("master_update")
  def action_label(:destroy), do: gettext("destroy")
  def action_label(:master_destroy), do: gettext("master_destroy")
  def action_label(:publish), do: gettext("publish")
  def action_label(:master_publish), do: gettext("master_publish")
  def action_label(:unpublish), do: gettext("unpublish")
  def action_label(:master_unpublish), do: gettext("master_unpublish")
  def action_label(:unarchive), do: gettext("unarchive")
  def action_label(:master_unarchive), do: gettext("master_unarchive")
  def action_label(action), do: action

  @doc """
  One changed value, formatted for the preview box.

  Maps and lists are pretty-printed, a string is shown as written, and anything else falls back to
  `inspect/1`. Formatting here rather than in the template keeps the value off its own line — under
  `whitespace-pre-wrap` the template's own indentation would otherwise render as part of the value.
  """
  @spec change_value(term()) :: String.t()
  def change_value(value) when is_map(value) or is_list(value),
    do: Jason.encode!(value, pretty: true)

  def change_value(nil), do: "null"
  def change_value(value) when is_binary(value), do: value
  def change_value(value), do: inspect(value)

  @doc "The last page of history, so the pager never offers a page that does not exist."
  @spec last_page(non_neg_integer(), pos_integer()) :: pos_integer()
  def last_page(total, per_page), do: max(ceil(total / per_page), 1)

  @doc """
  Who wrote `version`, for the reader whose read loaded its `:user`.

  The email the reader may read, "Master" when `master_ids` holds the version's `user_id`, "System"
  for a version with no user, and "Unknown" for a user the reader's read did not return.
  """
  @spec author(map(), MapSet.t()) :: String.t()
  def author(version, master_ids) do
    user_id = Map.get(version, :user_id)

    Helper.who(
      Map.get(version, :user),
      MapSet.member?(master_ids, user_id),
      (user_id && :unknown) || :system
    )
  end

  @doc """
  The ids among `versions`' authors that are masters, for `panel/1`'s `:master_ids`.

  Reads once, off the render: call it where the versions are loaded. An empty set when the read
  fails, so a master's version reads "Unknown" rather than breaking the modal.
  """
  @spec master_ids([map()]) :: MapSet.t()
  def master_ids(versions) do
    case versions |> Enum.map(&Map.get(&1, :user_id)) |> Helper.master_ids() do
      {:ok, masters} -> masters
      {:error, _reason} -> MapSet.new()
    end
  end

  @doc "Which fields a version touched, as one line."
  @spec changed_fields(map() | nil) :: String.t() | nil
  def changed_fields(changes) when is_map(changes) and map_size(changes) > 0,
    do: changes |> Map.keys() |> Enum.join(", ")

  def changed_fields(_changes), do: nil

  attr :id, :string, required: true
  attr :versions, :list, required: true
  attr :loading, :boolean, required: true
  attr :page, :integer, required: true
  attr :per_page, :integer, required: true
  attr :total, :integer, required: true
  attr :preview_id, :any, default: nil

  attr :master_ids, :any,
    default: MapSet.new(),
    doc: "`master_ids/1` of `:versions`, so a master's version reads \"Master\" to a site user."

  attr :empty_title, :string, default: nil
  attr :empty_hint, :string, default: nil

  # Event names, so a consumer with different handlers (e.g. the runtime preview modal) can reuse the
  # same panel. Defaults are the contract the blog pages already implement. Toggle/restore carry BOTH
  # `phx-value-version-id` and `phx-value-id`, and the pager carries `phx-value-page`, so a handler can
  # read whichever key it expects.
  attr :toggle_event, :string, default: "toggle_version_preview"
  attr :restore_event, :string, default: "restore_version"
  attr :prev_event, :string, default: "versions_prev_page"
  attr :next_event, :string, default: "versions_next_page"

  @doc """
  The scrolling list of versions and the pager under it.

  `:preview_id` is the one version whose changes are open; the list is an accordion, so at most one
  is. The "Current" badge is only correct on the first page — it marks the newest version, and page
  two's first row is not that.
  """
  def panel(assigns) do
    ~H"""
    <div
      id={@id}
      class="max-h-[min(60vh,520px)] overflow-y-auto px-[22px] py-4 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
    >
      <div :if={@loading} class="flex items-center justify-center gap-2.5 py-10">
        <span class="size-4 animate-spin rounded-full border-2 border-[#e0ddd6] border-t-[#5b57d6]" />
        <span class="text-[12px] font-medium text-[#8a877f]">
          {gettext("Loading versions…")}
        </span>
      </div>

      <div
        :if={!@loading and @versions == []}
        class="flex flex-col items-center rounded-[12px] border border-dashed border-[#e6e4de] py-9 text-center"
      >
        <span class="mb-[9px] grid size-10 place-items-center rounded-[11px] bg-[#f4f3ee] text-[#c3c0b8]">
          <.icon name="hero-document-text" class="size-[18px]" />
        </span>
        <span class="text-[12.5px] font-semibold text-[#a8a5a0]">
          {@empty_title || gettext("No version history yet")}
        </span>
        <span class="mt-[3px] text-[11px] font-medium text-[#c3c0b8]">
          {@empty_hint || gettext("Edits to this record will be recorded here.")}
        </span>
      </div>

      <div :if={!@loading and @versions != []} class="flex flex-col gap-2.5">
        <div
          :for={{version, index} <- Enum.with_index(@versions)}
          id={"#{@id}-#{version.id}"}
          class={[
            "rounded-[12px] border p-3.5 transition-colors",
            (@preview_id == version.id && "border-[#dcdbf5] bg-[#faf9ff]") ||
              "border-[#f0efea] bg-white"
          ]}
        >
          <div class="flex items-start gap-3 max-[560px]:flex-col!">
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-2">
                <span class="font-['Space_Grotesk'] text-[12.5px] font-semibold text-[#1b1a18]">
                  {Calendar.strftime(version.version_inserted_at, "%Y-%m-%d %H:%M:%S")}
                </span>

                <span
                  :if={index == 0 and @page == 1}
                  class="rounded-md bg-[#fbf1df] px-2 py-[3px] text-[9.5px] font-bold uppercase tracking-[0.03em] text-[#a5691a]"
                >
                  {gettext("Current")}
                </span>

                <span class={[
                  "rounded-md px-2 py-[3px] text-[9.5px] font-bold uppercase tracking-[0.03em]",
                  action_color(version.version_action_name)
                ]}>
                  {action_label(version.version_action_name)}
                </span>

                <span
                  id={"#{@id}-#{version.id}-author"}
                  class="inline-flex items-center gap-1.5 text-[11px] font-medium text-[#8a877f]"
                >
                  <.icon name="hero-user" class="size-3 text-[#a8a5a0]" />
                  <span dir="auto">{author(version, @master_ids)}</span>
                </span>
              </div>

              <div class="mt-1.5 truncate text-[11px] font-medium text-[#a8a5a0]">
                {changed_fields(version.changes) || gettext("No fields changed")}
              </div>
            </div>

            <div class="flex flex-none flex-wrap items-center justify-end gap-2 max-[560px]:w-full!">
              <button
                type="button"
                phx-click={@toggle_event}
                phx-value-version-id={version.id}
                phx-value-id={version.id}
                aria-expanded={to_string(@preview_id == version.id)}
                class={[
                  "inline-flex h-8 items-center gap-1.5 rounded-[9px] border px-2.5 text-[11.5px] font-semibold transition-colors",
                  (@preview_id == version.id && "border-[#dcdbf5] bg-[#f2f1fc] text-[#4f4bcc]") ||
                    "border-[#ecebe6] bg-white text-[#5c5a54] hover:bg-[#f7f6f3]"
                ]}
              >
                <.icon name="hero-eye" class="size-3.5" />
                {(@preview_id == version.id && gettext("Hide")) || gettext("Show")}
              </button>

              <button
                type="button"
                phx-click={@restore_event}
                phx-value-version-id={version.id}
                phx-value-id={version.id}
                data-confirm={
                  gettext(
                    "Are you sure you want to restore this version? Current data will be replaced."
                  )
                }
                class="inline-flex h-8 items-center gap-1.5 rounded-[9px] border border-[#c9e6d5] bg-[#eaf7ef] px-2.5 text-[11.5px] font-semibold text-[#177a53] transition-colors hover:bg-[#ddf1e5]"
              >
                <.icon name="hero-arrow-path" class="size-3.5" /> {gettext("Restore")}
              </button>
            </div>
          </div>

          <div
            :if={@preview_id == version.id}
            class="mt-3 rounded-[10px] border border-[#e4e2f7] bg-white p-3"
          >
            <div class="mb-2.5 flex items-center gap-2">
              <.icon name="hero-document-text" class="size-3.5 text-[#5b57d6]" />
              <span class="text-[11.5px] font-bold text-[#1b1a18]">
                {gettext("Version changes")}
              </span>
            </div>

            <div
              :if={changed_fields(version.changes)}
              class="flex flex-col gap-2.5"
            >
              <div :for={{field, value} <- version.changes}>
                <div class="mb-1 text-[10px] font-bold uppercase tracking-[0.05em] text-[#a8a5a0]">
                  {field |> to_string() |> String.replace("_", " ")}
                </div>
                <div
                  dir="auto"
                  class={[
                    "max-h-40 overflow-y-auto whitespace-pre-wrap break-all rounded-lg bg-[#faf9f6] p-2 font-mono text-[11.5px] [scrollbar-width:none] [&::-webkit-scrollbar]:hidden",
                    (is_nil(value) && "italic text-[#a8a5a0]") || "text-[#3a382f]"
                  ]}
                >
                  {change_value(value)}
                </div>
              </div>
            </div>

            <p
              :if={!changed_fields(version.changes)}
              class="text-[11.5px] font-medium italic text-[#a8a5a0]"
            >
              {gettext("No changes recorded")}
            </p>
          </div>
        </div>
      </div>
    </div>

    <div
      :if={!@loading and @versions != []}
      id={"#{@id}-pager"}
      class="flex flex-wrap items-center justify-between gap-3 border-t border-[#f0efea] px-[22px] py-3.5"
    >
      <span class="text-[12px] font-semibold text-[#a8a5a0]">
        {gettext("Showing %{first}–%{last} of %{total}",
          first: (@page - 1) * @per_page + 1,
          last: min(@page * @per_page, @total),
          total: @total
        )}
      </span>

      <div class="ms-auto flex items-center gap-2">
        <button
          type="button"
          phx-click={@prev_event}
          phx-value-page={@page - 1}
          disabled={@page == 1}
          class="h-9 rounded-[9px] border border-[#ecebe6] bg-white px-3.5 text-[12px] font-semibold text-[#6d6a63] transition-colors hover:bg-[#f7f6f3] disabled:cursor-default disabled:bg-[#f6f5f2] disabled:text-[#c3c0b8]"
        >
          {gettext("Previous")}
        </button>

        <span class="text-[12px] font-semibold text-[#8a877f]">
          {@page} / {last_page(@total, @per_page)}
        </span>

        <button
          type="button"
          phx-click={@next_event}
          phx-value-page={@page + 1}
          disabled={@page >= last_page(@total, @per_page)}
          class="h-9 rounded-[9px] border border-[#ecebe6] bg-white px-3.5 text-[12px] font-semibold text-[#6d6a63] transition-colors hover:bg-[#f7f6f3] disabled:cursor-default disabled:bg-[#f6f5f2] disabled:text-[#c3c0b8]"
        >
          {gettext("Next")}
        </button>
      </div>
    </div>
    """
  end
end
