defmodule Polly.Repo do
  use AshSqlite.Repo,
    otp_app: :polly
end
