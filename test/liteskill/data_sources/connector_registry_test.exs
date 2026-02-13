defmodule Liteskill.DataSources.ConnectorRegistryTest do
  use ExUnit.Case, async: true

  alias Liteskill.DataSources.ConnectorRegistry

  describe "get/1" do
    test "returns wiki connector for 'wiki' type" do
      assert {:ok, Liteskill.DataSources.Connectors.Wiki} = ConnectorRegistry.get("wiki")
    end

    test "returns google_drive connector for 'google_drive' type" do
      assert {:ok, Liteskill.DataSources.Connectors.GoogleDrive} =
               ConnectorRegistry.get("google_drive")
    end

    test "returns error for unknown type" do
      assert {:error, :unknown_connector} = ConnectorRegistry.get("nonexistent")
    end

    test "returns error for empty string" do
      assert {:error, :unknown_connector} = ConnectorRegistry.get("")
    end
  end

  describe "all/0" do
    test "returns all registered connectors" do
      all = ConnectorRegistry.all()
      assert is_list(all)
      assert {"wiki", Liteskill.DataSources.Connectors.Wiki} in all
      assert {"google_drive", Liteskill.DataSources.Connectors.GoogleDrive} in all
    end
  end
end
