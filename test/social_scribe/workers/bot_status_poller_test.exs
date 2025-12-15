defmodule SocialScribe.Workers.BotStatusPollerTest do
  use SocialScribe.DataCase, async: true

  import Mox
  import SocialScribe.AccountsFixtures
  import SocialScribe.CalendarFixtures
  import SocialScribe.BotsFixtures
  import SocialScribe.MeetingInfoExample
  import SocialScribe.MeetingTranscriptExample

  alias SocialScribe.Workers.BotStatusPoller
  alias SocialScribe.RecallApiMock
  alias SocialScribe.AIContentGeneratorMock, as: AIGeneratorMock
  alias SocialScribe.Bots
  alias SocialScribe.Meetings

  @mock_bot_api_info_pending %{
    id: "bot-pending-123",
    metadata: %{},
    meeting_url: %{meeting_id: "jqq-gusf-vvs", platform: "google_meet"},
    status_changes: [
      %{
        code: "ready",
        message: nil,
        created_at: "2025-05-24T12:04:15.203706Z",
        sub_code: nil
      },
      %{
        code: "joining_call",
        message: nil,
        created_at: "2025-05-24T23:13:01.665225Z",
        sub_code: nil
      },
      %{
        code: "in_waiting_room",
        message: nil,
        created_at: "2025-05-24T23:13:12.782221Z",
        sub_code: nil
      },
      %{
        code: "in_call_not_recording",
        message: nil,
        created_at: "2025-05-24T23:13:26.987838Z",
        sub_code: nil
      },
      %{
        code: "in_call_recording",
        message: nil,
        created_at: "2025-05-24T23:13:27.113531Z",
        sub_code: nil
      }
    ],
    join_at: "2025-05-24T23:13:00Z",
    transcription_options: %{
      provider: "meeting_captions",
      use_separate_streams_when_available: false
    },
    bot_name: "Meeting Notetaker",
    media_retention_end: "2025-05-31T23:16:23.890255Z",
    meeting_metadata: %{title: "jqq-gusf-vvs"},
    meeting_participants: []
  }

  @mock_bot_api_info_done meeting_info_example(%{id: "bot-done-456"})
  @mock_transcript_data meeting_transcript_example()
  @mock_transcript_payload @mock_transcript_data |> Jason.encode!() |> Jason.decode!()
  @mock_participants_payload @mock_bot_api_info_done.meeting_participants
                             |> Jason.encode!()
                             |> Jason.decode!()
  @mock_recording List.first(@mock_bot_api_info_done.recordings)
  @mock_transcript_download_url get_in(@mock_recording, [
                                  :media_shortcuts,
                                  :transcript,
                                  :data,
                                  :download_url
                                ])
  @mock_participants_download_url get_in(@mock_recording, [
                                    :media_shortcuts,
                                    :participant_events,
                                    :data,
                                    :participants_download_url
                                  ])

  describe "perform/1" do
    setup do
      stub_with(RecallApiMock, SocialScribe.Recall)
      stub_with(AIGeneratorMock, SocialScribe.AIContentGenerator)
      :ok
    end

    test "does nothing if there are no pending bots" do
      assert Bots.list_pending_bots() == []

      assert BotStatusPoller.perform(%Oban.Job{}) == :ok
    end

    test "polls a pending bot and updates its status if not 'done'" do
      user = user_fixture()
      calendar_event = calendar_event_fixture(%{user_id: user.id})

      bot_record =
        recall_bot_fixture(%{
          user_id: user.id,
          calendar_event_id: calendar_event.id,
          recall_bot_id: "bot-pending-123",
          status: "in_call_not_recording"
        })

      expect(RecallApiMock, :get_bot, fn "bot-pending-123" ->
        {:ok, %Tesla.Env{body: @mock_bot_api_info_pending}}
      end)

      assert BotStatusPoller.perform(%Oban.Job{}) == :ok

      updated_bot = Bots.get_recall_bot!(bot_record.id)
      assert updated_bot.status == "in_call_recording"

      assert Meetings.get_meeting_by_recall_bot_id(updated_bot.id) == nil
    end

    test "polls a bot, finds it 'done', fetches transcript, and creates meeting records" do
      user = user_fixture()
      calendar_event = calendar_event_fixture(%{user_id: user.id})

      bot_record =
        recall_bot_fixture(%{
          user_id: user.id,
          calendar_event_id: calendar_event.id,
          recall_bot_id: "bot-done-456",
          status: "recording_done"
        })

      # Expect API call to get bot status
      expect(RecallApiMock, :get_bot, fn "bot-done-456" ->
        # Returns "done"
        {:ok, %Tesla.Env{body: @mock_bot_api_info_done}}
      end)

      expect(RecallApiMock, :download_json_from_url, 2, fn url ->
        cond do
          url == @mock_transcript_download_url ->
            {:ok, @mock_transcript_payload}

          url == @mock_participants_download_url ->
            {:ok, @mock_participants_payload}

          true ->
            flunk("Unexpected download url #{inspect(url)}")
        end
      end)

      expect(AIGeneratorMock, :generate_follow_up_email, fn _meeting ->
        {:ok, "Follow-up email draft"}
      end)

      assert BotStatusPoller.perform(%Oban.Job{}) == :ok

      # Verify bot status was updated
      updated_bot = Bots.get_recall_bot!(bot_record.id)
      assert updated_bot.status == "done"

      meeting = Meetings.get_meeting_by_recall_bot_id(updated_bot.id)
      assert meeting.title == calendar_event.summary

      transcript_record = Repo.get_by!(Meetings.MeetingTranscript, meeting_id: meeting.id)

      assert transcript_record.content["data"] == @mock_transcript_payload

      meeting_id = meeting.id

      participants =
        Repo.all(from p in Meetings.MeetingParticipant, where: p.meeting_id == ^meeting_id)

      assert Enum.count(participants) == 1
      assert List.first(participants).name == "Felipe Gomes Paradas"
      assert List.first(participants).recall_participant_id == "100"
      assert List.first(participants).is_host == true

      # Assert AI content generation worker was enqueued
      assert_enqueued(
        worker: SocialScribe.Workers.AIContentGenerationWorker,
        args: %{"meeting_id" => meeting.id}
      )
    end

    test "polls a bot, finds it 'done', but does not re-create meeting if it already exists" do
      user = user_fixture()
      calendar_event = calendar_event_fixture(%{user_id: user.id})

      bot_record =
        recall_bot_fixture(%{
          user_id: user.id,
          calendar_event_id: calendar_event.id,
          recall_bot_id: "bot-already-processed-789",
          status: "call_ended"
        })

      # Pre-create a meeting record for this bot
      Meetings.create_meeting_from_recall_data(
        bot_record,
        @mock_bot_api_info_done,
        @mock_transcript_payload,
        @mock_participants_payload
      )

      # Expect API call to get bot status
      expect(RecallApiMock, :get_bot, fn "bot-already-processed-789" ->
        # Simulate Recall API still reporting it as "done"
        {:ok,
         %Tesla.Env{body: Map.put(@mock_bot_api_info_done, "id", "bot-already-processed-789")}}
      end)

      # CRUCIALLY: Do NOT expect download_json_from_url to be called again
      # Mox will verify this implicitly. If it were called, the test would fail
      # because there's no matching `expect` for it in this test case.

      assert BotStatusPoller.perform(%Oban.Job{}) == :ok

      updated_bot = Bots.get_recall_bot!(bot_record.id)
      # Status is updated
      assert updated_bot.status == "done"

      bot_record_id = bot_record.id
      # Ensure no new meeting records were created (count should remain 1)
      meetings_for_bot =
        Repo.all(from m in Meetings.Meeting, where: m.recall_bot_id == ^bot_record_id)

      assert Enum.count(meetings_for_bot) == 1
    end

    test "handles API error when polling bot status and updates bot to 'polling_error'" do
      user = user_fixture()
      calendar_event = calendar_event_fixture(%{user_id: user.id})

      bot_record =
        recall_bot_fixture(%{
          user_id: user.id,
          calendar_event_id: calendar_event.id,
          recall_bot_id: "bot-api-error-000",
          status: "joining_call"
        })

      # Expect API call to get bot status to fail
      expect(RecallApiMock, :get_bot, fn "bot-api-error-000" ->
        {:error, :timeout}
      end)

      assert BotStatusPoller.perform(%Oban.Job{}) == :ok

      # Verify bot status was updated to 'polling_error'
      updated_bot = Bots.get_recall_bot!(bot_record.id)
      assert updated_bot.status == "polling_error"
    end

    test "handles API error when downloading transcript data after bot is 'done'" do
      user = user_fixture()
      calendar_event = calendar_event_fixture(%{user_id: user.id})

      bot_record =
        recall_bot_fixture(%{
          user_id: user.id,
          calendar_event_id: calendar_event.id,
          recall_bot_id: "bot-transcript-error-111",
          status: "recording_done"
        })

      # Expect API call to get bot status (returns "done")
      expect(RecallApiMock, :get_bot, fn "bot-transcript-error-111" ->
        {:ok,
         %Tesla.Env{body: Map.put(@mock_bot_api_info_done, "id", "bot-transcript-error-111")}}
      end)

      # Expect transcript download to FAIL
      expect(RecallApiMock, :download_json_from_url, fn url ->
        assert url == @mock_transcript_download_url
        {:error, :transcript_fetch_failed}
      end)

      assert BotStatusPoller.perform(%Oban.Job{}) == :ok

      # Bot status should still be "done" because the get_bot call succeeded
      updated_bot = Bots.get_recall_bot!(bot_record.id)
      assert updated_bot.status == "done"

      # No meeting record should have been created because transcript fetching failed
      assert Meetings.get_meeting_by_recall_bot_id(updated_bot.id) == nil
    end
  end
end
