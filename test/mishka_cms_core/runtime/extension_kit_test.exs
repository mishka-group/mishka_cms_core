# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.ExtensionKitTest do
  @moduledoc """
  The Path-A extension seam: an extension ships its components as a bundle and they become ordinary
  `Component` rows, so the palette, the inspector, the examples modal and the compiler all work with
  no editor changes.

  The contract that matters most is that calling `install!/1` unconditionally is safe: an extension
  that ships no bundle must get `:noop`, not a crash, or every extension would have to guard the
  call itself.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.ExtensionKit

  describe "bundle discovery" do
    test "an application shipping no component bundle reports none" do
      refute ExtensionKit.available?(:mishka_cms_core)
      assert ExtensionKit.bundle_path(:mishka_cms_core) == nil
    end

    test "an application that does not exist is not an error" do
      refute ExtensionKit.available?(:no_such_application_at_all)
      assert ExtensionKit.bundle_path(:no_such_application_at_all) == nil
    end

    test "a named bundle is looked up beside the default one" do
      assert ExtensionKit.bundle_path(:mishka_cms_core, "extras") == nil
    end

    test "the UI kit's own bundle is found when asked for by name" do
      # `chelekom.json` is downloaded into this application's priv/cms_ui_kits, not
      # priv/cms_components, so this proves the lookup is scoped to the extension directory rather
      # than searching priv at large.
      refute ExtensionKit.available?(:mishka_cms_core, "chelekom")
    end
  end

  describe "install!/2 and uninstall!/2" do
    test "installing an extension with no bundle is a no-op, not a crash" do
      assert ExtensionKit.install!(:mishka_cms_core) == :noop
      assert ExtensionKit.install!(:no_such_application_at_all) == :noop
    end

    test "uninstalling an extension with no bundle is a no-op" do
      assert ExtensionKit.uninstall!(:mishka_cms_core) == :noop
    end

    test "a site-scoped install of a missing bundle is still a no-op" do
      assert ExtensionKit.install!(:mishka_cms_core, site_id: Ecto.UUID.generate()) == :noop
    end
  end
end
