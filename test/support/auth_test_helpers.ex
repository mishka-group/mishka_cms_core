# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.AuthTestHelpers do
  @moduledoc """
  Helper functions for authentication testing
  """

  import ExUnit.Assertions

  # `make_api_request/3` builds requests rather than data, so it lives on the case, not the factory.
  import MishkaCmsCore.ConnCase, only: [make_api_request: 3]

  @api_user_path "/api/json/v1/auth/user"
  @default_password "Password123!"

  @doc """
  Signs in a master user (system admin with no site_id).
  Uses x-no-tenant header for master authentication, on `localhost`: the fixture's master site, the
  only address that takes it.
  Returns the JWT token.
  """
  def sign_in_master(master_user, password \\ @default_password) do
    response =
      make_api_request(
        "#{@api_user_path}/sign-in",
        %{
          "type" => "user",
          "attributes" => %{"email" => to_string(master_user.email), "password" => password}
        },
        headers: [{"x-no-tenant", "true"}]
      )

    assert response.status == 201
    %{"meta" => %{"token" => token}} = Jason.decode!(response.resp_body)
    token
  end

  @doc """
  Signs in a tenant user (site-specific user with site_id).
  Site is determined automatically from host (defaults to localhost).
  Returns the JWT token.
  """
  def sign_in_tenant(tenant_user, password \\ @default_password) do
    response =
      make_api_request(
        "#{@api_user_path}/sign-in",
        %{
          "type" => "user",
          "attributes" => %{"email" => to_string(tenant_user.email), "password" => password}
        },
        []
      )

    assert response.status == 201
    %{"meta" => %{"token" => token}} = Jason.decode!(response.resp_body)
    token
  end

  @doc """
  A bearer token for a new user of `site` holding exactly `permission_names` — an admin of one
  area, say `["admin:api:runtime:page"]`, to show that an area reaches its own data and nothing else.
  """
  def area_token!(site, permission_names) do
    site.id
    |> area_user!(permission_names)
    |> sign_in_tenant()
  end

  defp area_user!(site_id, permission_names) do
    MishkaCmsCore.Test.Factory.create_user_with_permissions!(permission_names,
      site_id: site_id,
      email: "area-#{System.unique_integer([:positive])}@example.com",
      password: @default_password,
      password_confirmation: @default_password
    )
  end

  @doc """
  Captures a password reset token from email.

  This function:
  1. Requests a password reset for the given user
  2. Captures the reset email
  3. Extracts and returns the reset token
  """
  def get_password_reset_token(user, site, api_user_path, make_api_request_fn) do
    # Clear any existing emails
    flush_emails()

    # Build headers and host based on whether site exists
    {headers, host} =
      if site do
        {[{"x-no-tenant", "false"}], site.host}
      else
        {[{"x-no-tenant", "true"}], nil}
      end

    # Request password reset
    reset_request_response =
      make_api_request_fn.(
        "#{api_user_path}/reset-request",
        %{"email" => to_string(user.email)},
        headers: headers,
        host: host
      )

    assert reset_request_response.status == 201

    # Capture the reset email (skip confirmation emails)
    capture_reset_token_from_email()
  end

  @doc """
  Captures a reset token from password reset email.
  Filters out confirmation emails and other non-reset emails.
  """
  def capture_reset_token_from_email(timeout \\ 3000) do
    receive do
      {:email, email} ->
        if is_reset_email?(email) do
          extract_token_from_reset_email(email)
        else
          # Not a reset email, try again
          capture_reset_token_from_email(timeout)
        end
    after
      timeout ->
        raise "No password reset email received within #{timeout}ms"
    end
  end

  @doc """
  Generates a valid password reset token for testing.
  Use this when you want to skip the email flow.
  """
  def generate_reset_token(user, site \\ nil) do
    tenant_opts = if site, do: [tenant: site.id], else: []

    {:ok, token, _claims} =
      AshAuthentication.Jwt.token_for_user(
        user,
        %{
          "act" => "reset_password_with_token",
          "pur" => "user:reset_password"
        },
        tenant_opts
      )

    token
  end

  @doc """
  Performs a complete password reset flow.
  Returns the new authentication token.
  """
  def reset_user_password(user, new_password, site, api_user_path, make_api_request_fn) do
    # Get reset token
    reset_token = get_password_reset_token(user, site, api_user_path, make_api_request_fn)

    # Build headers and host based on whether site exists
    {headers, host} =
      if site do
        {[{"x-no-tenant", "false"}], site.host}
      else
        {[{"x-no-tenant", "true"}], nil}
      end

    # Reset password
    response =
      make_api_request_fn.(
        "#{api_user_path}/reset-password",
        %{
          "type" => "user",
          "attributes" => %{
            "reset_token" => reset_token,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        },
        headers: headers,
        host: host
      )

    assert response.status == 201
    result = Jason.decode!(response.resp_body)

    # Return the new auth token
    result["meta"]["token"]
  end

  @doc """
  Verifies that password was successfully changed.
  """
  def verify_password_changed(
        user,
        old_password,
        new_password,
        site,
        api_user_path,
        make_api_request_fn
      ) do
    # Build headers and host based on whether site exists
    {headers, host} =
      if site do
        {[{"x-no-tenant", "false"}], site.host}
      else
        {[{"x-no-tenant", "true"}], nil}
      end

    # Old password should not work
    old_response =
      make_api_request_fn.(
        "#{api_user_path}/sign-in",
        %{
          "type" => "user",
          "attributes" => %{
            "email" => to_string(user.email),
            "password" => old_password
          }
        },
        headers: headers,
        host: host
      )

    assert old_response.status == 403

    # New password should work
    new_response =
      make_api_request_fn.(
        "#{api_user_path}/sign-in",
        %{
          "type" => "user",
          "attributes" => %{
            "email" => to_string(user.email),
            "password" => new_password
          }
        },
        headers: headers,
        host: host
      )

    assert new_response.status == 201
    Jason.decode!(new_response.resp_body)["meta"]["token"]
  end

  @doc """
  Helper to build request options based on site context
  """
  def build_request_opts(site) do
    if site do
      %{
        headers: [{"x-no-tenant", "false"}],
        host: site.host
      }
    else
      %{
        headers: [{"x-no-tenant", "true"}],
        host: nil
      }
    end
  end

  # Private functions

  defp is_reset_email?(email) do
    email.subject =~ "Reset" or
      email.subject =~ "reset" or
      email.subject =~ "Password" or
      email.subject =~ "password"
  end

  defp extract_token_from_reset_email(email) do
    body = email.html_body || email.text_body || ""

    # Try to extract from password-reset URL
    case Regex.run(~r/password-reset\/([A-Za-z0-9\-_\.]+)/, body) do
      [_, token] ->
        token

      _ ->
        # Try to extract any JWT token
        case Regex.run(~r/eyJ[A-Za-z0-9\-_\.]+/, body) do
          [token] ->
            token

          _ ->
            raise "Could not extract reset token from email body"
        end
    end
  end

  def flush_emails do
    receive do
      {:email, _} -> flush_emails()
    after
      0 -> :ok
    end
  end
end
