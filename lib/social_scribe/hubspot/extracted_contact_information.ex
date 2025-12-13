defmodule SocialScribe.Hubspot.ExtractedContactInformation do
  use Ecto.Schema
  import Ecto.Changeset

  alias SocialScribe.Meetings.MeetingTranscript

  schema "extracted_contact_information" do
    field :contact_info, :map

    belongs_to :meeting_transcript, MeetingTranscript

    timestamps()
  end

  @doc false
  def changeset(extracted_contact_information, attrs) do
    extracted_contact_information
    |> cast(attrs, [:contact_info, :meeting_transcript_id])
    |> validate_required([:contact_info, :meeting_transcript_id])
  end
end
