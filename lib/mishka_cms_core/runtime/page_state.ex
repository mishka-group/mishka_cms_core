defmodule MishkaCmsCore.Runtime.PageState do
  @moduledoc """
  A database page's starting state: the assigns it declares in `Page.state`, put on the socket by
  the LiveView that serves the page.

  A page module is not a LiveView — `MishkaCmsWeb.RuntimeLive` owns `mount/3` and
  `handle_params/3` — so until a page could declare these, its template could not read `@count`
  before an event had assigned it. The ways around it were a default in every expression
  (`assigns[:count] || 0`, wrong for `false`) or a helper handed `assigns`, and LiveView cannot track
  what a function does with `assigns`: every update re-sent each such expression.

  ## What the compiler emits

  `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler.build_page_state/1` turns

      state: [%{name: "count", code: "0"}, %{name: "roles", code: "roles()"}]

  into

      def __page_state__, do: %{count: 0, roles: roles()}
      def __page_state_keys__, do: [:count, :roles]

  `__page_state__/0` runs once per visitor, when the page is mounted — the expressions may call the
  page's helpers, and `DateTime.utc_now/0` is fresh for each visitor. `__page_state_keys__/0` is a
  literal, so the runtime can tell which keys a page owns without running its code.

  ## Where the runtime calls this

    * `assign_initial/2` — `mount/3`, once the page module is known.
    * `switch/3` — `handle_params/3`. Only when the address now names ANOTHER page in the same
      process: that page's state is assigned and the keys only the previous page declared become
      `nil`, so nothing travels from one page to the next. The same page — a query string that
      changed, or the call right after `mount/3` — keeps the visitor's state untouched.
    * `fill_missing/2` — when the page is edited while it is open: the keys the new version
      declares and the socket does not have yet are added, so the template's new `@key` does not
      raise; the visitor's own values stay.

  ## Names

  `name` must match `^[a-z_][a-zA-Z0-9_]*$`, must not start with `__`, must be unique in the list
  and must not be one of `reserved/0` — the assigns the runtime and LiveView already own. The atoms
  are created when the page compiles, from names that passed this validation, never at request time.
  """

  import Phoenix.Component, only: [assign: 2]

  @reserved ~w(
    page private acl extra page_module current_site current_path query_params client_request
    runtime_page page_title page_seo page_languages page_editions site_language csp_nonce
    current_user current_tenant uploads flash live_action socket myself streams assigns
    inner_content
  )

  @name ~r/^[a-z_][a-zA-Z0-9_]*$/

  @doc "The assign names a page's state may not take."
  @spec reserved() :: [String.t()]
  def reserved, do: @reserved

  @doc "Whether `name` may name a state entry, before uniqueness."
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name),
    do:
      Regex.match?(@name, name) and not String.starts_with?(name, "__") and
        name not in @reserved

  def valid_name?(_name), do: false

  @doc """
  The page's starting state, evaluated now — `%{}` for a module compiled before state existed or
  for a page that declares none.
  """
  @spec of(module() | nil) :: map()
  def of(module) when is_atom(module) and not is_nil(module) do
    case function_exported?(module, :__page_state__, 0) do
      true -> module.__page_state__()
      false -> %{}
    end
  end

  def of(_module), do: %{}

  @doc "The keys `module` declares, without running its code."
  @spec keys(module() | nil) :: [atom()]
  def keys(module) when is_atom(module) and not is_nil(module) do
    case function_exported?(module, :__page_state_keys__, 0) do
      true -> module.__page_state_keys__()
      false -> []
    end
  end

  def keys(_module), do: []

  @doc "Puts the page's starting state on the socket. A page that declares none is untouched."
  @spec assign_initial(Phoenix.LiveView.Socket.t(), module()) :: Phoenix.LiveView.Socket.t()
  def assign_initial(socket, module) do
    case keys(module) do
      [] -> socket
      _declared -> assign(socket, of(module))
    end
  end

  @doc """
  Moves the socket from `previous`'s state to `module`'s, when they are different pages.

  The keys only `previous` declared become `nil`; `module`'s are assigned from scratch. The same
  module answers the socket untouched.
  """
  @spec switch(Phoenix.LiveView.Socket.t(), module() | nil, module()) ::
          Phoenix.LiveView.Socket.t()
  def switch(socket, module, module), do: socket

  def switch(socket, previous, module) do
    declared = keys(module)

    stale =
      for key <- keys(previous),
          key not in declared,
          Map.has_key?(socket.assigns, key),
          into: %{},
          do: {key, nil}

    socket
    |> assign(stale)
    |> assign_initial(module)
  end

  @doc """
  Adds the keys `module` declares that the socket does not have yet, and leaves every other value
  as the visitor left it.
  """
  @spec fill_missing(Phoenix.LiveView.Socket.t(), module()) :: Phoenix.LiveView.Socket.t()
  def fill_missing(socket, module) do
    case Enum.reject(keys(module), &Map.has_key?(socket.assigns, &1)) do
      [] -> socket
      missing -> assign(socket, Map.take(of(module), missing))
    end
  end
end
