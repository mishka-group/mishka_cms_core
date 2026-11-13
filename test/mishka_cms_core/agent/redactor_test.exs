# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.RedactorTest do
  @moduledoc """
  What a receipt may hold: shape, never content. A value a reader may not see is dropped, not
  shortened, and an error keeps its class and field names, never its message.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Agent.Redactor

  describe "evidence/1" do
    test "keeps scalars and drops content" do
      evidence =
        Redactor.evidence(%{
          status: :published,
          valid?: true,
          count: 3,
          id: "0b9d2c6e-8f1a-4b7e-9a51-2f4c8e6d1a30",
          topic: "blog_post:updated",
          at: ~U[2026-01-01 00:00:00Z],
          fields: [:title, :slug],
          title: "A secret plan for Tuesday",
          body: String.duplicate("x", 65),
          params: %{"email" => "someone@example.com"},
          record: %URI{host: "example.com"},
          values: ["not", "atoms"]
        })

      assert evidence == %{
               status: :published,
               valid?: true,
               count: 3,
               id: "0b9d2c6e-8f1a-4b7e-9a51-2f4c8e6d1a30",
               topic: "blog_post:updated",
               at: ~U[2026-01-01 00:00:00Z],
               fields: [:title, :slug]
             }
    end

    test "drops string keys, and keeps no more than sixteen keys" do
      assert Redactor.evidence(%{"status" => :ok}) == %{}

      many = Map.new(1..40, &{:"key_#{&1}", &1})
      assert map_size(Redactor.evidence(many)) == 16
    end

    test "nil stays nil and anything else is empty" do
      assert Redactor.evidence(nil) == nil
      assert Redactor.evidence("text") == %{}
      assert Redactor.evidence(status: :ok) == %{status: :ok}
    end
  end

  describe "error/3" do
    test "keeps the class and the top frame, never the message" do
      {kind, reason, stacktrace} =
        try do
          raise ArgumentError, "the password hunter2 was refused"
        catch
          kind, reason -> {kind, reason, __STACKTRACE__}
        end

      error = Redactor.error(kind, reason, stacktrace)

      assert error.kind == :error
      assert error.module == ArgumentError
      assert error.at =~ "RedactorTest"
      refute inspect(error) =~ "hunter2"
    end

    test "an Ash error keeps its classes and field names, not the values" do
      error =
        Ash.Error.to_error_class(
          Ash.Error.Changes.InvalidAttribute.exception(
            field: :email,
            message: "someone@example.com is taken",
            value: "someone@example.com"
          )
        )

      summary = Redactor.error(:error, error)

      assert summary.fields == [:email]
      assert Ash.Error.Changes.InvalidAttribute in summary.classes
      refute inspect(summary) =~ "someone@example.com"
    end
  end

  test "an actor is its id and kind only" do
    master = %{id: "u1", site_id: nil, email: "boss@example.com"}
    user = %{id: "u2", site_id: "s1", email: "user@example.com"}

    assert Redactor.actor(master) == %{id: "u1", kind: :master}
    assert Redactor.actor(user) == %{id: "u2", kind: :user}
    assert Redactor.actor(nil) == %{id: nil, kind: :system}
  end
end
