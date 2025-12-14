defmodule SocialScribe.AIContentGenerator do
  @moduledoc "Generates content using Google Gemini."

  @behaviour SocialScribe.AIContentGeneratorApi

  alias SocialScribe.Meetings
  alias SocialScribe.Automations

  require Logger

  @contact_fields ~w(
    first_name
    last_name
    email
    phone_number
    city
    state
    country
    postal_code
    job_title
    company_name
    date_of_birth
    marital_status
    time_zone
  )

  @gemini_model "gemini-2.0-flash"
  @gemini_api_base_url "https://generativelanguage.googleapis.com/v1beta/models"

  @impl SocialScribe.AIContentGeneratorApi
  def generate_follow_up_email(meeting) do
    case Meetings.generate_prompt_for_meeting(meeting) do
      {:error, reason} ->
        {:error, reason}

      {:ok, meeting_prompt} ->
        prompt = """
        Based on the following meeting transcript, please draft a concise and professional follow-up email.
        The email should summarize the key discussion points and clearly list any action items assigned, including who is responsible if mentioned.
        Keep the tone friendly and action-oriented.

        #{meeting_prompt}
        """

        call_gemini(prompt)
    end
  end

  @impl SocialScribe.AIContentGeneratorApi
  def generate_automation(automation, meeting) do
    case Meetings.generate_prompt_for_meeting(meeting) do
      {:error, reason} ->
        {:error, reason}

      {:ok, meeting_prompt} ->
        prompt = """
        #{Automations.generate_prompt_for_automation(automation)}

        #{meeting_prompt}
        """

        call_gemini(prompt)
    end
  end

  @impl SocialScribe.AIContentGeneratorApi
  def extract_contact_information(transcript_text, host_names \\ [])
      when is_binary(transcript_text) and is_list(host_names) do
    duplicate_resolution =
      if Enum.empty?(host_names) do
        ""
      else
        host_list = Enum.join(host_names, ", ")
        """
        DUPLICATE RESOLUTION: If the same contact field (e.g., email, phone) is mentioned by both the host(s) (#{host_list}) and a participant with different values, prefer the value mentioned by the participant.
        """
      end

    prompt = """
    Extract all contact information mentioned in the following meeting transcript.
    Return a JSON object with only the fields that are actually found.

    Possible fields to extract:
    - first_name, last_name, email, phone_number
    - city, state, country, postal_code
    - job_title, company_name
    - date_of_birth, marital_status, time_zone

    #{duplicate_resolution}

    IMPORTANT INSTRUCTIONS:
    - Only extract information that is EXPLICITLY mentioned in the transcript
    - Do NOT generate placeholder, example, or dummy data (e.g., "example.com", "John Doe", "555-123-4567")
    - Do NOT make up or infer contact information
    - If no contact information is found in the transcript, return an empty JSON object: {}
    - Return ONLY valid JSON, no additional text

    Transcript:
    #{transcript_text}
    """

    with {:ok, raw_response} <- call_gemini(prompt),
         {:ok, contact_map} <- decode_contact_info(raw_response) do
      {:ok, contact_map}
    end
  end

  def extract_contact_information(_transcript_text, _host_names),
    do: {:error, :invalid_transcript_payload}

  defp call_gemini(prompt_text) do
    call_gemini_with_retry(prompt_text, max_retries: 3)
  end

  defp call_gemini_with_retry(prompt_text, opts) do
    max_retries = Keyword.get(opts, :max_retries, 3)
    attempt = Keyword.get(opts, :attempt, 1)

    api_key = Application.fetch_env!(:social_scribe, :gemini_api_key)
    url = "#{@gemini_api_base_url}/#{@gemini_model}:generateContent?key=#{api_key}"

    payload = %{
      contents: [
        %{
          parts: [%{text: prompt_text}]
        }
      ]
    }

    case Tesla.post(client(), url, payload) do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        # Safely extract the text content
        # The response structure is typically: body.candidates[0].content.parts[0].text

        text_path = [
          "candidates",
          Access.at(0),
          "content",
          "parts",
          Access.at(0),
          "text"
        ]

        case get_in(body, text_path) do
          nil -> {:error, {:parsing_error, "No text content found in Gemini response", body}}
          text_content -> {:ok, text_content}
        end

      {:ok, %Tesla.Env{status: 429, body: error_body}} ->
        # Rate limit error - check if we should retry
        if attempt <= max_retries do
          retry_delay = extract_retry_delay(error_body)
          backoff_delay = calculate_backoff_delay(retry_delay, attempt)

          Logger.warning(
            "Gemini API rate limit exceeded (attempt #{attempt}/#{max_retries}). Retrying in #{backoff_delay}s..."
          )

          :timer.sleep(backoff_delay * 1000)

          call_gemini_with_retry(prompt_text, Keyword.put(opts, :attempt, attempt + 1))
        else
          Logger.error("Gemini API rate limit exceeded after #{max_retries} attempts")
          {:error, {:api_error, 429, error_body}}
        end

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        {:error, {:api_error, status, error_body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp extract_retry_delay(error_body) when is_map(error_body) do
    # The error structure includes RetryInfo with retryDelay
    # Example: error.details[].retryDelay = "59s"
    error_details = Map.get(error_body, "error", %{}) |> Map.get("details", [])

    retry_info =
      Enum.find(error_details, fn detail ->
        Map.get(detail, "@type") == "type.googleapis.com/google.rpc.RetryInfo"
      end)

    case retry_info do
      %{"retryDelay" => delay_string} when is_binary(delay_string) ->
        # Parse delay string like "59s" or "59.1s"
        delay_string
        |> String.replace("s", "")
        |> String.trim()
        |> case do
          "" -> 60
          str -> str |> Float.parse() |> elem(0) |> ceil()
        end

      _ ->
        60
    end
  end

  defp extract_retry_delay(_), do: 60

  defp calculate_backoff_delay(base_delay, attempt) do
    # Exponential backoff: base_delay * 2^(attempt-1), with a max of 300 seconds
    exponential_delay = base_delay * :math.pow(2, attempt - 1)
    min(ceil(exponential_delay), 300)
  end

  defp client do
    Tesla.client([
      {Tesla.Middleware.BaseUrl, @gemini_api_base_url},
      Tesla.Middleware.JSON
    ])
  end

  defp decode_contact_info(raw_response) when is_binary(raw_response) do
    cleaned_text = clean_json_text(raw_response)

    case Jason.decode(cleaned_text) do
      {:ok, %{} = decoded} ->
        cleaned =
          decoded
          |> Enum.reduce(%{}, fn
            {key, value}, acc ->
              key = to_string(key)

              cond do
                key not in @contact_fields ->
                  acc

                is_nil(value) ->
                  acc

                is_binary(value) && String.trim(value) == "" ->
                  acc

                is_binary(value) && is_placeholder_value?(value) ->
                  acc

                true ->
                  Map.put(acc, key, value)
              end
          end)

        {:ok, cleaned}

      {:ok, _other} ->
        {:error, :unexpected_format}

      {:error, reason} ->
        {:error, {:json_decode_failed, reason}}
    end
  end

  defp decode_contact_info(_), do: {:error, :invalid_response}

  defp is_placeholder_value?(value) when is_binary(value) do
    normalized = String.downcase(String.trim(value))

    # Check for common placeholder patterns
    cond do
      # Example emails
      String.contains?(normalized, "@example.com") or
          String.contains?(normalized, "@example.org") or
          String.contains?(normalized, "@test.com") ->
        true

      # Common placeholder phone numbers (555-xxxx pattern)
      Regex.match?(~r/^555[-.\s]?\d{3}[-.\s]?\d{4}$/, normalized) ->
        true

      # Common placeholder names
      normalized in ["john doe", "jane doe", "jane smith", "john smith", "alice smith", "bob smith"] ->
        true

      # Common placeholder companies
      normalized in ["acme corp", "acme corporation", "example company", "test company", "sample company"] ->
        true

      # Generic placeholder values
      normalized in ["example", "test", "sample", "placeholder", "dummy", "n/a", "na"] ->
        true

      true ->
        false
    end
  end

  defp is_placeholder_value?(_), do: false

  defp clean_json_text(text) do
    text
    |> String.trim()
    |> trim_leading_code_fence()
    |> trim_trailing_code_fence()
    |> String.trim()
  end

  defp trim_leading_code_fence("```json" <> remainder), do: String.trim_leading(remainder)
  defp trim_leading_code_fence("```" <> remainder), do: String.trim_leading(remainder)
  defp trim_leading_code_fence(text), do: text

  defp trim_trailing_code_fence(text) do
    cond do
      String.ends_with?(text, "```json") ->
        text |> String.replace_suffix("```json", "") |> String.trim()

      String.ends_with?(text, "```") ->
        text |> String.replace_suffix("```", "") |> String.trim()

      true ->
        text
    end
  end
end
