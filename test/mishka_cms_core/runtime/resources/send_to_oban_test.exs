defmodule MishkaCmsCore.Runtime.Resources.Changes.SendToObanTest do
  @moduledoc """
  The job payload carries the record attributes (including `site_id`) and a
  string action. Site name resolution happens in the worker, from `site_id`.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Resources.Changes.SendToOban
  alias MishkaCmsCore.Runtime.{Page, Component}

  defp page_record(attrs) do
    struct(
      Page,
      Map.merge(%{id: "p1", name: "home", title: "Home", path: "/home"}, Map.new(attrs))
    )
  end

  describe "build_job_args/2" do
    test "carries site_id and the lifecycle attributes the worker needs" do
      record = page_record(%{active: true, precompile: true, site_id: "s1"})
      changeset = Ash.Changeset.for_create(Page, :create, %{name: "home", title: "Home"})

      args = SendToOban.build_job_args(changeset, record)

      assert args.resource == "MishkaCmsCore.Runtime.Page"
      assert args.action == "create"
      assert args.data.site_id == "s1"
      assert args.data.active == true
      assert args.data.precompile == true
      assert args.data.path == "/home"
      assert args.data.name == "home"
    end

    test "normalizes the action to a string" do
      record = page_record(%{active: true, site_id: "s1"})
      changeset = Ash.Changeset.for_create(Page, :create, %{name: "home", title: "Home"})

      assert SendToOban.build_job_args(changeset, record).action == "create"
    end

    test "does not include the :site relationship" do
      record = page_record(%{active: true, site_id: "s1"})
      changeset = Ash.Changeset.for_create(Page, :create, %{name: "home", title: "Home"})

      refute Map.has_key?(SendToOban.build_job_args(changeset, record).data, :site)
    end

    test "global record carries a nil site_id" do
      record = struct(Component, %{id: "c1", name: "btn", active: true, site_id: nil})
      changeset = Ash.Changeset.for_create(Component, :create)

      assert SendToOban.build_job_args(changeset, record).data.site_id == nil
    end
  end

  # WHO CAUSED THE JOB. Without this the activity log answers "System" for every job, so a compile
  # that failed can never be tied back to the save that enqueued it — which is the question the log
  # is opened to answer. Read the same way AshPaperTrail reads it, so the job and the version written
  # by that same save can never disagree.
  describe "the acting user" do
    test "is carried when somebody is acting" do
      record = page_record(%{active: true, site_id: "s1"})

      changeset =
        Page
        |> Ash.Changeset.for_create(:create, %{name: "home", title: "Home"})
        |> Ash.Changeset.set_context(%{private: %{actor: %{id: "u-1"}}})

      assert SendToOban.build_job_args(changeset, record).actor_id == "u-1"
    end

    test "is absent when nobody is — a cron or a boot is genuinely System" do
      record = page_record(%{active: true, site_id: "s1"})
      changeset = Ash.Changeset.for_create(Page, :create, %{name: "home", title: "Home"})

      refute Map.has_key?(SendToOban.build_job_args(changeset, record), :actor_id)
    end

    test "survives the trip through Oban's JSON args" do
      record = page_record(%{active: true, site_id: "s1"})

      changeset =
        Page
        |> Ash.Changeset.for_create(:create, %{name: "home", title: "Home"})
        |> Ash.Changeset.set_context(%{private: %{actor: %{id: "u-1"}}})

      # Oban stores args as JSON, so what the feed reads back is string-keyed, never the atom key
      # written here. This is the seam that check catches.
      round_tripped =
        changeset |> SendToOban.build_job_args(record) |> Jason.encode!() |> Jason.decode!()

      assert round_tripped["actor_id"] == "u-1"
    end
  end
end
