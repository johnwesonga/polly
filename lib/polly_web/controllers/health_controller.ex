defmodule PollyWeb.HealthController do
  use PollyWeb, :controller

  def show(conn, _params) do
    text(conn, "ok")
  end
end
