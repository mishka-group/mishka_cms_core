# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Changes.StylesheetCompiles do
  @moduledoc """
  Refuses a stylesheet whose CSS Tailwind will not build, on its `content` field, in Tailwind's own
  words: `MishkaCmsCore.Runtime.Compilers.TailwindCompiler.verify_css/2`, the check the builder's
  reusable classes are written through.

  Every row is pasted into the input Tailwind builds a site's CSS from, so one row it refuses (an
  unclosed `{`, an `@apply` of a utility it does not know) fails that whole build, and the site
  keeps the CSS it had before for every later change too. The save said it was updated.

  Asked when `content` changes, in a `before_transaction` hook: it runs the Tailwind binary, about
  1.5 s, so it waits for the write rather than running on a form's every keystroke, and it is done
  before the write's transaction opens, so no database connection is held while Tailwind runs. The
  builder's own rows (`page_code: :builder`) are left to the builder, which checks each class and
  each element's CSS before it writes the row.

      changes do
        change {MishkaCmsCore.Runtime.Resources.Changes.StylesheetCompiles, []},
          on: [:create, :update]
      end
  """
  use Ash.Resource.Change

  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :content) and
         changeset.context[:page_code] != :builder do
      Ash.Changeset.before_transaction(changeset, &verified/1)
    else
      changeset
    end
  end

  # Read as the write will store it: every change of the action has run by now, `site_id` included.
  defp verified(changeset) do
    case Ash.Changeset.get_attribute(changeset, :content) do
      content when is_binary(content) -> built(changeset, content)
      _no_content -> changeset
    end
  end

  defp built(changeset, content) do
    case TailwindCompiler.verify_css(content, Ash.Changeset.get_attribute(changeset, :site_id)) do
      :ok -> changeset
      {:error, message} -> Ash.Changeset.add_error(changeset, field: :content, message: message)
    end
  end
end
