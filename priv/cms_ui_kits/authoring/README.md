# Writing a UI kit bundle this CMS can install

A bundle is one JSON file. `MishkaCmsCore.Runtime.Handlers.UiKitHandler.install_kit!/2` reads it and
creates a `Runtime.Component` row per component, a `Runtime.JsHook` row per hook and a
`Runtime.Stylesheet` row per stylesheet. Nothing is compiled at install time — a component is built
the first time a page uses it — so a bundle that installs is not yet a bundle that renders, and the
checklist at the bottom is the difference.

Everything here is checked by `MishkaCmsCore.UiKit.AuthoringExampleTest`, which installs
[`acme.json`](acme.json) in this directory and renders it. That file is the shortest bundle that
does every single thing described below; start by copying it.

## The file

```json
{
  "$schema": "mishka.ui_kit.bundle.v3",
  "name": "acme",
  "version": "0.1.0",
  "components": [ ... ],
  "js_hooks": [ ... ],
  "stylesheets": [ ... ]
}
```

`name` is the kit's namespace and it is load-bearing, not a label:

* **every component must be named `<kit>-<something>`.** `uninstall_kit!/2` deletes components by
  that prefix, and the installer's picker groups by it. A component named anything else installs and
  can never be removed by name.
* **every JS hook and stylesheet should be too.** The name IS the key — two kits shipping `carousel`
  are one row, and the second install silently replaces the first.

## A component

| field | required | what it is |
|---|---|---|
| `name` | ✅ | `<kit>-<component>`, kebab-case, unique in the bundle |
| `template` | ✅ | the HEEx rendered when a page places this component |
| `type` | | one of `general` `forms` `navigations` `media` `feedback` `overlays` — which group the picker files it under (default `general`) |
| `attrs` | | `[{name, type, opts}]` — the properties the Inspector draws |
| `slots` | | `[{name, opts}]` — the named slots the Inspector offers to add |
| `helpers` | | `[{name, args, code}]` — private functions the template calls |
| `dependencies` | | other component names this one renders; the picker locks them |
| `examples` | | finished HEEx snippets, shown in the palette |
| `extra` | | anything else. Unknown keys are dropped at the Ash boundary, so a kit may carry its own |

`MishkaCmsCore.UiKit.Contract` checks the shape of each one and **skips the ones that fail rather
than failing the install** — one malformed component costs that component, not the kit.

### Attributes are what an author actually edits

```json
{"name": "variant", "type": "string",
 "opts": {"default": "default", "values": ["default", "outline", "shadow"],
          "doc": "How the surface is drawn"}}
```

* `values` turns the field into a **select**; without it the author gets a text box.
* `default` is what a fresh drop uses, and what the installer's per-component narrowing keeps when
  someone installs the component minimally.
* `opts.required: true` means the component cannot render without it. The builder will not place one
  without a value, and will show `needs <name>` until it has one.
* `opts.editor` overrides the widget: `"url"`, `"media"` (opens the media library), `"icon"`,
  `"color"`.
* `type: "global"` collects every attribute the author wrote that the component never declared.

### One attribute is special

**`id`.** Declare it if the component's own markup, JS or `JS.exec` targets need one, and the editor
mints a value at placement, renumbers it if a second copy would collide, and rewrites the references
inside that copy. Do not declare it otherwise: an id nothing refers to is noise in the saved HEEx.

## A component that opens and closes

A dialog, drawer, dropdown, popover, tooltip, accordion or menu renders its content **closed**. Two
consequences, and both have an answer the CMS reads off the component itself rather than guessing:

**Say how you are opened.** Put the commands on the component's ROOT element:

```heex
<div id={@id} data-pb-open={show_popover(@id)} data-pb-close={hide_popover(@id)}>
```

`data-pb-open`, `data-pb-close` and `data-pb-toggle` — any subset. The builder's Interactions panel
then offers exactly the verbs you declared when a button is aimed at your component, and compiles the
click to `JS.exec("data-pb-open", to: …)`. Declare nothing and the author is offered the generic
`JS.show`/`JS.hide`, which for anything more elaborate than `display:none` reveals the wrong half —
a full-page backdrop with no dialog under it is the usual result.

**Nothing else is required to be editable.** A component whose root declares one of those three is
shown OPEN on the canvas while it is being edited, with a labelled drop area when it is empty, and
closed in preview and on the published page.

## A component that is part of a form

The builder reads a component's part in a form from its markup and attributes, never from its name,
so a renamed row answers the same:

* **Field** — an attribute typed `Phoenix.HTML.FormField` (any name), or a control whose `name` and
  `value` are bound to attributes the component declares.
* **Form** — markup rendering `<.form>` or `<form>`, a required `for` attribute, or an outer element
  that is another component which is itself a form. It passes its form to what is placed inside it
  when it writes `render_slot(@inner_block, f)` under a `:let={f}` on `<.form>`.
* **Send button** — the ONE outer element is a `<button>` whose type can be `submit` (a button with
  no type submits), or an `<input>` whose type can be `submit` or `image`, through a literal, the
  default of the attribute it is bound to, or that attribute's `values`. Buttons inside the markup
  do not count. The type is read in any case, and `type={:submit}` counts as `type="submit"`. The
  outer element is what renders, so a placed button given `href`, `navigate` or `patch` still sends
  its form; only a component with no markup that declares one of them (the CMS's own `<.button>`)
  is read as rendering a link.

To say it outright instead, declare it in `extra.form`; a declaration always wins:

```json
"extra": {"form": {"role": "field", "field": "bind", "name": "input_name", "label": "caption"}}
```

`role` is one of `wrapper`, `field`, `error`, `fieldset`, `submit`; the other keys name the
component's own attributes. An error component is never inferred, so declare `error` if you ship one.

## A JS hook

```json
{"name": "acme-reveal", "format": "js", "active": true, "site_id": null,
 "content": "export default {mounted(){ ... }};",
 "extra": {"module": "Reveal", "replaces": "reveal"}}
```

The row name becomes the live hook key: kebab split, capitalised, joined, with `Global` in front for
a site-less row. `acme-reveal` is reachable as **`GlobalAcmeReveal`** and as nothing else, so that is
what your templates must write:

```heex
<div phx-hook="GlobalAcmeReveal" id={@id}>
```

`extra.replaces` names a row an earlier version of this bundle shipped under a different name. The
installer deletes it on the way in, so a rename migrates instead of leaving two rows behind. Global
rows only — a site's own hook of the same name is never touched.

## A stylesheet

```json
{"name": "acme-theme", "kind": "theme", "content": "@theme { --color-acme: oklch(...); }"}
```

`kind: "theme"` is inlined into the shared base **before** `@import "tailwindcss"`, which is the
order Tailwind v4 requires for `@theme`. Anything else is appended after.

## Before you ship

1. `name` prefixes every component, hook and stylesheet.
2. Every `template` parses as HEEx on its own.
3. Every attribute the template reads is declared, or has a default — an undeclared `@thing` raises
   inside LiveView's diff, which the editor shows as a red box on the author's canvas.
4. Every `dependencies` entry names a component that exists in this bundle or is already installed.
5. Every component has at least two `examples`, and each example renders that component.
6. Any component that opens declares `data-pb-open` / `data-pb-close` on its root.
7. Every `phx-hook` your templates write is `Global<PascalKitHook>` for a hook this bundle ships.

Install it with:

```elixir
MishkaCmsCore.Runtime.Handlers.UiKitHandler.install_kit!("/path/to/acme.json")
```

or drop the file in `priv/cms_ui_kits/` and it appears in the Studio's kit list.
