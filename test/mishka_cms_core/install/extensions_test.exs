defmodule MishkaCmsCore.Install.ExtensionsTest do
  @moduledoc """
  The two per-site answers an extension's installer keeps, and the one thing about them that a
  screen cannot tell you: that they can be WRITTEN.

  A definition that renders is not a definition that saves. `MishkaCmsCore.Runtime.Setting`
  constrains `source` to `[:core, :extension, :plugin]`, and one declared outside that set draws
  perfectly, takes the admin's click, and comes back as "some settings could not be saved" with
  nothing saying which. That is how this was found — in the browser, not here — so it is asserted
  here now: every definition this module hands out is written through the same façade the settings
  screen writes through.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Install.Extensions
  alias MishkaCmsCore.Settings

  setup do
    {:ok, site: create_site!(name: "extset#{System.unique_integer([:positive])}")}
  end

  describe "settings/2" do
    test "declares both answers, per site, on the extension's own tab" do
      [installed, active] = Extensions.settings(:mishka_shop, "shop")

      assert installed.key == "mishka_shop.installed"
      assert installed.scope == :site
      assert installed.category == "shop"
      refute installed.editable?, "the version a site was set up at is state, not a preference"

      assert active.key == "mishka_shop.active"
      assert active.scope == :site
      assert active.type == :boolean
      assert active.default == true
    end

    # THE ONE THE BROWSER CAUGHT. `source` is an enum on the resource, and the screen reports a
    # value outside it only as a sentence about "some settings".
    test "declares a source the setting resource accepts, so the screen can save it", %{
      site: site
    } do
      for definition <- Extensions.settings(:mishka_shop, "shop") do
        assert definition.source in [:core, :extension, :plugin],
               "#{definition.key} declares source #{inspect(definition.source)}, which the " <>
                 "resource refuses"

        assert {:ok, _written} =
                 Settings.put(definition.key, writable(definition), site_id: site.id),
               "#{definition.key} could not be written"
      end
    end
  end

  describe "installed?/2 and active?/2" do
    test "a site nobody set up has no version, and is still wanted", %{site: site} do
      refute Extensions.installed?(site.id, :mishka_shop)
      assert Extensions.installed_version(site.id, :mishka_shop) == nil

      assert Extensions.active?(site.id, :mishka_shop),
             "an extension is wanted until somebody switches it off"
    end

    test "marking it records the version, per site", %{site: site} do
      other = create_site!(name: "extother#{System.unique_integer([:positive])}")

      :ok = Extensions.mark_installed!(site.id, :mishka_shop, "1.2.3")

      assert Extensions.installed_version(site.id, :mishka_shop) == "1.2.3"
      assert Extensions.installed?(site.id, :mishka_shop)

      refute Extensions.installed?(other.id, :mishka_shop),
             "one site's install answered for another"
    end

    # A VERSION IS NOT ALWAYS KNOWN, and "set up, version unknown" is still set up — an installer
    # that recorded nothing would send the admin back to the installer for ever.
    test "records that it happened even when the version is not known", %{site: site} do
      :ok = Extensions.mark_installed!(site.id, :mishka_shop, nil)

      assert Extensions.installed?(site.id, :mishka_shop)
    end

    test "switched off is remembered, and only for that site", %{site: site} do
      other = create_site!(name: "extonoff#{System.unique_integer([:positive])}")

      {:ok, _} = Settings.put("mishka_shop.active", false, site_id: site.id)

      refute Extensions.active?(site.id, :mishka_shop)
      assert Extensions.active?(other.id, :mishka_shop)
    end
  end

  describe "install/3" do
    # NOTHING ANSWERED IS NOT NOTHING TO DO. A screen told "it worked" over a site that got nothing
    # would send the admin looking for pages that were never written.
    test "refuses a key no plugin answers to, and records no install", %{site: site} do
      assert {:error, :no_plugin_answered} = Extensions.install(site.id, "mishka_nothing")

      refute Extensions.installed?(site.id, "mishka_nothing")
    end
  end

  defp writable(%{type: :boolean}), do: true
  defp writable(%{type: :string}), do: "1.0.0"
end
