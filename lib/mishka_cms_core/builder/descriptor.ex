defmodule MishkaCmsCore.Builder.Descriptor do
  @moduledoc """
  The one validated shape every page-builder registry entry takes — an inspector section, a right-rail
  tab, a Studio tab, a canvas toolbar action, a command-palette command, an audit check, a
  marketplace source, an AI backend.

  §28 lists these as eight separate structs that all carry the same six fields. They are one struct
  here, with `kind` naming which registry an entry belongs to, because the alternative is eight
  modules differing only in their moduledoc — and one shape means a plugin author learns the
  contract once and `Events.collect/2` can sort and de-duplicate every registry with the same code.

  `render` and `run` are `{module, function}` tuples or a LiveComponent module, **never closures**:
  a descriptor travels through a `MishkaInstaller` hook payload, which is plain-map only. This is the
  `MishkaCmsCore.Dashboard.Widget` rule, for the same reason.

  ## Permissions

  `permissions` is a list of permission names where holding **any** is enough, checked the same way
  a dashboard widget's is. An empty list means everyone who can open the builder sees it. A section
  a viewer may not see is filtered out of the registry, so it never renders and its events never
  fire.
  """

  require Logger
  require MishkaCmsCore.Runtime.PageBuilder.Strict

  alias MishkaCmsCore.Runtime.PageBuilder.Strict
  use GuardedStruct

  @kinds [
    :palette_entry,
    :inspector_section,
    :rail_tab,
    :studio_tab,
    :toolbar_action,
    :command,
    :audit_check,
    :marketplace_source,
    :ai_backend,
    :node_kind,
    :interaction
  ]

  guardedstruct do
    field(:key, :string, enforce: true, derives: "sanitize(trim) validate(string, not_empty)")

    field(:kind, :atom,
      enforce: true,
      derives:
        "validate(enum=Atom[palette_entry::inspector_section::rail_tab::studio_tab::toolbar_action::command::audit_check::marketplace_source::ai_backend::node_kind::interaction])"
    )

    field(:label, :string, derives: "sanitize(trim)")
    field(:description, :string, derives: "sanitize(trim)")
    field(:icon, :string)
    field(:group, :string)
    field(:permissions, list(), default: [])
    field(:priority, :integer, default: 50)
    field(:render, any())
    field(:run, any())
    field(:shortcut, :string)
    field(:config, :map, default: %{})
  end

  @doc "Every registry a descriptor can belong to."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  A descriptor's de-duplication key. Tolerates a plain map so a plugin that builds its entry by hand
  instead of through `builder/1` still sorts and de-duplicates rather than crashing the registry.
  """
  @spec key(map()) :: String.t()
  def key(%{key: key}) when is_binary(key), do: key
  def key(%{"key" => key}) when is_binary(key), do: key

  # AN ATOM IS A KEY TOO. A registry seeded by the core often names its entries with atoms, and
  # falling through to `inspect/1` on the whole map made every entry unique — so de-duplication,
  # which is what stops a plugin silently redefining a core entry, quietly did nothing.
  def key(%{key: key}) when is_atom(key) and not is_nil(key), do: Atom.to_string(key)
  def key(%{"key" => key}) when is_atom(key) and not is_nil(key), do: Atom.to_string(key)
  def key(other), do: inspect(other)

  @doc "A descriptor's sort priority; anything unreadable sorts last."
  @spec priority(map()) :: integer()
  def priority(%{priority: priority}) when is_integer(priority), do: priority
  def priority(%{"priority" => priority}) when is_integer(priority), do: priority
  def priority(_other), do: 100

  @doc "A descriptor's display label, falling back to its key."
  @spec label(map()) :: String.t()
  def label(%{label: label}) when is_binary(label), do: label
  def label(descriptor), do: key(descriptor)

  @doc """
  Whether `user` may see this descriptor — an empty permission list means everyone, otherwise
  holding any one of the listed permissions is enough.
  """
  @spec permitted?(map(), map() | nil) :: boolean()
  def permitted?(%{permissions: []}, _user), do: true
  def permitted?(%{permissions: nil}, _user), do: true

  def permitted?(%{permissions: permissions}, user) when is_list(permissions),
    do: Enum.any?(permissions, &MishkaCmsCore.Settings.permitted?(%{permission: &1}, user))

  def permitted?(_descriptor, _user), do: true

  @doc "Filters a collected registry down to what this viewer may see."
  @spec permitted(list(), map() | nil) :: list()
  def permitted(descriptors, user), do: Enum.filter(descriptors, &permitted?(&1, user))

  @doc """
  Renders a descriptor's component with `assigns`. A descriptor whose render ref is missing or
  raises degrades to nothing rather than taking the panel down — the extension-isolation boundary
  the runtime already applies to broken templates.
  """
  @spec render(map(), map()) :: Phoenix.LiveView.Rendered.t() | nil
  def render(%{render: {module, function}} = descriptor, assigns) do
    apply(module, function, [assigns])
  rescue
    error ->
      # THE PROMISE THIS DOCSTRING MAKES, KEPT. It was a bare `apply`, so an extension whose
      # component raised took the whole panel down with it — the opposite of the isolation the
      # runtime already gives a broken template. Development still stops, because there the author
      # is the person who can fix it.
      Strict.violation!(
        "Builder.Descriptor.render/2",
        "#{inspect(module)}.#{function}/1 raised: #{Exception.message(error)}"
      )

      Logger.error(
        "[Builder.Descriptor] #{key(descriptor)} could not be drawn: #{Exception.message(error)}"
      )

      nil
  end

  def render(_descriptor, _assigns), do: nil
end
