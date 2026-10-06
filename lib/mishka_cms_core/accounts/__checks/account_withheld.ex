defmodule MishkaCmsCore.Accounts.Checks.AccountWithheld do
  @moduledoc """
  True while what an account holds — its site, its permissions — is reached from that account by a
  caller who may not see it. Two ways reach it:

    * a load, when the account itself was reached through another resource — a comment's author, a
      post's blogger — by someone who is not an admin. `MishkaCmsCore.Accounts.User` marks such a
      read with `mark/1`; the mark is shared context, so Ash carries it into that account's own
      loads.
    * a filter, a sort or an aggregate through the account — `?filter[author][permissions][name]=`
      — which Ash authorizes hop by hop without loading anything, so no mark is there. Only an admin
      matches against what an account holds; everyone else asks nothing of it.

  An admin here is a holder of the user area on the request's surface (`admin:<surface>:user`), the
  same who read an account's own fields. The resources an account holds refuse under it with a filter
  policy of their own, so a load answers with nothing and a filter matches nothing, rather than
  failing the request:

      policies do
        policy MishkaCmsCore.Accounts.Checks.AccountWithheld do
          forbid_if always()
        end

        # ...
      end
  """
  use Ash.Policy.SimpleCheck

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions

  @key :mishka_account_withheld

  @doc "Marks a User read so that the account's own relationships are refused under it."
  @spec mark(Ash.Query.t()) :: Ash.Query.t()
  def mark(%Ash.Query{} = query), do: Ash.Query.set_context(query, %{shared: %{@key => true}})

  @impl Ash.Policy.Check
  def describe(_opts),
    do: "Reaching what an account holds, for a caller who may not see the account"

  @impl Ash.Policy.SimpleCheck
  def match?(actor, %{subject: %{context: context}}, _opts) do
    from_account?(context) and (marked?(context) or not loading?(context)) and
      not AccessPermissions.match?(actor, context,
        permissions: ["admin:dashboard:user", "admin:api:user"]
      )
  end

  def match?(_actor, _context, _opts), do: false

  defp from_account?(%{accessing_from: %{source: MishkaCmsCore.Accounts.User}}), do: true
  defp from_account?(_context), do: false

  defp marked?(%{shared: %{@key => true}}), do: true
  defp marked?(_context), do: false

  # Ash sets this on the read that loads a relationship; a filter, sort or aggregate path never
  # carries it.
  defp loading?(%{private: %{loading_relationships?: true}}), do: true
  defp loading?(_context), do: false
end
