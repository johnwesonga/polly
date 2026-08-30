defmodule Polly.Polls.Readiness do
  @moduledoc """
  Provides shared poll-opening invariants and dashboard readiness projections.

  Poll lifecycle validations use the per-poll predicates, while authorized
  administration surfaces use the aggregate projection to avoid loading every
  poll or issuing one query per poll.
  """

  require Ash.Query

  alias Polly.Accounts.Authorization
  alias Polly.Polls.{Eligibility, Option}

  @minimum_options 2

  @type attention_counts :: %{
          missing_options: non_neg_integer() | nil,
          missing_electorate: non_neg_integer() | nil,
          unsent_invitations: non_neg_integer() | nil,
          failed_deliveries: non_neg_integer() | nil,
          unpublished_results: non_neg_integer()
        }

  @doc "Returns whether a poll has enough active options to open."
  def has_minimum_options?(poll_id) do
    active_option_count(poll_id) >= @minimum_options
  end

  @doc "Returns the number of active options currently configured for a poll."
  def active_option_count(poll_id) do
    Option
    |> Ash.Query.filter(poll_id == ^poll_id and active == true)
    |> Ash.count!(authorize?: false)
  end

  @doc "Returns whether a poll has at least one eligible member."
  def has_eligible_members?(poll_id) do
    Eligibility
    |> Ash.Query.filter(poll_id == ^poll_id)
    |> Ash.exists?(authorize?: false)
  end

  @doc "Returns aggregate readiness counts visible to the supplied actor."
  @spec attention_counts(Polly.Accounts.User.t()) ::
          {:ok, attention_counts()} | {:error, :forbidden}
  def attention_counts(actor) do
    with :ok <- Authorization.authorize(actor, :view_results) do
      if Authorization.allowed?(actor, :manage_polls) do
        {:ok, manager_attention_counts()}
      else
        {:ok, result_attention_counts()}
      end
    end
  end

  defp manager_attention_counts do
    %{rows: [[missing_options, missing_electorate, unsent, failed, unpublished]]} =
      Polly.Repo.query!(
        """
        SELECT
          (SELECT COUNT(*) FROM polls p
           WHERE p.status = 'draft'
             AND (SELECT COUNT(*) FROM poll_options o
                  WHERE o.poll_id = p.id AND o.active = 1) < ?),
          (SELECT COUNT(*) FROM polls p
           WHERE p.status = 'draft'
             AND NOT EXISTS (SELECT 1 FROM poll_eligibilities e WHERE e.poll_id = p.id)),
          (SELECT COUNT(*) FROM polls p
           WHERE p.status = 'open'
             AND NOT EXISTS (
               SELECT 1 FROM poll_invitation_deliveries d
               WHERE d.poll_id = p.id AND d.status = 'accepted'
             )),
          (SELECT COUNT(*) FROM polls p
           WHERE p.status = 'open'
             AND EXISTS (
               SELECT 1 FROM poll_invitation_deliveries d
               WHERE d.poll_id = p.id AND d.status = 'failed'
             )),
          (SELECT COUNT(*) FROM polls p
           WHERE p.status = 'closed' AND p.results_published_at IS NULL)
        """,
        [@minimum_options]
      )

    %{
      missing_options: missing_options,
      missing_electorate: missing_electorate,
      unsent_invitations: unsent,
      failed_deliveries: failed,
      unpublished_results: unpublished
    }
  end

  defp result_attention_counts do
    %{rows: [[unpublished]]} =
      Polly.Repo.query!("""
      SELECT COUNT(*)
      FROM polls
      WHERE status = 'closed' AND results_published_at IS NULL
      """)

    %{
      missing_options: nil,
      missing_electorate: nil,
      unsent_invitations: nil,
      failed_deliveries: nil,
      unpublished_results: unpublished
    }
  end
end
