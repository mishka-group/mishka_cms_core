# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.ErrorsExceptions.NotFoundError do
  @moduledoc false
  defexception [:message, plug_status: 404]
end

defmodule MishkaCmsCore.ErrorsExceptions.UnauthorizedError do
  @moduledoc false
  defexception [:message, plug_status: 401]
end

defmodule MishkaCmsCore.ErrorsExceptions.ServerError do
  @moduledoc false
  defexception [:message, plug_status: 500]
end

defmodule MishkaCmsCore.ErrorsExceptions.ConfigError do
  @moduledoc false
  defexception [:message, plug_status: 400]
end

defmodule MishkaCmsCore.ErrorsExceptions.RuntimeError do
  @moduledoc false
  defexception [:message, plug_status: 404]
end

defmodule MishkaCmsCore.ErrorsExceptions.ForbiddenError do
  @moduledoc false
  defexception [:message, plug_status: 403]
end

defmodule MishkaCmsCore.ErrorsExceptions.ParserError do
  @moduledoc false
  defexception [:message, plug_status: 500]
end

defmodule MishkaCmsCore.ErrorsExceptions.CompilerError do
  @moduledoc false
  defexception [:message, plug_status: 500]
end
