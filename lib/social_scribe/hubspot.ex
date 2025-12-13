defmodule SocialScribe.Hubspot do
  @moduledoc """
  Entry point for HubSpot-related persistence helpers.
  """

  alias SocialScribe.Repo
  alias SocialScribe.Hubspot.ExtractedContactInformation

  @doc """
  Lists all extracted contact information records.
  """
  def list_extracted_contact_info do
    Repo.all(ExtractedContactInformation)
  end

  @doc """
  Fetches the extracted contact information for a meeting transcript if it exists.
  """
  def get_extracted_contact_info_by_transcript(meeting_transcript_id) do
    Repo.get_by(ExtractedContactInformation, meeting_transcript_id: meeting_transcript_id)
  end

  @doc """
  Creates a new extracted contact information record.
  """
  def create_extracted_contact_info(attrs) do
    %ExtractedContactInformation{}
    |> ExtractedContactInformation.changeset(attrs)
    |> Repo.insert()
  end
end
