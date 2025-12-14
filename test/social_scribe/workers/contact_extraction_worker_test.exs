defmodule SocialScribe.Workers.ContactExtractionWorkerTest do
  use SocialScribe.DataCase, async: true

  import Mox
  import SocialScribe.MeetingsFixtures
  import SocialScribe.HubspotFixtures
  import SocialScribe.CalendarFixtures
  import SocialScribe.BotsFixtures
  import SocialScribe.AccountsFixtures

  alias SocialScribe.Workers.ContactExtractionWorker
  alias SocialScribe.AIContentGeneratorMock, as: AIGeneratorMock
  alias SocialScribe.Hubspot

  # Make sure mocks are verified when the test exits
  setup :verify_on_exit!

  describe "perform/1" do
    setup do
      stub_with(AIGeneratorMock, SocialScribe.AIContentGenerator)
      :ok
    end

    test "successfully extracts contact info from transcript" do
      user = user_fixture()
      calendar_event = calendar_event_fixture(%{user_id: user.id})
      recall_bot = recall_bot_fixture(%{calendar_event_id: calendar_event.id, user_id: user.id})
      meeting = meeting_fixture(%{calendar_event_id: calendar_event.id, recall_bot_id: recall_bot.id})

      meeting_participant_fixture(%{meeting_id: meeting.id, is_host: true, name: "John Doe"})

      transcript_content = %{
        "data" => [
          %{
            "speaker" => "John Doe",
            "words" => [
              %{"text" => "Hello"},
              %{"text" => "my"},
              %{"text" => "email"},
              %{"text" => "is"},
              %{"text" => "john@example.com"}
            ]
          }
        ]
      }

      meeting_transcript = meeting_transcript_fixture(%{
        meeting_id: meeting.id,
        content: transcript_content
      })

      contact_info = %{
        "first_name" => "John",
        "last_name" => "Doe",
        "email" => "john@example.com"
      }

      expect(AIGeneratorMock, :extract_contact_information, fn transcript_text, host_names ->
        assert is_binary(transcript_text)
        assert transcript_text =~ "John Doe"
        assert "john doe" in host_names
        {:ok, contact_info}
      end)

      job_args = %{"meeting_transcript_id" => meeting_transcript.id}

      assert ContactExtractionWorker.perform(%Oban.Job{args: job_args}) == :ok

      # Verify contact info was persisted
      extracted_info = Hubspot.get_extracted_contact_info_by_transcript(meeting_transcript.id)
      assert extracted_info != nil
      assert extracted_info.contact_info == contact_info
    end

    test "handles empty transcript" do
      user = user_fixture()
      calendar_event = calendar_event_fixture(%{user_id: user.id})
      recall_bot = recall_bot_fixture(%{calendar_event_id: calendar_event.id, user_id: user.id})
      meeting = meeting_fixture(%{calendar_event_id: calendar_event.id, recall_bot_id: recall_bot.id})

      meeting_participant_fixture(%{meeting_id: meeting.id, is_host: true})

      meeting_transcript = meeting_transcript_fixture(%{
        meeting_id: meeting.id,
        content: %{"data" => []}
      })

      job_args = %{"meeting_transcript_id" => meeting_transcript.id}

      assert ContactExtractionWorker.perform(%Oban.Job{args: job_args}) == :ok

      # Verify no contact info was created
      extracted_info = Hubspot.get_extracted_contact_info_by_transcript(meeting_transcript.id)
      assert extracted_info == nil
    end

    test "handles missing transcript" do
      user = user_fixture()
      calendar_event = calendar_event_fixture(%{user_id: user.id})
      recall_bot = recall_bot_fixture(%{calendar_event_id: calendar_event.id, user_id: user.id})
      _meeting = meeting_fixture(%{calendar_event_id: calendar_event.id, recall_bot_id: recall_bot.id})

      job_args = %{"meeting_transcript_id" => 999_999}

      assert ContactExtractionWorker.perform(%Oban.Job{args: job_args}) ==
               {:error, :transcript_not_found}
    end

    test "handles AI API errors" do
      user = user_fixture()
      calendar_event = calendar_event_fixture(%{user_id: user.id})
      recall_bot = recall_bot_fixture(%{calendar_event_id: calendar_event.id, user_id: user.id})
      meeting = meeting_fixture(%{calendar_event_id: calendar_event.id, recall_bot_id: recall_bot.id})

      meeting_participant_fixture(%{meeting_id: meeting.id, is_host: true})

      transcript_content = %{
        "data" => [
          %{
            "speaker" => "John",
            "words" => [%{"text" => "Hello"}]
          }
        ]
      }

      meeting_transcript = meeting_transcript_fixture(%{
        meeting_id: meeting.id,
        content: transcript_content
      })

      expect(AIGeneratorMock, :extract_contact_information, fn _transcript_text, _host_names ->
        {:error, :gemini_api_timeout}
      end)

      job_args = %{"meeting_transcript_id" => meeting_transcript.id}

      assert ContactExtractionWorker.perform(%Oban.Job{args: job_args}) ==
               {:error, :gemini_api_timeout}

      # Verify no contact info was created
      extracted_info = Hubspot.get_extracted_contact_info_by_transcript(meeting_transcript.id)
      assert extracted_info == nil
    end

    test "skips if contact info already exists" do
      user = user_fixture()
      calendar_event = calendar_event_fixture(%{user_id: user.id})
      recall_bot = recall_bot_fixture(%{calendar_event_id: calendar_event.id, user_id: user.id})
      meeting = meeting_fixture(%{calendar_event_id: calendar_event.id, recall_bot_id: recall_bot.id})

      meeting_participant_fixture(%{meeting_id: meeting.id, is_host: true})

      transcript_content = %{
        "data" => [
          %{
            "speaker" => "John",
            "words" => [%{"text" => "Hello"}]
          }
        ]
      }

      meeting_transcript = meeting_transcript_fixture(%{
        meeting_id: meeting.id,
        content: transcript_content
      })

      # Create existing contact info
      extracted_contact_info_fixture(%{
        meeting_transcript_id: meeting_transcript.id,
        contact_info: %{"first_name" => "Existing"}
      })

      # AI should not be called since contact info already exists
      # (The worker checks for existing contact info before calling AI)

      job_args = %{"meeting_transcript_id" => meeting_transcript.id}

      # The worker will skip because contact info already exists
      # But it needs to load the meeting first, so it will call AI
      # Actually, looking at the code, it calls AI first, then checks if it exists
      # So we need to mock AI, but the persist step will skip

      expect(AIGeneratorMock, :extract_contact_information, fn _transcript_text, _host_names ->
        {:ok, %{"first_name" => "New"}}
      end)

      assert ContactExtractionWorker.perform(%Oban.Job{args: job_args}) == :ok

      # Verify existing contact info was not overwritten
      extracted_info = Hubspot.get_extracted_contact_info_by_transcript(meeting_transcript.id)
      assert extracted_info.contact_info["first_name"] == "Existing"
    end

    test "handles empty contact info from AI" do
      user = user_fixture()
      calendar_event = calendar_event_fixture(%{user_id: user.id})
      recall_bot = recall_bot_fixture(%{calendar_event_id: calendar_event.id, user_id: user.id})
      meeting = meeting_fixture(%{calendar_event_id: calendar_event.id, recall_bot_id: recall_bot.id})

      meeting_participant_fixture(%{meeting_id: meeting.id, is_host: true})

      transcript_content = %{
        "data" => [
          %{
            "speaker" => "John",
            "words" => [%{"text" => "Hello"}]
          }
        ]
      }

      meeting_transcript = meeting_transcript_fixture(%{
        meeting_id: meeting.id,
        content: transcript_content
      })

      expect(AIGeneratorMock, :extract_contact_information, fn _transcript_text, _host_names ->
        {:ok, %{}}
      end)

      job_args = %{"meeting_transcript_id" => meeting_transcript.id}

      assert ContactExtractionWorker.perform(%Oban.Job{args: job_args}) == :ok

      # Verify no contact info was created (empty map results in nil)
      extracted_info = Hubspot.get_extracted_contact_info_by_transcript(meeting_transcript.id)
      assert extracted_info == nil
    end

    test "handles invalid job args" do
      job_args = %{"invalid" => "args"}

      assert ContactExtractionWorker.perform(%Oban.Job{args: job_args}) ==
               {:error, :invalid_args}
    end

    test "calls AI API with correct parameters" do
      user = user_fixture()
      calendar_event = calendar_event_fixture(%{user_id: user.id})
      recall_bot = recall_bot_fixture(%{calendar_event_id: calendar_event.id, user_id: user.id})
      meeting = meeting_fixture(%{calendar_event_id: calendar_event.id, recall_bot_id: recall_bot.id})

      _host_participant = meeting_participant_fixture(%{
        meeting_id: meeting.id,
        is_host: true,
        name: "Jane Smith"
      })

      transcript_content = %{
        "data" => [
          %{
            "speaker" => "Jane Smith",
            "words" => [
              %{"text" => "My"},
              %{"text" => "phone"},
              %{"text" => "is"},
              %{"text" => "555-1234"}
            ]
          }
        ]
      }

      meeting_transcript = meeting_transcript_fixture(%{
        meeting_id: meeting.id,
        content: transcript_content
      })

      expect(AIGeneratorMock, :extract_contact_information, fn transcript_text, host_names ->
        # Verify transcript text includes the speaker and words
        assert transcript_text =~ "Jane Smith"
        assert transcript_text =~ "555-1234"

        # Verify host names are normalized and included
        assert "jane smith" in host_names

        {:ok, %{"phone_number" => "555-1234"}}
      end)

      job_args = %{"meeting_transcript_id" => meeting_transcript.id}

      assert ContactExtractionWorker.perform(%Oban.Job{args: job_args}) == :ok
    end
  end
end
