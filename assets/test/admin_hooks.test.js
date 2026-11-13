// SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
//
// SPDX-License-Identifier: Apache-2.0

import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";

import AdminHooks from "../js/index.js";

afterEach(() => {
  document.body.innerHTML = "";
});

// The gear panel this field lives in is `phx-update="ignore"`, so the server can never patch the
// value back. Whatever the field shows after the reader leaves it is what they keep seeing.
describe("NumberBounds", () => {
  function field(attrs) {
    document.body.innerHTML = `<input type="number" ${attrs} />`;

    const el = document.querySelector("input");
    const hook = Object.create(AdminHooks.NumberBounds);

    hook.el = el;
    hook.mounted();

    return el;
  }

  function blur(el, typed) {
    el.value = typed;
    el.dispatchEvent(new Event("blur"));

    return el.value;
  }

  test("snaps down to the maximum", () => {
    expect(blur(field('min="1" max="12"'), "999")).toBe("12");
  });

  test("snaps up to the minimum", () => {
    expect(blur(field('min="1" max="12"'), "0")).toBe("1");
  });

  test("leaves a value inside the bounds alone", () => {
    expect(blur(field('min="1" max="12"'), "7")).toBe("7");
  });

  test("leaves an empty field empty, which is not a zero", () => {
    expect(blur(field('min="1" max="12"'), "")).toBe("");
  });

  test("does nothing without bounds to hold it to", () => {
    expect(blur(field(""), "999")).toBe("999");
  });

  // The correction has to reach the server too, or the field and the stored value disagree the
  // other way round.
  test("announces the value it settled on", () => {
    const el = field('min="1" max="12"');
    const seen = [];

    el.addEventListener("input", () => seen.push(el.value));
    blur(el, "999");

    expect(seen).toEqual(["12"]);
  });
});

// The sidebar nav is replaced on every live navigation; the hook puts the new one where the reader
// left the old one, and with nothing remembered shows the page's own link.
describe("SidebarScroll", () => {
  const KEY = "admin-sidebar:scrollTop";
  let frames;
  let storage;

  // A `sessionStorage` stand-in that records writes, or refuses every call like a private window.
  function fakeStorage({ refuse = false } = {}) {
    const values = new Map();
    const refuseCall = () => {
      throw new DOMException("denied", "SecurityError");
    };

    return {
      writes: [],
      getItem(key) {
        if (refuse) refuseCall();

        return values.has(key) ? values.get(key) : null;
      },
      setItem(key, value) {
        if (refuse) refuseCall();

        this.writes.push([key, value]);
        values.set(key, String(value));
      },
    };
  }

  beforeEach(() => {
    frames = [];
    storage = fakeStorage();
    vi.stubGlobal("sessionStorage", storage);
    vi.stubGlobal("localStorage", fakeStorage());
    vi.stubGlobal("requestAnimationFrame", (fn) => frames.push(fn));
    vi.stubGlobal("cancelAnimationFrame", vi.fn());
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  // jsdom has no layout, so `scrollTop` is held on the element by hand and every write recorded.
  function nav() {
    document.body.innerHTML = `
      <nav id="admin-sidebar-nav">
        <a href="/admin/dashboard/runtime/pages">Pages</a>
        <a href="/admin/dashboard/runtime/sites" aria-current="page">Sites</a>
      </nav>`;

    const el = document.querySelector("nav");
    const writes = [];
    let top = 0;

    Object.defineProperty(el, "scrollTop", {
      configurable: true,
      get: () => top,
      set: (value) => {
        top = value;
        writes.push(value);
      },
    });

    const active = el.querySelector("[aria-current='page']");
    active.scrollIntoView = vi.fn();

    return { el, writes, active };
  }

  // `this.js()` as LiveView gives it to a hook, applied straight to the element.
  const js = {
    setAttribute: (el, name, value) => el.setAttribute(name, value),
    addClass: (el, name) => el.classList.add(name),
    removeClass: (el, name) => el.classList.remove(name),
  };

  function mount(el) {
    const hook = Object.create(AdminHooks.SidebarScroll);

    hook.el = el;
    hook.js = () => js;
    hook.mounted();

    return hook;
  }

  function flush() {
    const pending = frames;

    frames = [];
    pending.forEach((fn) => fn(0));
  }

  test("puts a new nav back at the position the last one was left at, then shows the active link", () => {
    storage.setItem(KEY, "240");
    const { el, writes, active } = nav();

    mount(el);

    expect(writes).toEqual([240]);
    expect(active.scrollIntoView).toHaveBeenCalledWith({ block: "nearest" });
  });

  test("with nothing remembered, shows the active link without moving the rest", () => {
    const { el, writes, active } = nav();

    mount(el);

    expect(writes).toEqual([]);
    expect(active.scrollIntoView).toHaveBeenCalledWith({ block: "nearest" });
  });

  test("treats a remembered value that is not a number as nothing remembered", () => {
    storage.setItem(KEY, "top");
    const { el, writes, active } = nav();

    mount(el);

    expect(writes).toEqual([]);
    expect(active.scrollIntoView).toHaveBeenCalledWith({ block: "nearest" });
  });

  test("remembers where the reader scrolled, once a frame however many scroll events fire", () => {
    const { el } = nav();

    mount(el);
    el.scrollTop = 120;
    el.dispatchEvent(new Event("scroll"));
    el.scrollTop = 180;
    el.dispatchEvent(new Event("scroll"));

    expect(frames).toHaveLength(1);

    flush();

    expect(storage.writes).toEqual([[KEY, "180"]]);
  });

  test("keeps the last position when the nav was swapped out before its frame ran", () => {
    storage.setItem(KEY, "300");
    storage.writes = [];
    const { el } = nav();

    mount(el);
    el.dispatchEvent(new Event("scroll"));
    el.remove();
    flush();

    expect(storage.writes).toEqual([]);
    expect(storage.getItem(KEY)).toBe("300");
  });

  test("stops listening and drops a pending frame once destroyed", () => {
    const { el } = nav();
    const hook = mount(el);

    el.dispatchEvent(new Event("scroll"));
    hook.destroyed();

    expect(cancelAnimationFrame).toHaveBeenCalledTimes(1);

    frames = [];
    el.dispatchEvent(new Event("scroll"));

    expect(frames).toHaveLength(0);
  });

  test("works without storage, as in a private window", () => {
    storage = fakeStorage({ refuse: true });
    vi.stubGlobal("sessionStorage", storage);
    const { el, active } = nav();

    expect(() => mount(el)).not.toThrow();
    expect(active.scrollIntoView).toHaveBeenCalledWith({ block: "nearest" });

    el.dispatchEvent(new Event("scroll"));

    expect(frames).toHaveLength(1);
    expect(() => flush()).not.toThrow();
    expect(storage.writes).toEqual([]);
  });
});

// A folded group or branch is put back on the fresh nav a live navigation or a reload draws, except
// the one that holds the open page.
describe("SidebarScroll folds", () => {
  const FOLDS = "admin-sidebar:folds";
  let local;

  const js = {
    setAttribute: (el, name, value) => el.setAttribute(name, value),
    addClass: (el, name) => el.classList.add(name),
    removeClass: (el, name) => el.classList.remove(name),
  };

  beforeEach(() => {
    const values = new Map();

    local = {
      getItem: (key) => (values.has(key) ? values.get(key) : null),
      setItem: (key, value) => values.set(key, String(value)),
    };

    vi.stubGlobal("localStorage", local);
    vi.stubGlobal("sessionStorage", { getItem: () => null, setItem: () => {} });
    vi.stubGlobal("requestAnimationFrame", vi.fn());
    vi.stubGlobal("cancelAnimationFrame", vi.fn());
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  function nav() {
    document.body.innerHTML = `
      <nav id="admin-sidebar-nav">
        <button data-fold aria-expanded="true" aria-controls="sb-runtime">Runtime</button>
        <div id="sb-runtime"><a href="/admin/dashboard/runtime/pages">Pages</a></div>
        <button data-fold aria-expanded="true" aria-controls="sb-plugins">Plugins</button>
        <div id="sb-plugins">
          <a href="/admin/dashboard/shop">Shop</a>
          <button data-fold aria-expanded="false" aria-controls="sbi-shop">Shop</button>
          <div id="sbi-shop" class="hidden">
            <a href="/admin/dashboard/shop/orders" aria-current="page">Orders</a>
          </div>
        </div>
      </nav>`;

    const el = document.querySelector("nav");
    el.querySelectorAll("a").forEach((link) => (link.scrollIntoView = vi.fn()));

    return el;
  }

  function mount(el) {
    const hook = Object.create(AdminHooks.SidebarScroll);

    hook.el = el;
    hook.js = () => js;
    hook.mounted();

    return hook;
  }

  const button = (el, id) => el.querySelector(`[aria-controls='${id}']`);
  const folded = (id) => document.getElementById(id).classList.contains("hidden");

  test("remembers a fold as the state the click leads to", () => {
    const el = nav();
    mount(el);

    button(el, "sb-runtime").click();

    expect(JSON.parse(local.getItem(FOLDS))).toEqual({ "sb-runtime": false });
  });

  test("puts a remembered fold back on a fresh nav", () => {
    local.setItem(FOLDS, JSON.stringify({ "sb-runtime": false }));
    const el = nav();

    mount(el);

    expect(folded("sb-runtime")).toBe(true);
    expect(button(el, "sb-runtime").getAttribute("aria-expanded")).toBe("false");
    expect(folded("sb-plugins")).toBe(false);
  });

  test("keeps the group and branch of the open page open, whatever was remembered", () => {
    local.setItem(FOLDS, JSON.stringify({ "sb-plugins": false, "sbi-shop": false }));
    const el = nav();

    mount(el);

    expect(folded("sb-plugins")).toBe(false);
    expect(folded("sbi-shop")).toBe(false);
    expect(button(el, "sbi-shop").getAttribute("aria-expanded")).toBe("true");
  });

  test("ignores a remembered value that is not a map of folds", () => {
    local.setItem(FOLDS, "[1,2]");
    const el = nav();

    expect(() => mount(el)).not.toThrow();
    expect(folded("sb-runtime")).toBe(false);
  });

  test("stops remembering once destroyed", () => {
    const el = nav();
    mount(el).destroyed();

    button(el, "sb-runtime").click();

    expect(local.getItem(FOLDS)).toBe(null);
  });
});

// A part dragged in the content editor's settings: the page is put back as it was, and the server
// is told the part it was dropped beside, which draws the new order.
describe("ContentParts", () => {
  function mounted() {
    document.body.innerHTML = `
      <div id="parts" data-target="#picker">
        <section data-content-part="r-0">A</section>
        <div data-content-part="r-2">B</div>
        <section data-content-part="r-4">C</section>
      </div>`;

    const hook = Object.create(AdminHooks.ContentParts);
    hook.el = document.getElementById("parts");
    hook.pushes = [];
    hook.pushEventTo = (target, event, payload) => hook.pushes.push({ target, event, payload });
    hook.mounted();

    return hook;
  }

  const order = (hook) => hook.parts().map((el) => el.dataset.contentPart);

  // What Sortable leaves in the page at the end of a drag from `from` to `to`.
  function drag(hook, from, to) {
    const parts = hook.parts();
    const item = parts[from];
    const options = hook.sorter.options;

    options.onStart({ item });
    item.remove();
    hook.el.insertBefore(item, hook.parts()[to] || null);
    options.onEnd({ item, oldDraggableIndex: from, newDraggableIndex: to });
  }

  test("a part dragged down names the one it now follows", () => {
    const hook = mounted();
    drag(hook, 0, 2);

    expect(hook.pushes).toEqual([
      { target: "#picker", event: "part_move", payload: { path: "r-0", to: "r-4" } },
    ]);
    expect(order(hook)).toEqual(["r-0", "r-2", "r-4"]);
  });

  test("a part dragged up names the one it now goes before", () => {
    const hook = mounted();
    drag(hook, 2, 1);

    expect(hook.pushes).toEqual([
      { target: "#picker", event: "part_move", payload: { path: "r-4", to: "r-2" } },
    ]);
    expect(order(hook)).toEqual(["r-0", "r-2", "r-4"]);
  });

  test("a part dropped where it was sends nothing", () => {
    const hook = mounted();
    drag(hook, 1, 1);

    expect(hook.pushes).toEqual([]);
  });

  test("drags by its grip alone", () => {
    const hook = mounted();

    expect(hook.sorter.options.handle).toBe("[data-part='grip']");
    expect(hook.sorter.options.draggable).toBe("[data-content-part]");
    hook.destroyed();
  });
});

// The preview modal's "Loading the preview…" sits behind the frame; a page with no background of its
// own showed it through, so it goes when the frame has loaded, and comes back with a new frame.
describe("PreviewFrame", () => {
  function frame(id) {
    return `<div data-preview-spinner id="spinner-${id}"></div><iframe id="frame-${id}"></iframe>`;
  }

  function mount(id) {
    document.body.innerHTML = `<div id="wrap">${frame(id)}</div>`;

    const hook = Object.create(AdminHooks.PreviewFrame);
    hook.el = document.getElementById("wrap");
    hook.mounted();

    return hook;
  }

  const spinner = () => document.querySelector("[data-preview-spinner]");

  test("shows the note until the frame loads, then hides it", () => {
    mount("a");
    expect(spinner().hidden).toBe(false);

    document.querySelector("iframe").dispatchEvent(new Event("load"));
    expect(spinner().hidden).toBe(true);
  });

  test("keeps the note hidden across a patch that redraws it for the same frame", () => {
    const hook = mount("a");
    const iframe = document.querySelector("iframe");
    iframe.dispatchEvent(new Event("load"));

    spinner().replaceWith(Object.assign(document.createElement("div"), { id: "spinner-a" }));
    document.getElementById("spinner-a").setAttribute("data-preview-spinner", "");
    hook.updated();

    expect(spinner().hidden).toBe(true);
  });

  test("shows the note again for a new frame, until that one loads", () => {
    const hook = mount("a");
    document.querySelector("iframe").dispatchEvent(new Event("load"));

    hook.el.innerHTML = frame("b");
    hook.updated();
    expect(spinner().hidden).toBe(false);

    document.querySelector("iframe").dispatchEvent(new Event("load"));
    expect(spinner().hidden).toBe(true);
  });
});
