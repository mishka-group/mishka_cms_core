# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.Helpers do
  @moduledoc false
  @doc """
  Generates a unique module name for runtime-compiled resources.

  This function creates a deterministic module name by combining the resource ID,
  site identifier, and resource type. It uses MD5 hashing to ensure the generated
  module name is always valid and avoids Elixir module naming restrictions.

  ## Parameters

   * `id` - A string identifier for the resource (typically a UUID)
   * `site` - A string identifier for the site/tenant
   * `resource` - A string representing the resource type (e.g., "page", "component", "layout")

  ## Examples

     iex> module_name("550e8400-e29b-41d4-a716-446655440000", "blog", "page")
     MishkaCmsCore.Runtime.A1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6.Page

     iex> module_name("123-456-789", "my_site", "component")
     MishkaCmsCore.Runtime.B2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7.Component

  ## Implementation Details

  The function uses MD5 hashing to:
  - Handle any special characters in `id` or `site` that would be invalid in module names
  - Ensure consistent module naming regardless of input format
  - Avoid Elixir's module name length limitations
  - Provide collision resistance for different ID/site combinations
  - If we expect < 50,000 unique pages, phash2 was fine. Beyond that, we considered MD5 for safety.

  The generated module follows the pattern: `MishkaCmsCore.Runtime.<md5_hash>.<Resource>`

  ## Notes

  - The same `id`, `site`, and `resource` combination will always generate the same module name
  - MD5 is used for speed and deterministic output, not cryptographic security
  - The function assumes `resource` contains only valid module name characters
  """
  @spec module_name(String.t(), String.t() | nil, String.t()) :: module()
  def module_name(id, site, resource) do
    # Coerce a missing/nil site to "Global" so callers can pass raw
    # `assigns[:site]` (which is `nil` outside the parent's declared
    # `:site` attr scope, e.g. inside slot inner_blocks) without
    # producing a different hash than the boot-time compile path.
    # Boot/worker code already routes `nil` through this same rule —
    # centralizing it here keeps the hash key authoritative.
    resolved_site = site || "Global"
    site_hash = :md5 |> :crypto.hash("#{id}" <> resolved_site) |> Base.encode16(case: :lower)

    Module.concat([MishkaCmsCore.Runtime, "#{site_hash}", resource])
  end

  @doc """
  Whether a runtime CMS module is currently loaded in the VM's code table.

  The single source of truth for the "is this compiled runtime module available?" check used
  across the runtime (the compiler handler, workers, render helpers, site teardown, ...). It is a
  pure `:erlang.module_loaded/1` code-table lookup that does NOT attempt to load the module — do
  not swap it for `Code.ensure_loaded?/1`, which would trigger loading and change hot-path behavior.

  ## Examples

      loaded?(Enum)                         #=> true
      loaded?(:"Elixir.Runtime.NotCompiled") #=> false
  """
  @spec loaded?(module()) :: boolean()
  def loaded?(module), do: :erlang.module_loaded(module)

  @doc """
  How many times a CSS or JS build asks `:global.trans/4` for the Tailwind or esbuild install lock
  before it gives up: about `wait` milliseconds of tries — `config :mishka_cms_core,
  :asset_install_wait`, ten minutes unless set.

  `:global` sleeps a random time between tries, up to 0.25, 0.5, 1, 2 and 4 seconds for the first
  five and up to 8 seconds after that — about 3.9 seconds for the five, then 4 seconds a try.

  ## Examples

      install_lock_retries(:timer.minutes(10)) #=> 154
      install_lock_retries(:timer.minutes(1))  #=> 19
  """
  @spec install_lock_retries(non_neg_integer()) :: non_neg_integer()
  def install_lock_retries(
        wait \\ Application.get_env(:mishka_cms_core, :asset_install_wait, :timer.minutes(10))
      ),
      do: 5 + div(max(wait - 3_875, 0), 4_000)

  @doc """
  Compresses Asset content using Brotli and Gzip algorithms.

  Returns a tuple with {brotli, gzip} where brotli may be nil if compression fails.
  """
  def compress_asset(css_content) do
    brotli =
      case ExBrotli.compress(css_content) do
        {:ok, compressed} -> compressed
        {:error, _} -> nil
      end

    gzip = :zlib.gzip(css_content)

    {brotli, gzip}
  end
end
