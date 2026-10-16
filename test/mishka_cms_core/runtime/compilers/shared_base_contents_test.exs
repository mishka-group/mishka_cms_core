# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.SharedBaseContentsTest do
  @moduledoc """
  What the shared base is, stated as behaviour rather than as a list of `@source` lines.

  It is compiled ONCE and prepended to every site's stylesheet, so two things follow. Whatever is in
  it is paid for by every visitor to every site — and whatever is in it is frozen until something
  drops the cache, because no per-site rebuild refreshes it.

  That makes its contents a decision with teeth on both sides. A global component in there is CSS
  every visitor downloads for a component their site may never render; a global component NOT in
  there means a save need not throw the base away, which is a full recompile of the host shell and
  `app.css` for a change that cannot touch either.

  See `SharedBaseStalenessTest` for the other half — that a global LAYOUT still reaches the sites
  whose pages use it, precisely because it is reached per site instead.
  """
  use MishkaCmsCore.DataCase, async: false
  @moduletag :integration

  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler
  alias MishkaCmsCore.Runtime.Handlers.BootHandler
  alias MishkaCmsCore.Runtime.States.AssetsState

  setup do
    TailwindCompiler.ensure_installed()
    :ok
  end

  describe "a global component's classes" do
    # If this fails, `delete_shared_base_css/0` on the Component save path becomes load-bearing again
    # and must go back — see `RuntimeCompilerWorker`'s Component clause.
    test "are not in the shared base, so no site pays for a component it never renders" do
      n = System.unique_integer([:positive])
      name = "sb-probe-#{n}"
      on_exit(fn -> BootHandler.delete_template_file(nil, "component", name) end)

      BootHandler.create_template_file(
        nil,
        "component",
        name,
        ~s(<div class="mt-[43px] tracking-[0.29em]">probe</div>)
      )

      {:ok, base} = TailwindCompiler.compile_shared_base()

      refute base =~ "mt-\\[43px\\]",
             "the shared base is carrying a global component; every visitor to every site downloads it"

      refute base =~ "tracking-\\[0\\.29em\\]"
    end
  end

  describe "saving a global component" do
    # A kit has hundreds of components and an author saves them one at a time. Throwing the base away
    # each time rebuilds the host shell and `app.css` — neither of which a component can affect.
    test "leaves the cached shared base alone" do
      {:ok, _css} = TailwindCompiler.compile_and_store_shared_base()
      assert AssetsState.exists?("__shared_base__", "css")

      name = "sb-save-#{System.unique_integer([:positive])}"
      on_exit(fn -> BootHandler.delete_template_file(nil, "component", name) end)

      assert :ok =
               MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker.perform(%Oban.Job{
                 args: %{
                   "resource" => "MishkaCmsCore.Runtime.Component",
                   "action" => "update",
                   "data" => %{
                     "id" => Ecto.UUID.generate(),
                     "name" => name,
                     "active" => true,
                     "precompile" => false,
                     "site_id" => nil,
                     "template" => ~s(<i class="sb-save-probe"></i>)
                   }
                 }
               })

      assert AssetsState.exists?("__shared_base__", "css"),
             "saving one component rebuilt the foundation stylesheet every site shares"
    end
  end
end
