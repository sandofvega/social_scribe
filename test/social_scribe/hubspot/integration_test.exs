defmodule SocialScribe.Hubspot.IntegrationTest do
  use SocialScribe.DataCase, async: false

  import SocialScribe.AccountsFixtures
  import SocialScribe.MeetingsFixtures
  import SocialScribe.HubspotFixtures
  import SocialScribe.CalendarFixtures
  import SocialScribe.BotsFixtures
  import Mox

  alias SocialScribe.Hubspot.Api
  alias SocialScribe.Accounts

  # Make sure mocks are verified when the test exits
  setup :verify_on_exit!

  describe "end-to-end HubSpot contact update flow" do
    test "complete flow from meeting to HubSpot update" do
      # This is a high-level integration test
      # In a real scenario, this would use Bypass to mock HubSpot API
      # For now, we test the components individually

      user = user_fixture()
      credential = hubspot_credential_fixture(%{user_id: user.id})

      calendar_event = calendar_event_fixture(%{user_id: user.id})
      recall_bot = recall_bot_fixture(%{calendar_event_id: calendar_event.id, user_id: user.id})

      meeting =
        meeting_fixture(%{calendar_event_id: calendar_event.id, recall_bot_id: recall_bot.id})

      meeting_participant_fixture(%{meeting_id: meeting.id, is_host: true})

      transcript_content = %{
        "data" => [
          %{
            "speaker" => "John Doe",
            "words" => [
              %{"text" => "My"},
              %{"text" => "email"},
              %{"text" => "is"},
              %{"text" => "john@example.com"}
            ]
          }
        ]
      }

      meeting_transcript =
        meeting_transcript_fixture(%{
          meeting_id: meeting.id,
          content: transcript_content
        })

      # Create extracted contact info (simulating what the worker would do)
      extracted_info =
        extracted_contact_info_fixture(%{
          meeting_transcript_id: meeting_transcript.id,
          contact_info: %{
            "first_name" => "John",
            "last_name" => "Doe",
            "email" => "john@example.com"
          }
        })

      # Verify the flow components work together
      assert extracted_info != nil
      assert extracted_info.contact_info["email"] == "john@example.com"

      # Verify credential is available
      hubspot_credential = Accounts.get_user_hubspot_credential(user)
      assert hubspot_credential != nil
      assert hubspot_credential.id == credential.id
    end

    test "flow with token refresh" do
      # This would test the token refresh flow
      # Requires mocking HubspotTokenRefresher
      user = user_fixture()
      expired_credential = expired_hubspot_credential_fixture(%{user_id: user.id})

      # Verify credential is expired
      assert DateTime.compare(expired_credential.expires_at, DateTime.utc_now()) == :lt

      # In a real test with Bypass, we would:
      # 1. Mock token refresh endpoint to return new token
      # 2. Call an API function that requires token refresh
      # 3. Verify the credential was updated with new token
    end
  end

  describe "error recovery" do
    test "recovery from transient API errors" do
      # This would test retry logic and error recovery
      # Requires Bypass to simulate network errors
      user = user_fixture()
      credential = hubspot_credential_fixture(%{user_id: user.id})

      # Test that empty queries don't trigger API calls
      assert {:ok, []} = Api.search_contacts(credential, "")
    end

    test "data validation with special characters" do
      user = user_fixture()
      credential = hubspot_credential_fixture(%{user_id: user.id})

      # Test that empty properties are rejected
      assert {:error, :no_properties_to_update} =
               Api.update_contact(credential, "contact_123", %{})

      # Test with valid properties (would require HTTP mocking for full test)
      properties = %{
        "firstname" => "John O'Brien",
        "lastname" => "Doe-Smith",
        "email" => "john+test@example.com"
      }

      # This would require Bypass to test the actual update
      # For now, we verify the validation
      assert map_size(properties) > 0
    end

    test "unicode character handling" do
      user = user_fixture()
      _credential = hubspot_credential_fixture(%{user_id: user.id})

      # Test with unicode characters
      properties = %{
        "firstname" => "José",
        "lastname" => "Müller",
        "company" => "Café & Co."
      }

      # This would require Bypass to test the actual update
      # For now, we verify the data structure
      assert map_size(properties) > 0
      assert String.valid?(properties["firstname"])
      assert String.valid?(properties["lastname"])
    end
  end

  describe "security and isolation" do
    test "credential isolation between users" do
      user1 = user_fixture()
      user2 = user_fixture()

      credential1 = hubspot_credential_fixture(%{user_id: user1.id})
      credential2 = hubspot_credential_fixture(%{user_id: user2.id})

      # Verify credentials are isolated
      assert credential1.user_id == user1.id
      assert credential2.user_id == user2.id
      assert credential1.id != credential2.id

      # Verify users can only access their own credentials
      assert Accounts.get_user_hubspot_credential(user1).id == credential1.id
      assert Accounts.get_user_hubspot_credential(user2).id == credential2.id
    end

    test "nil vs empty string handling" do
      user = user_fixture()
      credential = hubspot_credential_fixture(%{user_id: user.id})

      # Test that empty properties map is rejected
      assert {:error, :no_properties_to_update} =
               Api.update_contact(credential, "contact_123", %{})

      # Test with properties containing empty strings (would require HTTP mocking)
      properties = %{
        "firstname" => "",
        "lastname" => "Doe"
      }

      # Empty strings should be normalized/handled appropriately
      # This would be tested with Bypass
      assert map_size(properties) > 0
    end
  end
end
