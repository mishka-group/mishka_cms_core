# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Mishka.Css.Closure do
  @moduledoc """
  Prints which globally-installed components a site can actually reach, and what that saves.

  A UI kit is installed once and shared, so its components live in one directory that the CSS
  compiler globs wholesale. This walks the reference graph from a site's own templates instead and
  reports the difference — read-only, so it is safe to run against production data.

  ## Usage

      mix mishka.css.closure                 # every site
      mix mishka.css.closure --site localhost

  ## Reading the output

  `unbounded` means a reached template names a component in a way no build-time walk can resolve —
  an expression in `component_name={…}`, or a call handing an expression to an attribute a
  component names one through. That site keeps the full glob; the templates responsible are logged
  so they can be rewritten to literals if the saving is wanted.

  A component that names one through its own attribute — `component_name={@card}` — is printed
  with the names that attribute takes, its default and what the reached callers write for it:

      doc-workspace-list.card -> nothing

  See `MishkaCmsCore.Runtime.Compilers.CssClosure`, whose moduledoc lists every reference it cannot
  resolve.
  """

  use Mix.Task

  alias MishkaCmsCore.Runtime.Compilers.CssClosure
  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler

  @shortdoc "Reports the reachable component set per site"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest} = OptionParser.parse!(args, strict: [site: :string])
    runtime_dir = CssClosure.default_runtime_dir()
    all = CssClosure.all_components(runtime_dir: runtime_dir)

    sites =
      case opts[:site] do
        nil -> sites_in(runtime_dir)
        site -> [site]
      end

    Mix.shell().info(
      "#{length(all)} global components installed, #{human(bytes(all, runtime_dir))}\n"
    )

    Enum.each(sites, &report(&1, all, runtime_dir))
  end

  # THE ROOTS COME FROM THE COMPILER, not from a second guess at them. A layout is chosen by a
  # database relation, so which layouts a site's pages use is not visible in the directory tree —
  # and a report that walked from different roots than the build would describe a stylesheet nobody
  # ships.
  defp report(site, all, runtime_dir) do
    roots = TailwindCompiler.closure_roots(site, runtime_dir: runtime_dir)

    case CssClosure.for_site(site,
           runtime_dir: runtime_dir,
           roots: roots,
           content_components: TailwindCompiler.content_components(site)
         ) do
      :unbounded ->
        Mix.shell().info(
          "#{site}: unbounded — a template names a component the walk cannot resolve"
        )

      %{components: reached, scanned: scanned, resolved: resolved} ->
        saved = bytes(all, runtime_dir) - bytes(reached, runtime_dir)

        Mix.shell().info(
          "#{site}: #{length(reached)}/#{length(all)} components reachable from #{scanned} " <>
            "templates, #{human(saved)} not scanned"
        )

        Enum.each(
          resolved,
          &Mix.shell().info("  #{&1.component}.#{&1.attribute} -> #{names(&1)}")
        )

        Enum.each(reached, &Mix.shell().info("    #{&1}"))
    end
  end

  defp names(%{names: []}), do: "nothing"
  defp names(%{names: names}), do: Enum.join(names, ", ")

  defp sites_in(runtime_dir) do
    case File.ls(runtime_dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 == "__global__"))
        |> Enum.filter(&File.dir?(Path.join(runtime_dir, &1)))
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end

  defp bytes(components, runtime_dir) do
    Enum.reduce(components, 0, fn name, total ->
      path = Path.join([runtime_dir, "__global__", "component", name <> ".template"])

      case File.stat(path) do
        {:ok, %{size: size}} -> total + size
        {:error, _reason} -> total
      end
    end)
  end

  defp human(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp human(bytes) when bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp human(bytes), do: "#{bytes} B"
end
