# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.CodeSignatureStorageTest do
  @moduledoc """
  A signature `Changes.SignCode` adds on the way in is still there when the row is read back.

  An attribute whose items declare `fields` keeps only the listed keys, so a code field that does not
  list `signature` drops it before the write, and with a key configured every snippet in it compiles
  to a clause that does nothing. Each resource and field in `CodeAudit.sources/0` is written through
  its real actions here, so a constraint that loses the key fails this suite.
  """
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Runtime.Authoring.CodeAudit
  alias MishkaCmsCore.Runtime.Authoring.CodeSignature
  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.ErrorPage
  alias MishkaCmsCore.Runtime.Layout
  alias MishkaCmsCore.Runtime.Page

  require Ash.Query

  @moduletag :integration
  @moduletag :capture_log

  @key "a-test-signing-key-that-is-long-enough"
  @package %{page_code: :package}

  @entries %{
    events: [%{"name" => "save", "code" => "{:noreply, socket}"}],
    infos: [%{"name" => ":tick", "code" => "{:noreply, socket}"}],
    state: [%{"name" => "count", "code" => "0"}],
    helpers: [%{"name" => "shout", "args" => "word", "code" => "String.upcase(word)"}]
  }

  setup do
    on_exit(fn -> Application.delete_env(:mishka_cms_core, :code_signing_key) end)
    {:ok, site: create_site!()}
  end

  defp signing_on, do: Application.put_env(:mishka_cms_core, :code_signing_key, @key)

  defp reread(%resource{id: id}) do
    resource
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(authorize?: false)
  end

  defp assert_signed(row, fields) do
    for field <- fields do
      snippets = Map.fetch!(row, field)

      assert snippets != [], "#{inspect(row.__struct__)}.#{field} was stored empty"

      assert Enum.all?(snippets, &CodeSignature.trusted?/1),
             "#{inspect(row.__struct__)}.#{field} lost its signature on the way in: " <>
               inspect(snippets)
    end
  end

  defp code_for(fields), do: Map.new(fields, &{&1, Map.fetch!(@entries, &1)})

  defp create_unsigned!(Page, site), do: create_page!(site_id: site.id)
  defp create_unsigned!(Layout, site), do: create_layout!(site_id: site.id)
  defp create_unsigned!(Component, site), do: create_component!(site_id: site.id)
  defp create_unsigned!(ErrorPage, site), do: create_error_page!(site_id: site.id)

  describe "a page's events, infos and state" do
    test "keep their signatures through :create", %{site: site} do
      signing_on()

      page =
        Page
        |> Ash.Changeset.for_create(
          :create,
          Map.merge(code_for([:events, :infos, :state]), %{
            name: "signed",
            title: "Signed",
            path: "/signed",
            section: "default",
            template: "<div>signed</div>",
            format: :heex
          }),
          tenant: site.id,
          authorize?: false,
          context: @package
        )
        |> Ash.create!()

      assert_signed(reread(page), [:events, :infos, :state])
    end

    test "keep their signatures through :update", %{site: site} do
      page = create_page!(site_id: site.id)
      signing_on()

      page
      |> Ash.Changeset.for_update(:update, code_for([:events, :infos, :state]),
        tenant: site.id,
        authorize?: false,
        context: @package
      )
      |> Ash.update!()

      assert_signed(reread(page), [:events, :infos, :state])
    end
  end

  test "every resource and field the audit reads keeps its signature through :update",
       %{site: site} do
    for {resource, fields} <- CodeAudit.sources() do
      Application.delete_env(:mishka_cms_core, :code_signing_key)
      row = create_unsigned!(resource, site)
      signing_on()

      row
      |> Ash.Changeset.for_update(:update, code_for(fields),
        tenant: site.id,
        authorize?: false,
        context: @package
      )
      |> Ash.update!()

      assert_signed(reread(row), fields)
    end
  end

  describe "CodeAudit.resign/0" do
    test "signs what was stored unsigned, so the audit reaches zero", %{site: site} do
      page =
        create_page!(site_id: site.id)
        |> Ash.Changeset.for_update(:update, code_for([:events, :infos, :state, :helpers]),
          tenant: site.id,
          authorize?: false,
          context: @package
        )
        |> Ash.update!()

      signing_on()
      assert CodeAudit.untrusted() >= 4

      assert {:ok, count} = CodeAudit.resign()
      assert count >= 1

      assert CodeAudit.untrusted() == 0
      assert_signed(reread(page), [:events, :infos, :state, :helpers])
    end

    test "refuses with no key configured" do
      Application.delete_env(:mishka_cms_core, :code_signing_key)

      assert CodeAudit.resign() == {:error, :signing_off}
    end
  end
end
