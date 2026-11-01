# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.StylesheetCompiles do
  @moduledoc """
  Refuses a stylesheet whose CSS Tailwind will not build, on its `content` field, in Tailwind's own
  words: `MishkaCmsCore.Runtime.Compilers.TailwindCompiler.verify_css/2`, the check the builder's
  reusable classes are written through.

  Every row is pasted into the input Tailwind builds a site's CSS from, so one row it refuses (an
  unclosed `{`, an `@apply` of a utility it does not know) fails that whole build, and the site
  keeps the CSS it had before for every later change too. The save said it was updated.

  Asked when `content` changes, at the write only: it runs the Tailwind binary, too slow for a
  form's every keystroke. The builder's own rows (`page_code: :builder`) are left to the builder,
  which checks each class and each element's CSS before it writes the row.
  """
  use Ash.Resource.Validation

  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    content = Ash.Changeset.get_attribute(changeset, :content)

    if Ash.Changeset.changing_attribute?(changeset, :content) and is_binary(content) and
         changeset.context[:page_code] != :builder do
      verified(content, Ash.Changeset.get_attribute(changeset, :site_id))
    else
      :ok
    end
  end

  defp verified(content, site_id) do
    case TailwindCompiler.verify_css(content, site_id) do
      :ok -> :ok
      {:error, message} -> {:error, field: :content, message: message}
    end
  end
end
