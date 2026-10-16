# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.LazyHookLoaderTest do
  @moduledoc """
  The stub a lazy JS hook is registered as, run in Node.js against hook files on disk: the file is
  imported once, beside the bundle and with its query string, the first time an element mounts the
  hook; from then on every lifecycle callback is the hook's own, run on that element's hook.

  LiveView is played by a class that does what its `ViewHook` does with an object hook: no-op
  callbacks on the prototype, the hook's own keys copied onto the instance.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler

  @moduletag :node

  @object_hook """
  globalThis.evaluations = (globalThis.evaluations || 0) + 1;
  globalThis.chunkUrl = import.meta.url;

  const record = (...call) => globalThis.calls.push(call);

  export default {
    mounted() {
      record("mounted", this.el.id, this.helper());
      globalThis.mounted(this);
    },
    beforeUpdate(toEl) { record("beforeUpdate", this.el.id, toEl); },
    updated() { record("updated", this.el.id); },
    disconnected() { record("disconnected", this.el.id); },
    reconnected() { record("reconnected", this.el.id); },
    destroyed() { record("destroyed", this.el.id); },
    helper() { return "helper"; },
  };
  """

  @class_hook """
  class ViewHookPrototype {
    __mounted() {}
    mounted() {}
    updated() { globalThis.calls.push(["base updated", this.el.id]); }
  }

  class Shared extends ViewHookPrototype {
    shared() { return "shared"; }
  }

  export default class Chart extends Shared {
    mounted() {
      globalThis.calls.push(["class mounted", this.el.id, this.shared(), this.own()]);
      globalThis.mounted(this);
    }
    own() { return "own"; }
  }
  """

  @run """
  globalThis.calls = [];
  const errors = [];
  const failed = [];
  console.error = (message) => {
    errors.push(String(message));
    failed.shift()?.();
  };
  const nextError = () => new Promise((resolve) => failed.push(resolve));

  const mounts = [];
  globalThis.mounted = (hook) => mounts.shift()(hook);
  const nextMount = () => new Promise((resolve) => mounts.push(resolve));

  globalThis.document = {
    currentScript: { src: new URL("./bundle.js?preview=token", import.meta.url).href },
  };

  const { default: lazyHook } = await import("./__lazy_hook.js");

  class ViewHook {
    constructor(el, callbacks) {
      this.el = el;
      Object.assign(this, callbacks);
    }
    mounted() {}
    beforeUpdate() {}
    updated() {}
    destroyed() {}
    disconnected() {}
    reconnected() {}
  }

  const element = (id, file) => new ViewHook({ id }, lazyHook(file));

  const a = element("a", "abc.js");
  const b = element("b", "abc.js");
  const c = element("c", "abc.js");

  const aMounted = nextMount();
  a.mounted();
  b.mounted();
  b.destroyed();
  b.updated();
  const cMounted = nextMount();
  c.mounted();

  await aMounted;
  await cMounted;

  a.beforeUpdate("next");
  a.updated();
  a.disconnected();
  a.reconnected();
  a.destroyed();
  b.updated();

  const k = element("k", "klass.js");
  const kMounted = nextMount();
  k.mounted();
  await kMounted;
  k.updated();

  const missing = nextError();
  element("m", "missing.js").mounted();
  await missing;

  globalThis.document.currentScript = null;
  const { default: inlined } = await import("./__lazy_hook.js?inlined");
  new ViewHook({ id: "i" }, inlined("abc.js")).mounted();

  console.log(JSON.stringify({ calls, errors, evaluations, chunkUrl }));
  """

  setup do
    dir = Path.join([System.tmp_dir!(), "lazy_hook_#{System.unique_integer([:positive])}"])
    site_dir = Path.join([dir, "assets", "js", "site"])
    File.mkdir_p!(site_dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "package.json"), ~s({"type": "module"}))

    for {file, content} <- [
          {"__lazy_hook.js", JavaScriptCompiler.lazy_loader()},
          {"abc.js", @object_hook},
          {"klass.js", @class_hook},
          {"run.js", @run}
        ],
        do: File.write!(Path.join(site_dir, file), content)

    %{site_dir: site_dir}
  end

  test "the hook is imported once, on first mount, and then runs every callback as its own", %{
    site_dir: site_dir
  } do
    assert {output, 0} = System.cmd(node!(), ["run.js"], cd: site_dir, stderr_to_stdout: true)

    %{"calls" => calls, "errors" => errors, "evaluations" => evaluations, "chunkUrl" => url} =
      output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    assert calls == [
             ["mounted", "a", "helper"],
             ["mounted", "c", "helper"],
             ["beforeUpdate", "a", "next"],
             ["updated", "a"],
             ["disconnected", "a"],
             ["reconnected", "a"],
             ["destroyed", "a"],
             ["class mounted", "k", "shared", "own"]
           ]

    assert evaluations == 1, "one element or three, the file is imported once"
    assert String.ends_with?(url, "/assets/js/site/abc.js?preview=token")

    assert [missing, inlined] = errors
    assert missing =~ "Lazy hook missing.js could not be loaded."
    assert inlined =~ "the site's script was not loaded from a URL"
  end

  defp node! do
    System.find_executable("node") || flunk("node is not installed")
  end
end
