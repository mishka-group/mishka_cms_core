# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.UiKit.BundleShapeTest do
  @moduledoc """
  Tier 3 — bundle JSON snapshot test. No DB, no install, no compile.

  Validates the structural invariants of the v3 bundle JSON shipped at
  `priv/cms_ui_kits/chelekom.json`. Catches regressions in the upstream
  Chelekom converter (e.g. "combobox lost its 30 attrs after a
  multi-clause public-def refactor") immediately, before we even touch
  the runtime compiler.

  Runs in milliseconds. Decoupled from Postgres / Ash. If this fails,
  the converter shipped a broken bundle — re-export from Chelekom and
  copy the JSON before installing.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  @bundle_path MishkaCmsCore.Runtime.Handlers.UiKitHandler.default_bundle_path()

  setup_all do
    bundle = @bundle_path |> File.read!() |> Jason.decode!()
    {:ok, bundle: bundle}
  end

  describe "v3 schema envelope" do
    test "schema marker, name, version present", %{bundle: b} do
      assert b["$schema"] == "mishka.ui_kit.bundle.v3"
      assert is_binary(b["name"]) and b["name"] != ""
      assert is_binary(b["version"]) and b["version"] != ""
    end

    test "top-level arrays exist", %{bundle: b} do
      assert is_list(b["components"])
      assert is_list(b["js_hooks"])
      assert is_list(b["stylesheets"])
    end
  end

  # THE METADATA THE EDITOR IS BUILT ON. Both of these were won upstream and neither was pinned here:
  # the attribute value lists went from 23 to 365, and every component gained a `doc_url`. Nothing
  # asserted either, so a re-export that quietly lost them — which is exactly what the guard bug did
  # the first time — would have passed CI and shown up as an inspector full of text boxes.
  describe "the metadata the Inspector reads" do
    test "every component names its documentation page", %{bundle: b} do
      without = for c <- b["components"], is_nil(get_in(c, ["extra", "doc_url"])), do: c["name"]

      assert without == [], "components with no doc_url: #{inspect(Enum.take(without, 5))}"
    end

    # A VALUE LIST IS WHAT MAKES A PICKER. Without one the Inspector falls back to a name heuristic
    # and the author gets a text box to type `extra_small` into. 365 is what the current export
    # carries; the floor is deliberately below it so a small curation change is not a failure, while
    # the collapse back to 23 that this replaced would be.
    test "attributes carry their own value lists", %{bundle: b} do
      with_values =
        for component <- b["components"],
            attr <- component["attrs"] || [],
            values = get_in(attr, ["opts", "values"]),
            is_list(values) and values != [],
            do: attr["name"]

      assert length(with_values) >= 300,
             "only #{length(with_values)} attributes carry a value list — was 365"
    end

    # A `nil` in a value list renders as a blank, unlabelled option. Four of these ship, which the
    # Inspector drops on the way in; this is the count going UP that would be news.
    test "value lists are almost entirely free of nils", %{bundle: b} do
      nils =
        for component <- b["components"],
            attr <- component["attrs"] || [],
            values = get_in(attr, ["opts", "values"]),
            is_list(values),
            reduce: 0 do
          total -> total + Enum.count(values, &is_nil/1)
        end

      assert nils <= 4, "#{nils} nil options in the bundle — the Inspector has to drop each one"
    end
  end

  describe "components array" do
    test "non-empty (Chelekom kit ships >100 components)", %{bundle: b} do
      assert length(b["components"]) >= 100,
             "expected >=100 components, got #{length(b["components"])}"
    end

    test "every component has a name and template", %{bundle: b} do
      missing =
        b["components"]
        |> Enum.reject(fn c ->
          is_binary(c["name"]) and c["name"] != "" and
            is_binary(c["template"]) and c["template"] != ""
        end)
        |> Enum.map(& &1["name"])

      assert missing == [], "components missing name or template: #{inspect(missing)}"
    end

    test "every component name is slug-cased and prefixed with kit name", %{bundle: b} do
      kit = b["name"]

      bad =
        b["components"]
        |> Enum.reject(&String.starts_with?(&1["name"], kit <> "-"))
        |> Enum.map(& &1["name"])

      assert bad == [], "names not prefixed with #{inspect(kit)}: #{inspect(bad)}"
    end

    test "names are unique", %{bundle: b} do
      names = Enum.map(b["components"], & &1["name"])
      dups = names -- Enum.uniq(names)
      assert dups == [], "duplicate names: #{inspect(dups)}"
    end

    test "every component declares at least one attr OR slot (catches converter swallowing attrs)",
         %{bundle: b} do
      # This invariant catches the combobox bug: when the first def
      # clause was a delegating helper (no ~H body), the converter
      # reset `pending_attrs` and the next clause inherited zero attrs.
      #
      # A small handful of components legitimately declare only slots
      # (e.g. `chelekom-error` declares `slot :inner_block` and no
      # attrs) — accept those, fail only on truly empty rows.
      empty =
        b["components"]
        |> Enum.filter(fn c -> c["attrs"] == [] and c["slots"] == [] end)
        |> Enum.map(& &1["name"])

      assert empty == [],
             "components with 0 attrs AND 0 slots (likely converter bug): #{inspect(empty)}"
    end

    test "attrs and slots fields are arrays of maps", %{bundle: b} do
      bad =
        Enum.flat_map(b["components"], fn c ->
          attrs_bad = not is_list(c["attrs"])
          slots_bad = not is_list(c["slots"])
          if attrs_bad or slots_bad, do: [c["name"]], else: []
        end)

      assert bad == [], "components with non-list attrs/slots: #{inspect(bad)}"
    end

    test "each attr has name and type", %{bundle: b} do
      bad =
        b["components"]
        |> Enum.flat_map(fn c ->
          c["attrs"]
          |> Enum.with_index()
          |> Enum.flat_map(fn {a, i} ->
            if is_binary(a["name"]) and is_binary(a["type"]),
              do: [],
              else: ["#{c["name"]}.attrs[#{i}] = #{inspect(a)}"]
          end)
        end)

      assert bad == [], "malformed attrs: #{inspect(bad)}"
    end

    test "extra.ui_kit metadata stamped on every component", %{bundle: b} do
      bad =
        b["components"]
        |> Enum.reject(fn c -> get_in(c, ["extra", "ui_kit"]) == b["name"] end)
        |> Enum.map(& &1["name"])

      assert bad == [], "components missing extra.ui_kit=#{b["name"]}: #{inspect(bad)}"
    end
  end

  describe "type / dependencies / examples (MishkaCMS Component columns)" do
    test "every component carries a string `type`", %{bundle: b} do
      Enum.each(b["components"], fn c -> assert is_binary(c["type"]) end)
    end

    test "`dependencies` is always a list of strings", %{bundle: b} do
      Enum.each(b["components"], fn c ->
        assert is_list(c["dependencies"])
        Enum.each(c["dependencies"], fn d -> assert is_binary(d) end)
      end)
    end

    test "sibling deps are kit-prefixed and script deps end in .js", %{bundle: b} do
      all = Enum.flat_map(b["components"], & &1["dependencies"])
      assert Enum.any?(all, &String.starts_with?(&1, "#{b["name"]}-"))
      assert Enum.any?(all, &String.ends_with?(&1, ".js"))
    end

    test "`examples` are clean, self-contained <.component … site=\"Global\"> strings",
         %{bundle: b} do
      with_examples = Enum.filter(b["components"], &(&1["examples"] != []))
      assert with_examples != [], "kit shipped no examples"

      Enum.each(with_examples, fn c ->
        assert length(c["examples"]) <= 12, "#{c["name"]} has more than 12 examples"

        Enum.each(c["examples"], fn ex ->
          assert is_binary(ex)
          assert String.contains?(ex, "<.component")
          assert String.contains?(ex, ~s(site="Global"))
          # the dynamic site binding must have been normalized away
          refute String.contains?(ex, "assigns[:site]")
          # cleaned: no leftover demo conditionals
          refute String.contains?(ex, ":if=")
        end)
      end)
    end

    # This used to also require every example to be a SINGLE LINE, which was evidence that the
    # harvest's sanitizer had run rather than anything this CMS needs — `MishkaChelekom.CmsBundle`
    # collapses whitespace while scraping the docs pages.
    #
    # A kit may now also ship hand-authored examples (`priv/showcase/`), which never pass through
    # that sanitizer and are deliberately indented: they are finished blocks a person reads in the
    # code pane and edits, and a forty-element pricing card on one line cannot be read at all. What
    # the CMS actually needs of an example is that it PARSES, which is what this asserts instead.
    test "every example parses as something the editor can place", %{bundle: b} do
      unparseable =
        for c <- b["components"],
            ex <- c["examples"],
            match?({:error, _reason}, MishkaCmsCore.Runtime.PageBuilder.Tree.parse(ex)),
            do: "#{c["name"]}: #{String.slice(ex, 0, 80)}"

      assert unparseable == [],
             "an example that does not parse places nothing at all:\n" <>
               Enum.join(unparseable, "\n")
    end

    test "chelekom-accordion maps category->type and necessary->dependencies", %{bundle: b} do
      acc = Enum.find(b["components"], &(&1["name"] == "chelekom-accordion"))
      assert acc["type"] == "general"
      assert "chelekom-icon" in acc["dependencies"]
      assert "collapsible.js" in acc["dependencies"]
    end
  end

  describe "stylesheets array" do
    test "every entry has name, content, kind, format", %{bundle: b} do
      for s <- b["stylesheets"] do
        assert is_binary(s["name"]) and s["name"] != ""
        assert is_binary(s["content"]) and byte_size(s["content"]) > 0
        assert s["kind"] in ["app_base", "theme", "base", "custom"]
        assert s["format"] == "css"
      end
    end
  end

  describe "js_hooks array" do
    test "every entry has name and content", %{bundle: b} do
      bad =
        b["js_hooks"]
        |> Enum.reject(fn h -> is_binary(h["name"]) and is_binary(h["content"]) end)
        |> Enum.map(& &1["name"])

      assert bad == [], "malformed js_hooks: #{inspect(bad)}"
    end
  end

  describe "regression guards (specific components)" do
    test "chelekom-combobox has its full attr set (was lost when first clause delegated)",
         %{bundle: b} do
      c = Enum.find(b["components"], &(&1["name"] == "chelekom-combobox"))
      assert c, "chelekom-combobox missing from bundle"

      assert length(c["attrs"]) >= 25,
             "combobox has #{length(c["attrs"])} attrs, expected >=25 (converter regression)"
    end

    test "field components keep translate_error/input out of helpers", %{bundle: b} do
      # These collide with imports the runtime compiler injects via
      # `use MishkaCmsWeb, :live_view`. The converter must drop matching
      # locals; otherwise compile errors at boot.
      bad =
        b["components"]
        |> Enum.flat_map(fn c ->
          local_sigs =
            for h <- c["helpers"], do: {h["name"], helper_arity(h["args"])}

          host_collisions =
            local_sigs
            |> Enum.filter(fn pair ->
              pair in [{"translate_error", 1}, {"translate_errors", 1}, {"input", 1}]
            end)

          if host_collisions == [], do: [], else: [{c["name"], host_collisions}]
        end)

      assert bad == [], "components with host-injected collision: #{inspect(bad)}"
    end

    test "chelekom-alert preserves all 56 color_variant clauses", %{bundle: b} do
      c = Enum.find(b["components"], &(&1["name"] == "chelekom-alert"))
      assert c, "chelekom-alert missing"

      color_clauses = Enum.filter(c["helpers"], &(&1["name"] == "color_variant"))

      assert length(color_clauses) >= 50,
             "alert has #{length(color_clauses)} color_variant clauses, expected >=50"
    end
  end

  defp helper_arity(""), do: 0
  defp helper_arity(nil), do: 0

  defp helper_arity(args) when is_binary(args) do
    head =
      case String.split(args, " when ", parts: 2) do
        [head_only] -> head_only
        [head_only, _] -> head_only
      end

    case Code.string_to_quoted("def __probe__(#{head}), do: nil") do
      {:ok, {:def, _, [{:__probe__, _, arg_list}, _]}} when is_list(arg_list) ->
        length(arg_list)

      _ ->
        head |> String.split(",", trim: true) |> length()
    end
  end
end
