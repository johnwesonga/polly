defmodule PollyWeb.PollResultsExportController do
  use PollyWeb, :controller

  alias Polly.Polls.ResultExport

  def show(conn, %{"poll_id" => poll_id}) do
    case ResultExport.generate(poll_id,
           actor: conn.assigns.current_user,
           request_id: List.first(get_resp_header(conn, "x-request-id"))
         ) do
      {:ok, export} ->
        conn
        |> put_resp_content_type("text/csv", "utf-8")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{export.filename}"))
        |> put_resp_header("cache-control", "private, no-store, max-age=0")
        |> put_resp_header("pragma", "no-cache")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_resp(200, export.iodata)

      {:error, :poll_not_open} ->
        conn
        |> put_flash(:error, "Open the poll before exporting results")
        |> redirect(to: ~p"/admin/polls/#{poll_id}/results")

      {:error, :no_options} ->
        conn
        |> put_flash(:error, "This poll has no results to export")
        |> redirect(to: ~p"/admin/polls/#{poll_id}/results")

      {:error, _reason} ->
        send_resp(conn, 404, "Not found")
    end
  end
end
