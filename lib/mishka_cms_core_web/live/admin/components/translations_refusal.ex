defmodule MishkaCmsCoreWeb.Live.Admin.Components.TranslationsRefusal do
  @moduledoc """
  The alert an admin sees when archiving, or deleting for good, an original edition is refused
  because its translations are still live — with a button that archives (or deletes for good) those
  translations at once, after a confirmation naming them.

  The admin layout (`MishkaCmsCore.Layouts`) renders it once, beside the flash messages, so every
  admin page has it. A table reaches it through `MishkaCmsCore.LanguageEditions.on_delete_refused/3`,
  which calls `show/2`. It shows the refusal's own message at once, then reads the originals and
  their live translations as the signed-in admin, off the page's process
  (`MishkaCmsCore.LanguageEditions.refusal/3`). The button is drawn only when that admin may act on
  every one of those translations, and pressing it runs
  `MishkaCmsCore.LanguageEditions.take_translations/2` as that admin. It then reads the originals
  again: one with no live translation left can be deleted now, and one with a translation added in
  the meantime is shown again with the button for it. When that read crashes, the alert says the
  button is not coming.

  DOM ids: `translations-refusal-alert` (the alert), `translations-refusal-message`,
  `translations-refusal-act` (the button, its `data-confirm` naming the translations),
  `translations-refusal-done`, `translations-refusal-failed` and `translations-refusal-dismiss`.
  """
  use Phoenix.LiveComponent
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  alias MishkaCmsCore.LanguageEditions
  alias MishkaCmsCore.Runtime.Languages

  @id "translations-refusal"

  @doc "The DOM id, and the component id `show/2` updates."
  @spec id() :: String.t()
  def id, do: @id

  @doc """
  Shows the alert for `refused` — `MishkaCmsCore.LanguageEditions.refused_originals/1` of a failed
  destroy on `resource`. Call it from the page's process.
  """
  @spec show(module(), [%{id: String.t(), message: String.t()}]) :: :ok
  def show(resource, refused),
    do: send_update(__MODULE__, id: @id, refused: %{resource: resource, refused: refused})

  @impl true
  def mount(socket),
    do: {:ok, assign(socket, refused: nil, refusal: nil, outcome: nil, current_user: nil)}

  @impl true
  def update(%{refused: %{resource: resource, refused: refused}}, socket) do
    actor = socket.assigns.current_user

    {:ok,
     socket
     |> assign(
       refused: %{resource: resource, refused: refused},
       refusal: LanguageEditions.refusal(resource, refused, nil),
       outcome: nil
     )
     |> MishkaGervaz.Messages.start_async(:load, fn ->
       LanguageEditions.refusal(resource, refused, actor)
     end)}
  end

  def update(assigns, socket),
    do: {:ok, assign(socket, Map.take(assigns, [:id, :current_user]))}

  @impl true
  def handle_async(:load, {:ok, refusal}, socket),
    do: {:noreply, assign(socket, :refusal, refusal)}

  def handle_async(:load, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :outcome, {:failed, unloaded()})}

  @impl true
  def handle_event("act", _params, %{assigns: %{refusal: %{allowed?: true} = refusal}} = socket) do
    %{current_user: actor, refused: %{resource: resource, refused: refused}} = socket.assigns

    case LanguageEditions.take_translations(refusal, actor) do
      :ok ->
        {:noreply,
         assign(socket,
           refusal: LanguageEditions.refusal(resource, refused, actor),
           outcome: {:done, refusal}
         )}

      {:error, message} ->
        {:noreply,
         assign(socket,
           refusal: LanguageEditions.refusal(resource, refused, actor),
           outcome: {:failed, message}
         )}
    end
  end

  def handle_event("act", _params, socket), do: {:noreply, socket}

  def handle_event("dismiss", _params, socket),
    do: {:noreply, assign(socket, refused: nil, refusal: nil, outcome: nil)}

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="contents">
      <div
        :if={@refusal}
        id="translations-refusal-alert"
        role="alert"
        class="pointer-events-auto w-80 rounded-lg px-4 py-3 font-[system-ui,sans-serif] text-[13px] leading-snug text-[#5c3d00] ring-1 ring-[#f0d9a8] [background:#fff8e6] [box-shadow:0_4px_12px_rgba(0,0,0,0.15)] sm:w-96"
      >
        <div class="flex items-start gap-3">
          <.icon name="hero-language" class="mt-0.5 size-5 shrink-0" />
          <div class="min-w-0 flex-1">
            <p :if={match?({:done, _}, @outcome)} id="translations-refusal-done" class="mb-2">
              {done(elem(@outcome, 1), @refusal)}
            </p>
            <p :if={match?({:failed, _}, @outcome)} id="translations-refusal-failed" class="mb-2">
              {elem(@outcome, 1)}
            </p>
            <div
              :if={shown(@refusal, @outcome) != []}
              id="translations-refusal-message"
              class="flex flex-col gap-2"
            >
              <p :for={original <- shown(@refusal, @outcome)}>
                <span
                  :if={length(@refusal.originals) > 1 and original.title}
                  class="font-semibold"
                >
                  {quoted(original.title)}:
                </span>
                {original.message}
              </p>
            </div>
            <button
              :if={@refusal.allowed?}
              id="translations-refusal-act"
              type="button"
              phx-click="act"
              phx-target={@myself}
              data-confirm={confirm(@refusal)}
              class="mt-3 cursor-pointer rounded-md px-3 py-1.5 text-[12px] font-semibold text-white [background:#b45309] hover:opacity-90"
            >
              {label(@refusal.kind)}
            </button>
          </div>
          <button
            id="translations-refusal-dismiss"
            type="button"
            phx-click="dismiss"
            phx-target={@myself}
            aria-label={dgettext("mishka_gervaz", "Close")}
            class="group shrink-0 cursor-pointer self-start"
          >
            <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp unloaded do
    dgettext(
      "mishka_gervaz",
      "The quick action could not be loaded just now. Close this and try the delete again."
    )
  end

  defp label(:destroy), do: dgettext("mishka_gervaz", "Delete the translations for good")
  defp label(_archive), do: dgettext("mishka_gervaz", "Archive the translations")

  defp confirm(%{kind: :destroy} = refusal) do
    dgettext("mishka_gervaz", "Delete %{translations} for good? This can't be undone.",
      translations: translations(refusal)
    )
  end

  defp confirm(refusal) do
    dngettext(
      "mishka_gervaz",
      "Archive %{translations}? You can restore it later.",
      "Archive %{translations}? You can restore them later.",
      count(refusal),
      translations: translations(refusal)
    )
  end

  defp shown(refusal, {:done, _taken}), do: LanguageEditions.still_refused(refusal)
  defp shown(refusal, _outcome), do: refusal.originals

  defp done(taken, refusal) do
    taken
    |> taken_sentence()
    |> upcase_first()
    |> then(
      &Enum.join([&1 | cleared_sentence(taken.kind, LanguageEditions.cleared(refusal))], " ")
    )
  end

  defp taken_sentence(%{kind: :destroy} = taken) do
    dngettext(
      "mishka_gervaz",
      "%{translations} is deleted for good.",
      "%{translations} are deleted for good.",
      count(taken),
      translations: translations(taken)
    )
  end

  defp taken_sentence(taken) do
    dngettext(
      "mishka_gervaz",
      "%{translations} is archived.",
      "%{translations} are archived.",
      count(taken),
      translations: translations(taken)
    )
  end

  defp cleared_sentence(_kind, []), do: []

  defp cleared_sentence(:destroy, cleared),
    do: [
      dgettext("mishka_gervaz", "You can delete %{titles} for good now.", titles: titles(cleared))
    ]

  defp cleared_sentence(_archive, cleared),
    do: [dgettext("mishka_gervaz", "You can delete %{titles} now.", titles: titles(cleared))]

  defp titles(originals), do: originals |> Enum.map(&quoted(&1.title)) |> Languages.join()

  defp quoted(title), do: dgettext("mishka_gervaz", "“%{title}”", title: title)

  defp translations(refusal) do
    refusal
    |> LanguageEditions.still_refused()
    |> Enum.map(fn %{title: title, translations: translations} ->
      dngettext(
        "mishka_gervaz",
        "the %{languages} translation of “%{title}”",
        "the %{languages} translations of “%{title}”",
        length(translations),
        languages: translations |> Enum.map(& &1.language) |> Languages.names(),
        title: title
      )
    end)
    |> Languages.join()
  end

  defp upcase_first(text) do
    case String.next_grapheme(text) do
      {first, rest} -> String.upcase(first) <> rest
      nil -> text
    end
  end

  defp count(refusal), do: refusal.originals |> Enum.map(&length(&1.translations)) |> Enum.sum()
end
