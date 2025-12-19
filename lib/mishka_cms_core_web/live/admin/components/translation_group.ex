defmodule MishkaCmsCoreWeb.Live.Admin.Components.TranslationGroup do
  @moduledoc """
  One word in every language — the body of the admin Translations modal and of the visual editor's
  Translations sheet alike. A chip per language with its translation, or "Missing", beside it, and
  Gervaz's `MishkaCmsCore.Runtime.Translation` form for the one picked.

  Both pages keep the group in `:translation_group` and move it only through these, so the two
  cannot drift apart:

    * `open/2` — a row's Translate: the key of that row, the first missing language picked
    * `pick/2` — a click on a language
    * `saved/1` — after the form saves: read again, and on to the next missing language
    * `add_language/2` — the word in one more language, published on its site first if need be
    * `close/1`

  The picker sends `"translation_pick"` to the page with the row's `id`, and the add row
  `"translation_add_language"` with the typed `language`.
  """
  use Phoenix.Component
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.LanguageAccent
  alias MishkaCmsCore.Runtime.{Languages, Translation, Translations}

  @doc "Opens the key the row `id` belongs to, the first language still missing picked."
  @spec open(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def open(socket, id) do
    case Translations.group(socket.assigns.current_user, id) do
      {:ok, group} ->
        assign(
          socket,
          :translation_group,
          Map.put(group, :picked, next_missing(group, nil) || id)
        )

      {:error, :not_found} ->
        socket
        |> assign(:translation_group, nil)
        |> Phoenix.LiveView.put_flash(
          :error,
          dgettext("mishka_gervaz", "That word is no longer there.")
        )
    end
  end

  @doc "Picks the language row `id`, if it is one of the open key's."
  @spec pick(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def pick(%{assigns: %{translation_group: %{rows: rows} = group}} = socket, id) do
    if Enum.any?(rows, &(&1.id == id)),
      do: assign(socket, :translation_group, %{group | picked: id}),
      else: socket
  end

  def pick(socket, _id), do: socket

  @doc """
  Reads the open key again after a save, and picks the next language still missing after the one
  just saved — or keeps it, when none is.
  """
  @spec saved(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def saved(%{assigns: %{translation_group: %{picked: picked}}} = socket) do
    case Translations.group(socket.assigns.current_user, picked) do
      {:ok, group} ->
        assign(
          socket,
          :translation_group,
          Map.put(group, :picked, next_missing(group, picked) || picked)
        )

      {:error, :not_found} ->
        close(socket)
    end
  end

  def saved(socket), do: socket

  @doc """
  Adds `language` to the open word — see `Translations.add_language/4` for who may, and for the
  master's bounds — and picks the new language's row. A refusal is a flash, the word unchanged.
  """
  @spec add_language(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def add_language(%{assigns: %{translation_group: %{} = group}} = socket, language) do
    actor = socket.assigns.current_user
    code = language |> to_string() |> String.trim() |> String.downcase()

    with {:ok, _still_there} <- Translations.group(actor, group.picked),
         :ok <- Translations.add_language(actor, group.site_id, group.key, code),
         {:ok, reread} <- Translations.group(actor, group.picked) do
      row = Enum.find(reread.rows, &(&1.language == code))

      socket
      |> assign(:translation_group, Map.put(reread, :picked, (row && row.id) || group.picked))
      |> Phoenix.LiveView.put_flash(
        :info,
        dgettext("mishka_gervaz", "%{language} added", language: String.upcase(code))
      )
    else
      {:error, reason} -> Phoenix.LiveView.put_flash(socket, :error, refused(reason, code, group))
    end
  end

  def add_language(socket, _language), do: socket

  defp refused(:forbidden, _code, %{site_id: nil}),
    do: dgettext("mishka_gervaz", "Only a master can add a language to a word every site shares.")

  defp refused(:forbidden, _code, _group),
    do: dgettext("mishka_gervaz", "You can add languages to your own site's words.")

  defp refused(:not_allowed, code, _group) do
    dgettext("mishka_gervaz", "%{language} is not one of the languages a site may publish.",
      language: String.upcase(code)
    )
  end

  defp refused(:not_found, _code, _group),
    do: dgettext("mishka_gervaz", "That word is no longer there.")

  defp refused(_reason, _code, _group),
    do: dgettext("mishka_gervaz", "That is not a language code — try en, fa or pt-br.")

  @doc "Closes the open key."
  @spec close(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def close(socket), do: assign(socket, :translation_group, nil)

  # The first language with no translation, looking after `after_id` first and wrapping round.
  defp next_missing(%{rows: rows}, after_id) do
    {before, rest} = Enum.split_while(rows, &(&1.id != after_id))

    (Enum.drop(rest, 1) ++ before ++ Enum.take(rest, 1))
    |> Enum.find(&(not filled?(&1.value) and &1.id != after_id))
    |> case do
      nil -> nil
      row -> row.id
    end
  end

  attr :id, :string, required: true
  attr :group, :map, required: true
  attr :current_user, :any, required: true

  @doc """
  The key's languages and the form for the picked one — or, for a word the reader may not write,
  its value to read.
  """
  def translation_group(assigns) do
    held = Enum.map(assigns.group.rows, & &1.language)

    assigns =
      assigns
      |> assign(:picked, Enum.find(assigns.group.rows, &(&1.id == assigns.group.picked)))
      |> assign(:writable?, Translations.may_write?(assigns.current_user, assigns.group.site_id))
      |> assign(:addable, Translations.addable_languages(held))

    ~H"""
    <div id={@id} class="space-y-4">
      <div class="min-w-0">
        <p class="text-[11px] font-bold tracking-[0.03em] text-[#8a877f]">
          {if is_nil(@group.site_id),
            do: dgettext("mishka_gervaz", "Global — every site"),
            else: dgettext("mishka_gervaz", "This site")}
        </p>
        <p
          id={@id <> "-key"}
          dir="ltr"
          class="mt-1 break-words font-['Space_Grotesk'] text-[15px] font-bold text-[#1b1a18] rtl:text-right"
        >
          {@group.key}
        </p>
      </div>

      <ul
        id={@id <> "-languages"}
        class="divide-y divide-[#f0efea] overflow-hidden rounded-[12px] border border-[#ecebe6] bg-white"
      >
        <li :for={row <- @group.rows}>
          <button
            type="button"
            id={@id <> "-language-" <> row.language}
            phx-click="translation_pick"
            phx-value-id={row.id}
            aria-pressed={to_string(row.id == @group.picked)}
            aria-label={
              dgettext("mishka_gervaz", "%{language}: %{value}",
                language: String.upcase(row.language),
                value:
                  if(filled?(row.value),
                    do: row.value,
                    else: dgettext("mishka_gervaz", "missing")
                  )
              )
            }
            class={[
              "flex w-full items-center gap-3 px-4 py-2.5 text-start transition-colors hover:bg-[#faf9f6]",
              row.id == @group.picked && "bg-[#f4f2fd] hover:bg-[#f4f2fd]"
            ]}
          >
            <span class={[
              "inline-flex w-11 shrink-0 justify-center rounded-[20px] border px-2 py-[3px] font-['Space_Grotesk'] text-[10px] font-bold",
              chip_class(row)
            ]}>
              {String.upcase(row.language)}
            </span>
            <span
              :if={filled?(row.value)}
              dir={Languages.direction(row.language)}
              class="min-w-0 flex-1 truncate text-[13px] text-[#3a382f]"
            >
              {row.value}
            </span>
            <span
              :if={not filled?(row.value)}
              class="rounded-full bg-[#fdf3e6] px-2 py-[2px] text-[11px] font-semibold text-[#b8741a]"
            >
              {dgettext("mishka_gervaz", "Missing")}
            </span>
          </button>
        </li>
      </ul>

      <form
        :if={@writable?}
        id={@id <> "-add-language"}
        phx-submit="translation_add_language"
        class="flex flex-wrap items-center gap-2"
      >
        <input
          type="text"
          name="language"
          dir="ltr"
          list={@id <> "-addable"}
          required
          autocomplete="off"
          placeholder={
            if @addable == [],
              do: dgettext("mishka_gervaz", "A language code — fr, de…"),
              else: dgettext("mishka_gervaz", "Add a language")
          }
          class="h-9 min-w-0 flex-1 rounded-[10px] border border-[#ecebe6] bg-white px-3 text-[12.5px] text-[#3a382f] outline-none focus:border-[#c3c1f0] focus:shadow-[0_0_0_3px_rgba(91,87,214,0.1)]"
        />
        <datalist id={@id <> "-addable"}>
          <option :for={code <- @addable} value={code}>{String.upcase(code)}</option>
        </datalist>
        <MishkaCmsCore.CoreComponents.button
          id={@id <> "-add-language-submit"}
          variant="soft"
          icon="hero-plus"
        >
          {dgettext("mishka_gervaz", "Add language")}
        </MishkaCmsCore.CoreComponents.button>
      </form>

      <div :if={@picked} id={@id <> "-form"} class="rounded-[12px] border border-[#ecebe6] p-4">
        <p class="mb-3 text-[12px] font-semibold text-[#5c5a54]">
          {dgettext("mishka_gervaz", "Translating into")}
          <span class="font-bold">{String.upcase(@picked.language)}</span>
        </p>
        <.live_component
          :if={@writable?}
          module={MishkaGervaz.Form.Web.Live}
          id={MishkaGervaz.Resource.Info.Form.component_id(Translation)}
          resource={Translation}
          current_user={@current_user}
          record_id={@picked.id}
        />

        <div :if={!@writable?} id={@id <> "-read-only"} class="space-y-2">
          <p
            :if={filled?(@picked.value)}
            dir={Languages.direction(@picked.language)}
            class="break-words rounded-[10px] bg-[#faf9f6] px-3 py-2.5 text-[13px] text-[#3a382f]"
          >
            {@picked.value}
          </p>
          <p
            :if={not filled?(@picked.value)}
            class="inline-block rounded-full bg-[#fdf3e6] px-2 py-[2px] text-[11px] font-semibold text-[#b8741a]"
          >
            {dgettext("mishka_gervaz", "Missing")}
          </p>
          <p class="text-[12px] text-[#8a877f]">{read_only_line(@group)}</p>
        </div>
      </div>
    </div>
    """
  end

  defp read_only_line(%{site_id: nil}),
    do: dgettext("mishka_gervaz", "A global word — only a master can change it.")

  defp read_only_line(_group),
    do: dgettext("mishka_gervaz", "Only a master or an admin of this word's site can change it.")

  defp chip_class(row) do
    if filled?(row.value),
      do: LanguageAccent.for_language(row.language).chip,
      else: "border-dashed border-[#e6c9a3] bg-white text-[#b8741a]"
  end

  defp filled?(value), do: value not in [nil, ""]
end
