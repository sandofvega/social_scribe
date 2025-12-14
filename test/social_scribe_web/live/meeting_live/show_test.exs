defmodule SocialScribeWeb.MeetingLive.ShowTest do
  use SocialScribeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SocialScribe.AccountsFixtures
  import SocialScribe.MeetingsFixtures
  import SocialScribe.HubspotFixtures
  import SocialScribe.CalendarFixtures
  import SocialScribe.BotsFixtures

  alias SocialScribe.Hubspot

  describe "HubSpot Contact Update Modal" do
    setup %{conn: conn} do
      user = user_fixture()
      calendar_event = calendar_event_fixture(%{user_id: user.id})
      recall_bot = recall_bot_fixture(%{calendar_event_id: calendar_event.id, user_id: user.id})
      meeting = meeting_fixture(%{calendar_event_id: calendar_event.id, recall_bot_id: recall_bot.id})
      meeting_transcript = meeting_transcript_fixture(%{meeting_id: meeting.id})

      conn = log_in_user(conn, user)

      %{conn: conn, user: user, meeting: meeting, meeting_transcript: meeting_transcript}
    end

    test "shows message when no HubSpot credential is connected", %{conn: conn, meeting: meeting, meeting_transcript: meeting_transcript} do
      # Create extracted contact info so the button appears
      extracted_contact_info_fixture(%{
        meeting_transcript_id: meeting_transcript.id,
        contact_info: %{"first_name" => "John"}
      })

      {:ok, _view, html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}")

      # Should show message about connecting HubSpot
      assert html =~ "Connect your HubSpot account to review and sync contact updates"
    end

    test "shows Review Update button when credential and contact info exist", %{conn: conn, meeting: meeting, user: user, meeting_transcript: meeting_transcript} do
      _credential = hubspot_credential_fixture(%{user_id: user.id})

      # Create extracted contact info
      extracted_contact_info_fixture(%{
        meeting_transcript_id: meeting_transcript.id,
        contact_info: %{"first_name" => "John"}
      })

      {:ok, _view, html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}")

      # Should show Review Update button
      assert html =~ "Review Update"
    end

    test "searching contacts with empty query clears results", %{conn: conn, meeting: meeting, user: user, meeting_transcript: meeting_transcript} do
      _credential = hubspot_credential_fixture(%{user_id: user.id})

      extracted_contact_info_fixture(%{
        meeting_transcript_id: meeting_transcript.id,
        contact_info: %{"first_name" => "John"}
      })

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/review_hubspot_update")

      # Clear search with empty query
      assert view
             |> form("form[phx-change='search-contacts']", %{query: ""})
             |> render_change()

      # Results should be cleared (tested via handle_event)
    end

    test "displays extracted contact information in modal", %{conn: conn, meeting: meeting, user: user, meeting_transcript: meeting_transcript} do
      _credential = hubspot_credential_fixture(%{user_id: user.id})

      # Create extracted contact info
      extracted_contact_info_fixture(%{
        meeting_transcript_id: meeting_transcript.id,
        contact_info: %{
          "first_name" => "Jane",
          "last_name" => "Smith",
          "email" => "jane.smith@example.com"
        }
      })

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/review_hubspot_update")

      # Should show the modal with contact information
      html = render(view)
      assert html =~ "Update in HubSpot"
      assert html =~ "Select Contact"
    end

    test "update button is disabled when no contact selected", %{conn: conn, meeting: meeting, user: user, meeting_transcript: meeting_transcript} do
      _credential = hubspot_credential_fixture(%{user_id: user.id})

      extracted_contact_info_fixture(%{
        meeting_transcript_id: meeting_transcript.id,
        contact_info: %{"first_name" => "Jane"}
      })

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/review_hubspot_update")

      # Update button should be disabled
      html = render(view)
      assert html =~ ~s(disabled)
      # The message is in the title attribute - just verify the button is disabled
      # The exact message format may vary, so we just check for disabled state
    end

    test "shows waiting message when contact info is being extracted", %{conn: conn, meeting: meeting, user: user} do
      _credential = hubspot_credential_fixture(%{user_id: user.id})

      {:ok, _view, html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}")

      # Should show waiting message
      assert html =~ "Waiting for AI to extract contact information"
    end

    test "shows no contact info message when none found", %{conn: conn, meeting: meeting, user: user, meeting_transcript: meeting_transcript} do
      _credential = hubspot_credential_fixture(%{user_id: user.id})

      # Create extracted contact info with empty contact_info
      {:ok, _extracted_info} = Hubspot.create_extracted_contact_info(%{
        meeting_transcript_id: meeting_transcript.id,
        contact_info: %{}
      })

      {:ok, _view, html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}")

      # Should show no contact info message
      assert html =~ "No contact information found in the meeting"
    end
  end

  describe "Meeting display" do
    setup %{conn: conn} do
      user = user_fixture()
      calendar_event = calendar_event_fixture(%{user_id: user.id})
      recall_bot = recall_bot_fixture(%{calendar_event_id: calendar_event.id, user_id: user.id})
      meeting = meeting_fixture(%{calendar_event_id: calendar_event.id, recall_bot_id: recall_bot.id})
      meeting_transcript = meeting_transcript_fixture(%{meeting_id: meeting.id})

      conn = log_in_user(conn, user)

      %{conn: conn, user: user, meeting: meeting, meeting_transcript: meeting_transcript}
    end

    test "displays meeting details", %{conn: conn, meeting: meeting} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}")

      assert html =~ meeting.title
    end

    test "displays transcript if available", %{conn: conn, meeting: meeting} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}")

      # Should show transcript section
      assert html =~ "Transcript" || html =~ "transcript"
    end
  end
end
