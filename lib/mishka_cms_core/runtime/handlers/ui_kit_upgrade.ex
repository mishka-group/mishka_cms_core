# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Handlers.UiKitUpgrade do
  @moduledoc """
  What a site's kit components are against the bundle on disk now, and the one write that brings
  them forward without taking an admin's edits with it.

  ## The gap this closes

  `MishkaCmsCore.Runtime.Handlers.UiKitHandler.install_kit!/2` upserts by name, so it has exactly two
  settings: install every component the bundle ships — over the top of whatever an admin edited in
  the builder — or install only the ones a site has no row for at all, which is what every
  provisioner does and what leaves a site on the components it was seeded with for ever. A site set
  up in September kept September's `blog-post-list` while the bundle grew a `language` filter, and
  nothing anywhere compared the two.

  Nothing could compare them, because a row said only which kit had written it. It now says which
  VERSION of that kit wrote it and carries a fingerprint of what was written, both stamped by the
  installer into `extra` — see `stamp/3` — so three questions can be answered per row without
  guessing: is this even a row this kit wrote, has the bundle moved since it was written, and has
  anybody here changed it since.

  The second question is not the version string's to answer alone. A kit is edited far more often
  than it is renumbered, so the row's fingerprint is weighed against the BUNDLE's as well as against
  the one its own stamp carries: the first says whether the bundle has moved, the second whether
  anybody here has.

  ## The three answers, and the fourth

  `plan/2` sorts every component the bundle ships into:

    * `:current` — the bundle has nothing this row does not already hold, or the only thing it does
      not hold is the admin's own work;
    * `:outdated` — the bundle's copy has moved on, by its version or by its content, and the row is
      still byte-for-byte what the kit installed, so an update takes nothing away. This is the group
      the safe button writes;
    * `:edited` / `:unknown` — the "needs a choice" pile. Either the row no longer matches the
      fingerprint it was installed with, or it carries no fingerprint to compare (a row installed
      before any of this, or by another kit). Both are offered together and both are only written
      when the admin asks for them by name, because the second is the same risk as the first: the
      code cannot tell an edit from the original, so it says so rather than picking for them;
    * `:archived` and `:absent`, which are never written by an upgrade at all. An archived row is an
      answer the admin gave, and a component the site has no row for is what the extension's
      "Set up …" button is for — an upgrade that installed those would hand a site components it
      deliberately does not have.

  Updating a row in the third pile is not destructive either: `master_update` is what the installer
  writes through, so AshPaperTrail keeps what the row held in `component_versions` and the admin can
  restore it from the component's history. `message/1` says so in the same sentence that reports it.

  ## Every kit is stamped; not every kit has a button

  `stamp/3` runs inside the installer, so Chelekom's rows carry the same three keys as an
  extension's and `plan/2` reads them with no special case. What Chelekom does not have here is a
  button, and the reason is `install_kit!/2`'s `:selection`: its wizard installs a NARROWED kit —
  chosen components, chosen variants and colours — and this module writes the bundle's component
  whole. For an extension bundle those are the same thing, since nothing narrows them; for a site
  that installed Chelekom's `base` variant only, an update would quietly hand it every variant.
  Wiring Chelekom up means recording the selection a site was installed with and replaying it, which
  is a question no bundle answers today.

  ## Pressing it twice

  The write goes through `install_kit!/2` with a selection naming only the rows that were chosen, so
  a second press finds them all holding exactly what the bundle ships and writes nothing — it does
  not even reach the installer, which would otherwise rebuild the site's runtime to discover there
  was nothing to do.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler

  require Ash.Query

  # The page size of the reads below, not how much of them is read: `every_page/1` reads all of it.
  # Chelekom alone ships 136 components.
  @row_limit 100

  # EXACTLY WHAT AN UPGRADE WILL WRITE, which is the only set a fingerprint may cover. The question
  # it answers is "does this row still hold what the kit put there", and the answer is only worth
  # the button that reads it if it is asked about every field the write replaces.
  #
  # A narrower fingerprint — the markup and the code, on the grounds that rewording a description is
  # not forking a component — made the safe group lie. `install_kit!/2` sends every field
  # `master_update` accepts, both real bundles ship all of them, so a row whose `active` an admin had
  # turned off was reported "outdated, untouched" and the button that promises to take nothing away
  # switched it back on and compiled it into the site's runtime.
  #
  # `site_id` is the row's scope rather than its content and cannot differ between the two sides.
  # `extra` is here, projected without the stamp's own three keys — the one thing a fingerprint
  # cannot cover without covering itself.
  @written_keys [
    :name,
    :description,
    :template,
    :body,
    :format,
    :priority,
    :attrs,
    :slots,
    :helpers,
    :active,
    :precompile,
    :required,
    :stateful,
    :permissions,
    :examples,
    :type,
    :dependencies,
    :extra
  ]

  # WHAT THE ROW WILL HOLD WHERE THE BUNDLE SAYS NOTHING. One side of the comparison is a file free
  # to leave a field out and the other is a row the resource's default has already landed on, so
  # absent has to project as that default — otherwise every row of such a bundle reads as edited and
  # the safe group is empty for ever. The values below are `Component`'s own defaults; the strings
  # and the lists need no entry because `text/1` and `list/1` already answer "" and `[]`.
  @absent %{
    format: "heex",
    priority: 0,
    active: true,
    precompile: false,
    required: false,
    stateful: false
  }

  # `signature` is deliberately not among them. `Changes.SignCode` mints one on the way in wherever a
  # signing key is configured and `mix mishka.resign_code` re-mints every one of them, so a
  # fingerprint covering it would call a whole site's components edited the day a key is rotated.
  @helper_keys [:name, :args, :code, :attrs, :slots, :discriminators]

  @kit_key "ui_kit"
  @version_key "ui_kit_version"
  @digest_key "ui_kit_digest"

  @typedoc """
  Where one component of the bundle stands on this site.

  `:unknown` is the honest answer rather than a fourth guess: the row is installed and nothing
  readable on it says what it was installed from, so it is offered with the edited ones.
  """
  @type standing :: :current | :outdated | :edited | :unknown | :archived | :absent

  @typedoc "One component, its standing, and what the row says it was installed from."
  @type entry :: %{
          name: String.t(),
          standing: standing(),
          version: String.t() | nil,
          kit: String.t() | nil,
          reason: atom() | nil
        }

  @type plan :: %{
          kit: String.t(),
          version: String.t(),
          site_id: String.t() | nil,
          current: [entry()],
          outdated: [entry()],
          choice: [entry()],
          archived: [entry()],
          absent: [entry()]
        }

  @type report :: %{
          kit: String.t(),
          version: String.t(),
          updated: [String.t()],
          added: [String.t()],
          edited: [String.t()],
          left: [String.t()],
          archived: [String.t()],
          absent: [String.t()],
          current: [String.t()]
        }

  @doc """
  Records on a component's params which kit wrote it, from which version, and what was written.

  Called by the installer for every component of every bundle — there is no per-kit opt-in, because
  a stamp only one kit writes is a stamp an upgrade can only read for that kit.

  The fingerprint is taken from the params the install is ABOUT to write, which is what makes it
  comparable afterwards: `digest/1` reads the same fields off the stored row.
  """
  @spec stamp(map(), String.t(), String.t() | nil) :: map()
  def stamp(params, kit_name, kit_version) when is_binary(kit_name) do
    extra =
      case Map.get(params, "extra") do
        extra when is_map(extra) -> extra
        _absent -> %{}
      end

    Map.put(
      params,
      "extra",
      extra
      |> Map.put(@kit_key, kit_name)
      |> Map.put(@version_key, kit_version)
      |> Map.put(@digest_key, digest(params))
    )
  end

  def stamp(params, _kit_name, _kit_version), do: params

  @doc """
  The fingerprint of what a component is made of, taken from a bundle entry or from a stored row.

  Both shapes go through the same projection — the bundle's string keys and the row's atoms and
  embedded structs land on the same canonical term — so a digest taken at install still matches the
  row it was taken from, and stops matching the moment somebody edits it.
  """
  @spec digest(map() | struct()) :: String.t()
  def digest(source) do
    @written_keys
    |> Enum.map(&[Atom.to_string(&1), content(source, &1)])
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Where every component of the bundle at `bundle_path` stands on `site_id` (`nil` for global rows).

  Reads nothing but the rows the bundle names, and writes nothing at all: this is what a dashboard
  shows an admin BEFORE anything happens.

  `{:error, :kit_has_no_version}` when the bundle does not say which version it is. Without one
  nothing can be called outdated, and reporting every row as current would be a worse answer than
  saying the kit cannot be compared.
  """
  @spec plan(String.t(), String.t() | nil, map() | nil) :: {:ok, plan()} | {:error, term()}
  def plan(bundle_path, site_id, actor \\ nil) when is_binary(bundle_path) do
    with {:ok, bundle} <- UiKitHandler.read_bundle(bundle_path),
         {:ok, version} <- bundle_version(bundle) do
      components = bundle["components"] || []
      names = Enum.map(components, & &1["name"])

      {archived_action, archived_opts} = archived_read(actor)

      active = Map.new(rows(:read_any, reading(actor), names, site_id, actor), &{&1.name, &1})

      archived =
        MapSet.new(rows(archived_action, archived_opts, names, site_id, actor), & &1.name)

      entries = Enum.map(components, &entry(&1, active, archived, bundle["name"], version))

      {:ok,
       %{
         kit: bundle["name"],
         version: version,
         site_id: site_id,
         current: standing(entries, [:current]),
         outdated: standing(entries, [:outdated]),
         choice: standing(entries, [:edited, :unknown]),
         archived: standing(entries, [:archived]),
         absent: standing(entries, [:absent])
       }}
    end
  end

  @doc """
  Writes the newer components onto a site and says what it did.

  `:include` picks which pile is written — `:safe` (the default) takes only the outdated rows
  nobody has touched, `:all` takes those and the ones that need a choice. No other COMPONENT is
  written: an archived row is skipped by the installer as well, and a component the site has no row
  for is not offered here at any setting.

  The selection reaches the installer's component list and nothing else, so a bundle's `js_hooks`
  and `stylesheets` are still upserted whole — and a hook the bundle's `extra.replaces` names is
  still deleted. Neither extension bundle ships either today; a kit that does would have an admin's
  edit to a hook replaced here without it appearing in the report, because nothing stamps a hook.

  Idempotent by construction. The plan is read again inside this call rather than taken from the
  caller, so a row that was updated a moment ago by somebody else is already current and is not
  written twice — and with nothing left to write the installer is not called at all.

  ## The pieces an updated component is made of come with it

  The one exception to "an absent component is never installed here", and it is not a softening of
  that rule but what the rule is for. A kit may SPLIT a component: the blog's post list stopped
  drawing its own cards and started drawing `blog-post-card`, a component of the same bundle. A site
  that took the update and not the card would be given a list whose every row is the runtime's red
  "failed to render" box — the update would break the page it was meant to improve.

  So a component this call writes brings the components its own row DECLARES it needs, and theirs in
  turn, wherever the site has no row for them at all. They are reported separately, as `added`,
  because they are not updates of anything the admin had. A piece the admin ARCHIVED is still left
  where it is: that is an answer they gave about a component they have.

  A component the site simply does not use and nothing it does use needs is still not installed.
  That is what the extension's "Set up …" button is for.

  Pass `actor: user` and every component written is written as them, through the action their own
  role may use. Leave it out and the write is the system's, as it is for the wizard.
  """

  @spec upgrade!(String.t(), String.t() | nil, keyword()) :: {:ok, report()} | {:error, term()}
  def upgrade!(bundle_path, site_id, opts \\ []) when is_binary(bundle_path) do
    include = Keyword.get(opts, :include, :safe)
    # WHO PRESSED UPDATE. Every row this writes is written as them — see `UiKitHandler`'s own
    # `writing/3` — and absent only for a caller with no session behind it.
    actor = Keyword.get(opts, :actor)

    with {:ok, bundle} <- UiKitHandler.read_bundle(bundle_path),
         {:ok, plan} <- plan(bundle_path, site_id, actor) do
      {taken, left} = split(plan, include)

      case Enum.map(taken, & &1.name) do
        [] ->
          {:ok, report(plan, taken, left, [])}

        names ->
          added = missing_pieces(bundle, plan, names)

          with {:ok, _installed} <-
                 UiKitHandler.install_kit!(bundle_path,
                   site_id: site_id,
                   selection: %{components: names ++ added},
                   actor: actor
                 ) do
            {:ok, report(plan, taken, left, added)}
          end
      end
    end
  end

  @doc """
  The line a dashboard shows beside one component, saying what its standing is FROM.

  A standing on its own reads as a verdict the admin has to take on trust; the version a row was
  installed from, and the fact that an old row cannot be told from an edited one, are what let them
  decide.
  """
  @spec note(entry()) :: String.t()
  def note(%{standing: :current, version: version}),
    do: gettext("version %{version}", version: version)

  def note(%{standing: :outdated, reason: :changed_in_place, version: version}),
    do:
      gettext("installed from %{version}, untouched — the kit's own copy has changed since",
        version: version
      )

  def note(%{standing: :outdated, version: version}),
    do: gettext("installed from %{version}, untouched", version: version)

  def note(%{standing: :edited, version: version}),
    do: gettext("edited here since %{version} installed it", version: version)

  def note(%{reason: :other_kit, kit: kit}),
    do:
      gettext("installed by the %{kit} kit, so this one cannot say what it should hold",
        kit: kit
      )

  def note(%{reason: :no_digest, version: version}),
    do:
      gettext(
        "installed from %{version} with no fingerprint, so an edit cannot be told from the original",
        version: version
      )

  def note(%{reason: :no_version}),
    do:
      gettext(
        "installed before versions were recorded, so an edit cannot be told from the original"
      )

  def note(%{standing: :archived}), do: gettext("archived here, left where it is")
  def note(%{standing: :absent}), do: gettext("not installed on this site")

  @doc """
  What one upgrade did, worded from what was actually written.

  The sentence about history is not decoration: updating a row an admin edited is only safe because
  the row they had is kept as a version, and an admin who is not told that has no way to know they
  can get it back.
  """
  @spec message(report()) :: String.t()
  # NOTHING LIVE TO SPEAK FOR. Every component the bundle ships is either archived here or was never
  # installed, and both of those are answers an upgrade has to leave alone — so it says what is true
  # rather than "everything is up to date", which on a site holding none of them reads as a bug.
  def message(%{updated: [], current: [], left: []}),
    do: gettext("This site has none of this kit's components in use.")

  def message(%{updated: []} = report) do
    case report.left do
      [] ->
        gettext("Every component this kit ships is up to date.")

      left ->
        ngettext(
          "Nothing updated. 1 component waiting on a choice.",
          "Nothing updated. %{count} components waiting on a choice.",
          length(left)
        )
    end
  end

  def message(report) do
    [
      ngettext(
        "Updated 1 component to %{version}.",
        "Updated %{count} components to %{version}.",
        length(report.updated),
        version: report.version
      ),
      brought(report.added),
      kept(report.edited),
      still_waiting(report.left)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  # ---------------------------------------------------------------------------
  # The plan
  # ---------------------------------------------------------------------------

  defp entry(component, active, archived, kit, version) do
    name = component["name"]

    case Map.fetch(active, name) do
      {:ok, row} ->
        installed(name, row, component, kit, version)

      :error ->
        %{
          name: name,
          standing: absent_or_archived(name, archived),
          version: nil,
          kit: nil,
          reason: nil
        }
    end
  end

  # AN ARCHIVED ROW IS PRESENT, not missing. The installer skips one rather than reviving it, so
  # reporting it as absent would offer the admin a component they would then not get.
  defp absent_or_archived(name, archived),
    do: (MapSet.member?(archived, name) && :archived) || :absent

  defp installed(name, row, component, kit, version) do
    stamp = read_stamp(row)
    {standing, reason} = judge(row, stamp, component, kit, version)

    %{name: name, standing: standing, version: stamp.version, kit: stamp.kit, reason: reason}
  end

  # EVERY ANSWER BUT "CURRENT" AND "OUTDATED" IS A REFUSAL TO GUESS. A row this kit did not stamp, or
  # stamped before there was a version to stamp, or stamped without a fingerprint, are three
  # different ways of not knowing whether the admin's work is in it — and all three are handled the
  # same way, by asking.
  defp judge(row, stamp, component, kit, version) do
    cond do
      is_nil(stamp.kit) -> {:unknown, :no_version}
      stamp.kit != kit -> {:unknown, :other_kit}
      is_nil(stamp.version) -> {:unknown, :no_version}
      is_nil(stamp.digest) -> without_fingerprint(stamp, version)
      true -> compare(row, stamp, component, version)
    end
  end

  # A VERSION STRING IS ALL THERE IS TO GO ON. At the bundle's own version there is nothing to offer;
  # behind it, nobody can say whether the row still holds what the kit wrote, so it joins the pile
  # that asks.
  defp without_fingerprint(stamp, version),
    do: (older?(stamp.version, version) && {:unknown, :no_digest}) || {:current, nil}

  # THE BUNDLE IS THE THIRD THING TO COMPARE AGAINST, not just the row's own stamp. A kit is edited
  # far more often than it is renumbered — `mishka_blog.json` was rewritten under an unchanged
  # `2.0.0` the day before this was written — and a version check on its own reported every such row
  # as current, which is the failure this whole module exists to close, one commit later.
  #
  # So the two fingerprints say between them what the version string cannot: whether the bundle has
  # moved since this row was installed, and whether anybody here has touched it since.
  defp compare(row, stamp, component, version) do
    mine = digest(row)
    theirs = digest(component)

    cond do
      # Nothing to give it, and its stamp already says so.
      mine == theirs and not older?(stamp.version, version) -> {:current, nil}
      # Untouched since the install, so whatever the bundle has now is a gift, not a loss.
      mine == stamp.digest -> {:outdated, drift(stamp, version)}
      # Touched, but the bundle's copy is still the one it was installed from: the only difference
      # here is the admin's own work, and an upgrade has no business offering to take it.
      stamp.digest == theirs -> {:current, nil}
      true -> {:edited, nil}
    end
  end

  # A ROW BEHIND A VERSION IT CAN NAME EXPLAINS ITSELF; one behind a bundle stamped the same as it is
  # does not, and "untouched" with nothing said about why it is listed reads as the card failing.
  defp drift(stamp, version) do
    if older?(stamp.version, version), do: nil, else: :changed_in_place
  end

  # SEMANTIC WHERE BOTH SIDES ARE SEMANTIC, and a plain inequality where they are not. A kit is free
  # to version itself `2026-09-19`, and calling that older than `2026-09-18` by string comparison
  # would be luck; what is NOT luck is that a row installed from a different string is a row the
  # bundle has moved on from, which is all "offer the update" needs.
  defp older?(installed, bundle) do
    case {Version.parse(installed), Version.parse(bundle)} do
      {{:ok, mine}, {:ok, theirs}} -> Version.compare(mine, theirs) == :lt
      _unparseable -> installed != bundle
    end
  end

  defp read_stamp(%{extra: extra}) when is_map(extra) do
    %{
      kit: string(extra[@kit_key]),
      version: string(extra[@version_key]),
      digest: string(extra[@digest_key])
    }
  end

  defp read_stamp(_no_extra), do: %{kit: nil, version: nil, digest: nil}

  defp string(value) when is_binary(value), do: value
  defp string(_not_a_string), do: nil

  defp standing(entries, wanted), do: Enum.filter(entries, &(&1.standing in wanted))

  defp bundle_version(%{"version" => version}) when is_binary(version) and version != "",
    do: {:ok, version}

  defp bundle_version(_no_version), do: {:error, :kit_has_no_version}

  # ---------------------------------------------------------------------------
  # The write
  # ---------------------------------------------------------------------------

  defp split(plan, :all), do: {plan.outdated ++ plan.choice, []}
  defp split(plan, _safe), do: {plan.outdated, plan.choice}

  defp report(plan, taken, left, added) do
    %{
      kit: plan.kit,
      version: plan.version,
      updated: Enum.map(taken, & &1.name),
      added: added,
      edited: for(entry <- taken, entry.standing != :outdated, do: entry.name),
      left: Enum.map(left, & &1.name),
      archived: Enum.map(plan.archived, & &1.name),
      absent: Enum.map(plan.absent, & &1.name) -- added,
      current: Enum.map(plan.current, & &1.name)
    }
  end

  # WHAT THE ROWS BEING WRITTEN ARE MADE OF, followed through the bundle rather than through the
  # site: a dependency of a dependency arrives too, and only where the site has no row for it. A
  # name the site holds — current, outdated, edited or archived — is not here, so nothing this
  # returns can overwrite anything.
  defp missing_pieces(bundle, plan, names) do
    absent = MapSet.new(plan.absent, & &1.name)
    by_name = Map.new(bundle["components"] || [], &{&1["name"], &1})

    names
    |> Enum.reduce(MapSet.new(), &pieces_of(&1, by_name, absent, &2))
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp pieces_of(name, by_name, absent, found) do
    by_name
    |> Map.get(name, %{})
    |> Map.get("dependencies", [])
    |> List.wrap()
    |> Enum.filter(&(MapSet.member?(absent, &1) and not MapSet.member?(found, &1)))
    |> Enum.reduce(found, fn piece, gathered ->
      pieces_of(piece, by_name, absent, MapSet.put(gathered, piece))
    end)
  end

  # SAID SEPARATELY FROM THE UPDATES, because these are components the site did not have: an admin
  # reading "updated 4" and finding 9 new rows in their component list has been told the wrong thing.
  defp brought([]), do: ""

  defp brought(names),
    do:
      ngettext(
        "1 component they are drawn with was installed too.",
        "%{count} components they are drawn with were installed too.",
        length(names)
      )

  defp kept([]), do: ""

  defp kept(names),
    do:
      ngettext(
        "1 component needed a choice; what each held is kept in its history.",
        "%{count} components needed a choice; what each held is kept in its history.",
        length(names)
      )

  defp still_waiting([]), do: ""

  defp still_waiting(names),
    do:
      ngettext(
        "1 component left for you to decide on.",
        "%{count} components left for you to decide on.",
        length(names)
      )

  # ---------------------------------------------------------------------------
  # The fingerprint
  # ---------------------------------------------------------------------------

  defp content(source, :helpers), do: Enum.map(list(field(source, :helpers)), &helper/1)

  # THE STAMP ITSELF IS NOT PART OF WHAT IT FINGERPRINTS. Everything else an install put in `extra`
  # is: the installer writes the map whole, so a key an admin added there is a key an upgrade
  # replaces.
  defp content(source, :extra),
    do: source |> field(:extra) |> map() |> Map.drop(stamp_keys()) |> canonical()

  defp content(source, key) when key in [:name, :description, :template, :body, :type],
    do: text(field(source, key))

  defp content(source, key) when key in [:attrs, :slots, :permissions, :examples, :dependencies],
    do: canonical(list(field(source, key)))

  defp content(source, key), do: scalar(field(source, key), Map.fetch!(@absent, key))

  defp helper(helper) do
    Enum.map(@helper_keys, fn
      key when key in [:name, :args, :code] -> text(field(helper, key))
      key -> canonical(list(field(helper, key)))
    end)
  end

  # BOTH SPELLINGS, for the reason the digest exists at all: one side of the comparison is a bundle
  # that has been through JSON and the other is a row that has been through Ash's casting.
  defp field(source, key) when is_map(source),
    do: Map.get(source, key) || Map.get(source, Atom.to_string(key))

  # TRIMMED, BECAUSE THAT IS WHAT IS STORED. `Ash.Type.String` trims on cast, and the `template`
  # attribute asks for it explicitly — so a bundle whose helpers end in the newline an exporter
  # wrote is stored without it, and a fingerprint taken from the file would disagree with every row
  # it had just written. Every component of a real kit is in that state.
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_absent), do: ""

  defp list(value) when is_list(value), do: value
  defp list(_absent), do: []

  defp map(value) when is_map(value), do: value
  defp map(_absent), do: %{}

  defp scalar(nil, fallback), do: fallback
  defp scalar(value, _fallback), do: canonical(value)

  defp stamp_keys, do: [@kit_key, @version_key, @digest_key]

  # A MAP BECOMES A SORTED LIST OF PAIRS. Nothing guarantees the key order of a map that came back
  # from jsonb, and two orders of the same declaration are the same declaration.
  defp canonical(%_struct{} = value) do
    value
    |> Map.from_struct()
    |> Map.drop([:__meta__, :__metadata__, :__order__, :aggregates, :calculations])
    |> canonical()
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, inner} -> [to_string(key), canonical(inner)] end)
    |> Enum.sort_by(&hd/1)
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)

  defp canonical(value) when is_atom(value) and value not in [nil, true, false],
    do: to_string(value)

  defp canonical(value), do: value

  # ---------------------------------------------------------------------------
  # Reading
  # ---------------------------------------------------------------------------

  defp rows(action, opts, names, site_id, actor) do
    Component
    |> Ash.Query.for_read(action, %{}, opts)
    |> Ash.Query.filter(name in ^names)
    |> scope(site_id)
    |> Ash.read!(reading(actor) ++ [page: [limit: @row_limit]])
    |> every_page()
  end

  # SEE `MishkaCmsCore.Runtime.PageProvision`'s `reading/1`: the read action does not change with
  # the actor, because `scope/2` above already names the site.
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

  # A nil site_id must compare as IS NULL, not `= NULL` (always false), or a globally installed kit
  # is read as though the site had none of it.
  defp scope(query, nil), do: Ash.Query.filter(query, is_nil(site_id))
  defp scope(query, site_id), do: Ash.Query.filter(query, site_id == ^site_id)

  # A PAGE THAT CARRIED SOMETHING is what earns the next one: a keyset page with no results answers
  # itself, so a page claiming `more?` over nothing would be asked for its successor for ever.
  defp every_page(%{results: [_first | _rest] = found, more?: true} = page),
    do: found ++ every_page(Ash.page!(page, :next))

  defp every_page(%{results: found}), do: found
  defp every_page(found) when is_list(found), do: found
end
