# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Workers.SiteTeardownWorkerTest do
  @moduledoc """
  The teardown worker frees a permanently-deleted site's in-memory artifacts:
  SiteState gate entry, cached assets, and routing metadata.

  ## Why it needs a database connection to test three ETS tables

  `perform/1` asks the DATABASE whether the site is really gone before it purges anything — the
  guard against a rolled-back permanent delete. So the worker cannot run without a checked-out
  connection, and this case had none: it passed only while some neighbouring test's shared sandbox
  owner happened to still be alive, and exited with `DBConnection.Holder.checkout` "no process" when
  it was not. Order-dependent, and it surfaced as one failure in a full run on some seeds and not
  others.
  """
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Runtime.Workers.SiteTeardownWorker, as: Worker
  alias MishkaCmsCore.Runtime.States.{SiteState, AssetsState, WebRunTimeMetaDataState}

  test "purges SiteState, assets and routing for a deleted site" do
    n = System.unique_integer([:positive])
    # A non-existent (already-deleted) site id → site_present? is false.
    site_id = Ecto.UUID.generate()
    site_name = "std-acme-#{n}"
    page_id = "std-page-#{n}"

    SiteState.save(%{id: site_id, name: site_name, host: "#{n}.test", priority: 0, active: true})

    AssetsState.save(%{
      id: site_name,
      type: "css",
      value: "body{}",
      hash: "deadbeef",
      updated_at: ~U[2026-05-30 00:00:00Z]
    })

    WebRunTimeMetaDataState.save(%{
      id: page_id,
      site: site_name,
      path: "/about",
      title: "About",
      created_at: ~U[2026-05-30 00:00:00Z],
      section: "Page",
      priority: 0
    })

    assert SiteState.get!(site_id)
    assert AssetsState.exists?(site_name, "css")
    assert WebRunTimeMetaDataState.count_by_site(site_name) == 1

    job = %Oban.Job{
      args: %{
        "site_id" => site_id,
        "site_name" => site_name,
        "modules" => [%{"type" => "Page", "key" => page_id}]
      }
    }

    assert :ok = Worker.perform(job)

    refute SiteState.get!(site_id)
    refute AssetsState.exists?(site_name, "css")
    assert WebRunTimeMetaDataState.count_by_site(site_name) == 0
  end
end
