# Script to create a dummy past meeting with transcript
# Run with: mix run priv/repo/create_dummy_meeting.exs

alias SocialScribe.Repo
alias SocialScribe.Accounts.{User, UserCredential}
alias SocialScribe.Calendar.{CalendarEvent}
alias SocialScribe.Bots.{RecallBot}
alias SocialScribe.Meetings.{Meeting, MeetingTranscript, MeetingParticipant}

import Ecto.Query

require Logger

# Helper function to generate random alphanumeric string
random_string = fn length ->
  :crypto.strong_rand_bytes(length)
  |> Base.url_encode64(padding: false)
  |> String.slice(0, length)
  |> String.replace(~r/[^a-zA-Z0-9]/, "a")
end

# Helper function to generate Google Meet code (format: xxx-xxxx-xxx)
generate_meet_code = fn ->
  part1 = random_string.(3)
  part2 = random_string.(4)
  part3 = random_string.(3)
  "#{part1}-#{part2}-#{part3}"
end

# Get first existing user
get_first_user = fn ->
  case Repo.one(from u in User, limit: 1) do
    nil ->
      raise "No user found in database. Please create a user first."
    user ->
      user
  end
end

# Get or create user credential
get_or_create_user_credential = fn user ->
  case Repo.one(
         from uc in UserCredential,
           where: uc.user_id == ^user.id,
           limit: 1
       ) do
    nil ->
      # Create a basic user credential
      unique_id = System.unique_integer([:positive]) |> Integer.to_string()

      attrs = %{
        user_id: user.id,
        provider: "google",
        uid: "dummy_uid_#{unique_id}",
        token: "dummy_token_#{unique_id}",
        refresh_token: "dummy_refresh_#{unique_id}",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        email: user.email || "dummy@example.com"
      }

      case SocialScribe.Accounts.create_user_credential(attrs) do
        {:ok, credential} -> credential
        {:error, changeset} -> raise "Failed to create user credential: #{inspect(changeset.errors)}"
      end

    credential ->
      credential
  end
end

# Create a new calendar event
create_calendar_event = fn user, user_credential ->
  # Generate unique google_event_id (alphanumeric string)
  google_event_id = random_string.(26)

  # Random past date (1-7 days ago)
  days_ago = :rand.uniform(7)
  hours_offset = :rand.uniform(12) - 1  # 0-11 hours
  minutes_offset = :rand.uniform(4) * 15  # 0, 15, 30, or 45 minutes

  start_time =
    DateTime.utc_now()
    |> DateTime.add(-days_ago, :day)
    |> DateTime.add(-hours_offset, :hour)
    |> DateTime.add(-minutes_offset, :minute)

  # Meeting duration: 30-60 minutes
  duration_minutes = 30 + :rand.uniform(31)
  end_time = DateTime.add(start_time, duration_minutes, :minute)

  # Generate meeting titles
  titles = [
    "Client Consultation",
    "Strategy Session",
    "Q4 Planning Meeting",
    "Product Demo",
    "Sales Review",
    "Business Development Call",
    "Partnership Discussion"
  ]
  summary = Enum.random(titles)

  # Generate Google Meet link
  meet_code = generate_meet_code.()
  hangout_link = "https://meet.google.com/#{meet_code}"

  # Generate HTML link
  html_link = "https://www.google.com/calendar/event?eid=#{google_event_id}"

  attrs = %{
    user_id: user.id,
    user_credential_id: user_credential.id,
    google_event_id: google_event_id,
    summary: summary,
    description: nil,
    location: nil,
    html_link: html_link,
    hangout_link: hangout_link,
    status: "confirmed",
    start_time: start_time,
    end_time: end_time,
    record_meeting: false
  }

  case SocialScribe.Calendar.create_calendar_event(attrs) do
    {:ok, event} -> event
    {:error, changeset} -> raise "Failed to create calendar event: #{inspect(changeset.errors)}"
  end
end

# Create a recall bot
create_recall_bot = fn user, calendar_event ->
  unique_id = System.unique_integer([:positive]) |> Integer.to_string()
  recall_bot_id = "dummy_bot_#{unique_id}"

  attrs = %{
    user_id: user.id,
    calendar_event_id: calendar_event.id,
    recall_bot_id: recall_bot_id,
    status: "done",
    meeting_url: calendar_event.hangout_link
  }

  case SocialScribe.Bots.create_recall_bot(attrs) do
    {:ok, bot} -> bot
    {:error, changeset} -> raise "Failed to create recall bot: #{inspect(changeset.errors)}"
  end
end

# Create a meeting
create_meeting = fn calendar_event, recall_bot ->
  # Recorded at should be around the start time of the calendar event
  recorded_at =
    calendar_event.start_time
    |> DateTime.add(:rand.uniform(5), :minute)  # Start recording a few minutes after start

  # Duration in seconds (15-60 minutes)
  duration_minutes = 15 + :rand.uniform(46)
  duration_seconds = duration_minutes * 60

  attrs = %{
    title: calendar_event.summary,
    recorded_at: recorded_at,
    duration_seconds: duration_seconds,
    calendar_event_id: calendar_event.id,
    recall_bot_id: recall_bot.id
  }

  case SocialScribe.Meetings.create_meeting(attrs) do
    {:ok, meeting} -> meeting
    {:error, changeset} -> raise "Failed to create meeting: #{inspect(changeset.errors)}"
  end
end

# Helper to create a transcript segment
create_segment = fn speaker, speaker_id, text, start_timestamp ->
  # Estimate end timestamp (roughly 2-3 words per second)
  word_count = String.split(text) |> length()
  duration = word_count * 0.4  # seconds per word
  end_timestamp = start_timestamp + duration

  %{
    words: [
      %{
        text: text,
        language: nil,
        start_timestamp: start_timestamp,
        end_timestamp: end_timestamp,
        confidence: nil
      }
    ],
    language: "en-us",
    speaker: speaker,
    speaker_id: speaker_id
  }
end

# Generate realistic advisor-client conversation transcript
generate_transcript_data = fn ->
  # Sample advisor and client names
  advisor_name = "Sarah Johnson"
  client_name = "Michael Chen"

  # Sample contact information
  phone_number = "555-#{:rand.uniform(900) + 100}-#{:rand.uniform(9000) + 1000}"
  email = "michael.chen@#{["techcorp.com", "innovate.io", "businesssolutions.com"] |> Enum.random()}"
  company = ["TechCorp", "Innovate Solutions", "Global Business Inc", "StartupXYZ"] |> Enum.random()
  job_title = ["CEO", "CTO", "VP of Sales", "Director of Operations"] |> Enum.random()

  # Conversation segments with timestamps
  base_timestamp = 0.0

  segments = [
    # Advisor greeting
    create_segment.(advisor_name, 100, "Hello, thank you for taking the time to meet with me today.", base_timestamp + 0.5),
    create_segment.(advisor_name, 100, "How are you doing?", base_timestamp + 5.2),

    # Client introduction
    create_segment.(client_name, 200, "I'm doing well, thank you. I'm Michael Chen, #{job_title} at #{company}.", base_timestamp + 7.8),
    create_segment.(client_name, 200, "I'm excited to discuss how we can work together.", base_timestamp + 12.5),

    # Advisor response
    create_segment.(advisor_name, 100, "Great to meet you, Michael. I'm Sarah Johnson, and I'll be your advisor for this project.", base_timestamp + 15.3),
    create_segment.(advisor_name, 100, "Can you tell me a bit more about what you're looking to achieve?", base_timestamp + 20.1),

    # Client provides contact info
    create_segment.(client_name, 200, "Sure. Before we dive in, let me give you my contact information.", base_timestamp + 24.7),
    create_segment.(client_name, 200, "You can reach me at #{phone_number}.", base_timestamp + 28.9),
    create_segment.(client_name, 200, "My email is #{email}.", base_timestamp + 33.2),
    create_segment.(client_name, 200, "Feel free to contact me anytime.", base_timestamp + 37.8),

    # Advisor acknowledges
    create_segment.(advisor_name, 100, "Perfect, I've got that. #{phone_number} and #{email}.", base_timestamp + 41.5),
    create_segment.(advisor_name, 100, "Now, tell me about your company's current situation.", base_timestamp + 45.9),

    # Client discusses business
    create_segment.(client_name, 200, "Well, #{company} has been growing rapidly over the past year.", base_timestamp + 50.3),
    create_segment.(client_name, 200, "We're looking to expand into new markets and need strategic guidance.", base_timestamp + 55.1),
    create_segment.(client_name, 200, "That's why I reached out to you.", base_timestamp + 60.7),

    # Advisor provides guidance
    create_segment.(advisor_name, 100, "I understand. Based on what you've told me, I think we can help you with that.", base_timestamp + 64.2),
    create_segment.(advisor_name, 100, "Let me outline a few strategies we could explore.", base_timestamp + 69.8),

    # Discussion continues
    create_segment.(client_name, 200, "That sounds great. I'm particularly interested in the digital transformation approach.", base_timestamp + 74.5),
    create_segment.(advisor_name, 100, "Excellent choice. We've seen great results with that strategy for similar companies.", base_timestamp + 79.3),

    # Next steps
    create_segment.(advisor_name, 100, "Let's schedule a follow-up meeting next week to dive deeper.", base_timestamp + 84.7),
    create_segment.(client_name, 200, "Perfect. I'll send you a calendar invite. You have my email, #{email}.", base_timestamp + 89.2),
    create_segment.(advisor_name, 100, "Sounds good. I'll also send you some materials to review before our next call.", base_timestamp + 94.6),
    create_segment.(client_name, 200, "Thank you so much, Sarah. This has been very helpful.", base_timestamp + 99.1),
    create_segment.(advisor_name, 100, "You're welcome, Michael. Looking forward to working with you.", base_timestamp + 103.8),
    create_segment.(advisor_name, 100, "Have a great day!", base_timestamp + 108.5)
  ]

  segments
end

# Create meeting transcript
create_meeting_transcript = fn meeting ->
  transcript_data = generate_transcript_data.()

  attrs = %{
    meeting_id: meeting.id,
    content: %{data: transcript_data},
    language: "en-us"
  }

  case SocialScribe.Meetings.create_meeting_transcript(attrs) do
    {:ok, transcript} -> transcript
    {:error, changeset} -> raise "Failed to create meeting transcript: #{inspect(changeset.errors)}"
  end
end

# Create meeting participants
create_meeting_participants = fn meeting ->
  # Based on the transcript, we have two participants:
  # - Sarah Johnson (advisor, speaker_id: 100) - host
  # - Michael Chen (client, speaker_id: 200) - not host

  participants = [
    %{
      recall_participant_id: "100",
      name: "Sarah Johnson",
      is_host: true,
      meeting_id: meeting.id
    },
    %{
      recall_participant_id: "200",
      name: "Michael Chen",
      is_host: false,
      meeting_id: meeting.id
    }
  ]

  Enum.each(participants, fn attrs ->
    case SocialScribe.Meetings.create_meeting_participant(attrs) do
      {:ok, participant} ->
        IO.puts("    ✓ Created participant: #{participant.name} (#{if participant.is_host, do: "host", else: "participant"})")
      {:error, changeset} ->
        raise "Failed to create meeting participant: #{inspect(changeset.errors)}"
    end
  end)
end

# Main function - creates everything in a transaction
create_dummy_meeting = fn ->
  Repo.transaction(fn ->
    IO.puts("Creating dummy meeting...")

    # Get user
    IO.puts("  → Getting first user...")
    user = get_first_user.()
    IO.puts("    ✓ Found user: #{user.email}")

    # Get or create user credential
    IO.puts("  → Getting or creating user credential...")
    user_credential = get_or_create_user_credential.(user)
    IO.puts("    ✓ User credential ready")

    # Create calendar event
    IO.puts("  → Creating calendar event...")
    calendar_event = create_calendar_event.(user, user_credential)
    IO.puts("    ✓ Created calendar event: #{calendar_event.summary}")

    # Create recall bot
    IO.puts("  → Creating recall bot...")
    recall_bot = create_recall_bot.(user, calendar_event)
    IO.puts("    ✓ Created recall bot: #{recall_bot.recall_bot_id}")

    # Create meeting
    IO.puts("  → Creating meeting...")
    meeting = create_meeting.(calendar_event, recall_bot)
    IO.puts("    ✓ Created meeting: #{meeting.title}")

    # Create transcript
    IO.puts("  → Creating meeting transcript...")
    transcript = create_meeting_transcript.(meeting)
    IO.puts("    ✓ Created transcript with #{length(transcript.content.data)} segments")

    # Create meeting participants
    IO.puts("  → Creating meeting participants...")
    create_meeting_participants.(meeting)

    IO.puts("\n✅ Successfully created dummy meeting!")
    IO.puts("   Meeting ID: #{meeting.id}")
    IO.puts("   Title: #{meeting.title}")
    IO.puts("   Recorded at: #{meeting.recorded_at}")
    IO.puts("   Duration: #{div(meeting.duration_seconds, 60)} minutes")

    meeting
  end)
end

# Run the script
case create_dummy_meeting.() do
  {:ok, _meeting} ->
    IO.puts("\n🎉 All done! Run this script again to create another meeting.")
    :ok

  {:error, reason} ->
    IO.puts("\n❌ Error creating dummy meeting:")
    IO.inspect(reason)
    System.halt(1)
end
