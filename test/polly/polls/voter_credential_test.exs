defmodule Polly.Polls.VoterCredentialTest do
  use ExUnit.Case, async: false

  alias Polly.Polls.VoterCredential

  test "derivation is stable for one version and separated across inputs" do
    grant_id = Ash.UUID.generate()
    nonce = VoterCredential.generate_nonce()

    token = VoterCredential.derive(grant_id, nonce, 1)

    assert token == VoterCredential.derive(grant_id, nonce, 1)
    refute token == VoterCredential.derive(grant_id, nonce, 2)
    refute token == VoterCredential.derive(Ash.UUID.generate(), nonce, 1)
    refute token == VoterCredential.derive(grant_id, VoterCredential.generate_nonce(), 1)
    assert VoterCredential.digest(token) == VoterCredential.digest(token)
  end

  test "rejects a derivation secret shorter than 32 bytes" do
    previous = Application.fetch_env!(:polly, :voter_token_secret)
    Application.put_env(:polly, :voter_token_secret, "too-short")

    on_exit(fn -> Application.put_env(:polly, :voter_token_secret, previous) end)

    assert_raise RuntimeError, "voter token secret must contain at least 32 bytes", fn ->
      VoterCredential.derive(Ash.UUID.generate(), VoterCredential.generate_nonce(), 1)
    end
  end
end
