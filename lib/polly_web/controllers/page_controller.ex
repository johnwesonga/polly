defmodule PollyWeb.PageController do
  use PollyWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
