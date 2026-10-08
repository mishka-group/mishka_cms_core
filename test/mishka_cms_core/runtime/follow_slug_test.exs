defmodule MishkaCmsCore.Runtime.FollowSlugTest do
  @moduledoc """
  `MishkaCmsCore.Runtime.Helpers.follow_slug/4`, the `on_validate` step that fills a record's slug
  from its title while the record is created.

  Driven the way a Gervaz form drives it: each change hands the hook the form's params, and the form
  is then validated with what the hook returned, so the next change reads the title the form held.
  Core's page form is the one used — its `:master_create` action slugifies `name`, which a page is
  given from its title. The forms of the blog and the documents that call it are tested in their
  own repositories, a save included.
  """
  use MishkaCmsCore.DataCase

  alias MishkaCmsCore.Runtime.{Helpers, Page}

  setup do
    {:ok, master: create_user_with_permissions!(["*"])}
  end

  defp creating(ctx),
    do: state(:create, AshPhoenix.Form.for_create(Page, :master_create, actor: ctx.master))

  defp state(mode, form), do: %{mode: mode, form: Phoenix.Component.to_form(form)}

  # One `phx-change`: the browser sends every field the form shows, the hook runs, and the form is
  # validated with the params it returned. Answers the name the form shows after it.
  defp change(state, title, name, into \\ :name) do
    params =
      Helpers.follow_slug(%{"form" => %{"title" => title, "name" => name}}, state, :title, into)

    form =
      state.form.source
      |> AshPhoenix.Form.validate(params["form"])
      |> Phoenix.Component.to_form()

    {params["form"]["name"], %{state | form: form}}
  end

  describe "while a record is created" do
    test "the slug follows each change of the title", ctx do
      {name, state} = change(creating(ctx), "Hello World", "")
      assert name == "hello-world"

      {name, _state} = change(state, "Hello World, Again", name)
      assert name == "hello-world-again"
    end

    test "a slug the author typed stops it following, and emptying it starts it again", ctx do
      {_name, state} = change(creating(ctx), "Hello World", "")
      {name, state} = change(state, "Hello World", "my-page")
      assert name == "my-page"

      {name, state} = change(state, "Renamed", name)
      assert name == "my-page"

      {name, state} = change(state, "Renamed", "")
      assert name == ""

      {name, _state} = change(state, "Renamed Again", name)
      assert name == "renamed-again"
    end

    test "a slug typed before any title is kept", ctx do
      assert {"own-name", _state} = change(creating(ctx), "A Title", "own-name")
    end

    test "a Persian title is transliterated as the save does it", ctx do
      {name, _state} = change(creating(ctx), "قیمت‌گذاری", "")

      assert name == "qymtgdhry"
      assert name == Slug.slugify("قیمت‌گذاری")
    end

    test "an emptied title, or one with nothing to spell, empties a following slug", ctx do
      {name, state} = change(creating(ctx), "Hello", "")
      assert name == "hello"

      {name, state} = change(state, "", name)
      assert name == ""

      {name, _state} = change(state, "😀", name)
      assert name == ""
    end

    test "a field the form's action does not slugify is left alone", ctx do
      assert {"", _state} = change(creating(ctx), "Hello World", "", :path)
    end
  end

  test "a record being updated keeps its slug when its title changes", ctx do
    page = create_page!(title: "Stored Title", name: "stored-name")
    state = state(:update, AshPhoenix.Form.for_update(page, :master_update, actor: ctx.master))

    assert {"stored-name", state} = change(state, "A New Title", "stored-name")
    assert {"", _state} = change(state, "Another Title", "")
  end

  test "the slugify changes are read off the action, with the options the save uses" do
    assert [{:name, :name, options}] =
             Page |> Ash.Resource.Info.action(:master_create) |> Helpers.slugifiers()

    assert options[:lowercase] == true
    assert Helpers.slugifiers(Ash.Resource.Info.action(Page, :read)) == []
  end

  test "a change held by another as `change:`, as AshEvents wraps one, is read as the one it holds" do
    [slugify] =
      Page
      |> Ash.Resource.Info.action(:master_create)
      |> Map.fetch!(:changes)
      |> Enum.filter(&match?(%{change: {AshSlug.Changes.Slugify, _opts}}, &1))

    wrapped = %{slugify | change: {AshEvents.Events.ReplayChangeWrapper, [change: slugify]}}

    assert Helpers.slugifiers(%{changes: [wrapped]}) == Helpers.slugifiers(%{changes: [slugify]})
    assert [{:name, :name, _options}] = Helpers.slugifiers(%{changes: [wrapped]})
  end
end
