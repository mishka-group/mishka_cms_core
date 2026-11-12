// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

// THE HOOKS THE CORE'S OWN ADMIN TEMPLATES MOUNT, beside the code box (`pb_code_editor.js`) and the
// rich-text editor (`pb_content_editor.js`): the dashboard's widget grid and its library tray, the
// parts of a content component in its settings drawer, the media thumbnails, a widget's bounded
// number fields, the sidebar's scroll position and the preview modal's frame. No public template names
// one of them; `index.js` hands all nine to the host's admin bundle.
//
// `sortablejs` is a peer dependency (package.json): it comes from the host's own
// `assets/node_modules`, which the host's esbuild profile puts on `NODE_PATH`.

import Sortable from "sortablejs";

// A THUMBNAIL WHOSE IMAGE MAY NEVER ARRIVE — the media gallery's cards, the Assets sheet's rows, the
// media table's preview cell. Every one of them paints a type glyph BEHIND the <img>, so a file that
// no longer exists on disk only has to get the image out of the way for the glyph to be what you
// see. A loaded image gets a background of its own where the element asks for one, or a transparent
// PNG picks up the tile's tint instead of sitting on paper.
//
// It exists because `onload=`/`onerror=` cannot: an enforced CSP blocks inline event handlers
// outright, and there is no nonce or hash that applies to them — the attribute is the violation.
// A listener bound from the admin bundle is ordinary same-origin script, which the policy allows.
//
// THE `complete` CHECK IS THE PART THE ATTRIBUTES DID NOT NEED. They were parsed before the request
// started, so no event could be missed. A hook mounts after the element is in the document, and a
// cached image is already finished by then — it will never fire `load` again, and without this every
// second visit to the page would show the glyph under an image that is perfectly fine.
const MediaThumb = {
  mounted() {
    this.sync();
  },
  updated() {
    this.sync();
  },
  sync() {
    const img = this.el.querySelector("img");
    if (!img) return;

    if (img !== this.img) {
      this.detach();
      this.img = img;
      this.settled = (event) => this.settle(event.type === "load");
      img.addEventListener("load", this.settled);
      img.addEventListener("error", this.settled);
    }

    // A patch may have swapped the src for another record's, so the verdict on the old one is
    // cleared before the new one is judged.
    img.style.display = "";
    img.style.background = "";
    if (img.complete) this.settle(img.naturalWidth > 0);
  },
  settle(loaded) {
    if (!loaded) {
      this.img.style.display = "none";
      return;
    }

    const background = this.el.dataset.loadedBackground;
    if (background) this.img.style.background = background;
  },
  detach() {
    if (!this.img) return;
    this.img.removeEventListener("load", this.settled);
    this.img.removeEventListener("error", this.settled);
    this.img = null;
  },
  destroyed() {
    this.detach();
  },
};

// Admin dashboard widget grid: drag-to-reorder within the grid, and a shared Sortable group with
// the widget library tray so chips drop in ("add_at") and widgets drag off the board ("hide" via
// the tray's onAdd). Dragging is enabled only while data-customize="true". Touch-friendly: the
// short delayOnTouchOnly hold starts a drag while taps and page scroll keep working.
const DashboardGrid = {
  mounted() {
    this.sorter = new Sortable(this.el, {
      group: "dash-widgets",
      animation: 150,
      handle: "[data-drag-handle]",
      draggable: "[data-id]",
      delay: 120,
      delayOnTouchOnly: true,
      forceFallback: true,
      fallbackTolerance: 5,
      ghostClass: "opacity-40",
      dragClass: "shadow-2xl",
      disabled: this.el.dataset.customize !== "true",
      onAdd: (evt) => {
        const id = evt.item.dataset.id;
        const index = evt.newIndex;
        evt.item.remove();
        this.pushEvent("add_at", { id, index });
      },
      onEnd: (evt) => {
        if (evt.from !== evt.to || evt.oldIndex === evt.newIndex) return;
        const ids = Array.from(
          this.el.querySelectorAll(":scope > [data-id]"),
        ).map((el) => el.dataset.id);
        this.pushEvent("reorder", { ids });
      },
    });
  },
  updated() {
    this.sorter?.option("disabled", this.el.dataset.customize !== "true");
  },
  destroyed() {
    this.sorter?.destroy();
  },
};

// The widget library tray: chips drag onto the grid (handled by the grid's onAdd); a widget card
// dropped HERE is removed from the board ("hide"). Chips also add on plain click/tap.
const DashboardTray = {
  mounted() {
    this.sorter = new Sortable(this.el, {
      group: "dash-widgets",
      sort: false,
      animation: 150,
      draggable: "[data-id]",
      delay: 120,
      delayOnTouchOnly: true,
      forceFallback: true,
      fallbackTolerance: 5,
      ghostClass: "opacity-40",
      dragClass: "shadow-2xl",
      onAdd: (evt) => {
        const id = evt.item.dataset.id;
        evt.item.remove();
        this.pushEvent("hide", { id });
      },
    });
  },
  destroyed() {
    this.sorter?.destroy();
  },
};

// THE PARTS ONE COMPONENT HOLDS in the content editor's settings drawer, dragged by their grips to
// another place among themselves. Sortable moves the part in the page; it is put back where it was
// and the server is told which part it was dropped beside (`part_move`, `to`), whose answer draws
// the new order — the parts' ids name their places, and the page must not hold an order the
// server did not draw.
const ContentParts = {
  mounted() {
    this.sorter = new Sortable(this.el, {
      animation: 150,
      handle: "[data-part='grip']",
      draggable: "[data-content-part]",
      forceFallback: true,
      fallbackTolerance: 5,
      ghostClass: "opacity-40",
      onStart: (evt) => {
        this.home = evt.item.nextSibling;
      },
      onEnd: (evt) => {
        const { item, oldDraggableIndex: from, newDraggableIndex: to } = evt;
        if (from === to) return;

        const parts = this.parts();
        const beside = parts[to < from ? to + 1 : to - 1];

        this.el.insertBefore(item, this.home);
        if (!beside) return;

        this.pushEventTo(this.el.dataset.target, "part_move", {
          path: item.dataset.contentPart,
          to: beside.dataset.contentPart,
        });
      },
    });
  },
  parts() {
    return Array.from(this.el.children).filter((el) => el.matches("[data-content-part]"));
  },
  destroyed() {
    this.sorter?.destroy();
  },
};

// A number field the server bounds, bounded on the client too. The gear panel it lives in is
// `phx-update="ignore"`, so once rendered its inputs are never patched again: a value the server
// clamps is stored clamped while the field keeps showing what was typed, for the rest of the
// session. Snapping on blur rather than on every keystroke leaves typing alone.
const NumberBounds = {
  mounted() {
    // `getAttribute`, not `el.min`: an absent bound reads as "" there and `Number("")` is 0, which
    // would hold every unbounded field to zero.
    const bound = (name) => {
      const raw = this.el.getAttribute(name);

      return raw === null || raw === "" ? null : Number(raw);
    };

    this.onBlur = () => {
      const value = Number(this.el.value);

      if (this.el.value === "" || Number.isNaN(value)) return;

      const min = bound("min");
      const max = bound("max");

      let bounded = value;

      if (min !== null && !Number.isNaN(min)) bounded = Math.max(min, bounded);
      if (max !== null && !Number.isNaN(max)) bounded = Math.min(max, bounded);

      if (bounded !== value) {
        this.el.value = String(bounded);
        this.el.dispatchEvent(new Event("input", { bubbles: true }));
      }
    };

    this.el.addEventListener("blur", this.onBlur);
  },
  destroyed() {
    this.el.removeEventListener("blur", this.onBlur);
  },
};

// The admin sidebar's scrolling nav. It is drawn by the LiveView layout, so every live navigation
// replaces it with a fresh element at the top; this puts it back where the reader left it. The
// position lives in `sessionStorage`, one per tab, so it also survives the full page loads into and
// out of the builder. Then the active link is scrolled into view, which moves nothing when it is
// already in view.
//
// It also keeps what the reader folded. A group or a branch folds with `Phoenix.LiveView.JS`, but
// `JS` cannot write storage, so the hook remembers each fold in `localStorage` (one map of panel id
// to open, for every tab and the next visit) and puts it back on the fresh nav. A panel that holds
// the open page stays open whatever was remembered. The fold is put back through `this.js()`, so a
// later patch of the sidebar keeps it, as it keeps one made by a click.
const SIDEBAR_SCROLL_KEY = "admin-sidebar:scrollTop";
const SIDEBAR_FOLDS_KEY = "admin-sidebar:folds";

function readFolds() {
  try {
    const folds = JSON.parse(localStorage.getItem(SIDEBAR_FOLDS_KEY));

    return folds && typeof folds === "object" && !Array.isArray(folds) ? folds : {};
  } catch (_denied) {
    // Refused storage or a value that is not JSON: nothing is remembered.
    return {};
  }
}

// A link inside a folded list has no box to scroll to.
function shown(el) {
  return typeof el.checkVisibility !== "function" || el.checkVisibility();
}

const SidebarScroll = {
  mounted() {
    let saved = null;

    try {
      saved = sessionStorage.getItem(SIDEBAR_SCROLL_KEY);
    } catch (_denied) {
      // Private browsing may refuse sessionStorage; fall back to the active link below.
    }

    this.restoreFolds();

    const top = saved === null ? NaN : parseInt(saved, 10);

    if (!Number.isNaN(top)) this.el.scrollTop = top;

    [...this.el.querySelectorAll("[aria-current='page']")]
      .find(shown)
      ?.scrollIntoView({ block: "nearest" });

    this.frame = null;
    this.onScroll = () => {
      if (this.frame !== null) return;

      this.frame = requestAnimationFrame(() => {
        this.frame = null;

        // A nav already swapped out reads 0; keep the position the reader actually left.
        if (!this.el.isConnected) return;

        try {
          sessionStorage.setItem(SIDEBAR_SCROLL_KEY, String(this.el.scrollTop));
        } catch (_denied) {
          // Without storage the position is simply not kept.
        }
      });
    };

    // LiveView runs the fold from its own click listener on `window`, after this one, so the state
    // the click leads to is the opposite of the one read here.
    this.onFold = (event) => {
      const button = event.target.closest?.("[data-fold]");
      const id = button?.getAttribute("aria-controls");

      if (!id) return;

      const folds = readFolds();
      folds[id] = button.getAttribute("aria-expanded") !== "true";

      try {
        localStorage.setItem(SIDEBAR_FOLDS_KEY, JSON.stringify(folds));
      } catch (_denied) {
        // Without storage the fold lasts until the nav is drawn again.
      }
    };

    this.el.addEventListener("scroll", this.onScroll, { passive: true });
    this.el.addEventListener("click", this.onFold);
  },
  restoreFolds() {
    const folds = readFolds();
    const js = this.js();

    this.el.querySelectorAll("[data-fold]").forEach((button) => {
      const id = button.getAttribute("aria-controls");
      const panel = id && document.getElementById(id);

      if (!panel || typeof folds[id] !== "boolean") return;

      const open = folds[id] || panel.querySelector("[aria-current='page']") !== null;

      js.setAttribute(button, "aria-expanded", String(open));

      if (open) {
        js.removeClass(panel, "hidden");
      } else {
        js.addClass(panel, "hidden");
      }
    });
  },
  destroyed() {
    this.el.removeEventListener("scroll", this.onScroll);
    this.el.removeEventListener("click", this.onFold);

    if (this.frame !== null) cancelAnimationFrame(this.frame);
  },
};

// THE PREVIEW MODAL'S FRAME, whose "Loading the preview…" note sits behind the iframe. A page with
// no background of its own let the note show through it after the page had loaded, so the note goes
// on the frame's `load`. A hook because nothing else can: `Phoenix.LiveView.JS` binds no `load`,
// and the CSP refuses an inline `onload`. The frame and the note are re-keyed together for every new
// address, so a new frame brings its note back; a patch that keeps the frame keeps the note hidden.
const PreviewFrame = {
  mounted() {
    this.sync();
  },
  updated() {
    this.sync();
  },
  sync() {
    const frame = this.el.querySelector("iframe");
    if (!frame) return;

    if (frame !== this.frame) {
      this.frame = frame;
      this.loaded = false;
      frame.addEventListener("load", () => {
        if (this.frame !== frame) return;
        this.loaded = true;
        this.hide();
      });
    }

    if (this.loaded) this.hide();
  },
  hide() {
    const spinner = this.el.querySelector("[data-preview-spinner]");
    if (spinner) spinner.hidden = true;
  },
};

export default {
  PreviewFrame,
  NumberBounds,
  SidebarScroll,
  MediaThumb,
  DashboardGrid,
  DashboardTray,
  ContentParts,
};
