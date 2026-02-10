defmodule Liteskill.CryptoTest do
  use ExUnit.Case, async: true

  alias Liteskill.Crypto

  describe "encrypt/1" do
    test "returns nil for nil input" do
      assert Crypto.encrypt(nil) == nil
    end

    test "returns nil for empty string" do
      assert Crypto.encrypt("") == nil
    end

    test "encrypts a plaintext string to base64" do
      ciphertext = Crypto.encrypt("my-secret-key")
      assert is_binary(ciphertext)
      assert {:ok, _} = Base.decode64(ciphertext)
      refute ciphertext == "my-secret-key"
    end

    test "produces different ciphertexts for same input (random IV)" do
      a = Crypto.encrypt("same-value")
      b = Crypto.encrypt("same-value")
      assert a != b
    end
  end

  describe "decrypt/1" do
    test "returns nil for nil input" do
      assert Crypto.decrypt(nil) == nil
    end

    test "round-trips through encrypt/decrypt" do
      original = "super-secret-api-key-12345"
      encrypted = Crypto.encrypt(original)
      assert Crypto.decrypt(encrypted) == original
    end

    test "returns :error for invalid base64" do
      assert Crypto.decrypt("not-valid-base64!!!") == :error
    end

    test "returns :error for tampered ciphertext" do
      encrypted = Crypto.encrypt("test-value")
      {:ok, raw} = Base.decode64(encrypted)
      # Flip a byte in the ciphertext portion
      tampered = Base.encode64(raw <> <<0>>)
      assert Crypto.decrypt(tampered) == :error
    end
  end
end
