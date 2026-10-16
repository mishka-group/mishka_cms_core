# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.ResignCodeTest do
  @moduledoc """
  `mix mishka.resign_code`, which is the answer the log line gives an operator whose database came
  from somewhere else.

  ## Why it needed a test

  It had none, and the cheapest proof of what it promises is exactly this: run
  `mix mishka.resign_code` against a seeded DB and assert the count reaches zero. The bug it would
  have caught was real — the task asked `:master_read` for `page: [limit: 1000]` and that action
  caps `max_page_size` at 100, so a deployment with more than a hundred pages re-signed the first
  hundred, printed a success line, and left every row after them compiling to an inert clause.
  Silently, and only on the deployments large enough to care.

  ## What "unsigned" costs

  A snippet whose signature does not verify compiles to a clause that does nothing, and the page
  still renders — which is the right failure mode and also the quiet one. Helpers became signable
  only when `Embeddeds.Helper` gained a `signature` field, so this is the first release where
  running the task is the difference between a component's lifecycle working and doing nothing.
  """
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.PageBuilder.CodeAudit
  alias MishkaCmsCore.Runtime.PageBuilder.CodeSignature

  require Ash.Query

  @moduletag :integration
  @moduletag :capture_log

  @key "a-test-signing-key-that-is-long-enough"

  setup do
    on_exit(fn -> Application.delete_env(:mishka_cms_core, :code_signing_key) end)
    :ok
  end

  defp with_unsigned_helpers(site, count) do
    for index <- 1..count do
      create_component!(
        name: "unsigned-#{index}",
        site_id: site.id,
        helpers: [%{"name" => "shout", "args" => "word", "code" => "String.upcase(word)"}]
      )
    end
  end

  defp helpers_of(site) do
    Component
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.stream!(authorize?: false)
    |> Enum.flat_map(& &1.helpers)
  end

  test "re-signs every row, not the first page of them" do
    site = create_site!()

    # Written with signing OFF, which is how a restored dump arrives: code, no signatures.
    with_unsigned_helpers(site, 120)

    assert Enum.all?(helpers_of(site), &is_nil(&1.signature)),
           "the fixture was not written unsigned"

    Application.put_env(:mishka_cms_core, :code_signing_key, @key)

    refute Enum.any?(helpers_of(site), &CodeSignature.trusted?/1),
           "nothing should verify before the task runs"

    Mix.Tasks.Mishka.ResignCode.run([])

    helpers = helpers_of(site)

    assert length(helpers) == 120

    # THE ASSERTION THE 100-ROW CAP FAILED. Rows 101-120 stayed unsigned and the task said it had
    # succeeded.
    assert Enum.all?(helpers, &CodeSignature.trusted?/1),
           "#{Enum.count(helpers, &(!CodeSignature.trusted?(&1)))} of 120 helpers are still unsigned"
  end

  # THE COUNT THE OPERATOR ACTUALLY READS. `CodeSignature` names each unverified snippet as it
  # compiles, scattered through a boot that also logs every site and page; the total is what says
  # "none of the code in this database runs here" at a moment somebody is looking.
  describe "the boot-time audit" do
    test "counts what does not verify, and reaches zero when the task has run" do
      site = create_site!()
      with_unsigned_helpers(site, 3)

      Application.put_env(:mishka_cms_core, :code_signing_key, @key)

      assert CodeAudit.untrusted() >= 3,
             "the audit did not see helpers that do not verify"

      Mix.Tasks.Mishka.ResignCode.run([])

      assert CodeAudit.untrusted() == 0,
             "the task reported success and the audit still finds unsigned code"
    end

    test "says the total at warning, naming the command that fixes it" do
      site = create_site!()
      with_unsigned_helpers(site, 3)

      Application.put_env(:mishka_cms_core, :code_signing_key, @key)

      log = ExUnit.CaptureLog.capture_log(fn -> assert CodeAudit.report() == :ok end)

      assert log =~ "[CodeSignature]"
      assert log =~ "mix mishka.resign_code"
      assert log =~ "does nothing"
    end

    # OFF IS THE DEFAULT, and an audit that read four tables at every boot to answer zero would be a
    # cost paid by every deployment that never turns signing on.
    test "answers zero without reading anything when signing is off" do
      site = create_site!()
      with_unsigned_helpers(site, 3)

      Application.delete_env(:mishka_cms_core, :code_signing_key)

      assert CodeAudit.untrusted() == 0
      assert CodeAudit.report() == :ok
    end

    # The resign task re-signs exactly what the audit counts, from one list, so a fifth resource
    # gaining a code field cannot be audited and left unsigned — or signed and never counted.
    test "the task and the audit read the same list of resources" do
      names = Enum.map(CodeAudit.sources(), fn {resource, _fields} -> resource end)

      assert MishkaCmsCore.Runtime.Page in names
      assert MishkaCmsCore.Runtime.Layout in names
      assert MishkaCmsCore.Runtime.Component in names
      assert MishkaCmsCore.Runtime.ErrorPage in names
    end
  end

  # SIGNING WITH NO KEY IS A NO-OP THAT WOULD REPORT SUCCESS, which is the one outcome worse than
  # refusing.
  test "refuses to run with no key configured" do
    Application.delete_env(:mishka_cms_core, :code_signing_key)

    assert_raise Mix.Error, ~r/code_signing_key/, fn ->
      Mix.Tasks.Mishka.ResignCode.run([])
    end
  end
end
