defmodule MishkaCmsCore.Runtime.CssInvalidationTest do
  @moduledoc """
  Whose stylesheet has to be rebuilt when a component changes.

  A site's CSS is built from what that site reaches, which makes the rebuild question real: a
  component saved in the admin has to reach the stylesheet of every site that renders it, and of no
  other. Two cases carry it —

    * a SITE-SCOPED component can only be used by its own site, so one site rebuilds;
    * a GLOBAL component may be used by any site, including through a global layout several sites
      share, so every site rebuilds. Broader than strictly necessary, and deliberately so: the
      alternative is asking, per site, whether that component is in its closure, and a site that is
      wrongly skipped serves a page with missing rules until something else happens to touch it.

  The shared base is dropped for a global change too, because it is compiled once and reused.

  See `MishkaCmsCore.Runtime.Compilers.TailwindCompiler.closure_roots/2` for the read that decides
  what a rebuild will then scan.
  """
  use MishkaCmsCore.DataCase, async: false

  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use Oban.Testing, repo: @repo
  @moduletag :integration

  alias MishkaCmsCore.Runtime.Handlers.BootHandler
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker

  setup do
    sites =
      for i <- 1..2 do
        n = System.unique_integer([:positive])
        site = create_site!(name: "css-inv-#{i}-#{n}", host: "css-inv-#{i}-#{n}.test")

        :ok =
          SiteState.save(%{
            id: site.id,
            name: site.name,
            host: site.host,
            priority: 0,
            active: true
          })

        on_exit(fn -> SiteState.delete(site.id) end)
        site
      end

    %{sites: sites}
  end

  defp save_component(component, action \\ "create") do
    site_name =
      case component["site_id"] do
        nil -> "Global"
        id -> elem(SiteState.get(id), 1).name
      end

    on_exit(fn ->
      BootHandler.delete_template_file(
        if(component["site_id"], do: site_name),
        "component",
        component["name"]
      )
    end)

    RuntimeCompilerWorker.perform(%Oban.Job{
      args: %{
        "resource" => "MishkaCmsCore.Runtime.Component",
        "action" => action,
        "data" => component
      }
    })
  end

  defp component(overrides) do
    Map.merge(
      %{
        "id" => Ecto.UUID.generate(),
        "name" => "css-inv-c-#{System.unique_integer([:positive])}",
        "active" => true,
        "precompile" => false,
        "site_id" => nil,
        "template" => ~s(<b class="css-inv-class"></b>)
      },
      overrides
    )
  end

  defp css_jobs_for(site_name) do
    RuntimeCompilerWorker
    |> then(&all_enqueued(worker: &1))
    |> Enum.filter(fn job ->
      get_in(job.args, ["data", "site_name"]) == site_name and
        get_in(job.args, ["data", "type"]) == "css"
    end)
  end

  # R9 — a component added at runtime and used in a page has to reach that site's stylesheet, and a
  # stylesheet is only rebuilt because a job says so.
  describe "a site's own component" do
    test "rebuilds that site's CSS", %{sites: [site, _other]} do
      assert :ok = save_component(component(%{"site_id" => site.id}))

      assert length(css_jobs_for(site.name)) == 1
    end

    test "does not rebuild anybody else's", %{sites: [site, other]} do
      assert :ok = save_component(component(%{"site_id" => site.id}))

      assert css_jobs_for(other.name) == []
    end
  end

  # R10 — a global component may be rendered through a layout several sites share, so a change to it
  # is a change to all of them. What it must NOT do is throw away the shared base; that property and
  # the measurement behind it live in
  # `MishkaCmsCore.Runtime.Compilers.SharedBaseContentsTest`.
  describe "a global component" do
    test "rebuilds every active site", %{sites: [one, two]} do
      assert :ok = save_component(component(%{"site_id" => nil}))

      assert length(css_jobs_for(one.name)) == 1
      assert length(css_jobs_for(two.name)) == 1
    end
  end

  describe "the template a rebuild will scan" do
    # The rebuild is worth nothing if the file it scans does not carry the new classes. This is the
    # half that used to be skipped whenever the component was not compiled.
    test "is written even though a lazy component compiles no module", %{sites: [site, _other]} do
      com = component(%{"site_id" => site.id, "precompile" => false})

      assert :ok = save_component(com)

      path =
        ["runtime", site.name, "component"]
        |> MishkaCmsCore.Runtime.Helpers.static_temp_dir()
        |> Path.join("#{Slug.slugify(com["name"])}.template")

      assert File.read!(path) =~ "css-inv-class"
    end

    test "is removed when the component is deactivated", %{sites: [site, _other]} do
      com = component(%{"site_id" => site.id})
      assert :ok = save_component(com)

      assert :ok = save_component(Map.put(com, "active", false), "update")

      path =
        ["runtime", site.name, "component"]
        |> MishkaCmsCore.Runtime.Helpers.static_temp_dir()
        |> Path.join("#{Slug.slugify(com["name"])}.template")

      refute File.exists?(path)
    end
  end

  describe "a job that runs after a newer save" do
    # A job carries the row as it was saved, the way `SendToOban.build_job_args/2` writes it — JSON,
    # so its times are ISO 8601 text.
    defp args_of(record, overrides) do
      record
      |> Map.from_struct()
      |> Map.take(
        Ash.Resource.Info.attribute_names(MishkaCmsCore.Runtime.Component)
        |> MapSet.to_list()
      )
      |> Map.merge(overrides)
      |> JSON.encode!()
      |> JSON.decode!()
    end

    defp template_of(site, com) do
      ["runtime", site.name, "component"]
      |> MishkaCmsCore.Runtime.Helpers.static_temp_dir()
      |> Path.join("#{Slug.slugify(com.name)}.template")
    end

    # Rescued by `Oban.Lifeline` half an hour after a seed script left it executing, it wrote its old
    # template over the one the next save had built.
    test "does not write its older copy over the stored row's", %{sites: [site, _other]} do
      com =
        create_component!(
          site_id: site.id,
          template: ~s(<b class="css-inv-new"></b>),
          active: true
        )

      older = com.updated_at |> DateTime.add(-60, :second)
      stale = args_of(com, %{template: ~s(<b class="css-inv-old"></b>), updated_at: older})

      assert :ok = save_component(stale, "update")

      refute File.exists?(template_of(site, com)) and
               File.read!(template_of(site, com)) =~ "css-inv-old"
    end

    test "while a job carrying the stored row's own copy still builds it", %{
      sites: [site, _other]
    } do
      com =
        create_component!(
          site_id: site.id,
          template: ~s(<b class="css-inv-new"></b>),
          active: true
        )

      assert :ok = save_component(args_of(com, %{}), "update")

      assert File.read!(template_of(site, com)) =~ "css-inv-new"
    end
  end
end
