# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.Validations.ValidEmail do
  @moduledoc """
  Validates email addresses according to RFC 5322 standards.

  This validation performs comprehensive email format checking to ensure that email
  addresses meet technical specifications and common usage patterns. It validates
  both the local part (before @) and domain part (after @) of email addresses,
  enforcing length limits, character restrictions, and structural requirements.

  The validation checks include: empty string detection, space character prohibition,
  @ symbol presence and uniqueness, maximum length constraints (254 total, 64 for
  local part), and full RFC 5322 regex pattern matching. The regex supports quoted
  strings, IP addresses in brackets, and internationalized domain names.

  The validation is case-insensitive and trims whitespace before processing. It can
  be configured to validate any field through the `:field` option, defaulting to the
  `:email` attribute. Nil values are considered valid to allow optional email fields.
  """

  use Gettext, backend: MishkaCmsCore.Gettext
  use Ash.Resource.Validation

  @impl true
  @doc """
  Validates an email address field in the changeset.

  ## Options
  - `:field` - The field to validate (defaults to `:email`)

  ## Returns
  - `:ok` if the email is valid or nil
  - `{:error, field: atom(), message: String.t()}` with specific validation failure message
  """
  def validate(changeset, opts, _context) do
    field = Keyword.get(opts, :field, :email)

    case Ash.Changeset.get_attribute(changeset, field) do
      nil ->
        :ok

      email ->
        validate_email(email, field)
    end
  end

  # Performs comprehensive email validation checks.
  # Returns specific error messages for different validation failures.
  defp validate_email(email, field) do
    email_string = email |> to_string() |> String.trim() |> String.downcase()

    cond do
      email_string == "" ->
        {:error, field: field, message: dgettext_noop("errors", "cannot be empty")}

      String.contains?(email_string, " ") ->
        {:error, field: field, message: dgettext_noop("errors", "cannot contain spaces")}

      !String.contains?(email_string, "@") ->
        {:error, field: field, message: dgettext_noop("errors", "must contain @ symbol")}

      match?([_, _, _ | _], String.split(email_string, "@")) ->
        {:error,
         field: field, message: dgettext_noop("errors", "cannot contain multiple @ symbols")}

      String.length(email_string) > 254 ->
        {:error,
         field: field, message: dgettext_noop("errors", "is too long (maximum 254 characters)")}

      email_string |> String.split("@") |> List.first() |> String.length() > 64 ->
        {:error,
         field: field,
         message:
           dgettext_noop("errors", "local part is too long (maximum 64 characters before @)")}

      !valid_format?(email_string) ->
        {:error, field: field, message: dgettext_noop("errors", "is not a valid email format")}

      true ->
        :ok
    end
  end

  # Validates email format using RFC 5322 compliant regex.
  # Supports quoted strings, IP addresses, and international domains.
  defp valid_format?(email) do
    regex =
      ~r/^(?:[a-z0-9!#$%&'*+\/=?^_`{|}~-]+(?:\.[a-z0-9!#$%&'*+\/=?^_`{|}~-]+)*|"(?:[\x01-\x08\x0b\x0c\x0e-\x1f\x21\x23-\x5b\x5d-\x7f]|\\[\x01-\x09\x0b\x0c\x0e-\x7f])*")@(?:(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?|\[(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?|[a-z0-9-]*[a-z0-9]:(?:[\x01-\x08\x0b\x0c\x0e-\x1f\x21-\x5a\x53-\x7f]|\\[\x01-\x09\x0b\x0c\x0e-\x7f])+)\])$/

    Regex.match?(regex, email)
  end
end
