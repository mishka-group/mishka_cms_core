<div align="center">

[![Buy Me a Coffee](https://img.shields.io/badge/Buy_Me_a_Coffee-mishkagroup-ffdd00?style=flat-square&logo=buy-me-a-coffee&logoColor=black)](https://www.buymeacoffee.com/mishkagroup)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub_Sponsors-mishka--group-ea4aaa?style=flat-square&logo=github)](https://github.com/sponsors/mishka-group)

# Mishka CMS Core

**The engine of [Mishka CMS](https://mishka.tools/cms): a multi-tenant runtime, accounts and an admin dashboard for Elixir and Phoenix LiveView.**

[Website](https://mishka.tools/cms) · [Documentation](https://mishka.tools/cms/docs) · [Extensions](https://mishka.tools/cms#extensions) · [Hire us](https://mishka.tools/hire-us)

</div>

## 📖 What is Mishka CMS Core?

`mishka_cms_core` is an Elixir library built on Ash and Phoenix LiveView. It holds the resources and the runtime that turn database rows into running websites: sites, pages, layouts, components, error pages, stylesheets, JavaScript hooks, media, translations, redirects and settings. It also holds user accounts, permissions, notifications, the admin dashboard screens and the document layer every authored template goes through. The visual page builder is a separate package, [mishka_cms_builder](https://github.com/mishka-group/mishka_cms_builder), which a host adds when it wants the editor.

The package has no endpoint, router or repo of its own. The host application supplies them through the config shown under Getting started.

## 🧩 Part of Mishka CMS

`mishka_cms_core` is the core of [Mishka CMS](https://mishka.tools/cms), an open source real-time CMS. The [mishka_cms](https://github.com/mishka-group/mishka_cms) application runs it, and the visual page builder ([mishka_cms_builder](https://github.com/mishka-group/mishka_cms_builder)), the [blog extension](https://mishka.tools/cms/extensions/blog) ([mishka_blog](https://github.com/mishka-group/mishka_blog)) and the [documentation extension](https://mishka.tools/cms/extensions/documentation) ([mishka_document](https://github.com/mishka-group/mishka_document)) are built on it.

## ✨ Features

- Multi-tenant sites. A site has its own domain, languages, settings and content, and a request is matched to its site by host. A site can serve Phoenix LiveView pages, the JSON:API, or both. See [multi-tenant sites](https://mishka.tools/cms#tenant).
- A runtime compiler. Pages, layouts, components and error pages become modules at runtime from HEEx, EEx or Markdown. Each site gets one stylesheet built with Tailwind CSS v4 and one script bundle that includes its JavaScript hooks.
- A document layer, `MishkaCmsCore.Runtime.Authoring`, for every template an author writes: the HEEx tree and its edit operations, the checks a template must pass before it compiles, page forms, and the fields and elements an editor offers. The admin's code editor writes through it, and so does the visual page builder of [mishka_cms_builder](https://github.com/mishka-group/mishka_cms_builder), with its canvas, inspector, design tokens, presets, snippets, undo history, review comments and a view of who else is editing the same page.
- Autosaved drafts that publish on demand, version history with restore, and archiving instead of deletion.
- Elixir written by an author in a page can be switched off for a whole deployment (`PAGE_CODE=off` in Mishka CMS). With a `CODE_SIGNING_KEY` set, Elixir that did not come through the CMS does not run.
- A media library with categories, and redirect rules for addresses that moved (301, 302, 307 and 308).
- Translation keys for templates (`t("key")`), registered when a template is saved and translated per language.
- A settings registry where extensions and plugins declare their own settings. A setting has a global value and a per-site override, and secret settings are stored sealed.
- Several languages per site. A page can have one edition per language with `hreflang` links, and the site chooses whether the primary language has a URL prefix. Dates, numbers, lists and language names come from Unicode CLDR through the `localize` library.
- Accounts on AshAuthentication: password sign-in, emailed sign-in links, optional two-step sign-in with an authenticator app and recovery codes, rate limits per IP address and per account, and an admin switch that closes sign-in or registration for a site.
- A captcha for the sign-in forms from Cloudflare Turnstile, Google reCAPTCHA (v2 or v3) or hCaptcha, chosen per site.
- Email through a provider each site picks. Resend is included, and a local mailbox is available in development.
- SEO from the page's own fields: title, description, canonical address, Open Graph and Twitter tags, a `sitemap.xml` and `robots.txt` for each site, and 1200 x 630 share cards drawn with libvips in a separate OS process.
- Notifications for each user, delivered live, and an activity log that picks up the versioned resources of every configured Ash domain on its own.
- A home board of dashboard widgets and an admin sidebar that extensions add to.
- JSON:API routes for the runtime and account resources, for master and tenant users, including version listing and restore.
- The Chelekom UI kit, which the install wizard downloads from Chelekom's newest release into `priv/cms_ui_kits`.

## 🔐 Permissions

An admin permission is a plain string, `admin:<surface>:<area>`. The surface is `dashboard` for the admin screens and the data they use, or `api` for the JSON:API. Examples are `admin:dashboard:runtime:page` and `admin:api:blog:post`. A `*` as the whole last segment covers everything below it (`admin:dashboard:*`, `admin:*`), and `*` alone covers everything. A master is a user that belongs to no site.

## 🔌 Extending it

Every create, update and destroy action on a resource that lists `MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook` fires a [Mishka Installer](https://mishka.tools/installer) event named `<app>:<resource>:after_<action>`, such as `blog:comment:after_create`, and a create or update also fires `<app>:<resource>:after_save`. A plugin listens like this:

```elixir
use MishkaInstaller.Event.Hook,
  event: MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook.event_name(MishkaBlog.BlogPost, :publish)
```

An extension adds routes with the `MishkaCmsCore.ExtensionRouter` behaviour, adds sidebar entries on the `sidebar:menus` event, and appears in the install wizard by subscribing to `installer:extension:install`.

An editor is an extension too. [mishka_cms_builder](https://github.com/mishka-group/mishka_cms_builder) adds its pages that way, answers `runtime:document:editor_url` with the address of its editor (the admin shows an editor button only when one answers), writes the snippets of an extension's setup on `runtime:provision:snippets`, adds its history to the activity log on `activity:sources` and registers its settings on `settings:register`. A plugin for the editor listens on the `builder:*` events of `MishkaCmsCore.Builder.Events`, which stay in the core so an extension can ship one without depending on the editor.

## 🚀 Getting started

Add it from Hex:

```elixir
{:mishka_cms_core, "~> 0.0.2"}
```

[Mishka CMS](https://github.com/mishka-group/mishka_cms) loads it from `__extensions/mishka_cms_core` instead when that folder exists.

Mishka CMS also tells the package which repo, endpoint and web module to use, and which extensions are installed:

```elixir
config :mishka_cms_core,
  repo: MishkaCms.Repo,
  endpoint: MishkaCmsWeb.Endpoint,
  host_app: :mishka_cms,
  web_module: MishkaCmsWeb,
  core_components: MishkaCmsWeb.CoreComponents

config :mishka_cms_core,
  extensions: [MishkaCmsCoreWeb, MishkaBlogWeb, MishkaDocumentWeb, MishkaCmsBuilderWeb]

config :mishka_cms,
  ash_domains: [
    MishkaCmsBuilder,
    MishkaDocument,
    MishkaBlog,
    MishkaCmsCore.Runtime,
    MishkaCmsCore.Accounts,
    MishkaCmsCore.Notify,
    MishkaCmsCore.Mail
  ]
```

`MishkaCmsBuilderWeb` and `MishkaCmsBuilder` are the visual page builder's; leave them out to run without it.

To run it, follow [Getting started in mishka_cms](https://github.com/mishka-group/mishka_cms#-getting-started). To work on the engine, check out the packages side by side under `__extensions/` in a `mishka_cms` clone, and Mishka CMS uses those folders:

```bash
git clone https://github.com/mishka-group/mishka_cms.git
cd mishka_cms
git clone https://github.com/mishka-group/mishka_gervaz.git __extensions/mishka_gervaz
git clone https://github.com/mishka-group/mishka_cms_core.git __extensions/mishka_cms_core
git clone https://github.com/mishka-group/mishka_cms_builder.git __extensions/mishka_cms_builder
git clone https://github.com/mishka-group/mishka_blog.git __extensions/mishka_blog
git clone https://github.com/mishka-group/mishka_document.git __extensions/mishka_document
```

## 📚 Documentation

- [Mishka CMS documentation](https://mishka.tools/cms/docs), which is still being written
- [Features](https://mishka.tools/cms#platform), [multi-tenant sites](https://mishka.tools/cms#tenant)
- The [extensions](https://mishka.tools/cms#extensions) built on the core
- [Mishka Installer documentation](https://mishka.tools/installer/docs), for plugins and events
- [Mishka Gervaz documentation](https://mishka.tools/gervaz/docs), for the Ash admin DSL the dashboard screens use

## 💬 Community and support

- Report a bug or ask a question in [GitHub issues](https://github.com/mishka-group/mishka_cms_core/issues).
- Read about new releases on the [Mishka blog](https://mishka.tools/blog).
- For a custom extension, a migration from another CMS or priority support, [hire the Mishka team](https://mishka.tools/hire-us).

## 💖 Support the project

Mishka CMS is free and open source. You can support its development through [GitHub Sponsors](https://github.com/sponsors/mishka-group) or [Buy Me a Coffee](https://www.buymeacoffee.com/mishkagroup).

## 📜 License

Apache License 2.0. See [LICENSE](LICENSE).
