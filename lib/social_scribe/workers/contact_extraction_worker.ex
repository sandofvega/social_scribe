defmodule SocialScribe.Workers.ContactExtractionWorker do
  use Oban.Worker, queue: :ai_content, max_attempts: 3

  alias SocialScribe.AIContentGeneratorApi
  alias SocialScribe.Hubspot
  alias SocialScribe.Meetings
  alias SocialScribe.Meetings.Meeting
  alias SocialScribe.Meetings.MeetingTranscript

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"meeting_transcript_id" => transcript_id}}) do
    with {:ok, %Meeting{} = meeting} <- load_meeting_from_transcript(transcript_id),
         {:ok, transcript_text} <- build_transcript_text(meeting),
         host_names <- host_participant_names(meeting),
         {:ok, contact_info} <- extract_contact_info(transcript_text, host_names),
         {:ok, _record} <- persist_contact_info(meeting.meeting_transcript.id, contact_info) do
      :ok
    else
      {:skip, reason} ->
        Logger.info("ContactExtractionWorker skipped: #{inspect(reason)}")
        :ok

      {:error, reason} ->
        Logger.error("ContactExtractionWorker failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("ContactExtractionWorker received invalid args: #{inspect(args)}")
    {:error, :invalid_args}
  end

  defp load_meeting_from_transcript(transcript_id) do
    case Meetings.get_meeting_transcript!(transcript_id) do
      %MeetingTranscript{} = transcript ->
        case Meetings.get_meeting_with_details(transcript.meeting_id) do
          %Meeting{} = meeting -> {:ok, meeting}
          nil -> {:error, :meeting_not_found}
        end
    end
  rescue
    Ecto.NoResultsError -> {:error, :transcript_not_found}
  end

  defp build_transcript_text(%Meeting{} = meeting) do
    case meeting.meeting_transcript do
      %MeetingTranscript{} = transcript ->
        transcript
        |> all_segments()
        |> segments_to_text()
        |> case do
          "" -> {:skip, :empty_transcript}
          transcript_text -> {:ok, transcript_text}
        end

      nil ->
        {:skip, :missing_transcript}
    end
  end

  defp extract_contact_info(transcript_text, host_names) do
    case AIContentGeneratorApi.extract_contact_information(transcript_text, host_names) do
      {:ok, %{} = contact_info} when map_size(contact_info) == 0 ->
        {:ok, nil}

      {:ok, contact_info} ->
        {:ok, contact_info}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_contact_info(meeting_transcript_id, contact_info) do
    case Hubspot.get_extracted_contact_info_by_transcript(meeting_transcript_id) do
      nil ->
        Hubspot.create_extracted_contact_info(%{
          contact_info: contact_info,
          meeting_transcript_id: meeting_transcript_id
        })

      _existing ->
        {:skip, :already_exists}
    end
  end

  defp host_participant_names(%Meeting{} = meeting) do
    meeting.meeting_participants
    |> Enum.filter(& &1.is_host)
    |> Enum.map(&normalize_string(&1.name))
    |> Enum.reject(&is_nil/1)
  end

  defp all_segments(%MeetingTranscript{} = transcript) do
    transcript.content
    |> Map.get("data", [])
  end

  defp segments_to_text(segments) do
    segments
    |> Enum.map(&segment_to_line/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp segment_to_line(segment) do
    speaker = Map.get(segment, "speaker", "Participant")

    text =
      segment
      |> Map.get("words", [])
      |> Enum.map(&Map.get(&1, "text", ""))
      |> Enum.join(" ")
      |> String.trim()

    if text == "" do
      ""
    else
      "#{speaker}: #{text}"
    end
  end

  defp normalize_string(nil), do: nil

  defp normalize_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      other -> String.downcase(other)
    end
  end
end
