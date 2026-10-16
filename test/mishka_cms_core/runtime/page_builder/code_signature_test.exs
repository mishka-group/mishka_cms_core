# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.CodeSignatureTest do
  @moduledoc """
  An HMAC over each stored snippet, so code that did not come through this application does not run.

  Three properties, in order of how much they matter:

    1. **Off by default.** No key, and everything behaves exactly as it did before this existed —
       otherwise adding it to a live database stops every page at once.
    2. **Unsigned code does nothing, and the page still renders.** Refusing to compile would turn one
       tampered helper into a site-wide outage, which is a better outcome for whoever tampered with
       it than for anybody else.
    3. **Signing survives the round trip** through storage and reformatting, or it is an outage
       waiting for the next save.
  """
  use ExUnit.Case, async: false

  @moduletag :unit
  @moduletag :capture_log

  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.PageBuilder.CodeSignature

  @key "a-test-signing-key-that-is-long-enough"

  setup do
    on_exit(fn -> Application.delete_env(:mishka_cms_core, :code_signing_key) end)
    :ok
  end

  defp signing_on, do: Application.put_env(:mishka_cms_core, :code_signing_key, @key)
  defp signing_off, do: Application.delete_env(:mishka_cms_core, :code_signing_key)

  defp compile!(infos) do
    {_params, ast} = LiveViewCompiler.build_info_handlers({%{infos: infos}, []})
    module = Module.concat(__MODULE__, "S#{System.unique_integer([:positive])}")

    Module.create(module, {:__block__, [], ast}, Macro.Env.location(__ENV__))
    module
  end

  # THE PROPERTY THAT LETS THIS BE ADDED TO A LIVE DATABASE AT ALL.
  describe "off unless a key is configured" do
    test "nothing is signed and nothing is verified" do
      signing_off()

      refute CodeSignature.enabled?()
      assert CodeSignature.sign("anything") == nil
      assert CodeSignature.put(%{code: "x"}) == %{code: "x"}
      assert CodeSignature.valid?("x", nil), "with no key there is nothing to verify"
      assert CodeSignature.trusted?(%{code: "x"})
    end

    test "and an unsigned snippet still runs" do
      signing_off()
      module = compile!([%{name: ":tick", code: "{:ran, socket}"}])

      assert module.handle_info(:tick, :state) == {:ran, :state}
    end
  end

  describe "with a key" do
    test "a signature is produced, and it is not the code" do
      signing_on()

      assert signature = CodeSignature.sign("{:noreply, socket}")
      assert String.length(signature) == 64
      refute signature =~ "noreply"
    end

    test "the same code signs the same way and different code does not" do
      signing_on()

      assert CodeSignature.sign("a") == CodeSignature.sign("a")
      refute CodeSignature.sign("a") == CodeSignature.sign("b")
    end

    # A save that only changes indentation, or a paste that brings CRLF with it, must not invalidate
    # a signature — and the compiler has to reach the same digest from the stored text.
    test "trailing whitespace and line endings do not change it" do
      signing_on()

      assert CodeSignature.sign("a\nb") == CodeSignature.sign("a  \nb")
      assert CodeSignature.sign("a\nb") == CodeSignature.sign("a\r\nb")
      assert CodeSignature.sign("a\nb") == CodeSignature.sign("a\nb\n")
    end

    test "a different key gives a different answer — which is the staging story" do
      signing_on()
      ours = CodeSignature.sign("{:noreply, socket}")

      Application.put_env(:mishka_cms_core, :code_signing_key, "some-other-deployments-key")

      refute CodeSignature.valid?("{:noreply, socket}", ours),
             "a dump restored elsewhere must not verify"
    end

    test "a snippet signed by us is trusted, and one that was edited afterwards is not" do
      signing_on()
      signed = CodeSignature.put(%{code: "{:noreply, socket}", name: ":tick"})

      assert CodeSignature.trusted?(signed)
      refute CodeSignature.trusted?(%{signed | code: "System.cmd(\"rm\", [])"})
    end

    test "string-keyed and atom-keyed snippets both work, and keep their shape" do
      signing_on()

      assert %{"signature" => _} = CodeSignature.put(%{"code" => "x", "name" => "a"})
      assert %{signature: _} = CodeSignature.put(%{code: "x", name: "a"})
    end
  end

  # THE ONE THAT PAYS FOR THE FEATURE. A row written by anything other than this application compiles
  # to a clause that does nothing.

  # A SNIPPET IS NOT ALWAYS A MAP. `events` and `infos` are plain maps, and `helpers` is a list of
  # `%Embeddeds.Helper{}` — a struct, which does not implement Access. The bracket form this module
  # used raised on every one of them, so configuring a key made saving OR compiling anything that
  # carries a helper fail outright, on all four signed resources.
  describe "a snippet that is a struct" do
    alias MishkaCmsCore.Runtime.Resources.Embeddeds.Helper

    # `_name` because the INERT clause this compiles to under a key has an empty body, and a bound
    # argument nothing reads is a warning on the generated module rather than on this file.
    defp helper, do: %Helper{name: "greet", args: "_name", code: ~s("hi")}

    test "is read rather than raised on, with a key and without" do
      signing_off()
      assert CodeSignature.trusted?(helper())

      signing_on()
      refute_raise(fn -> CodeSignature.trusted?(helper()) end)
      refute_raise(fn -> CodeSignature.put(helper()) end)
    end

    # AND IT IS SIGNED LIKE ANY OTHER SNIPPET, now that `Helper` declares a `signature` field and
    # `@derive` carries it. Before that there was nowhere to put one: a signature written onto a
    # helper was lost between here and the column, `trusted?/1` answered false for a snippet this
    # deployment had just signed, and a deployment that turned signing on compiled every helper it
    # had into an inert clause.
    test "is signed, and the signature survives on the struct" do
      signing_on()

      signed = CodeSignature.put(helper())

      assert is_binary(signed.signature)
      assert CodeSignature.trusted?(signed)
      refute CodeSignature.trusted?(%{signed | code: ~s("tampered")})
    end

    # AND THE SHAPE THAT REACHES THE COLUMN KEEPS IT. `@derive {Jason.Encoder, only: […]}` decides
    # what is stored, and a key left off that list is a signature that verifies in memory and is
    # gone by the next read.
    test "and survives the encoding the column stores" do
      signing_on()

      round_tripped =
        helper() |> CodeSignature.put() |> Jason.encode!() |> Jason.decode!()

      assert is_binary(round_tripped["signature"])
      assert CodeSignature.trusted?(round_tripped)
    end

    # AN UNSIGNED ONE STILL GOES INERT, which is the whole point: a helper written into the database
    # by anything other than this application does nothing, and the page still renders.
    test "an unsigned helper compiles to an inert clause under a key, and warns" do
      signing_on()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {_params, ast} = LiveViewCompiler.build_helpers({%{helpers: [helper()]}, []})
          module = Module.concat(__MODULE__, "H#{System.unique_integer([:positive])}")
          Module.create(module, {:__block__, [], ast}, Macro.Env.location(__ENV__))

          assert module.greet("world") == nil
        end)

      assert log =~ "greet"
    end

    defp refute_raise(fun) do
      fun.()
      :ok
    rescue
      error -> flunk("raised: " <> Exception.message(error))
    end
  end

  describe "what the compiler does with untrusted code" do
    test "signed code runs" do
      signing_on()
      signed = CodeSignature.put(%{name: ":tick", code: "{:ran, socket}"})

      assert compile!([signed]).handle_info(:tick, :state) == {:ran, :state}
    end

    test "unsigned code is inert, and the clause is still there" do
      signing_on()

      module = compile!([%{name: ":tick", code: "{:should_not_run, socket}"}])

      assert module.handle_info(:tick, :state) == {:noreply, :state}
    end

    test "code edited after signing is inert" do
      signing_on()
      signed = CodeSignature.put(%{name: ":tick", code: "{:ran, socket}"})
      tampered = %{signed | code: "{:tampered, socket}"}

      assert compile!([tampered]).handle_info(:tick, :state) == {:noreply, :state}
    end

    # The whole reason it is inert rather than a refusal: one tampered snippet must not take the
    # document with it.
    test "the rest of the document still compiles and runs" do
      signing_on()
      good = CodeSignature.put(%{name: ":good", code: "{:ran, socket}"})
      bad = %{name: ":bad", code: "{:should_not_run, socket}"}

      module = compile!([good, bad])

      assert module.handle_info(:good, :state) == {:ran, :state}
      assert module.handle_info(:bad, :state) == {:noreply, :state}
    end

    test "and it says so in the log, naming what to do about it" do
      signing_on()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          compile!([%{name: ":tick", code: "{:should_not_run, socket}"}])
        end)

      assert log =~ "not signed for this deployment"
      assert log =~ "re-sign"
    end
  end
end
