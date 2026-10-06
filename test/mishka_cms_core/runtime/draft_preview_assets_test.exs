defmodule MishkaCmsCore.Runtime.DraftPreviewAssetsTest do
  use ExUnit.Case, async: true
  @moduletag :unit

  alias MishkaCmsCore.Runtime.{DraftPreviewAssets, Layout, PageDraft}
  alias MishkaCmsCore.Runtime.Resources.Embeddeds.Helper
  alias MishkaCmsCore.Runtime.States.AssetsState

  defp token, do: "tok-" <> Integer.to_string(System.unique_integer([:positive]))

  defp draft(overrides \\ []) do
    struct!(
      PageDraft,
      Keyword.merge(
        [
          id: Ash.UUID.generate(),
          name: "draft",
          title: "Draft",
          path: "/draft",
          preview_token: token(),
          template: ~S|<p class="probe">{shout("hi")}</p>|,
          helpers: [%Helper{name: "shout", args: "word", code: "String.upcase(word)"}],
          events: [],
          infos: [],
          extra: %{},
          permissions: [],
          site: nil,
          layout: nil,
          updated_at: ~U[2026-10-02 10:00:00.000000Z]
        ],
        overrides
      )
    )
  end

  defp html(rendered),
    do: rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

  defp page_assigns(module),
    do: Map.merge(module.__page_information__(), %{flash: %{}, query_params: %{}})

  describe "ensure_module/2" do
    test "compiles a page with its own helpers, which a template alone cannot call" do
      record = draft()

      assert {:ok, module} = DraftPreviewAssets.ensure_module(record, nil)
      assert html(module.render(page_assigns(module))) =~ ~s|<p class="probe">HI</p>|

      DraftPreviewAssets.unload_module(record)
    end

    test "is not the live page's module, so a draft never replaces what visitors are served" do
      record = draft()

      {:ok, module} = DraftPreviewAssets.ensure_module(record, nil)

      assert inspect(module) =~ "MishkaCmsCore.Runtime.Preview."
      assert module.__page_information__([:private, :page_module]) == module

      DraftPreviewAssets.unload_module(record)
    end

    test "keeps the compiled module while the record is unchanged" do
      record = draft()

      {:ok, module} = DraftPreviewAssets.ensure_module(record, nil)
      compiled = AssetsState.get!(record.preview_token, "module")
      {:ok, ^module} = DraftPreviewAssets.ensure_module(record, nil)

      assert AssetsState.get!(record.preview_token, "module") == compiled,
             "compiled again for an unchanged record"

      DraftPreviewAssets.unload_module(record)
    end

    test "compiles again once the record is saved" do
      record = draft()
      {:ok, module} = DraftPreviewAssets.ensure_module(record, nil)

      saved =
        %{record | template: ~S|<p class="probe">{shout("saved")}</p>|}
        |> Map.put(:updated_at, ~U[2026-10-02 11:00:00.000000Z])

      {:ok, ^module} = DraftPreviewAssets.ensure_module(saved, nil)

      assert html(module.render(page_assigns(module))) =~ "SAVED"

      DraftPreviewAssets.unload_module(saved)
    end

    test "compiles a layout that renders around the content it is handed" do
      layout =
        struct!(Layout,
          id: Ash.UUID.generate(),
          name: "shell",
          path: "/layouts/shell",
          preview_token: token(),
          template: ~S|<main class="shell"><b>{mark()}</b>{@inner_content}</main>|,
          helpers: [%Helper{name: "mark", args: "", code: ~S|"*"|}],
          extra: %{},
          permissions: [],
          site: nil,
          updated_at: ~U[2026-10-02 10:00:00.000000Z]
        )

      {:ok, module} = DraftPreviewAssets.ensure_module(layout, nil)

      assert html(module.render(%{flash: %{}}, Phoenix.HTML.raw("<i>page</i>"))) =~
               ~s|<main class="shell"><b>*</b><i>page</i></main>|

      DraftPreviewAssets.unload_module(layout)
    end

    test "answers a template that does not compile with its error" do
      record = draft(template: "<p>{undefined_helper()}</p>", helpers: [])

      assert {:error, message} = DraftPreviewAssets.ensure_module(record, nil)
      assert message =~ "undefined_helper"
    end
  end

  # PREVIEWS OF ONE RECORD OPENED TOGETHER. They share its module, so they compile under one lock —
  # and the ones that waited for it find the module the first one compiled instead of compiling it
  # again, one after another.
  describe "previews opened together" do
    test "compile the record once, not once each" do
      record = draft()
      older = %{record | updated_at: ~U[2026-10-01 10:00:00.000000Z]}
      {:ok, module} = DraftPreviewAssets.ensure_module(older, nil)
      lock = {{DraftPreviewAssets, module}, self()}
      true = :global.set_lock(lock, [node()])

      previews =
        for _ <- 1..5, do: Task.async(fn -> DraftPreviewAssets.ensure_module(record, nil) end)

      wait_until(fn -> Enum.all?(previews, &waiting_for_lock?/1) end)

      # Compiled here, under the lock they wait on; it is let go once this compile is done.
      {:ok, ^module} = DraftPreviewAssets.ensure_module(record, nil)
      compiled = AssetsState.get!(record.preview_token, "module")

      assert Task.await_many(previews, 30_000) |> Enum.uniq() == [{:ok, module}]

      assert AssetsState.get!(record.preview_token, "module") == compiled,
             "compiled again by a preview that waited"

      DraftPreviewAssets.unload_module(record)
    end

    # A PUBLISH UNLOADS FROM INSIDE ITS TRANSACTION, and must not hold it open for a preview that is
    # compiling. The preview's module goes when that preview closes.
    test "unloading does not wait for a preview that is compiling" do
      record = draft()
      {:ok, module} = DraftPreviewAssets.ensure_module(record, nil)
      test = self()

      compiling =
        spawn(fn ->
          true = :global.set_lock({{DraftPreviewAssets, module}, self()}, [node()])
          send(test, :holding)
          receive do: (:done -> :ok)
        end)

      assert_receive :holding
      unload = Task.async(fn -> DraftPreviewAssets.unload_module(record) end)

      assert Task.yield(unload, 2_000) == {:ok, :ok}
      assert AssetsState.get!(record.preview_token, "module") == nil

      send(compiling, :done)
      DraftPreviewAssets.unload_module(record)
    end
  end

  defp waiting_for_lock?(%Task{pid: pid}) do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, frames} ->
        Enum.any?(frames, &match?({:global, _fun, _arity, _at}, &1))

      nil ->
        false
    end
  end

  defp wait_until(fun, tries \\ 1_000) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("the previews never reached the lock")

      true ->
        Process.sleep(5)
        wait_until(fun, tries - 1)
    end
  end

  describe "unload_module/1 and purge/1" do
    test "unload the compiled module" do
      record = draft()
      {:ok, module} = DraftPreviewAssets.ensure_module(record, nil)

      assert :ok = DraftPreviewAssets.unload_module(record)
      refute :erlang.module_loaded(module)

      {:ok, ^module} = DraftPreviewAssets.ensure_module(record, nil)
      DraftPreviewAssets.purge(record)
      refute :erlang.module_loaded(module)
    end

    test "unload a module compiled twice" do
      record = draft()
      {:ok, module} = DraftPreviewAssets.ensure_module(record, nil)

      {:ok, ^module} =
        DraftPreviewAssets.ensure_module(%{record | updated_at: DateTime.utc_now()}, nil)

      DraftPreviewAssets.unload_module(record)

      refute :erlang.module_loaded(module)
      refute :erlang.check_old_code(module)
    end
  end
end
