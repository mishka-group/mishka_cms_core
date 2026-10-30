# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.AdminCss do
  @moduledoc """
  Builds the two BUILD-TIME stylesheets, into the host app's `priv/static`.

  One command, no prerequisites for whoever installs this CMS:

    * compiles `admin.css` — every Tailwind utility the dashboard, the page builder and the login
      page use, scanned out of the host app and every extension;
    * compiles `public.css` — the same for the host's own marketing pages, from the host's web tree
      alone;
    * installs the vendored Tailwind browser build, which the page builder's canvas loads;
    * installs the admin's web fonts.

  Both sheets exist because their classes live in `.ex` files and cannot change without a deploy.
  The third audience — a SITE — has classes in database rows that change without one, which is why
  `MishkaCmsCore.Runtime.Compilers.TailwindCompiler` builds those at runtime. Three audiences, three
  sheets, no overlap; they used to be a single 2.4 MB file that every one of them downloaded.

  All three ship inside this library's `priv/admin_assets/`, so a host gets them by depending on it.
  Nothing is fetched at build time and nothing is expected to be there already.

  ## `source(none)` is load-bearing

  Without it Tailwind v4 auto-detects sources from the CSS file's own tree in ADDITION to the
  `@source` lines below, and walks into `priv/cms_ui_kits/chelekom.json` — an 11.7 MB kit bundle whose
  every component template is a string inside JSON. Tailwind cannot tell that from markup, so it
  compiled a rule for every class of all 244 components plus 1,288 heroicons: 2,511,005 bytes and an
  11-second build, for classes the admin chrome never renders. Those components appear only inside
  the editor's canvas, which loads Tailwind Live and generates them on demand.

  With `source(none)`, only the explicit `@source` lines below are scanned. 589,694 bytes, 836 ms.

  ## Why a task and not a `config :tailwind` profile

  Because the `@source` globs have to be GENERATED. Tailwind v4 skips gitignored entries while
  WALKING a directory, and a CMS install routinely gitignores vendored path dependencies and always
  gitignores `deps/` — so `@source "__extensions/**"` silently matches nothing for them. Absolute
  paths do not help: the filter applies to the walk, not to the form of the path. Naming each
  directory outright is what bypasses it, and that list can only be built by listing the disk.

  That is not a hypothetical. Compiling this without the per-directory globs produced a dashboard
  whose tables had lost their responsive layout, because one Gervaz line
  (`max-[980px]:overflow-visible!` and friends) lived in a gitignored extension.

  ## Why the admin is compiled at all, when a site is not

  A site's classes live in database rows that change without a deploy, which is why
  `MishkaCmsCore.Runtime.Compilers.TailwindCompiler` builds site CSS at runtime. The admin's classes
  live in templates and are fixed when the release is built, so compiling them per request bought
  nothing — it cost a 275 KB browser JIT and an in-browser compile on every admin page.

  The page builder still loads that JIT, and always will: a class typed into the inspector, or a kit
  component whose classes no build ever scanned, has to exist a frame later.

  ## Why neither sheet may go into the host's `app.css`

  `TailwindCompiler.build_css_content_static_base/0` inlines that file wholesale into the base every
  site's CSS is built on. Compiling the dashboard into it would ship the entire admin inside every
  public page's stylesheet — which is the bug this whole split exists to undo.

  ## Usage

      mix admin_css              # once, as part of assets.build / assets.deploy

  In development the endpoint watches each audience in its own process — see `watch/1`. `--watch` is
  refused here, because Tailwind's watch never returns and only the first of the two sheets would
  ever be built.
  """

  use Mix.Task

  @shortdoc "Builds the admin chrome's CSS, fonts and Tailwind JIT into priv/static"

  @css "priv/static/assets/css/admin.css"

  # The host's PUBLIC marketing pages — `HomeLive`, the blog, the docs. Their classes live in `.ex`
  # files and change only on deploy, so they are compiled once here rather than carried inside every
  # site's runtime bundle. That is where they used to live: the compile-time static base was prepended
  # to every site's CSS, so a visitor to a database page downloaded 268 KB of marketing styling it
  # could never use, and a content edit invalidated the marketing cache.
  @public "priv/static/assets/css/public.css"
  @vendor "priv/static/assets/js/vendor"
  @fonts "priv/static/fonts"

  # A STABLE path, not a temp file: `--watch` has to keep reading the same input, and anyone
  # debugging the build wants to see what was actually handed to Tailwind.
  @input "_build/admin_chrome.css"
  @public_input "_build/public_pages.css"

  @impl Mix.Task
  def run(args) do
    root = File.cwd!()

    args |> Enum.member?("--watch") |> refuse_watch()
    install_assets(root)

    Enum.each([:admin, :public], &build(&1, root, args))
  end

  defp refuse_watch(false), do: :ok

  defp refuse_watch(true) do
    Mix.raise("""
    `mix admin_css --watch` would build only the first of two stylesheets. Tailwind's watch never
    returns, so `public.css` would never be reached. Watch each audience in its own process:

        admin_css: {Mix.Tasks.AdminCss, :watch, [[only: :admin]]},
        public_css: {Mix.Tasks.AdminCss, :watch, [[only: :public]]}
    """)
  end

  @doc """
  Rebuilds ONE audience on every change, for the endpoint's `:watchers` list.

  The admin used to be styled by the browser JIT, which generated a class the moment it appeared in
  the DOM — so an edit to an admin template needed no build step at all. Serving compiled CSS means
  something has to notice that edit, and without this a developer adds a class, sees nothing happen,
  and has no reason to suspect the stylesheet.

  ## One audience per watcher, and why it cannot be both

  Tailwind's `--watch` does not return. A single call that built the admin sheet and then the public
  one therefore never reached the second: `admin.css` rebuilt on every keystroke while `public.css`
  sat untouched for days, so an edit to a marketing page produced no rule and the class silently did
  nothing — the exact failure described above, fixed for the admin and left live for the public half.

  Each audience gets its own entry, which Phoenix runs in its own process:

      watchers: [
        admin_css: {Mix.Tasks.AdminCss, :watch, [[only: :admin]]},
        public_css: {Mix.Tasks.AdminCss, :watch, [[only: :public]]}
      ]
  """
  @spec watch(keyword()) :: non_neg_integer()
  def watch(opts \\ []) do
    root = File.cwd!()
    audience = Keyword.get(opts, :only, :admin)

    install_assets(root)
    Mix.shell().info("[admin_css] watching #{audience}")
    build(audience, root, ["--watch"])

    0
  end

  defp build(:admin, root, args) do
    input = Path.join(root, @input)
    File.mkdir_p!(Path.dirname(input))
    File.write!(input, css(root))

    tailwind(:admin_chrome, ["--input=#{input}", "--output=#{Path.join(root, @css)}" | args])

    Mix.shell().info("admin chrome → #{@css}")
  end

  defp build(:public, root, args) do
    input = Path.join(root, @public_input)
    File.mkdir_p!(Path.dirname(input))
    File.write!(input, public_css(root))

    tailwind(:public_pages, ["--input=#{input}", "--output=#{Path.join(root, @public)}" | args])

    Mix.shell().info("public pages → #{@public}")
  end

  # Straight to Tailwind, not through `mix tailwind`: Mix runs a task once until it re-enables it, and
  # the two watchers start together, so the one that asks second while the first holds the task gets
  # nothing and its sheet is never built.
  defp tailwind(profile, args) do
    {:ok, _apps} = Application.ensure_all_started(:tailwind)

    case Tailwind.install_and_run(profile, args) do
      0 -> :ok
      status -> Mix.raise("[admin_css] tailwind #{profile} exited with #{status}")
    end
  end

  # Copied rather than served from this library's own priv, because a host's `Plug.Static` serves the
  # host's `priv/static` and nothing else. Idempotent, so it is safe on every build.
  defp install_assets(root) do
    copy_tree(Path.join(assets_dir(), "vendor"), Path.join(root, @vendor))
    copy_tree(Path.join(assets_dir(), "fonts"), Path.join(root, @fonts))
  end

  defp copy_tree(from, to) do
    case File.dir?(from) do
      true ->
        File.mkdir_p!(to)
        File.cp_r!(from, to)

      # Named, never silent: a missing font is a visible thing, and a missing Tailwind build leaves
      # the page builder with no utilities at all.
      false ->
        Mix.shell().error("[admin_css] expected assets at #{from}")
    end
  end

  defp css(root) do
    """
    @import "tailwindcss" source(none);

    @source "#{root}/lib/**/*.{ex,heex,eex}";
    #{extension_sources(root)}
    @source "#{root}/assets/js/**/*.{js,ts}";

    #{heroicons_plugin(root)}

    /* LiveView's own wrappers must not become layout boxes — the same rule the runtime compiler
       emits for a site. Without it a nested LiveView or a teleported element introduces a block that
       breaks the grid around it. */
    [data-phx-session], [data-phx-teleported-src] { display: contents }

    /* The host's `app.css` carries the `@theme` tokens that named classes resolve against —
       `bg-primary-light` is a name, and without its definition it compiles to nothing. */
    #{read_or_empty(Path.join(root, "assets/css/app.css"))}

    #{File.read!(Path.join(assets_dir(), "admin.css"))}
    """
  end

  # The marketing surface only: the host's own web tree, and nothing from any extension. An extension
  # ships admin screens and site components — neither renders on a marketing page.
  defp public_css(root) do
    """
    @import "tailwindcss" source(none);

    @source "#{root}/lib/mishka_cms_web/**/*.{ex,heex,eex}";
    @source "#{root}/assets/js/**/*.{js,ts}";

    #{accent_utilities()}

    #{heroicons_plugin(root)}

    [data-phx-session], [data-phx-teleported-src] { display: contents }

    #{read_or_empty(Path.join(root, "assets/css/app.css"))}
    """
  end

  # THE ONE SANCTIONED ESCAPE HATCH for a class that cannot be a literal.
  #
  # `/cms` colours each product card by an accent carried on the row it renders —
  # `bg-[color-mix(in_oklch,\#{feature.accent},transparent_84%)]` and a dozen shapes like it. Tailwind's
  # scanner reads source text, so it sees the hole and generates nothing: those borders, glows,
  # tinted fills and progress widths rendered with no rule at all. Everywhere else in this codebase
  # the fix is to write the whole class out (see `MishkaCmsWeb.InterpolatedClassTest`), but here the
  # value belongs to the data, so the finite set is DECLARED instead — which is precisely what
  # `@source inline` is for. Brace expansion keeps it to one line per shape rather than 5 × 15
  # spelled out.
  #
  # Four pages render these shapes and nothing else does. `lib/mishka_cms_web/live/mishka_cms_live.ex`
  # renders every shape below; `lib/mishka_cms_web/live/mishka_gervaz_live.ex` and
  # `lib/mishka_cms_web/live/hire_mishka_live.html.heex` render only `[--c:…]`, the arbitrary property
  # that carries a row's colour so the literal `var(--c)` utilities around it can read it back.
  # `lib/mishka_cms_web/live/home_live.ex` renders `[--c:…]`, `{bg,border,text}-[…]` and the 135deg
  # gradient for the violet, magenta and cyan it shares with `colors` — which is why `home_accents/0`
  # leaves those three off its own copies of those shapes rather than compiling each rule twice.
  # `/gervaz` also reaches `--c` with the archived grey `#5e5a85`, which is why that colour has its own
  # line instead of joining `colors`: on the shared list it would also emit the flat, tinted, shadow
  # and gradient rules of a grey no page renders. A colour added here and rendered by none of those
  # files is dead CSS, and a shape rendered there and missing here renders unstyled with nothing to say
  # so. Each of those files needs its own entry in that test's `@allowed`.
  #
  # `/installer` has a palette of its own and reaches `--c` with shapes these five do not — see
  # `installer_accents/0`. `/guarded-struct` reaches it with three torch colours of its own — see
  # `guarded_struct_accents/0`, `/cms/extensions/blog` with thirteen — see `blog_accents/0` — and `/`
  # with a palette and a run of shapes larger than all of them — see `home_accents/0`.
  #
  # `/cms/extensions/documentation` reaches `[--c:…]` and `w-[…%]` with values these lists already
  # hold, and adds one grey and a second property, `--c2`, for the rows that show two coloured pills
  # at once — see `docs_accents/0`. `/chelekom/custom-service` sets `--acc`, `--tc` and `--cc` over a
  # palette of its own, and paints backgrounds, glows and a polaroid's rotation straight onto the
  # element rather than through a custom property — see `custom_service_accents/0`.
  #
  # This function is composed into `public_css/1` ALONE, and the admin has no counterpart. It briefly
  # had one, declaring the page builder's panel widths, zoom steps, layer depths and category dots.
  # Every entry was a value computed at runtime — a dragged width, a hashed hex — so the list could
  # only ever be an enumeration of what those computations happen to produce today, and its own
  # comment conceded that a layer tree nested past the fortieth row would render flush left. Those
  # sites carry an inline `style` attribute again, which is exact at any depth and needs no list.
  defp accent_utilities do
    colors =
      "oklch(0.68_0.22_295),oklch(0.66_0.24_330),oklch(0.78_0.16_220),oklch(0.74_0.17_155),oklch(0.80_0.15_75)"

    tinted = "{bg,border}-[color-mix(in_oklch,{#{colors}},transparent_{55,60,80,84,86,88}%)]"
    flat = "{bg,border,text}-[{#{colors}}]"

    # The `!` variants get their own lines. Brace expansion has no empty alternative — `{,!}` is not
    # a suffix that may be absent, it silently produces nothing at all, and the difference shows up
    # only as a rule that never appears.
    """
    @source inline("#{flat}");
    @source inline("#{flat}!");
    @source inline("#{tinted}");
    @source inline("#{tinted}!");
    @source inline("shadow-[0_0_{6,8,10}px_{#{colors}}]");
    @source inline("shadow-[0_6px_20px_-8px_{#{colors}}]");
    @source inline("bg-[linear-gradient(90deg,{#{colors}},transparent)]");
    @source inline("bg-[linear-gradient(135deg,{#{colors}},oklch(0.66_0.24_330))]");
    @source inline("w-[{74,82,91}%]");
    @source inline("[--c:{#{colors}}]");
    @source inline("[--c:#5e5a85]");
    #{installer_accents()}
    #{blog_accents()}
    #{docs_accents()}
    #{guarded_struct_accents()}
    #{custom_service_accents()}
    #{home_accents()}
    """
  end

  # `/` — `lib/mishka_cms_web/live/home_live.ex`, the largest of these pages and the only one whose
  # accents leave the `--c` family. Three populations reach a class there:
  #
  #   * the per-row accents — release cards, feature cards, service cards, the team polaroids, the
  #     footer chips and the two placeholder cards — which set `--c`, `--tc`, `--hue`, `--accent` and
  #     their pre-mixed alpha variants, exactly as `/gervaz` and `/installer` do;
  #   * the fake dashboard, installer and page builder it animates, whose tints, glows, gradients and
  #     drop-shadows are computed from a row's colour and a step counter;
  #   * the component explorer's live previews, which paint a swatch, a dot or a badge from a colour
  #     in the list being rendered.
  #
  # Eight colours reach them: the page's own violet, magenta and cyan (which happen to match three of
  # `colors` above), its indigo, green, amber, gold and the red of the "offline" indicator. Each shape
  # lists only the colours that actually render in it — the builder's four, the plugin rail's five,
  # the ecosystem inspector's five — so the cross product never happens. The two shapes
  # `accent_utilities/0` already declares in this very form, `{bg,border,text}-[…]` and `[--c:…]`,
  # subtract `shared`: on both lists those three would compile the identical rule twice. The fixed
  # gradients drop their violet-to-magenta pair for the same reason. Every other shape here is this
  # page's alone, so it carries its palette whole.
  defp home_accents do
    violet = "0.68_0.22_295"
    magenta = "0.66_0.24_330"
    cyan = "0.78_0.16_220"
    indigo = "0.62_0.18_265"
    green = "0.72_0.18_150"
    amber = "0.78_0.15_85"
    gold = "0.85_0.15_90"
    red = "0.66_0.24_30"

    eco = [violet, magenta, cyan, indigo, amber]
    quad = [violet, magenta, cyan, green]
    penta = [violet, magenta, cyan, green, amber]
    card = [violet, magenta, cyan, indigo, green, amber]
    all = [violet, magenta, cyan, indigo, green, amber, gold, red]
    shared = [violet, magenta, cyan]

    tech = "#FD4F00,#A66ED5,#DEA584,#38BDF8,#F7DF1E,#3178C6,#61DAFB,#FFFFFF"

    """
    @source inline("{bg,border,text}-[{#{flat(all -- shared)}}]");
    @source inline("{bg,border}-[{#{tint(eco, "0.078")}}]");
    @source inline("{bg,border}-[{#{tint(eco, "0.14")}}]");
    @source inline("{bg,border}-[{#{tint(eco, "0.2")}}]");
    @source inline("{bg,border}-[{#{tint(eco, "0.33")}}]");
    @source inline("{bg,border}-[{#{tint(eco, "0.4")}}]");
    @source inline("{bg,border}-[{#{tint(quad, "0.08")}}]");
    @source inline("{bg,border}-[{#{tint(quad, "0.1")}}]");
    @source inline("{bg,border}-[{#{tint(quad, "0.25")}}]");
    @source inline("{bg,border}-[{#{tint(quad, "0.333")}}]");
    @source inline("{bg,border}-[{#{tint(quad, "0.53")}}]");
    @source inline("[box-shadow:0_0_{6,8,10,12,18}px_{#{flat(all)}}]");
    @source inline("[box-shadow:0_0_20px_{#{tint(penta, "0.467")}}]");
    @source inline("[box-shadow:0_0_10px_{#{tint(penta, "0.333")}}]");
    @source inline("[box-shadow:0_0_0_3px_{#{tint(quad, "0.25")}}]");
    @source inline("[box-shadow:0_24px_70px_-30px_{#{flat(eco)}},inset_0_1px_0_rgba(255,255,255,0.04)]");
    @source inline("[filter:drop-shadow(0_0_{4,8}px_{#{flat(eco)}})]");
    @source inline("[filter:drop-shadow(0_0_14px_{#{tint(eco, "0.6")}})]");
    @source inline("bg-[linear-gradient(90deg,transparent,{#{flat(eco)}},transparent)]");
    @source inline("bg-[linear-gradient({#{flat(quad)}},rgba(120,110,200,0.14))]");
    @source inline("bg-[linear-gradient(135deg,{#{tint(penta, "0.18")}},rgba(8,6,18,0.5))]");
    #{home_pair_gradients(penta)}
    #{home_fixed_gradients()}
    @source inline("[--c:{#{flat(card -- shared)}}]");
    @source inline("[--c{40,66}:{#{tint(card, "0.4")}}]");
    @source inline("[--c{33,20}:{#{tint(card, "0.2")}}]");
    @source inline("[--c{12,1f}:{#{tint(card, "0.122")}}]");
    @source inline("[--c55:{#{tint(card, "0.333")}}]");
    @source inline("[--tc:{#{tech}}]");
    @source inline("[--tcg:{#{tech}}66]");
    @source inline("[--hue:{#{flat([cyan, magenta])}}]");
    @source inline("[--hue05:{#{tint([cyan, magenta], "0.5")}}]");
    @source inline("[--accent:{#{flat([violet, magenta, cyan, gold])}}]");
    @source inline("[--accent-55:{#{tint([magenta, cyan, gold], "0.333")}}]");
    @source inline("[--sticker-bg:{#{tint([green, cyan, gold], "0.85")}}]");
    @source inline("[--tape:{#{tint([magenta], "0.45")},#{tint([cyan, gold], "0.5")}}]");
    @source inline("[--tilt:{-3.2,2.4,-1.6}deg]");
    @source inline("[--tape-rot:{2.24,-1.68,1.12}deg]");
    """
  end

  defp flat(list), do: Enum.map_join(list, ",", &"oklch(#{&1})")

  defp tint(list, alpha), do: Enum.map_join(list, ",", &"oklch(#{&1}_/_#{alpha})")

  # The builder's dropped block and the plugin rail's lit icon each blend ONE colour with itself at a
  # second alpha, so the two holes are correlated and brace expansion — which gives the cross product —
  # cannot express it. A line per colour is the only faithful form.
  defp home_pair_gradients(colors) do
    Enum.map_join(colors, "\n", fn c ->
      """
      @source inline("bg-[linear-gradient(135deg,oklch(#{c}_/_0.32),oklch(#{c}_/_0.18))]");
      @source inline("bg-[linear-gradient(135deg,oklch(#{c}),oklch(#{c}_/_0.55))]");\
      """
    end)
  end

  # The explorer's avatar stack and gallery grid carry a whole gradient in their data rather than a
  # colour, so each is its own literal. The violet-to-magenta pair both open with is absent because
  # the 135deg line in `accent_utilities/0` already declares it.
  defp home_fixed_gradients do
    [
      "oklch(0.78_0.16_220),oklch(0.68_0.22_295)",
      "oklch(0.66_0.24_330),oklch(0.85_0.15_90)",
      "oklch(0.72_0.18_150),oklch(0.78_0.16_220)",
      "oklch(0.85_0.15_90),oklch(0.66_0.24_30)",
      "oklch(0.66_0.24_30),oklch(0.66_0.24_330)"
    ]
    |> Enum.map_join("\n", &~s|@source inline("bg-[linear-gradient(135deg,#{&1})]");|)
  end

  # `/guarded-struct` — `lib/mishka_cms_web/live/guarded_struct_live.ex` and its template. Seven
  # colours reach `--c` there: the violet, magenta and cyan of `colors` and the archived grey are
  # already declared above, and these three torch hexes are the fortress palette's own. Whichever
  # one a rune sigil, entity card, derive-group dot, armory line or beacon label carries, the
  # literal `var(--c)` utilities around it read it back as that element's fill, glow, text-shadow
  # or drop-shadow. Only `--c` is interpolated on that page; every other value set there is small
  # enough to be written out one function clause at a time.
  defp guarded_struct_accents do
    """
    @source inline("[--c:{#ff8a3a,#ffb86b,#d9b455}]");
    """
  end

  # `/cms/extensions/blog` reaches `--c` with thirteen values: the five accents and `#5e5a85` above,
  # plus a rose the other pages do not use, the paragraph grey of its editor and canvas blocks, and
  # the five brand hexes of its share row — which are the brands' own colours and can never be
  # anything else.
  defp blog_accents do
    rest = "oklch(0.70_0.19_12),#9a96c4,#0A66C2,#1877F2,#1DA1F2,#26A5E4,#6364FF"

    """
    @source inline("[--c:{#{rest}}]");
    """
  end

  # `/cms/extensions/documentation` — `lib/mishka_cms_web/live/mishka_docs_live.ex`. Its palette is
  # the shared five plus the rose `blog_accents/0` already declares, so a feature card, doc event,
  # draft verdict or issue kind reaches `--c` with a colour that is on one of those lists already;
  # only the review workflow's first phase, the inert grey `#5a6285`, is this page's own. Its
  # completion bars are `w-[{74,82,91}%]` above — the same three percentages `/cms` renders.
  #
  # `--c2` is the one shape this page adds. A draft row shows content review and technical review as
  # two independently coloured pills, and an issue row its kind beside its state, so a second custom
  # property carries the colour of the pill that sits next to `--c`. Only a review verdict or an
  # issue state reaches it, which is why it takes three colours rather than the whole palette.
  defp docs_accents do
    """
    @source inline("[--c:#5a6285]");
    @source inline("[--c2:{oklch(0.74_0.17_155),oklch(0.80_0.15_75),oklch(0.78_0.16_220)}]");
    """
  end

  # `/installer` — `lib/mishka_cms_web/live/mishka_installer_live.ex` and its template. Same idea, an
  # unrelated palette: sodium-lamp hex rather than the shared oklch five, so it gets its own lists
  # instead of joining `colors`, where every colour would also acquire that page's flat, tinted and
  # gradient shapes.
  #
  # Two shapes are new. `--c` there carries a whole `drop-shadow` argument list as well as a bare
  # colour — the dispatch clock's dots glow at three radii — and an element that needs several
  # pre-mixed alphas of its accent at once names each after the alpha it holds, so `--c26` is only
  # ever the accent at `26`. Which palette reaches which shape is what keeps that from becoming a
  # cross product: only the five scenario colours reach the clock, only the five plugin states reach
  # the registry row, and the action bar adds `#ffd58a` for "Fire event".
  defp installer_accents do
    scenario = "#5cd8ff,#ffd58a,#ffb86b,#ff5fa6,#7be0a3"
    state = "#7be0a3,#ff5fa6,#5cd8ff,#ffb86b,#9b73ff"
    action = "#{state},#ffd58a"
    palette = "#{scenario},#9b73ff,#5b6478"

    """
    @source inline("[--c:{#{palette}}]");
    @source inline("[--c:0_0_{4,6,10}px_{#{scenario}}]");
    @source inline("[--c2:{#{scenario}}{1a,44}]");
    @source inline("[--c3:{#{scenario}}66]");
    @source inline("[--c2:{#{state}}22]");
    @source inline("[--c1a:{#{state}}1a]");
    @source inline("[--c26:{#{state}}26]");
    @source inline("[--c55:{#{state}}55]");
    @source inline("[--c66:{#{state}}66]");
    @source inline("[--c10:{#{action}}10]");
    @source inline("[--c22:{#{action}}22]");
    @source inline("[--c88:{#{action}}88]");
    """
  end

  # `/chelekom/custom-service` — `lib/mishka_cms_web/live/custom_service_live.ex` and its template.
  # Seven populations reach a class there, each from a literal in that module's own data:
  #
  #   * the six service accents, which colour a card's glyph tile, its number pill and the preview
  #     inside it — the preview's own `@color` is the service's, so the two travel together;
  #   * the six swatches of the design-system preview and the eight brand hexes of the tech row;
  #   * the four community channel colours, which reach `--cc`;
  #   * the three polaroid accents, tapes and stickers, and the tilt each polaroid and its tape is
  #     rotated by, which reach `transform` directly rather than a custom property.
  #
  # The tilts are the raw expression the template interpolates — `-tilt * 0.7` in double precision,
  # not a rounded literal — so what is declared here is byte-identical to the class the page renders.
  # Three of the polaroid accents and seven of the tech hexes also appear on `/`'s list, and the page
  # keeps its own copies: a repeated candidate compiles to the one rule, and the whole of what this
  # page can render is then readable against the page. Its gradients pair a colour with a partner
  # carried on the same row, so they are one line each rather than a cross product. The token ramp's
  # four `hsl()` gradients and the audit table's dashed rule are literals in the source, so they are
  # not declared here at all.
  defp custom_service_accents do
    service = "#9b73ff,#5cd8ff,#ff7eb6,#ffb86b,#7be0a3,#c4a3ff"
    swatch = "#9b73ff,#ff7eb6,#5cd8ff,#7be0a3,#ffb86b,#ff7e8a"
    tech = "#FD4F00,#A66ED5,#DEA584,#38BDF8,#F7DF1E,#3178C6,#61DAFB,#ffffff"
    channel = "#ffffff,#5cd8ff,#ff5fa6,#ffb86b"
    accent = "oklch(0.66_0.24_330),oklch(0.78_0.16_220),oklch(0.85_0.15_90)"
    tape = "oklch(0.66_0.24_330_/_0.45),oklch(0.85_0.15_90_/_0.5),oklch(0.78_0.16_220_/_0.5)"
    sticker = "oklch(0.72_0.18_150_/_0.85),oklch(0.78_0.16_220_/_0.85),oklch(0.85_0.15_90_/_0.85)"

    """
    @source inline("[background:{#{swatch},#{tech},#{tape},#{sticker}}]");
    @source inline("[background:{#{service}}1a]");
    @source inline("[background:#ff7eb6{44,55,66,77}]");
    @source inline("[background:{#5cd8ff22,#ffb86b15}]");
    #{custom_service_glyph_gradients()}
    @source inline("[box-shadow:0_0_8px_#9b73ff]");
    @source inline("[box-shadow:0_0_6px_{#{tech}}]");
    @source inline("[box-shadow:0_0_14px_{#{service}}55]");
    @source inline("[filter:drop-shadow(0_0_4px_#5cd8ff)]");
    @source inline("border-[{#{service}}55]");
    @source inline("border-[{#9b73ff33,#ff7eb6}]");
    @source inline("text-[{#{service},#{accent}}]");
    @source inline("[--acc:{#{accent}}]");
    @source inline("[--tc:{#{tech}}]");
    @source inline("[--cc:{#{channel}}]");
    @source inline("[transform:rotate({-3.2,2.4,-1.6}deg)]");
    @source inline("[transform:translateX(-50%)_rotate({2.2399999999999998,-1.68,1.1199999999999999}deg)]");
    """
  end

  # A service card's glyph tile blends its own colour with the accent of the SAME row, so the two
  # holes are correlated and brace expansion — which gives the cross product — cannot express it.
  defp custom_service_glyph_gradients do
    [
      {"#9b73ff", "#ff7eb6"},
      {"#5cd8ff", "#9b73ff"},
      {"#ff7eb6", "#9b73ff"},
      {"#ffb86b", "#ff7eb6"},
      {"#7be0a3", "#5cd8ff"},
      {"#c4a3ff", "#ff7eb6"}
    ]
    |> Enum.map_join("\n", fn {color, accent} ->
      ~s|@source inline("[background:linear-gradient(135deg,#{color},#{accent})]");|
    end)
  end

  # THE ICONS. A heroicon is a class with no glyph in the markup — `<span class="hero-pencil">` and a
  # CSS mask — and the mask rule comes from this plugin. Leaving it out is why the admin's table
  # actions rendered as empty rounded squares: the buttons were there, the icons had no rule.
  #
  # It comes from `mix copy_js_assets`, which must therefore run first. The Dockerfile orders them
  # that way and says why.
  defp heroicons_plugin(root) do
    path = Path.join(root, "priv/static/temp/js_assets/vendor/heroicons.js")

    case File.exists?(path) do
      true ->
        ~s|@plugin "#{path}";|

      false ->
        Mix.shell().error(
          "[admin_css] no heroicons plugin at #{path} — admin icons will not render"
        )

        ""
    end
  end

  # ONE GLOB PER EXTENSION, for the gitignore reason in the moduledoc. Both locations, because the
  # same package lives in either depending on how it was installed: `__extensions/` while it is
  # developed in the tree, `deps/mishka_*` once released to hex — which is where they are all headed.
  # An extension must not lose its styling by changing how it was fetched.
  #
  # And its `assets/js`: an extension that ships its LiveView hooks as JavaScript the host imports
  # (the visual editor does) sets classes from there, which no `.ex` file spells and the host's own
  # `assets/js` no longer carries.
  defp extension_sources(root) do
    vendored = root |> Path.join("__extensions") |> directories()
    released = root |> Path.join("deps") |> directories() |> Enum.filter(&mishka?/1)

    (vendored ++ released)
    |> Enum.sort()
    |> Enum.map_join("\n", fn dir ->
      ~s|@source "#{dir}/**/*.{ex,heex,eex}";\n@source "#{dir}/assets/js/**/*.{js,ts}";|
    end)
  end

  defp directories(parent) do
    case File.ls(parent) do
      {:ok, entries} -> entries |> Enum.map(&Path.join(parent, &1)) |> Enum.filter(&File.dir?/1)
      {:error, _reason} -> []
    end
  end

  # `deps/` holds hundreds of packages and scanning all of them costs minutes for classes that cannot
  # exist. The ecosystem's naming is the filter — an extension published under another prefix has to
  # be added here, which is a deliberate trade against scanning `ecto` for CSS.
  defp mishka?(path), do: path |> Path.basename() |> String.starts_with?("mishka_")

  defp assets_dir, do: Path.join(:code.priv_dir(:mishka_cms_core), "admin_assets")

  defp read_or_empty(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _reason} -> ""
    end
  end
end
