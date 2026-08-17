defmodule MishkaCmsCore.Runtime.PageBuilder.AiBackend do
  @moduledoc """
  The seam the Assistant rail talks to, and an honest default that does not pretend to be an AI.

  The rail's UI is real: the conversation, the scope bound to the live selection, and per-message
  **Restore** wired to genuine `EditorSession` history entries. What is stubbed is only the part
  that would need a model — and `Echo` says so in its reply rather than fabricating an edit. A
  suggestion the editor cannot actually make must not look like one it made.

      config :mishka_cms_core, :builder_ai_backend, MyApp.RealAssistant

  A real backend returns the same `t:message/0`, optionally carrying `ops` — validated
  `MishkaCmsCore.Runtime.PageBuilder.Op` structs the session applies through the ordinary funnel, so
  an AI edit is undoable, containment-checked and plugin-visible exactly like a human one.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  @type scope :: %{node_id: String.t() | nil, label: String.t()}
  @type message :: %{
          role: :ai | :user,
          text: String.t(),
          plain: String.t() | nil,
          scope: String.t() | nil,
          ops: [map()]
        }

  @callback name() :: String.t()
  @callback ask(String.t(), scope(), keyword()) :: {:ok, message()} | {:error, term()}

  @doc "The configured backend."
  @spec adapter() :: module()
  def adapter do
    Application.get_env(
      :mishka_cms_core,
      :builder_ai_backend,
      MishkaCmsCore.Runtime.PageBuilder.AiBackend.Echo
    )
  end

  @doc """
  Asks the configured backend for a change, scoped to the current selection.

  `opts` names the document being edited — `:token`, `:section`, `:resource_id`, `:site_id` — so a
  backend that would rather write its own ops than return them has the handle
  `MishkaCmsCore.Runtime.PageBuilder.EditorSession` is addressed by.
  """
  @spec ask(String.t(), scope(), keyword()) :: {:ok, message()} | {:error, term()}
  def ask(prompt, scope, opts \\ []), do: adapter().ask(prompt, scope, opts)

  @doc """
  Whether a real backend is configured.

  The rail says so plainly either way. Claiming "Connected" while the default Echo is answering
  would make its honest "no model is configured" reply read as a malfunction instead of the truth.
  """
  @spec connected?() :: boolean()
  def connected?, do: adapter() != MishkaCmsCore.Runtime.PageBuilder.AiBackend.Echo

  @doc "One line about the configured backend, for the rail's Advanced settings panel."
  @spec adapter_note() :: String.t()
  def adapter_note do
    case connected?() do
      true ->
        gettext(
          "Edits this assistant makes go through the same op funnel as your own, so they are undoable."
        )

      false ->
        gettext(
          "No model is connected. Set `config :mishka_cms_core, :builder_ai_backend` to one, and its edits will run through the same undoable op funnel as yours."
        )
    end
  end

  @doc "A user's own message, for appending to the transcript before the backend answers."
  @spec user_message(String.t(), scope()) :: message()
  def user_message(text, scope) do
    %{role: :user, text: text, plain: nil, scope: scope[:label], ops: [], attachment: nil}
  end
end

defmodule MishkaCmsCore.Runtime.PageBuilder.AiBackend.Echo do
  @moduledoc """
  The default assistant: it restates the request, names the scope it would act on, and says plainly
  that no model is configured.

  This is deliberately not a fake. An assistant that invented plausible-sounding edits it never made
  would be worse than none, and the rail is useful before a model exists precisely because the
  scope, the transcript and Restore are all real.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  @behaviour MishkaCmsCore.Runtime.PageBuilder.AiBackend

  @impl true
  def name, do: gettext("Echo (no model configured)")

  @impl true
  def ask(prompt, scope, _opts) do
    {:ok,
     %{
       role: :ai,
       text:
         gettext(
           "No AI backend is configured, so I cannot make this change: %{prompt}. Set `config :mishka_cms_core, :builder_ai_backend` to connect one.",
           prompt: String.trim(prompt)
         ),
       plain: gettext("Nothing was changed — this editor has no assistant connected yet."),
       scope: scope[:label],
       ops: []
     }}
  end
end
