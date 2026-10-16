# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# How AshJsonApi shows a request that reaches one site's data with no site chosen — what an unscoped
# request (`x-no-tenant`, see `MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug`) gets on a route
# that works on one site, such as the public `/v1/user/…` routes and the tenant admin ones. It says
# what `MishkaCmsCore.Runtime.Resources.Validations.TenantContext` says to the same request. A
# protocol implementation for a dependency's error, so it sits apart from either library's callers,
# like `_account_sort_errors.ex`.

defimpl AshJsonApi.ToJsonApiError, for: Ash.Error.Invalid.TenantRequired do
  use Gettext, backend: MishkaCmsCore.Gettext

  def to_json_api_error(_error) do
    %AshJsonApi.Error{
      id: Ash.UUID.generate(),
      status_code: 400,
      code: "tenant_required",
      title: dgettext("errors", "Tenant required"),
      detail:
        dgettext(
          "errors",
          "Tenant context is required for this action. Use the master action instead."
        ),
      log_level: :debug
    }
  end
end
