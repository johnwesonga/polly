defmodule Polly.Polls.VoterCredential do
  @moduledoc "Derives and verifies versioned poll-voting credentials."

  @domain "polly:voter-access:v1"
  @nonce_bytes 32

  @spec generate_nonce() :: String.t()
  def generate_nonce do
    @nonce_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @spec derive(Ecto.UUID.t(), String.t(), pos_integer()) :: String.t()
  def derive(grant_id, nonce, version)
      when is_binary(grant_id) and is_binary(nonce) and is_integer(version) and version > 0 do
    payload = encode_payload(grant_id, nonce, version)

    :hmac
    |> :crypto.mac(:sha256, secret(), payload)
    |> Base.url_encode64(padding: false)
  end

  @spec digest(String.t()) :: String.t()
  def digest(token) when is_binary(token) do
    token
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp encode_payload(grant_id, nonce, version) do
    [
      @domain,
      <<0>>,
      <<byte_size(grant_id)::unsigned-big-32>>,
      grant_id,
      <<byte_size(nonce)::unsigned-big-32>>,
      nonce,
      <<version::unsigned-big-64>>
    ]
  end

  defp secret do
    case Application.fetch_env!(:polly, :voter_token_secret) do
      secret when is_binary(secret) and byte_size(secret) >= 32 -> secret
      _invalid -> raise "voter token secret must contain at least 32 bytes"
    end
  end
end
