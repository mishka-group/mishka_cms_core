# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Web.DoctorChecksTest do
  @moduledoc """
  The checks extensions add to their "check and repair" window on `doctor:checks`
  (`MishkaCmsCore.Install.DoctorChecks`, drawn by
  `MishkaCmsCoreWeb.Live.Admin.Components.DoctorChecks` inside `doctor_modal/1`): a plugin answers
  for its own app, an actor sees and repairs only the checks of an area they hold, a check that
  raises or hangs reads as such on its own row while the others answer, and a repair runs, then the
  check again, in place.

  The plugin is `MishkaCmsCore.Test.Plugins.DoctorChecksProbe`, the host
  `MishkaCmsCore.Test.KitUpgradeHostLive`, whose extension is `:mishka_kit_host`; no real
  extension's check is tested here. `async: false`: the plugin registry is process-global.
  """
  use MishkaCmsCore.ConnCase, async: false

  @moduletag :capture_log

  import MishkaCmsCore.Test.Factory
  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Install.DoctorChecks
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.{Installer, KitUpgradeHostLive}
  alias MishkaCmsCore.Test.Plugins.DoctorChecksProbe

  @area "admin:dashboard:kit_host:product"

  setup do
    name = "doctor#{System.unique_integer([:positive])}"
    site = create_site!(name: name, host: "#{name}.test", active: true)
    SiteState.save(Map.take(site, [:id, :name, :host, :priority, :active, :master]))

    dir = Path.join(System.tmp_dir!(), "doctor_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    bundle = Path.join(dir, "kit.json")

    File.write!(
      bundle,
      Jason.encode!(%{
        "$schema" => "mishka.ui_kit.bundle.v3",
        "name" => "doctorkit",
        "version" => "1.0.0",
        "components" => []
      })
    )

    Installer.register!(DoctorChecksProbe, DoctorChecks.event())

    on_exit(fn ->
      DoctorChecksProbe.reset()
      File.rm_rf(dir)
      SiteState.delete(site.id)
      Application.delete_env(:mishka_cms_core, :doctor_check_timeout)
    end)

    admin = create_user_with_permissions!([@area], site_id: site.id)
    other = create_user_with_permissions!(["admin:dashboard:kit_host:order"], site_id: site.id)

    %{site: site, bundle: bundle, admin: load(admin), other: load(other)}
  end

  defp load(user),
    do: Ash.load!(user, [:permissions, :permission_values], authorize?: false)

  # A check of the probe's group that answers `answer` and tells the test it ran.
  defp check(id, answer, extra \\ %{}) do
    test = self()

    Map.merge(
      %{
        id: id,
        label: "Check #{id}",
        permission: @area,
        group: "Test extension",
        group_id: "kit_host",
        run: fn site_id, _actor ->
          send(test, {:ran, id, site_id})
          answer.()
        end
      },
      extra
    )
  end

  defp answers(checks), do: DoctorChecksProbe.answer(fn _data -> checks end)

  defp open(conn, ctx, actor) do
    {:ok, view, _html} =
      live_isolated(conn, KitUpgradeHostLive,
        session: %{"bundle" => ctx.bundle, "actor_id" => actor.id, "site_id" => ctx.site.id}
      )

    view |> element("#open-doctor") |> render_click()
    render_async(view)
    view
  end

  describe "collect/4" do
    test "answers only the checks of the window's app that the actor holds the area of", ctx do
      answers([
        check("prices", fn -> :ok end),
        check("orders", fn -> :ok end, %{permission: "admin:dashboard:kit_host:order"}),
        check("nobody", fn -> :ok end, %{permission: nil}),
        %{id: "broken", label: "No run", permission: @area}
      ])

      assert {:ok, [%{key: "kit_host:prices", group: "Test extension"}]} =
               DoctorChecks.collect(:mishka_kit_host, ctx.site.id, ctx.admin)

      assert {:ok, [%{key: "kit_host:orders"}]} =
               DoctorChecks.collect(:mishka_kit_host, ctx.site.id, ctx.other)

      assert {:ok, []} = DoctorChecks.collect(:another_extension, ctx.site.id, ctx.admin)
    end

    test "a plugin that never answers is cut at the limit and lists nothing", ctx do
      DoctorChecksProbe.answer(:hang)

      assert {:error, :timeout} =
               DoctorChecks.collect(:mishka_kit_host, ctx.site.id, ctx.admin, timeout: 0)
    end
  end

  describe "run/4" do
    test "a check that raises or hangs answers for itself and the others still answer", ctx do
      ok = check("ok", fn -> :ok end)
      found = check("found", fn -> {:problems, [%{id: "p1", text: "One is missing."}]} end)
      raises = check("raises", fn -> raise "broken check" end)

      ref = make_ref()
      handler = "doctor-run-#{inspect(ref)}"
      test = self()

      :telemetry.attach(
        handler,
        [:mishka_cms, :doctor_checks, :run],
        fn _event, _measure, meta, _config -> send(test, {ref, meta.check, meta.outcome}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      answers([ok, found, raises])
      {:ok, checks} = DoctorChecks.collect(:mishka_kit_host, ctx.site.id, ctx.admin)

      assert [
               %{check: %{id: "ok"}, outcome: :ok},
               %{
                 check: %{id: "found"},
                 outcome: {:problems, [%{id: "p1", text: "One is missing.", repair: nil}]}
               },
               %{check: %{id: "raises"}, outcome: {:error, :crashed}}
             ] = DoctorChecks.run(checks, ctx.site.id, ctx.admin)

      assert_received {^ref, "kit_host:ok", :ok}
      assert_received {^ref, "kit_host:found", :problems}
      assert_received {^ref, "kit_host:raises", :crashed}

      hangs =
        check("hangs", fn ->
          receive do
            :never -> :ok
          end
        end)

      answers([hangs])
      {:ok, [hang]} = DoctorChecks.collect(:mishka_kit_host, ctx.site.id, ctx.admin)

      assert [%{outcome: {:error, :timeout}}] =
               DoctorChecks.run([hang], ctx.site.id, ctx.admin, timeout: 0)
    end
  end

  describe "repair/5" do
    test "runs for an actor with the area, and refuses one without it before it runs", ctx do
      test = self()

      repair = %{
        label: "Fix all",
        run: fn site_id, _actor, problem ->
          send(test, {:repaired, site_id, problem})
          {:ok, "Fixed."}
        end
      }

      answers([check("fixable", fn -> :ok end, %{repair: repair})])
      {:ok, [fixable]} = DoctorChecks.collect(:mishka_kit_host, ctx.site.id, ctx.admin)

      assert {:error, _refused} = DoctorChecks.repair(fixable, ctx.site.id, ctx.other, nil)
      refute_received {:repaired, _site, _problem}

      assert {:ok, "Fixed."} = DoctorChecks.repair(fixable, ctx.site.id, ctx.admin, nil)
      site_id = ctx.site.id
      assert_received {:repaired, ^site_id, nil}
    end

    test "a repair that raises answers a plain sentence, never the exception", ctx do
      repair = %{label: "Fix", run: fn _site_id, _actor, _problem -> raise "secret detail" end}
      answers([check("fixable", fn -> :ok end, %{repair: repair})])
      {:ok, [fixable]} = DoctorChecks.collect(:mishka_kit_host, ctx.site.id, ctx.admin)

      assert {:error, sentence} = DoctorChecks.repair(fixable, ctx.site.id, ctx.admin, nil)
      refute sentence =~ "secret detail"
    end
  end

  describe "the window" do
    test "runs the checks when opened and lists them under the extension's name",
         %{conn: conn} = ctx do
      answers([
        check("ok", fn -> :ok end),
        check("found", fn -> {:problems, [%{id: "p1", text: "One is missing."}]} end),
        check("raises", fn -> raise "broken check" end),
        check("orders", fn -> :ok end, %{permission: "admin:dashboard:kit_host:order"})
      ])

      {:ok, view, _html} =
        live_isolated(conn, KitUpgradeHostLive,
          session: %{"bundle" => ctx.bundle, "actor_id" => ctx.admin.id, "site_id" => ctx.site.id}
        )

      refute_received {:ran, _id, _site}

      view |> element("#open-doctor") |> render_click()
      render_async(view)

      assert has_element?(view, "#kit-checks-group-kit_host", "Test extension")
      assert has_element?(view, "[data-check='kit_host:ok'][data-outcome=ok]")

      assert has_element?(
               view,
               "[data-check='kit_host:found'][data-outcome=problems]",
               "One is missing."
             )

      assert has_element?(view, "[data-check='kit_host:raises'][data-outcome=crashed]")
      refute has_element?(view, "[data-check='kit_host:orders']")
      refute render(view) =~ "broken check"
    end

    test "a repair button runs the repair, then the check again, in place", %{conn: conn} = ctx do
      test = self()
      {:ok, fixed?} = Agent.start_link(fn -> false end)

      answers([
        check(
          "prices",
          fn ->
            case Agent.get(fixed?, & &1) do
              true ->
                :ok

              false ->
                {:problems,
                 [%{id: "price-1", text: "Price one is missing.", repair: "Make it again"}]}
            end
          end,
          %{
            repair: %{
              label: "Check every price",
              run: fn _site_id, _actor, problem ->
                send(test, {:repaired, problem})
                Agent.update(fixed?, fn _ -> true end)
                {:ok, "Made again."}
              end
            }
          }
        )
      ])

      view = open(conn, ctx, ctx.admin)
      assert has_element?(view, "[data-check='kit_host:prices'][data-outcome=problems]")

      assert has_element?(
               view,
               "[data-check='kit_host:prices'] [data-role=check-repair]",
               "Check every price"
             )

      view
      |> element("[data-problem=price-1] [data-role=problem-repair]")
      |> render_click()

      render_async(view)

      assert_received {:repaired, %{id: "price-1"}}
      assert has_element?(view, "[data-check='kit_host:prices'][data-outcome=ok]")

      assert has_element?(
               view,
               "[data-check='kit_host:prices'] [data-role=repair-note]",
               "Made again."
             )
    end

    test "plugins that never answer leave the window open with one plain line",
         %{conn: conn} = ctx do
      Application.put_env(:mishka_cms_core, :doctor_check_timeout, 0)
      DoctorChecksProbe.answer(:hang)

      view = open(conn, ctx, ctx.admin)
      assert has_element?(view, "#kit-checks-unlisted")
      assert has_element?(view, "#kit-checks-again")
      assert has_element?(view, "#kit-form")
    end

    test "an admin without the area is shown no check and no repair button",
         %{conn: conn} = ctx do
      test = self()

      answers([
        check("prices", fn -> :ok end, %{
          repair: %{
            label: "Fix",
            run: fn _site_id, _actor, _problem ->
              send(test, :repaired)
              :ok
            end
          }
        })
      ])

      view = open(conn, ctx, ctx.other)
      assert has_element?(view, "#kit-checks-none")
      refute has_element?(view, "[data-check]")
      refute has_element?(view, "[data-role=check-repair]")
      refute_received :repaired
    end
  end
end
