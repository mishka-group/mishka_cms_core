defmodule MishkaCmsCore.UiKit.LinkAddressTest do
  @moduledoc """
  An address a designer types into a kit property has to become a plain `href`.

  `chelekom-content-item` and the `item` slot of `chelekom-table-content` both rendered their anchor
  as `<.link :if={@link_title && @link} patch={@link}>`. Two things were wrong with it. The guard
  meant that filling Link alone — the only field a table-of-contents author looks for — rendered
  nothing at all, silently. And `patch` is live navigation: it needs a route in the router and a
  `handle_params/3` on the view, and a published page is a compiled module that has neither, so the
  one address that did get through took the page down instead of jumping to the heading.

  `href` is the general case. A fragment, a path in this app and an address on another host are all
  the same thing to it, and none of them needs the page to be a LiveView at all.

  The sweep is the part that must not rot: no kit template may put an author-supplied address into
  `patch`, whatever the kit is called and however many components it ships.
  """

  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.Compilers.ComponentCompiler
  alias MishkaCmsCore.Runtime.Compilers.ModuleCompiler

  @moduletag :unit

  @kits_dir Path.join([:code.priv_dir(:mishka_cms_core), "cms_ui_kits"])

  # `patch={...}` with anything but a bare string inside — an attribute, a slot lookup, an
  # interpolation. A literal `patch="/known/route"` written by the kit author is its own business.
  @author_supplied ~r/patch=\{(?!\s*"[^"]*"\s*\})/

  setup_all do
    components =
      @kits_dir
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path |> File.read!() |> Jason.decode!() |> Map.get("components", [])
      end)

    {:ok, components: components, by_name: Map.new(components, &{&1["name"], &1})}
  end

  defp compile(entry, suffix) do
    module = Module.concat(["MishkaCmsCore", "Runtime", "LinkAddressTest#{suffix}", "Component"])

    params =
      entry
      |> Map.take(~w(attrs slots helpers permissions template body extra format))
      |> Map.merge(%{
        "id" => "link-address-#{suffix}",
        "title" => String.replace(entry["name"], "-", "_"),
        "component_module" => module,
        "site" => "Test",
        "site_id" => nil,
        "host" => nil,
        "priority" => 50,
        "timestamp" => ~U[2026-01-01 00:00:00Z]
      })

    {:ok, module, _binary} =
      params |> ComponentCompiler.build_module() |> ModuleCompiler.compile_module()

    {module, String.to_existing_atom(params["title"])}
  end

  defp render(entry, suffix, assigns) do
    {module, function} = compile(entry, suffix)

    defaults =
      Map.new(entry["attrs"], fn attr ->
        {String.to_existing_atom(attr["name"]), get_in(attr, ["opts", "default"])}
      end)

    assigns =
      defaults
      |> Map.merge(%{rest: %{}, inner_block: [], item: [], __changed__: nil})
      |> Map.merge(assigns)

    rendered_to_string(apply(module, function, [assigns]))
  end

  describe "an address typed into Link, and nothing else" do
    test "the component renders an anchor to it", %{by_name: by_name} do
      html = render(by_name["chelekom-content-item"], "Item", %{link: "#home"})

      assert html =~ ~s(href="#home")
      assert html =~ "#home"
      refute html =~ ~s(data-phx-link="patch")
    end

    test "and the same address inside the table of contents' own item", %{by_name: by_name} do
      html =
        render(by_name["chelekom-table-content"], "Toc", %{
          item: [%{__slot__: :item, link: "#home", inner_block: fn _assigns, _ -> [] end}]
        })

      assert html =~ ~s(href="#home")
      refute html =~ ~s(data-phx-link="patch")
    end
  end

  describe "a Link with a title still reads as the title" do
    test "the address is the fallback, not the label", %{by_name: by_name} do
      html =
        render(by_name["chelekom-content-item"], "Titled", %{link: "#home", link_title: "Home"})

      assert html =~ ~s(href="#home")
      assert html =~ ">Home<"
    end
  end

  describe "every kit, every component" do
    test "no author-supplied address is live navigation", %{components: components} do
      offenders =
        for component <- components,
            template = component["template"] || "",
            match = Regex.run(@author_supplied, template),
            do: "#{component["name"]} — #{hd(match)}"

      assert offenders == [],
             "these send a typed-in address through `patch`, which a published page cannot " <>
               "answer:\n" <> Enum.join(offenders, "\n")
    end

    test "and the sweep is looking at a real kit", %{components: components} do
      assert length(components) >= 100
      assert Enum.any?(components, &String.contains?(&1["template"] || "", "href="))
    end
  end
end
