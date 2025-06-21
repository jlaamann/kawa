defmodule Kawa.Utils.ApiKeyTest do
  use ExUnit.Case, async: true

  alias Kawa.Utils.ApiKey

  describe "generate/1" do
    test "generates API key for prod environment" do
      {api_key, api_key_hash, api_key_prefix} = ApiKey.generate("prod")

      assert String.starts_with?(api_key, "kawa_prod_")
      assert String.length(api_key) > 20
      assert api_key_prefix == "kawa_pro"
      assert is_binary(api_key_hash)
      # SHA256 hex length
      assert String.length(api_key_hash) == 64
    end

    test "generates API key for dev environment" do
      {api_key, api_key_hash, api_key_prefix} = ApiKey.generate("dev")

      assert String.starts_with?(api_key, "kawa_dev_")
      assert api_key_prefix == "kawa_dev"
      assert is_binary(api_key_hash)
    end

    test "generates API key for staging environment" do
      {api_key, api_key_hash, api_key_prefix} = ApiKey.generate("staging")

      assert String.starts_with?(api_key, "kawa_staging_")
      assert api_key_prefix == "kawa_sta"
      assert is_binary(api_key_hash)
    end

    test "generates unique API keys on each call" do
      {api_key1, hash1, _} = ApiKey.generate("prod")
      {api_key2, hash2, _} = ApiKey.generate("prod")

      refute api_key1 == api_key2
      refute hash1 == hash2
    end

    test "generates API key with expected format" do
      {api_key, _hash, _prefix} = ApiKey.generate("test")

      # Should be: kawa_test_{32_char_random}
      parts = String.split(api_key, "_")
      assert length(parts) == 3
      assert Enum.at(parts, 0) == "kawa"
      assert Enum.at(parts, 1) == "test"
      assert String.length(Enum.at(parts, 2)) == 32
    end
  end

  describe "validate/2" do
    test "validates correct API key" do
      {api_key, api_key_hash, _prefix} = ApiKey.generate("prod")

      assert ApiKey.validate(api_key, api_key_hash) == true
    end

    test "rejects incorrect API key" do
      {_api_key, api_key_hash, _prefix} = ApiKey.generate("prod")
      wrong_key = "kawa_prod_wrongkey123456789012345"

      assert ApiKey.validate(wrong_key, api_key_hash) == false
    end

    test "rejects API key with wrong hash" do
      {api_key, _api_key_hash, _prefix} = ApiKey.generate("prod")
      wrong_hash = "incorrect_hash"

      assert ApiKey.validate(api_key, wrong_hash) == false
    end
  end

  describe "extract_environment/1" do
    test "extracts environment from valid API key" do
      assert ApiKey.extract_environment("kawa_prod_abc123") == {:ok, "prod"}
      assert ApiKey.extract_environment("kawa_dev_xyz789") == {:ok, "dev"}
      assert ApiKey.extract_environment("kawa_staging_test") == {:ok, "staging"}
    end

    test "returns error for invalid API key format" do
      assert ApiKey.extract_environment("invalid_key") == {:error, :invalid_format}
      assert ApiKey.extract_environment("kawa_only") == {:error, :invalid_format}
      assert ApiKey.extract_environment("not_kawa_format") == {:error, :invalid_format}
      assert ApiKey.extract_environment("") == {:error, :invalid_format}
    end

    test "handles API key with underscores in random part" do
      assert ApiKey.extract_environment("kawa_prod_abc_def_123") == {:ok, "prod"}
    end
  end
end
