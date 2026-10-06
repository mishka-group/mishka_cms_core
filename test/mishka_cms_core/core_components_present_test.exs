defmodule MishkaCmsCore.CoreComponentsPresentTest do
  @moduledoc """
  `present?/1` is the guard every admin template reaches for before reading through a relationship,
  and `MishkaCmsCore.ExtensionLiveView` imports it into all of them — so what it answers is worth
  saying here rather than leaving to whichever template happens to exercise a clause.

  The three it has to call absent are the three that are truthy in a template: `%Ash.NotLoaded{}`
  for a relationship nobody loaded, `%Ash.ForbiddenField{}` for one a field policy hid — this
  application turns those on for relationships, `allow_forbidden_field_for_relationships_by_default?`
  — and `nil` for a `belongs_to` with nothing on the other end. `:if={@record.site}` waves the first
  two straight past, and the `{@record.site.name}` behind the guard takes the LiveView down.
  """

  use ExUnit.Case, async: true

  import MishkaCmsCore.CoreComponents, only: [present?: 1]

  alias MishkaCmsCore.Runtime.{MediaCategory, Site}

  test "a relationship nobody loaded is not there to read through" do
    refute present?(%Ash.NotLoaded{type: :relationship, field: :site, resource: MediaCategory})
  end

  test "a field a policy hid is not there to read through" do
    refute present?(%Ash.ForbiddenField{field: :site, type: :relationship})
  end

  test "an empty relationship is not there to read through" do
    refute present?(nil)
  end

  test "a loaded relationship is" do
    assert present?(%Site{name: "localhost"})
  end

  # A `has_many` that loaded and found nothing is loaded: the template reads through it and draws
  # the empty list it is meant to draw.
  test "a loaded relationship with nothing in it is" do
    assert present?([])
  end
end
