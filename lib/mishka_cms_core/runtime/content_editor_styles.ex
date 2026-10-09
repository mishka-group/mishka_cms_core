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

  The editor draws each preview in a shadow root, so a theme variable the stylesheet declares on
  `:root` alone is declared on `:host` too.
  """

  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler
  alias MishkaCmsCore.Runtime.States.{AssetsState, SiteState}

  @prefix "content-editor-"
  @name ~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/

  @doc "The `AssetsState` id the editor's stylesheet for the site `site_id` is kept under."
  @spec key(String.t()) :: String.t()
  def key(site_id) when is_binary(site_id), do: @prefix <> site_id

  @doc """
  The site id of an `AssetsState` id `key/1` made, or `:error` for any other.
  """
  @spec site_of(String.t()) :: {:ok, String.t()} | :error
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
  @spec ensure(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def ensure(site_id, names) when is_binary(site_id) and is_list(names) do
    with {:ok, %{name: site_name}} <- SiteState.get(site_id) do
      names = names |> Enum.filter(&(is_binary(&1) and Regex.match?(@name, &1))) |> Enum.sort()
      key = key(site_id)
      hash = fingerprint(site_name, names)

      case AssetsState.hash(key, "css") do
        ^hash -> {:ok, href(key, hash)}
        _missing_or_stale -> build(site_name, names, key, hash)
      end
    else
      _unknown -> {:error, :unknown_site}
    end
  end

  # What the stylesheet is built from: the site's own stylesheet, by its hash, and the components.
  defp fingerprint(site_name, names) do
    :md5
    |> :crypto.hash([
      AssetsState.hash(site_name, "css") || "",
      "\n" | Enum.intersperse(names, ",")
    ])
    |> Base.encode16(case: :lower)
  end

  defp build(site_name, names, key, hash) do
    template = Enum.map_join(names, "\n", &~s(<.component component_name="#{&1}" />))

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
            value: String.replace(css, ":root{", ":root,:host{"),
            hash: hash,
            updated_at: DateTime.utc_now()
          })

        {:ok, href(key, hash)}

      {:error, _reason} = error ->
        error
    end
  end
end
