# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.ContentEditorStyles do
  @moduledoc """
  The stylesheet the content editor draws its previews with: the site's own, and the classes of
  every component its palette offers.

  The admin's stylesheet is built from the admin's templates, and a site's from the templates its
  pages reach and the components its saved content names. Neither holds a component an author has
  just placed, nor the variant or colour they just picked — `chelekom-blockquote` turned `shadow`
  and `secondary` in the settings, and its preview stayed as it was. This builds, ahead, what the
  site's pages will be styled with once content using any of those components is saved.

  It is built with `MishkaCmsCore.Runtime.Compilers.TailwindCompiler.compile_preview/4`, against a
  template naming each component the palette offers, kept in `AssetsState` under `key/1` and served
  by `MishkaCmsCoreWeb.AssetsController` at `href/2` — to a master admin, or an admin of that site.
  It is built again only when the site's own stylesheet or the palette's components change, and
  stays as it is otherwise.

  A record with no site — only a master edits one — is previewed with the base every site starts
  from and the global components, built the same way under `key(nil)`.

  The editor draws each preview in a shadow root, so a theme variable the stylesheet declares on
  `:root` alone is declared on `:host` too, and so is the starting value of every variable it
  registers with `@property` — a rule a shadow root ignores, which left a border with no style and
  an `::after` with no content: a timeline drew without the line joining its items.
  """

  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler
  alias MishkaCmsCore.Runtime.ContentComponents
  alias MishkaCmsCore.Runtime.States.{AssetsState, SiteState}

  @prefix "content-editor-"
  @global "__global__"
  @shared_base "__shared_base__"
  @name ~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/

  @doc """
  The `AssetsState` id the editor's stylesheet for the site `site_id` is kept under, `nil` for a
  record with no site.
  """
  @spec key(String.t() | nil) :: String.t()
  def key(nil), do: @prefix <> @global
  def key(site_id) when is_binary(site_id), do: @prefix <> site_id

  @doc """
  The site id of an `AssetsState` id `key/1` made for a site, or `:error` for any other — the one
  for no site among them.
  """
  @spec site_of(String.t()) :: {:ok, String.t()} | :error
  def site_of(@prefix <> @global), do: :error
  def site_of(@prefix <> site_id), do: {:ok, site_id}
  def site_of(_id), do: :error

  @doc "The address the stylesheet kept under `key` with `hash` is served at."
  @spec href(String.t(), String.t()) :: String.t()
  def href(key, hash), do: "/assets/css/#{URI.encode_www_form(key)}/#{hash}"

  @doc """
  The stylesheet for the site `site_id` and the components `names`, built when it is missing or
  was built from another site stylesheet or other components: `{:ok, href}`, or `{:error, reason}`
  when it does not build or the site is unknown.
  """
  @spec ensure(String.t() | nil, [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def ensure(site_id, names) when (is_binary(site_id) or is_nil(site_id)) and is_list(names) do
    with {:ok, scope, base} <- scope(site_id) do
      names = names |> Enum.filter(&(is_binary(&1) and Regex.match?(@name, &1))) |> Enum.sort()
      key = key(site_id)
      template = template(names)
      hash = fingerprint(base, template)

      case AssetsState.hash(key, "css") do
        ^hash -> {:ok, href(key, hash)}
        _missing_or_stale -> build(scope, template, key, hash)
      end
    end
  end

  # Where the components are read from, and the stylesheet the result starts from.
  defp scope(nil), do: {:ok, @global, @shared_base}

  defp scope(site_id) do
    case SiteState.get(site_id) do
      {:ok, %{name: site_name}} -> {:ok, site_name, site_name}
      _unknown -> {:error, :unknown_site}
    end
  end

  # Every component named, and the notice a preview draws in place of one that cannot be drawn.
  defp template(names) do
    [
      ~s(<span class="#{ContentComponents.unavailable_class()}"></span>)
      | Enum.map(names, &~s(<.component component_name="#{&1}" />))
    ]
    |> Enum.join("\n")
  end

  # What the stylesheet is built from: the stylesheet it starts from, by its hash, and the template.
  defp fingerprint(base, template) do
    :md5
    |> :crypto.hash([AssetsState.hash(base, "css") || "", "\n", template])
    |> Base.encode16(case: :lower)
  end

  defp build(site_name, template, key, hash) do
    case TailwindCompiler.compile_preview(
           site_name,
           "content_editor_" <> hash,
           "content",
           template
         ) do
      {:ok, css} ->
        :ok =
          AssetsState.save(%{
            id: key,
            type: "css",
            value: hosted(css),
            hash: hash,
            updated_at: DateTime.utc_now()
          })

        {:ok, href(key, hash)}

      {:error, _reason} = error ->
        error
    end
  end

  # What a document gives a stylesheet and a shadow root does not: `:root`, and the variables
  # `@property` registers, each declared with its starting value where every element can read it —
  # in the lowest layer, so any utility setting one still wins.
  defp hosted(css) do
    css = String.replace(css, ":root{", ":root,:host{")

    case Regex.scan(~r/@property\s+(--[\w-]+)\s*\{([^}]*)\}/, css) do
      [] ->
        css

      registered ->
        starting =
          registered
          |> Enum.uniq_by(fn [_rule, name, _body] -> name end)
          |> Enum.map_join(";", fn [_rule, name, body] -> name <> ":" <> starting_value(body) end)

        css <> "\n@layer properties{:host,*,:before,:after,::backdrop{" <> starting <> "}}"
    end
  end

  defp starting_value(body) do
    case Regex.run(~r/initial-value\s*:\s*([^;]+)/, body) do
      [_declaration, value] -> String.trim(value)
      nil -> "initial"
    end
  end
end
