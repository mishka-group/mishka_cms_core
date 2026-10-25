# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.ShareCard do
  @moduledoc """
  The picture a link to a page shows where it is shared — X, Telegram, WhatsApp, LinkedIn,
  Slack, Discord — drawn from what the page is: 1200×630 JPEG, the size every one of them shows
  large.

  `MishkaCmsCore.Runtime.Seo` asks for one (`image/2`) for a public page whose head has no image of
  its own to show: nothing stored in its `og:image`. A plugin on `MishkaCmsCore.Runtime.Seo.event/0`
  fills what the card shows of its record through `card`, and its `image` is the card's picture.

  ## What a card shows

  `card` is a map; every key but `title` may be left out:

    * `title` — the page's title, up to three lines, smaller as it grows, then cut with `…`
    * `description` — all of it, in as many lines as fit under the title: set smaller, down to 21
      pixels, before the title steps down a size; one that fits at no size is cut at the end of a
      sentence, else at a word, with `…` (`shorten/1`)
    * `eyebrow` — a short label above the title: a post's category, "Team", "Author"
    * `site`, `host` — the site's name, in the page's language, and its address
    * `logo` — the `site.logo` setting, on a white tile; the site's first letter without one
    * `people` — `[%{name: name, image: path}]`: round photos, the names beside them; up to four
    * `byline`, `meta` — a line under the names: a team, a date, a reading time
    * `picture` — a picture behind the card, darkened under the text

  A picture is a file of the site's own (`site_file/2`): a `/uploads/<site_id>/media/…` path of
  its media (`MishkaCmsCore.Runtime.Media.storage_paths/2`), or a `/…` path under the host's static
  folder. An `http(s)://` address is never fetched. A photo is read only when it is a JPEG, PNG,
  WebP or GIF (`picture_type/1`); the logo may be an SVG too. One it cannot read is left out, and
  the card is drawn without it.

  Text written right to left — Persian, Arabic, Hebrew — puts everything on the right. The fonts
  are in `priv/share_card`: Plus Jakarta Sans for Latin text and Vazirmatn for Arabic script, both
  under the SIL Open Font License 1.1 (`priv/share_card/OFL.txt`).

  ## When it is drawn

  Never in a request. `image/2` answers from ETS (`MishkaCmsCore.Runtime.States.AssetsState`), and
  the first time a card is asked for it is queued: this module is the Oban worker, on
  `:share_cards` (`MishkaCmsCore.Runtime.ShareCardQueue`, as many at once as the Share-card workers
  setting says), one job per card. Until it is drawn, the page shows its own image, or none.

  A card is named by what it shows (`key/1`): a page whose title changes asks for a new card, and the
  old one stays where it is. It is stored at `/uploads/<site_id>/share/<key>.jpg`, served as the
  site's other files are.

  ## Ready before the first visit

  `refresh/3` looks at a page's or a record's card in the background — the plugins on the
  after-save events call it — and queues its drawing when it is not drawn yet, so it is there for
  the first visitor. A save that leaves what the card shows alone finds it drawn and draws nothing.
  `refresh(site_id, target, force: true)` draws it again over the old file: the Regenerate button.

  ## Every card of a site

  `redraw_all/2` looks at every card of a site in the background, so none waits for its first
  visitor: after what every card of the site shows changes — its address, its name or that name's
  translation, its logo — and from the Redraw buttons of the settings page and of an extension. It
  queues one planner job (`MishkaCmsCore.Runtime.Workers.ShareCardPlanWorker`), which asks the
  producers for the cards they own on the site through the `targets_event/0` mishka_installer
  event (`targets/2`) and queues a look at each, in batches. The core answers with its pages
  (`MishkaCmsCore.Runtime.PageShareCardTargets`); an extension or a site answers with its own.

  ## Old cards

  A card drawn for data that has changed since stays on disk until the next look at every card of
  the site: each look marks the files its pages show (`keep/2`), and once all have run the planner's
  `MishkaCmsCore.Runtime.Workers.ShareCardSweepWorker` deletes the files none of them marked. A page
  that asks again for a card swept away has it drawn again.

  Drawn by libvips in a separate process (`MishkaCmsCore.Isolated`), so a file that crashes it ends
  that process, never the server. That process runs at a lower priority (`nice` 10) and libvips in
  it on one thread, so a long redraw leaves the processor to the pages being served.
  """
  use Oban.Worker,
    queue: :share_cards,
    max_attempts: 3,
    unique: [
      period: :infinity,
      keys: [:site_id, :key],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Ash.Query
  require Logger

  alias MishkaCmsCore.Isolated
  alias MishkaCmsCore.Runtime.{Languages, Layout, Media, Page, PageEditions, PageUpload, Seo}
  alias MishkaCmsCore.Runtime.States.{AssetsState, SiteState}
  alias MishkaCmsCore.Runtime.Workers.{ShareCardPlanWorker, ShareCardRefreshWorker}
  alias MishkaInstaller.Event.Hook
  alias Vix.Vips.Image, as: VImage
  alias Vix.Vips.Operation, as: Op

  # Raise it when what a card looks like changes: every card is drawn again under a new key.
  @version 2

  @width 1200
  @height 630
  @margin 72
  @background [10, 9, 18]
  @avatar 60
  @logo 52

  @texts ~w(title description eyebrow site host logo byline picture)

  @photo_types ~w(image/jpeg image/png image/webp image/gif)

  @title_sizes [60, 52, 44]
  @title_gap 22
  @description_sizes [27, 25, 23, 21]

  # A description beyond this many characters fits no card: it is shortened before it is measured.
  @description_cap 600

  @targets_event "runtime:share_card:targets"
  @swept_event "runtime:share_card:swept"

  # The settings a core card shows on every page of a site (`MishkaCmsCore.Runtime.Seo`).
  @site_settings ~w(site.title site.logo)

  @typedoc "What a card shows; see the module doc."
  @type card :: %{optional(atom() | String.t()) => term()}

  @doc """
  The card `card` names, for the site `site_id`: `%{url:, width:, height:, type:}` once it is
  drawn, `nil` until then — the first ask queues it.

  `nil` for a card with no title, and for a site with no id.
  """
  @spec image(String.t() | nil, card()) :: map() | nil
  def image(site_id, card) when is_binary(site_id) and is_map(card) do
    case normalize(card) do
      %{"title" => _} = card -> lookup(site_id, card)
      _no_title -> nil
    end
  end

  def image(_site_id, _card), do: nil

  @typedoc """
  What a refresh is for: one page, by its id, or the pages that show records of a kind
  (`MishkaCmsCore.Runtime.Seo.record_of/1`), with the captures that name one record —
  `{:record, "blog:post", %{"slug" => "hello", "lang" => "en"}}`.
  """
  @type target :: {:page, String.t()} | {:record, String.t(), map()}

  @doc """
  Queues a look, in the background, at the card `target` shows now, and its drawing when it is not
  drawn yet. Saves within two seconds of each other are one look.

  `force: true` looks now and draws the card again even when it is drawn, over the old file.
  """
  @spec refresh(String.t(), target(), keyword()) :: :ok | {:error, term()}
  def refresh(site_id, target, opts \\ []) when is_binary(site_id) do
    force = Keyword.get(opts, :force, false)
    later = if force, do: [], else: [schedule_in: 2]

    %{site_id: site_id, target: encode(target), force: force}
    |> ShareCardRefreshWorker.new(later)
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The event every share card of a site is collected through: `"#{@targets_event}"`.

  It is called with `%{site_id: id, force: boolean, producer: name | nil, targets: %{}}`, and each
  plugin answers with its own put in `targets` under its name (`put_targets/3`) — the name of its
  OTP application, `%{"mishka_blog" => [target, …]}`. A target is either

    * a `t:target/0`, `{:page, id}` or `{:record, kind, captures}`, which `refresh/3` looks at, or
    * an `Oban.Job` changeset of the producer's own worker on `:share_cards`, for a card the core
      does not draw: built with `force` it draws the card again over the old file, else only when
      it is not drawn yet.

  An answer names targets only — ids and captures, read in pages or streamed — and draws nothing.
  With `producer` set, only that producer answers; with `names_only: true` each puts its name and
  no targets (`producers/1`).
  """
  @spec targets_event() :: String.t()
  def targets_event, do: @targets_event

  @doc "The settings a core card shows on every page of a site: its name and its logo."
  @spec site_settings() :: [String.t()]
  def site_settings, do: @site_settings

  @doc """
  Puts `producer`'s targets in an answer to `targets_event/0`; `fun` is called for them only when
  the answer asks every producer or this one.
  """
  @spec put_targets(map(), String.t(), (-> Enumerable.t())) :: map()
  def put_targets(%{names_only: true, targets: %{} = targets} = data, producer, _fun)
      when is_binary(producer),
      do: %{data | targets: Map.put(targets, producer, [])}

  def put_targets(%{producer: only, targets: %{} = targets} = data, producer, fun)
      when is_binary(producer) and (is_nil(only) or only == producer) do
    %{data | targets: Map.put(targets, producer, Enum.to_list(fun.()))}
  end

  def put_targets(data, _producer, _fun), do: data

  @doc """
  Every share card of the site `site_id`, by producer, as the plugins on `targets_event/0` answer:
  `{:ok, %{"mishka_cms_core" => [{:page, id}, …], …}}`.

  Options: `:force`, handed to the producers, and `:producer`, to ask that one alone.
  `{:error, :cannot_run}` while the event cannot run: one of its plugins is started but not loaded.
  """
  @spec targets(String.t(), keyword()) :: {:ok, %{String.t() => list()}} | {:error, :cannot_run}
  def targets(site_id, opts \\ []) when is_binary(site_id) do
    asked = %{
      site_id: site_id,
      force: Keyword.get(opts, :force, false),
      producer: Keyword.get(opts, :producer),
      names_only: false,
      targets: %{}
    }

    case Hook.call(@targets_event, asked, cannot_run: :cannot_run) do
      %{targets: %{} = targets} ->
        {:ok, Map.filter(targets, fn {name, list} -> is_binary(name) and is_list(list) end)}

      :cannot_run ->
        {:error, :cannot_run}

      _not_answered ->
        {:ok, %{}}
    end
  end

  @doc """
  The producers that answer `targets_event/0` on the site `site_id` — or on any site, for `nil` —
  sorted: `["mishka_blog", "mishka_cms_core"]`. Asks for their names alone; nothing is read.
  """
  @spec producers(String.t() | nil) :: [String.t()]
  def producers(site_id) do
    asked = %{site_id: site_id, force: false, producer: nil, names_only: true, targets: %{}}

    case Hook.call(@targets_event, asked) do
      %{targets: %{} = targets} ->
        targets |> Map.keys() |> Enum.filter(&is_binary/1) |> Enum.sort()

      _not_answered ->
        []
    end
  end

  @doc """
  Looks at every share card of the site `site_id` in the background — of every active site for
  `nil` — so a card whose data changed is drawn before anybody asks for it: one planner job a site
  on `:share_cards`, which collects the cards through `targets_event/0` and queues a look at each.
  A site that already has a planner waiting with the same options keeps that one.

  Options:

    * `:force` — `true` draws every card again over its old file; by default only a card whose data
      changed is drawn
    * `:producer` — the one producer to ask, `"mishka_blog"`; every one by default
    * `:schedule_in` — seconds to wait first, so the saves of a burst are one look; none by default

  `{:ok, site_ids}`: the sites a planner is queued for.
  """
  @spec redraw_all(String.t() | nil, keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def redraw_all(site_id, opts \\ [])

  def redraw_all(nil, opts) do
    SiteState.get_active_sites()
    |> Enum.reduce_while({:ok, []}, fn %{id: id}, {:ok, queued} ->
      case redraw_all(id, opts) do
        {:ok, [^id]} -> {:cont, {:ok, [id | queued]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, queued} -> {:ok, Enum.reverse(queued)}
      error -> error
    end
  end

  def redraw_all(site_id, opts) when is_binary(site_id) do
    later =
      case Keyword.get(opts, :schedule_in) do
        seconds when is_integer(seconds) and seconds > 0 -> [schedule_in: seconds]
        _now -> []
      end

    %{
      site_id: site_id,
      force: Keyword.get(opts, :force, false) == true,
      producer: Keyword.get(opts, :producer)
    }
    |> ShareCardPlanWorker.new(later)
    |> Oban.insert()
    |> case do
      {:ok, _job} -> {:ok, [site_id]}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Each card `target`'s pages show now: `%{title:, url:, drawn_at:}`, `drawn_at` the Unix time its
  file was written, `nil` until it is drawn. A page kept out of an index, or storing an `og:image`
  of its own, shows none.
  """
  @spec cards(String.t(), target()) :: [
          %{title: String.t(), url: String.t(), drawn_at: integer() | nil}
        ]
  def cards(site_id, target) do
    for spec <- specs(site_id, target),
        %{"title" => title} = card <- [normalize(spec)],
        key = key(card),
        do: %{title: title, url: url(site_id, key), drawn_at: drawn_at(site_id, key)}
  end

  defp drawn_at(site_id, key) do
    case File.stat(disk_path(site_id, key), time: :posix) do
      {:ok, %{type: :regular, mtime: mtime}} -> mtime
      _not_drawn -> nil
    end
  end

  @doc """
  What each page that shows `target` puts on its share card, as `Seo.head/2` builds it for a visit
  to it: the same card, with the same name. The pages are read as the system, as the sitemap reads
  them — a job has no visitor.

  `redraw: true` tells the plugins on `MishkaCmsCore.Runtime.Seo.event/0` the card is to be drawn
  again (`redraw` in `MishkaCmsCore.Runtime.Seo.given/2`): one that draws a card of its own draws it
  over its old file.
  """
  @spec specs(String.t(), target(), keyword()) :: [map()]
  def specs(site_id, target, opts \\ []) when is_binary(site_id) do
    for %{card: %{} = spec} <- heads(site_id, target, Keyword.get(opts, :redraw, false)),
        do: spec
  end

  @doc """
  Looks at the cards `target`'s pages show now, as `ShareCardRefreshWorker` does in the background:
  a card not drawn yet is queued (`image/2`), and with `force: true` every card is drawn again over
  its old file (`redraw/2`). Each card file the pages show — the core's, and one a plugin on
  `MishkaCmsCore.Runtime.Seo.event/0` drew and put in the head's image — is kept (`keep/2`).
  """
  @spec look(String.t(), target(), keyword()) :: :ok
  def look(site_id, target, opts \\ []) when is_binary(site_id) do
    force = Keyword.get(opts, :force, false) == true

    for head <- heads(site_id, target, force) do
      case head do
        %{card: %{} = spec} when force -> redraw(site_id, spec)
        %{card: %{} = spec} -> keep(site_id, image(site_id, spec))
        _no_card -> :ok
      end

      keep(site_id, head.image)
    end

    :ok
  end

  @doc """
  Marks the card file `url` names as shown now — `/uploads/<site_id>/share/<name>.jpg`, or an
  address whose path is that — so the sweep that follows a look at every card of the site
  (`MishkaCmsCore.Runtime.Workers.ShareCardSweepWorker`) leaves it. A producer whose own job finds
  its card drawn calls it; `look/3` calls it for the core's cards and a plugin's. A map with a
  `url`, as `image/2` answers, is read for it. A file that is not there, a path elsewhere and
  anything else are left alone.
  """
  @spec keep(String.t(), String.t() | map() | nil) :: :ok
  def keep(site_id, %{url: url}), do: keep(site_id, url)

  def keep(site_id, url) when is_binary(site_id) and is_binary(url) do
    with %URI{path: path} when is_binary(path) <- URI.parse(url),
         ["/", "uploads", ^site_id, "share", name] <- Path.split(path),
         ".jpg" <- Path.extname(name),
         file = Path.join(dir(site_id), name),
         true <- File.regular?(file) do
      File.touch(file)
    end

    :ok
  end

  def keep(_site_id, _no_card), do: :ok

  @doc """
  The event the names of the card files a sweep deleted are announced on:
  `"#{@swept_event}"`, with `%{site_id:, removed: ["<name>.jpg", …]}`. A producer that remembers
  its cards as drawn forgets those names here; the core forgets its own.
  """
  @spec swept_event() :: String.t()
  def swept_event, do: @swept_event

  @doc "The folder the share cards of the site `site_id` are written to."
  @spec dir(String.t()) :: String.t()
  def dir(site_id), do: Path.join([Media.static_dir(), "uploads", site_id, "share"])

  # The head each page that shows `target` renders, as built for a visit to it, with the card's
  # spec in `card`.
  defp heads(site_id, target, redraw) do
    case SiteState.get(site_id) do
      {:ok, %{host: host}} when is_binary(host) ->
        base = Seo.base(host)

        for {page, params} <- pages(site_id, target),
            do: head(page, params, site_id, base, redraw)

      _unknown ->
        []
    end
  end

  @doc """
  Queues `card` to be drawn again, over the file drawn before; `:ok` for a card with no title.
  """
  @spec redraw(String.t(), card()) :: :ok | {:error, term()}
  def redraw(site_id, card) when is_binary(site_id) do
    case normalize(card) do
      %{"title" => _} = card ->
        key = key(card)

        case Oban.insert(new(%{site_id: site_id, key: key, card: card})) do
          {:ok, _job} -> mark(site_id, "share_card:" <> key, :queued)
          {:error, reason} -> {:error, reason}
        end

      _no_title ->
        :ok
    end
  end

  @page_fields [
    :id,
    :title,
    :path,
    :section,
    :language,
    :language_group_id,
    :description,
    :seo_tags,
    :schema,
    :permissions,
    :extra,
    :layout_id,
    :updated_at
  ]

  defp pages(site_id, target) do
    Page
    |> Ash.Query.filter(active == true)
    |> only(target)
    |> Ash.Query.select(@page_fields)
    |> Ash.Query.load(tenant_layout: Ash.Query.select(Layout, [:seo_tags]))
    |> Ash.read!(tenant: site_id, authorize?: false, page: false)
    |> Enum.flat_map(&editions(&1, target, site_id))
  end

  defp only(query, {:page, id}), do: Ash.Query.filter(query, id == ^id)
  defp only(query, {:record, _kind, _params}), do: query

  # A page at one address in each language it answers; a page that shows records is left to them.
  defp editions(page, {:page, _id}, site_id) do
    cond do
      Seo.record_of(page.extra) ->
        []

      Languages.captures?(page.path) ->
        for language <- PageEditions.served_languages(page, site_id),
            do: {page, %{Languages.capture() => language}}

      true ->
        [{page, %{}}]
    end
  end

  defp editions(page, {:record, kind, params}, _site_id) do
    if Seo.record_of(page.extra) == kind, do: [{page, params}], else: []
  end

  # The head a visit to `page` with `params` gets, with the card's spec and nothing asked for.
  defp head(page, params, site_id, base, redraw) do
    language = Map.get(params, Languages.capture()) || page.language

    Seo.resolve(
      %{
        title: page.title,
        path: page.path,
        section: page.section,
        language: language,
        language_group_id: page.language_group_id,
        timestamp: page.updated_at,
        seo: %{description: page.description, meta_tags: page.seo_tags, schema: page.schema}
      },
      site_id: site_id,
      url: page.path |> Languages.url(params, site_id) |> Seo.absolute(base),
      params: params,
      record: Seo.record_of(page.extra),
      base: base,
      restricted?: Seo.noindex?(page.permissions, page.extra),
      layers: [layout_tags(page.tenant_layout), List.wrap(page.seo_tags)],
      card: :spec,
      redraw: redraw
    )
  end

  defp layout_tags(%{seo_tags: tags}), do: List.wrap(tags)
  defp layout_tags(_no_layout), do: []

  @doc false
  # A target as a job stores it, and back.
  def encode({:page, id}), do: %{"page" => id}
  def encode({:record, kind, params}), do: %{"record" => kind, "params" => params}

  @doc false
  def decode(%{"page" => id}), do: {:page, id}
  def decode(%{"record" => kind, "params" => params}), do: {:record, kind, params}

  defp lookup(site_id, card) do
    key = key(card)
    entry = "share_card:" <> key

    case AssetsState.get_value(site_id, entry) do
      :ready ->
        found(site_id, key)

      :queued ->
        nil

      nil ->
        case File.regular?(disk_path(site_id, key)) do
          true ->
            mark(site_id, entry, :ready)
            found(site_id, key)

          false ->
            queue(site_id, key, card, entry)
            nil
        end
    end
  end

  defp found(site_id, key),
    do: %{url: url(site_id, key), width: @width, height: @height, type: "image/jpeg"}

  defp queue(site_id, key, card, entry) do
    case Oban.insert(new(%{site_id: site_id, key: key, card: card})) do
      {:ok, _job} -> mark(site_id, entry, :queued)
      {:error, reason} -> Logger.warning("[ShareCard] not queued: #{inspect(reason)}")
    end
  end

  defp mark(site_id, entry, state),
    do:
      AssetsState.save(%{
        id: site_id,
        type: entry,
        value: state,
        hash: nil,
        updated_at: DateTime.utc_now()
      })

  @doc """
  The name of the card that shows `card`: the same for the same card, another when anything on it
  changes.
  """
  @spec key(card()) :: String.t()
  def key(card) do
    {@version, normalize(card)}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  @doc "Where the card `key` of the site `site_id` is served."
  @spec url(String.t(), String.t()) :: String.t()
  def url(site_id, key), do: "/uploads/#{site_id}/share/#{key}.jpg"

  @doc """
  The headers `Plug.Static` adds to a file it serves from the uploads folder:

    * a card is named by what it shows (`key/1`), and a site's icon
      (`/uploads/<site_id>/icons/<hash>-<size>.png`, `MishkaCmsCore.Runtime.SiteIcon`) by the
      picture it is drawn from, so any cache may keep either a year;
    * a file a visitor uploaded to a page (`/uploads/<site_id>/forms/<file>`) is saved rather than
      shown, never sniffed into another type, and sandboxed — see
      `MishkaCmsCore.Runtime.PageUpload.static_headers/0`;
    * a media library file (`/uploads/<site_id>/media/…`) is never sniffed into another type, and an
      `.svg` among them is sandboxed, so a script in it does not run when its address is opened;
    * any other file gets none.

      plug Plug.Static, at: "/", only: ~w(uploads), headers: {ShareCard, :static_headers, []}
  """
  @spec static_headers(Plug.Conn.t()) :: %{optional(String.t()) => String.t()}
  def static_headers(%Plug.Conn{path_info: ["uploads", _site_id, folder, _name]})
      when folder in ["share", "icons"],
      do: %{"cache-control" => "public, max-age=31536000, immutable"}

  def static_headers(%Plug.Conn{path_info: ["uploads", _site_id, "forms", _name]}),
    do: PageUpload.static_headers()

  def static_headers(%Plug.Conn{path_info: ["uploads", _site_id, "media" | [_ | _] = inner]}) do
    case inner |> List.last() |> Path.extname() |> String.downcase() do
      ".svg" -> %{"x-content-type-options" => "nosniff", "content-security-policy" => "sandbox"}
      _other -> %{"x-content-type-options" => "nosniff"}
    end
  end

  def static_headers(_conn), do: %{}

  defp disk_path(site_id, key), do: Path.join(dir(site_id), key <> ".jpg")

  # String keys, as the job stores it; empty and unknown values left out.
  defp normalize(card) do
    texts =
      for key <- @texts,
          value = text(field(card, key)),
          is_binary(value),
          into: %{},
          do: {key, value}

    people =
      for person <- List.wrap(field(card, "people")),
          is_map(person),
          name = text(field(person, "name")),
          is_binary(name),
          do: %{"name" => name, "image" => text(field(person, "image"))}

    meta =
      for value <- List.wrap(field(card, "meta")), text = text(value), is_binary(text), do: text

    texts
    |> put_list("people", Enum.take(people, 4))
    |> put_list("meta", Enum.take(meta, 3))
  end

  defp put_list(map, _key, []), do: map
  defp put_list(map, key, list), do: Map.put(map, key, list)

  # A key as a string or an atom: a plugin's card has atoms, a stored job strings.
  defp field(map, key) when is_map(map) do
    Map.get_lazy(map, key, fn ->
      Enum.find_value(map, fn {name, value} ->
        is_atom(name) and Atom.to_string(name) == key and value
      end)
    end)
  end

  defp text(value) when is_binary(value) do
    case value |> String.replace(~r/\s+/u, " ") |> String.trim() do
      "" -> nil
      text -> text
    end
  end

  defp text(_not_text), do: nil

  @impl Oban.Worker
  # sobelow_skip ["Traversal.FileModule"]
  # The site's share folder plus `key/1`, a hex SHA-256 digest; this module enqueued both.
  def perform(%Oban.Job{args: %{"site_id" => site_id, "key" => key, "card" => card}}) do
    target = disk_path(site_id, key)
    card = with_files(card, site_id)

    with {:ok, {:ok, jpeg}} <-
           Isolated.run(__MODULE__, :draw, [card], env: env(), nice: 10, timeout: 60_000),
         :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.write(target <> ".part", jpeg),
         :ok <- File.rename(target <> ".part", target) do
      mark(site_id, "share_card:" <> key, :ready)
      :ok
    else
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # The site's own files a card names, as paths on disk; anything else is left out.
  defp with_files(card, site_id) do
    people =
      for person <- Map.get(card, "people", []),
          do: Map.put(person, "image", site_file(person["image"], site_id))

    card
    |> Map.put("picture", site_file(card["picture"], site_id))
    |> Map.put("logo", site_file(card["logo"], site_id))
    |> Map.put("people", people)
  end

  @doc """
  The file on disk a picture's address names, when it is a file of the site `site_id`'s own: a
  `/uploads/<site_id>/media/…` path of its media (`MishkaCmsCore.Runtime.Media.storage_paths/2`),
  or a `/…` path under the host's static folder outside `uploads`. `nil` for a file that is not
  there, a path of another site or climbing out, an `http(s)://` address — never fetched — and
  anything else.

      site_file("/uploads/<site_id>/media/brand/logo.svg", site_id) #=> "<static>/uploads/<site_id>/media/brand/logo.svg"
  """
  @spec site_file(term(), String.t()) :: Path.t() | nil
  def site_file("/uploads/" <> _ = path, site_id) do
    with {:ok, %{active: active}} <- Media.storage_paths(path, site_id),
         true <- File.regular?(active) do
      active
    else
      _not_a_file -> nil
    end
  end

  def site_file("/" <> relative, _site_id) do
    with {:ok, clean} <- Path.safe_relative(relative),
         false <- String.starts_with?(clean, "uploads"),
         path = Path.join(Media.static_dir(), clean),
         true <- File.regular?(path) do
      path
    else
      _not_a_file -> nil
    end
  end

  def site_file(_not_a_path, _site_id), do: nil

  # The fonts in `priv/share_card`, found through fontconfig on every system — macOS included,
  # whose own text backend cannot load a font file — and every loader allowed: only the formats
  # `image?/2` checked are read.
  defp env do
    [
      {~c"FONTCONFIG_FILE",
       String.to_charlist(Application.app_dir(:mishka_cms_core, "priv/share_card/fonts.conf"))},
      {~c"PANGOCAIRO_BACKEND", ~c"fc"},
      {~c"VIPS_CONCURRENCY", ~c"1"},
      {~c"XDG_CACHE_HOME", String.to_charlist(System.tmp_dir!())},
      {~c"VIPS_BLOCK_UNTRUSTED", false}
    ]
  end

  @doc false
  # Runs in the separate process `perform/1` starts; `card` is what `with_files/2` made of it.
  @spec draw(map()) :: {:ok, binary()} | {:error, term()}
  def draw(card) do
    rtl? = rtl?(card["title"])
    picture = picture(card["picture"], rtl?)
    text_width = if picture, do: 700, else: @width - 2 * @margin

    (picture || backdrop())
    |> compose(grid(), 0, 0)
    |> compose(accent_line(), 0, @height - 6)
    |> header(card, rtl?)
    |> footer(card, rtl?)
    |> body(card, rtl?, text_width)
    |> Image.write(:memory, suffix: ".jpg", quality: 88, strip_metadata: true)
  end

  @doc """
  Where `card`'s text goes, measured as `draw/1` sets it, in a separate process like the drawing and
  without drawing it: `{:ok, %{title_size:, description_size:, description:}}` — the sizes in pixels
  and the description as it is shown, which is the whole of it unless no size fits it. Never called
  in a request.
  """
  @spec layout(card()) :: {:ok, map()} | {:error, term()}
  def layout(card) do
    Isolated.run(__MODULE__, :measure, [normalize(card)], env: env(), nice: 10, timeout: 60_000)
  end

  @doc false
  # Runs in the separate process `layout/1` starts.
  @spec measure(map()) :: map()
  def measure(card) do
    text_width = if card["picture"], do: 700, else: @width - 2 * @margin
    texts = texts(card, text_width)

    %{
      title_size: texts.title_size,
      description_size: texts.description_size,
      description: texts.shown
    }
  end

  @doc """
  The picture at `path` drawn in a square of each of `sizes`, as PNGs: fitted whole and centered
  on transparency, never stretched or cut. Drawn in a separate process, as a card is:
  `{:ok, %{size => png}}`, else `{:error, reason}`.

  `path` is a file on disk `picture_type/1` names a PNG, JPEG, WebP, GIF or SVG — a site's
  home-screen icon (`MishkaCmsCore.Runtime.SiteIcon`).

      squares("/srv/uploads/<site_id>/media/icon.svg", [180, 512])
      #=> {:ok, %{180 => <<137, 80, 78, 71, …>>, 512 => <<137, 80, 78, 71, …>>}}
  """
  @spec squares(Path.t(), [pos_integer()]) ::
          {:ok, %{pos_integer() => binary()}} | {:error, term()}
  def squares(path, sizes) when is_binary(path) and is_list(sizes) do
    case Isolated.run(__MODULE__, :draw_squares, [path, sizes],
           env: env(),
           nice: 10,
           timeout: 60_000
         ) do
      {:ok, {:ok, pngs}} -> {:ok, pngs}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # Runs in the separate process `squares/2` starts.
  @spec draw_squares(Path.t(), [pos_integer()]) ::
          {:ok, %{pos_integer() => binary()}} | {:error, term()}
  def draw_squares(path, sizes) do
    Enum.reduce_while(sizes, {:ok, %{}}, fn size, {:ok, pngs} ->
      case square(path, size) do
        {:ok, png} -> {:cont, {:ok, Map.put(pngs, size, png)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp square(path, size) do
    with {:ok, img} <- Image.thumbnail(path, "#{size}x#{size}"),
         {:ok, img} <- with_alpha(img),
         {:ok, img} <- Image.embed(img, size, size) do
      Image.write(img, :memory, suffix: ".png", strip_metadata: true)
    end
  end

  # --- the parts ---------------------------------------------------------------------------------

  defp header(canvas, card, rtl?) do
    {mark, wide?} = brand(card["logo"], card["site"])
    mark_x = edge(rtl?, width(mark))
    mark_y = 56 + div(@logo - height(mark), 2)
    canvas = compose(canvas, mark, mark_x, mark_y)

    case {wide?, card["site"]} do
      {false, site} when is_binary(site) ->
        site = text!(site, "Bold", 26, "#eeeaff", 760)
        x = if rtl?, do: mark_x - 16 - width(site), else: mark_x + width(mark) + 16
        compose(canvas, site, x, 56 + div(@logo - height(site), 2))

      _wordmark_or_nameless ->
        canvas
    end
  end

  defp footer(canvas, %{"people" => [_ | _] = people} = card, rtl?) do
    stack = avatar_stack(people)
    names = Enum.map_join(people, if(rtl?, do: "، ", else: ", "), & &1["name"])
    names = text!(names, "Bold", 24, "#f1eeff", 620)
    second = byline(card)
    second = second && text!(second, "Regular", 21, "#a7a2cc", 620)

    top = @height - @margin - @avatar
    stack_x = edge(rtl?, width(stack))

    text_x = fn img ->
      if rtl?, do: stack_x - 18 - width(img), else: stack_x + width(stack) + 18
    end

    lines = height(names) + if(second, do: 4 + height(second), else: 0)
    names_y = top + div(@avatar - lines, 2)

    canvas
    |> compose(stack, stack_x, top)
    |> compose(names, text_x.(names), names_y)
    |> compose_if(second, &compose(&1, second, text_x.(second), names_y + height(names) + 4))
    |> host(card, rtl?)
  end

  defp footer(canvas, card, rtl?) do
    middle = @height - @margin - div(@avatar, 2)

    case byline(card) do
      nil ->
        host(canvas, card, rtl?)

      line ->
        line = text!(line, "Regular", 22, "#a7a2cc", 700)

        canvas
        |> compose(line, edge(rtl?, width(line)), middle - div(height(line), 2))
        |> host(card, rtl?)
    end
  end

  defp byline(card) do
    case Enum.reject([card["byline"] | Map.get(card, "meta", [])], &is_nil/1) do
      [] -> nil
      parts -> Enum.join(parts, "  ·  ")
    end
  end

  # The host is an address: left to right, on the side the text does not start from.
  defp host(canvas, %{"host" => host}, rtl?) when is_binary(host) do
    host = text!(host, "Regular", 22, "#8f8ab8", 400)
    x = if rtl?, do: @margin, else: @width - @margin - width(host)
    compose(canvas, host, x, @height - @margin - div(@avatar, 2) - div(height(host), 2))
  end

  defp host(canvas, _card, _rtl?), do: canvas

  defp body(canvas, card, rtl?, text_width) do
    %{eyebrow: eyebrow, title: title, description: description, top: top, bottom: bottom} =
      texts(card, text_width)

    blocks = Enum.filter([{eyebrow, 18}, {title, 22}, {description, 0}], &elem(&1, 0))
    total = blocks |> Enum.map(fn {block, gap} -> height(block) + gap end) |> Enum.sum()
    start = top + max(div(bottom - top - total, 2), 0)

    {canvas, _y} =
      Enum.reduce(blocks, {canvas, start}, fn {block, gap}, {canvas, y} ->
        {compose(canvas, block, edge(rtl?, width(block)), y), y + height(block) + gap}
      end)

    canvas
  end

  # The eyebrow, the title and the description as the card shows them, with the room they share.
  defp texts(card, text_width) do
    top = 140
    bottom = @height - @margin - @avatar - 40

    eyebrow =
      card["eyebrow"] &&
        text!(String.upcase(card["eyebrow"]), "Bold", 21, "#b69cff", text_width)

    room = bottom - top - if(eyebrow, do: height(eyebrow) + 18, else: 0)

    {title, title_size, description, description_size, shown} =
      title_and_description(card, room, text_width)

    %{
      eyebrow: eyebrow,
      title: title,
      title_size: title_size,
      description: description,
      description_size: description_size,
      shown: shown,
      top: top,
      bottom: bottom
    }
  end

  # The largest title, and under it the largest description, that fit `room` together: the
  # description is set smaller before the title steps down. One that fits at no size is shortened
  # at the smallest of both.
  defp title_and_description(%{"description" => description} = card, room, text_width)
       when is_binary(description) do
    string = card["title"]
    capped = capped(description)

    Enum.find_value(@title_sizes, fn size ->
      title = text!(string, "Bold", size, "#ffffff", text_width)

      if height(title) <= tallest(string, "Bold", size, 3),
        do: described(title, size, capped, room, text_width)
    end) || shortened(card, room, text_width)
  end

  defp title_and_description(card, _room, text_width) do
    {title, size} = fit(card["title"], @title_sizes, "Bold", "#ffffff", text_width, 3)
    {title, size, nil, nil, nil}
  end

  # The title with the largest description that leaves room for it; `nil` when none does.
  defp described(title, size, description, room, text_width) do
    Enum.find_value(@description_sizes, fn small ->
      shown = text!(description, "Regular", small, "#b9b4dc", text_width)

      if height(title) + @title_gap + height(shown) <= room,
        do: {title, size, shown, small, description}
    end)
  end

  defp shortened(card, room, text_width) do
    small = List.last(@description_sizes)

    {title, size} =
      fit(card["title"], [List.last(@title_sizes)], "Bold", "#ffffff", text_width, 3)

    left = room - height(title) - @title_gap

    {description, shown} =
      card["description"]
      |> capped()
      |> Stream.iterate(&shorten/1)
      |> Stream.take_while(&is_binary/1)
      |> Stream.map(&{text!(&1, "Regular", small, "#b9b4dc", text_width), &1})
      |> Enum.find({nil, nil}, fn {img, _text} -> height(img) <= left end)

    {title, size, description, description && small, shown}
  end

  defp capped(text) do
    text
    |> Stream.iterate(&shorten/1)
    |> Enum.find(&(is_nil(&1) or String.length(&1) <= @description_cap))
    |> Kernel.||(text)
  end

  @doc """
  `text` one step shorter, for a text that has no room: without its last sentence while it has more
  than one, else without its last word, the rest ending in `…`. `nil` once one word is left.

      iex> MishkaCmsCore.Runtime.ShareCard.shorten("First one. Second one. Third one.")
      "First one. Second one."
      iex> MishkaCmsCore.Runtime.ShareCard.shorten("A single long sentence, with commas.")
      "A single long sentence, with…"
  """
  @spec shorten(String.t()) :: String.t() | nil
  def shorten(text) when is_binary(text) do
    case Regex.split(~r/(?<=[.!?؟。])\s+/u, String.trim(text)) do
      [_one_sentence] -> without_last_word(text)
      sentences -> sentences |> Enum.drop(-1) |> Enum.join(" ")
    end
  end

  defp without_last_word(text) do
    case text |> String.trim_trailing("…") |> String.split() do
      [_one_word] ->
        nil

      words ->
        kept = words |> Enum.drop(-1) |> Enum.join(" ")
        String.replace(kept, ~r/[\s,;:.،؛]+$/u, "") <> "…"
    end
  end

  # --- text --------------------------------------------------------------------------------------

  # The largest of `sizes` that fits `lines` lines, else the smallest, cut to fit: the picture and
  # the size it is set at.
  defp fit(string, sizes, weight, color, width, lines) do
    smallest = List.last(sizes)

    Enum.find_value(sizes, fn size ->
      img = text!(string, weight, size, color, width)
      if height(img) <= tallest(string, weight, size, lines), do: {img, size}
    end) || {clipped(string, weight, smallest, color, width, lines), smallest}
  end

  defp clipped(string, weight, size, color, width, lines) do
    img = text!(string, weight, size, color, width)
    limit = tallest(string, weight, size, lines)

    if height(img) <= limit do
      img
    else
      words = String.split(string)

      Enum.find_value((length(words) - 1)..1//-1, img, fn count ->
        img = text!(Enum.join(Enum.take(words, count), " ") <> "…", weight, size, color, width)
        if height(img) <= limit, do: img
      end)
    end
  end

  # How tall `lines` lines are, in the script `string` is written in — Arabic script stands taller.
  defp tallest(string, weight, size, lines) do
    sample = if rtl?(string), do: "سلام", else: "Ag"

    sample
    |> List.duplicate(max(lines, 1))
    |> Enum.join("\n")
    |> text!(weight, size, "#fff", 2000)
    |> height()
    |> Kernel.+(2)
  end

  defp text!(string, weight, size, color, width) do
    {:ok, {img, _flags}} =
      Op.text(~s(<span foreground="#{color}">#{escape(string)}</span>),
        font: "Plus Jakarta Sans, Vazirmatn #{weight} #{size}",
        width: width,
        rgba: true,
        wrap: :VIPS_TEXT_WRAP_WORD_CHAR
      )

    img
  end

  defp escape(string) do
    string
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp rtl?(string) when is_binary(string),
    do: Regex.match?(~r/^[^\p{L}]*[\p{Arabic}\p{Hebrew}]/u, string)

  defp rtl?(_no_text), do: false

  # --- pictures ----------------------------------------------------------------------------------

  defp picture(path, rtl?) do
    with true <- image?(path, false),
         {:ok, img} <- Image.thumbnail(path, "#{@width}x#{@height}", crop: :attention),
         {:ok, img} <- opaque(img) do
      # Solid behind the text, fading out over the far half of the other side.
      {slope, start} = if rtl?, do: {0.3, 408 - 0.3 * @width}, else: {-0.3, 408.0}
      alpha = @width |> ramp(@height, slope, start) |> scale(235 / 255)
      compose(img, layer(@background, alpha), 0, 0)
    else
      _unreadable -> nil
    end
  end

  # The logo on a white tile, and whether it is a wordmark that names the site itself; the site's
  # first letter when there is none.
  defp brand(path, site) do
    case image?(path, true) && logo(path) do
      %VImage{} = logo ->
        wide? = width(logo) > height(logo) * 1.6
        padding = 8
        tile_w = width(logo) + 2 * padding
        tile = layer([255, 255, 255], rounded_mask(tile_w, @logo, 14))
        {compose(tile, logo, padding, div(@logo - height(logo), 2)), wide?}

      _no_logo ->
        {initial(site, @logo, 14), false}
    end
  end

  defp logo(path) do
    inner = @logo - 16

    with {:ok, img} <- Image.thumbnail(path, "#{inner * 5}x#{inner}"),
         {:ok, img} <- with_alpha(img) do
      img
    else
      _unreadable -> nil
    end
  end

  defp avatar_stack(people) do
    ring = @avatar + 6
    step = @avatar - 14
    w = ring + step * (length(people) - 1)

    people
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.reduce(layer(@background, solid(w, ring, 0)), fn {person, i}, canvas ->
      x = i * step

      canvas
      |> compose(layer(@background, rounded_mask(ring, ring, ring / 2)), x, 0)
      |> compose(avatar(person), x + 3, 3)
    end)
    |> Op.extract_area!(0, 3, w, @avatar)
  end

  defp avatar(%{"name" => name} = person) do
    path = person["image"]

    with true <- image?(path, false),
         {:ok, img} <- Image.thumbnail(path, @avatar, crop: :attention),
         {:ok, img} <- opaque(img),
         {:ok, img} <- Op.bandjoin([img, rounded_mask(@avatar, @avatar, @avatar / 2)]) do
      img
    else
      _unreadable -> initial(name, @avatar, @avatar / 2)
    end
  end

  defp initial(name, size, radius) do
    letter =
      name |> to_string() |> String.trim() |> String.first() |> to_string() |> String.upcase()

    disc = layer([124, 77, 255], rounded_mask(size, size, radius))

    case letter do
      "" ->
        disc

      letter ->
        letter = text!(letter, "Bold", round(size * 0.42), "#ffffff", size)
        compose(disc, letter, div(size - width(letter), 2), div(size - height(letter), 2))
    end
  end

  # Only the formats a card reads: a photo is a JPEG, PNG, WebP or GIF, and a logo may be an SVG.
  defp image?(path, svg?) do
    case picture_type(path) do
      type when type in @photo_types -> true
      "image/svg+xml" -> svg?
      _other -> false
    end
  end

  @doc """
  The type of the picture file at `path`, read off its first bytes, never its name:
  `"image/jpeg"`, `"image/png"`, `"image/webp"`, `"image/gif"`, `"image/svg+xml"` or
  `"image/x-icon"`. `nil` for any other file, and for one that cannot be read.
  """
  @spec picture_type(term()) :: String.t() | nil
  # sobelow_skip ["Traversal.FileModule"]
  # Reads the first bytes of a path `site_file/2` already confined to the site's media or static folder.
  def picture_type(path) when is_binary(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 256)) do
      {:ok, <<0xFF, 0xD8, 0xFF, _::binary>>} -> "image/jpeg"
      {:ok, <<0x89, "PNG", _::binary>>} -> "image/png"
      {:ok, <<"RIFF", _::binary-size(4), "WEBP", _::binary>>} -> "image/webp"
      {:ok, <<"GIF8", _::binary>>} -> "image/gif"
      {:ok, <<0, 0, 1, 0, _::binary>>} -> "image/x-icon"
      {:ok, head} when is_binary(head) -> if svg?(head), do: "image/svg+xml"
      _unreadable -> nil
    end
  end

  def picture_type(_no_path), do: nil

  defp svg?(head), do: head |> String.trim_leading() |> String.starts_with?(["<svg", "<?xml"])

  defp opaque(img) do
    img = srgb(img)

    if Image.has_alpha?(img),
      do: Image.flatten(img, background_color: @background),
      else: {:ok, img}
  end

  defp with_alpha(img) do
    img = srgb(img)
    if Image.has_alpha?(img), do: {:ok, img}, else: Image.add_alpha(img, 255)
  end

  defp srgb(img) do
    if VImage.bands(img) in [1, 2],
      do: Op.colourspace!(img, :VIPS_INTERPRETATION_sRGB),
      else: img
  end

  # --- drawing, with libvips arithmetic: SVG is not loaded for anything a card draws itself ------

  defp backdrop do
    Image.new!(@width, @height, color: @background)
    |> compose(glow({1060, 40}, 720, [124, 77, 255], 0.55), 0, 0)
    |> compose(glow({0, 630}, 640, [47, 107, 255], 0.28), 0, 0)
  end

  defp glow({cx, cy}, radius, color, strength) do
    {x, y} = axes(@width, @height)
    dx = Op.linear!(x, [1.0], [-cx * 1.0])
    dy = Op.linear!(y, [1.0], [-cy * 1.0])

    distance =
      Op.math2_const!(
        Op.add!(Op.multiply!(dx, dx), Op.multiply!(dy, dy)),
        :VIPS_OPERATION_MATH2_POW,
        [0.5]
      )

    # 1 - distance / radius, clipped to 0..1, then squared for a soft edge.
    near =
      distance |> Op.linear!([-255 / radius], [255.0]) |> uchar() |> Op.linear!([1 / 255], [0.0])

    alpha = Op.multiply!(near, near) |> Op.linear!([255 * strength], [0.0]) |> uchar()
    layer(color, alpha)
  end

  defp grid do
    {x, y} = axes(@width, @height)

    on_x =
      Op.relational_const!(Op.remainder_const!(x, [48.0]), :VIPS_OPERATION_RELATIONAL_EQUAL, [0.0])

    on_y =
      Op.relational_const!(Op.remainder_const!(y, [48.0]), :VIPS_OPERATION_RELATIONAL_EQUAL, [0.0])

    lines = Op.boolean!(on_x, on_y, :VIPS_OPERATION_BOOLEAN_OR)
    layer([255, 255, 255], lines |> Op.linear!([9 / 255], [0.0]) |> uchar())
  end

  defp accent_line do
    {x, _y} = axes(@width, 6)
    gradient(Op.linear!(x, [1 / (@width - 1)], [0.0]), [139, 92, 246], [34, 211, 238])
  end

  defp gradient(t, from, to) do
    t
    |> Op.linear!(Enum.zip_with(to, from, &((&1 - &2) * 1.0)), Enum.map(from, &(&1 * 1.0)))
    |> uchar()
    |> Op.copy!(interpretation: :VIPS_INTERPRETATION_sRGB)
  end

  defp ramp(w, h, slope, start) do
    {x, _y} = axes(w, h)
    x |> Op.linear!([slope], [start]) |> uchar()
  end

  defp scale(alpha, factor), do: alpha |> Op.linear!([factor], [0.0]) |> uchar()

  # 255 inside a `w`×`h` rectangle with corners of `radius`, antialiased at the edge.
  defp rounded_mask(w, h, radius) do
    {x, y} = axes(w, h)
    dx = outside(x, (w - 1) / 2, w / 2 - radius)
    dy = outside(y, (h - 1) / 2, h / 2 - radius)

    distance =
      Op.math2_const!(
        Op.add!(Op.multiply!(dx, dx), Op.multiply!(dy, dy)),
        :VIPS_OPERATION_MATH2_POW,
        [0.5]
      )

    distance |> Op.linear!([-255.0], [255.0 * (radius + 0.5)]) |> uchar()
  end

  # How far past the straight part of an edge a coordinate is; 0 along it.
  defp outside(v, centre, half) do
    past = v |> Op.linear!([1.0], [-centre]) |> Op.abs!() |> Op.linear!([1.0], [-half])

    positive =
      past
      |> Op.relational_const!(:VIPS_OPERATION_RELATIONAL_MORE, [0.0])
      |> Op.linear!([1 / 255], [0.0])

    Op.multiply!(past, positive)
  end

  defp axes(w, h) do
    xyz = Op.xyz!(w, h)
    {Op.extract_band!(xyz, 0), Op.extract_band!(xyz, 1)}
  end

  defp uchar(img), do: Op.cast!(img, :VIPS_FORMAT_UCHAR)

  defp solid(w, h, value), do: Image.new!(w, h, color: [value], bands: 1)

  defp layer(color, alpha) do
    rgb = Image.new!(width(alpha), height(alpha), color: color)
    Op.bandjoin!([rgb, alpha])
  end

  defp compose(base, overlay, x, y),
    do: Op.composite2!(base, overlay, :VIPS_BLEND_MODE_OVER, x: round(x), y: round(y))

  defp compose_if(canvas, nil, _fun), do: canvas
  defp compose_if(canvas, _part, fun), do: fun.(canvas)

  defp edge(false, _w), do: @margin
  defp edge(true, w), do: @width - @margin - w

  defp width(img), do: VImage.width(img)
  defp height(img), do: VImage.height(img)
end
