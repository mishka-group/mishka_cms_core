# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.InstallerTest do
  @moduledoc """
  Installer steps with receipts: the installer's answer is never the whole evidence. An extension
  that caught its own failure, a report that left pages out, a plugin step the registry does not
  show, and a library that never installed each leave a receipt that is not verified.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Agent.{Installer, Receipts}
  alias MishkaCmsCore.Install.Extensions
  alias MishkaCmsCore.Test.Plugins.{AgentExtensionProbe, AgentLifecycleProbe}
  alias MishkaInstaller.Event.Event

  setup do
    Receipts.switch(true)
    on_exit(fn -> Receipts.switch(false) end)
    {:ok, site: create_site!(name: "rcptinst#{System.unique_integer([:positive])}")}
  end

  defp stage(receipt, name), do: Enum.find(receipt.stages, &(&1.name == name))

  describe "install_extension/5" do
    setup do
      MishkaCmsCore.Test.Installer.register!(AgentExtensionProbe, Extensions.event())
    end

    test "a complete install is verified by the row it wrote and the version it reported", %{
      site: site
    } do
      admin = create_user_with_permissions!(["admin:dashboard:*"])

      assert {{:ok, %{version: "9.9.9"}}, receipt} =
               Installer.install_extension(site.id, "mishka_receipt_probe", %{}, nil,
                 source: :admin
               )

      assert receipt.status == :verified
      assert receipt.site_id == site.id
      assert %{status: :verified, layer: :db} = stage(receipt, :installed_record)

      assert %{status: :verified, observed: %{version: "9.9.9"}} =
               stage(receipt, :installed_version)

      assert {:ok, _} = Receipts.get(receipt.id, admin)
    end

    test "a report that left a page out is partial, not verified", %{site: site} do
      assert {{:ok, _report}, receipt} =
               Installer.install_extension(site.id, "mishka_receipt_probe", %{"skip" => true})

      assert %{status: :unverified, reason: :pages_left_out, observed: %{skipped_pages: 1}} =
               stage(receipt, :report_complete)

      assert receipt.status == :partial
    end

    test "an extension that caught its own failure is a failed receipt with nothing of its message",
         %{
           site: site
         } do
      assert {{:error, {:extension_failed, _message}}, receipt} =
               Installer.install_extension(site.id, "mishka_receipt_probe", %{"fail" => true})

      assert receipt.status == :failed
      assert %{status: :failed, reason: :refused} = stage(receipt, :action_committed)
      assert %{status: :unverified, reason: :not_reached} = stage(receipt, :installed_record)
      refute inspect(receipt) =~ "private details"
    end

    test "with receipts off it is the plain install", %{site: site} do
      Receipts.switch(false)

      assert {{:ok, %{version: "9.9.9"}}, nil} =
               Installer.install_extension(site.id, "mishka_receipt_probe")
    end
  end

  describe "plugin/3" do
    setup do
      on_exit(fn -> Event.unregister(:name, AgentLifecycleProbe, false) end)
    end

    test "register and unregister are read back from the registry" do
      assert {{:ok, _}, registered} = Installer.plugin(:register, AgentLifecycleProbe)
      assert registered.status == :verified

      assert %{status: :verified, layer: :db, observed: %{status: _}} =
               stage(registered, :registry_status)

      assert {{:ok, _}, unregistered} = Installer.plugin(:unregister, AgentLifecycleProbe)
      assert unregistered.status == :verified
      assert %{observed: %{present: false}} = stage(unregistered, :registry_status)
    end

    test "a step the installer refuses is failed, and its checks never reached" do
      assert {{:error, _}, receipt} = Installer.plugin(:stop, AgentLifecycleProbe)

      assert receipt.status == :failed
      assert %{status: :unverified, reason: :not_reached} = stage(receipt, :registry_status)
    end

    test "a start that leaves the plugin unhealthy is verified in the registry and says so" do
      {{:ok, _}, _registered} = Installer.plugin(:register, AgentLifecycleProbe)

      {_started, receipt} = Installer.plugin(:start, AgentLifecycleProbe)

      # Never supervised, so no process answers for it: the registry says started, the probe does
      # not agree, and the receipt keeps both.
      assert %{status: :failed, reason: :unhealthy, observed: %{alive?: false}} =
               stage(receipt, :plugin_health)
    end
  end

  # Refused or raised, the receipt is the same: failed, its checks never reached. Which one it is
  # depends on how the installer is configured, so the receipt is read back rather than returned.
  test "a library that does not install is a failed receipt" do
    master = create_user_with_permissions!(["admin:dashboard:*"])
    library = %{app: "mishka_no_such_library", version: "0.0.1", path: "/nowhere"}

    result =
      try do
        Installer.install_library(library)
      rescue
        error -> {:raised, error}
      end

    refute match?({{:ok, _}, _}, result)

    assert [receipt] = Receipts.recent(master, operation: "installer:library:install", limit: 1)
    assert receipt.status == :failed
    assert %{status: :unverified, reason: :not_reached} = stage(receipt, :registry_record)
  end
end
