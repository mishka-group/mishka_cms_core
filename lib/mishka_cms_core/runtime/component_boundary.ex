# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.ComponentBoundary do
  @moduledoc """
  Where a component a `[[component …]]` marker names, in stored content, is drawn as a small box
  when it raises while it draws, and the rest of the page draws around it.

  `MishkaCmsCore.Runtime.ContentComponents` draws every marker of `rich_content/1` through `draw/3`
  — a docs note's, a blog post's, any stored content's, a marker inside another marker included —
  so a component that raises takes neither the HTTP response nor the visitor's LiveView with it.

  A page's, a layout's and an error page's own `<.component>` calls are not drawn through it: their
  author sees the component in the builder's canvas, and they render at full speed.

  ## What it catches

  An exception raised while the component's function runs, or while any part of its template is
  evaluated: its expressions, its `:if` and `:for`, the slots it renders and the function
  components it calls.

  A HEEx template is evaluated lazily. The `%Phoenix.LiveView.Rendered{}` a component returns holds
  its values in a closure that LiveView calls later — while it writes the HTTP response, or while it
  diffs the connected render — and by then nothing of this module is on the stack. So `draw/3`
  calls those closures itself, inside the boundary, and hands LiveView a tree whose closures return
  the values already computed. Each closure still runs once, as LiveView would have run it; a
  component that does not raise is drawn from the same values, and only the walk that collects them
  is added.

  A closure is evaluated with change tracking off. When the component is drawn again because its
  attributes changed, every value it draws is sent again, not only the ones that changed. A
  component whose attributes did not change is not drawn again at all, as before.

  ## What it does not catch

    * An exception that names a response status of its own between 400 and 499 — a
      `Plug.Exception`, such as MishkaCmsCore.ErrorsExceptions.NotFoundError or an Ash error that
      answers 403 or 404. That is the page's answer, and it is raised on.
    * A `throw` and an `exit`. LiveView sends redirects as throws, and an exit belongs to the
      process drawing the page.
    * A stateful component. LiveView runs its `update/2` and `render/1` itself, after the page is
      drawn; one that raises stops the visitor's LiveView, as before.
    * A component a page, a layout or an error page names in its own template.
    * Content drawn in the canvas and the previews, which draw through `static_component/1` and
      contain a raise themselves.

  ## The box

  `This component could not be drawn`, in a `<span data-role="component-crashed">` drawn with the
  classes `box_class/0` names and no inline style, so a strict CSP allows it. The error is logged
  with the component's name, its site and the stacktrace, under an error id. A viewer that
  `put_viewer/1` names as a dashboard admin also sees the id in the box; a visitor never does.

  ## Events

    * `runtime:component:crashed` — after a component's raise is contained, with
      `%{component_name: name, site: site, site_id: site_id, error_id: id, error: exception,
      stacktrace: stacktrace}`. `site` is the site's name, `nil` for a global component, and
      `site_id` the site being rendered. Fired with `return: false`: a plugin is told, and its answer
      is not read.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  import Phoenix.Component, only: [sigil_H: 2]

  require Logger

  alias MishkaCmsCore.Accounts.Helper
  alias MishkaCmsCore.Runtime.{CspNonce, Translations}
  alias MishkaInstaller.Event.Hook
  alias Phoenix.LiveView.{Comprehension, Rendered}

  @event "runtime:component:crashed"
  @viewer_key {__MODULE__, :viewer}
  @box_class "inline-block rounded border border-dashed border-gray-300 px-2 py-1 text-sm text-gray-500"

  @doc """
  Draws the component `render` returns, or the box when drawing it raises. A stateful component's
  `%Phoenix.LiveView.Component{}` is returned as it is.

  `name` and `site` are the component's name and its site's name, `nil` for a global component;
  they are what the log and `runtime:component:crashed` name.

      ComponentBoundary.draw("chelekom-alert", "my-site", fn -> MyComponent.alert(assigns) end)
  """
  @spec draw(String.t(), String.t() | nil, (-> Rendered.t() | Phoenix.LiveView.Component.t())) ::
          Rendered.t() | Phoenix.LiveView.Component.t()
  def draw(name, site, render) when is_function(render, 0) do
    render.() |> settled()
  rescue
    error -> contained(error, __STACKTRACE__, name, site)
  end

  @doc """
  Names the signed-in user of the response this process draws, `nil` for a guest.

  A dashboard admin named here sees a contained component's error id in its box. The user is kept
  for this response only — tied to its CSP nonce — so a process that draws a later response draws
  it for nobody until it is named again. Nothing calls it on a page's render path; a host that wants
  its admins to see the id calls it where the user is known, after
  `MishkaCmsCore.LiveUserAuth.load_current_user/1`:

      socket = LiveUserAuth.load_current_user(socket)
      :ok = ComponentBoundary.put_viewer(socket.assigns[:current_user])
  """
  @spec put_viewer(map() | nil) :: :ok
  def put_viewer(user) do
    Process.put(@viewer_key, {CspNonce.current(), user})
    :ok
  end

  @doc """
  The classes the box is drawn with, for whatever builds a site's stylesheet.
  """
  @spec box_class() :: String.t()
  def box_class, do: @box_class

  # The rendered tree with every closure called once, now, with change tracking off — what
  # `Phoenix.HTML.Safe` and `Phoenix.LiveView.Diff` would call later. A tree this module already
  # settled, an inner component's or a box, is kept as it is.
  defp settled(%Rendered{dynamic: dynamic} = rendered) do
    case ours?(dynamic) do
      true ->
        rendered

      false ->
        values = settled_values(dynamic.(false))
        %{rendered | dynamic: fn _track_changes? -> values end}
    end
  end

  defp settled(%Comprehension{entries: entries} = comprehension),
    do: %{comprehension | entries: Enum.map(entries, &settled_entry/1)}

  defp settled(value), do: value

  defp settled_entry({key, vars, render} = entry) do
    case ours?(render) do
      true ->
        entry

      false ->
        values = settled_values(render.(%{}, false))
        {key, vars, fn _vars_changed, _track_changes? -> values end}
    end
  end

  defp settled_values(values), do: Enum.map(values, &settled/1)

  defp ours?(fun), do: :erlang.fun_info(fun, :module) == {:module, __MODULE__}

  defp contained(error, stacktrace, name, site) do
    case Plug.Exception.status(error) do
      status when status in 400..499 -> reraise error, stacktrace
      _failure -> crashed(error, stacktrace, name, site)
    end
  end

  defp crashed(error, stacktrace, name, site) do
    error_id = 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    site_id = Translations.site()

    Logger.error(
      "[Runtime] component #{name} of site #{site || "Global"} could not be drawn " <>
        "(error #{error_id}, rendering site #{inspect(site_id)})\n" <>
        Exception.format(:error, error, stacktrace),
      error_id: error_id,
      component: name
    )

    Hook.call(
      @event,
      %{
        component_name: name,
        site: site,
        site_id: site_id,
        error_id: error_id,
        error: error,
        stacktrace: stacktrace
      },
      return: false
    )

    box(%{error_id: shown(error_id), class: @box_class})
  end

  defp shown(error_id) do
    case Process.get(@viewer_key) do
      {nonce, user} when is_binary(nonce) and is_map(user) ->
        if nonce == CspNonce.current() and Helper.dashboard_admin?(user), do: error_id

      _nobody ->
        nil
    end
  end

  # One line, so no whitespace is drawn around the words.
  defp box(assigns) do
    ~H"""
    <span data-role="component-crashed" data-error-id={@error_id} class={@class}>{gettext("This component could not be drawn")}<span :if={@error_id}> · {@error_id}</span></span>
    """noformat
  end
end
