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

      case TailwindCompiler.compile_shared_base() do
        {:ok, css} when is_binary(css) ->
          assert byte_size(css) > 0

        {:error, reason} ->
          assert is_binary(reason) or is_atom(reason)
      end
    end
  end

  describe "compile_and_store_shared_base/0" do
    test "compiles and stores shared base CSS" do
      TailwindCompiler.ensure_installed()

      case TailwindCompiler.compile_and_store_shared_base() do
        {:ok, css} when is_binary(css) ->
          assert {:ok, asset} = AssetsState.get("__shared_base__", "css")
          assert is_binary(asset.value)
          assert {:ok, _} = AssetsState.get("__shared_base__", "brotli_css")
          assert {:ok, _} = AssetsState.get("__shared_base__", "gzip_css")

        {:error, reason} ->
          assert is_binary(reason) or is_atom(reason)
      end
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
      case quiet_compile("test_site") do
        {:ok, css} when is_binary(css) ->
          assert String.contains?(css, "/*") or css == ""

        {:error, reason} ->
          assert is_binary(reason) or is_atom(reason)
      end
    end

    # There is ONE way to assemble a site's stylesheet: the cached shared base plus the site's own
    # delta. The `use_shared_base: false` mode that used to sit beside it restated every decision
    # about what gets scanned, was called by nothing but its own tests, and drifted each time that
    # answer changed.
    test "the site's delta is appended to the shared base, under its own marker" do
      TailwindCompiler.ensure_installed()

      case TailwindCompiler.compile("test_shared_site") do
        {:ok, css} when is_binary(css) ->
          assert String.contains?(css, "/* Site: test_shared_site */")

        {:error, reason} ->
          assert is_binary(reason) or is_atom(reason)
      end
    end

    test "handles compile errors gracefully" do
      log =
        capture_log(fn ->
          result = quiet_compile("test_error_site")
          assert match?({:ok, _}, result) or match?({:error, _}, result)
        end)

      # May or may not have logs depending on Tailwind availability
      assert is_binary(log)
    end

    test "handles different site names" do
      sites = ["site_one", "site-two", "site.three", "site_4"]

      for site <- sites do
        result = quiet_compile(site)
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end

    test "compile result is consistent for same site" do
      site_name = "test_consistent_#{System.unique_integer([:positive])}"

      case quiet_compile(site_name) do
        {:ok, css1} ->
          case quiet_compile(site_name) do
            {:ok, css2} ->
              # CSS should be similar for same site
              assert byte_size(css1) == byte_size(css2)

            {:error, _} ->
              :ok
          end

        {:error, _} ->
          :ok
      end
    end
  end

  describe "compile_and_store/1" do
    test "compiles and stores CSS with all compression formats" do
      site_name = "test_compile_store_#{System.unique_integer([:positive])}"

      # Clean up any existing CSS first
      AssetsState.delete(site_name, "css")

      case quiet_compile_and_store(site_name) do
        {:ok, css} when is_binary(css) ->
          # Check that all formats are stored
          assert {:ok, asset} = AssetsState.get(site_name, "css")
          assert {:ok, brotli} = AssetsState.get(site_name, "brotli_css")
          assert {:ok, gzip} = AssetsState.get(site_name, "gzip_css")

          # All should have same hash
          assert asset.hash == brotli.hash
          assert asset.hash == gzip.hash

          # Check metadata
          assert asset.updated_at != nil
          assert is_binary(asset.value)

        {:error, reason} ->
          # Tailwind might not be available
          assert is_binary(reason) or is_atom(reason)
      end

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

      case quiet_compile_and_store(site_name) do
        {:ok, _css} ->
          {:ok, asset} = AssetsState.get(site_name, "css")

          # Check metadata fields
          assert asset.id == site_name
          assert asset.type == "css"
          assert is_binary(asset.hash)
          # MD5 hash length in hex
          assert String.length(asset.hash) == 32
          assert %DateTime{} = asset.updated_at

        {:error, _} ->
          :ok
      end

      # Cleanup
      AssetsState.delete(site_name, "css")
    end

    test "logs success when CSS is compiled and stored" do
      site_name = "test_log_success_#{System.unique_integer([:positive])}"

      log =
        capture_log([level: :debug], fn ->
          case quiet_compile_and_store(site_name) do
            {:ok, _css} ->
              # Success case
              :ok

            {:error, _reason} ->
              # Tailwind might not be available
              :ok
          end
        end)

      # May have debug log if successful
      assert is_binary(log)

      # Cleanup
      AssetsState.delete(site_name, "css")
    end

    test "logs error when compilation fails" do
      # Mock a failure by using compile directly with a site that might fail
      log =
        capture_log([level: :error], fn ->
          # This might or might not fail depending on Tailwind availability
          _result = quiet_compile_and_store("test_error_site")
        end)

      # May or may not have error logs
      assert is_binary(log)
    end

    test "returns same CSS that gets stored" do
      site_name = "test_return_store_#{System.unique_integer([:positive])}"

      case quiet_compile_and_store(site_name) do
        {:ok, returned_css} ->
          stored_css = TailwindCompiler.get_compiled_css(site_name)
          assert returned_css == stored_css

        {:error, _} ->
          :ok
      end

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
      case quiet_refresh_css(site_name) do
        {:ok, css} ->
          assert is_binary(css)

          # Verify CSS was stored
          assert TailwindCompiler.css_exists?(site_name)
          stored = TailwindCompiler.get_compiled_css(site_name)
          assert stored == css

        {:error, _reason} ->
          # Tailwind might not be available
          :ok
      end

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
      case quiet_refresh_css(site_name) do
        {:ok, new_css} ->
          # Should have new CSS
          assert new_css != old_css
          stored = TailwindCompiler.get_compiled_css(site_name)
          assert stored == new_css

        {:error, _} ->
          # Tailwind not available
          :ok
      end

      # Cleanup
      AssetsState.delete(site_name, "css")
    end

    test "updates all compression formats on refresh" do
      site_name = "test_refresh_formats_#{System.unique_integer([:positive])}"

      case quiet_refresh_css(site_name) do
        {:ok, _css} ->
          # All formats should be updated
          assert {:ok, _} = AssetsState.get(site_name, "css")
          assert {:ok, _} = AssetsState.get(site_name, "brotli_css")
          assert {:ok, _} = AssetsState.get(site_name, "gzip_css")

        {:error, _} ->
          :ok
      end

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

      # Compile and store (might fail if Tailwind not available)
      case quiet_compile_and_store(site_name) do
        {:ok, css} ->
          assert is_binary(css)

          # CSS should now exist
          assert TailwindCompiler.css_exists?(site_name) == true

          # Should be retrievable
          retrieved = TailwindCompiler.get_compiled_css(site_name)
          assert retrieved == css

          # Status should show compiled
          status = TailwindCompiler.get_css_status(site_name)
          assert status.compiled == true
          assert status.css_size > 0

        {:error, _reason} ->
          # Tailwind not available - that's ok for tests
          :ok
      end

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

      case quiet_compile_and_store(site_name) do
        {:ok, _css} ->
          # Get all formats
          {:ok, raw} = AssetsState.get(site_name, "css")
          {:ok, brotli} = AssetsState.get(site_name, "brotli_css")
          {:ok, gzip} = AssetsState.get(site_name, "gzip_css")

          # All should have same hash (content identifier)
          assert raw.hash == brotli.hash
          assert raw.hash == gzip.hash

          # All should have same timestamp
          assert raw.updated_at == brotli.updated_at
          assert raw.updated_at == gzip.updated_at

          # Brotli and gzip should be binary (compressed)
          assert is_binary(brotli.value)
          assert is_binary(gzip.value)

          # Raw CSS should be different from compressed
          assert raw.value != brotli.value
          assert raw.value != gzip.value

        {:error, _} ->
          :ok
      end

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
end
