# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.ActsOnRecordSite do
  @moduledoc """
  Refuses a write by a caller that does not act on the site the record belongs to.

  A missing tenant is not a master, and neither is anything that is not a site user. Without a
  tenant, only a master (a record's `site_id` nil) or the system (`authorize?: false`) passes; with
  one, whoever acts on that site passes, for that site's records alone. The rule is
  `MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals.acts_on?/2`, asked of the row's
  CURRENT `site_id`.

  ## Options

  - `:message` - Required. The message for a caller that does not act on the record's site.

  ## Usage

      validate {MishkaCmsCore.Runtime.Resources.Validations.ActsOnRecordSite,
                message: dgettext_noop("errors", "Cannot restore version of layout from another site.")}
  """
  use Ash.Resource.Validation

  alias MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :message) do
      {:ok, message} when is_binary(message) -> {:ok, [message: message]}
      _missing -> {:error, "ActsOnRecordSite needs a :message"}
    end
  end

  @impl true
  def validate(changeset, opts, context) do
    case SiteWithGlobals.acts_on?(context, changeset.data.site_id) do
      true -> :ok
      false -> {:error, message: Keyword.fetch!(opts, :message)}
    end
  end
end
