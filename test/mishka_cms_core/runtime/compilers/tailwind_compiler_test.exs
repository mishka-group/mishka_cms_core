# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.TailwindCompilerTest do
  use ExUnit.Case, async: false

  # Raw SQL and sandbox calls need the same repo the resources write through.
  @repo Application.compile_env!(:mishka_cms_core, :repo)
  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler
  alias MishkaCmsCore.Runtime.States.AssetsState
  alias MishkaCmsCore.Test.EventCannotRun

  import ExUnit.CaptureLog
  import ExUnit.CaptureIO
  @moduletag :unit

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})

    on_exit(fn ->
      for i <- 1..10 do
        AssetsState.delete("test_site_#{i}", "css")
        AssetsState.delete("test_compile_store_#{i}", "css")
        AssetsState.delete("test_get_css_#{i}", "css")
      end

      AssetsState.delete("__shared_base__", "css")
      AssetsState.delete("__shared_base__", "brotli_css")
      AssetsState.delete("__shared_base__", "gzip_css")
    end)

    :ok
  end

  # Helper to suppress Tailwind CLI output
  defp quiet_compile(site_name) do
    capture_io(fn ->
      send(self(), TailwindCompiler.compile(site_name))
    end)

    receive do
      result -> result
    end
  end

  defp quiet_compile_and_store(site_name) do
    capture_io(fn ->
      send(self(), TailwindCompiler.compile_and_store(site_name))
    end)

    receive do
      result -> result
    end
  end

  defp quiet_refresh_css(site_name) do
    capture_log(fn ->
      capture_io(fn ->
        send(self(), TailwindCompiler.refresh_css(site_name))
      end)
    end)

    receive do
      result -> result
    end
  end

  describe "ensure_installed/0" do
    test "ensures Tailwind binary is installed and returns :ok" do
      result = TailwindCompiler.ensure_installed()
      assert result == :ok
    end

    test "returns :ok on subsequent calls (cached)" do
      TailwindCompiler.ensure_installed()
      result = TailwindCompiler.ensure_installed()
      assert result == :ok
    end
  end

  describe "compile_shared_base/0" do
    test "compiles shared base CSS" do
      TailwindCompiler.ensure_installed()

      assert {:ok, css} = TailwindCompiler.compile_shared_base()
      assert byte_size(css) > 0
    end
  end

  describe "compile_and_store_shared_base/0" do
    test "compiles and stores shared base CSS" do
      TailwindCompiler.ensure_installed()

      assert {:ok, css} = TailwindCompiler.compile_and_store_shared_base()

      assert {:ok, asset} = AssetsState.get("__shared_base__", "css")
      assert asset.value == css
      assert {:ok, _} = AssetsState.get("__shared_base__", "brotli_css")
      assert {:ok, _} = AssetsState.get("__shared_base__", "gzip_css")
    end
  end

  describe "get_or_compile_shared_base/0" do
    test "returns cached shared base if exists" do
      test_css = "/* Cached shared base */"

      AssetsState.save(%{
        id: "__shared_base__",
        type: "css",
        value: test_css,
        hash: "test",
        updated_at: DateTime.utc_now()
      })

      result = TailwindCompiler.get_or_compile_shared_base()
      assert result == test_css

      AssetsState.delete("__shared_base__", "css")
    end

    test "compiles shared base if not cached" do
      AssetsState.delete("__shared_base__", "css")
      TailwindCompiler.ensure_installed()

      result = TailwindCompiler.get_or_compile_shared_base()
      assert is_binary(result)
    end
  end

  describe "compile/1 and compile/2" do
    test "returns compiled CSS for a site" do
      assert {:ok, css} = quiet_compile("test_site")
      assert css =~ "/* Site: test_site */"
    end

    # There is ONE way to assemble a site's stylesheet: the cached shared base plus the site's own
    # delta. The `use_shared_base: false` mode that used to sit beside it restated every decision
    # about what gets scanned, was called by nothing but its own tests, and drifted each time that
    # answer changed.
    test "the site's delta is appended to the shared base, under its own marker" do
      TailwindCompiler.ensure_installed()

      assert {:ok, css} = TailwindCompiler.compile("test_shared_site")
      assert css =~ "/* Site: test_shared_site */"
    end

    test "a site with nothing of its own still compiles, and logs no error" do
      log =
        capture_log([level: :error], fn ->
          assert {:ok, css} = quiet_compile("test_error_site")
          assert css =~ "/* Site: test_error_site */"
        end)

      assert log == ""
    end

    test "handles different site names" do
      sites = ["site_one", "site-two", "site.three", "site_4"]

      for site <- sites do
        assert {:ok, css} = quiet_compile(site)
        assert css =~ "/* Site: #{site} */"
      end
    end

    test "compile result is consistent for same site" do
      site_name = "test_consistent_#{System.unique_integer([:positive])}"

      assert {:ok, css1} = quiet_compile(site_name)
      assert {:ok, css2} = quiet_compile(site_name)

      assert css1 == css2
    end
  end

  describe "compile_and_store/1" do
    test "compiles and stores CSS with all compression formats" do
      site_name = "test_compile_store_#{System.unique_integer([:positive])}"

      # Clean up any existing CSS first
      AssetsState.delete(site_name, "css")

      assert {:ok, css} = quiet_compile_and_store(site_name)

      assert {:ok, asset} = AssetsState.get(site_name, "css")
      assert {:ok, brotli} = AssetsState.get(site_name, "brotli_css")
      assert {:ok, gzip} = AssetsState.get(site_name, "gzip_css")

      assert asset.hash == brotli.hash
      assert asset.hash == gzip.hash
      assert %DateTime{} = asset.updated_at
      assert asset.value == css

      # Cleanup
      AssetsState.delete(site_name, "css")
    end

    test "stores the stylesheet while runtime:compile:css cannot run" do
      EventCannotRun.stub!("runtime:compile:css")
      site_name = "test_compile_store_#{System.unique_integer([:positive])}"
      on_exit(fn -> AssetsState.delete(site_name, "css") end)

      assert {:ok, css} = quiet_compile_and_store(site_name)
      assert is_binary(css) and byte_size(css) > 0
      assert AssetsState.get_value(site_name, "css") == css
    end

    test "stores CSS with proper metadata" do
      site_name = "test_metadata_#{System.unique_integer([:positive])}"

      assert {:ok, css} = quiet_compile_and_store(site_name)
      assert {:ok, asset} = AssetsState.get(site_name, "css")

      assert asset.id == site_name
      assert asset.type == "css"
      assert asset.hash == Base.encode16(:crypto.hash(:md5, css), case: :lower)
      assert %DateTime{} = asset.updated_at

      # Cleanup
      AssetsState.delete(site_name, "css")
    end

    test "logs no error when the compilation succeeds" do
      log =
        capture_log([level: :error], fn ->
          assert {:ok, _css} = quiet_compile_and_store("test_error_site")
        end)

      assert log == ""
    end

    test "returns same CSS that gets stored" do
      site_name = "test_return_store_#{System.unique_integer([:positive])}"

      assert {:ok, returned_css} = quiet_compile_and_store(site_name)
      assert TailwindCompiler.get_compiled_css(site_name) == returned_css

      # Cleanup
      AssetsState.delete(site_name, "css")
    end
  end

  describe "get_compiled_css/2" do
    test "returns CSS when it exists in cache" do
      site_name = "test_get_css_#{System.unique_integer([:positive])}"
      test_css = "/* Test CSS */"

      # Store test CSS
      AssetsState.save(%{
        id: site_name,
        type: "css",
        value: test_css,
        hash: "test_hash",
        updated_at: DateTime.utc_now()
      })

      result = TailwindCompiler.get_compiled_css(site_name)
      assert result == test_css

      # Cleanup
      AssetsState.delete(site_name, "css")
    end

    test "returns error comment when CSS not found" do
      result = TailwindCompiler.get_compiled_css("non_existent_site")
      assert result == "/* CSS not found for site: non_existent_site */"
    end

    test "returns compressed CSS for different types" do
      site_name = "test_compressed_#{System.unique_integer([:positive])}"

      # Store different formats
      AssetsState.save_batch([
        %{
          id: site_name,
          type: "css",
          value: "/* Raw CSS */",
          hash: "h1",
          updated_at: DateTime.utc_now()
        },
        %{
          id: site_name,
          type: "brotli_css",
          value: <<1, 2, 3>>,
          hash: "h2",
          updated_at: DateTime.utc_now()
        },
        %{
          id: site_name,
          type: "gzip_css",
          value: <<4, 5, 6>>,
          hash: "h3",
          updated_at: DateTime.utc_now()
        }
      ])

      assert TailwindCompiler.get_compiled_css(site_name, "css") == "/* Raw CSS */"
      assert TailwindCompiler.get_compiled_css(site_name, "brotli_css") == <<1, 2, 3>>
      assert TailwindCompiler.get_compiled_css(site_name, "gzip_css") == <<4, 5, 6>>

      # Cleanup
      AssetsState.delete(site_name, "css")
    end
  end

  describe "css_exists?/1" do
    test "returns true when CSS exists" do
      site_name = "test_exists_#{System.unique_integer([:positive])}"

      # Store CSS
      AssetsState.save(%{
        id: site_name,
        type: "css",
        value: "/* CSS */",
        hash: "test",
        updated_at: DateTime.utc_now()
      })

      assert TailwindCompiler.css_exists?(site_name) == true

      # Cleanup
      AssetsState.delete(site_name, "css")
    end

    test "returns false when CSS doesn't exist" do
      assert TailwindCompiler.css_exists?("non_existent_site") == false
    end
  end

  describe "delete_compiled_css/1" do
    test "deletes CSS from cache" do
      site_name = "test_delete_#{System.unique_integer([:positive])}"

      # Store CSS first
      AssetsState.save(%{
        id: site_name,
        type: "css",
        value: "/* CSS */",
        hash: "test",
        updated_at: DateTime.utc_now()
      })

      # Verify it exists
      assert TailwindCompiler.css_exists?(site_name) == true

      # Delete it
      assert TailwindCompiler.delete_compiled_css(site_name) == :ok

      # Verify it's gone
      assert TailwindCompiler.css_exists?(site_name) == false
    end

    test "returns ok even if CSS doesn't exist" do
      assert TailwindCompiler.delete_compiled_css("non_existent") == :ok
    end
  end

  describe "refresh_css/1" do
    test "recompiles and stores fresh CSS" do
      site_name = "test_refresh_#{System.unique_integer([:positive])}"

      # refresh_css should compile and store the CSS
      assert {:ok, css} = quiet_refresh_css(site_name)

      assert TailwindCompiler.css_exists?(site_name)
      assert TailwindCompiler.get_compiled_css(site_name) == css

      # Cleanup
      AssetsState.delete(site_name, "css")
    end

    test "replaces existing CSS when refreshing" do
      site_name = "test_refresh_replace_#{System.unique_integer([:positive])}"

      # Store initial CSS
      old_css = "/* Old CSS */"

      AssetsState.save(%{
        id: site_name,
        type: "css",
        value: old_css,
        hash: "old_hash",
        updated_at: DateTime.utc_now()
      })

      # Verify old CSS exists
      assert TailwindCompiler.get_compiled_css(site_name) == old_css

      # Refresh CSS
      assert {:ok, new_css} = quiet_refresh_css(site_name)

      assert new_css != old_css
      assert TailwindCompiler.get_compiled_css(site_name) == new_css

      # Cleanup
      AssetsState.delete(site_name, "css")
    end

    test "updates all compression formats on refresh" do
      site_name = "test_refresh_formats_#{System.unique_integer([:positive])}"

      assert {:ok, _css} = quiet_refresh_css(site_name)

      assert {:ok, _} = AssetsState.get(site_name, "css")
      assert {:ok, _} = AssetsState.get(site_name, "brotli_css")
      assert {:ok, _} = AssetsState.get(site_name, "gzip_css")

      # Cleanup
      AssetsState.delete(site_name, "css")
    end
  end

  describe "get_css_status/1" do
    test "returns status when CSS exists" do
      site_name = "test_status_#{System.unique_integer([:positive])}"
      now = DateTime.utc_now()
      test_css = "/* Test CSS content with some size */"

      # Store CSS
      AssetsState.save(%{
        id: site_name,
        type: "css",
        value: test_css,
        hash: "test",
        updated_at: now
      })

      status = TailwindCompiler.get_css_status(site_name)

      assert status.site == site_name
      assert status.compiled == true
      assert status.updated_at == now
      assert status.css_size == byte_size(test_css)

      # Cleanup
      AssetsState.delete(site_name, "css")
    end

    test "returns status when CSS doesn't exist" do
      status = TailwindCompiler.get_css_status("non_existent_site")

      assert status.site == "non_existent_site"
      assert status.compiled == false
      assert status.updated_at == nil
      assert status.css_size == 0
    end
  end

  describe "integration scenarios" do
    test "compile, store, retrieve, and delete workflow" do
      site_name = "test_workflow_#{System.unique_integer([:positive])}"

      # Start with no CSS
      assert TailwindCompiler.css_exists?(site_name) == false

      assert {:ok, css} = quiet_compile_and_store(site_name)

      assert TailwindCompiler.css_exists?(site_name) == true
      assert TailwindCompiler.get_compiled_css(site_name) == css

      status = TailwindCompiler.get_css_status(site_name)
      assert status.compiled == true
      assert status.css_size == byte_size(css)

      # Delete CSS
      assert TailwindCompiler.delete_compiled_css(site_name) == :ok
      assert TailwindCompiler.css_exists?(site_name) == false
    end

    test "multiple sites can have independent CSS" do
      sites = for i <- 1..3, do: "test_multi_#{i}_#{System.unique_integer([:positive])}"

      # Store CSS for each site
      Enum.each(sites, fn site ->
        AssetsState.save(%{
          id: site,
          type: "css",
          value: "/* CSS for #{site} */",
          hash: "hash_#{site}",
          updated_at: DateTime.utc_now()
        })
      end)

      # Verify each site has its own CSS
      Enum.each(sites, fn site ->
        assert TailwindCompiler.css_exists?(site) == true
        css = TailwindCompiler.get_compiled_css(site)
        assert css =~ site
      end)

      # Delete one site's CSS shouldn't affect others
      [first | rest] = sites
      TailwindCompiler.delete_compiled_css(first)

      assert TailwindCompiler.css_exists?(first) == false

      Enum.each(rest, fn site ->
        assert TailwindCompiler.css_exists?(site) == true
      end)

      # Cleanup
      Enum.each(sites, fn site ->
        AssetsState.delete(site, "css")
      end)
    end

    test "compression formats are properly linked" do
      site_name = "test_compression_#{System.unique_integer([:positive])}"

      assert {:ok, css} = quiet_compile_and_store(site_name)

      {:ok, raw} = AssetsState.get(site_name, "css")
      {:ok, brotli} = AssetsState.get(site_name, "brotli_css")
      {:ok, gzip} = AssetsState.get(site_name, "gzip_css")

      assert raw.hash == brotli.hash
      assert raw.hash == gzip.hash
      assert raw.updated_at == brotli.updated_at
      assert raw.updated_at == gzip.updated_at

      assert raw.value == css
      assert :zlib.gunzip(gzip.value) == css

      # Cleanup
      AssetsState.delete(site_name, "css")
    end

    test "handles special characters in site names" do
      # Test with various special characters that should be handled
      special_sites = [
        "test-with-dash",
        "test_with_underscore",
        "test.with.dots"
      ]

      for site <- special_sites do
        full_name = "#{site}_#{System.unique_integer([:positive])}"

        # Store test CSS
        AssetsState.save(%{
          id: full_name,
          type: "css",
          value: "/* CSS for special site */",
          hash: "test",
          updated_at: DateTime.utc_now()
        })

        # Should be retrievable
        assert TailwindCompiler.css_exists?(full_name)
        css = TailwindCompiler.get_compiled_css(full_name)
        assert css =~ "CSS for special site"

        # Cleanup
        AssetsState.delete(full_name, "css")
      end
    end

    test "get_css_status provides accurate metrics" do
      site_name = "test_metrics_#{System.unique_integer([:positive])}"
      # Create CSS with measurable size
      test_css = String.duplicate("/* CSS content */", 100)
      now = DateTime.utc_now()

      # Store CSS with known values
      AssetsState.save(%{
        id: site_name,
        type: "css",
        value: test_css,
        hash: "test_hash",
        updated_at: now
      })

      # Get status
      status = TailwindCompiler.get_css_status(site_name)

      # Verify metrics
      assert status.site == site_name
      assert status.compiled == true
      assert status.updated_at == now
      assert status.css_size == byte_size(test_css)
      assert status.css_size > 0

      # Cleanup
      AssetsState.delete(site_name, "css")
    end

    test "concurrent operations on different sites" do
      sites = for i <- 1..5, do: "test_concurrent_#{i}_#{System.unique_integer([:positive])}"

      # Simulate concurrent operations
      tasks =
        Enum.map(sites, fn site ->
          Task.async(fn ->
            # Store CSS
            AssetsState.save(%{
              id: site,
              type: "css",
              value: "/* CSS for #{site} */",
              hash: "hash_#{site}",
              updated_at: DateTime.utc_now()
            })

            # Read CSS
            css = TailwindCompiler.get_compiled_css(site)

            # Get status
            status = TailwindCompiler.get_css_status(site)

            {site, css, status}
          end)
        end)

      # Collect results
      results = Enum.map(tasks, &Task.await/1)

      # Verify each site's operations succeeded independently
      Enum.each(results, fn {site, css, status} ->
        assert css =~ site
        assert status.site == site
        assert status.compiled == true
      end)

      # Cleanup
      Enum.each(sites, fn site ->
        AssetsState.delete(site, "css")
      end)
    end
  end

  # AN UNLAYERED RULE BEATS EVERY LAYERED ONE, so the icon's own `width:1.5rem` beat `size-3`.
  describe "an icon with a size utility on it" do
    setup do
      site = "icon-size-#{System.unique_integer([:positive])}"

      MishkaCmsCore.Runtime.Handlers.BootHandler.create_template_file(
        site,
        "page",
        "home",
        ~s(<span class="hero-bell size-3"></span>)
      )

      on_exit(fn ->
        File.rm_rf(MishkaCmsCore.Runtime.Helpers.static_temp_dir(["runtime", site]))
      end)

      %{site: site}
    end

    test "is sized by the utility: the icon rule is in components, ranked below utilities", %{
      site: site
    } do
      assert {:ok, css} = TailwindCompiler.compile(site)
      [_shared, own] = String.split(css, "/* Site: #{site} */", parts: 2)

      # The site's chunk orders its layers itself, not only through the shared base before it.
      for stylesheet <- [css, own] do
        assert ranked_layers(stylesheet) == ~w(theme base components utilities)
      end

      assert layers_around(own, ".hero-bell{") == ["components"]
      assert layers_around(own, ".size-3{") == ["utilities"]
    end
  end

  # Tailwind's four layers in the order the stylesheet first names them, which is their rank.
  defp ranked_layers(css) do
    ~r/@layer\s*([\w\s,-]+?)\s*[;{]/
    |> Regex.scan(css, capture: :all_but_first)
    |> Enum.flat_map(fn [names] -> String.split(names, ",", trim: true) end)
    |> Enum.map(&String.trim/1)
    |> Enum.uniq()
    |> Enum.filter(&(&1 in ~w(theme base components utilities)))
  end

  # The `@layer` blocks open where the first rule starting with `needle` is, outermost first.
  defp layers_around(css, needle) do
    {at, _length} = :binary.match(css, needle)

    for "@layer " <> name <- css |> binary_part(0, at) |> open_blocks("", []), do: name
  end

  defp open_blocks(<<>>, _prelude, stack), do: Enum.reverse(stack)

  defp open_blocks(<<"/*", rest::binary>>, prelude, stack),
    do: rest |> :binary.split("*/") |> List.last() |> open_blocks(prelude, stack)

  defp open_blocks(<<?\\, _escaped, rest::binary>>, prelude, stack),
    do: open_blocks(rest, prelude, stack)

  defp open_blocks(<<quote, rest::binary>>, prelude, stack) when quote in [?", ?'],
    do: rest |> after_string(quote) |> open_blocks(prelude, stack)

  defp open_blocks(<<?{, rest::binary>>, prelude, stack),
    do: open_blocks(rest, "", [String.trim(prelude) | stack])

  defp open_blocks(<<?}, rest::binary>>, _prelude, [_closed | stack]),
    do: open_blocks(rest, "", stack)

  defp open_blocks(<<?;, rest::binary>>, _prelude, stack), do: open_blocks(rest, "", stack)

  defp open_blocks(<<char, rest::binary>>, prelude, stack),
    do: open_blocks(rest, <<prelude::binary, char>>, stack)

  defp after_string(<<?\\, _escaped, rest::binary>>, quote), do: after_string(rest, quote)
  defp after_string(<<quote, rest::binary>>, quote), do: rest
  defp after_string(<<_char, rest::binary>>, quote), do: after_string(rest, quote)
  defp after_string(<<>>, _quote), do: <<>>
end
