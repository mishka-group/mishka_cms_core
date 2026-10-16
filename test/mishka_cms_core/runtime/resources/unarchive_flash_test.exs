# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.UnarchiveFlashTest do
  @moduledoc """
  The unarchive success hooks registered on each runtime resource's table tell the
  user the record was restored INACTIVE. These drive the real hook the table event
  handler runs (`apply_action_hook_socket`), reading the hook from the resource's
  compiled DSL config — so removing the hook (or its message) fails the test.

  `State.init/3` reads the database (a table's relationship filters load their options), so each
  test owns a sandboxed connection instead of reaching whichever one the previous test shared.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaGervaz.Table.Web.{Events, State}

  @resources [
    {MishkaCmsCore.Runtime.Component, "Component"},
    {MishkaCmsCore.Runtime.Page, "Page"},
    {MishkaCmsCore.Runtime.Layout, "Layout"},
    {MishkaCmsCore.Runtime.ErrorPage, "ErrorPage"},
    {MishkaCmsCore.Runtime.Stylesheet, "Stylesheet"},
    {MishkaCmsCore.Runtime.JsHook, "JsHook"}
  ]

  defp master_user, do: %{id: "flash-master", site_id: nil, role: :admin}

  defp socket do
    %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
  end

  defp state_for(resource), do: State.init("unarchive-flash", resource, master_user())

  describe "row unarchive success flash — every runtime resource" do
    for {resource, label} <- @resources do
      test "#{label} sets an info flash that says the record is restored inactive" do
        state = state_for(unquote(resource))

        # The hook must actually be registered on the table DSL.
        assert is_function(state.static.hooks[{:on_row_action_success, :unarchive}]),
               "#{unquote(label)} is missing an on_row_action_success :unarchive hook"

        result =
          Events.apply_action_hook_socket(
            state,
            :on_row_action_success,
            :unarchive,
            [%{id: "rec-1"}, state],
            socket()
          )

        assert result.assigns.flash["info"] =~ "inactive"
        assert result.assigns.flash["info"] =~ "activate"
      end
    end
  end

  describe "bulk unarchive success flash — every runtime resource" do
    for {resource, label} <- @resources do
      test "#{label} flashes the restored-inactive count" do
        state = state_for(unquote(resource))

        assert is_function(state.static.hooks[{:on_bulk_action_success, :unarchive}]),
               "#{unquote(label)} is missing an on_bulk_action_success :unarchive hook"

        summary = %{succeeded_count: 2, skipped_count: 0, failed_count: 0}

        Events.apply_action_hook_socket(
          state,
          :on_bulk_action_success,
          :unarchive,
          [summary, state],
          socket()
        )

        # The bulk hook defers the flash via a message to the LiveView process.
        assert_received {:put_flash, :info, msg}
        assert msg =~ "2"
        assert msg =~ "inactive"
      end
    end
  end
end
