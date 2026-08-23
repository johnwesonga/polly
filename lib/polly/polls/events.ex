defmodule Polly.Polls.Events do
  @moduledoc "Poll-scoped status and result event topics."

  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe(poll_id) do
    Phoenix.PubSub.subscribe(Polly.PubSub, topic(poll_id))
  end

  @spec broadcast_status(Polly.Polls.Poll.t()) :: :ok | {:error, term()}
  def broadcast_status(poll) do
    Phoenix.PubSub.broadcast(
      Polly.PubSub,
      topic(poll.id),
      {:poll_status_changed, poll.id, poll.status, poll.results_published_at}
    )
  end

  @spec broadcast_results(Ecto.UUID.t()) :: :ok | {:error, term()}
  def broadcast_results(poll_id) do
    Phoenix.PubSub.broadcast(Polly.PubSub, topic(poll_id), {:poll_results_changed, poll_id})
  end

  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(poll_id), do: "poll:#{poll_id}"
end
