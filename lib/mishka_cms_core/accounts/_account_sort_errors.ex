# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# How AshJsonApi shows a sort it refuses because a field or a relationship is `sortable? false` —
# every relationship into an account is (see `MishkaCmsCore.Accounts.User`'s `:related`), and
# `sort_included[comments]=author.email` reaches Ash with no check of AshJsonApi's own first. A
# protocol implementation for a dependency's error, so it sits apart from either library's callers,
# like `_auth_rate_limit_errors.ex`.

defimpl AshJsonApi.ToJsonApiError, for: Ash.Error.Query.UnsortableField do
  use Gettext, backend: MishkaCmsCore.Gettext

  def to_json_api_error(error) do
    %AshJsonApi.Error{
      id: Ash.UUID.generate(),
      status_code: 400,
      code: "invalid_sort",
      title: gettext("Invalid sort"),
      detail: gettext("The results cannot be sorted by %{field}.", field: error.field),
      log_level: :debug
    }
  end
end
