defmodule SocialScribe.AIContentGeneratorApi do
  @moduledoc """
  Behaviour for generating AI content for meetings.
  """

  @callback generate_follow_up_email(map()) :: {:ok, String.t()} | {:error, any()}
  @callback generate_automation(map(), map()) :: {:ok, String.t()} | {:error, any()}
  @callback extract_contact_information(String.t(), list(String.t())) :: {:ok, map()} | {:error, any()}

  def generate_follow_up_email(meeting) do
    impl().generate_follow_up_email(meeting)
  end

  def generate_automation(automation, meeting) do
    impl().generate_automation(automation, meeting)
  end

  def extract_contact_information(transcript_text, host_names \\ []) do
    impl().extract_contact_information(transcript_text, host_names)
  end

  defp impl do
    Application.get_env(
      :social_scribe,
      :ai_content_generator_api,
      SocialScribe.AIContentGenerator
    )
  end
end
