defmodule MishkaCmsCore.Runtime.Handlers.UiKitHandler do
  @moduledoc """
  Trivial loader for `mishka.ui_kit.bundle.v3` JSON bundles.

  The bundle is the install plan. Each entry under `components` is the
  exact shape `Ash.create!(MishkaCmsCore.Runtime.Component, params,
  action: :master_create)` accepts. Each entry under `js_hooks` is the
  same for `Runtime.JsHook`. This module performs no transformation
  beyond key atomization, slug-based cleanup of pre-existing rows, and
  optional per-install `site_id` override.

  All semantic decisions (slugged names, sibling cross-call rewriting,
  prelude dedup, type-resolved attrs, dropped struct defaults) live in
  the upstream converter (Chelekom's `mix mishka.ui.export ... --cms`).

      iex> MishkaCmsCore.Runtime.Handlers.UiKitHandler.install_chelekom!()
      iex> MishkaCmsCore.Runtime.Handlers.UiKitHandler.install_chelekom!(site_id: tenant_id)
      iex> MishkaCmsCore.Runtime.Handlers.UiKitHandler.uninstall_chelekom!()
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Builder.FormRole
  alias MishkaCmsCore.Runtime.{Component, JsHook, Stylesheet}
  alias MishkaCmsCore.Runtime.Handlers.RuntimeOrchestrator
  alias MishkaCmsCore.Runtime.Handlers.UiKitUpgrade
  alias MishkaCmsCore.Runtime.PageBuilder.CodeReads
  alias MishkaCmsCore.Runtime.PageBuilder.Markup
  alias MishkaCmsCore.UiKit.Contract

  require Logger
  require Ash.Query

  @kits_dir Path.join([:code.priv_dir(:mishka_cms_core), "cms_ui_kits"])

  @default_bundle_file "chelekom.json"

  # THE OFFICIAL PACKAGES: which files to fetch, never which version. The version is the newest
  # release of `@repo` that attaches them (see `discover/1`), so a new Chelekom release reaches every
  # install without this list changing. `config :mishka_cms_core, :official_ui_kits, […]` names exact
  # files instead — to hold a version, use a fork, or, with `[]`, download nothing at all.
  @packages [
    %{key: :styled, label: gettext_noop("Chelekom — styled"), file: "chelekom.json"},
    %{key: :headless, label: gettext_noop("Chelekom — headless"), file: "chelekom_headless.json"}
  ]

  @repo "mishka-group/mishka_chelekom"

  @channels [:stable, :prerelease, :master]

  @doc """
  The directory the kit bundles are read from and written to: `priv/cms_ui_kits/`, or the
  `config :mishka_cms_core, :ui_kits_dir, path` a host keeps them in instead.
  """
  @spec kits_dir() :: String.t()
  def kits_dir, do: Application.get_env(:mishka_cms_core, :ui_kits_dir, @kits_dir)

  @doc """
  Every UI kit bundle on disk, newest-looking first: `[%{name:, version:, path:, components:}]`.

  The CMS ships one kit today and the generator already exports a second — `mix mishka.ui.export
  priv/headless --cms --name chelekom_headless` — so the installer asks the DIRECTORY what is
  available rather than naming Chelekom in code. Drop a bundle into `priv/cms_ui_kits/` and it is
  offered; nothing else has to change.

  A file that is not a readable v3 bundle is skipped rather than raising: an installer that refuses
  to start because somebody left a note in the kits directory is worse than one that ignores it.
  """
  @spec available_kits(String.t()) :: [
          %{
            name: String.t(),
            version: String.t(),
            path: String.t(),
            components: non_neg_integer()
          }
        ]
  def available_kits(dir \\ kits_dir()) do
    dir
    |> bundle_files()
    |> Enum.map(&describe_kit/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  The path of every `.json` file in the kits directory, sorted, without opening any of them.

  What a cache keyed by the bundles on disk reads: `available_kits/1` parses each bundle, and the
  Chelekom one alone is 10.8 MB.
  """
  @spec bundle_files(String.t()) :: [String.t()]
  def bundle_files(dir \\ kits_dir()),
    do: dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()

  defp describe_kit(path) do
    case load_bundle(path) do
      {:ok, bundle} ->
        %{
          name: bundle["name"],
          version: bundle["version"],
          path: path,
          components: length(bundle["components"] || [])
        }

      _unreadable ->
        nil
    end
  end

  @doc """
  Installs every kit named, or all of them.

  `kits` is a list of bundle NAMES as `available_kits/0` reports them. Each is installed through
  `install_kit!/2`, which is already kit-agnostic — it prefixes its cleanup with the bundle's own
  name, so two kits installed side by side never delete each other's components.
  """
  @spec install_kits!([String.t()] | :all, keyword()) :: :ok
  def install_kits!(kits \\ :all, opts \\ []) do
    available_kits()
    |> Enum.filter(&wanted?(&1, kits))
    |> Enum.each(fn kit ->
      install_kit!(kit.path, Keyword.put(opts, :selection, selection_for(kit, opts)))
    end)
  end

  defp wanted?(_kit, :all), do: true
  defp wanted?(kit, names) when is_list(names), do: kit.name in names

  # A selection is per-kit: `%{"chelekom" => %{components: [...]}}` picks for one kit only, while a
  # bare selection map applies to whichever kit is being installed — what the single-kit installer
  # has always passed.
  defp selection_for(kit, opts) do
    case Keyword.get(opts, :selection, :all) do
      %{} = selection -> Map.get(selection, kit.name, selection)
      other -> other
    end
  end

  @doc "The on-disk path of the Chelekom bundle in `kits_dir/0` (operator-overridable by placing a file there)."
  @spec default_bundle_path() :: String.t()
  def default_bundle_path, do: Path.join(kits_dir(), @default_bundle_file)

  @doc """
  The packages the installer fetches, in order: the host's `:official_ui_kits` when it set them,
  otherwise Chelekom's two. Each carries `:key`, `:label` and `:file`; a configured one also its
  `:tag` and `:url`, while Chelekom's version is found when they are fetched — see `official_kits/1`.
  """
  @spec packages() :: [map()]
  def packages, do: configured_kits() || @packages

  @doc """
  Whether the host names its kits in `config :mishka_cms_core, :official_ui_kits, […]`. Then that
  list is fetched as it is, and no release is looked up — `[]` means nothing is downloaded and only
  the bundles already in `kits_dir/0` are offered, which is what an air-gapped install wants.
  """
  @spec configured?() :: boolean()
  def configured?, do: configured_kits() != nil

  @doc """
  The release channels the installer offers when the kits are not configured: `:stable`, the newest
  release that is not a pre-release; `:prerelease`, the newest of any kind; and `:master`, the
  files committed on Chelekom's `master` branch, which no release has vouched for yet.
  """
  @spec channels() :: [atom()]
  def channels, do: @channels

  @doc """
  The official kits from `channel`, each with the `:tag` an operator reads in the wizard and the
  `:url` it is fetched from: the configured list as it is, or Chelekom's packages as the release
  `channel` finds attaches them — or as `master` holds them, while no release attaches any. `[]`
  when the releases could not be looked up.
  """
  @spec official_kits(atom()) :: [map()]
  def official_kits(channel \\ :stable) do
    case official_source(channel) do
      {:ok, kits, _release} -> kits
      {:error, _reason} -> []
    end
  end

  defp configured_kits, do: Application.get_env(:mishka_cms_core, :official_ui_kits)

  defp official_source(channel) do
    case configured_kits() do
      nil -> discover(channel)
      kits -> {:ok, kits, nil}
    end
  end

  # WHICH RELEASE. `:stable` is the newest release that is not a pre-release and attaches a kit — and
  # while none does, the newest that does, marked `fallback?` so the wizard can say so rather than
  # install a pre-release silently. `:prerelease` is the newest of any kind. `:master` is the files
  # committed on `master`, unreleased, so the branch is all the tag there is — and where every
  # channel ends up, marked `fallback?`, while no published release attaches a kit at all.
  defp discover(:master), do: from_master(false)

  defp discover(channel) do
    with {:ok, releases} <- releases() do
      with_kits = Enum.filter(releases, &attaches_kit?/1)
      pick(channel, Enum.find(with_kits, &(&1["prerelease"] != true)), List.first(with_kits))
    end
  end

  defp pick(_channel, _stable, nil), do: from_master(true)
  defp pick(:stable, nil, newest), do: found(newest, :stable, true)
  defp pick(:stable, stable, _newest), do: found(stable, :stable, false)
  defp pick(:prerelease, _stable, newest), do: found(newest, :prerelease, false)

  defp from_master(fallback?) do
    kits = Enum.map(@packages, &Map.merge(&1, %{tag: "master", url: master_url(&1.file)}))
    {:ok, kits, %{channel: :master, tag: "master", fallback?: fallback?}}
  end

  # A package the release does not attach keeps a `nil` URL, so it is reported as missing rather
  # than silently left out.
  defp found(%{"tag_name" => tag} = release, channel, fallback?) do
    assets = Map.new(release["assets"] || [], &{&1["name"], &1["browser_download_url"]})
    kits = Enum.map(@packages, &Map.merge(&1, %{tag: tag, url: assets[&1.file]}))
    {:ok, kits, %{channel: channel, tag: tag, fallback?: fallback?}}
  end

  defp attaches_kit?(release) do
    files = Enum.map(@packages, & &1.file)
    release["draft"] != true and Enum.any?(release["assets"] || [], &(&1["name"] in files))
  end

  # ONE REQUEST, WITHOUT A TOKEN. GitHub answers sixty an hour from one address, and the wizard asks
  # once a visit; a failure is reported, and the kits already on disk are offered instead.
  defp releases do
    request =
      [
        url: "https://api.github.com/repos/#{repo()}/releases",
        params: [per_page: 30],
        headers: [accept: "application/vnd.github+json"],
        max_retries: 1
      ] ++ req_options()

    case Req.get(request) do
      {:ok, %{status: 200, body: releases}} when is_list(releases) ->
        {:ok, releases}

      {:ok, %{status: status}} ->
        {:error, gettext("GitHub answered HTTP %{status}", status: status)}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp repo, do: Application.get_env(:mishka_cms_core, :ui_kit_repo, @repo)

  defp master_url(file),
    do: "https://raw.githubusercontent.com/#{repo()}/master/priv/cms_ui_kits/#{file}"

  @doc """
  Resolves ONE official kit to a parsed `mishka.ui_kit.bundle.v3` map, local-first.

  If a bundle already exists at the kit's path it is used as-is; otherwise it is downloaded and
  cached there. Kept for the single-kit callers that predate `resolve_kits/1`; raises on failure.
  """
  @spec ensure_bundle!(keyword()) :: map()
  def ensure_bundle!(opts \\ []) do
    kit = Keyword.get_lazy(opts, :kit, fn -> List.first(packages()) end)

    path =
      Keyword.get(opts, :bundle_path) ||
        kit_path(kit, Keyword.get_lazy(opts, :kits_dir, &kits_dir/0))

    case load_bundle(path) do
      {:ok, bundle} ->
        bundle

      {:error, reason} ->
        download_and_cache!(Keyword.get(opts, :url) || url_of(kit), path, reason)
    end
  end

  # Asked only when the file is missing, so a kit on disk never costs a request to GitHub.
  defp url_of(%{url: url}) when is_binary(url), do: url
  defp url_of(kit), do: Enum.find_value(official_kits(), &(&1.key == kit[:key] && &1.url))

  @doc """
  Every kit the installer should offer, as parsed bundles. Raises only when NONE can be resolved.

  See `resolve_kits/1` for the same work with the failures reported rather than discarded.
  """
  @spec ensure_bundles!(keyword()) :: [map()]
  def ensure_bundles!(opts \\ []) do
    case resolve_kits(opts) do
      %{bundles: [], failures: failures} ->
        raise "no UI-kit bundle could be resolved:\n" <>
                Enum.map_join(
                  failures,
                  "\n",
                  &"  #{&1.label} (#{&1.tag}) — #{&1.reason} — #{&1.url}"
                )

      %{bundles: bundles} ->
        bundles
    end
  end

  @doc """
  Every kit the installer should offer, WITH the ones that could not be fetched.

  Returns `%{bundles: [...], sources: [...], failures: [%{key:, label:, tag:, url:, reason:}]}`.

  `:sources` describes what resolved — `%{name:, version:, tag:, official?:}` per bundle — because
  the wizard has to tell an operator which version it is about to install, and joining a bundle back
  to the configured entry by filename would be a guess. The resolver already knows.

  Failures are reported rather than raised because there is more than one official package now: a
  headless bundle that 404s must not take the styled one — or a perfectly good third-party bundle
  sitting on disk — down with it. The wizard names what it could not reach and installs the rest.

  `progress: fun` is called as an official kit downloads — `fun.(key, {received, total})`, in
  bytes, `total` being `nil` when the server does not say — about once a percent. The wizard draws
  its bars from it. A kit read from disk reports nothing.

  `channel:` is a release channel from `channels/0`; `:release` in the answer says which release it
  found — `%{channel:, tag:, fallback?:}`, `nil` for configured kits or none. Without a channel a
  developer's bundle on disk wins (`prefer_local?/0`) and no release is looked up; with one, that
  channel is fetched. `local_only: true` looks nothing up and downloads nothing — the bundles in
  `kits_dir/0` are the answer, which is what the Studio wants.
  """
  @spec resolve_kits(keyword()) :: %{bundles: [map()], failures: [map()]}
  def resolve_kits(opts \\ []) do
    dir = Keyword.get_lazy(opts, :kits_dir, &kits_dir/0)
    progress = Keyword.get(opts, :progress)
    channel = Keyword.get(opts, :channel)
    prefer_local = is_nil(channel) and prefer_local?()
    {official_list, release, lookup_failures} = official_for(opts, channel, prefer_local)

    {resolved, failures} =
      official_list
      |> Enum.map(fn kit ->
        case resolve_official(kit, dir, progress, prefer_local) do
          {:ok, bundle} -> {:ok, {kit, bundle}}
          {:error, failure} -> {:error, failure}
        end
      end)
      |> Enum.split_with(&match?({:ok, _resolved}, &1))

    official = Enum.map(resolved, &elem(&1, 1))

    official_paths = official_list |> Enum.map(&kit_path(&1, dir)) |> MapSet.new()

    # Anything else already in the kits directory joins unconditionally — a second kit is offered
    # simply by being there, and a bundle a developer placed by hand is never downloaded over.
    others =
      available_kits(dir)
      |> Enum.reject(&MapSet.member?(official_paths, &1.path))
      |> Enum.flat_map(fn kit ->
        case load_bundle(kit.path) do
          {:ok, bundle} -> [bundle]
          {:error, _unreadable} -> []
        end
      end)

    %{
      bundles: Enum.map(official, &elem(&1, 1)) ++ others,
      sources:
        Enum.map(official, fn {kit, bundle} -> source(bundle, kit[:tag], true) end) ++
          Enum.map(others, &source(&1, nil, false)),
      failures: lookup_failures ++ Enum.map(failures, &elem(&1, 1)),
      release: release
    }
  end

  # NO RELEASE IS LOOKED UP for the Studio, nor while a developer's own bundles win: what is on disk
  # is the answer. A configured list is fetched as it is. A failed lookup is a failure the wizard
  # names — with the releases page to check — while the bundles on disk are still offered.
  defp official_for(opts, channel, prefer_local) do
    cond do
      Keyword.get(opts, :local_only, false) -> {[], nil, []}
      not configured?() and prefer_local -> {[], nil, []}
      true -> looked_up(official_source(channel || :stable), channel || :stable)
    end
  end

  defp looked_up({:ok, kits, release}, _channel), do: {kits, release, []}

  defp looked_up({:error, reason}, channel) do
    {[], nil,
     [
       %{
         key: :release,
         label: "Chelekom",
         tag: Atom.to_string(channel),
         url: "https://github.com/#{repo()}/releases",
         reason: reason
       }
     ]}
  end

  defp source(bundle, tag, official?) do
    %{name: bundle["name"], version: bundle["version"], tag: tag, official?: official?}
  end

  @doc """
  Which site an install may write into, derived from the ACTOR rather than from what was asked for.

  A master (`site_id == nil`) may install globally — shared by every site — or into one named site.
  A tenant may install into their own site and nowhere else; asking for `nil` is read as "mine"
  rather than refused, because a form that omits the field is not an attack.

  ## Why this is not left to the UI

  The scope arrives on an event, and an event is whatever the client sent. A tenant who never sees
  the control can still emit `phx-click` with any payload, and `install_kit!/2` writes `site_id`
  straight through — a global install from a tenant would put their components on every site on the
  server, and only a master could remove them.

  ## `:global` is a value, not `nil`

  The scope this resolves TO is a `site_id`, and `nil` there means global — but `nil` coming IN
  means "the request said nothing". Letting one atom carry both is how the first version of this
  allowed exactly what it was written to stop: a tenant sent `scope: "global"`, the caller turned
  that into `nil`, and `nil` matched the "unspecified, so give them their own site" clause. Allowed,
  silently. `:global` has to be asked for by name.

      iex> install_scope(%{site_id: nil}, :global)
      {:ok, nil}

      iex> install_scope(%{site_id: nil}, "acme")
      {:ok, "acme"}

      iex> install_scope(%{site_id: "acme"}, nil)
      {:ok, "acme"}

      iex> install_scope(%{site_id: "acme"}, :global)
      {:error, :forbidden}
  """
  @spec install_scope(map() | nil, :global | String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, :forbidden}
  def install_scope(%{site_id: nil}, :global), do: {:ok, nil}
  def install_scope(%{site_id: nil}, requested), do: {:ok, requested}
  def install_scope(%{site_id: site_id}, nil), do: {:ok, site_id}
  def install_scope(%{site_id: site_id}, site_id), do: {:ok, site_id}
  def install_scope(_actor, _requested), do: {:error, :forbidden}

  @doc """
  Fetches a UI-kit bundle from an arbitrary URL, validates it, and caches it beside the official ones.

  The one way to install a package this CMS does not ship. It is deliberately the same code path an
  official kit takes once the bytes are in hand — the same `$schema` check, the same directory, the
  same discovery on the next boot — because a third-party kit that behaved differently would be a
  second class of kit to keep working.

  ## What is checked, and why each one

    * the response is **bounded** (`:max_bundle_bytes`, 32 MB) — an unbounded read of a URL a
      stranger controls is the whole attack, and the largest kit anyone ships is under 12 MB;
    * it parses as JSON and carries `"$schema": "mishka.ui_kit.bundle.v3"`, so a 200 that is really
      an HTML error page is refused rather than installed as an empty kit;
    * it has a `name`, which becomes its component prefix and its uninstall key;
    * that name **does not collide** with a kit already present. Two kits sharing a prefix means
      uninstalling either deletes the other's components — see `uninstall_kit!/2`, which purges by
      prefix.

  Returns `{:ok, bundle}` or `{:error, reason}` with a sentence a wizard can show. Nothing is written
  unless every check passes.

  The source URL is recorded on the cached bundle so the admin can say where a kit came from, which
  matters more for one of these than for a package we shipped.
  """
  @spec add_custom_kit(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def add_custom_kit(url, opts \\ []) do
    dir = Keyword.get_lazy(opts, :kits_dir, &kits_dir/0)

    with {:ok, url} <- valid_url(url),
         {:ok, bundle} <- download_bundle(url),
         :ok <- validate_bundle_shape(bundle),
         :ok <- unique_name(bundle["name"], dir) do
      bundle = Map.put(bundle, "source_url", url)
      cache_bundle(bundle, Path.join(dir, "#{slug(bundle["name"])}.json"))

      Logger.info("[UiKitHandler] added custom kit #{bundle["name"]} from #{url}")
      {:ok, bundle}
    end
  end

  # An operator pastes what they have. A bare host, a path, or an `ftp://` is not something to hand
  # to `Req` and hope.
  defp valid_url(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, URI.to_string(uri)}

      _other ->
        {:error, gettext("That is not an http:// or https:// address.")}
    end
  end

  defp valid_url(_url), do: {:error, gettext("Enter the address of a bundle JSON.")}

  defp validate_bundle_shape(bundle) do
    case validate_bundle(bundle) do
      :ok ->
        :ok

      {:error, :not_a_v3_bundle} ->
        {:error,
         gettext(
           "That response is not a mishka.ui_kit.bundle.v3 — it needs a \"$schema\", a \"name\" and a \"components\" list."
         )}
    end
  end

  # PREFIX COLLISION IS DATA LOSS, not an inconvenience: `uninstall_kit!/2` deletes components by
  # prefix, so two kits called the same thing means removing one takes the other's rows with it.
  defp unique_name(name, dir) do
    taken = dir |> available_kits() |> Enum.map(&slug(&1.name))

    case slug(name) in taken do
      true ->
        {:error,
         gettext("A kit called %{name} is already installed. Rename it or remove the other.",
           name: name
         )}

      false ->
        :ok
    end
  end

  defp slug(name), do: name |> to_string() |> String.downcase() |> String.replace("_", "-")

  @doc """
  Whether a bundle already on disk beats the pinned download for this environment.

  DEVELOPMENT prefers the local file, because a developer who put one there did so on purpose.
  PRODUCTION prefers the pinned tag, because a file that happens to be in the image — a stale cache,
  something baked in by a previous release — must not silently override the version the operator
  chose. A file on disk that IS the pinned version is read rather than downloaded again, in both.

  Either way the other source is still tried: a developer with no local copy still gets a working
  install, and production still falls back to a bundle downloaded earlier when the network is gone,
  so neither environment can dead-end.

  Default `false` — production behaviour — so a host that never configures it gets the version it
  asked for rather than whatever is lying around.
  """
  @spec prefer_local?() :: boolean()
  def prefer_local?, do: Application.get_env(:mishka_cms_core, :prefer_local_ui_kits, false)

  defp resolve_official(kit, dir, progress, prefer_local) do
    path = kit_path(kit, dir)

    case attempt(kit, path, for_kit(progress, kit), prefer_local) do
      {:ok, bundle} ->
        {:ok, bundle}

      {:error, reason} ->
        Logger.warning("[UiKitHandler] #{kit[:label]} (#{kit[:tag]}) unavailable: #{reason}")

        {:error,
         %{key: kit[:key], label: kit[:label], tag: kit[:tag], url: kit[:url], reason: reason}}
    end
  end

  defp attempt(kit, path, progress, prefer_local) do
    local = from_disk(path)

    case local_first?(local, kit, prefer_local) do
      true -> local
      false -> kit |> from_network(path, progress) |> fallback(fn -> local end)
    end
  end

  defp for_kit(nil, _kit), do: nil
  defp for_kit(progress, kit), do: &progress.(kit[:key], &1)

  # A FILE THAT IS ALREADY THE PINNED VERSION IS NOT DOWNLOADED AGAIN. Development takes whatever a
  # developer placed; production takes the file when it is the version the operator pinned — fetched
  # once, by the installer or the first look at the Studio, and read from disk from then on.
  defp local_first?({:ok, bundle}, kit, prefer_local), do: prefer_local or pinned?(bundle, kit)
  defp local_first?({:error, _absent}, _kit, _prefer_local), do: false

  defp pinned?(%{"version" => version}, %{tag: tag}) when is_binary(version) and is_binary(tag),
    do: String.trim_leading(version, "v") == String.trim_leading(tag, "v")

  defp pinned?(_bundle, _kit), do: false

  defp fallback({:ok, _bundle} = resolved, _next), do: resolved

  defp fallback({:error, primary}, next) do
    case next.() do
      {:ok, _bundle} = resolved -> resolved
      {:error, secondary} -> {:error, reportable(primary, secondary)}
    end
  end

  # THE NETWORK REASON, when there is one. "Not on disk" is never news to whoever is reading the
  # banner — they can see the file is not there. `HTTP 404` is the sentence they can act on.
  defp reportable(:absent, secondary), do: secondary
  defp reportable(primary, _secondary), do: primary

  defp from_disk(path) do
    case load_bundle(path) do
      {:ok, bundle} -> {:ok, bundle}
      {:error, _reason} -> {:error, :absent}
    end
  end

  defp from_network(kit, path, progress) do
    case download_bundle(kit[:url], progress) do
      {:ok, bundle} ->
        cache_bundle(bundle, path)
        {:ok, bundle}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp kit_path(%{file: file}, dir), do: Path.join(dir, file)
  defp kit_path(_kit, dir), do: Path.join(dir, @default_bundle_file)

  defp download_and_cache!(url, path, reason) do
    case download_bundle(url) do
      {:ok, bundle} ->
        cache_bundle(bundle, path)
        bundle

      {:error, why} ->
        raise "UI-kit bundle unavailable at #{path} (#{inspect(reason)}) and #{url}: #{why}"
    end
  end

  defp cache_bundle(bundle, path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(bundle))
  end

  # A REASON, not a raise. With two official packages one of them failing is an ordinary state the
  # wizard has to render, and `Req` failures are noisy enough that the caller wants a sentence.
  defp download_bundle(url, progress \\ nil)

  defp download_bundle(nil, _progress),
    do: {:error, gettext("no download URL is configured for this kit")}

  defp download_bundle(url, progress) do
    # ONE RETRY, not Req's default three. A 404 — the shape this fails as when a bundle has not been
    # published for a tag — will never succeed on a retry, and the wizard sat on a spinner for eight
    # seconds of exponential backoff before it could say so. One covers a genuine blip.
    #
    # STREAMED so the size limit is a real one. Reading the whole body and measuring it afterwards
    # bounds nothing — the bytes are already in memory by then — and this URL can be one a stranger
    # gave us. `:into` lets the read be abandoned mid-flight.
    case Req.get(url, [max_retries: 1, into: bounded_collector(progress)] ++ req_options()) do
      # THREE SHAPES a 200 can arrive in, and all three are reachable. Req's JSON step runs AFTER the
      # collector, on whatever it accumulated: a decoded map for good JSON, the untouched
      # `{:too_large, _}` sentinel when the collector gave up (nothing for the decoder to work on),
      # and a raw binary when the response was not JSON-typed.
      {:ok, %{status: 200, body: {:too_large, limit}}} ->
        {:error, gettext("larger than %{size}", size: mb(limit))}

      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        decode_bundle(body)

      {:ok, %{status: status}} ->
        {:error, gettext("HTTP %{status}", status: status)}

      # Req raises the decode out as an error, so a 200 carrying an HTML error page lands here
      # rather than in `decode_bundle/1`. Same sentence either way — where it was caught is not
      # something the reader of a wizard banner should have to know.
      {:error, %Jason.DecodeError{}} ->
        {:error, gettext("the response was not valid JSON")}

      {:error, exception} ->
        {:error, Exception.message(exception)}

      other ->
        {:error, inspect(other)}
    end
  end

  defp bounded_collector(progress) do
    limit = max_bundle_bytes()

    fn {:data, chunk}, {request, response} ->
      case response.body do
        {:too_large, _limit} = stop ->
          {:halt, {request, %{response | body: stop}}}

        body when byte_size(body) + byte_size(chunk) > limit ->
          {:halt, {request, %{response | body: {:too_large, limit}}}}

        body ->
          report(progress, byte_size(body), byte_size(body) + byte_size(chunk), response)
          {:cont, {request, %{response | body: body <> chunk}}}
      end
    end
  end

  # ONCE A PERCENT, NOT ONCE A CHUNK: a 12 MB kit arrives in hundreds of chunks, and each report is a
  # message to the page drawing the bar. Without a length to take a percent of, once each 256 KB.
  defp report(nil, _before, _now, _response), do: :ok

  defp report(progress, before, now, response) do
    total = content_length(response)
    step = if total, do: max(div(total, 100), 1), else: 262_144
    if div(before, step) != div(now, step), do: progress.({now, total})
    :ok
  end

  defp content_length(response) do
    with [length | _] <- Req.Response.get_header(response, "content-length"),
         {total, ""} when total > 0 <- Integer.parse(length) do
      total
    else
      _unknown -> nil
    end
  end

  defp mb(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  # A TEST SEAM, not a feature. `Req` takes a `:plug`, which is the only way to prove that production
  # reaches for the pinned tag BEFORE the file on disk — an assertion about ordering needs both
  # sources to succeed, and only one of them can be faked.
  defp req_options, do: Application.get_env(:mishka_cms_core, :ui_kit_req_options, [])

  # 32 MB. Chelekom, the largest kit anyone ships, is under 12 MB — this is headroom, not a target.
  defp max_bundle_bytes,
    do: Application.get_env(:mishka_cms_core, :max_ui_kit_bytes, 32 * 1024 * 1024)

  defp decode_bundle(body) do
    case Jason.decode(body) do
      {:ok, bundle} when is_map(bundle) -> {:ok, bundle}
      {:ok, _other} -> {:error, gettext("the response was JSON but not a bundle object")}
      {:error, _reason} -> {:error, gettext("the response was not valid JSON")}
    end
  end

  @doc """
  Install any UI-kit bundle from `bundle_path`. Kit-agnostic — point it at
  any `mishka.ui_kit.bundle.v3` JSON. `install_chelekom!/1` is a thin
  wrapper that defaults the path to the downloaded Chelekom bundle.

  Rows are **upserted** by `unique_name_per_site` (name + site_id): an
  existing component/stylesheet/js_hook is updated in place (stable id,
  preserved history); a new one is created. So re-importing is safe and
  non-destructive — no need to wipe first.

  ## Options

    * `:site_id` — install under this tenant. Default `nil` (global).
    * `:cleanup` — when `true`, hard-delete existing `<kit_name>-*` rows
      before importing (full reset; drops rows no longer in the bundle).
      Default `false` — rely on upsert. Use `true` only for a clean slate.
    * `:selection` — narrow what gets installed. See "Selection".

  ## Selection

  Default is `:all` — install everything in the bundle. Custom shape:

      %{
        components: :all | [String.t()],
        variants:   :all | [String.t()],
        colors:     :all | [String.t()],
        per_component: %{String.t() => component_filter}
      }

  where `component_filter` is `%{variants: [...], colors: [...]}`.

  Examples:

      # Only `button` and `badge`, all variants/colors
      install_kit!(path, selection: %{components: ["button", "badge"]})

      # All components, only `base` variant
      install_kit!(path, selection: %{variants: ["base"]})

  Filtering applies to the component list, each kept component's
  `helpers[]` (drop clauses the selection rules out), and `attrs[]`
  `values:` constraints. Catch-all helpers (`_, _`) are always kept so
  dropping color/variant clauses never crashes a render.

  > #### Beware narrowing helpers {: .warning}
  > A restrictive `:variants`/`:colors` selection drops the matching
  > `color_variant`/etc. clauses. A component installed that way renders
  > WITHOUT those colors/variants (the catch-all fallback returns the
  > bare variant name). For a full component set, use `:all`.
  """
  def install_kit!(bundle_path, opts \\ []) when is_binary(bundle_path) do
    site_id = Keyword.get(opts, :site_id, nil)
    cleanup? = Keyword.get(opts, :cleanup, false)
    selection = Keyword.get(opts, :selection, :all)
    timeout = Keyword.get(opts, :timeout, :timer.minutes(2))
    # WHO IS INSTALLING. Absent for the wizard, which runs before there is a user, and for the
    # seeds; present for anything an admin pressed, and then every row written here is written as
    # them — the resource's policy answers, and the version history says who.
    actor = Keyword.get(opts, :actor)

    MishkaInstaller.Event.Hook.call(
      "runtime:ui_kit:before_install",
      %{bundle_path: bundle_path, site_id: site_id, selection: selection},
      return: false
    )

    with {:ok, bundle} <- load_bundle(bundle_path) do
      if cleanup? do
        delete_existing_components_by_prefix(bundle["name"], site_id)
        delete_existing_js_hooks(hook_purge_targets(bundle))
        delete_existing_stylesheets(Enum.map(bundle["stylesheets"] || [], & &1["name"]), site_id)
      end

      # A RENAME IS PART OF INSTALLING THIS BUNDLE, NOT PART OF CLEANING UP AFTER THE LAST ONE.
      #
      # `:cleanup` is off by default, and rightly — an upgrade updates rows in place and must not
      # drop a site's customisations to do it. But a row this bundle has RENAMED cannot be updated in
      # place: the name is the key, so the new name creates a row and the old one stays, leaving two
      # hooks with the same code and an admin list that reads worse than the inconsistency the rename
      # fixed. Chelekom's hooks shipped bare — `floating`, `carousel` — while its 136 components
      # shipped as `chelekom-*`; they are namespaced now.
      #
      # Bounded by what the BUNDLE claims in `extra.replaces`, and global rows only. "Delete whatever
      # this would be called without its kit prefix" would take a site's own `carousel` on a first
      # install of a kit that happens to have one.
      bundle
      |> hook_rename_targets()
      |> announce_renames(bundle["name"])
      |> delete_existing_js_hooks()

      filtered_components =
        (bundle["components"] || [])
        |> apply_selection(selection, bundle["name"])

      result =
        Ash.transaction(
          [Component, JsHook, Stylesheet],
          fn ->
            {cps, cps_skipped} =
              filtered_components
              |> Enum.map(&create_component(&1, site_id, bundle, actor))
              |> partition_results()

            {hs, hs_skipped} =
              (bundle["js_hooks"] || [])
              |> Enum.map(&create_js_hook(&1, site_id, actor))
              |> partition_results()

            {ss, ss_skipped} =
              (bundle["stylesheets"] || [])
              |> Enum.map(&create_stylesheet(&1, site_id, actor))
              |> partition_results()

            %{
              components: cps,
              js_hooks: hs,
              stylesheets: ss,
              skipped_archived: %{
                components: cps_skipped,
                js_hooks: hs_skipped,
                stylesheets: ss_skipped
              }
            }
          end,
          timeout: timeout
        )

      # Per-row runtime jobs were deferred (defer_runtime context); rebuild the
      # runtime ONCE now that the whole batch is committed.
      with {:ok, bundle_result} <- result do
        RuntimeOrchestrator.sync_after_bulk(
          scope: sync_scope(site_id),
          kinds: touched_kinds(bundle_result)
        )

        MishkaInstaller.Event.Hook.call(
          "runtime:ui_kit:after_install",
          %{site_id: site_id, bundle: bundle["name"], kinds: touched_kinds(bundle_result)},
          return: false
        )

        result
      end
    end
  end

  defp sync_scope(nil), do: :global
  defp sync_scope(site_id), do: {:site, site_id}

  defp touched_kinds(%{components: cps, js_hooks: hs, stylesheets: ss}) do
    [{:component, cps}, {:js_hook, hs}, {:stylesheet, ss}]
    |> Enum.filter(fn {_kind, rows} -> rows != [] end)
    |> Enum.map(fn {kind, _rows} -> kind end)
  end

  def install_chelekom!(opts \\ []) do
    {bundle_path, rest} = Keyword.pop_lazy(opts, :bundle_path, &default_bundle_path/0)
    install_kit!(bundle_path, rest)
  end

  @doc """
  Remove every row tagged with this kit (components by `<kit_name>-*`
  prefix, plus the bundle's JsHook + Stylesheet names). Kit-agnostic;
  `uninstall_chelekom!/1` defaults the path to the Chelekom bundle.
  """
  def uninstall_kit!(bundle_path, opts \\ []) when is_binary(bundle_path) do
    site_id = Keyword.get(opts, :site_id, nil)

    MishkaInstaller.Event.Hook.call(
      "runtime:ui_kit:before_uninstall",
      %{bundle_path: bundle_path, site_id: site_id},
      return: false
    )

    # A DESTRUCTIVE OPERATION MUST NOT GUESS. This defaulted to "chelekom", so an extension whose own
    # bundle had stopped parsing — a partial write, a bumped `$schema` — called
    # `ExtensionKit.uninstall!/1` on teardown and purged CHELEKOM instead. Every `acme-*` row still
    # installed, every global `chelekom-*` row hard-deleted through `:master_permanent_destroy`,
    # which is excluded from both the archive and PaperTrail. Nothing to roll back, and it returned
    # `:ok` with no log line.
    #
    # The filename is a faithful stand-in and not a guess: `ExtensionKit.bundle_path/2` builds it as
    # `"#{name || app}.json"`, `available_kits/0` discovers by the same wildcard, and
    # `delete_existing_components_by_prefix/2` slugifies it identically. Absent even that, refuse.
    with {:ok, {kit_name, hook_names, sheet_names}} <- purge_targets(bundle_path, opts) do
      delete_existing_components_by_prefix(kit_name, site_id)
      delete_existing_js_hooks(hook_names)
      delete_existing_stylesheets(sheet_names, site_id)

      MishkaInstaller.Event.Hook.call(
        "runtime:ui_kit:after_uninstall",
        %{site_id: site_id, kit: kit_name},
        return: false
      )

      :ok
    end
  end

  defp purge_targets(bundle_path, opts) do
    case load_bundle(bundle_path) do
      {:ok, bundle} ->
        {:ok,
         {bundle["name"], hook_purge_targets(bundle),
          Enum.map(bundle["stylesheets"] || [], & &1["name"])}}

      {:error, reason} ->
        case Keyword.get(opts, :kit_name) || basename_kit(bundle_path) do
          nil ->
            Logger.error(
              "[UiKitHandler] refusing to uninstall #{bundle_path}: it does not parse " <>
                "(#{inspect(reason)}) and no :kit_name was given — deleting by a guessed prefix " <>
                "would purge whichever kit the guess happened to name."
            )

            {:error, {:unreadable_bundle, reason}}

          name ->
            Logger.warning(
              "[UiKitHandler] #{bundle_path} does not parse (#{inspect(reason)}); purging by its " <>
                "filename, #{name}."
            )

            {:ok, {name, [], []}}
        end
    end
  end

  # The bundle's filename without its extension. Empty is not a name — a path ending in `.json` with
  # nothing before it must reach the refusal, not delete everything with a blank prefix.
  defp basename_kit(bundle_path) do
    case bundle_path |> Path.basename() |> Path.rootname() |> String.trim() do
      "" -> nil
      name -> name
    end
  end

  def uninstall_chelekom!(opts \\ []) do
    {bundle_path, rest} = Keyword.pop_lazy(opts, :bundle_path, &default_bundle_path/0)
    uninstall_kit!(bundle_path, rest)
  end

  @doc """
  Return the bare component names (without the kit prefix) shipped by
  the bundle. Useful for an installer UI that lets the user pick which
  components to install.

      {:ok, names} = UiKitHandler.list_components(bundle_path: path)
      # => {:ok, ["accordion", "alert", "avatar", "badge", "button", ...]}
  """
  @spec list_components(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def list_components(opts) do
    bundle_path = Keyword.fetch!(opts, :bundle_path)

    with {:ok, bundle} <- load_bundle(bundle_path) do
      prefix = bundle["name"] <> "-"

      names =
        bundle["components"]
        |> Enum.map(&String.replace_prefix(&1["name"], prefix, ""))
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, names}
    end
  end

  @doc """
  Return the per-axis feature set for a single component. The
  `:features` map shows every axis the user can filter, paired with
  the values the kit ships for that axis.

  Sources:
  - Helper-level discriminators (extracted from the kit's `.eex`
    `<%= if %>` chain) — exact axis-value pairs the helpers support.
  - Attribute `values:` constraints — values declared via
    `attr :variant, :string, values: [...]`.

      {:ok, info} =
        UiKitHandler.list_features(bundle_path: path, component: "button")

      # => {:ok, %{
      #      component: "chelekom-button",
      #      attrs: ["id", "variant", "color", "size", ...],
      #      features: %{
      #        "variant" => ["base", "default", "outline", "shadow", ...],
      #        "color"   => ["primary", "secondary", "danger", ...],
      #        "size"    => ["extra_small", "small", "medium", ...],
      #        "rounded" => ["none", "small", "medium", "large", "full"]
      #      }
      #    }}
  """
  @spec list_features(keyword()) :: {:ok, map()} | {:error, term()}
  def list_features(opts) do
    bundle_path = Keyword.fetch!(opts, :bundle_path)
    component_name = Keyword.fetch!(opts, :component)

    with {:ok, bundle} <- load_bundle(bundle_path) do
      prefix = bundle["name"] <> "-"

      full_name =
        if String.starts_with?(component_name, prefix),
          do: component_name,
          else: prefix <> component_name

      case Enum.find(bundle["components"], &(&1["name"] == full_name)) do
        nil -> {:error, :not_found}
        comp -> {:ok, build_features(comp)}
      end
    end
  end

  @doc """
  The available option values per axis for a single ALREADY-PARSED bundle component
  (`%{"variant" => [...], "color" => [...], ...}`) — the same extraction `list_features/1` does, but
  from an in-memory component map (no bundle reload). Used by the installer's `UiKitCatalog` to build
  the per-component variant picker.
  """
  @spec component_features(map()) :: %{optional(String.t()) => [String.t()]}
  def component_features(component), do: build_features(component).features

  defp build_features(component) do
    from_helpers =
      for helper <- component["helpers"] || [],
          clause <- helper["discriminators"] || [],
          reduce: %{} do
        acc ->
          Map.update(
            acc,
            clause["axis"],
            MapSet.new(clause["values"]),
            &MapSet.union(&1, MapSet.new(clause["values"]))
          )
      end
      |> Map.new(fn {axis, set} -> {axis, set |> MapSet.to_list() |> Enum.sort()} end)

    from_attrs =
      for attr <- component["attrs"] || [],
          values = get_in(attr, ["opts", "values"]),
          is_list(values),
          cleaned = Enum.reject(values, &is_nil/1),
          cleaned != [],
          into: %{} do
        {attr["name"], cleaned}
      end

    # Helper-derived features take precedence over attr-declared values, and are re-keyed from the
    # helper's own parameter name to the ATTRIBUTE that is passed in that position. Clause heads sit
    # between the two: less authoritative than a recorded discriminator, more so than a list the
    # component merely declares.
    %{
      component: component["name"],
      attrs: Enum.map(component["attrs"] || [], & &1["name"]),
      features:
        from_attrs
        |> Map.merge(from_clause_heads(component))
        |> Map.merge(bind_axes(from_helpers, component))
        |> with_declared_defaults(component)
    }
  end

  # A LIST THAT EXCLUDES THE COMPONENT'S OWN DEFAULT IS AN INCOMPLETE DERIVATION, and the kit is the
  # authority on that one value.
  #
  # `chelekom-dropdown` declares `position` with `default: "bottom"` and no `values`, so the list is
  # derived from clause heads — and the only helper taking `@position` in a literal position is
  # `dropdown_mobile_position`, which has two clauses: "left" and "right". The panel then offered a
  # dropdown that could be positioned left or right, on a component whose default position is
  # neither. A reader looking at that list concludes the component cannot do what it does by default.
  #
  # Folded in rather than used to discard the derivation: the derived values ARE what this install
  # shipped — narrowing a component to fewer variants is a real feature — and the default is one more
  # value known to be legal, not a replacement for them. Blank is skipped; that is the select's
  # "— default —" row, not an option.
  defp with_declared_defaults(features, component) do
    Enum.reduce(component["attrs"] || [], features, fn attr, acc ->
      with values when is_list(values) <- Map.get(acc, attr["name"]),
           default when is_binary(default) <- get_in(attr, ["opts", "default"]),
           false <- String.trim(default) == "" or default in values do
        Map.put(acc, attr["name"], Enum.sort([default | values]))
      else
        _keep -> acc
      end
    end)
  end

  # What an axis the extractor recorded NO discriminators for can still be known to accept.
  #
  # The discriminators are the authority on what a given install shipped — pick "base variant only"
  # and the exporter emits only base clauses, so the panel offers only base without anything here
  # being configured. But the extractor does not record them for every helper: `chelekom-combobox`
  # calls `padding_size(@padding)` and ships six clauses carrying none. The clause HEADS say the same
  # thing — five literals is five paddings this install can render — so they are read as a second
  # source rather than falling all the way back to the list the attribute declares.
  #
  # A NON-LITERAL at that position (a catch-all, a bound variable) means the helper accepts anything
  # there and the value does render — `border_position="none"` reaching `rounded_size`'s fallback is
  # exactly what "none" should do. Then nothing is claimed and the declared list stands: offering one
  # option too many is a smaller failure than hiding a control that works.
  defp from_clause_heads(component) do
    clauses = Enum.group_by(component["helpers"] || [], & &1["name"])

    source =
      [component["template"] || "" | Enum.map(component["helpers"] || [], &(&1["code"] || ""))]
      |> Enum.join("\n")

    for [_call, helper, args] <- Regex.scan(~r/\b([a-z_][a-z0-9_]*)\s*\(([^()]*)\)/, source),
        heads = Map.get(clauses, helper),
        is_list(heads),
        {attr, index} <- passed_assigns(args),
        reduce: %{} do
      acc -> Map.update(acc, attr, head_values(heads, index), &merge_heads(&1, heads, index))
    end
    |> Enum.filter(fn {_attr, values} -> is_list(values) and values != [] end)
    # UNIQUE, because several clauses may carry the same literal at that position: a helper written
    # once per orientation ships `"dashed"` twice, and the picker drew the swatch twice with it. It
    # showed only once the axis that had been overwriting this stopped doing so.
    |> Map.new(fn {attr, values} -> {attr, values |> Enum.uniq() |> Enum.sort()} end)
  end

  # `:open` is contagious across call sites: one that accepts anything settles the question for the
  # attribute however many others enumerate.
  defp merge_heads(:open, _heads, _index), do: :open

  defp merge_heads(values, heads, index) do
    case head_values(heads, index) do
      :open -> :open
      more -> Enum.uniq(values ++ more)
    end
  end

  defp head_values(heads, index) do
    Enum.reduce_while(heads, [], fn head, acc ->
      case head |> Map.get("args") |> split_arguments() |> Enum.at(index) do
        nil -> {:halt, :open}
        pattern -> (literal(pattern) && {:cont, [literal(pattern) | acc]}) || {:halt, :open}
      end
    end)
  end

  # `@variant, @kind` -> [{"variant", 0}, {"kind", 1}]. Position matters: `rounded_size(@rounded,
  # @rounded_position)` describes two different attributes from one helper's clauses.
  defp passed_assigns(args) do
    args
    |> split_arguments()
    |> Enum.with_index()
    |> Enum.flat_map(fn {argument, index} ->
      case Regex.run(~r/^@([a-z_][a-z0-9_]*)$/, argument) do
        [_full, name] -> [{name, index}]
        nil -> []
      end
    end)
  end

  defp literal(pattern) do
    pattern
    |> String.split(" when ")
    |> hd()
    |> String.trim()
    |> case do
      <<?", rest::binary>> = quoted ->
        String.ends_with?(quoted, ~s(")) && String.trim_trailing(rest, ~s("))

      <<?:, rest::binary>> ->
        Regex.match?(~r/^[a-z_][a-z0-9_]*$/, rest) && rest

      _other ->
        nil
    end
  end

  # Commas inside a map, list or tuple pattern are not argument separators.
  #
  # A helper that carries NO head — an extension registering one by hand, a bundle written before the
  # exporter emitted `args` — reads as no arguments rather than as a crash. `Enum.at([], _)` is `nil`,
  # which `head_values/2` already treats as "cannot narrow".
  defp split_arguments(args) when not is_binary(args), do: []

  defp split_arguments(args) do
    args
    |> String.graphemes()
    |> Enum.reduce({[], "", 0}, fn
      grapheme, {done, current, 0} when grapheme == "," ->
        {[current | done], "", 0}

      grapheme, {done, current, depth} when grapheme in ["(", "[", "{"] ->
        {done, current <> grapheme, depth + 1}

      grapheme, {done, current, depth} when grapheme in [")", "]", "}"] ->
        {done, current <> grapheme, depth - 1}

      grapheme, {done, current, depth} ->
        {done, current <> grapheme, depth}
    end)
    |> then(fn {done, current, _depth} -> Enum.reverse([current | done]) end)
    |> Enum.map(&String.trim/1)
  end

  @doc """
  Which attribute each helper axis actually describes, read from the call sites in the template.

  A discriminator is keyed by the helper's own PARAMETER name — `color_variant(variant, color)` gives
  axes `variant` and `color`. The attribute passed in is a different thing: alert's template calls
  `color_variant(@variant, @kind)`, so the eleven colours belong to `kind`. Keyed by the axis, they
  belonged to an attribute the component does not have, and the single most consequential choice on
  an alert — is it primary, is it danger? — had no picker at all. Twenty-five components have an
  orphan `color` axis, twenty-two `variant`, twenty-one `rounded`.

  Two rules, in order:

    1. an axis whose name IS one of the passed attributes binds to it — the common case, where the
       author named the parameter after the attribute;
    2. when exactly one axis and one attribute are left over, they bind to each other — which is what
       recovers `color` → `kind`, **and only when the attribute's own default is one of the values
       that axis offers**. That last clause is not caution for its own sake: without it, `divider`
       and `hr` bound their `type` axis onto `position`, whose default is `middle` and which the axis
       has never heard of. The picker offered two options, neither of them the value the element
       actually had.

  Anything still ambiguous is left keyed by its axis, because a wrong picker on the wrong property is
  worse than a text box.

  ## A kit may simply say

  All of the above is inference, and inference is what a second kit can break. A component carrying

      "axes": [{"name": "color", "attr": "kind"}]

  is believed and none of it runs. The exporter that emits it lives upstream, in the kit's own
  repository; this end is ready for it, so the day a bundle ships the key the guessing stops for
  that component with no change here.

  **The key is the opt-out, not the entries.** A component carrying an `axes` list — even an empty
  one, which says "this component has none" — is never guessed at again. An entry naming an
  attribute the component does not declare is dropped, and the axis simply goes unbound: falling
  back to the reading above would re-enable, on a typo, the exact mechanism the declaration was
  written to replace, and it could bind somewhere the kit never meant. A text box is the better
  failure here, which is the same reason the leftover rule refuses an ambiguous pair.
  """
  @spec axis_bindings(map()) :: %{optional(String.t()) => String.t()}
  def axis_bindings(component) do
    case component["axes"] do
      declared when is_list(declared) -> declared_axes(component, declared)
      _absent -> inferred_axis_bindings(component)
    end
  end

  # `scope` is accepted and ignored: it names the helper an axis belongs to, which matters to the
  # exporter and not to a map from axis to attribute. Reading it would only give this end a second
  # thing to disagree with the kit about.
  defp declared_axes(component, declared) do
    for entry <- declared,
        is_map(entry),
        axis = blank_to_nil(entry["name"]),
        attr = blank_to_nil(entry["attr"]),
        declared_attr?(component, attr),
        into: %{},
        do: {axis, attr}
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp declared_attr?(component, attr) do
    component["attrs"] |> List.wrap() |> Enum.any?(&(&1["name"] == attr))
  end

  # WHICH HELPER THE TEMPLATE HANDS WHICH ATTRIBUTE TO, read off the parsed expressions.
  #
  # It was `~r/\b([a-z_][a-z0-9_]*)\s*\(([^()]*)\)/` over the template, and `[^()]*` is the whole
  # problem: a call's arguments cannot contain a bracket, so `color_variant(@variant, tone(@kind))`
  # matched `tone(@kind)` and never `color_variant`, and the axis that helper carries went unbound.
  # It also read a call out of anything shaped like one — inside a class name, inside a string, in
  # prose the component renders — and the parens are what it keyed on, so there was no telling those
  # from the real thing either.
  defp inferred_axis_bindings(component) do
    names = MapSet.new(component["helpers"] || [], & &1["name"])
    axes_by_helper = helper_axes(component)

    for expression <- Markup.expressions(component["template"]),
        {called, args} <- CodeReads.calls(expression),
        helper = Atom.to_string(called),
        MapSet.member?(names, helper),
        attrs = template_attrs(args),
        attrs != [],
        axes = Map.get(axes_by_helper, helper, []),
        axes != [],
        {axis, attr} <- bind(axes, attrs, component),
        into: %{} do
      {axis, attr}
    end
  end

  defp helper_axes(component) do
    component
    |> collect_helper_axes()
    |> drop_kit_axes()
  end

  defp collect_helper_axes(component) do
    for helper <- component["helpers"] || [], reduce: %{} do
      acc ->
        axes = for clause <- helper["discriminators"] || [], do: clause["axis"]
        Map.update(acc, helper["name"], Enum.uniq(axes), &Enum.uniq(&1 ++ axes))
    end
  end

  # AN AXIS ON EVERY HELPER IS NOT A PARAMETER OF ANY OF THEM. Chelekom generates `chelekom-grid` and
  # `chelekom-flex` from one source, so the exporter stamps its own `type` axis (`flex` | `grid`) onto
  # all EIGHTEEN of the grid's helpers — `cols_class`, `wrap_class`, `place_self_class` and the rest.
  # It is the generator's axis, not a runtime option, and `type` is not even a declared attribute.
  #
  # `bind/2` then saw one spare axis and one spare attribute at `place_self_class(@place_self)` and
  # paired them, which put a `flex | grid` picker on CSS `place-self` — the only non-text control the
  # grid had, and nonsense. A real axis belongs to the helper that discriminates on it:
  # `color_variant` carries `variant` and `color`, `padding_size` carries `padding`, one helper each.
  defp drop_kit_axes(axes_by_helper) when map_size(axes_by_helper) < 2, do: axes_by_helper

  defp drop_kit_axes(axes_by_helper) do
    shared =
      axes_by_helper
      |> Enum.flat_map(fn {_helper, axes} -> axes end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_axis, count} -> count > 1 end)
      |> MapSet.new(&elem(&1, 0))

    Map.new(axes_by_helper, fn {helper, axes} ->
      {helper, Enum.reject(axes, &MapSet.member?(shared, &1))}
    end)
  end

  # `color_variant(@variant, @kind)` -> ["variant", "kind"]. Only bare assign references count: a
  # literal or an expression is not an attribute anyone can bind an option list to.
  #
  # POSITION IS THE ANSWER, so an argument that is not one keeps its place as `nil` — `bind/3` pairs
  # a helper's axes against this list and dropping an argument would shift every one after it.
  defp template_attrs(args), do: Enum.map(args, &attr_name/1)

  defp attr_name({:@, _meta, [{name, _name_meta, context}]})
       when is_atom(name) and is_atom(context),
       do: Atom.to_string(name)

  defp attr_name(_argument), do: nil

  defp bind(axes, attrs, component) do
    direct = for axis <- axes, axis in attrs, do: {axis, axis}
    bound_axes = MapSet.new(direct, &elem(&1, 0))
    bound_attrs = MapSet.new(direct, &elem(&1, 1))

    loose_axes = Enum.reject(axes, &MapSet.member?(bound_axes, &1))

    loose_attrs =
      attrs
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&MapSet.member?(bound_attrs, &1))

    direct ++ pair_leftovers(loose_axes, loose_attrs, component)
  end

  # Only when it is unambiguous. Two spare axes and two spare attributes could pair either way, and
  # guessing would put the colours on the padding.
  #
  # AND ONLY WHEN THE ATTRIBUTE COULD HOLD THOSE VALUES. One spare of each is not evidence that they
  # belong together — `divider` and `hr` call a helper carrying the generator's `type` axis and pass
  # `@position`, and this paired them. The attribute's own default is `middle`; the axis offers two
  # values and `middle` is not one of them, so the panel drew a picker whose options could not
  # include what the element already was. A default the axis has never heard of is the cheapest proof
  # available that the pairing is wrong, and it is decisive: measured over the shipped kit, seven
  # pairings, two refused, five kept — including the `color` → `kind` on alert and flash that this
  # whole mechanism exists for.
  #
  # A blank default proves nothing either way, so it is left alone rather than being read as a no.
  #
  # THE ONE WAY THIS CAN BE WRONG: `discriminators` lists the values a helper has an explicit clause
  # for, so a kit whose helper handles the default through a `_` fallback ships a list that does not
  # contain it, and a right pairing would be refused. No component in the shipped kit is shaped that
  # way — every one of the five kept pairings has its default in the list — but a third-party kit
  # could be, and the symptom would be a text box where a picker belongs. If that shows up, the fix
  # is to read the helper's own clause heads for a catch-all rather than to loosen this.
  # AND ONLY WHEN THE AXIS HAS NOWHERE ELSE TO LIVE. An axis named after an attribute the component
  # declares is about that attribute, whatever helper it was recorded on. `chelekom-gallery`
  # declares `type` (default, masonry, featured) and its `column_class` clauses carry a `type` axis
  # whose one value is `gallery` — the generator saying which KIND of component the clause belongs
  # to, not a value the attribute takes. Paired onto the one spare attribute, that made `cols` a
  # picker offering a single swatch reading "gallery", in place of the twelve column counts.
  defp pair_leftovers([axis], [attr], component) do
    case homeless?(component, axis) and plausible?(component, axis, attr) do
      true -> [{axis, attr}]
      false -> []
    end
  end

  defp pair_leftovers(_axes, _attrs, _component), do: []

  defp homeless?(component, axis), do: axis not in declared_names(component)

  defp declared_names(component) do
    component["attrs"] |> List.wrap() |> Enum.map(& &1["name"])
  end

  defp plausible?(component, axis, attr) do
    case declared_default(component, attr) do
      blank when blank in [nil, ""] -> true
      default -> to_string(default) in Enum.map(axis_values(component, axis), &to_string/1)
    end
  end

  defp declared_default(component, attr) do
    component["attrs"]
    |> List.wrap()
    |> Enum.find(&(&1["name"] == attr))
    |> case do
      nil -> nil
      declared -> get_in(declared, ["opts", "default"])
    end
  end

  defp axis_values(component, axis) do
    for helper <- component["helpers"] || [],
        clause <- helper["discriminators"] || [],
        clause["axis"] == axis,
        value <- clause["values"] || [],
        uniq: true,
        do: value
  end

  # AN AXIS THAT BOUND TO NOTHING MAY STILL BE ABOUT THE ATTRIBUTE OF ITS OWN NAME — but it has to
  # pass the same test a pairing does, and for the same reason. `chelekom-divider` declares `type`
  # as dashed/dotted/solid and its `text_position` clauses carry a `type` axis reading
  # `["hr", "divider"]`, the generator naming which component the clause is for. Keyed onto `type`
  # unchecked, that replaced the three real values with two that are not values at all.
  defp bind_axes(from_helpers, component) do
    bindings = axis_bindings(component)

    from_helpers
    |> Enum.flat_map(fn {axis, values} ->
      case Map.fetch(bindings, axis) do
        {:ok, attr} -> [{attr, values}]
        :error -> (keeps_its_name?(component, axis) && [{axis, values}]) || []
      end
    end)
    |> Map.new()
  end

  # A bound axis was already matched against the attribute it names. An unbound one that happens to
  # share a name with a declared attribute is only guessing, so it is held to the same proof — and an
  # axis naming no attribute at all is not a claim about one, so it passes through as it always did.
  defp keeps_its_name?(component, axis) do
    axis not in declared_names(component) or plausible?(component, axis, axis)
  end

  @doc """
  The bundle at `path` as the installer reads it — screened, so what comes back is what an install
  would actually write.

  `MishkaCmsCore.Runtime.Handlers.UiKitUpgrade` compares a site's rows against it, and comparing
  against the raw file would report a component this installer drops as one the site is missing.
  """
  @spec read_bundle(String.t()) :: {:ok, map()} | {:error, term()}
  def read_bundle(path) when is_binary(path), do: load_bundle(path)

  defp load_bundle(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, json} <- Jason.decode(raw),
         :ok <- validate_bundle(json) do
      {:ok, screen_bundle(json, path)}
    end
  end

  # A bundle is somebody else's file, and one component in it that this CMS cannot install should
  # cost that component rather than the kit. `Contract` checks the shape the rest of the pipeline
  # depends on — a name to find it by, a template to compile — and anything that fails is dropped
  # here with a log line naming it, instead of raising out of `Ash.create!` several layers down.
  # EVERY COLLECTION, not just components. A malformed component costs that component and is named in
  # the log; a malformed stylesheet or hook went straight to the resource, raised out of the
  # transaction, and cost the operator all 136 good components with nothing on screen naming the row
  # that did it. The asymmetry was the bug, and it matters more now that a bundle can arrive from a
  # URL an operator pasted.
  defp screen_bundle(bundle, path) do
    bundle
    |> screen_collection("components", path, &Contract.partition/1)
    |> screen_collection("js_hooks", path, &partition_rows(&1, ["name", "content"]))
    |> screen_collection("stylesheets", path, &partition_rows(&1, ["name", "content"]))
    |> audit_form_roles(path)
  end

  # A form role is a HINT, not a requirement, so it screens nothing — the bundle goes through
  # untouched and the components come out the other side installed. What it does is say so out loud:
  # a kit that meant to declare `extra.form` and misspelled the role gets silence from the editor,
  # which then infers, and the kit author has no way to tell the two apart. This log line is that
  # way. `MishkaCmsCore.Builder.FormRole` decides what unreadable means.
  defp audit_form_roles(bundle, path) do
    unreadable =
      for component <- bundle["components"] || [],
          declared = declared_form(component),
          is_map(declared) and map_size(declared) > 0,
          FormRole.build(declared, component) == :none,
          do: {component["name"], declared}

    log_unreadable_roles(unreadable, path)

    bundle
  end

  defp log_unreadable_roles([], _path), do: :ok

  defp log_unreadable_roles(unreadable, path) do
    Logger.warning(
      "[UiKitHandler] #{Path.basename(path)}: installed #{length(unreadable)} component" <>
        "#{(length(unreadable) == 1 && "") || "s"} whose declared form role could not be read, " <>
        "so the editor infers a role for #{(length(unreadable) == 1 && "it") || "them"} — " <>
        Enum.map_join(unreadable, ", ", fn {name, declared} ->
          "#{name || "(unnamed)"}: #{inspect(declared)}"
        end)
    )
  end

  defp declared_form(%{"extra" => %{"form" => declared}}), do: declared
  defp declared_form(%{extra: %{form: declared}}), do: declared
  defp declared_form(_component), do: nil

  defp screen_collection(bundle, key, path, partition) do
    case partition.(bundle[key] || []) do
      {kept, []} ->
        Map.put(bundle, key, kept)

      {kept, rejected} ->
        Logger.warning(
          "[UiKitHandler] #{Path.basename(path)}: skipped #{length(rejected)} #{key} entr" <>
            "#{(length(rejected) == 1 && "y") || "ies"} that do not meet the bundle contract — " <>
            Enum.map_join(rejected, ", ", fn {name, reason} ->
              "#{name || "(unnamed)"}: #{inspect(reason)}"
            end)
        )

        Map.put(bundle, key, kept)
    end
  end

  # `Contract.partition/1` knows what a COMPONENT needs. A hook and a stylesheet need a name and a
  # body and nothing else — the resource decides the rest — so the shape is checked here rather than
  # given a contract module of its own.
  defp partition_rows(rows, required) when is_list(rows) do
    Enum.split_with(rows, fn row ->
      is_map(row) and Enum.all?(required, &present?(row[&1]))
    end)
    |> then(fn {kept, rejected} ->
      {kept, Enum.map(rejected, &{is_map(&1) && &1["name"], missing_keys(&1, required)})}
    end)
  end

  defp partition_rows(_rows, _required), do: {[], []}

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp missing_keys(row, required) when is_map(row) do
    {:missing, Enum.reject(required, &present?(row[&1]))}
  end

  defp missing_keys(_row, _required), do: {:missing, :not_an_object}

  # WHY THIS IS STILL v3, ANSWERED RATHER THAN LEFT DRIFTING. A `v4` contract was designed and
  # measured on 11 Aug 2026 and deliberately not adopted:
  #
  #   * most of what it proposed already ships INSIDE v3's `opts` — `values`, `required`, `default`,
  #     `editor`, `min`/`max`/`step` — or duplicates something the CMS already holds: a component's
  #     title is `humanize(name)`, its category is its `type`, its description is a column;
  #   * `source: "heroicons"` would have been dead on arrival. `Icons.libraries/0` routes by class
  #     PREFIX and a kit's own glyphs self-register, so the picker never needs telling which registry
  #     to read;
  #   * the proposed shape OMITTED the top-level `icons` key this file's bundles actually carry and
  #     `Icons.Bundled` depends on — implemented literally it would have dropped the icon catalogue;
  #   * the one field that would change behaviour is a declared `axes` list, which would retire the
  #     inference in `axis_bindings/1` above. Emitting it is exporter work upstream. The schema
  #     number was never the blocker.
  #
  # And the cost of bumping is not zero: a v4 file meeting this clause fails QUIETLY — `describe_kit/1`
  # answers nil, so the installer, `install_kits!/2` and the Studio's Registry all behave as though
  # the kit were not on disk. New fields keep arriving additively instead, which is what `required`
  # and `precompile` already did.
  #
  # Revisit when a SECOND kit ships. That is the first moment the guesses here can be wrong, and the
  # moment a declared contract starts paying for itself.
  defp validate_bundle(%{"$schema" => "mishka.ui_kit.bundle.v3", "name" => n, "components" => cs})
       when is_binary(n) and is_list(cs),
       do: :ok

  defp validate_bundle(_), do: {:error, :not_a_v3_bundle}

  defp apply_selection(components, :all, _kit_name), do: components

  defp apply_selection(components, %{} = sel, kit_name) do
    components
    |> Enum.filter(&component_in_selection?(&1, sel, kit_name))
    |> Enum.map(&narrow_component(&1, sel, kit_name))
  end

  # `components` may name the kit-prefixed full name (`"chelekom-button"`)
  # or the bare function name (`"button"`); match either.
  defp component_in_selection?(component, sel, kit_name) do
    case Map.get(sel, :components, :all) do
      :all ->
        true

      list when is_list(list) ->
        full = component["name"]
        short = String.replace_prefix(full, "#{kit_name}-", "")
        full in list or short in list
    end
  end

  # Narrow a kept component's helpers + attrs. Per-component overrides win
  # over top-level keys.
  defp narrow_component(component, sel, kit_name) do
    short = String.replace_prefix(component["name"], "#{kit_name}-", "")

    per_comp = Map.get(sel, :per_component, %{}) |> Map.get(short, %{})

    selection_by_axis = build_selection_by_axis(sel, per_comp)

    cond do
      selection_by_axis == %{} ->
        component

      true ->
        component
        |> filter_helpers(selection_by_axis)
        |> narrow_attr_values(selection_by_axis)
    end
  end

  @reserved_selection_keys [:components, :per_component]

  defp build_selection_by_axis(sel, per_comp) do
    sel
    |> Map.drop(@reserved_selection_keys)
    |> Map.merge(per_comp)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case axis_for_selection_key(key) do
        nil -> acc
        axis -> Map.put(acc, axis, value)
      end
    end)
  end

  # `:variants` → "variant", `:colors` → "color", `:sizes` → "size";
  # any other key passes through as a string axis name.
  defp axis_for_selection_key(:variants), do: "variant"
  defp axis_for_selection_key(:colors), do: "color"
  defp axis_for_selection_key(:sizes), do: "size"
  defp axis_for_selection_key(key) when is_atom(key), do: Atom.to_string(key)
  defp axis_for_selection_key(key) when is_binary(key), do: key
  defp axis_for_selection_key(_), do: nil

  # Drop helper clauses the selection rules out. Prefer the helper's
  # `discriminators` (exact axis/value pairs); fall back to matching the
  # literal positional args. Unclassifiable helpers (catch-all, non-literal
  # patterns) are always kept so a render never crashes.
  defp filter_helpers(component, selection_by_axis) do
    helpers = component["helpers"] || []
    bindings = helper_bindings(component)

    kept =
      Enum.filter(helpers, fn h ->
        cond do
          discriminators = h["discriminators"] ->
            keep_by_discriminators?(discriminators, selection_by_axis)

          true ->
            keep_by_bindings?(h, Map.get(bindings, h["name"], %{}), selection_by_axis)
        end
      end)

    Map.put(component, "helpers", kept)
  end

  # WHICH ATTRIBUTE EACH HELPER PARAMETER DESCRIBES, read from the kit's own call sites.
  #
  # `color_variant(@variant, @kind)` in a component's template says parameter 0 is `variant` and
  # parameter 1 is `kind`. This used to be assumed instead — argument 0 tested against the variant
  # selection, argument 1 against the colour — which is Chelekom's signature written into the
  # installer. `discriminators` is the Chelekom exporter's own field, so a third-party kit fell to
  # that branch for every helper: a kit ordering its parameters differently, or naming its axes the
  # obvious `variant`/`color`, had every clause of `size_class/1` tested as `"sm" in ["solid"]` and
  # dropped. Either the component then renders at its fallback style with controls that do nothing,
  # or the generated module defines no `size_class/1` while the template calls it and the component
  # fails to compile — on the canvas AND on the published page.
  #
  # `passed_assigns/1` and this scan are the same two the feature extractor above already uses.
  defp helper_bindings(component) do
    source =
      [component["template"] || "" | Enum.map(component["helpers"] || [], &(&1["code"] || ""))]
      |> Enum.join("\n")

    for [_call, helper, args] <- Regex.scan(~r/\b([a-z_][a-z0-9_]*)\s*\(([^()]*)\)/, source),
        reduce: %{} do
      acc ->
        case passed_assigns(args) do
          [] -> acc
          pairs -> Map.update(acc, helper, index_map(pairs), &Map.merge(index_map(pairs), &1))
        end
    end
  end

  defp index_map(pairs), do: Map.new(pairs, fn {attr, index} -> {index, attr} end)

  # A clause survives unless EVERY position that is both bound and selected rules it out. An
  # unbound position, a catch-all pattern, and an axis the operator did not narrow all mean "cannot
  # say", and cannot-say keeps the clause — shipping one clause too many is a component that renders,
  # while shipping one too few is a component that does not.
  defp keep_by_bindings?(helper, bindings, selection_by_axis) do
    case parse_literal_args(helper["args"] || "") do
      {:ok, args} ->
        args
        |> Enum.with_index()
        |> Enum.all?(fn {argument, index} ->
          allowed = Map.get(selection_by_axis, Map.get(bindings, index), :all)

          argument == "_" or allowed == :all or
            (is_binary(argument) and argument in allowed)
        end)

      _opaque ->
        true
    end
  end

  defp keep_by_discriminators?([], _selection), do: true

  defp keep_by_discriminators?(clauses, selection) when is_list(clauses) do
    Enum.all?(clauses, fn clause ->
      axis = clause["axis"]
      clause_values = clause["values"] || []

      case Map.get(selection, axis, :all) do
        :all -> true
        user_values when is_list(user_values) -> Enum.any?(clause_values, &(&1 in user_values))
      end
    end)
  end

  defp keep_by_discriminators?(_, _), do: true

  # `"default", "primary"` → `{:ok, ["default", "primary"]}`, `_` → `{:ok, ["_"]}`.
  # Anything non-literal returns `:opaque` (helper kept as-is).
  defp parse_literal_args(""), do: :opaque

  defp parse_literal_args(args) when is_binary(args) do
    parts =
      args
      |> String.split(",")
      |> Enum.map(&String.trim/1)

    if Enum.all?(parts, &literal_or_underscore?/1) do
      {:ok, Enum.map(parts, &unquote_literal/1)}
    else
      :opaque
    end
  end

  defp literal_or_underscore?(s),
    do: s == "_" or (String.starts_with?(s, "\"") and String.ends_with?(s, "\""))

  defp unquote_literal("_"), do: "_"

  defp unquote_literal(s) when is_binary(s) do
    s |> String.trim_leading("\"") |> String.trim_trailing("\"")
  end

  # Narrow `attrs[].values` to the selected set so Phoenix's compile-time
  # attr validation rejects un-installed values.
  defp narrow_attr_values(component, selection_by_axis) do
    attrs =
      (component["attrs"] || [])
      |> Enum.map(fn attr ->
        case Map.get(selection_by_axis, attr["name"], :all) do
          :all -> attr
          allowed when is_list(allowed) -> narrow_attr_axis(attr, allowed)
        end
      end)

    Map.put(component, "attrs", attrs)
  end

  defp narrow_attr_axis(attr, allowed) when is_list(allowed) do
    case get_in(attr, ["opts", "values"]) do
      nil ->
        attr

      values when is_list(values) ->
        kept = Enum.filter(values, &(&1 in allowed))
        opts = Map.put(attr["opts"], "values", kept)
        Map.put(attr, "opts", opts)
    end
  end

  defp create_component(params, site_id, bundle, actor) do
    params
    |> stamp_kit(bundle)
    |> stringify_to_atom_keys()
    |> Map.put(:site_id, site_id)
    |> Map.update(:format, :heex, &maybe_atom/1)
    |> normalize_helpers()
    |> normalize_attrs()
    |> normalize_slots()
    |> upsert_row(Component, actor)
  end

  # WHICH KIT A ROW CAME FROM, recorded rather than inferred. Uninstall used to select rows by the
  # kit's own name as a prefix, which is only true of kits that name their components after
  # themselves. A bundle called `acmekit` shipping `acme-icon` uninstalled to `:ok` and left every
  # component installed, with no surface anywhere to remove them afterwards.
  #
  # Chelekom's exporter already stamps `extra.ui_kit`, but a hand-written bundle need not, so the
  # value written here is the INSTALLING bundle's name — the same string `uninstall_kit!/2` matches
  # on — rather than whatever the file happened to carry.
  #
  # AND WHICH VERSION OF IT, with a fingerprint of what was written: a row that says only which kit
  # wrote it cannot be compared with a newer bundle, which is why a site kept the components it was
  # seeded with for ever. `UiKitUpgrade` is what reads all three back.
  defp stamp_kit(params, %{"name" => kit_name} = bundle),
    do: UiKitUpgrade.stamp(params, kit_name, bundle["version"])

  defp stamp_kit(params, _bundle), do: params

  defp create_js_hook(params, site_id, actor) do
    params
    |> stringify_to_atom_keys()
    |> Map.put(:site_id, site_id)
    |> Map.update(:format, :js, &coerce_enum(JsHook, :format, &1, :js))
    # JsHook has no `extra` field; drop the converter's traceability stamp.
    |> Map.delete(:extra)
    |> upsert_row(JsHook, actor)
  end

  defp create_stylesheet(params, site_id, actor) do
    params
    |> stringify_to_atom_keys()
    |> Map.put(:site_id, site_id)
    |> Map.update(:format, :css, &coerce_enum(Stylesheet, :format, &1, :css))
    |> Map.update(:kind, :theme, &coerce_enum(Stylesheet, :kind, &1, :theme))
    |> upsert_row(Stylesheet, actor)
  end

  # Create-or-update by (name, site_id):
  #   * active row    → `master_update` (in place, history kept)
  #   * archived row  → `{:skipped, name}` (never resurrect; unarchive first)
  #   * no row        → `master_create`
  # site_id: nil = global (master), a UUID = that one site.
  defp upsert_row(attrs, resource, actor) do
    attrs = accepted_only(attrs, resource)
    name = attrs[:name]
    site_id = attrs[:site_id]

    cond do
      active = active_row(resource, name, site_id, actor) ->
        {:upserted, Ash.update!(active, own(attrs, actor), writing(actor, site_id, :update))}

      archived_row?(resource, name, site_id, actor) ->
        {:skipped, name}

      true ->
        {:upserted, Ash.create!(resource, own(attrs, actor), writing(actor, site_id, :create))}
    end
  end

  @package %{defer_runtime: true, page_code: :package}

  # NOBODY, A MASTER, OR THE SITE'S OWN ADMIN — the three answers every runtime write in this CMS
  # gives, and the reason the middle one cannot simply keep its tenant: `TenantContext` refuses a
  # master action carrying one, and with `authorize?: false` that refusal never ran. A tenant admin
  # writes their own site's action under its tenant, which is what makes the site Ash's answer
  # rather than this module's.
  defp writing(nil, site_id, :create),
    do: [action: :master_create, authorize?: false, tenant: site_id, context: @package]

  defp writing(nil, site_id, :update),
    do: [action: :master_update, authorize?: false, tenant: site_id, context: @package]

  defp writing(%{site_id: nil} = actor, _site_id, :create),
    do: [action: :master_create, actor: actor, context: @package]

  defp writing(%{site_id: nil} = actor, _site_id, :update),
    do: [action: :master_update, actor: actor, context: @package]

  defp writing(actor, site_id, :create),
    do: [action: :create, actor: actor, tenant: site_id, context: @package]

  defp writing(actor, site_id, :update),
    do: [action: :update, actor: actor, tenant: site_id, context: @package]

  # THE TENANT ACTION TAKES ITS SITE FROM THE TENANT, and refuses to be told it twice.
  defp own(attrs, nil), do: attrs
  defp own(attrs, %{site_id: nil}), do: attrs
  defp own(attrs, _tenant_admin), do: Map.delete(attrs, :site_id)

  # A bundle is a THIRD PARTY's file, and a key its author added that this resource does not accept
  # is not a reason to take the caller down with an `Ash.Error.Invalid` — which is exactly what
  # happened: one extra top-level key in a kit's JSON crashed the Studio's Install and closed the
  # editor's sheet. Unknown keys are dropped and the rest installs.
  defp accepted_only(attrs, resource) do
    accepted = accepted_inputs(resource)
    Map.filter(attrs, fn {key, _value} -> MapSet.member?(accepted, key) end)
  end

  defp accepted_inputs(resource) do
    for action <- Ash.Resource.Info.actions(resource),
        action.name in [:master_create, :master_update],
        input <- (action.accept || []) ++ Enum.map(action.arguments || [], & &1.name),
        into: MapSet.new(),
        do: input
  end

  defp active_row(resource, name, site_id, actor) do
    resource
    |> Ash.Query.for_read(:read_any, %{}, reading(actor))
    |> scope_to_row(name, site_id)
    |> read_first(actor)
  end

  defp archived_row?(resource, name, site_id, actor) do
    {action, opts} = archived_read(actor)

    resource
    |> Ash.Query.for_read(action, %{}, opts)
    |> scope_to_row(name, site_id)
    |> read_first(actor)
    |> then(&(!is_nil(&1)))
  end

  # name + site_id scope. nil site_id must compare as IS NULL, not `= NULL`
  # (always false), or global rows are never found.
  defp scope_to_row(query, name, site_id) do
    query = Ash.Query.filter(query, name == ^name)

    if is_nil(site_id),
      do: Ash.Query.filter(query, is_nil(site_id)),
      else: Ash.Query.filter(query, site_id == ^site_id)
  end

  # SEE `MishkaCmsCore.Runtime.PageProvision`'s `reading/1`: the read action does not change with
  # the actor, because the rows are already scoped by name and site in the filter.
  defp reading(nil), do: [authorize?: false]
  defp reading(actor), do: [actor: actor]

  # THE ARCHIVED ROWS, AND THE ONE READ AN ACTOR'S ROLE DOES CHANGE. `:master_archived` refuses a
  # tenant actor outright — see `MishkaCmsCore.Runtime.Resources.Validations.TenantContext` — so the
  # site's own admin reads its own `:archived` under its tenant, which answers with the same rows
  # for the only site they can be provisioning.
  defp archived_read(nil), do: {:master_archived, [authorize?: false]}
  defp archived_read(%{site_id: nil} = actor), do: {:master_archived, [actor: actor]}

  defp archived_read(%{site_id: site_id} = actor),
    do: {:archived, [actor: actor, tenant: site_id]}

  # The name + site_id scope is unique, so there is at most one row.
  #
  # THE OPTS HERE WIN OVER THE QUERY'S OWN. `Ash.Query.for_read/4` above puts the actor on the
  # query, and an `authorize?: false` handed to `Ash.read!/2` would override it and skip the policy
  # anyway — which is what this did, so the actor two lines up was decorative.
  defp read_first(query, actor) do
    case Ash.read!(query, reading(actor)) do
      %{results: results} -> List.first(results)
      list when is_list(list) -> List.first(list)
    end
  end

  # Split `{:upserted, record} | {:skipped, name}` results into
  # `{[records], [skipped_names]}`, preserving order.
  defp partition_results(tagged) do
    {ups, skips} =
      Enum.reduce(tagged, {[], []}, fn
        {:upserted, record}, {ups, skips} -> {[record | ups], skips}
        {:skipped, name}, {ups, skips} -> {ups, [name | skips]}
      end)

    {Enum.reverse(ups), Enum.reverse(skips)}
  end

  # Top-level keys (name, template, attrs, etc.) are atomized so Ash's
  # changeset accepts them. Nested maps (`opts`, `extra`) keep string keys.
  defp stringify_to_atom_keys(%{} = m) do
    Enum.into(m, %{}, fn {k, v} when is_binary(k) -> {String.to_atom(k), v} end)
  end

  defp normalize_helpers(%{helpers: helpers} = params) when is_list(helpers) do
    %{params | helpers: Enum.map(helpers, &atomize_helper/1)}
  end

  defp normalize_helpers(params), do: params

  defp atomize_helper(%{} = h) do
    Enum.into(h, %{}, fn {k, v} when is_binary(k) -> {String.to_atom(k), v} end)
  end

  defp normalize_attrs(%{attrs: attrs} = params) when is_list(attrs) do
    %{params | attrs: Enum.map(attrs, &atomize_attr/1)}
  end

  defp normalize_attrs(params), do: params

  # Each attr has top-level atom keys (name, type, opts, struct_name);
  # opts itself stays string-keyed (Ash :map type).
  defp atomize_attr(%{} = a) do
    Enum.into(a, %{}, fn {k, v} when is_binary(k) -> {String.to_atom(k), v} end)
  end

  defp normalize_slots(%{slots: slots} = params) when is_list(slots) do
    %{params | slots: Enum.map(slots, &atomize_slot/1)}
  end

  defp normalize_slots(params), do: params

  defp atomize_slot(%{} = s) do
    Enum.into(s, %{}, fn {k, v} when is_binary(k) -> {String.to_atom(k), v} end)
  end

  # THE RESOURCE ALREADY KNOWS WHAT IT ACCEPTS. `String.to_existing_atom/1` on a value from a file we
  # did not write is two failures wearing one hat: it raises for a word nobody has used, and for a
  # word that happens to exist elsewhere in the VM it silently produces a value the attribute never
  # allowed. Reading the attribute's own `one_of` hardcodes no vocabulary and stays correct when the
  # enum grows.
  defp coerce_enum(resource, key, value, fallback) when is_binary(value) do
    attribute = Ash.Resource.Info.attribute(resource, key)
    allowed = (attribute && get_in(attribute.constraints, [:one_of])) || []

    Enum.find(allowed, (attribute && attribute.default) || fallback, &(to_string(&1) == value))
  end

  defp coerce_enum(_resource, _key, value, _fallback) when is_atom(value), do: value
  defp coerce_enum(_resource, _key, _value, fallback), do: fallback

  defp maybe_atom(s) when is_binary(s), do: String.to_existing_atom(s)
  defp maybe_atom(s) when is_atom(s), do: s

  # Hard-deletes via `:master_permanent_destroy`; soft-deleted rows still
  # occupy the unique-name index.
  # The prefix has to be SLUGIFIED, because that is the form the rows were stored under: the
  # `Component` resource slugifies names, so a bundle called `acme_headless` installs
  # `acme-headless-tree`. Matching on the raw name meant a kit whose name carries an underscore
  # could be installed and never uninstalled.
  defp delete_existing_components_by_prefix(kit_name, site_id) do
    prefix = "#{slugified_kit(kit_name)}-%"
    kit = to_string(kit_name)

    # PROVENANCE FIRST, prefix second. The prefix alone is a Chelekom convention — its kit is
    # `chelekom` and its components are `chelekom-*` — and a kit that names its components anything
    # else was silently un-uninstallable: `:ok`, hooks and stylesheets gone, every component left.
    # The prefix arm stays for rows installed before `stamp_kit/2` existed.
    #
    # A COPY IS NOBODY'S KIT. `MishkaCmsCore.Runtime.ComponentCopy` names a copy of
    # `chelekom-button` `chelekom-button-copy-…`, which the prefix arm matches, and this delete leaves
    # no archive and no version. The copy drops `ui_kit` and records `copied_from`, and that is what
    # spares it.
    Component
    |> Ash.Query.filter(
      (like(name, ^prefix) or extra["ui_kit"] == ^kit) and is_nil(extra["copied_from"])
    )
    |> Ash.read!(authorize?: false)
    |> Enum.filter(fn r -> r.site_id == site_id end)
    |> Enum.each(fn record ->
      Ash.destroy!(record, action: :master_permanent_destroy, authorize?: false)
    end)
  end

  defp slugified_kit(kit_name),
    do: kit_name |> to_string() |> String.downcase() |> String.replace("_", "-")

  # Collect both the kebab `name` and the PascalCase `extra.module` — either
  # form may occupy a unique-name slot. Matching is case/separator-insensitive
  # (see `normalize_hook_name/1`).
  defp hook_purge_targets(bundle) do
    hooks = bundle["js_hooks"] || []
    names = Enum.map(hooks, & &1["name"])

    modules = Enum.map(hooks, &hook_extra(&1, "module")) |> Enum.reject(&is_nil/1)

    # A ROW THIS BUNDLE HAS RENAMED IS STILL THIS BUNDLE'S ROW. Chelekom shipped its hooks as bare
    # `floating`, `carousel`, `sidebar` while its 136 components shipped as `chelekom-*`; the hooks
    # are namespaced now, and without this an upgrade would create the new row and leave the old one
    # beside it — two hooks with the same code, and an admin list that reads worse than the
    # inconsistency this fixed.
    #
    # Named by the BUNDLE rather than guessed by stripping a prefix: "delete every hook whose name is
    # what this one would be called without its kit" would purge a site's own `carousel` on the first
    # install of a kit that happens to have one.
    replaces = Enum.map(hooks, &hook_extra(&1, "replaces")) |> Enum.reject(&is_nil/1)

    Enum.uniq(names ++ modules ++ replaces)
  end

  # A RENAME IS THE ONE THING AN INSTALL DOES THAT A STORED TEMPLATE CANNOT FOLLOW. A page that wrote
  # `phx-hook="GlobalFloating"` by hand keeps saying so, and the row it named is gone — the element
  # renders, carries its attribute, and does nothing, which is the silent failure this whole rename
  # was meant to stop happening between kits. The installer cannot rewrite somebody's pages, so it
  # says what it did and names the new key, which is the only thing an operator can act on.
  #
  # Logged only when a row is actually there to remove: on every install after the first, this is
  # empty and silent.
  defp announce_renames(targets, kit) do
    wanted = MapSet.new(targets, &normalize_hook_name/1)

    existing =
      JsHook
      |> Ash.read!(authorize?: false)
      |> Enum.filter(fn row ->
        is_nil(row.site_id) and MapSet.member?(wanted, normalize_hook_name(row.name))
      end)

    for row <- existing do
      Logger.warning(
        "[UiKitHandler] #{kit} has renamed the js_hook #{row.name} to #{kit}-#{row.name}. " <>
          "Any template naming #{live_hook_key(row.name)} must now name " <>
          "#{live_hook_key(kit <> "-" <> row.name)}."
      )
    end

    targets
  end

  defp live_hook_key(name),
    do: "Global" <> (name |> String.split("-") |> Enum.map_join("", &String.capitalize/1))

  # What this bundle says it has renamed, and nothing else — never the bundle's own new names, which
  # are about to be written.
  defp hook_rename_targets(bundle) do
    (bundle["js_hooks"] || [])
    |> Enum.map(&hook_extra(&1, "replaces"))
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
  end

  # ATOM KEYS ARE WRITTEN OUT, NOT MINTED. `String.to_existing_atom/1` raises when the atom is not in
  # the table yet, and `:replaces` reaches the code table only if something else happened to have
  # written it — which in a fresh VM installing a kit fetched from a URL, nothing had.
  defp hook_extra(hook, "module"),
    do: get_in(hook, ["extra", "module"]) || get_in(hook, [:extra, :module])

  defp hook_extra(hook, "replaces"),
    do: get_in(hook, ["extra", "replaces"]) || get_in(hook, [:extra, :replaces])

  defp delete_existing_js_hooks([]), do: :ok

  defp delete_existing_js_hooks(targets) when is_list(targets) do
    target_set = MapSet.new(targets, &normalize_hook_name/1)

    JsHook
    |> Ash.read!(authorize?: false)
    |> Enum.filter(fn r ->
      is_nil(r.site_id) and MapSet.member?(target_set, normalize_hook_name(r.name))
    end)
    |> Enum.each(fn record ->
      Ash.destroy!(record, action: :master_permanent_destroy, authorize?: false)
    end)
  end

  defp normalize_hook_name(nil), do: ""

  defp normalize_hook_name(name) when is_binary(name) do
    name |> String.downcase() |> String.replace(["-", "_"], "")
  end

  # Case-insensitive name match scoped to the install tenancy.
  defp delete_existing_stylesheets([], _site_id), do: :ok

  defp delete_existing_stylesheets(names, site_id) do
    target = MapSet.new(names, &String.downcase/1)

    Stylesheet
    |> Ash.read!(authorize?: false)
    |> Enum.filter(fn r ->
      r.site_id == site_id and MapSet.member?(target, String.downcase(r.name))
    end)
    |> Enum.each(fn record ->
      Ash.destroy!(record, action: :master_permanent_destroy, authorize?: false)
    end)
  end
end
