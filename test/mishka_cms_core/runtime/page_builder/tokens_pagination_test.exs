defmodule MishkaCmsCore.Runtime.PageBuilder.TokensPaginationTest do
  @moduledoc """
  Studio listing every token the site declares, not the first hundred sheets' worth.

  `token_sheets/1` read with `page: [limit: 100]` and sorted by `{kind_order(kind), -priority}`
  AFTERWARDS. The sort is what decides which declaration of a name wins, and it can only decide
  between rows it was handed — so past a hundred stylesheet rows the survivors were whatever order
  the database chose. A site's own theme could be dropped and its tokens simply stopped appearing in
  Studio: a shorter list, no error, nothing on screen to notice.

  A hundred rows is not exotic. Every installed kit ships at least one, every site can add its own,
  and nothing prunes them.

  `async: false` — global stylesheet rows are visible to every site.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.PageBuilder.Tokens
  alias MishkaCmsCore.Runtime.Stylesheet

  # `Token.key` is the name without its leading `--`, which is what the Studio's DOM ids are built
  # from — `pb-token-form-brand`, not `pb-token-form---brand`.
  @count 101

  defp sheet!(name, content) do
    Stylesheet
    |> Ash.Changeset.for_create(
      :master_create,
      %{name: name, kind: :theme, content: content, site_id: nil, active: true},
      authorize?: false
    )
    |> Ash.create!()
  end

  describe "a site with more stylesheet rows than the old cap" do
    test "lists a token from every one of them" do
      run = System.unique_integer([:positive])

      for index <- 1..@count do
        name = "tokpage-#{run}-#{index}"
        sheet!(name, ":root {\n  --#{name}: #0b6f68;\n}\n")
      end

      listed = Tokens.list(nil) |> MapSet.new(& &1.key)
      declared = for index <- 1..@count, do: "tokpage-#{run}-#{index}"

      missing = Enum.reject(declared, &MapSet.member?(listed, &1))

      assert missing == [],
             "the read was capped at 100 sheets, so #{length(missing)} of #{@count} declarations " <>
               "were never seen — and #{@count} sheets is an ordinary install, not an extreme one"
    end

    # The same capped read backs `put/5` through `declaring_sheet/2`, so a token past the cap could
    # not be listed OR written: the Studio would have refused it as a name the site does not declare.
    test "a token declared past the cap can still be written" do
      run = System.unique_integer([:positive])

      for index <- 1..(@count - 1) do
        name = "tokfill-#{run}-#{index}"
        sheet!(name, ":root {\n  --#{name}: #111111;\n}\n")
      end

      key = "tokwrite-#{run}"
      sheet!(key, ":root {\n  --#{key}: #0b6f68;\n}\n")

      master = MishkaCmsCore.Test.Factory.create_user_with_permissions!(["*"])

      assert {:ok, token} = Tokens.put(master, nil, "--" <> key, "#de1135")
      assert token.value == "#de1135"
    end
  end
end
