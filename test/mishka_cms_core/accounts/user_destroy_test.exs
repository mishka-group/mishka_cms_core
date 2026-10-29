# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.UserDestroyTest do
  @moduledoc """
  Deleting an account that has worked in the editor.

  Everything the editor records about a change keeps the account's id: the history sheet's events,
  the versions of a page, a review note and who closed it. They are a record of what happened, so
  they are not the account's to take with it and not a reason to keep it — deleting the account
  leaves each row in place with no author, which the screens read as a deleted user. Before, the
  first of them the database met refused the delete with a raw `Ecto.ConstraintError`.

  `every foreign key to users` is the class guard: it reads the database rather than a list of the
  resources known today, so a table added later that points at an account without saying what
  happens to it fails here, by name.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.User

  @moduletag :unit
  @repo Application.compile_env!(:mishka_cms_core, :repo)

  setup do
    %{master: create_user_with_permissions!(["*"])}
  end

  defp gone?(context, user),
    do: match?({:ok, nil}, Ash.get(User, user.id, actor: context.master, error?: false))

  describe "an account with a history in the editor" do
    test "still refuses to delete yourself, and nothing is deleted", context do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.destroy(context.master, action: :table_destroy, actor: context.master)

      refute gone?(context, context.master)
    end
  end

  describe "every foreign key to users" do
    # `a` NO ACTION and `r` RESTRICT refuse the delete, which is what surfaces as a raw constraint
    # error. A key either goes with the account (`c`, its own grants and codes) or lets go of it
    # (`n`, history and notes). A table that is neither has to refuse on purpose, with a message of
    # its own, and be named here when it does.
    test "lets the account go: it cascades or it is released" do
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          @repo,
          """
          SELECT conrelid::regclass::text, conname, confdeltype::text
          FROM pg_constraint
          WHERE contype = 'f' AND confrelid = 'users'::regclass
          ORDER BY 1, 2
          """
        )

      assert rows != [], "the query found no foreign key to users at all"

      refusing = for [table, name, rule] <- rows, rule not in ["c", "n"], do: "#{table}.#{name}"

      assert refusing == [],
             "deleting an account is refused by #{Enum.join(refusing, ", ")}: " <>
               "give the reference `on_delete: :nilify` (history) or `:delete` (what the account owns)"
    end
  end
end
