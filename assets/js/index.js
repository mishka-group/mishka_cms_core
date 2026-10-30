// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

// THE PACKAGE'S ENTRY, named by `main` and `module` in the root `package.json`: the eight hooks the
// core's admin templates mount. A host's admin bundle imports it by name and hands the hooks to its
// LiveSocket with its own:
//
//     import CoreHooks from "mishka_cms_core";
//     boot({ ...SharedHooks, ...CoreHooks });
//
// esbuild finds the package through the host's `NODE_PATH`: `deps/mishka_cms_core` for the Hex
// release, `__extensions/mishka_cms_core` for a checkout. These are ES module sources, bundled by the
// host; nothing here is built ahead of time.

import AdminHooks from "./admin_hooks.js";
import { PbCodeEditor } from "./pb_code_editor.js";
import { ContentEditor } from "./pb_content_editor.js";

export default { ...AdminHooks, PbCodeEditor, ContentEditor };
