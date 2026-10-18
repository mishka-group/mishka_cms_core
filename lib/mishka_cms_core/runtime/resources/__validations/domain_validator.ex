# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.DomainValidator do
  @moduledoc """
  Validates domain formats for Site resources including host, frontend_domain, and allowed_origins.

  This module provides comprehensive domain validation for multi-tenant CMS configurations,
  ensuring proper format for API hosts, frontend domains, and CORS origins.
  """

  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  @impl true
  def init(opts) do
    {:ok, opts}
  end

  @impl true
  def validate(changeset, _opts, _context) do
    with :ok <- validate_host(changeset),
         :ok <- validate_frontend_domain(changeset),
         :ok <- validate_allowed_origins(changeset) do
      :ok
    end
  end

  defp validate_host(changeset) do
    case Ash.Changeset.get_attribute(changeset, :host) do
      nil ->
        :ok

      host ->
        if valid_domain?(host) do
          :ok
        else
          msg =
            dgettext_noop(
              "errors",
              """
              Host must be a valid domain format

              Like:
                mishka.tools without scheme!, not http://mishka.tools or https://mishka.tools
              """
            )

          {:error, field: :host, message: msg}
        end
    end
  end

  defp validate_frontend_domain(changeset) do
    case Ash.Changeset.get_attribute(changeset, :frontend_domain) do
      nil ->
        :ok

      "" ->
        :ok

      domain ->
        if valid_domain?(domain) do
          :ok
        else
          msg =
            dgettext_noop(
              "errors",
              "Frontend domain must be a valid domain format (e.g., app.example.com)"
            )

          {:error, field: :frontend_domain, message: msg}
        end
    end
  end

  defp validate_allowed_origins(changeset) do
    case Ash.Changeset.get_attribute(changeset, :allowed_origins) do
      nil ->
        :ok

      [] ->
        :ok

      origins ->
        invalid_origins = Enum.reject(origins, &valid_origin?/1)

        if Enum.empty?(invalid_origins) do
          :ok
        else
          msg =
            dgettext(
              "errors",
              "Invalid origin format: %{origins}. Origins must start with http:// or https://",
              origins: Enum.join(invalid_origins, ", ")
            )

          {:error, field: :allowed_origins, message: msg}
        end
    end
  end

  defp domain_regex do
    ~r/\A[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*\z/
  end

  defp valid_domain?(domain) when is_binary(domain) do
    String.match?(domain, domain_regex())
  end

  defp valid_domain?(_), do: false

  # The scheme is mandatory: an `Origin` header always carries one, and the Site guardedstruct
  # already rejects scheme-less entries on write, so accepting them here only disagreed with the
  # resource without ever admitting a value. The host is read with `URI.new/1`, and a port that is
  # not a number, a user name before the host or a line break anywhere is not an origin.
  defp valid_origin?(origin) when is_binary(origin) do
    with false <- String.contains?(origin, [" ", "\t", "\n", "\r"]),
         {:ok, %URI{scheme: scheme, host: host, userinfo: nil}} when scheme in ["http", "https"] <-
           URI.new(origin) do
      valid_domain?(host)
    else
      _not_an_origin -> false
    end
  end

  defp valid_origin?(_), do: false

  @impl true
  def atomic(_changeset, _opts, _context) do
    :ok
  end

  @impl true
  def describe(_opts) do
    [
      message: "Validates domain formats for host, frontend_domain, and allowed_origins",
      vars: []
    ]
  end
end
