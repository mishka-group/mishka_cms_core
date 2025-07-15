defmodule MishkaCmsCore.ApplicationTest do
  @moduledoc """
  The boot invariant every plugin in this repo depends on: mishka_installer's Mnesia registry is
  already up when the first plugin starts, and the tree those plugins run under is still standing
  when the suite does.

  Both were silently false whenever `deps/` was built with `MIX_ENV` exported. The library picks its
  own supervision tree in a compile-time branch that reads that variable before the `:project_env`
  the config sets, so it supervised nothing; the plugins then blocked in
  `:mnesia.wait_for_tables/2`, and whoever brought Mnesia up afterwards stopped it under all of them
  at once — more deaths in one moment than any supervisor's restart intensity allows, so every
  plugin tree in the run went down before the first test. Nothing failed out loud: `Hook.call/2`
  simply returned its payload untouched, which for `MishkaCmsCore.Sidebar` means an admin page no
  extension declares, and `Sidebar.PageGuard` refusing it.
  """
  use ExUnit.Case, async: false

  alias MishkaInstaller.Event.Event

  # What `MishkaInstaller.Application` supervises for itself when its branch says to — and the one
  # side of this that can change without us, since `MishkaCmsCore.Application` supervises the
  # complement of it. A release that adds a fourth child would go unsupervised wherever the branch
  # compiled empty, so the library's list is read back here rather than assumed.
  @installer [
    MishkaInstaller.Installer.CompileHandler,
    MishkaInstaller.Event.EventHandler,
    MishkaInstaller.MnesiaRepo
  ]

  # A build that compiled the empty branch answers `[]`, which says nothing about what the release
  # names; there is no way to ask it from here, so that answer is admitted rather than guessed at,
  # and the loop below is what carries the invariant in that build.
  test "the installer tree is supervised exactly once, whichever branch the dependency compiled" do
    assert MishkaInstaller.Application.supervised_children() in [[], @installer]

    for child <- @installer,
        do: assert(Process.whereis(child), "#{inspect(child)} is not running")
  end

  test "the event table is loaded, so a plugin's wait_for_tables returns instead of blocking" do
    assert :mnesia.wait_for_tables([Event], 0) == :ok
  end

  # The plugin tree, not the individual plugins: a test may stop or unregister one of those on
  # purpose, and none of them may take the tree with it. This is the assertion the regression broke
  # — `MishkaCmsCore.Supervisor` was gone before the first test, and every `Hook.call/2` in the run
  # answered with its own payload.
  test "the tree this application supervises its plugins under is still up" do
    assert Process.whereis(MishkaCmsCore.Supervisor)
  end
end
