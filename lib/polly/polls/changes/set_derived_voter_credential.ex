defmodule Polly.Polls.Changes.SetDerivedVoterCredential do
  @moduledoc false

  use Ash.Resource.Change

  alias Polly.Polls.VoterCredential

  @impl true
  def change(changeset, _opts, _context) do
    grant_id = Ash.Changeset.get_attribute(changeset, :id) || Ash.UUID.generate()
    nonce = VoterCredential.generate_nonce()
    version = 1

    token = VoterCredential.derive(grant_id, nonce, version)

    changeset
    |> Ash.Changeset.force_change_attribute(:id, grant_id)
    |> Ash.Changeset.force_change_attribute(:credential_nonce, nonce)
    |> Ash.Changeset.force_change_attribute(:credential_version, version)
    |> Ash.Changeset.force_change_attribute(:token_digest, VoterCredential.digest(token))
    |> Ash.Changeset.force_change_attribute(:credential_issued_at, DateTime.utc_now())
  end
end
