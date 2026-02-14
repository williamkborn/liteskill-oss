defmodule Liteskill.LlmProvidersTest do
  use Liteskill.DataCase, async: true

  alias Liteskill.Authorization
  alias Liteskill.Authorization.EntityAcl
  alias Liteskill.LlmProviders
  alias Liteskill.LlmProviders.LlmProvider

  import Ecto.Query

  setup do
    {:ok, admin} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "admin-#{System.unique_integer([:positive])}@example.com",
        name: "Admin",
        oidc_sub: "admin-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, other} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "other-#{System.unique_integer([:positive])}@example.com",
        name: "Other",
        oidc_sub: "other-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{admin: admin, other: other}
  end

  defp valid_attrs(user_id) do
    %{
      name: "AWS Bedrock US-East",
      provider_type: "amazon_bedrock",
      user_id: user_id
    }
  end

  # --- Changeset ---

  describe "LlmProvider changeset" do
    test "valid changeset with required fields", %{admin: admin} do
      changeset = LlmProvider.changeset(%LlmProvider{}, valid_attrs(admin.id))
      assert changeset.valid?
    end

    test "invalid without name", %{admin: admin} do
      attrs = valid_attrs(admin.id) |> Map.delete(:name)
      changeset = LlmProvider.changeset(%LlmProvider{}, attrs)
      refute changeset.valid?
    end

    test "invalid without provider_type", %{admin: admin} do
      attrs = valid_attrs(admin.id) |> Map.delete(:provider_type)
      changeset = LlmProvider.changeset(%LlmProvider{}, attrs)
      refute changeset.valid?
    end

    test "invalid provider_type rejected", %{admin: admin} do
      attrs = valid_attrs(admin.id) |> Map.put(:provider_type, "invalid_type")
      changeset = LlmProvider.changeset(%LlmProvider{}, attrs)
      refute changeset.valid?
    end

    test "invalid status rejected", %{admin: admin} do
      attrs = valid_attrs(admin.id) |> Map.put(:status, "deleted")
      changeset = LlmProvider.changeset(%LlmProvider{}, attrs)
      refute changeset.valid?
    end

    test "valid_provider_types includes all ReqLLM providers" do
      types = LlmProvider.valid_provider_types()
      # Dynamically sourced from ReqLLM — includes 50+ providers
      assert length(types) >= 50
      # Key providers present
      assert "amazon_bedrock" in types
      assert "anthropic" in types
      assert "openai" in types
      assert "google" in types
      assert "groq" in types
      assert "azure" in types
      assert "cerebras" in types
      assert "xai" in types
      assert "openrouter" in types
      assert "vllm" in types
      assert "deepseek" in types
    end
  end

  # --- CRUD ---

  describe "create_provider/1" do
    test "creates provider with valid attrs and owner ACL", %{admin: admin} do
      assert {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))
      assert provider.name == "AWS Bedrock US-East"
      assert provider.provider_type == "amazon_bedrock"
      assert provider.status == "active"
      assert provider.instance_wide == false

      acl =
        Repo.one(
          from a in EntityAcl,
            where: a.entity_type == "llm_provider" and a.entity_id == ^provider.id
        )

      assert acl.user_id == admin.id
      assert acl.role == "owner"
    end

    test "creates provider with all optional fields", %{admin: admin} do
      attrs =
        valid_attrs(admin.id)
        |> Map.merge(%{
          api_key: "secret-api-key",
          provider_config: %{"region" => "us-west-2"},
          instance_wide: true,
          status: "inactive"
        })

      assert {:ok, provider} = LlmProviders.create_provider(attrs)
      assert provider.api_key == "secret-api-key"
      assert provider.provider_config == %{"region" => "us-west-2"}
      assert provider.instance_wide == true
      assert provider.status == "inactive"
    end

    test "fails with invalid attrs", %{admin: admin} do
      attrs = valid_attrs(admin.id) |> Map.delete(:name)
      assert {:error, _changeset} = LlmProviders.create_provider(attrs)
    end
  end

  describe "update_provider/3" do
    test "owner can update provider", %{admin: admin} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      assert {:ok, updated} =
               LlmProviders.update_provider(provider.id, admin.id, %{name: "Updated Name"})

      assert updated.name == "Updated Name"
    end

    test "non-owner cannot update provider", %{admin: admin, other: other} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      assert {:error, :forbidden} =
               LlmProviders.update_provider(provider.id, other.id, %{name: "Hacked"})
    end

    test "returns not_found for missing provider", %{admin: admin} do
      assert {:error, :not_found} =
               LlmProviders.update_provider(Ecto.UUID.generate(), admin.id, %{name: "X"})
    end
  end

  describe "delete_provider/2" do
    test "owner can delete provider", %{admin: admin} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      assert {:ok, _} = LlmProviders.delete_provider(provider.id, admin.id)
      assert Repo.get(LlmProvider, provider.id) == nil
    end

    test "non-owner cannot delete provider", %{admin: admin, other: other} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      assert {:error, :forbidden} = LlmProviders.delete_provider(provider.id, other.id)
    end

    test "returns not_found for missing provider", %{admin: admin} do
      assert {:error, :not_found} = LlmProviders.delete_provider(Ecto.UUID.generate(), admin.id)
    end
  end

  # --- Queries ---

  describe "list_providers/1" do
    test "returns own providers", %{admin: admin} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      providers = LlmProviders.list_providers(admin.id)
      assert length(providers) == 1
      assert hd(providers).id == provider.id
    end

    test "returns instance_wide providers to other users", %{admin: admin, other: other} do
      attrs = valid_attrs(admin.id) |> Map.put(:instance_wide, true)
      {:ok, _} = LlmProviders.create_provider(attrs)

      providers = LlmProviders.list_providers(other.id)
      assert length(providers) == 1
    end

    test "does not return non-instance_wide providers to other users", %{
      admin: admin,
      other: other
    } do
      {:ok, _} = LlmProviders.create_provider(valid_attrs(admin.id))

      providers = LlmProviders.list_providers(other.id)
      assert providers == []
    end

    test "returns ACL-shared providers", %{admin: admin, other: other} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      {:ok, _} =
        Authorization.grant_access("llm_provider", provider.id, admin.id, other.id, "viewer")

      providers = LlmProviders.list_providers(other.id)
      assert length(providers) == 1
    end

    test "returns providers ordered by name", %{admin: admin} do
      {:ok, _} =
        LlmProviders.create_provider(valid_attrs(admin.id) |> Map.put(:name, "Zzz Provider"))

      {:ok, _} =
        LlmProviders.create_provider(valid_attrs(admin.id) |> Map.put(:name, "Aaa Provider"))

      providers = LlmProviders.list_providers(admin.id)
      assert length(providers) == 2
      assert hd(providers).name == "Aaa Provider"
    end
  end

  describe "get_provider/2" do
    test "owner can get provider", %{admin: admin} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      assert {:ok, fetched} = LlmProviders.get_provider(provider.id, admin.id)
      assert fetched.id == provider.id
    end

    test "instance_wide provider accessible to all", %{admin: admin, other: other} do
      attrs = valid_attrs(admin.id) |> Map.put(:instance_wide, true)
      {:ok, provider} = LlmProviders.create_provider(attrs)

      assert {:ok, _} = LlmProviders.get_provider(provider.id, other.id)
    end

    test "ACL-shared provider accessible", %{admin: admin, other: other} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      {:ok, _} =
        Authorization.grant_access("llm_provider", provider.id, admin.id, other.id, "viewer")

      assert {:ok, _} = LlmProviders.get_provider(provider.id, other.id)
    end

    test "returns not_found for unauthorized user", %{admin: admin, other: other} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      assert {:error, :not_found} = LlmProviders.get_provider(provider.id, other.id)
    end

    test "returns not_found for missing provider", %{admin: admin} do
      assert {:error, :not_found} = LlmProviders.get_provider(Ecto.UUID.generate(), admin.id)
    end
  end

  describe "get_provider!/1" do
    test "returns provider by id", %{admin: admin} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      fetched = LlmProviders.get_provider!(provider.id)
      assert fetched.id == provider.id
    end
  end

  # --- Encrypted fields round-trip ---

  describe "encrypted fields" do
    test "api_key is encrypted and decrypted", %{admin: admin} do
      attrs = valid_attrs(admin.id) |> Map.put(:api_key, "super-secret-key-123")
      {:ok, provider} = LlmProviders.create_provider(attrs)

      reloaded = Repo.get!(LlmProvider, provider.id)
      assert reloaded.api_key == "super-secret-key-123"
    end

    test "provider_config is encrypted and decrypted", %{admin: admin} do
      config = %{"region" => "eu-west-1", "custom_field" => "value"}
      attrs = valid_attrs(admin.id) |> Map.put(:provider_config, config)
      {:ok, provider} = LlmProviders.create_provider(attrs)

      reloaded = Repo.get!(LlmProvider, provider.id)
      assert reloaded.provider_config == config
    end
  end
end
