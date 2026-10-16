# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.MentionsTest do
  @moduledoc """
  Naming somebody in a note: what counts as a name, who may be named, and who hears about it.

  `async: false` — masters have no site, so the candidate lists cross site boundaries by design.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Notify.Notification
  alias MishkaCmsCore.Runtime.PageBuilder.Mentions
  alias MishkaCmsCore.Runtime.PageComment

  setup do
    site = create_site!()
    %{site: site, page: create_page!(site_id: site.id), other_site: create_site!()}
  end

  # THE AUTHOR IS WHOEVER WRITES IT. The tenant `:create` takes `author_id` from the actor and
  # accepts none from input, so a note by somebody is written AS them.
  defp note!(site, attrs) do
    {author, attrs} = Map.pop(attrs, :author)

    PageComment
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{body: "a note", type: :information, section: :page}, attrs),
      tenant: site.id,
      actor: author,
      authorize?: false
    )
    |> Ash.create!()
  end

  defp feed(user) do
    Notification
    |> Ash.Query.for_read(:feed)
    |> Ash.read!(actor: user, tenant: user.site_id, page: false)
  end

  describe "reading a body" do
    test "an @address is a name and the rest is text" do
      assert Mentions.segments("ping @sara@example.com now") == [
               {:text, "ping "},
               {:mention, "sara@example.com"},
               {:text, " now"}
             ]
    end

    # A LOCAL PART IS STILL UNDERSTOOD. The picker writes the whole address, but notes written before
    # it did — and anyone typing by hand — say less than that and still mean somebody.
    test "a bare local part is still a name" do
      assert Mentions.segments("ping @sara now") == [
               {:text, "ping "},
               {:mention, "sara"},
               {:text, " now"}
             ]
    end

    test "punctuation after a name is not part of it" do
      assert Mentions.segments("@sara@example.com, look") == [
               {:mention, "sara@example.com"},
               {:text, ", look"}
             ]
    end

    # THE CASE THAT MADE IT SPLIT ON WHITESPACE. Scanning for `@` finds one in every address, so a
    # note that QUOTES one would highlight the domain and name nobody by it.
    test "a quoted address is not a name" do
      assert Mentions.segments("write to sara@example.com") == [
               {:text, "write to sara@example.com"}
             ]
    end

    test "a lone @ is text" do
      assert Mentions.segments("costs @ 5") == [{:text, "costs @ 5"}]
    end

    test "nothing in, nothing out" do
      assert Mentions.segments(nil) == []
      assert Mentions.segments("") == []
    end

    test "the handles are downcased and counted once" do
      assert Mentions.handles("@Sara@X.test and @sara@x.test and @ali@x.test") ==
               ["sara@x.test", "ali@x.test"]
    end
  end

  describe "who can be named" do
    # A MASTER IS A USER WHOSE `site_id` IS NIL — never a note with no author. With nobody asking, a
    # page's note offers that site's people and stops there.
    test "a note on a page with no author offers that site's people alone", %{
      site: site,
      other_site: other
    } do
      mine = create_user!(site_id: site.id, email: "sara@mine.test")
      master = create_user!(email: "boss@master.test")
      create_user!(site_id: other.id, email: "nobody@other.test")

      handles = %{site_id: site.id} |> Mentions.candidates("") |> Enum.map(& &1.handle)

      assert "sara@mine.test" in handles
      refute "boss@master.test" in handles, "no author is not a master"

      refute "nobody@other.test" in handles,
             "another tenant's user list is not this site's to offer"

      assert Enum.all?([mine.id, master.id], &is_binary/1)
    end

    test "a master's note on something shared offers only the masters", %{site: site} do
      create_user!(site_id: site.id, email: "sara@mine.test")
      master = create_user!(email: "boss@master.test")

      handles =
        %{site_id: nil, actor: master} |> Mentions.candidates("") |> Enum.map(& &1.handle)

      assert "boss@master.test" in handles
      refute "sara@mine.test" in handles
    end

    test "a note on something shared with no author offers nobody", %{site: site} do
      create_user!(site_id: site.id, email: "sara@mine.test")
      create_user!(email: "boss@master.test")

      assert Mentions.candidates(%{site_id: nil}, "") == []
      assert Mentions.candidates(%{site_id: nil, actor: %{}}, "") == []
    end

    test "typing narrows the list", %{site: site} do
      create_user!(site_id: site.id, email: "sara@mine.test")
      create_user!(site_id: site.id, email: "sam@mine.test")
      create_user!(site_id: site.id, email: "ali@mine.test")

      assert %{site_id: site.id} |> Mentions.candidates("sa") |> Enum.map(& &1.handle) == [
               "sam@mine.test",
               "sara@mine.test"
             ]
    end

    # THE WHOLE REASON THE HANDLE IS AN ADDRESS. Two people called `master` are two people, and the
    # only thing that tells them apart is where they are.
    test "the domain tells two people with one name apart", %{site: site} do
      create_user!(site_id: site.id, email: "master@one.test")
      create_user!(site_id: site.id, email: "master@two.test")

      assert %{site_id: site.id} |> Mentions.candidates("master") |> Enum.map(& &1.handle) == [
               "master@one.test",
               "master@two.test"
             ]

      assert %{site_id: site.id} |> Mentions.candidates("master@two") |> Enum.map(& &1.handle) ==
               [
                 "master@two.test"
               ]
    end

    # The picker draws the address in two weights, so it is handed both halves rather than made to
    # split a string it did not build.
    test "a candidate carries the address in the halves the picker draws", %{site: site} do
      create_user!(site_id: site.id, email: "sara@mine.test")

      assert [%{handle: "sara@mine.test", local: "sara", domain: "@mine.test"}] =
               Mentions.candidates(%{site_id: site.id}, "sara")
    end

    # A TENANT'S REACH STOPS AT THEIR OWN SITE. The masters are the platform's people, not the
    # customer's, and their addresses are not a tenant's to have — the same line the activity feed
    # draws when it shows a tenant "System" instead of who really made a change.
    test "a tenant is not offered the masters", %{site: site} do
      tenant = create_user!(site_id: site.id, email: "sara@mine.test")
      create_user!(email: "boss@master.test")

      handles =
        %{site_id: site.id, actor: tenant} |> Mentions.candidates("") |> Enum.map(& &1.handle)

      assert "sara@mine.test" in handles
      refute "boss@master.test" in handles, "a master's address is not a tenant's to see"
    end

    test "a master is offered the site's people and the other masters", %{site: site} do
      master = create_user!(email: "boss@master.test")
      create_user!(site_id: site.id, email: "sara@mine.test")

      handles =
        %{site_id: site.id, actor: master} |> Mentions.candidates("") |> Enum.map(& &1.handle)

      assert "sara@mine.test" in handles
      assert "boss@master.test" in handles
    end

    # Their own site whatever the document is: a tenant writing on a shared component still writes
    # to their own people, because the note is stamped with their site.
    test "a tenant on a shared document still reaches their own site", %{site: site} do
      tenant = create_user!(site_id: site.id, email: "sara@mine.test")
      create_user!(email: "boss@master.test")

      handles = %{site_id: nil, actor: tenant} |> Mentions.candidates("") |> Enum.map(& &1.handle)

      assert handles == ["sara@mine.test"]
    end

    # A PREFIX OF THE ADDRESS, not a substring of it. Typing a domain on its own finds nobody, because
    # nobody's address STARTS with it — the way to narrow by domain is to name somebody and keep
    # typing, which is what the test above does.
    test "a domain on its own is nobody's prefix", %{site: site} do
      create_user!(site_id: site.id, email: "sara@acme.test")

      assert Mentions.candidates(%{site_id: site.id}, "acme") == []
    end
  end

  describe "being named" do
    test "the person named is told, with a link back to the note", %{site: site, page: page} do
      named = create_user!(site_id: site.id, email: "sara@mine.test")
      author = create_user!(site_id: site.id, email: "ali@mine.test")
      before = named |> feed() |> length()

      note!(site, %{
        document_id: page.id,
        body: "@sara@mine.test can you check this?",
        author: author
      })

      assert [newest | _rest] = feed(named)
      assert length(feed(named)) == before + 1
      assert newest.type == "cms_core:page_comment:mentioned"
      assert newest.link == "/admin/dashboard/runtime/builder/page/#{page.id}"
      assert newest.body =~ "can you check this?"
    end

    test "naming yourself tells you nothing", %{site: site, page: page} do
      author = create_user!(site_id: site.id, email: "ali@mine.test")
      before = author |> feed() |> length()

      note!(site, %{
        document_id: page.id,
        body: "@ali@mine.test reminder to self",
        author: author
      })

      assert length(feed(author)) == before
    end

    test "a note that names nobody notifies nobody", %{site: site, page: page} do
      watcher = create_user!(site_id: site.id, email: "sara@mine.test")
      before = watcher |> feed() |> length()

      note!(site, %{document_id: page.id, body: "no names here"})

      assert length(feed(watcher)) == before
    end

    # NAMING SOMEBODY BY ADDRESS NAMES ONE PERSON. Two accounts answering to one local part is the
    # case the address exists for, so only the one written to is told.
    test "an address names the account it is, not the other like it", %{site: site, page: page} do
      one = create_user!(site_id: site.id, email: "master@one.test")
      two = create_user!(site_id: site.id, email: "master@two.test")
      before_one = one |> feed() |> length()
      before_two = two |> feed() |> length()

      note!(site, %{document_id: page.id, body: "@master@two.test only you"})

      assert length(feed(one)) == before_one
      assert length(feed(two)) == before_two + 1
    end

    # …and a bare local part still reaches everybody who answers to it, because a note that says only
    # that has not said which one it meant.
    test "a bare local part still reaches everybody who answers to it", %{site: site, page: page} do
      one = create_user!(site_id: site.id, email: "master@one.test")
      two = create_user!(site_id: site.id, email: "master@two.test")
      before_one = one |> feed() |> length()
      before_two = two |> feed() |> length()

      note!(site, %{document_id: page.id, body: "@master which of you"})

      assert length(feed(one)) == before_one + 1
      assert length(feed(two)) == before_two + 1
    end

    # WHAT THE PICKER WOULD NOT OFFER, THE NOTE CANNOT REACH. A tenant who types a master's address
    # by hand has still named somebody they were never shown.
    test "a tenant naming a master reaches nobody", %{site: site, page: page} do
      tenant = create_user!(site_id: site.id, email: "sara@mine.test")
      master = create_user!(email: "boss@master.test")
      before = master |> feed() |> length()

      note!(site, %{document_id: page.id, body: "@boss@master.test look", author: tenant})

      assert length(feed(master)) == before
    end

    test "a master naming a master reaches them", %{site: site, page: page} do
      writer = create_user!(email: "writer@master.test")
      master = create_user!(email: "boss@master.test")
      before = master |> feed() |> length()

      note!(site, %{document_id: page.id, body: "@boss@master.test look", author: writer})

      assert length(feed(master)) == before + 1
    end

    # AN AUTHOR NOBODY CAN FIND IS NOT A MASTER. A note with no author, or with the id of an account
    # that is gone, reaches its own site's people and never the masters.
    test "a note with no author, or an author nobody can find, reaches no master", %{
      site: site,
      page: page
    } do
      master = create_user!(email: "boss@master.test")
      sara = create_user!(site_id: site.id, email: "sara@mine.test")
      before = master |> feed() |> length()
      before_sara = sara |> feed() |> length()

      note!(site, %{document_id: page.id, body: "@boss@master.test @sara@mine.test look"})

      Mentions.notify(%{
        id: Ecto.UUID.generate(),
        body: "@boss@master.test look",
        site_id: site.id,
        section: :page,
        document_id: page.id,
        author_id: Ecto.UUID.generate()
      })

      assert length(feed(master)) == before
      assert length(feed(sara)) == before_sara + 1
    end

    test "a handle that matches nobody is a typo, not an audience", %{site: site, page: page} do
      watcher = create_user!(site_id: site.id, email: "sara@mine.test")
      before = watcher |> feed() |> length()

      note!(site, %{document_id: page.id, body: "@saraa@mine.test look"})

      assert length(feed(watcher)) == before
    end

    test "a site user named beside a master reads the master as @Master", %{
      site: site,
      page: page
    } do
      writer = create_user!(email: "writer@master.test")
      master = create_user!(email: "boss@master.test")
      sara = create_user!(site_id: site.id, email: "sara@mine.test")

      note!(site, %{
        document_id: page.id,
        body: "@boss@master.test and @sara@mine.test, look",
        author: writer
      })

      assert [told_sara | _] = feed(sara)
      assert told_sara.body == "@Master and @sara@mine.test, look"
      refute told_sara.body =~ "boss"

      assert [told_boss | _] = feed(master)
      assert told_boss.body == "@boss@master.test and @sara@mine.test, look"
    end

    # The audience follows the note's own site, which is where the tenancy rule already put it.
    test "a tenant's note cannot name another site's people", %{
      site: site,
      page: page,
      other_site: other
    } do
      stranger = create_user!(site_id: other.id, email: "sara@other.test")
      before = stranger |> feed() |> length()

      note!(site, %{document_id: page.id, body: "@sara@other.test look at this"})

      assert length(feed(stranger)) == before
    end
  end

  describe "a master's handle, for a site user" do
    test "an address a master holds is a master's", %{site: site} do
      create_user!(email: "boss@master.test")
      create_user!(site_id: site.id, email: "sara@mine.test")

      assert Mentions.master_handles(["@Boss@master.test and @sara@mine.test"], site.id) ==
               MapSet.new(["boss@master.test"])
    end

    test "a local part is a master's only when nobody on the site answers to it", %{
      site: site,
      other_site: other
    } do
      create_user!(email: "boss@master.test")
      create_user!(email: "chief@master.test")
      create_user!(site_id: site.id, email: "boss@mine.test")
      create_user!(site_id: other.id, email: "chief@other.test")

      assert Mentions.master_handles(["@boss @chief"], site.id) == MapSet.new(["chief"])
    end

    test "a handle nobody holds, or no site at all, names no master", %{site: site} do
      create_user!(email: "boss@master.test")

      assert Mentions.master_handles(["@nobody@nowhere.test"], site.id) == MapSet.new()
      assert Mentions.master_handles(["@boss@master.test"], nil) == MapSet.new()
      assert Mentions.master_handles([nil, "no names"], site.id) == MapSet.new()
    end

    test "a master reads every handle; a site user has a master's masked", %{site: site} do
      create_user!(email: "boss@master.test")
      notes = [%{body: "@boss@master.test hi"}, %{body: "plain"}]

      assert Mentions.master_mentions(notes, %{site_id: site.id}) == [["boss@master.test"], []]
      assert Mentions.master_mentions(notes, %{site_id: nil}) == [[], []]
    end

    test "masking keeps everything but the master's handle as written" do
      masked = MapSet.new(["boss@master.test"])

      assert Mentions.mask_masters("@Boss@master.test, @sara ok", masked) == "@Master, @sara ok"
      assert Mentions.mask_masters(nil, masked) == nil
    end
  end
end
