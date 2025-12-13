defmodule Mix.Tasks.ExtractContactInfo do
  @moduledoc """
  Manually trigger contact extraction for a meeting transcript.

  ## Usage

      mix extract_contact_info <meeting_transcript_id>

  ## Examples

      mix extract_contact_info 123

  This will run the ContactExtractionWorker synchronously for the given transcript ID.
  """
  use Mix.Task

  alias SocialScribe.Workers.ContactExtractionWorker

  @shortdoc "Manually extract contact information from a meeting transcript"

  @impl Mix.Task
  def run(args) do
    # Start required applications
    Mix.Task.run("app.start")

    case args do
      [transcript_id_string] ->
        case Integer.parse(transcript_id_string) do
          {transcript_id, _} ->
            extract_contact_info(transcript_id)

          :error ->
            Mix.shell().error("Invalid transcript ID: #{transcript_id_string}")
            System.halt(1)
        end

      [] ->
        Mix.shell().error("Please provide a meeting transcript ID")
        Mix.shell().info("Usage: mix extract_contact_info <meeting_transcript_id>")
        System.halt(1)

      _ ->
        Mix.shell().error("Too many arguments")
        Mix.shell().info("Usage: mix extract_contact_info <meeting_transcript_id>")
        System.halt(1)
    end
  end

  defp extract_contact_info(transcript_id) do
    Mix.shell().info("Extracting contact information for transcript ID: #{transcript_id}")

    # Create a mock Oban.Job struct to call perform directly
    job = %Oban.Job{
      id: 0,
      args: %{"meeting_transcript_id" => transcript_id},
      worker: "SocialScribe.Workers.ContactExtractionWorker",
      queue: "ai_content",
      state: "available"
    }

    case ContactExtractionWorker.perform(job) do
      :ok ->
        Mix.shell().info("✅ Contact extraction completed successfully!")
        Mix.shell().info("Check the extracted_contact_information table for results.")

      {:error, {:api_error, 429, _error_body} = reason} ->
        Mix.shell().error("❌ Contact extraction failed: Rate limit exceeded")
        Mix.shell().info("The Gemini API rate limit was exceeded. Please try again later.")
        Mix.shell().info("Error details: #{inspect(reason)}")
        System.halt(1)

      {:error, reason} ->
        Mix.shell().error("❌ Contact extraction failed: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
