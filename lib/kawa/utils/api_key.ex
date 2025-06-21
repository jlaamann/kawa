defmodule Kawa.Utils.ApiKey do
  @moduledoc """
  Utilities for generating and managing API keys for Kawa clients.
  """

  @doc """
  Generates a new API key with the format: kawa_{environment}_{random_string}

  Returns a tuple of {api_key, api_key_hash, api_key_prefix}

  ## Examples

      iex> {api_key, hash, prefix} = Kawa.Utils.ApiKey.generate("prod")
      iex> String.starts_with?(api_key, "kawa_prod_")
      true
      iex> prefix
      "kawa_pro"

  """
  def generate(environment) do
    # Generate random string (32 characters)
    random_string = generate_random_string(32)

    # Create the full API key
    api_key = "kawa_#{environment}_#{random_string}"

    # Hash the API key for secure storage
    api_key_hash = :crypto.hash(:sha256, api_key) |> Base.encode16(case: :lower)

    # Create prefix for identification (first 8 chars)
    api_key_prefix = String.slice(api_key, 0, 8)

    {api_key, api_key_hash, api_key_prefix}
  end

  @doc """
  Validates an API key by comparing its hash.
  """
  def validate(api_key, expected_hash) do
    actual_hash = :crypto.hash(:sha256, api_key) |> Base.encode16(case: :lower)
    actual_hash == expected_hash
  end

  @doc """
  Extracts environment from an API key.
  """
  def extract_environment(api_key) do
    case String.split(api_key, "_", parts: 3) do
      ["kawa", environment, _rest] -> {:ok, environment}
      _ -> {:error, :invalid_format}
    end
  end

  defp generate_random_string(length) do
    length
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(case: :lower, padding: false)
    |> String.slice(0, length)
  end
end
