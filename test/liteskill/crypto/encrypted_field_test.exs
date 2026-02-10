defmodule Liteskill.Crypto.EncryptedFieldTest do
  use ExUnit.Case, async: true

  alias Liteskill.Crypto.EncryptedField

  describe "type/0" do
    test "returns :string" do
      assert EncryptedField.type() == :string
    end
  end

  describe "cast/1" do
    test "casts nil" do
      assert {:ok, nil} = EncryptedField.cast(nil)
    end

    test "casts binary string" do
      assert {:ok, "my-key"} = EncryptedField.cast("my-key")
    end

    test "rejects non-binary" do
      assert :error = EncryptedField.cast(123)
    end
  end

  describe "dump/1" do
    test "dumps nil as nil" do
      assert {:ok, nil} = EncryptedField.dump(nil)
    end

    test "dumps string as encrypted ciphertext" do
      {:ok, dumped} = EncryptedField.dump("secret-key")
      assert is_binary(dumped)
      refute dumped == "secret-key"
      # Should be base64 encoded
      assert {:ok, _} = Base.decode64(dumped)
    end

    test "rejects non-binary" do
      assert :error = EncryptedField.dump(123)
    end
  end

  describe "load/1" do
    test "loads nil as nil" do
      assert {:ok, nil} = EncryptedField.load(nil)
    end

    test "round-trips through dump and load" do
      {:ok, encrypted} = EncryptedField.dump("my-api-key")
      assert {:ok, "my-api-key"} = EncryptedField.load(encrypted)
    end

    test "returns error for garbage input" do
      assert :error = EncryptedField.load("not-encrypted-data")
    end

    test "rejects non-binary" do
      assert :error = EncryptedField.load(123)
    end
  end
end
