defmodule MishkaCmsCore.Dev.LocalhostPages do
  @moduledoc """
  The dev showcase: what `localhost` answers on top of the starter site every seeded site gets.

  One module per site, because a page here names THIS site's components and THIS site's hooks by
  name and a list shared between sites cannot. `MishkaCmsCore.Dev.Seeds` picks the module out of
  `@site_configs`; `MishkaCmsCore.Install.StarterContent` has already written the home, about,
  contact and privacy pages these link back to.

  Between them the pages below use every part of a runtime page a developer has to be able to see
  working: the UI kit's interactive components, a page form with uploads, page events and infos,
  `pb:say`, a site JS hook and a global one, a `:param` capture, a `*rest` capture, a page that is
  switched off, and the `/:lang` path mode every address here is written in.
  """

  @nav [{"Pricing", "/pricing"}, {"Gallery", "/gallery"}, {"Messages", "/messages"}]

  @doc "The header links the layout is built with — see `MishkaCmsCore.Install.StarterContent`."
  @spec nav() :: [{String.t(), String.t()}]
  def nav, do: @nav

  @doc """
  The pages, as `MishkaCmsCore.Runtime.PageProvision` definitions.

  `pictures` is `MishkaCmsCore.Dev.SeedMedia.images/1` for this site, which these pages do not use —
  every site's module is asked the same question and `MishkaCmsCore.Dev.SiteAPages` answers it with
  faces from the library.
  """
  @spec pages(%{atom() => [String.t()]}) :: [map()]
  def pages(_pictures) do
    [
      pricing(),
      gallery(),
      messages(),
      forms(),
      upload(),
      feature(),
      handbook(),
      terms(),
      coming_soon(),
      no_language()
    ]
  end

  @doc """
  The about page this site answers `/:lang/about` with, in place of the installer's: the same page,
  plus a container hidden from visitors (`MishkaCmsCore.Runtime.PageBuilder.Visibility`) holding
  components and containers of its own — what the builder's Hide from visitors looks like when it
  opens, and what the live page leaves out.
  """
  @spec about() :: String.t()
  def about do
    ~S"""
    <article class="rounded-card border border-line bg-white p-8">
      <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">
        About localhost
      </h1>
      <p class="mt-4 text-[15px] leading-relaxed text-ink-soft">
        This page is here so you have something to edit. Replace it with who you are, what you
        make and why somebody should read on.
      </p>
      <dl class="mt-8 grid gap-5 sm:grid-cols-3">
        <div :for={
          {term, detail} <- [
            {"Runs on", "Elixir, Phoenix and the Ash Framework"},
            {"Edited in", "The page builder, on this same site"},
            {"Published", "When you say so, and not before"}
          ]
        }>
          <dt class="text-[11.5px] font-bold uppercase tracking-[0.14em] text-muted">{term}</dt>
          <dd class="mt-1 text-[13.5px] text-ink">{detail}</dd>
        </div>
      </dl>
      <div
        data-pb-hidden
        id="about-team"
        class="mt-8 rounded-card border border-dashed border-line p-6"
      >
        <p class="text-[12px] font-bold uppercase tracking-[0.18em] text-accent">
          Hidden from visitors
        </p>
        <h2 class="mt-2 font-display text-[20px] font-bold tracking-[-0.02em] text-ink">
          Coming soon: the team
        </h2>
        <p class="mt-2 text-[13.5px] leading-relaxed text-ink-soft">
          This section is in the page and in the builder, and in no visitor's browser. Show it from
          its Hidden chip in the layers tree, the right-click menu or the Inspector.
        </p>
        <div class="mt-4 flex flex-wrap gap-2">
          <.component component_name="chelekom-badge" site="Global" color="success">
            Editor
          </.component>
          <.component component_name="chelekom-badge" site="Global" color="warning">
            Runtime
          </.component>
        </div>
        <div class="mt-5 grid gap-4 sm:grid-cols-2">
          <div class="rounded-[12px] border border-line p-4">
            <h3 class="font-display text-[15px] font-bold text-ink">The editor team</h3>
            <p class="mt-1 text-[13px] text-ink-soft">Builds the canvas, the layers and the Inspector.</p>
          </div>
          <div class="rounded-[12px] border border-line p-4">
            <h3 class="font-display text-[15px] font-bold text-ink">The runtime team</h3>
            <p class="mt-1 text-[13px] text-ink-soft">Compiles every page a visitor opens.</p>
          </div>
        </div>
        <.component component_name="chelekom-stat-group" site="Global" id="about-team-stats" class="mt-5">
          <.component
            component_name="chelekom-stat"
            site="Global"
            id="about-team-people"
            title="People"
            value="2"
            description="Both hidden with the section around them"
          />
        </.component>
      </div>
      <p class="mt-8">
        <.link navigate={"/#{@query_params["lang"]}"} class="text-[13px] font-bold text-accent">
          ← Back home
        </.link>
      </p>
    </article>
    """
  end

  @doc """
  The home page this site answers `/:lang` with, in place of the installer's starter home.

  `MishkaCmsCore.Install.StarterContent` writes the plain page a stranger's first install opens on;
  in dev the first page a developer opens is the one that has to show what a runtime page can do,
  so each site hands its own template to the same seeding run.
  """
  @spec home() :: String.t()
  def home do
    ~S"""
    <section
      id="localhost-home"
      phx-hook="LocalhostConsoleLogger"
      class="rounded-card border border-line bg-white px-8 py-14 text-center"
    >
      <p class="text-[12px] font-bold uppercase tracking-[0.18em] text-accent">Dev seed</p>
      <h1 class="mt-3 font-display text-[38px] font-bold leading-[1.15] tracking-[-0.03em] text-ink">
        Everything a runtime page can do
      </h1>
      <p class="mx-auto mt-4 max-w-[620px] text-[15px] leading-relaxed text-ink-soft">
        Every address on this site is a row in the database compiled to a Phoenix module — no route
        answers any of them. This page is hooked, so the console says so the moment it mounts.
      </p>
      <div class="mt-7 flex flex-wrap items-center justify-center gap-3">
        <.link
          navigate={"/#{@query_params["lang"]}/gallery"}
          class="rounded-[9px] bg-[#17161a] px-4 py-2 text-[12px] font-bold text-white"
        >
          Open the gallery
        </.link>
        <.link
          navigate={"/#{@query_params["lang"]}/pricing"}
          class="rounded-[9px] border border-line px-4 py-2 text-[12px] font-bold text-ink"
        >
          Pricing
        </.link>
      </div>
    </section>

    <.component component_name="chelekom-stat-group" site="Global" id="home-stats" class="mt-6">
      <.component
        component_name="chelekom-stat"
        site="Global"
        id="home-stat-sites"
        title="Seeded sites"
        value="3"
        description="localhost, site-a and site-b, each its own tenant"
      />
      <.component
        component_name="chelekom-stat"
        site="Global"
        id="home-stat-languages"
        title="Languages here"
        value="2"
        description="English and Persian, both on /:lang"
      />
      <.component
        component_name="chelekom-stat"
        site="Global"
        id="home-stat-hooks"
        title="JS hooks"
        value="3"
        description="Two this site owns, one the whole node shares"
      />
    </.component>

    <section class="mt-6 grid gap-5 md:grid-cols-3">
      <.link
        :for={
          {title, body, path} <- [
            {"The kit, composed", "Tabs, tables, modals, drawers, steppers and a pager.", "/gallery"},
            {"Events and infos", "Page events, a timer, pb:say and the flash region.", "/messages"},
            {"Forms and uploads", "Two forms on one page, and a live file field.", "/forms"}
          ]
        }
        navigate={"/#{@query_params["lang"]}#{path}"}
        class="rounded-card border border-line bg-white p-5 shadow-[0_1px_2px_rgba(30,28,24,0.04)] hover:border-accent"
      >
        <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">{title}</h2>
        <p class="mt-2 text-[13.5px] leading-relaxed text-ink-soft">{body}</p>
      </.link>
    </section>

    <section class="mt-6 flex flex-wrap items-center justify-between gap-4 rounded-card border border-line bg-white p-6">
      <div>
        <h2 class="font-display text-[20px] font-bold tracking-[-0.02em] text-ink">
          The captures, too
        </h2>
        <p class="mt-1 text-[13.5px] text-ink-soft">
          One page answers every feature, and one answers a path of any depth.
        </p>
      </div>
      <div class="flex flex-wrap gap-3">
        <.link
          navigate={"/#{@query_params["lang"]}/features/multi-tenant"}
          class="rounded-[9px] border border-line px-4 py-2 text-[12px] font-bold text-ink"
        >
          A :param page
        </.link>
        <.link
          navigate={"/#{@query_params["lang"]}/handbook/getting-started/install"}
          class="rounded-[9px] bg-accent px-4 py-2 text-[12px] font-bold text-white"
        >
          A *rest page
        </.link>
      </div>
    </section>
    """
  end

  defp pricing do
    %{
      name: "Pricing",
      title: "Pricing",
      path: "/:lang/pricing",
      section: "main",
      description:
        "Tabs, a comparison table and an accordion — three kit components on one page.",
      format: :heex,
      template: ~S"""
      <section class="rounded-card border border-line bg-white px-7 py-8">
        <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">Pricing</h1>
        <p class="mt-2 max-w-[620px] text-[13.5px] leading-relaxed text-ink-soft">
          Everything on this page is a component stored in the database. Open it in the builder and
          the tabs, the table and the accordion are all still components.
        </p>
      </section>

      <section class="mt-6 rounded-card border border-line bg-white p-6">
        <.component
          component_name="chelekom-tabs"
          site="Global"
          id="pricing-tabs"
          variant="pills"
          color="primary"
          size="medium"
        >
          <:tab>Monthly</:tab>
          <:tab>Yearly</:tab>
          <:panel>
            <div class="grid gap-5 md:grid-cols-3">
              <article
                :for={
                  {plan, price, line} <- [
                    {"Starter", "€0", "One site, one editor, every feature."},
                    {"Team", "€29", "Five sites and a draft review step."},
                    {"Agency", "€99", "Unlimited sites and your own kits."}
                  ]
                }
                class="rounded-card border border-line p-5"
              >
                <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">
                  {plan}
                </h2>
                <p class="mt-1 font-display text-[28px] font-bold text-accent">{price}</p>
                <p class="mt-2 text-[13px] text-ink-soft">{line}</p>
              </article>
            </div>
          </:panel>
          <:panel>
            <p class="text-[13.5px] text-ink-soft">
              Two months free on every plan. The numbers are the same otherwise.
            </p>
          </:panel>
        </.component>
      </section>

      <section class="mt-6 rounded-card border border-line bg-white p-6">
        <h2 class="mb-4 font-display text-[17px] font-bold tracking-[-0.02em] text-ink">
          What is in each plan
        </h2>
        <.component component_name="chelekom-table" site="Global" id="pricing-table" color="natural">
          <:header>Feature</:header>
          <:header>Starter</:header>
          <:header>Team</:header>
          <:header>Agency</:header>
          <.component component_name="chelekom-tr" site="Global" :for={
            {feature, starter, team, agency} <- [
              {"Sites", "1", "5", "Unlimited"},
              {"Page builder", "Yes", "Yes", "Yes"},
              {"Draft review", "No", "Yes", "Yes"},
              {"Own UI kits", "No", "No", "Yes"}
            ]
          }>
            <.component component_name="chelekom-td" site="Global">{feature}</.component>
            <.component component_name="chelekom-td" site="Global">{starter}</.component>
            <.component component_name="chelekom-td" site="Global">{team}</.component>
            <.component component_name="chelekom-td" site="Global">{agency}</.component>
          </.component>
        </.component>
      </section>

      <section class="mt-6 rounded-card border border-line bg-white p-6">
        <h2 class="mb-4 font-display text-[17px] font-bold tracking-[-0.02em] text-ink">
          Questions
        </h2>
        <.component
          component_name="chelekom-accordion"
          site="Global"
          id="pricing-faq"
          variant="bordered"
          color="natural"
        >
          <:item id="faq-billing" title="Can I change plan later?">
            Yes. The change takes effect on the next invoice and nothing is lost.
          </:item>
          <:item id="faq-data" title="Where does my content live?">
            In your own database. Every page, layout and component is a row you can export.
          </:item>
          <:item id="faq-cancel" title="What happens if I stop paying?">
            The sites stay published on the free plan's limits until you decide.
          </:item>
        </.component>
      </section>

      <p class="mt-6 text-[13px]">
        <.link navigate={"/#{@query_params["lang"]}/gallery"} class="font-bold text-accent">
          See the rest of the kit →
        </.link>
      </p>
      """,
      translations: %{"fa" => pricing_fa()}
    }
  end

  defp pricing_fa do
    %{
      name: "قیمت‌گذاری",
      title: "قیمت‌گذاری",
      description: "زبانه‌ها، جدول مقایسه و آکاردئون — سه مؤلفه از کیت روی یک صفحه.",
      template: ~S"""
      <section class="rounded-card border border-line bg-white px-7 py-8">
        <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">قیمت‌گذاری</h1>
        <p class="mt-2 max-w-[620px] text-[13.5px] leading-relaxed text-ink-soft">
          هر چیزی که در این صفحه می‌بینید یک مؤلفهٔ ذخیره‌شده در پایگاه داده است. آن را در صفحه‌ساز باز
          کنید؛ زبانه‌ها، جدول و آکاردئون همچنان همان مؤلفه‌ها هستند.
        </p>
      </section>

      <section class="mt-6 rounded-card border border-line bg-white p-6">
        <.component
          component_name="chelekom-tabs"
          site="Global"
          id="pricing-tabs"
          variant="pills"
          color="primary"
          size="medium"
        >
          <:tab>ماهانه</:tab>
          <:tab>سالانه</:tab>
          <:panel>
            <div class="grid gap-5 md:grid-cols-3">
              <article
                :for={
                  {plan, price, line} <- [
                    {"استارتر", "€۰", "یک سایت، یک ویرایشگر، همهٔ امکانات."},
                    {"تیمی", "€۲۹", "پنج سایت و یک مرحلهٔ بازبینی پیش‌نویس."},
                    {"آژانس", "€۹۹", "سایت نامحدود و کیت‌های اختصاصی خودتان."}
                  ]
                }
                class="rounded-card border border-line p-5"
              >
                <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">
                  {plan}
                </h2>
                <p class="mt-1 font-display text-[28px] font-bold text-accent">{price}</p>
                <p class="mt-2 text-[13px] text-ink-soft">{line}</p>
              </article>
            </div>
          </:panel>
          <:panel>
            <p class="text-[13.5px] text-ink-soft">
              در همهٔ طرح‌ها دو ماه رایگان هدیه می‌گیرید. جز این، اعداد همان‌هایی هستند که دیدید.
            </p>
          </:panel>
        </.component>
      </section>

      <section class="mt-6 rounded-card border border-line bg-white p-6">
        <h2 class="mb-4 font-display text-[17px] font-bold tracking-[-0.02em] text-ink">
          هر طرح چه امکاناتی دارد
        </h2>
        <.component component_name="chelekom-table" site="Global" id="pricing-table" color="natural">
          <:header>امکان</:header>
          <:header>استارتر</:header>
          <:header>تیمی</:header>
          <:header>آژانس</:header>
          <.component component_name="chelekom-tr" site="Global" :for={
            {feature, starter, team, agency} <- [
              {"سایت‌ها", "۱", "۵", "نامحدود"},
              {"صفحه‌ساز", "بله", "بله", "بله"},
              {"بازبینی پیش‌نویس", "خیر", "بله", "بله"},
              {"کیت اختصاصی", "خیر", "خیر", "بله"}
            ]
          }>
            <.component component_name="chelekom-td" site="Global">{feature}</.component>
            <.component component_name="chelekom-td" site="Global">{starter}</.component>
            <.component component_name="chelekom-td" site="Global">{team}</.component>
            <.component component_name="chelekom-td" site="Global">{agency}</.component>
          </.component>
        </.component>
      </section>

      <section class="mt-6 rounded-card border border-line bg-white p-6">
        <h2 class="mb-4 font-display text-[17px] font-bold tracking-[-0.02em] text-ink">
          پرسش‌ها
        </h2>
        <.component
          component_name="chelekom-accordion"
          site="Global"
          id="pricing-faq"
          variant="bordered"
          color="natural"
        >
          <:item id="faq-billing" title="آیا می‌توانم بعداً طرحم را عوض کنم؟">
            بله. تغییر از صورت‌حساب بعدی اعمال می‌شود و چیزی از دست نمی‌رود.
          </:item>
          <:item id="faq-data" title="محتوای من کجا نگهداری می‌شود؟">
            در پایگاه دادهٔ خودتان. هر صفحه، چیدمان و مؤلفه یک ردیف است که می‌توانید از آن خروجی بگیرید.
          </:item>
          <:item id="faq-cancel" title="اگر پرداخت را متوقف کنم چه می‌شود؟">
            سایت‌ها تا زمانی که خودتان تصمیم بگیرید، با محدودیت‌های طرح رایگان منتشر باقی می‌مانند.
          </:item>
        </.component>
      </section>

      <p class="mt-6 text-[13px]">
        <.link navigate={"/fa/gallery"} class="font-bold text-accent">
          باقی کیت را ببینید ←
        </.link>
      </p>
      """
    }
  end

  # THE HOOK NAMES ARE THIS SITE'S OWN. A site hook is registered under its site's prefix, so
  # `LocalhostConsoleLogger` works here and nowhere else — which is exactly why this list belongs to
  # one site. A global hook (`GlobalChelekomClipboard`) is registered for everyone and carries no
  # prefix.
  defp gallery do
    %{
      name: "Gallery",
      title: "Gallery",
      path: "/:lang/gallery",
      section: "main",
      description:
        "Every interactive part of the kit, and the way into the rest of the dev pages.",
      format: :heex,
      template: ~S"""
      <.component component_name="chelekom-breadcrumb" site="Global" id="gallery-crumbs">
        <:item link={"/#{@query_params["lang"]}"} title="Home">Home</:item>
        <:item title="Gallery">Gallery</:item>
      </.component>

      <section class="mt-5 rounded-card border border-line bg-white px-7 py-8">
        <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">
          The kit, working
        </h1>
        <p class="mt-2 max-w-[620px] text-[13.5px] leading-relaxed text-ink-soft">
          Click everything. A modal, a drawer, a tooltip, a toast, a stepper and a pager, each one a
          component compiled out of the database.
        </p>
      </section>

      <section class="mt-6 grid gap-5 md:grid-cols-2">
        <div class="rounded-card border border-line bg-white p-6">
          <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">Overlays</h2>
          <div class="mt-4 flex flex-wrap items-center gap-3">
            <button
              type="button"
              id="gallery-open-modal"
              phx-click={JS.exec("data-pb-open", to: "#gallery-modal")}
              class="rounded-[9px] bg-[#17161a] px-4 py-2 text-[12px] font-bold text-white"
            >
              Open the modal
            </button>
            <button
              type="button"
              id="gallery-open-drawer"
              phx-click={JS.exec("data-pb-open", to: "#gallery-drawer")}
              class="rounded-[9px] border border-line px-4 py-2 text-[12px] font-bold text-ink"
            >
              Open the drawer
            </button>
            <.component component_name="chelekom-tooltip" site="Global" id="gallery-tip" color="dark">
              <:trigger>
                <span class="rounded-[9px] border border-line px-4 py-2 text-[12px] font-bold text-ink">
                  Hover me
                </span>
              </:trigger>
              <:content>A tooltip, positioned by the kit.</:content>
            </.component>
          </div>

          <.component
            component_name="chelekom-modal"
            site="Global"
            id="gallery-modal"
            title="A modal from the database"
            color="natural"
          >
            <p class="text-[13.5px] text-ink-soft">
              Nothing here was written in Elixir. The component, its styling and this text are rows.
            </p>
          </.component>

          <.component
            component_name="chelekom-drawer"
            site="Global"
            id="gallery-drawer"
            title="A drawer"
            position="right"
          >
            <p class="text-[13.5px] text-ink-soft">
              Drawers, modals and toasts all share the kit's show and hide commands.
            </p>
          </.component>
        </div>

        <div class="rounded-card border border-line bg-white p-6">
          <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">Progress</h2>
          <.component
            component_name="chelekom-stepper"
            site="Global"
            id="gallery-stepper"
            color="primary"
            class="mt-4"
          >
            <.component component_name="chelekom-stepper-section" site="Global" id="step-1">
              Write
            </.component>
            <.component component_name="chelekom-stepper-section" site="Global" id="step-2">
              Review
            </.component>
            <.component component_name="chelekom-stepper-section" site="Global" id="step-3">
              Publish
            </.component>
          </.component>
          <.component
            component_name="chelekom-progress"
            site="Global"
            id="gallery-progress"
            value={64}
            color="primary"
            class="mt-6"
          />
          <div class="mt-6 flex flex-wrap items-center gap-2">
            <.component component_name="chelekom-badge" site="Global" color="success">Live</.component>
            <.component component_name="chelekom-badge" site="Global" color="warning">Draft</.component>
            <.component component_name="chelekom-badge" site="Global" color="danger">Archived</.component>
          </div>
        </div>
      </section>

      <section class="mt-6 rounded-card border border-line bg-white p-6">
        <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">Paging</h2>
        <.component
          component_name="chelekom-pagination"
          site="Global"
          id="gallery-pager"
          total={40}
          active={1}
          color="primary"
          class="mt-4"
        />
      </section>

      <%!-- A TENANT HOOK AND A GLOBAL ONE, side by side. The difference is invisible in the markup
            and total in the browser: an unregistered hook name is an attribute and nothing else. --%>
      <section class="mt-6 grid gap-5 md:grid-cols-2">
        <div class="rounded-card border border-line bg-white p-6">
          <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">
            This site's own JS hook
          </h2>
          <p class="mt-2 text-[13px] text-ink-soft">
            Open the console and click. The hook row belongs to localhost alone.
          </p>
          <button
            type="button"
            id="gallery-console-logger"
            phx-hook="LocalhostConsoleLogger"
            class="mt-4 rounded-[9px] bg-accent px-4 py-2 text-[12px] font-bold text-white"
          >
            Log to console
          </button>
        </div>
        <div class="rounded-card border border-line bg-white p-6">
          <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">
            A global JS hook
          </h2>
          <p class="mt-2 text-[13px] text-ink-soft">
            The kit's clipboard hook is installed once for every site on the node.
          </p>
          <.component
            component_name="chelekom-clipboard"
            site="Global"
            id="gallery-copy"
            text="mix run priv/repo/dev_seeds.exs"
            class="mt-4 inline-block"
          >
            <:trigger>
              <span class="rounded-[9px] border border-line px-4 py-2 text-[12px] font-bold text-ink">
                Copy the seed command
              </span>
            </:trigger>
          </.component>
        </div>
      </section>

      <section class="mt-6 rounded-card border border-line bg-white p-6">
        <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">
          The rest of the dev pages
        </h2>
        <ul class="mt-4 grid gap-2 text-[13.5px] sm:grid-cols-2">
          <li :for={
            {label, path} <- [
              {"Pricing — tabs, table, accordion", "/pricing"},
              {"Messages — events, infos and flashes", "/messages"},
              {"Forms — two independent forms", "/forms"},
              {"Upload — a live file field", "/upload"},
              {"A :param page", "/features/multi-tenant"},
              {"A *rest page", "/handbook/getting-started/install"},
              {"Terms", "/terms"}
            ]
          }>
            <.link
              navigate={"/#{@query_params["lang"]}#{path}"}
              class="font-medium text-accent hover:underline"
            >
              {label}
            </.link>
          </li>
        </ul>
      </section>
      """,
      translations: %{"fa" => gallery_fa()}
    }
  end

  defp gallery_fa do
    %{
      name: "گالری",
      title: "گالری",
      description: "هر بخش تعاملی کیت در یک‌جا، و راه رسیدن به باقی صفحه‌های توسعه.",
      template: ~S"""
      <.component component_name="chelekom-breadcrumb" site="Global" id="gallery-crumbs">
        <:item link={"/fa"} title="خانه">خانه</:item>
        <:item title="گالری">گالری</:item>
      </.component>

      <section class="mt-5 rounded-card border border-line bg-white px-7 py-8">
        <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">
          کیت، در حال کار
        </h1>
        <p class="mt-2 max-w-[620px] text-[13.5px] leading-relaxed text-ink-soft">
          روی همه‌چیز کلیک کنید. یک مُدال، یک کشو، یک راهنمای شناور، یک نوتیفیکیشن، یک استپر و یک
          صفحه‌بندی — هرکدام مؤلفه‌ای برگرفته از پایگاه داده.
        </p>
      </section>

      <section class="mt-6 grid gap-5 md:grid-cols-2">
        <div class="rounded-card border border-line bg-white p-6">
          <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">
            لایه‌های روی صفحه
          </h2>
          <div class="mt-4 flex flex-wrap items-center gap-3">
            <button
              type="button"
              id="gallery-open-modal"
              phx-click={JS.exec("data-pb-open", to: "#gallery-modal")}
              class="rounded-[9px] bg-[#17161a] px-4 py-2 text-[12px] font-bold text-white"
            >
              باز کردن مُدال
            </button>
            <button
              type="button"
              id="gallery-open-drawer"
              phx-click={JS.exec("data-pb-open", to: "#gallery-drawer")}
              class="rounded-[9px] border border-line px-4 py-2 text-[12px] font-bold text-ink"
            >
              باز کردن کشو
            </button>
            <.component component_name="chelekom-tooltip" site="Global" id="gallery-tip" color="dark">
              <:trigger>
                <span class="rounded-[9px] border border-line px-4 py-2 text-[12px] font-bold text-ink">
                  نشانگر را نگه دارید
                </span>
              </:trigger>
              <:content>یک راهنمای شناور که کیت خودش آن را جای‌گذاری می‌کند.</:content>
            </.component>
          </div>

          <.component
            component_name="chelekom-modal"
            site="Global"
            id="gallery-modal"
            title="مُدالی از پایگاه داده"
            color="natural"
          >
            <p class="text-[13.5px] text-ink-soft">
              هیچ‌چیز اینجا به الیکسیر نوشته نشده. مؤلفه، استایل آن و همین متن، همگی ردیف‌هایی در
              پایگاه داده‌اند.
            </p>
          </.component>

          <.component
            component_name="chelekom-drawer"
            site="Global"
            id="gallery-drawer"
            title="یک کشو"
            position="right"
          >
            <p class="text-[13.5px] text-ink-soft">
              کشوها، مُدال‌ها و نوتیفیکیشن‌ها همگی از فرمان‌های نمایش و پنهان‌سازی یکسان کیت استفاده
              می‌کنند.
            </p>
          </.component>
        </div>

        <div class="rounded-card border border-line bg-white p-6">
          <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">پیشرفت</h2>
          <.component
            component_name="chelekom-stepper"
            site="Global"
            id="gallery-stepper"
            color="primary"
            class="mt-4"
          >
            <.component component_name="chelekom-stepper-section" site="Global" id="step-1">
              نوشتن
            </.component>
            <.component component_name="chelekom-stepper-section" site="Global" id="step-2">
              بازبینی
            </.component>
            <.component component_name="chelekom-stepper-section" site="Global" id="step-3">
              انتشار
            </.component>
          </.component>
          <.component
            component_name="chelekom-progress"
            site="Global"
            id="gallery-progress"
            value={64}
            color="primary"
            class="mt-6"
          />
          <div class="mt-6 flex flex-wrap items-center gap-2">
            <.component component_name="chelekom-badge" site="Global" color="success">فعال</.component>
            <.component component_name="chelekom-badge" site="Global" color="warning">
              پیش‌نویس
            </.component>
            <.component component_name="chelekom-badge" site="Global" color="danger">
              بایگانی‌شده
            </.component>
          </div>
        </div>
      </section>

      <section class="mt-6 rounded-card border border-line bg-white p-6">
        <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">صفحه‌بندی</h2>
        <.component
          component_name="chelekom-pagination"
          site="Global"
          id="gallery-pager"
          total={40}
          active={1}
          color="primary"
          class="mt-4"
        />
      </section>

      <section class="mt-6 grid gap-5 md:grid-cols-2">
        <div class="rounded-card border border-line bg-white p-6">
          <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">
            هوک جاوااسکریپت اختصاصی این سایت
          </h2>
          <p class="mt-2 text-[13px] text-ink-soft">
            کنسول را باز کنید و کلیک کنید. این هوک فقط متعلق به localhost است.
          </p>
          <button
            type="button"
            id="gallery-console-logger"
            phx-hook="LocalhostConsoleLogger"
            class="mt-4 rounded-[9px] bg-accent px-4 py-2 text-[12px] font-bold text-white"
          >
            ثبت در کنسول
          </button>
        </div>
        <div class="rounded-card border border-line bg-white p-6">
          <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">
            یک هوک جاوااسکریپت سراسری
          </h2>
          <p class="mt-2 text-[13px] text-ink-soft">
            هوک کلیپ‌بورد کیت یک‌بار برای همهٔ سایت‌های این نود نصب می‌شود.
          </p>
          <.component
            component_name="chelekom-clipboard"
            site="Global"
            id="gallery-copy"
            text="mix run priv/repo/dev_seeds.exs"
            class="mt-4 inline-block"
          >
            <:trigger>
              <span class="rounded-[9px] border border-line px-4 py-2 text-[12px] font-bold text-ink">
                کپی کردن دستور seed
              </span>
            </:trigger>
          </.component>
        </div>
      </section>

      <section class="mt-6 rounded-card border border-line bg-white p-6">
        <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">
          باقی صفحه‌های توسعه
        </h2>
        <ul class="mt-4 grid gap-2 text-[13.5px] sm:grid-cols-2">
          <li :for={
            {label, path} <- [
              {"قیمت‌گذاری — زبانه، جدول، آکاردئون", "/pricing"},
              {"پیام‌ها — رویدادها، اطلاعیه‌ها و پیام‌های فوری", "/messages"},
              {"فرم‌ها — دو فرم مستقل", "/forms"},
              {"بارگذاری — فیلد آپلود زنده", "/upload"},
              {"یک صفحهٔ :param", "/features/multi-tenant"},
              {"یک صفحهٔ *rest", "/handbook/getting-started/install"},
              {"شرایط استفاده", "/terms"}
            ]
          }>
            <.link
              navigate={"/fa#{path}"}
              class="font-medium text-accent hover:underline"
            >
              {label}
            </.link>
          </li>
        </ul>
      </section>
      """
    }
  end

  # EVERY WAY A PAGE CAN SAY SOMETHING, on one page: a click that flashes without reaching a
  # handler (`pb:say`), a click that does reach one (`demo_count`), and a message the page sends
  # itself and answers in an info handler (`:demo_tick`). The layout renders the flash region, so
  # the compiled page adds none of its own.
  defp messages do
    %{
      name: "Messages",
      title: "Messages",
      path: "/:lang/messages",
      section: "main",
      description: "Page events, page infos, pb:say and a toast the page opens and closes.",
      format: :heex,
      events: [
        %{
          name: "demo_count",
          code: ~S"""
          count = (socket.assigns[:demo_count] || 0) + 1
          Process.send_after(self(), :demo_tick, 1_500)
          {:noreply, assign(socket, :demo_count, count)}
          """
        }
      ],
      infos: [
        %{
          name: ":demo_tick",
          code: ~S"""
          {:noreply, put_flash(socket, :info, "Counted #{socket.assigns[:demo_count] || 0} so far.")}
          """
        }
      ],
      template: ~S"""
      <section class="rounded-card border border-line bg-white px-7 py-8">
        <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">Messages</h1>
        <p class="mt-2 max-w-[620px] text-[13.5px] leading-relaxed text-ink-soft">
          Three ways a page talks to whoever is reading it. The banner they appear in is the
          layout's, which is why no page needs one of its own.
        </p>
      </section>

      <section class="mt-6 grid gap-5 md:grid-cols-3">
        <div class="rounded-card border border-line bg-white p-6">
          <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">A flash</h2>
          <p class="mt-2 text-[13px] text-ink-soft">
            No handler anywhere — the click carries the words with it.
          </p>
          <button
            type="button"
            id="say-something-good"
            phx-click={
              JS.push("pb:say", value: %{"kind" => "info", "message" => "Said from the page itself."})
            }
            class="mt-4 rounded-[9px] bg-[#17161a] px-4 py-2 text-[12px] font-bold text-white"
          >
            Say something good
          </button>
        </div>

        <div class="rounded-card border border-line bg-white p-6">
          <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">An event</h2>
          <p class="mt-2 text-[13px] text-ink-soft">
            The page's own `demo_count` handler counts, then asks itself to speak in a second and
            a half.
          </p>
          <button
            type="button"
            id="count-me"
            phx-click="demo_count"
            class="mt-4 rounded-[9px] bg-accent px-4 py-2 text-[12px] font-bold text-white"
          >
            Count me ({assigns[:demo_count] || 0})
          </button>
        </div>

        <div class="rounded-card border border-line bg-white p-6">
          <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">A toast</h2>
          <p class="mt-2 text-[13px] text-ink-soft">
            Shown and hidden in the browser, with no round trip at all.
          </p>
          <div class="mt-4 flex flex-wrap gap-2">
            <button
              type="button"
              id="open-the-toast"
              phx-click={JS.show(to: "#demo-toast")}
              class="rounded-[9px] border border-line px-4 py-2 text-[12px] font-bold text-ink"
            >
              Open the toast
            </button>
            <button
              type="button"
              id="close-the-toast"
              phx-click={JS.hide(to: "#demo-toast")}
              class="rounded-[9px] border border-line px-4 py-2 text-[12px] font-bold text-ink"
            >
              Close it
            </button>
          </div>
        </div>
      </section>

      <.component
        component_name="chelekom-toast"
        site="Global"
        id="demo-toast"
        color="success"
        class="hidden"
      >
        This toast is a kit component the page shows and hides itself.
      </.component>
      """,
      translations: %{"fa" => messages_fa()}
    }
  end

  defp messages_fa do
    %{
      name: "پیام‌ها",
      title: "پیام‌ها",
      description:
        "رویدادهای صفحه، اطلاعیه‌های صفحه، pb:say و نوتیفیکیشنی که خود صفحه باز و بسته می‌کند.",
      template: ~S"""
      <section class="rounded-card border border-line bg-white px-7 py-8">
        <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">پیام‌ها</h1>
        <p class="mt-2 max-w-[620px] text-[13.5px] leading-relaxed text-ink-soft">
          سه راه که یک صفحه با خوانندهٔ خودش حرف می‌زند. نواری که این پیام‌ها در آن ظاهر می‌شوند
          متعلق به چیدمان است، به همین دلیل هیچ صفحه‌ای نیازی به نوار اختصاصی خودش ندارد.
        </p>
      </section>

      <section class="mt-6 grid gap-5 md:grid-cols-3">
        <div class="rounded-card border border-line bg-white p-6">
          <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">
            یک پیام فوری
          </h2>
          <p class="mt-2 text-[13px] text-ink-soft">
            اینجا هیچ هندلری وجود ندارد — خودِ کلیک پیام را با خود می‌برد.
          </p>
          <button
            type="button"
            id="say-something-good"
            phx-click={
              JS.push("pb:say", value: %{"kind" => "info", "message" => "این پیام از خود صفحه گفته شده است."})
            }
            class="mt-4 rounded-[9px] bg-[#17161a] px-4 py-2 text-[12px] font-bold text-white"
          >
            یک حرف خوب بزن
          </button>
        </div>

        <div class="rounded-card border border-line bg-white p-6">
          <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">یک رویداد</h2>
          <p class="mt-2 text-[13px] text-ink-soft">
            هندلر اختصاصی `demo_count` این صفحه می‌شمارد، سپس از خودش می‌خواهد یک و نیم ثانیه بعد
            حرف بزند.
          </p>
          <button
            type="button"
            id="count-me"
            phx-click="demo_count"
            class="mt-4 rounded-[9px] bg-accent px-4 py-2 text-[12px] font-bold text-white"
          >
            من را بشمار ({assigns[:demo_count] || 0})
          </button>
        </div>

        <div class="rounded-card border border-line bg-white p-6">
          <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">
            یک نوتیفیکیشن
          </h2>
          <p class="mt-2 text-[13px] text-ink-soft">
            کاملاً در مرورگر نمایش و پنهان می‌شود، بدون هیچ رفت‌وبرگشتی به سرور.
          </p>
          <div class="mt-4 flex flex-wrap gap-2">
            <button
              type="button"
              id="open-the-toast"
              phx-click={JS.show(to: "#demo-toast")}
              class="rounded-[9px] border border-line px-4 py-2 text-[12px] font-bold text-ink"
            >
              باز کردن نوتیفیکیشن
            </button>
            <button
              type="button"
              id="close-the-toast"
              phx-click={JS.hide(to: "#demo-toast")}
              class="rounded-[9px] border border-line px-4 py-2 text-[12px] font-bold text-ink"
            >
              بستن آن
            </button>
          </div>
        </div>
      </section>

      <.component
        component_name="chelekom-toast"
        site="Global"
        id="demo-toast"
        color="success"
        class="hidden"
      >
        این نوتیفیکیشن یک مؤلفهٔ کیت است که خودِ صفحه آن را نمایش و پنهان می‌کند.
      </.component>
      """
    }
  end

  # A PAGE TO DEVELOP THE FORM MACHINERY AGAINST, and two of them deliberately: one form is not
  # enough to catch the bug that matters, which is one form's typing marking the other's fields.
  defp forms do
    %{
      name: "Forms",
      title: "Forms",
      path: "/:lang/forms",
      section: "main",
      description: "Two independent forms, for exercising the form machinery in development.",
      format: :heex,
      template: ~S"""
      <section class="rounded-card border border-line bg-white px-7 py-8">
        <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">Forms</h1>
        <p class="mt-2 max-w-[620px] text-[13.5px] leading-relaxed text-ink-soft">
          Two forms on one page, each with its own name, its own events and its own errors. Typing
          in one must never mark the other.
        </p>
      </section>

      <.form
        :let={f}
        id="signup-form"
        as={:signup}
        for={assigns[:signup_form]}
        phx-change="signup_validate"
        phx-submit="signup_submit"
        data-success="Signed up."
        class="mt-6 space-y-5 rounded-card border border-line bg-white p-7"
      >
        <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">Sign up</h2>
        <.component
          component_name="chelekom-text-field"
          site="Global"
          id="signup-full-name"
          field={f[:full_name]}
          label="Full name"
          required
          minlength="2"
          maxlength="80"
        />
        <.component
          component_name="chelekom-email-field"
          site="Global"
          id="signup-email"
          field={f[:email]}
          label="Email"
          required
          data-format="email"
        />
        <.component
          component_name="chelekom-number-field"
          site="Global"
          id="signup-age"
          field={f[:age]}
          label="Age"
          min="13"
          max="120"
        />
        <.component
          component_name="chelekom-url-field"
          site="Global"
          id="signup-site"
          field={f[:site]}
          label="Website"
          data-format="url"
        />
        <.component
          component_name="chelekom-native-select"
          site="Global"
          id="signup-plan"
          field={f[:plan]}
          label="Plan"
          required
        >
          <:option :for={plan <- ["Free", "Team", "Agency"]} value={plan}>{plan}</:option>
        </.component>
        <.component
          component_name="chelekom-checkbox-field"
          site="Global"
          id="signup-terms"
          field={f[:terms]}
          label="I accept the terms"
          required
        />
        <button
          type="submit"
          class="rounded-[9px] bg-[#17161a] px-4 py-2 text-[12px] font-bold text-white"
        >
          Create account
        </button>
      </.form>

      <.form
        :let={f}
        id="feedback-form"
        as={:feedback}
        for={assigns[:feedback_form]}
        phx-change="feedback_validate"
        phx-submit="feedback_submit"
        data-success="Thanks for the feedback."
        class="mt-6 space-y-5 rounded-card border border-line bg-white p-7"
      >
        <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">Feedback</h2>
        <fieldset class="space-y-4 rounded-[12px] border border-line p-5">
          <legend class="px-1 text-[12.5px] font-bold text-ink">About you</legend>
          <.component
            component_name="chelekom-text-field"
            site="Global"
            id="feedback-name"
            field={f[:name]}
            label="Name"
            minlength="2"
          />
          <.component
            component_name="chelekom-email-field"
            site="Global"
            id="feedback-reply-to"
            field={f[:reply_to]}
            label="Reply to"
            data-format="email"
          />
        </fieldset>
        <.component
          component_name="chelekom-text-field"
          site="Global"
          id="feedback-subject"
          field={f[:subject]}
          label="Subject"
          required
          minlength="3"
        />
        <.component
          component_name="chelekom-textarea-field"
          site="Global"
          id="feedback-body"
          field={f[:body]}
          label="Message"
          required
          minlength="10"
          maxlength="2000"
        />
        <button
          type="submit"
          class="rounded-[9px] bg-accent px-4 py-2 text-[12px] font-bold text-white"
        >
          Send feedback
        </button>
      </.form>
      """,
      translations: %{"fa" => forms_fa()}
    }
  end

  defp forms_fa do
    %{
      name: "فرم‌ها",
      title: "فرم‌ها",
      description: "دو فرم مستقل، برای آزمودن سازوکار فرم در محیط توسعه.",
      template: ~S"""
      <section class="rounded-card border border-line bg-white px-7 py-8">
        <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">فرم‌ها</h1>
        <p class="mt-2 max-w-[620px] text-[13.5px] leading-relaxed text-ink-soft">
          دو فرم روی یک صفحه، هرکدام با نام، رویدادها و خطاهای اختصاصی خودش. تایپ در یکی نباید هرگز
          دیگری را نشان‌دار کند.
        </p>
      </section>

      <.form
        :let={f}
        id="signup-form"
        as={:signup}
        for={assigns[:signup_form]}
        phx-change="signup_validate"
        phx-submit="signup_submit"
        data-success="ثبت‌نام انجام شد."
        class="mt-6 space-y-5 rounded-card border border-line bg-white p-7"
      >
        <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">ثبت‌نام</h2>
        <.component
          component_name="chelekom-text-field"
          site="Global"
          id="signup-full-name"
          field={f[:full_name]}
          label="نام کامل"
          required
          minlength="2"
          maxlength="80"
        />
        <.component
          component_name="chelekom-email-field"
          site="Global"
          id="signup-email"
          field={f[:email]}
          label="ایمیل"
          required
          data-format="email"
        />
        <.component
          component_name="chelekom-number-field"
          site="Global"
          id="signup-age"
          field={f[:age]}
          label="سن"
          min="13"
          max="120"
        />
        <.component
          component_name="chelekom-url-field"
          site="Global"
          id="signup-site"
          field={f[:site]}
          label="وب‌سایت"
          data-format="url"
        />
        <.component
          component_name="chelekom-native-select"
          site="Global"
          id="signup-plan"
          field={f[:plan]}
          label="طرح"
          required
        >
          <:option :for={plan <- ["رایگان", "تیمی", "آژانس"]} value={plan}>{plan}</:option>
        </.component>
        <.component
          component_name="chelekom-checkbox-field"
          site="Global"
          id="signup-terms"
          field={f[:terms]}
          label="قوانین را می‌پذیرم"
          required
        />
        <button
          type="submit"
          class="rounded-[9px] bg-[#17161a] px-4 py-2 text-[12px] font-bold text-white"
        >
          ساخت حساب
        </button>
      </.form>

      <.form
        :let={f}
        id="feedback-form"
        as={:feedback}
        for={assigns[:feedback_form]}
        phx-change="feedback_validate"
        phx-submit="feedback_submit"
        data-success="بابت بازخورد شما سپاسگزاریم."
        class="mt-6 space-y-5 rounded-card border border-line bg-white p-7"
      >
        <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">بازخورد</h2>
        <fieldset class="space-y-4 rounded-[12px] border border-line p-5">
          <legend class="px-1 text-[12.5px] font-bold text-ink">دربارهٔ شما</legend>
          <.component
            component_name="chelekom-text-field"
            site="Global"
            id="feedback-name"
            field={f[:name]}
            label="نام"
            minlength="2"
          />
          <.component
            component_name="chelekom-email-field"
            site="Global"
            id="feedback-reply-to"
            field={f[:reply_to]}
            label="ایمیل پاسخ"
            data-format="email"
          />
        </fieldset>
        <.component
          component_name="chelekom-text-field"
          site="Global"
          id="feedback-subject"
          field={f[:subject]}
          label="موضوع"
          required
          minlength="3"
        />
        <.component
          component_name="chelekom-textarea-field"
          site="Global"
          id="feedback-body"
          field={f[:body]}
          label="پیام"
          required
          minlength="10"
          maxlength="2000"
        />
        <button
          type="submit"
          class="rounded-[9px] bg-accent px-4 py-2 text-[12px] font-bold text-white"
        >
          ارسال بازخورد
        </button>
      </.form>
      """
    }
  end

  defp upload do
    %{
      name: "Upload",
      title: "Upload",
      path: "/:lang/upload",
      section: "main",
      description: "A live file field, declared by the page and consumed by its form.",
      format: :heex,
      uploads: [%{"name" => "attachment", "accept" => "image/*,.pdf", "max_entries" => 2}],
      template: ~S"""
      <section class="rounded-card border border-line bg-white px-7 py-8">
        <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">Upload</h1>
        <p class="mt-2 max-w-[620px] text-[13.5px] leading-relaxed text-ink-soft">
          The page declares the upload and the kit's file field is handed it. Submitting consumes
          the files and the descriptors travel with the rest of the values.
        </p>
      </section>

      <.form
        :let={f}
        id="attachment-form"
        as={:attachment}
        for={assigns[:attachment_form]}
        phx-change="attachment_validate"
        phx-submit="attachment_submit"
        data-success="Uploaded."
        class="mt-6 space-y-5 rounded-card border border-line bg-white p-7"
      >
        <.component
          component_name="chelekom-text-field"
          site="Global"
          id="attachment-note"
          field={f[:note]}
          label="What is this?"
          required
          minlength="3"
        />
        <.component
          component_name="chelekom-file-field"
          site="Global"
          id="attachment-field"
          live
          upload={@uploads.attachment}
          label="Pick a picture or a PDF"
        />
        <button
          type="submit"
          class="rounded-[9px] bg-[#17161a] px-4 py-2 text-[12px] font-bold text-white"
        >
          Send it
        </button>
      </.form>
      """,
      translations: %{"fa" => upload_fa()}
    }
  end

  defp upload_fa do
    %{
      name: "بارگذاری",
      title: "بارگذاری",
      description: "یک فیلد آپلود زنده، اعلام‌شده توسط خود صفحه و مصرف‌شده در فرمش.",
      template: ~S"""
      <section class="rounded-card border border-line bg-white px-7 py-8">
        <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">بارگذاری</h1>
        <p class="mt-2 max-w-[620px] text-[13.5px] leading-relaxed text-ink-soft">
          صفحه آپلود را اعلام می‌کند و فیلد فایل کیت به آن سپرده می‌شود. با ارسال فرم، فایل‌ها مصرف
          می‌شوند و توصیف‌گر آن‌ها همراه بقیهٔ مقادیر می‌رود.
        </p>
      </section>

      <.form
        :let={f}
        id="attachment-form"
        as={:attachment}
        for={assigns[:attachment_form]}
        phx-change="attachment_validate"
        phx-submit="attachment_submit"
        data-success="بارگذاری شد."
        class="mt-6 space-y-5 rounded-card border border-line bg-white p-7"
      >
        <.component
          component_name="chelekom-text-field"
          site="Global"
          id="attachment-note"
          field={f[:note]}
          label="این چیست؟"
          required
          minlength="3"
        />
        <.component
          component_name="chelekom-file-field"
          site="Global"
          id="attachment-field"
          live
          upload={@uploads.attachment}
          label="یک عکس یا PDF انتخاب کنید"
        />
        <button
          type="submit"
          class="rounded-[9px] bg-[#17161a] px-4 py-2 text-[12px] font-bold text-white"
        >
          ارسال کن
        </button>
      </.form>
      """
    }
  end

  defp feature do
    %{
      name: "Feature",
      title: "Feature",
      path: "/:lang/features/:slug",
      section: "main",
      description: "One page for every feature — a :param capture read straight off the address.",
      format: :heex,
      template: ~S"""
      <article class="rounded-card border border-line bg-white px-7 py-8">
        <p class="text-[12px] font-bold uppercase tracking-[0.18em] text-accent">Feature</p>
        <h1 id="feature-slug" class="mt-3 font-display text-[30px] font-bold tracking-[-0.03em] text-ink">
          {@query_params["slug"]}
        </h1>
        <p class="mt-3 max-w-[620px] text-[13.5px] leading-relaxed text-ink-soft">
          This one page answers every address under <code>/features/</code>. The captured segment
          arrives in <code>@query_params</code> under its own name, exactly as a query string would.
        </p>
        <div class="mt-6 flex flex-wrap gap-2 text-[13px]">
          <.link
            :for={slug <- ["multi-tenant", "page-builder", "runtime-css"]}
            navigate={"/#{@query_params["lang"]}/features/#{slug}"}
            class="rounded-[9px] border border-line px-3 py-1.5 font-medium text-ink hover:text-accent"
          >
            {slug}
          </.link>
        </div>
      </article>
      """,
      translations: %{"fa" => feature_fa()}
    }
  end

  defp feature_fa do
    %{
      name: "ویژگی",
      title: "ویژگی",
      description: "یک صفحه برای همهٔ ویژگی‌ها — گرفتن پارامتر :param مستقیماً از آدرس.",
      template: ~S"""
      <article class="rounded-card border border-line bg-white px-7 py-8">
        <p class="text-[12px] font-bold uppercase tracking-[0.18em] text-accent">ویژگی</p>
        <h1 id="feature-slug" class="mt-3 font-display text-[30px] font-bold tracking-[-0.03em] text-ink">
          {@query_params["slug"]}
        </h1>
        <p class="mt-3 max-w-[620px] text-[13.5px] leading-relaxed text-ink-soft">
          همین یک صفحه به هر آدرسی زیر <code>/features/</code> پاسخ می‌دهد. بخش گرفته‌شده از آدرس،
          دقیقاً مثل یک پارامتر کوئری، زیر نام خودش در <code>@query_params</code> در دسترس است.
        </p>
        <div class="mt-6 flex flex-wrap gap-2 text-[13px]">
          <.link
            :for={slug <- ["multi-tenant", "page-builder", "runtime-css"]}
            navigate={"/fa/features/#{slug}"}
            class="rounded-[9px] border border-line px-3 py-1.5 font-medium text-ink hover:text-accent"
          >
            {slug}
          </.link>
        </div>
      </article>
      """
    }
  end

  defp handbook do
    %{
      name: "Handbook",
      title: "Handbook",
      path: "/:lang/handbook/*rest",
      section: "main",
      description: "Everything under one address — a *rest capture, however deep it goes.",
      format: :heex,
      template: ~S"""
      <article class="rounded-card border border-line bg-white px-7 py-8">
        <p class="text-[12px] font-bold uppercase tracking-[0.18em] text-accent">Handbook</p>
        <h1 id="handbook-rest" class="mt-3 font-display text-[26px] font-bold tracking-[-0.03em] text-ink">
          {@query_params["rest"]}
        </h1>
        <p class="mt-3 max-w-[620px] text-[13.5px] leading-relaxed text-ink-soft">
          A rest capture takes the whole tail of the address, so one row answers a tree of them.
        </p>
        <ul class="mt-6 space-y-2 text-[13px]">
          <li :for={rest <- ["getting-started/install", "getting-started/first-page", "recipes/seo"]}>
            <.link
              navigate={"/#{@query_params["lang"]}/handbook/#{rest}"}
              class="font-medium text-accent hover:underline"
            >
              /handbook/{rest}
            </.link>
          </li>
        </ul>
      </article>
      """,
      translations: %{"fa" => handbook_fa()}
    }
  end

  defp handbook_fa do
    %{
      name: "کتابچهٔ راهنما",
      title: "کتابچهٔ راهنما",
      description: "همه‌چیز زیر یک آدرس — یک گرفتنِ *rest، به هر عمقی که باشد.",
      template: ~S"""
      <article class="rounded-card border border-line bg-white px-7 py-8">
        <p class="text-[12px] font-bold uppercase tracking-[0.18em] text-accent">کتابچهٔ راهنما</p>
        <h1 id="handbook-rest" class="mt-3 font-display text-[26px] font-bold tracking-[-0.03em] text-ink">
          {@query_params["rest"]}
        </h1>
        <p class="mt-3 max-w-[620px] text-[13.5px] leading-relaxed text-ink-soft">
          یک گرفتنِ rest کل دنبالهٔ آدرس را می‌گیرد، پس یک ردیف به یک درخت کامل از آن‌ها پاسخ می‌دهد.
        </p>
        <ul class="mt-6 space-y-2 text-[13px]">
          <li :for={rest <- ["getting-started/install", "getting-started/first-page", "recipes/seo"]}>
            <.link
              navigate={"/fa/handbook/#{rest}"}
              class="font-medium text-accent hover:underline"
            >
              /handbook/{rest}
            </.link>
          </li>
        </ul>
      </article>
      """
    }
  end

  defp terms do
    %{
      name: "Terms",
      title: "Terms",
      path: "/:lang/terms",
      section: "main",
      description: "The other legal page, beside the starter site's privacy one.",
      format: :heex,
      template: ~S"""
      <article class="rounded-card border border-line bg-white p-8">
        <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">Terms</h1>
        <p class="mt-4 text-[15px] leading-relaxed text-ink-soft">
          Placeholder text for the page every site needs and nobody reads. Say what you promise and
          what you do not.
        </p>
        <p class="mt-8 text-[13px]">
          <.link navigate={"/#{@query_params["lang"]}/privacy"} class="font-bold text-accent">
            Privacy →
          </.link>
        </p>
      </article>
      """,
      translations: %{"fa" => terms_fa()}
    }
  end

  defp terms_fa do
    %{
      name: "شرایط استفاده",
      title: "شرایط استفاده",
      description: "صفحهٔ حقوقیِ دیگر، در کنار صفحهٔ حریم خصوصیِ سایت آغازین.",
      template: ~S"""
      <article class="rounded-card border border-line bg-white p-8">
        <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">شرایط استفاده</h1>
        <p class="mt-4 text-[15px] leading-relaxed text-ink-soft">
          متن جای‌نگه‌دار برای صفحه‌ای که هر سایتی به آن نیاز دارد و کسی آن را نمی‌خواند. بگویید چه
          چیزی را تعهد می‌کنید و چه چیزی را نه.
        </p>
        <p class="mt-8 text-[13px]">
          <.link navigate={"/fa/privacy"} class="font-bold text-accent">
            حریم خصوصی ←
          </.link>
        </p>
      </article>
      """
    }
  end

  # A PAGE THAT IS SWITCHED OFF answers the site's own 404 rather than disappearing from the admin,
  # and a developer needs one of each to tell the two apart.
  defp coming_soon do
    %{
      name: "Coming soon",
      title: "Coming soon",
      path: "/:lang/coming-soon",
      section: "main",
      description: "Inactive on purpose — it must answer this site's 404.",
      format: :heex,
      active: false,
      template: ~S"""
      <article class="rounded-card border border-line bg-white p-8">
        <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">Coming soon</h1>
        <p class="mt-4 text-[15px] text-ink-soft">
          If you are reading this, the page was published. It is seeded switched off.
        </p>
      </article>
      """,
      translations: %{"fa" => coming_soon_fa()}
    }
  end

  defp coming_soon_fa do
    %{
      name: "به‌زودی",
      title: "به‌زودی",
      description: "از عمد غیرفعال — باید ۴۰۴ همین سایت را نشان دهد.",
      template: ~S"""
      <article class="rounded-card border border-line bg-white p-8">
        <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">به‌زودی</h1>
        <p class="mt-4 text-[15px] text-ink-soft">
          اگر این متن را می‌خوانید، یعنی صفحه منتشر شده است. این صفحه از ابتدا و به‌عمد غیرفعال
          ایجاد شده است.
        </p>
      </article>
      """
    }
  end

  # A PAGE OUTSIDE `/:lang` MODE. Every other page on every seeded site is written as `/:lang/...`,
  # answering whatever languages its site names, so nothing here had ever exercised the other half of
  # `MishkaCmsCore.Runtime.Languages` — a literal path with no `lang` capture at all, in one language
  # only, offered no translation and not swapped by the language switcher. One is enough to develop
  # against; `MishkaCmsCore.Dev.Seeds.seed_page_translations/3` reads `Languages.captures?/1` on this
  # page's path the same way the runtime does, and leaves it alone for exactly that reason.
  defp no_language do
    %{
      name: "No language",
      title: "No language",
      path: "/no-lang",
      section: "main",
      description: "A literal address outside /:lang mode — no language capture, no translation.",
      format: :heex,
      template: ~S"""
      <article class="rounded-card border border-line bg-white p-8">
        <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">No language</h1>
        <p class="mt-4 text-[15px] leading-relaxed text-ink-soft">
          Every other page here answers at <code>/:lang/...</code>. This one answers at
          <code>/no-lang</code> only — no language capture, so it is served in whatever its own
          language column says and offered no translation.
        </p>
      </article>
      """
    }
  end
end
