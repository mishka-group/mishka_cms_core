# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.ComponentPreviewDocumentTest do
  @moduledoc """
  An administrator opens a component in the kit browser to decide whether to use it. That decision
  is worth nothing if the thing renders unstyled — and it must not cost the sites anything, because
  nobody has chosen to use the component yet.

  Both halves used to fail. The preview borrowed whichever compiled site bundle happened to be the
  largest, so a component previewed correctly only if some site already rendered it: exactly
  backwards for a browser whose job is showing you things you have NOT used. And the obvious fix —
  compile the component into a stylesheet — would have charged every visitor for a component their
  site never renders.

  So the document brings the same in-browser Tailwind the page builder's canvas runs and generates
  from its own markup. Nothing is compiled on the server, and no site's stylesheet changes.

  See `MishkaCmsCore.Runtime.Compilers.SharedBaseContentsTest` for the other side of that bargain —
  that a component's classes stay out of the shared base every visitor downloads.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.{Component, Layout, RuntimePreview}
  alias MishkaCmsCore.Runtime.States.AssetsState

  defp component(overrides \\ []) do
    n = System.unique_integer([:positive])

    struct(
      Component,
      Keyword.merge(
        [
          id: Ecto.UUID.generate(),
          name: "doc-probe-#{n}",
          examples: [~s(<div class="pt-[47px]">example</div>)],
          extra: %{},
          site: nil
        ],
        overrides
      )
    )
  end

  describe "the document a component preview renders in" do
    test "carries the generator, so it styles itself from its own markup" do
      {html, nil} = RuntimePreview.render_document(component(), Component)

      assert html =~ ~s(type="text/tailwindcss"),
             "the @theme block the generator needs to resolve a kit's tokens is missing"

      assert html =~ "document.createElement",
             "the nonce shim is missing; the generator's <style> will be refused by the admin policy"

      assert byte_size(html) > 200_000,
             "the engine is not inlined — a sandboxed frame has an opaque origin and cannot fetch it"
    end

    test "borrows no site's compiled stylesheet" do
      site = create_site!(name: "doc-#{unique()}", host: "doc-#{unique()}.test")

      :ok =
        AssetsState.save(%{
          id: site.name,
          type: "css",
          value: ".borrowed-marker{color:red}",
          hash: "h",
          updated_at: DateTime.utc_now()
        })

      on_exit(fn -> AssetsState.delete(site.name, "css") end)

      {html, nil} = RuntimePreview.render_document(component(), Component)

      refute html =~ "borrowed-marker",
             "the preview is still inlining a site's bundle; a component previews correctly only if that site uses it"
    end

    # The generator resolves nothing it has not been handed: `bg-primary` is a colour only because a
    # kit declared `--color-primary` in an `@theme` block. A component belonging to a site may use a
    # token that site declares, so the theme it ships must be that site's, not just the global rows.
    test "ships the OWNING site's theme, not only the global one" do
      n = unique()
      site = create_site!(name: "doc-t-#{n}", host: "doc-t-#{n}.test")

      MishkaCmsCore.Runtime.Stylesheet
      |> Ash.Changeset.for_create(
        :master_create,
        %{
          name: "doc-theme-#{n}",
          kind: :theme,
          format: :css,
          site_id: site.id,
          content: "@theme { --color-tenant-probe-#{n}: oklch(0.5 0.1 30); }"
        },
        authorize?: false
      )
      |> Ash.create!()

      record = component(site: site)

      {html, nil} = RuntimePreview.render_document(record, Component)

      assert html =~ "--color-tenant-probe-#{n}",
             "a tenant component previews without its own site's tokens, so its colours resolve to nothing"
    end

    # THE @theme BLOCK IS MOSTLY ALIASES. Chelekom writes
    #
    #     :root  { --base-border-light: oklch(…); }
    #     @theme { --color-base-border-light: var(--base-border-light); }
    #
    # so shipping the block alone leaves every alias pointing at a variable that was never declared:
    # the generator emits `border-color: var(--color-base-border-light)`, the chain resolves to
    # nothing, and a grey border renders black. Measured in a browser before this was fixed.
    test "ships the declarations the theme's aliases point at, not only the aliases" do
      n = unique()

      MishkaCmsCore.Runtime.Stylesheet
      |> Ash.Changeset.for_create(
        :master_create,
        %{
          name: "doc-alias-#{n}",
          kind: :theme,
          format: :css,
          content: """
          :root { --raw-probe-#{n}: oklch(0.7 0.2 140); }
          @theme { --color-alias-probe-#{n}: var(--raw-probe-#{n}); }
          """
        },
        authorize?: false
      )
      |> Ash.create!()

      {html, nil} = RuntimePreview.render_document(component(), Component)

      assert html =~ "--color-alias-probe-#{n}", "the @theme block is missing"

      assert html =~ "--raw-probe-#{n}: oklch(0.7 0.2 140)",
             "the alias points at a declaration the document never carries, so the colour resolves to nothing"
    end

    # AN ICON IS A MASK RULE, NOT A UTILITY. `hero-bell` is a class plus a CSS mask that the SERVER
    # generates from the registered icon libraries — the browser generator has no idea it exists and
    # cannot invent it. The preview used to get these rules from the borrowed site bundle, so
    # dropping the bundle left every icon in every example blank.
    test "carries the mask rules for the icons its examples use" do
      record = component(examples: [~s(<span class="hero-bell size-5"></span>)])

      {html, nil} = RuntimePreview.render_document(record, Component)

      assert html =~ "hero-bell",
             "an icon renders blank: the generator cannot produce mask rules, only utilities"

      assert html =~ "mask", "the icon class is present but its mask rule is not"
    end

    test "renders the example markup the admin is judging" do
      {html, nil} = RuntimePreview.render_document(component(), Component)

      assert html =~ "pt-[47px]"
      assert html =~ "example"
    end

    # A component with nothing to show is a note, not a blank frame — and a note needs no generator.
    test "a component with no examples says so, without shipping the engine" do
      {html, "no example"} =
        RuntimePreview.render_document(component(examples: []), Component)

      assert html =~ "no example yet"

      assert byte_size(html) < 20_000,
             "the engine travelled with a document that renders no markup"
    end
  end

  describe "every other resource is unaffected" do
    # A page, a layout and an error page each belong to one site, so that site's compiled bundle is
    # exactly right for them — and their frames stay fully sandboxed.
    test "a layout preview still inlines its own site's bundle and no generator" do
      site = create_site!(name: "doc-l-#{unique()}", host: "doc-l-#{unique()}.test")

      :ok =
        AssetsState.save(%{
          id: site.name,
          type: "css",
          value: ".site-bundle-marker{color:blue}",
          hash: "h",
          updated_at: DateTime.utc_now()
        })

      on_exit(fn -> AssetsState.delete(site.name, "css") end)

      layout =
        struct(Layout, %{
          id: Ecto.UUID.generate(),
          name: "doc-layout",
          template: "<html><body>{@inner_content}</body></html>",
          site: site
        })

      {html, _note} = RuntimePreview.render_document(layout, Layout)

      assert html =~ "site-bundle-marker"
      refute html =~ ~s(type="text/tailwindcss")
    end
  end

  defp unique, do: System.unique_integer([:positive])
end
