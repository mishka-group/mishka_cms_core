# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.Validations.GrantWithinActorScope do
  @moduledoc """
  Refuses a permission grant that would hand out more than the granting actor holds.

  What is handed out is what the account does not hold yet: a permission it already holds, sent
  back as the account form does, is no grant, whoever holds it.

  This is what lets a site run itself. A tenant admin holding `admin:dashboard:permission` and
  `admin:dashboard:blog:*` can make a colleague a blog editor without a master being involved — which
  is the point, because a CMS with many sites and many managers cannot route every routine grant
  through one person. What it cannot do is reach past its own ceiling: it does not hold `*` or
  `admin:dashboard:document:*`, so it cannot grant them.

  The ceiling is the same wildcard rule every gate uses
  (`MishkaCmsCore.Accounts.Checks.AccessPermissions.covers?/2`), so `admin:dashboard:blog:*` covers
  `admin:dashboard:blog:post`, and nothing but `*` covers `*`. A tenant holding `*` — a site owner —
  may grant anything, and that is still contained: the row policy keeps them to their own site's
  users, and `require_master` gates master actions on `site_id`, never on permissions. Their `*` is
  site-wide, not system-wide.

  A MASTER (a user whose `site_id` is nil) has a ceiling too: what it holds. A master holding `*`
  grants anything; one holding only `admin:dashboard:permission` grants nothing it does not hold,
  itself included. A call made with `authorize?: false` (seeds, the installer) is a system call and
  has none. Anything else with no actor is refused: a missing actor is nobody, not a master.

  Declare it with `before_action?: true`, on an update, a create or a generic action taking
  `permission_ids`. The ceiling is then asked right before the write, of the actor the action RUNS
  with — the actor the policies ask — and not of the one the changeset was built with. A grant built
  by a master, by a system call or with no actor, and run by a site's admin, is held to that admin's
  ceiling.

      update :assign_permissions do
        validate {MishkaCmsCore.Accounts.Validations.GrantWithinActorScope, []},
          before_action?: true
      end

  Escalation is closed from both directions only in combination with the policy that forbids editing
  your own permissions — otherwise two colleagues could raise each other. See
  `MishkaCmsCore.Accounts.User`'s `assign_permissions` policy.
  """
  use Gettext, backend: MishkaCmsCore.Gettext
  use Ash.Resource.Validation

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Accounts.Helper

  @impl true
  def supports(_opts), do: [Ash.Changeset, Ash.ActionInput]

  # A system call is answered before any query: this validation runs on every grant, including the
  # hundreds a seed run makes, and it must cost nothing when it cannot refuse anything.
  @impl true
  def validate(_changeset, _opts, %{authorize?: false}), do: :ok

  def validate(_changeset, _opts, %{actor: nil}),
    do:
      {:error,
       field: :permission_ids,
       message: dgettext_noop("errors", "only a signed-in user can grant permissions")}

  def validate(changeset, _opts, context) do
    changeset
    |> requested_names(context)
    |> beyond(context)
    |> case do
      [] ->
        :ok

      over ->
        {:error,
         field: :permission_ids,
         message:
           dgettext_noop("errors", "cannot grant permissions you do not hold yourself: %{over}"),
         over: Enum.join(over, ", ")}
    end
  end

  defp beyond(requested, %{actor: actor}), do: AccessPermissions.beyond(actor, requested)

  defp requested_names(subject, _context) do
    held = subject |> account_id() |> Helper.permission_ids()

    subject
    |> ids()
    |> Enum.reject(&MapSet.member?(held, &1))
    |> Helper.names_of()
  end

  # `assign_permissions` takes a list; `add_permission`/`remove_permission` take one.
  defp ids(subject) do
    [:permission_ids, :permission_id]
    |> Enum.flat_map(&(subject |> argument(&1) |> List.wrap()))
    |> Enum.filter(&is_binary/1)
  end

  defp argument(%Ash.ActionInput{} = input, name), do: Ash.ActionInput.get_argument(input, name)
  defp argument(changeset, name), do: Ash.Changeset.get_argument(changeset, name)

  # The account a grant is for: the record an update writes, or the `:id` a generic action names. A
  # create's account holds nothing yet.
  defp account_id(%Ash.Changeset{action_type: :update, data: %{id: id}}), do: id
  defp account_id(%Ash.ActionInput{} = input), do: Ash.ActionInput.get_argument(input, :id)
  defp account_id(_create), do: nil
end
