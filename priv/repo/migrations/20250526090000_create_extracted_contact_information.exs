defmodule SocialScribe.Repo.Migrations.CreateExtractedContactInformation do
  use Ecto.Migration

  def change do
    create table(:extracted_contact_information) do
      add :contact_info, :map, null: false

      add :meeting_transcript_id,
          references(:meeting_transcripts, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:extracted_contact_information, [:meeting_transcript_id])
    create index(:extracted_contact_information, [:inserted_at])
  end
end
