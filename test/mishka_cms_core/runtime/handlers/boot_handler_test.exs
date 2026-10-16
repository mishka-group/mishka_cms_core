# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Handlers.BootHandlerTest do
  use ExUnit.Case, async: true
  @moduletag :unit

  alias MishkaCmsCore.Runtime.Handlers.BootHandler

  describe "asset_job/3 — unique + debounced per-site build job" do
    test "targets the :assets queue with the runtime compiler worker" do
      job = BootHandler.asset_job("site_a", "site-a-id", "css")

      assert Ecto.Changeset.get_change(job, :queue) == "assets"

      assert Ecto.Changeset.get_change(job, :worker) ==
               "MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker"
    end

    test "a warm job waits on the :maintenance queue, with the same unique, debounced rules" do
      job = BootHandler.asset_job("site_a", "site-a-id", "warm")
      args = Ecto.Changeset.get_change(job, :args)

      assert Ecto.Changeset.get_change(job, :queue) == "maintenance"
      assert args.data.type == "warm"
      assert args.boot_id == BootHandler.boot_id()
      assert Ecto.Changeset.get_change(job, :unique).states == [:available, :scheduled]
      assert Ecto.Changeset.get_change(job, :replace) == [scheduled: [:scheduled_at]]
    end

    test "carries the site name and asset type in args" do
      args =
        "site_a" |> BootHandler.asset_job("site-a-id", "css") |> Ecto.Changeset.get_change(:args)

      assert args.resource == "MishkaCmsCore.Runtime.Handlers.BootHandler"
      assert args.action == "boot_handler"
      assert args.data == %{site_name: "site_a", site_id: "site-a-id", type: "css"}
    end

    test "carries the boot id of the instance that inserts it" do
      args =
        "site_a" |> BootHandler.asset_job("site-a-id", "css") |> Ecto.Changeset.get_change(:args)

      assert is_binary(BootHandler.boot_id())
      assert args.boot_id == BootHandler.boot_id()
    end

    test "is configured unique over {worker, args} for available + scheduled" do
      unique =
        "site_a"
        |> BootHandler.asset_job("site-a-id", "css")
        |> Ecto.Changeset.get_change(:unique)

      assert unique.fields == [:worker, :args]
      assert unique.states == [:available, :scheduled]
    end

    test "is debounced (scheduled in the future) and replaces scheduled_at on conflict" do
      job = BootHandler.asset_job("site_a", "site-a-id", "css")

      assert Ecto.Changeset.get_change(job, :scheduled_at) != nil
      assert Ecto.Changeset.get_change(job, :replace) == [scheduled: [:scheduled_at]]
    end

    test "same {site, type} produces unique-equal args (coalesces); different type does not" do
      a1 =
        "site_a" |> BootHandler.asset_job("site-a-id", "css") |> Ecto.Changeset.get_change(:args)

      a2 =
        "site_a" |> BootHandler.asset_job("site-a-id", "css") |> Ecto.Changeset.get_change(:args)

      b = "site_a" |> BootHandler.asset_job("site-a-id", "js") |> Ecto.Changeset.get_change(:args)

      c =
        "site_b" |> BootHandler.asset_job("site-b-id", "css") |> Ecto.Changeset.get_change(:args)

      assert a1 == a2
      refute a1 == b
      refute a1 == c
    end
  end

  describe "classify_compile_stream_result/1 — on_timeout: :kill_task keeps boot alive" do
    test "a clean item reports nothing" do
      assert BootHandler.classify_compile_stream_result({:ok, nil}) == nil
    end

    test "a broken-but-skipped item passes its error tuple through" do
      assert BootHandler.classify_compile_stream_result({:ok, {:error, :not_found}}) ==
               {:error, :not_found}
    end

    test "a timed-out item becomes a compilation_exit (not a crash that aborts boot)" do
      assert BootHandler.classify_compile_stream_result({:exit, :timeout}) ==
               {:compilation_exit, :timeout}
    end

    test "any exit reason is carried through the same way" do
      assert BootHandler.classify_compile_stream_result({:exit, {:shutdown, 1}}) ==
               {:compilation_exit, {:shutdown, 1}}
    end
  end

  describe "build_error_template_content/1 — what the site's stylesheet scans" do
    @error_pages [
      %{
        status: 404,
        template: ~s(<p class="status-class">gone</p>),
        layout: %{"template" => ~s(<div class="layout-class"><%= @inner_content %></div>)}
      }
    ]

    test "a record read at boot carries every status's layout" do
      record =
        struct(MishkaCmsCore.Runtime.ErrorPage,
          root_layout_template: ~s(<body class="root-class"><%= @inner_content %></body>),
          helpers: [],
          error_pages: @error_pages
        )

      content = BootHandler.build_error_template_content(record)

      assert content =~ "root-class"
      assert content =~ "status-class"
      assert content =~ "layout-class"
    end

    test "a job's data carries them the same way" do
      data = %{
        "root_layout_template" => ~s(<body class="root-class"><%= @inner_content %></body>),
        "helpers" => [],
        "error_pages" => [
          %{
            "status" => 404,
            "template" => ~s(<p class="status-class">gone</p>),
            "layout" => %{"template" => ~s(<div class="layout-class"><%= @inner_content %></div>)}
          }
        ]
      }

      content = BootHandler.build_error_template_content(data)

      assert content =~ "status-class"
      assert content =~ "layout-class"
    end
  end
end
