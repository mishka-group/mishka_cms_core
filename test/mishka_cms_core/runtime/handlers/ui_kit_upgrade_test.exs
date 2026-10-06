defmodule MishkaCmsCore.Runtime.Handlers.UiKitUpgradeTest do
  @moduledoc """
  A site that already has a kit's components, and a newer bundle on disk.

  Every case here is about the one thing an upgrade is not allowed to do: overwrite work an admin
  did in the builder. `UiKitHandler.install_kit!/2` upserts, so the whole question is WHICH names
  reach it — and that is decided from the stamp the installer writes, a kit name, the version it
  was at and a fingerprint of what it wrote.

  The bundle here is a local one written twice, at `1.0.0` and `2.0.0`, so nothing depends on a
  shipped kit's version staying where it is.

  `async: false` — installs write runtime rows and rebuild the site's modules.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler
  alias MishkaCmsCore.Runtime.Handlers.UiKitUpgrade

  require Ash.Query

  @moduletag :integration

  @chelekom Path.join([:code.priv_dir(:mishka_cms_core), "cms_ui_kits", "chelekom.json"])

  # A component with nothing on it but the two fields that cannot be left out, and one changed value
  # per field an install writes — the pair `digest/1` is asked about field by field.
  @bare %{"name" => "upg-card", "template" => ~s|<span>card</span>|}

  @changed %{
    name: "upg-card-two",
    description: "ours, not the kit's",
    template: ~s|<span>mine</span>|,
    body: "mine",
    format: :surface,
    priority: 7,
    attrs: [%{"name" => "tone", "type" => "string"}],
    slots: [%{"name" => "inner_block"}],
    helpers: [%{"name" => "paint", "args" => "_", "code" => ~s|defp paint(_), do: "x"|}],
    active: false,
    precompile: true,
    required: true,
    stateful: true,
    permissions: ["admin:component:*"],
    examples: ["<.upg_card />"],
    type: "layouts",
    dependencies: ["upg-badge"],
    extra: %{"note" => "mine"}
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "kit_upgrade_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    name = "upgradetown#{System.unique_integer([:positive])}"
    site = create_site!(name: name, host: "#{name}.test", active: true)

    on_exit(fn -> File.rm_rf(dir) end)

    %{
      site: site,
      dir: dir,
      old: write_bundle!(dir, "1.0.0"),
      new: write_bundle!(dir, "2.0.0")
    }
  end

  defp write_bundle!(dir, version) do
    path = Path.join(dir, "upgradekit-#{version}.json")
    File.write!(path, Jason.encode!(bundle(version)))

    path
  end

  # THE TRAILING NEWLINES ARE PART OF THE FIXTURE. A real exporter writes them and `Ash.Type.String`
  # trims them away on the way in, so a bundle without them would never exercise the one thing a
  # fingerprint has to survive: being taken from a file and read back off a row.
  defp bundle(version) do
    %{
      "$schema" => "mishka.ui_kit.bundle.v3",
      "name" => "upgradekit",
      "version" => version,
      "components" => [
        %{
          "name" => "upg-card",
          "type" => "widgets",
          "template" => ~s|<span class={paint(@tone)}>card #{version}</span>\n|,
          "attrs" => [
            %{
              "name" => "tone",
              "type" => "string",
              "opts" => %{"values" => ["calm", "loud"], "default" => "calm"}
            }
          ],
          "helpers" => [
            %{
              "name" => "paint",
              "args" => ~s|"calm"|,
              "code" => ~s|defp paint("calm"), do: "c"\n|
            },
            %{"name" => "paint", "args" => "_", "code" => ~s|defp paint(_), do: "#{version}"\n|}
          ]
        },
        %{"name" => "upg-badge", "type" => "widgets", "template" => ~s|<span>badge</span>\n|},
        %{"name" => "upg-note", "type" => "widgets", "template" => ~s|<p>note</p>\n|}
      ]
    }
  end

  # THE SAME KIT AFTER A SPLIT: the card is drawn out of a badge now, and the badge out of a note.
  # Written at 3.0.0 so the card is outdated on a site holding 1.0.0's rows.
  defp split_bundle!(dir) do
    split = bundle("3.0.0")

    components =
      Enum.map(split["components"], fn component ->
        case component["name"] do
          "upg-card" -> Map.put(component, "dependencies", ["upg-badge"])
          "upg-badge" -> Map.put(component, "dependencies", ["upg-note"])
          _stands_alone -> component
        end
      end)

    path = Path.join(dir, "upgradekit-split.json")
    File.write!(path, Jason.encode!(Map.put(split, "components", components)))

    path
  end

  defp install!(path, site), do: UiKitHandler.install_kit!(path, site_id: site.id)

  defp rows(site, action) do
    Component
    |> Ash.Query.for_read(action, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.read!(authorize?: false, page: [limit: 200])
    |> Map.fetch!(:results)
  end

  defp row(site, name, action \\ :read_any),
    do: Enum.find(rows(site, action), &(&1.name == name))

  defp names(entries), do: entries |> Enum.map(& &1.name) |> Enum.sort()

  defp edit!(site, name, template) do
    site
    |> row(name)
    |> Ash.update!(%{template: template},
      action: :master_update,
      authorize?: false,
      tenant: site.id
    )
  end

  # The stamp as a row carries it, which is the only form anything here may read: a plan is built
  # from what is in the database, not from what the install returned.
  defp stamp(site, name), do: row(site, name).extra

  describe "what an install records" do
    test "stamps every component with the kit, its version and a fingerprint", %{
      site: site,
      old: old
    } do
      install!(old, site)

      for name <- ~w(upg-card upg-badge upg-note) do
        assert %{"ui_kit" => "upgradekit", "ui_kit_version" => "1.0.0"} = stamp(site, name)
        assert byte_size(stamp(site, name)["ui_kit_digest"]) == 64
      end
    end

    # THE HALF THAT CANNOT BE ASSERTED ANYWHERE ELSE. The fingerprint is taken from the params the
    # install is about to write and read back off the stored row — through Ash's casting, embedded
    # helper structs and a jsonb round trip. If those two do not land on the same digest, every row
    # on every site reads as edited and the safe group is empty for ever.
    test "takes a fingerprint the stored row still answers to", %{site: site, old: old} do
      install!(old, site)

      for name <- ~w(upg-card upg-badge upg-note) do
        row = row(site, name)

        assert UiKitUpgrade.digest(row) == row.extra["ui_kit_digest"],
               "#{name}'s fingerprint does not survive being written"
      end
    end

    test "stops answering once somebody edits the row", %{site: site, old: old} do
      install!(old, site)
      edited = edit!(site, "upg-card", ~s|<span>mine</span>|)

      refute UiKitUpgrade.digest(edited) == edited.extra["ui_kit_digest"]
    end

    # WHAT THE FINGERPRINT HAS TO COVER, counted from the resource rather than from a list somebody
    # kept up to date by hand. `install_kit!/2` hands `master_update` every field it accepts that the
    # bundle carries, so a field the fingerprint leaves out is a field an admin can change while the
    # row still reads "untouched" — and the button that promises to take nothing away takes it.
    #
    # A field added to the action and not to the map below fails here, which is the place that says
    # why it matters.
    test "covers every field an install writes" do
      accepted =
        Component
        |> Ash.Resource.Info.action(:master_update)
        |> Map.fetch!(:accept)
        |> MapSet.new()
        # The row's scope, not its content: an upgrade reads and writes one site at a time and the
        # two sides of the comparison are the same row.
        |> MapSet.delete(:site_id)

      assert MapSet.new(Map.keys(@changed)) == accepted,
             "the fingerprint is claimed over a different set of fields than an install writes"

      for {key, value} <- @changed do
        refute UiKitUpgrade.digest(Map.put(@bare, Atom.to_string(key), value)) ==
                 UiKitUpgrade.digest(@bare),
               "#{key} is written by an install and is not part of the fingerprint"
      end
    end

    # THE BUNDLE THAT SETTLES IT. The fixture above ships three fields; Chelekom ships every one of
    # them across 136 components, with the attrs, slots and delegating helper clauses a hand-written
    # bundle has no reason to have. If any field the fingerprint covers failed to come back off the
    # row as it went in, every one of these rows would read as edited and the safe group would be
    # empty on every site that has the kit.
    test "survives a real bundle of every shape the installer writes", %{site: site} do
      install!(@chelekom, site)

      rows = rows(site, :read_any)
      shipped = @chelekom |> File.read!() |> Jason.decode!() |> Map.fetch!("components")

      assert length(rows) == length(shipped), "not every component of the kit was read back"

      for row <- rows do
        assert UiKitUpgrade.digest(row) == row.extra["ui_kit_digest"],
               "#{row.name}'s fingerprint does not survive being written"
      end
    end

    # THE ONE EXCEPTION, and the reason it is one: the stamp lives in `extra`, so a fingerprint that
    # covered it could never match the row it was taken from.
    test "leaves its own stamp out of what it fingerprints" do
      stamped = %{
        "ui_kit" => "upgradekit",
        "ui_kit_version" => "1.0.0",
        "ui_kit_digest" => String.duplicate("a", 64)
      }

      assert UiKitUpgrade.digest(Map.put(@bare, "extra", stamped)) == UiKitUpgrade.digest(@bare)
    end
  end

  describe "a site already on the newest bundle" do
    setup %{site: site, new: new} do
      install!(new, site)
      :ok
    end

    test "has every component current and nothing to offer", %{site: site, new: new} do
      assert {:ok, plan} = UiKitUpgrade.plan(new, site.id)

      assert names(plan.current) == ~w(upg-badge upg-card upg-note)
      assert plan.outdated == []
      assert plan.choice == []
      assert plan.version == "2.0.0"
      assert plan.kit == "upgradekit"

      assert Enum.map(plan.current, &UiKitUpgrade.note/1) == [
               "version 2.0.0",
               "version 2.0.0",
               "version 2.0.0"
             ]
    end

    test "is told so rather than written to", %{site: site, new: new} do
      before = row(site, "upg-card")

      assert {:ok, report} = UiKitUpgrade.upgrade!(new, site.id)

      assert report.updated == []
      assert UiKitUpgrade.message(report) == "Every component this kit ships is up to date."
      assert row(site, "upg-card").updated_at == before.updated_at
    end

    # AN EDIT AT THE CURRENT VERSION IS NOT A PROBLEM TO REPORT. There is nothing newer to give the
    # row, so listing it among the ones needing a decision would ask the admin for a decision that
    # has no second option — and NOTHING may write it either, at either setting. A row the bundle
    # has nothing newer for is a row an upgrade has no business touching, and the admin pressing the
    # second button is answering a question about the rows that are behind, not offering up this one.
    test "counts an edited row as current, and writes it at neither setting", %{
      site: site,
      new: new
    } do
      edit!(site, "upg-card", ~s|<span>mine</span>|)

      assert {:ok, plan} = UiKitUpgrade.plan(new, site.id)

      assert "upg-card" in names(plan.current)
      assert plan.choice == []

      for include <- [:safe, :all] do
        assert {:ok, report} = UiKitUpgrade.upgrade!(new, site.id, include: include)

        assert report.updated == []

        assert row(site, "upg-card").template == ~s|<span>mine</span>|,
               "pressing #{include} wrote over an edit the bundle had nothing newer for"
      end
    end
  end

  describe "a site on an older bundle" do
    setup %{site: site, old: old} do
      install!(old, site)
      :ok
    end

    test "reports every untouched row as outdated and safe", %{site: site, new: new} do
      assert {:ok, plan} = UiKitUpgrade.plan(new, site.id)

      assert names(plan.outdated) == ~w(upg-badge upg-card upg-note)
      assert plan.current == []
      assert plan.choice == []

      assert Enum.map(plan.outdated, &UiKitUpgrade.note/1) == [
               "installed from 1.0.0, untouched",
               "installed from 1.0.0, untouched",
               "installed from 1.0.0, untouched"
             ]
    end

    test "takes the newer components, and says how many", %{site: site, new: new} do
      assert {:ok, report} = UiKitUpgrade.upgrade!(new, site.id)

      assert Enum.sort(report.updated) == ~w(upg-badge upg-card upg-note)
      assert report.edited == []
      assert UiKitUpgrade.message(report) == "Updated 3 components to 2.0.0."

      assert row(site, "upg-card").template == ~s|<span class={paint(@tone)}>card 2.0.0</span>|
      assert stamp(site, "upg-card")["ui_kit_version"] == "2.0.0"
    end

    # IDEMPOTENT, and not by writing the same thing twice: the second press finds every row at the
    # bundle's version and never reaches the installer, which would otherwise rebuild the site's
    # runtime to discover there was nothing to do.
    test "presses twice and writes nothing the second time", %{site: site, new: new} do
      assert {:ok, _first} = UiKitUpgrade.upgrade!(new, site.id)
      written = row(site, "upg-card").updated_at
      versions = version_count(Component.Version, row(site, "upg-card").id, tenant: site.id)

      assert {:ok, second} = UiKitUpgrade.upgrade!(new, site.id)

      assert second.updated == []
      assert row(site, "upg-card").updated_at == written

      assert version_count(Component.Version, row(site, "upg-card").id, tenant: site.id) ==
               versions
    end

    # AN EDIT IS NOT ONLY AN EDIT TO THE MARKUP. `install_kit!/2` writes every field the bundle
    # ships, `active` among them — and a component an admin deliberately took off the site coming
    # back on, compiled into its runtime, is the worst thing the button called "safe" could do. So
    # any field the write replaces puts the row in the pile that asks.
    test "treats a change to what a row IS as an edit, not as untouched", %{site: site, new: new} do
      site
      |> row("upg-card")
      |> Ash.update!(%{active: false, description: "ours, not the kit's"},
        action: :master_update,
        authorize?: false,
        tenant: site.id
      )

      assert {:ok, plan} = UiKitUpgrade.plan(new, site.id)

      assert names(plan.choice) == ~w(upg-card)
      refute "upg-card" in names(plan.outdated)

      assert {:ok, report} = UiKitUpgrade.upgrade!(new, site.id)

      refute "upg-card" in report.updated

      assert row(site, "upg-card").active == false,
             "the safe update switched the component back on"

      assert row(site, "upg-card").description == "ours, not the kit's"
    end

    test "leaves a row the admin edited to the admin", %{site: site, new: new} do
      edit!(site, "upg-card", ~s|<span>mine</span>|)

      assert {:ok, plan} = UiKitUpgrade.plan(new, site.id)

      assert names(plan.choice) == ~w(upg-card)
      assert names(plan.outdated) == ~w(upg-badge upg-note)
      assert UiKitUpgrade.note(hd(plan.choice)) == "edited here since 1.0.0 installed it"

      assert {:ok, report} = UiKitUpgrade.upgrade!(new, site.id)

      assert Enum.sort(report.updated) == ~w(upg-badge upg-note)
      assert report.left == ~w(upg-card)
      assert row(site, "upg-card").template == ~s|<span>mine</span>|

      assert UiKitUpgrade.message(report) ==
               "Updated 2 components to 2.0.0. 1 component left for you to decide on."
    end

    # WHAT MAKES THE CHOICE SAFE TO MAKE. The admin's own version was written when they saved it, and
    # the upgrade adds another — so the row they had is in the component's history either way, and
    # the message says so because an admin who is not told cannot know to look.
    test "keeps what an edited row held when the admin asks for it anyway", %{
      site: site,
      new: new
    } do
      edited = edit!(site, "upg-card", ~s|<span>mine</span>|)

      assert {:ok, report} = UiKitUpgrade.upgrade!(new, site.id, include: :all)

      assert "upg-card" in report.updated
      assert report.edited == ~w(upg-card)
      assert row(site, "upg-card").template == ~s|<span class={paint(@tone)}>card 2.0.0</span>|

      assert version_with_changes(
               Component.Version,
               edited.id,
               %{template: ~s|<span>mine</span>|},
               tenant: site.id
             ),
             "what the admin had is not in the component's history to restore"

      assert UiKitUpgrade.message(report) =~ "kept in its history"
    end

    test "never writes a row the admin archived", %{site: site, new: new} do
      archived = row(site, "upg-note")
      :ok = Ash.destroy!(archived, action: :master_destroy, authorize?: false, tenant: site.id)

      assert {:ok, plan} = UiKitUpgrade.plan(new, site.id)

      assert names(plan.archived) == ~w(upg-note)
      refute "upg-note" in names(plan.outdated)

      assert {:ok, report} = UiKitUpgrade.upgrade!(new, site.id, include: :all)

      refute "upg-note" in report.updated
      assert report.archived == ~w(upg-note)
      refute row(site, "upg-note"), "an archived component came back as a new row"
      assert row(site, "upg-note", :master_archived).template == ~s|<p>note</p>|
    end

    # AN UPGRADE IS NOT AN INSTALL. A site that never had a component, or deleted one, said so — and
    # the extension's "Set up …" button is the surface that adds it back.
    test "never installs a component the site does not have", %{site: site, new: new} do
      gone = row(site, "upg-badge")

      :ok =
        Ash.destroy!(gone, action: :master_permanent_destroy, authorize?: false, tenant: site.id)

      assert {:ok, plan} = UiKitUpgrade.plan(new, site.id)

      assert names(plan.absent) == ~w(upg-badge)

      assert {:ok, report} = UiKitUpgrade.upgrade!(new, site.id, include: :all)

      refute "upg-badge" in report.updated
      assert report.absent == ~w(upg-badge)
      refute row(site, "upg-badge")
    end

    # THE ONE ABSENT COMPONENT AN UPGRADE DOES INSTALL, and the case it exists for: a kit that
    # SPLIT a component. The newer `upg-card` draws `upg-badge`, which draws `upg-note`, and a site
    # given the newer card without either would render the runtime's red box inside every card —
    # the update breaking the page it was meant to improve.
    test "brings the pieces an updated component is now made of, and theirs", %{
      site: site,
      dir: dir
    } do
      for name <- ~w(upg-badge upg-note) do
        Ash.destroy!(row(site, name),
          action: :master_permanent_destroy,
          authorize?: false,
          tenant: site.id
        )
      end

      split = split_bundle!(dir)

      assert {:ok, plan} = UiKitUpgrade.plan(split, site.id)
      assert names(plan.absent) == ~w(upg-badge upg-note)

      assert {:ok, report} = UiKitUpgrade.upgrade!(split, site.id)

      assert report.updated == ~w(upg-card)
      assert report.added == ~w(upg-badge upg-note)
      assert report.absent == [], "a piece that arrived is still reported as missing"

      assert row(site, "upg-badge"), "the card draws a component the site was not given"
      assert row(site, "upg-note"), "a piece of a piece was left out"

      assert UiKitUpgrade.message(report) =~
               "2 components they are drawn with were installed too."
    end

    # A PIECE THE ADMIN ARCHIVED IS STILL AN ANSWER THEY GAVE. It is a component they have, not one
    # they are missing, so the rule above does not reach it and the installer leaves it archived.
    test "and leaves an archived piece where the admin put it", %{site: site, dir: dir} do
      Ash.destroy!(row(site, "upg-badge"),
        action: :master_destroy,
        authorize?: false,
        tenant: site.id
      )

      split = split_bundle!(dir)

      assert {:ok, report} = UiKitUpgrade.upgrade!(split, site.id)

      assert report.added == []
      assert "upg-badge" in report.archived
      refute row(site, "upg-badge")
    end

    # A SITE WITH NOTHING LIVE OF THIS KIT'S IS NOT A SITE THAT IS UP TO DATE. Both answers write
    # nothing, and telling an admin who has archived or deleted the lot that everything is current
    # reads as the card failing to look.
    test "says so when every component is archived or gone", %{site: site, new: new} do
      for name <- ~w(upg-card upg-badge) do
        Ash.destroy!(row(site, name), action: :master_destroy, authorize?: false, tenant: site.id)
      end

      Ash.destroy!(row(site, "upg-note"),
        action: :master_permanent_destroy,
        authorize?: false,
        tenant: site.id
      )

      assert {:ok, report} = UiKitUpgrade.upgrade!(new, site.id, include: :all)

      assert report.updated == []

      assert UiKitUpgrade.message(report) == "This site has none of this kit's components in use."
    end

    test "leaves another site's rows alone", %{site: site, old: old, new: new} do
      name = "othertown#{System.unique_integer([:positive])}"
      other = create_site!(name: name, host: "#{name}.test", active: true)
      install!(old, other)

      assert {:ok, report} = UiKitUpgrade.upgrade!(new, site.id)

      assert Enum.sort(report.updated) == ~w(upg-badge upg-card upg-note)
      assert row(other, "upg-card").template == ~s|<span class={paint(@tone)}>card 1.0.0</span>|
      assert stamp(other, "upg-card")["ui_kit_version"] == "1.0.0"
    end
  end

  # A KIT IS EDITED FAR MORE OFTEN THAN IT IS RENUMBERED. `mishka_blog.json` was rewritten under an
  # unchanged `2.0.0` the day this was written — the `language` filter this whole feature exists to
  # deliver — and a version check on its own called every such row current and offered nothing.
  describe "a bundle rewritten without a new version" do
    setup %{site: site, dir: dir, new: new} do
      install!(new, site)

      %{again: rewritten!(dir, new)}
    end

    test "is offered, and says it is the kit's own copy that moved", %{site: site, again: again} do
      assert {:ok, plan} = UiKitUpgrade.plan(again, site.id)

      assert names(plan.outdated) == ~w(upg-card)
      assert names(plan.current) == ~w(upg-badge upg-note)

      assert UiKitUpgrade.note(hd(plan.outdated)) ==
               "installed from 2.0.0, untouched — the kit's own copy has changed since"
    end

    test "is written, and the second press finds nothing left", %{site: site, again: again} do
      assert {:ok, report} = UiKitUpgrade.upgrade!(again, site.id)

      assert report.updated == ~w(upg-card)
      assert row(site, "upg-card").template =~ "card moved on"

      assert {:ok, second} = UiKitUpgrade.upgrade!(again, site.id)

      assert second.updated == []
      assert UiKitUpgrade.message(second) == "Every component this kit ships is up to date."
    end

    test "still leaves an edited row in the pile that asks", %{site: site, again: again} do
      edit!(site, "upg-card", ~s|<span>mine</span>|)

      assert {:ok, plan} = UiKitUpgrade.plan(again, site.id)

      assert names(plan.choice) == ~w(upg-card)

      assert {:ok, report} = UiKitUpgrade.upgrade!(again, site.id)

      assert report.updated == []
      assert row(site, "upg-card").template == ~s|<span>mine</span>|
    end
  end

  describe "a row nothing can be told about" do
    setup %{site: site, old: old} do
      install!(old, site)
      :ok
    end

    # THE ROWS EVERY EXISTING SITE HAS. They were installed before any of this was recorded, so an
    # edit cannot be told from the original — and the answer is to ask rather than to guess, in
    # either direction: overwriting them silently is the bug this whole feature exists to fix, and
    # calling them safe would do exactly that.
    test "is offered with the edited ones, never with the safe ones", %{site: site, new: new} do
      unstamped!(site, "upg-card", %{"ui_kit" => "upgradekit"})

      assert {:ok, plan} = UiKitUpgrade.plan(new, site.id)

      assert names(plan.choice) == ~w(upg-card)
      refute "upg-card" in names(plan.outdated)

      assert UiKitUpgrade.note(hd(plan.choice)) ==
               "installed before versions were recorded, so an edit cannot be told from the original"

      assert {:ok, report} = UiKitUpgrade.upgrade!(new, site.id)

      refute "upg-card" in report.updated
      assert report.left == ~w(upg-card)
    end

    test "is taken when the admin asks for it by name", %{site: site, new: new} do
      unstamped!(site, "upg-card", %{"ui_kit" => "upgradekit"})

      assert {:ok, report} = UiKitUpgrade.upgrade!(new, site.id, include: :all)

      assert "upg-card" in report.updated
      assert report.edited == ~w(upg-card)
      assert row(site, "upg-card").template == ~s|<span class={paint(@tone)}>card 2.0.0</span>|
    end

    test "says when the row belongs to another kit", %{site: site, new: new} do
      unstamped!(site, "upg-card", %{"ui_kit" => "someone-elses", "ui_kit_version" => "9.9.9"})

      assert {:ok, plan} = UiKitUpgrade.plan(new, site.id)

      assert names(plan.choice) == ~w(upg-card)

      assert UiKitUpgrade.note(hd(plan.choice)) ==
               "installed by the someone-elses kit, so this one cannot say what it should hold"
    end

    test "says when the row carries a version but no fingerprint", %{site: site, new: new} do
      unstamped!(site, "upg-card", %{"ui_kit" => "upgradekit", "ui_kit_version" => "1.0.0"})

      assert {:ok, plan} = UiKitUpgrade.plan(new, site.id)

      assert UiKitUpgrade.note(hd(plan.choice)) ==
               "installed from 1.0.0 with no fingerprint, so an edit cannot be told from the original"
    end
  end

  describe "a bundle that cannot be compared" do
    test "is refused rather than reported as current", %{site: site, old: old} do
      install!(old, site)

      path = Path.join(Path.dirname(old), "versionless.json")

      File.write!(
        path,
        old |> File.read!() |> Jason.decode!() |> Map.delete("version") |> Jason.encode!()
      )

      assert {:error, :kit_has_no_version} = UiKitUpgrade.plan(path, site.id)
      assert {:error, :kit_has_no_version} = UiKitUpgrade.upgrade!(path, site.id)
    end

    test "says so when the file is not a bundle at all", %{site: site, old: old} do
      path = Path.join(Path.dirname(old), "notes.txt")
      File.write!(path, "a note somebody left in the kits directory")

      assert {:error, _reason} = UiKitUpgrade.plan(path, site.id)
    end
  end

  # The same bundle under the same version with one component's markup changed — a kit's file edited
  # in place, which is what happens between releases.
  defp rewritten!(dir, path) do
    bundle = path |> File.read!() |> Jason.decode!()

    components =
      Enum.map(bundle["components"], fn
        %{"name" => "upg-card"} = component ->
          Map.put(component, "template", ~s|<span class={paint(@tone)}>card moved on</span>\n|)

        untouched ->
          untouched
      end)

    again = Path.join(dir, "upgradekit-again.json")
    File.write!(again, Jason.encode!(Map.put(bundle, "components", components)))

    again
  end

  # A row as it was before the installer recorded anything: the stamp rewritten by hand, which is
  # the only way to produce what every site installed before this feature actually holds.
  defp unstamped!(site, name, extra) do
    site
    |> row(name)
    |> Ash.update!(%{extra: extra},
      action: :master_update,
      authorize?: false,
      tenant: site.id
    )
  end
end
