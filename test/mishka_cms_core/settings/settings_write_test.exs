# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.SettingsWriteTest do
  @moduledoc """
  The two write paths on `MishkaCmsCore.Settings` and the coercion both editors share.

  `put/3` is the trusted infra path — boot seeding and plugin registration, where there is no user
  to speak for — and deliberately skips authorization. `put_as/4` is what anything an admin typed
  goes through, and it must not: a master writes the global row and any site's, a tenant only its
  own, and a user with no roles nothing. `cast/2` is the gate in front of both, so a value that a
  definition does not allow never reaches a row in the first place.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.Setting
  alias MishkaCmsCore.Settings

  require Ash.Query

  @keys ~w(cms.offline site.title)

  setup do
    site = create_site!()
    other_site = create_site!()

    forget_settings(@keys, [nil, site.id, other_site.id])

    %{
      site: site,
      other_site: other_site,
      master: create_user_with_permissions!(["admin:dashboard:*"]),
      tenant: create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id),
      roleless: create_user!(site_id: site.id)
    }
  end

  defp stored(key, site_id) do
    Setting
    |> Ash.Query.filter(key == ^key)
    |> then(
      &if is_nil(site_id),
        do: Ash.Query.filter(&1, is_nil(site_id)),
        else: Ash.Query.filter(&1, site_id == ^site_id)
    )
    |> Ash.read!(action: :read_any, authorize?: false)
    |> case do
      [%{value: %{"value" => value}}] -> value
      [] -> :none
    end
  end

  describe "put_as/4 — master with roles" do
    test "writes the global row", %{master: master} do
      assert {:ok, true} = Settings.put_as(master, "cms.offline", true)
      assert stored("cms.offline", nil) == true
    end

    test "writes any site's row", %{master: master, site: site, other_site: other_site} do
      assert {:ok, "A"} = Settings.put_as(master, "site.title", "A", site_id: site.id)
      assert {:ok, "B"} = Settings.put_as(master, "site.title", "B", site_id: other_site.id)

      assert stored("site.title", site.id) == "A"
      assert stored("site.title", other_site.id) == "B"
    end
  end

  describe "put_as/4 — tenant with roles" do
    test "writes its own site's row without naming it", %{tenant: tenant, site: site} do
      assert {:ok, "Mine"} = Settings.put_as(tenant, "site.title", "Mine")
      assert stored("site.title", site.id) == "Mine"
    end

    test "is refused another site's row, and writes nothing", %{
      tenant: tenant,
      other_site: other_site
    } do
      assert {:error, _} = Settings.put_as(tenant, "site.title", "Theirs", site_id: other_site.id)
      assert stored("site.title", other_site.id) == :none
    end

    # `site_id: nil` is indistinguishable from omitting it, and for a tenant that means "my own
    # site" — so this does not fail, it lands on the tenant's row. What matters is the one thing a
    # tenant must never manage: the shared global row stays untouched.
    test "cannot reach the shared global row by asking for a nil site", %{
      tenant: tenant,
      site: site
    } do
      assert {:ok, true} = Settings.put_as(tenant, "cms.offline", true, site_id: nil)

      assert stored("cms.offline", nil) == :none
      assert stored("cms.offline", site.id) == true
    end

    test "cannot overwrite a value a master set globally", %{master: master, tenant: tenant} do
      assert {:ok, "Global"} = Settings.put_as(master, "site.title", "Global")
      assert {:ok, "Mine"} = Settings.put_as(tenant, "site.title", "Mine")

      assert stored("site.title", nil) == "Global"
    end
  end

  describe "put_as/4 — tenant without roles" do
    test "writes nothing at all", %{roleless: roleless, site: site} do
      assert {:error, _} = Settings.put_as(roleless, "site.title", "Nope")
      assert stored("site.title", site.id) == :none
    end
  end

  describe "put_as/4 — no actor" do
    test "is refused rather than silently treated as a master" do
      assert {:error, :no_actor} = Settings.put_as(nil, "cms.offline", true)
      assert stored("cms.offline", nil) == :none
    end
  end

  describe "put/3 — the trusted infra path" do
    test "still writes without an actor, which is what boot seeding relies on" do
      assert {:ok, true} = Settings.put("cms.offline", true)
      assert stored("cms.offline", nil) == true
    end
  end

  describe "reads resolve site over global" do
    test "a tenant sees its own value, another tenant the global default", %{
      master: master,
      tenant: tenant,
      site: site,
      other_site: other_site
    } do
      assert {:ok, _} = Settings.put_as(master, "site.title", "Default")
      assert {:ok, _} = Settings.put_as(tenant, "site.title", "Mine")

      assert Settings.get("site.title", nil, site.id) == "Mine"
      assert Settings.get("site.title", nil, other_site.id) == "Default"
      assert Settings.get("site.title") == "Default"
    end
  end

  describe "cast/2" do
    test "clamps an integer to the definition's declared bounds" do
      definition = Settings.define("k", :integer, default: 4, min: 1, max: 12)

      assert Settings.cast(definition, "6") == {:ok, 6}
      assert Settings.cast(definition, "0") == {:ok, 1}
      assert Settings.cast(definition, "99") == {:ok, 12}
      assert Settings.cast(definition, 7) == {:ok, 7}
    end

    test "refuses a number it cannot parse instead of writing a zero" do
      definition = Settings.define("k", :integer, default: 4, min: 1, max: 12)

      assert Settings.cast(definition, "abc") == :error
      assert Settings.cast(definition, "") == :error
      assert Settings.cast(definition, nil) == :error
      assert Settings.cast(definition, "6 posts") == :error
    end

    test "takes a picture as a path on the site or a web address, and nothing else" do
      definition = Settings.define("k", :image, default: "")

      assert Settings.cast(definition, " /uploads/site/media/logo.svg ") ==
               {:ok, "/uploads/site/media/logo.svg"}

      assert Settings.cast(definition, "https://cdn.test/logo.png") ==
               {:ok, "https://cdn.test/logo.png"}

      assert Settings.cast(definition, "") == {:ok, ""}
      assert Settings.cast(definition, "//elsewhere.test/logo.png") == :error
      assert Settings.cast(definition, "javascript:alert(1)") == :error
      assert Settings.cast(definition, "logo.png") == :error
      assert Settings.cast(definition, nil) == :error
    end

    test "reads a checkbox, treating anything absent as false" do
      definition = Settings.define("k", :boolean, default: true)

      assert Settings.cast(definition, "on") == {:ok, true}
      assert Settings.cast(definition, "true") == {:ok, true}
      assert Settings.cast(definition, true) == {:ok, true}
      assert Settings.cast(definition, nil) == {:ok, false}
      assert Settings.cast(definition, "off") == {:ok, false}
    end

    test "refuses a select value that is not one of the declared options" do
      definition = Settings.define("k", :select, default: "a", options: ["a", "b"])

      assert Settings.cast(definition, "a") == {:ok, "a"}
      assert Settings.cast(definition, "b") == {:ok, "b"}
      assert Settings.cast(definition, "c") == :error
    end

    test "accepts a select declared as {label, value} pairs, as a widget descriptor writes them" do
      definition = Settings.define("k", :select, default: 7, options: [{"Seven", 7}, {"Ten", 10}])

      assert Settings.cast(definition, "7") == {:ok, 7}
      assert Settings.cast(definition, 10) == {:ok, 10}
      assert Settings.cast(definition, 8) == :error
    end

    test "takes any binary for a string or text, and refuses a non-binary" do
      assert Settings.cast(Settings.define("k", :string), "hello") == {:ok, "hello"}
      assert Settings.cast(Settings.define("k", :text), "") == {:ok, ""}
      assert Settings.cast(Settings.define("k", :string), nil) == :error
      assert Settings.cast(Settings.define("k", :string), 5) == :error
    end

    test "splits a list typed as comma-separated text, and keeps a list of strings" do
      definition = Settings.define("k", :list, default: ["en"])

      assert Settings.cast(definition, " en, fa ,,en, ar ") == {:ok, ["en", "fa", "ar"]}
      assert Settings.cast(definition, ["en", " fa "]) == {:ok, ["en", "fa"]}
      assert Settings.cast(definition, "") == {:ok, []}
    end

    test "refuses a list holding anything but strings" do
      definition = Settings.define("k", :list, default: ["en"])

      assert Settings.cast(definition, ["en", 5]) == :error
      assert Settings.cast(definition, nil) == :error
    end

    test "refuses a value of the right type that the definition's validate refuses" do
      definition = Settings.define("k", :list, validate: &(&1 != []))

      assert Settings.cast(definition, "en, fa") == {:ok, ["en", "fa"]}
      assert Settings.cast(definition, " , ") == :error
    end

    test "refuses a type it does not know" do
      assert Settings.cast(%{type: :colour}, "red") == :error
      assert Settings.cast(%{}, "red") == :error
    end
  end
end
