# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.AccessPermissionsMatrixTest do
  @moduledoc """
  Every combination the checker answers, asked the two ways the code asks it: `covers?/2` (does a
  held name grant a required one) and `match?/3` (does an actor pass a policy's list, on the
  surface the request came from, within its own site).

  The expected answers come from the rule written out in `oracle/2`, not from the checker: a held
  name covers itself, `*` covers everything, and a held `prefix:*` covers every name that starts with
  `prefix:`. A generated property holds the checker to that rule over names it has never seen.
  """
  use MishkaCmsCore.DataCase, async: false
  use ExUnitProperties

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User}
  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.Page

  @held [
    "*",
    "admin:*",
    "admin:dashboard:*",
    "admin:api:*",
    "admin:dashboard:runtime:*",
    "admin:api:runtime:*",
    "admin:dashboard:runtime:page",
    "admin:dashboard:runtime:layout",
    "admin:dashboard:runtime:component",
    "admin:api:runtime:page",
    "admin:dashboard:runtime",
    "admin:dashboard:code",
    "admin:api:code",
    "admin:dashboard:setting",
    "admin:dashboard:blog:*",
    "admin:dashboard:blog:post"
  ]

  @required [
    "*",
    "admin:*",
    "admin:dashboard:*",
    "admin:api:*",
    "admin:dashboard:runtime:*",
    "admin:api:runtime:*",
    "admin:dashboard:runtime:page",
    "admin:dashboard:runtime:layout",
    "admin:dashboard:runtime:error_page",
    "admin:dashboard:runtime:js_hook",
    "admin:api:runtime:page",
    "admin:dashboard:runtime",
    "admin:dashboard:code",
    "admin:api:code",
    "admin:dashboard:setting",
    "admin:dashboard:blog:post"
  ]

  @runtime_sections ~w(site page layout component error_page stylesheet js_hook media translation redirect activity)

  @dashboard %{}
  @api %{shared: %{admin_surface: :api}}

  # THE RULE, written apart from the checker it judges.
  defp oracle(held, required) do
    held == required or held == "*" or
      (String.ends_with?(held, ":*") and
         String.starts_with?(required, String.trim_trailing(held, "*")))
  end

  defp holder(names, site_id \\ nil) do
    %User{
      id: Ecto.UUID.generate(),
      site_id: site_id,
      permissions: Enum.map(names, &%Permission{name: &1})
    }
  end

  defp surface_of(name) do
    case String.split(name, ":", parts: 3) do
      ["admin", "dashboard", _rest] -> :dashboard
      ["admin", "api", _rest] -> :api
      _other -> :both
    end
  end

  describe "covers?/2 — every held name against every required name" do
    test "matches the rule for each of the #{length(@held) * length(@required)} pairs" do
      wrong =
        for held <- @held,
            required <- @required,
            AccessPermissions.covers?(held, required) != oracle(held, required),
            do: {held, required, AccessPermissions.covers?(held, required)}

      assert wrong == []
    end

    test "each wildcard covers every runtime section below it, and no leaf covers a sibling" do
      for section <- @runtime_sections, surface <- ["dashboard", "api"] do
        name = "admin:#{surface}:runtime:#{section}"

        for wildcard <- ["*", "admin:*", "admin:#{surface}:*", "admin:#{surface}:runtime:*"],
            do: assert(AccessPermissions.covers?(wildcard, name), "#{wildcard} misses #{name}")

        other = if surface == "dashboard", do: "api", else: "dashboard"

        for wildcard <- ["admin:#{other}:*", "admin:#{other}:runtime:*", "admin:#{surface}:code"],
            do: refute(AccessPermissions.covers?(wildcard, name), "#{wildcard} covers #{name}")

        for sibling <- @runtime_sections -- [section],
            do: refute(AccessPermissions.covers?("admin:#{surface}:runtime:#{sibling}", name))
      end
    end

    test "a name with no * covers only itself, the bare group name included" do
      refute AccessPermissions.covers?("admin:dashboard:runtime", "admin:dashboard:runtime:page")
      refute AccessPermissions.covers?("admin:dashboard:runtime:page", "admin:dashboard:runtime")

      refute AccessPermissions.covers?(
               "admin:dashboard:runtime:page",
               "admin:dashboard:runtime:*"
             )

      assert AccessPermissions.covers?("admin:dashboard:runtime", "admin:dashboard:runtime")
    end
  end

  describe "covers?/2 — generated names" do
    # A small alphabet, so the generated names share prefixes as often as real ones do.
    defp segment, do: member_of(~w(admin dashboard api runtime page layout code blog x))

    defp name do
      gen all(
            segments <- list_of(segment(), min_length: 1, max_length: 5),
            wildcard <- boolean()
          ) do
        Enum.join(segments, ":") <> if(wildcard, do: ":*", else: "")
      end
    end

    property "agrees with the rule on any pair of names" do
      check all(
              held <- one_of([name(), constant("*")]),
              required <- one_of([name(), constant("*")]),
              max_runs: 2_000
            ) do
        assert AccessPermissions.covers?(held, required) == oracle(held, required)
      end
    end

    property "a name covers itself, * covers every name, and covering chains" do
      check all(a <- name(), b <- name(), c <- name(), max_runs: 1_000) do
        assert AccessPermissions.covers?(a, a)
        assert AccessPermissions.covers?("*", a)

        if AccessPermissions.covers?(a, b) and AccessPermissions.covers?(b, c),
          do: assert(AccessPermissions.covers?(a, c))
      end
    end
  end

  describe "match?/3 — one required name, on each surface" do
    test "passes exactly when a held name covers it and the name counts on the surface" do
      wrong =
        for held <- @held,
            required <- @required,
            {context, surface} <- [{@dashboard, :dashboard}, {@api, :api}],
            counts? = surface_of(required) in [surface, :both],
            expected = counts? and oracle(held, required),
            AccessPermissions.match?(holder([held]), context, permissions: [required]) != expected,
            do: {held, required, surface}

      assert wrong == []
    end

    test "a policy naming one runtime section is met by that section and every wildcard above it" do
      policy = [permissions: ["admin:dashboard:runtime:page", "admin:api:runtime:page"]]

      for held <-
            ~w(* admin:* admin:dashboard:* admin:dashboard:runtime:* admin:dashboard:runtime:page),
          do: assert(AccessPermissions.match?(holder([held]), @dashboard, policy), held)

      for held <- ~w(* admin:* admin:api:* admin:api:runtime:* admin:api:runtime:page),
          do: assert(AccessPermissions.match?(holder([held]), @api, policy), held)

      for held <-
            ~w(admin:dashboard:runtime:layout admin:dashboard:runtime admin:dashboard:code admin:dashboard:setting admin:dashboard:blog:*),
          context <- [@dashboard, @api],
          do: refute(AccessPermissions.match?(holder([held]), context, policy), held)

      for held <- ~w(admin:api:* admin:api:runtime:* admin:api:runtime:page),
          do: refute(AccessPermissions.match?(holder([held]), @dashboard, policy), held)

      for held <- ~w(admin:dashboard:* admin:dashboard:runtime:* admin:dashboard:runtime:page),
          do: refute(AccessPermissions.match?(holder([held]), @api, policy), held)
    end

    test "a list is met by any one entry, and one held name among many is enough" do
      policy = [permissions: ["admin:dashboard:runtime:page", "admin:dashboard:code"]]

      assert AccessPermissions.match?(holder(["admin:dashboard:code"]), @dashboard, policy)

      assert AccessPermissions.match?(
               holder(["admin:dashboard:runtime:page"]),
               @dashboard,
               policy
             )

      assert AccessPermissions.match?(
               holder(["admin:dashboard:setting", "admin:dashboard:runtime:page"]),
               @dashboard,
               policy
             )

      refute AccessPermissions.match?(
               holder(["admin:dashboard:runtime:layout"]),
               @dashboard,
               policy
             )
    end
  end

  describe "match?/3 — {:under, prefix} and {:under, :surface}" do
    test "anything under the prefix counts, and every wildcard over it" do
      under = [permissions: [{:under, "admin:dashboard:runtime"}]]

      for held <-
            ~w(* admin:* admin:dashboard:* admin:dashboard:runtime:* admin:dashboard:runtime:page admin:dashboard:runtime:media),
          do: assert(AccessPermissions.match?(holder([held]), @dashboard, under), held)

      for held <-
            ~w(admin:dashboard:runtime admin:dashboard:code admin:api:runtime:page admin:dashboard:blog:*),
          do: refute(AccessPermissions.match?(holder([held]), @dashboard, under), held)
    end

    test ":surface is the request's own surface, as an entry or as the under: option" do
      for opts <- [[permissions: [{:under, :surface}]], [under: :surface]] do
        assert AccessPermissions.match?(
                 holder(["admin:dashboard:runtime:page"]),
                 @dashboard,
                 opts
               )

        refute AccessPermissions.match?(holder(["admin:dashboard:runtime:page"]), @api, opts)
        assert AccessPermissions.match?(holder(["admin:api:runtime:page"]), @api, opts)
        refute AccessPermissions.match?(holder(["admin:api:runtime:page"]), @dashboard, opts)

        for held <- ["*", "admin:*"],
            context <- [@dashboard, @api],
            do: assert(AccessPermissions.match?(holder([held]), context, opts))
      end
    end

    test "under: and permissions: are added together" do
      opts = [permissions: ["admin:dashboard:code"], under: "admin:dashboard:runtime"]

      assert AccessPermissions.match?(holder(["admin:dashboard:code"]), @dashboard, opts)
      assert AccessPermissions.match?(holder(["admin:dashboard:runtime:site"]), @dashboard, opts)
      refute AccessPermissions.match?(holder(["admin:dashboard:setting"]), @dashboard, opts)
    end
  end

  describe "match?/3 — what grants nothing" do
    test "no actor, no permissions, nothing required, or an entry that is no requirement" do
      refute AccessPermissions.match?(nil, @dashboard, permissions: ["*"])
      refute AccessPermissions.match?(holder([]), @dashboard, permissions: ["admin:dashboard:*"])
      refute AccessPermissions.match?(holder(["*"]), @dashboard, permissions: [])
      refute AccessPermissions.match?(holder(["*"]), @dashboard, [])
      refute AccessPermissions.match?(holder(["*"]), @dashboard, permissions: [{:area, "page"}])
      refute AccessPermissions.match?(holder(["*"]), @dashboard, permissions: [:page])
    end
  end

  describe "match?/3 — as a policy asks it, on a real changeset" do
    setup do
      site = create_site!()
      other = create_site!()
      {:ok, site: site, other: other}
    end

    defp changeset(tenant, surface) do
      Page
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(tenant)
      |> then(fn cs ->
        if surface == :api,
          do: Ash.Changeset.set_context(cs, %{shared: %{admin_surface: :api}}),
          else: cs
      end)
    end

    test "the surface is read from the changeset", ctx do
      policy = [permissions: ["admin:dashboard:runtime:page", "admin:api:runtime:page"]]
      dashboard = %{subject: changeset(ctx.site.id, :dashboard)}
      api = %{subject: changeset(ctx.site.id, :api)}

      assert AccessPermissions.surface(dashboard) == :dashboard
      assert AccessPermissions.surface(api) == :api

      page_admin = holder(["admin:dashboard:runtime:page"], ctx.site.id)
      api_admin = holder(["admin:api:runtime:page"], ctx.site.id)

      assert AccessPermissions.match?(page_admin, dashboard, policy)
      refute AccessPermissions.match?(page_admin, api, policy)
      assert AccessPermissions.match?(api_admin, api, policy)
      refute AccessPermissions.match?(api_admin, dashboard, policy)
    end

    test "a site user holds its names on its own site's tenant only; a master on every one",
         ctx do
      policy = [permissions: ["admin:dashboard:runtime:*"]]

      site_admin = holder(["*"], ctx.site.id)
      master = holder(["admin:dashboard:runtime:page", "admin:dashboard:runtime:*"])

      assert AccessPermissions.match?(
               site_admin,
               %{subject: changeset(ctx.site.id, :dashboard)},
               policy
             )

      refute AccessPermissions.match?(
               site_admin,
               %{subject: changeset(ctx.other.id, :dashboard)},
               policy
             )

      assert AccessPermissions.match?(
               master,
               %{subject: changeset(ctx.site.id, :dashboard)},
               policy
             )

      assert AccessPermissions.match?(
               master,
               %{subject: changeset(ctx.other.id, :dashboard)},
               policy
             )
    end
  end

  describe "the helpers the gates share" do
    test "holds_under?/2 answers for a prefix, wildcards over it included" do
      assert AccessPermissions.holds_under?(
               holder(["admin:dashboard:runtime:page"]),
               "admin:dashboard"
             )

      assert AccessPermissions.holds_under?(
               holder(["admin:dashboard:runtime:page"]),
               "admin:dashboard:runtime"
             )

      assert AccessPermissions.holds_under?(
               holder(["admin:dashboard:*"]),
               "admin:dashboard:runtime"
             )

      assert AccessPermissions.holds_under?(holder(["*"]), "admin:api:runtime")

      refute AccessPermissions.holds_under?(
               holder(["admin:dashboard:code"]),
               "admin:dashboard:runtime"
             )

      refute AccessPermissions.holds_under?(holder(["admin:api:runtime:page"]), "admin:dashboard")
      refute AccessPermissions.holds_under?(nil, "admin:dashboard")
    end

    test "beyond/2 names what the actor holds nothing covering" do
      runtime = holder(["admin:dashboard:runtime:*"])

      assert AccessPermissions.beyond(runtime, [
               "admin:dashboard:runtime:page",
               "admin:dashboard:runtime:*",
               "admin:dashboard:code",
               "admin:api:runtime:page",
               "*"
             ]) == ["admin:dashboard:code", "admin:api:runtime:page", "*"]

      assert AccessPermissions.beyond(holder(["*"]), ["admin:*", "admin:api:code"]) == []

      assert AccessPermissions.beyond(nil, ["admin:dashboard:runtime:page"]) == [
               "admin:dashboard:runtime:page"
             ]
    end

    test "an actor whose permissions are not loaded has them read, and then matches the same" do
      user = create_user_with_permissions!(["admin:dashboard:runtime:page"])
      bare = Ash.get!(User, user.id, authorize?: false)

      refute Ash.Resource.loaded?(bare, :permissions)

      assert AccessPermissions.match?(bare, @dashboard,
               permissions: ["admin:dashboard:runtime:page"]
             )

      refute AccessPermissions.match?(bare, @dashboard,
               permissions: ["admin:dashboard:runtime:layout"]
             )
    end
  end
end
