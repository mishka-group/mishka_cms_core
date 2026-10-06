defmodule MishkaCmsCore.Accounts.WhoLabelTest do
  @moduledoc """
  What a screen calls whoever did something: the email the reader may read, "Master" for a master
  it may not, and the screen's own word for a record with no account.
  """
  use MishkaCmsCore.DataCase

  alias MishkaCmsCore.Accounts.Helper

  describe "who/4" do
    test "a loaded account's email, when it is an Ash.CiString" do
      user = %{email: Ash.CiString.new("Ada@Example.com")}

      assert Helper.who(user, false, "System") == "Ada@Example.com"
      assert Helper.who(user, true, "System") == "Ada@Example.com"
    end

    test "a loaded account's email, when it is a binary" do
      assert Helper.who(%{email: "ada@example.com"}, false, "Guest") == "ada@example.com"
    end

    test "a real account's email, as a read returns it" do
      user = create_user!(site_id: create_site!().id)

      assert Helper.who(user, false, "System") == to_string(user.email)
    end

    test "a forbidden email reads Master for a master and the no-account word otherwise" do
      forbidden = %{email: %Ash.ForbiddenField{field: :email, type: :attribute}}

      assert Helper.who(forbidden, true, "Unknown") == "Master"
      assert Helper.who(forbidden, false, "Unknown") == "Unknown"

      assert Helper.who(%Ash.ForbiddenField{field: :author, type: :relationship}, true, "x") ==
               "Master"
    end

    test "no account loaded, with a master's id, reads Master" do
      assert Helper.who(nil, true, "Unknown") == "Master"
      assert Helper.who(%Ash.NotLoaded{}, true, "Unknown") == "Master"
    end

    test "no account loaded, without a master's id, reads the no-account word" do
      assert Helper.who(nil, false, "Unknown") == "Unknown"
      assert Helper.who(nil, false, "Guest") == "Guest"
      assert Helper.who(nil, false, "System") == "System"
    end

    test "a master's own name replaces Master, and only for a master" do
      assert Helper.who(nil, true, "Guest", "Platform Team") == "Platform Team"
      assert Helper.who(nil, true, "Guest", nil) == "Master"
      assert Helper.who(nil, true, "Guest", "") == "Master"
      assert Helper.who(nil, false, "Guest", "Platform Team") == "Guest"

      assert Helper.who(%{email: "ada@example.com"}, true, "Guest", "Platform Team") ==
               "ada@example.com"
    end
  end

  describe "visible_to/2" do
    test "a master reads everyone, a site user its own site, nobody else anything" do
      site = "11111111-1111-1111-1111-111111111111"
      other = "22222222-2222-2222-2222-222222222222"
      colleague = %{site_id: site, email: "c@example.com"}
      master = %{site_id: nil, email: "m@example.com"}

      assert Helper.visible_to(colleague, %{site_id: nil}) == colleague
      assert Helper.visible_to(master, %{site_id: nil}) == master
      assert Helper.visible_to(colleague, %{site_id: site}) == colleague
      assert Helper.visible_to(master, %{site_id: site}) == nil
      assert Helper.visible_to(colleague, %{site_id: other}) == nil
      assert Helper.visible_to(colleague, nil) == nil
      assert Helper.visible_to(nil, %{site_id: site}) == nil
    end
  end

  describe "master_ids/1" do
    test "finds the masters among ids in one read, whatever else is in the list" do
      site = create_site!()
      master = create_user!()
      colleague = create_user!(site_id: site.id)

      assert {:ok, masters} = Helper.master_ids([master.id, colleague.id, nil, master.id])
      assert MapSet.to_list(masters) == [master.id]
    end

    test "no id at all reads nothing" do
      assert Helper.master_ids([]) == {:ok, MapSet.new()}
      assert Helper.master_ids([nil, nil]) == {:ok, MapSet.new()}
    end

    test "an id nobody holds is no master" do
      assert Helper.master_ids([Ash.UUID.generate()]) == {:ok, MapSet.new()}
    end
  end

  describe "who/4 with the word for no account" do
    test "names it by :guest, :system or :unknown" do
      assert Helper.who(nil, false, :guest) == "Guest"
      assert Helper.who(nil, false, :system) == "System"

      assert Helper.who(%Ash.ForbiddenField{field: :user, type: :relationship}, false, :unknown) ==
               "Unknown"

      assert Helper.who(nil, true, :unknown) == "Master"
    end
  end

  describe "in the reader's language" do
    setup do
      Gettext.put_locale(MishkaCmsCore.Gettext, "fa")
      :ok
    end

    test "a master and a record with no account read in the reader's language" do
      assert Helper.who(nil, true, :unknown) == "[fa] Master"
      assert Helper.who(nil, false, :guest) == "[fa] Guest"
      assert Helper.who(nil, false, :system) == "[fa] System"
      assert Helper.who(%Ash.NotLoaded{}, false, :unknown) == "[fa] Unknown"
    end

    test "an email still reads as the email" do
      assert Helper.who(%{email: "ada@example.com"}, true, :unknown) == "ada@example.com"
    end
  end
end
