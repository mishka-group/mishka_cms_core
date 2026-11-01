# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.StylesheetCompilesTest do
  @moduledoc """
  A stylesheet whose CSS Tailwind will not build is refused on its `content` field, by every write
  that changes it (`Changes.StylesheetCompiles`). Stored, one such row failed the whole build of
  the site's CSS, after a save that said it was updated.

  `async: false`: it runs the Tailwind binary.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler
  alias MishkaCmsCore.Runtime.Stylesheet

  @moduletag :integration

  @unclosed ".a{color:red;}\n.b { color: red;"

  setup do
    TailwindCompiler.ensure_installed()
    %{site: create_site!()}
  end

  defp create(site, action, content) do
    attrs = %{name: "sc-#{System.unique_integer([:positive])}", content: content}

    {attrs, tenant} =
      case action do
        :create -> {attrs, site.id}
        :master_create -> {Map.put(attrs, :site_id, site.id), nil}
      end

    Stylesheet
    |> Ash.Changeset.for_create(action, attrs, tenant: tenant, authorize?: false)
    |> Ash.create(authorize?: false)
  end

  defp edit(row, action, content) do
    tenant = if action == :update, do: row.site_id

    row
    |> Ash.Changeset.for_update(action, %{content: content}, tenant: tenant, authorize?: false)
    |> Ash.update(authorize?: false)
  end

  defp changing(row, attrs, context \\ %{}) do
    Ash.Changeset.for_update(row, :update, attrs,
      tenant: row.site_id,
      authorize?: false,
      context: context
    )
  end

  defp stored(row), do: Ash.get!(Stylesheet, row.id, action: :get_any, authorize?: false)

  for action <- [:create, :master_create] do
    test "#{action} refuses CSS Tailwind will not build, in its words", %{site: site} do
      for {content, message} <- [
            {@unclosed, "Missing closing } at .b"},
            {".a { @apply rounde-xl; }", "Cannot apply unknown utility class `rounde-xl`"}
          ] do
        assert {:error, %Ash.Error.Invalid{errors: [error]}} =
                 create(site, unquote(action), content)

        assert %{field: :content, message: ^message} = error
      end

      assert {:ok, _row} = create(site, unquote(action), ".a { @apply p-4; }\n.b { color: red; }")
    end
  end

  for action <- [:update, :master_update] do
    test "#{action} refuses it and the row keeps what it had", %{site: site} do
      {:ok, row} = create(site, :create, ".a { color: red; }")

      assert {:error, %Ash.Error.Invalid{errors: [error]}} =
               edit(row, unquote(action), @unclosed)

      assert %{field: :content, message: "Missing closing } at .b"} = error
      assert stored(row).content == ".a { color: red; }"
    end
  end

  # TAILWIND TAKES ABOUT 1.5 S, and run as a validation inside the write's transaction it held a
  # database connection that long on every save. A form's validate builds the changeset and runs no
  # Tailwind; the refusal comes from the hooks Ash runs before it opens the transaction.
  test "the check runs before the write's transaction opens, not when the changeset is built", %{
    site: site
  } do
    {:ok, row} = create(site, :create, ".a { color: red; }")

    changeset = changing(row, %{content: @unclosed})
    assert changeset.valid?

    checked = Ash.Changeset.run_before_transaction_hooks(changeset)
    refute checked.valid?
    assert [%{field: :content, message: "Missing closing } at .b"}] = checked.errors
  end

  # A row stored before the check, or seeded past it, still takes an edit to its other fields, and the
  # builder checks its own rows before it writes them.
  test "a write that leaves the CSS as it is, and the builder's own write, are not built", %{
    site: site
  } do
    row =
      Ash.Seed.seed!(Stylesheet, %{
        name: "sc-seeded-#{System.unique_integer([:positive])}",
        content: @unclosed,
        site_id: site.id
      })

    assert {:ok, %{description: "kept"}} =
             row |> changing(%{description: "kept"}) |> Ash.update(authorize?: false)

    assert {:ok, %{content: ".b { color: red;"}} =
             row
             |> changing(%{content: ".b { color: red;"}, %{page_code: :builder})
             |> Ash.update(authorize?: false)
  end
end
