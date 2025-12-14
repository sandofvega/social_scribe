defmodule SocialScribe.HubspotFixtures do
  @moduledoc """
  Test fixtures for HubSpot-related entities.
  """

  import SocialScribe.AccountsFixtures

  @doc """
  Creates a HubSpot user credential fixture with valid token.
  """
  def hubspot_credential_fixture(attrs \\ %{}) do
    user_id = attrs[:user_id] || user_fixture().id

    user_credential_fixture(
      attrs
      |> Enum.into(%{
        user_id: user_id,
        provider: "hubspot",
        token: "test_access_token_#{System.unique_integer()}",
        refresh_token: "test_refresh_token_#{System.unique_integer()}",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        uid: "hubspot_uid_#{System.unique_integer()}",
        email: "test@example.com"
      })
    )
  end

  @doc """
  Creates a HubSpot user credential fixture with expired token.
  """
  def expired_hubspot_credential_fixture(attrs \\ %{}) do
    user_id = attrs[:user_id] || user_fixture().id

    user_credential_fixture(
      attrs
      |> Enum.into(%{
        user_id: user_id,
        provider: "hubspot",
        token: "expired_token_#{System.unique_integer()}",
        refresh_token: "test_refresh_token_#{System.unique_integer()}",
        expires_at: DateTime.add(DateTime.utc_now(), -3600, :second),
        uid: "hubspot_uid_#{System.unique_integer()}",
        email: "test@example.com"
      })
    )
  end

  @doc """
  Creates a HubSpot user credential fixture without expires_at.
  """
  def hubspot_credential_no_expiry_fixture(attrs \\ %{}) do
    user_id = attrs[:user_id] || user_fixture().id

    user_credential_fixture(
      attrs
      |> Enum.into(%{
        user_id: user_id,
        provider: "hubspot",
        token: "test_access_token_#{System.unique_integer()}",
        refresh_token: "test_refresh_token_#{System.unique_integer()}",
        expires_at: nil,
        uid: "hubspot_uid_#{System.unique_integer()}",
        email: "test@example.com"
      })
    )
  end

  @doc """
  Creates a mock HubSpot contact response.
  """
  def mock_hubspot_contact(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      "id" => "contact_#{System.unique_integer()}",
      "properties" => %{
        "firstname" => "John",
        "lastname" => "Doe",
        "email" => "john.doe@example.com",
        "phone" => "+1234567890",
        "city" => "San Francisco",
        "state" => "CA",
        "country" => "United States",
        "zip" => "94102",
        "jobtitle" => "Software Engineer",
        "company" => "Example Corp"
      }
    })
  end

  @doc """
  Creates a mock HubSpot contact search results.
  """
  def mock_hubspot_contact_search_results(count \\ 1) do
    1..count
    |> Enum.map(fn i ->
      mock_hubspot_contact(%{
        "id" => "contact_#{i}",
        "properties" => %{
          "firstname" => "John#{i}",
          "lastname" => "Doe#{i}",
          "email" => "john#{i}@example.com"
        }
      })
    end)
  end

  @doc """
  Creates extracted contact information fixture.
  """
  def extracted_contact_info_fixture(attrs \\ %{}) do
    import SocialScribe.MeetingsFixtures

    meeting_transcript_id =
      attrs[:meeting_transcript_id] ||
        meeting_transcript_fixture().id

    contact_info = attrs[:contact_info] || %{
      "first_name" => "Jane",
      "last_name" => "Smith",
      "email" => "jane.smith@example.com",
      "phone_number" => "+1987654321"
    }

    {:ok, extracted_info} =
      SocialScribe.Hubspot.create_extracted_contact_info(%{
        meeting_transcript_id: meeting_transcript_id,
        contact_info: contact_info
      })

    extracted_info
  end
end
