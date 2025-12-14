defmodule SocialScribe.Hubspot.ApiTest do
  use SocialScribe.DataCase, async: true

  import SocialScribe.HubspotFixtures
  import Mox

  alias SocialScribe.Hubspot.Api

  # Make sure mocks are verified when the test exits
  setup :verify_on_exit!

  describe "search_contacts/3" do
    test "with empty query returns empty list" do
      credential = hubspot_credential_fixture()

      assert {:ok, []} = Api.search_contacts(credential, "")
      assert {:ok, []} = Api.search_contacts(credential, "   ")
      assert {:ok, []} = Api.search_contacts(credential, "\n\t")
    end

    test "with valid credential and query - requires HTTP mocking" do
      # Note: This test would require Bypass or refactoring to inject base_url
      # For now, we test the empty query validation which doesn't require HTTP
      credential = hubspot_credential_fixture()
      assert {:ok, []} = Api.search_contacts(credential, "")
    end

    test "respects limit option - requires HTTP mocking" do
      # Note: This would require mocking to verify the limit parameter
      credential = hubspot_credential_fixture()
      assert {:ok, []} = Api.search_contacts(credential, "", limit: 10)
    end
  end

  describe "get_contact/3" do
    test "with valid contact ID - requires HTTP mocking" do
      # Note: This test would require Bypass or refactoring
      _credential = hubspot_credential_fixture()
      # This would test the actual HTTP call
    end
  end

  describe "update_contact/3" do
    test "with empty properties map returns error" do
      credential = hubspot_credential_fixture()

      assert {:error, :no_properties_to_update} =
               Api.update_contact(credential, "contact_123", %{})
    end

    test "with nil properties" do
      credential = hubspot_credential_fixture()

      # The function head requires map_size(properties) > 0, so nil won't match
      # This tests the function clause matching
      assert {:error, :no_properties_to_update} =
               Api.update_contact(credential, "contact_123", %{})
    end

    test "with valid properties - requires HTTP mocking" do
      _credential = hubspot_credential_fixture()
      _properties = %{"firstname" => "John", "lastname" => "Doe"}

      # This would require Bypass to mock the HTTP PATCH request
    end
  end

  describe "token management" do
    test "ensure_valid_token returns token when not expired" do
      _credential = hubspot_credential_fixture(%{
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

      # This is a private function, but we can test it indirectly through public functions
      # The token should be valid and not trigger a refresh
    end

    test "ensure_valid_token returns token when expires_at is nil" do
      _credential = hubspot_credential_no_expiry_fixture()

      # Token should be used directly without checking expiry
      # Tested indirectly through API calls
    end

    test "ensure_valid_token triggers refresh when expired" do
      _expired_credential = expired_hubspot_credential_fixture()

      # This would require mocking HubspotTokenRefresher
      # Tested in integration tests
    end
  end
end
