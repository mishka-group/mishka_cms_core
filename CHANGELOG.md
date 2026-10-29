# Changelog for MishkaCmsCore 0.0.3

- The visual page builder left the core: it is the [mishka_cms_builder](https://github.com/mishka-group/mishka_cms_builder) package (`MishkaCmsBuilder`, `MishkaCmsBuilderWeb`), with the editor's pages, canvas, Studio, history, review notes and snippets and their resources. A host that wants the editor adds the package, `MishkaCmsBuilderWeb` to `config :mishka_cms_core, extensions:` and `MishkaCmsBuilder` to its `ash_domains`. Without it the admin keeps the code editor and a create menu opens the form. The editor's tables, addresses and permissions are unchanged
- `MishkaCmsCore.Runtime.PageBuilder` is `MishkaCmsCore.Runtime.Authoring`: the document layer every authored template goes through (the HEEx tree and its edit operations, the checks the compilers and resources run, page forms, and the fields and elements an editor offers), with or without an editor. `PageBuilder.LiveView.HtmlTokenizer` is `Authoring.HtmlTokenizer`
- New events an editor answers: `runtime:document:editor_url` (`MishkaCmsCore.Runtime.Authoring.Section.editor_url/3`, the address of the editor, or `nil`), `runtime:provision:snippets` (the snippets an extension's setup writes) and `activity:sources` (more sources for the activity log, `MishkaCmsCore.Activity.Behaviours.UnionSource`). A setting definition can cover every key under a prefix (`match: :prefix`)
- The editor's settings are under its own prefix: `cms_builder.studio.*`, `cms_builder.preset.*` and `notify.cms_builder.page_comment.mentioned`. Values stored under the old keys are no longer read
- The core starts `MishkaCmsCore.PubSub` itself, so a host no longer starts it, and `MishkaCmsCore.Supervision.children/1` gives a host the runtime's processes in three groups (`:caches`, `:engine`, `:boot`)
- The test harness ships in `lib/mishka_cms_core/test/` (`MishkaCmsCore.Test.Boot`, `MishkaCmsCore.DataCase`, `MishkaCmsCore.ConnCase` and their helpers), so an extension's suite boots on it
- The admin's JavaScript hooks ship as ES module sources (`assets/js`, `package.json`) that a host's esbuild imports as `mishka_cms_core`

# Changelog for MishkaCmsCore 0.0.2

- The package now ships `priv/gettext`: core's templates (`.pot`) and English translations (`.po`). 0.0.1 left them out, so `MishkaCmsCore.Gettext` compiled with no translations

# Changelog for MishkaCmsCore 0.0.1

- Initial version: [mishka.tools/cms](https://mishka.tools/cms)
