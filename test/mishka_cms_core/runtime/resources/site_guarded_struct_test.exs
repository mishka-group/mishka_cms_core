# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.SiteGuardedStructTest do
  @moduledoc """
  Tests the GuardedStruct sanitize/validate pipeline wired into the Site
  resource via `GuardedStruct.AshResource`.

  Covers the layer GuardedStruct contributes on top of Ash's built-in
  attribute constraints — sanitize (trim/downcase), defense-in-depth
  type/range/enum validation, and the pipeline's behaviour through
  `Ash.Changeset.for_create/3` + `Ash.create/1`.

  The pipeline-level checks via `Site.__guarded_change__/1` document the
  raw error shape so future refactors don't accidentally weaken it.
  """

  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false
  import Ash.Test
  alias MishkaCmsCore.Runtime.Site
  @moduletag :unit

  describe "guardedstruct introspection" do
    test "resource exposes the guarded field set" do
      assert MapSet.new([
               :name,
               :host,
               :priority,
               :active,
               :master,
               :mode,
               :frontend_domain,
               :allowed_origins
             ]) == Site.__guarded_field_name_set__()
    end

    test "GuardedStruct.AshResource.Change is registered as a change" do
      assert Site
             |> Ash.Resource.Info.changes()
             |> Enum.any?(fn c -> c.change == {GuardedStruct.AshResource.Change, []} end)
    end

    test "every declared field appears in the field meta map" do
      for name <- [
            :name,
            :host,
            :priority,
            :active,
            :master,
            :mode,
            :frontend_domain,
            :allowed_origins
          ] do
        assert %{name: ^name} = Site.__guarded_field_meta__(name)
      end
    end
  end

  describe "direct pipeline via __guarded_change__/1" do
    test "trims and downcases host" do
      assert {:ok, %{host: "mishka.tools"}} =
               Site.__guarded_change__(%{name: "ok-site", host: "  Mishka.TOOLS  "})
    end

    test "trims name without downcasing (slugify owns case)" do
      assert {:ok, %{name: "My Awesome Site"}} =
               Site.__guarded_change__(%{name: "  My Awesome Site  ", host: "valid-host.io"})
    end

    test "trims and downcases frontend_domain when given a string" do
      assert {:ok, %{frontend_domain: "app.example.com"}} =
               Site.__guarded_change__(%{
                 name: "valid-name",
                 host: "valid-host.io",
                 frontend_domain: "  App.Example.COM  "
               })
    end

    test "passes nil frontend_domain through untouched" do
      assert {:ok, attrs} =
               Site.__guarded_change__(%{
                 name: "valid-name",
                 host: "valid-host.io",
                 frontend_domain: nil
               })

      assert attrs.frontend_domain == nil
    end

    test "passes empty-string frontend_domain through untouched" do
      assert {:ok, %{frontend_domain: ""}} =
               Site.__guarded_change__(%{
                 name: "valid-name",
                 host: "valid-host.io",
                 frontend_domain: ""
               })
    end

    test "rejects name shorter than min_len=3" do
      assert {:error, errs} = Site.__guarded_change__(%{name: "ab", host: "ok.io"})
      assert Enum.any?(errs, &match?(%{field: :name, action: :min_len}, &1))
    end

    test "rejects name longer than max_len=70" do
      long = String.duplicate("a", 71)
      assert {:error, errs} = Site.__guarded_change__(%{name: long, host: "ok.io"})
      assert Enum.any?(errs, &match?(%{field: :name, action: :max_len}, &1))
    end

    test "rejects host with non-string type" do
      assert {:error, errs} = Site.__guarded_change__(%{name: "ok", host: 123})
      assert Enum.any?(errs, &match?(%{field: :host}, &1))
    end

    test "rejects priority outside 0..100" do
      assert {:error, errs1} =
               Site.__guarded_change__(%{name: "valid-name", host: "valid-host.io", priority: -1})

      assert Enum.any?(errs1, &match?(%{field: :priority}, &1))

      assert {:error, errs2} =
               Site.__guarded_change__(%{
                 name: "valid-name",
                 host: "valid-host.io",
                 priority: 101
               })

      assert Enum.any?(errs2, &match?(%{field: :priority}, &1))
    end

    test "rejects mode outside the declared atom enum" do
      assert {:error, errs} =
               Site.__guarded_change__(%{name: "valid-name", host: "valid-host.io", mode: :bogus})

      assert Enum.any?(errs, &match?(%{field: :mode}, &1))
    end

    test "accepts each declared mode" do
      for m <- [:api_only, :phoenix_only, :hybrid] do
        assert {:ok, %{mode: ^m}} =
                 Site.__guarded_change__(%{name: "valid-name", host: "valid-host.io", mode: m})
      end
    end

    test "rejects non-boolean active / master" do
      assert {:error, errs} =
               Site.__guarded_change__(%{
                 name: "valid-name",
                 host: "valid-host.io",
                 active: "yes"
               })

      assert Enum.any?(errs, &match?(%{field: :active}, &1))
    end

    test "rejects non-list allowed_origins" do
      assert {:error, errs} =
               Site.__guarded_change__(%{
                 name: "ok",
                 host: "ok.io",
                 allowed_origins: "not-a-list"
               })

      assert Enum.any?(errs, &match?(%{field: :allowed_origins}, &1))
    end

    test "empty input is a no-op (Ash enforces allow_nil? on its own attrs)" do
      assert {:ok, %{}} = Site.__guarded_change__(%{})
    end
  end

  describe "sanitize lands in the changeset via Ash.create/1" do
    test "host is downcased+trimmed before insert" do
      {:ok, site} =
        Site
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Cleaned Host", host: "  MIXED.Case.COM  "},
          authorize?: false
        )
        |> Ash.create()

      assert site.host == "mixed.case.com"
    end

    test "frontend_domain is downcased+trimmed before insert" do
      {:ok, site} =
        Site
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "With Frontend",
            host: "with-frontend.io",
            frontend_domain: "  Front.Example.COM  "
          },
          authorize?: false
        )
        |> Ash.create()

      assert site.frontend_domain == "front.example.com"
    end

    test "nil frontend_domain stays nil after insert" do
      {:ok, site} =
        Site
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Nil Frontend", host: "nil-frontend.io", frontend_domain: nil},
          authorize?: false
        )
        |> Ash.create()

      assert site.frontend_domain == nil
    end

    test "host is re-sanitized on update" do
      site =
        Site
        |> Ash.Changeset.for_create(
          :create,
          %{name: "To Update", host: "to-update.io"},
          authorize?: false
        )
        |> Ash.create!()

      updated =
        site
        |> Ash.Changeset.for_update(:update, %{host: "  UPDATED.IO  "}, authorize?: false)
        |> Ash.update!()

      assert updated.host == "updated.io"
    end
  end

  describe "Ash strips invalid values before changes run" do
    test "out-of-range priority is replaced by the attribute default before changes see it" do
      changeset =
        Ash.Changeset.for_create(
          Site,
          :create,
          %{name: "valid-name", host: "valid-host.io", priority: 101},
          authorize?: false
        )

      refute changeset.valid?
      assert changeset.attributes.priority == 0
      assert Enum.any?(changeset.errors, &match?(%{field: :priority}, &1))
    end

    test "short name is removed from attributes before changes see it" do
      changeset =
        Ash.Changeset.for_create(
          Site,
          :create,
          %{name: "ab", host: "good-host.io"},
          authorize?: false
        )

      refute changeset.valid?
      refute Map.has_key?(changeset.attributes, :name)

      assert Enum.any?(
               changeset.errors,
               &(&1.field == :name and String.contains?(&1.message, "length"))
             )
    end

    test "the GuardedStruct pipeline still rejects bad input when called directly" do
      assert {:error, errs} =
               Site.__guarded_change__(%{name: "ab", host: "valid-host.io"})

      assert Enum.any?(errs, &(&1.field == :name and &1.action == :min_len))
    end
  end

  describe ":create action — GuardedStruct cooperates with slugify and other changes" do
    test "all expected changes are registered on the resource" do
      change_modules =
        Site
        |> Ash.Resource.Info.changes()
        |> Enum.map(fn c -> elem(c.change, 0) end)

      assert GuardedStruct.AshResource.Change in change_modules
      assert MishkaCmsCore.Runtime.Resources.Changes.ScheduleSiteRuntime in change_modules
    end

    test "host downcase + name slugify both land on the persisted row" do
      {:ok, site} =
        Site
        |> Ash.Changeset.for_create(
          :create,
          %{name: "My Awesome SITE", host: "  Mixed.CASE.example.com  "},
          authorize?: false
        )
        |> Ash.create()

      assert site.name == "my-awesome-site"
      assert site.host == "mixed.case.example.com"
    end

    test "trailing space in name survives both pipelines (slugify trims, GuardedStruct trims)" do
      {:ok, site} =
        Site
        |> Ash.Changeset.for_create(
          :create,
          %{name: "  Padded Name  ", host: "padded-host.io"},
          authorize?: false
        )
        |> Ash.create()

      assert site.name == "padded-name"
      refute String.starts_with?(site.name, " ")
      refute String.ends_with?(site.name, " ")
    end

    test "update :update action — host gets re-sanitized through the change pipeline" do
      {:ok, site} =
        Site
        |> Ash.Changeset.for_create(
          :create,
          %{name: "To Be Updated", host: "to-be-updated.io"},
          authorize?: false
        )
        |> Ash.create()

      {:ok, updated} =
        site
        |> Ash.Changeset.for_update(:update, %{host: "  AFTER.UPDATE.IO  "}, authorize?: false)
        |> Ash.update()

      assert updated.host == "after.update.io"
    end
  end

  describe "Proof that GuardedStruct.validate fires through Ash — using :hostname (no Ash equivalent)" do
    test "host with underscore passes Ash constraints, fails GuardedStruct :hostname" do
      changeset =
        Ash.Changeset.for_create(
          Site,
          :create,
          %{name: "regex-target", host: "bad_host.io"},
          authorize?: false
        )

      refute changeset.valid?
      assert changeset.attributes.host == "bad_host.io"

      host_messages =
        changeset.errors
        |> Enum.filter(&match?(%{field: :host}, &1))
        |> Enum.map(& &1.message)

      assert Enum.any?(host_messages, &String.contains?(&1, "Invalid hostname format")),
             "expected GuardedStruct :hostname error in #{inspect(host_messages)}"
    end

    test "host matching the hostname pattern passes the GuardedStruct layer" do
      {:ok, site} =
        Site
        |> Ash.Changeset.for_create(
          :create,
          %{name: "regex-ok", host: "good-host.io"},
          authorize?: false
        )
        |> Ash.create()

      assert site.host == "good-host.io"
    end
  end

  describe "allowed_origins each-element sanitize fires through Ash (within DomainValidator's constraints)" do
    test "duplicates are removed by sanitize(uniq) when each element is individually valid" do
      {:ok, site} =
        Site
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "origins-uniq",
            host: "origins-uniq.io",
            allowed_origins: ["https://one.com", "https://one.com", "https://two.com"]
          },
          authorize?: false
        )
        |> Ash.create()

      assert site.allowed_origins == ["https://one.com", "https://two.com"]
    end

    test "non-list allowed_origins is rejected by validate(list)" do
      assert {:error, errs} =
               Site.__guarded_change__(%{
                 name: "valid-name",
                 host: "valid-host.io",
                 allowed_origins: "not-a-list"
               })

      assert Enum.any?(errs, &match?(%{field: :allowed_origins, action: :list}, &1))
    end

    test "direct __guarded_change__/1: sanitize trims/downcases each origin, uniq dedupes, regex passes" do
      assert {:ok,
              %{
                name: "valid-name",
                host: "valid-host.io",
                allowed_origins: ["https://one.com", "https://two.com"]
              }} =
               Site.__guarded_change__(%{
                 name: "valid-name",
                 host: "valid-host.io",
                 allowed_origins: [
                   "  HTTPS://One.COM  ",
                   "  https://one.com  ",
                   "https://two.com"
                 ]
               })
    end

    test "direct __guarded_change__/1: bare-hostname origin (no scheme) is rejected by the regex" do
      assert {:error, errs} =
               Site.__guarded_change__(%{
                 name: "valid-name",
                 host: "valid-host.io",
                 allowed_origins: ["https://ok.com", "missing-scheme.com"]
               })

      assert [
               %{
                 field: :allowed_origins,
                 action: :regex,
                 __index__: 1,
                 message: "Invalid format in the allowed_origins field"
               }
             ] = errs
    end
  end

  describe "validate errors block Ash.create/1" do
    test "invalid mode atom is rejected" do
      changeset =
        Ash.Changeset.for_create(
          Site,
          :create,
          %{name: "Bad Mode", host: "bad-mode.io", mode: :bogus},
          authorize?: false
        )

      assert_has_error(changeset, fn err ->
        err.__struct__ == Ash.Error.Changes.InvalidAttribute
      end)
    end

    test "priority out of range is rejected" do
      changeset =
        Ash.Changeset.for_create(
          Site,
          :create,
          %{name: "Bad Priority", host: "bad-priority.io", priority: 999},
          authorize?: false
        )

      assert_has_error(changeset, fn err ->
        err.__struct__ == Ash.Error.Changes.InvalidAttribute
      end)
    end
  end
end
