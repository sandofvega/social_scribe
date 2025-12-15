defmodule SocialScribe.Hubspot.Api do
  @moduledoc """
  Lightweight HubSpot client used inside LiveViews to look up contacts.
  """

  require Logger

  alias SocialScribe.Accounts
  alias SocialScribe.Accounts.UserCredential
  alias SocialScribe.HubspotTokenRefresher
  alias SocialScribe.Repo

  @base_url "https://api.hubapi.com"
  @search_path "/crm/v3/objects/contacts/search"
  @contacts_path "/crm/v3/objects/contacts"
  @default_properties ~w(
    firstname
    lastname
    email
    phone
    city
    state
    country
    zip
    jobtitle
    company
    dateofbirth
    maritalstatus
    timezone
  )
  @default_limit 5

  @type credential :: %UserCredential{}
  @type contact_result :: map()

  @doc """
  Search HubSpot contacts for the given query.

  Returns `{:ok, [%{"id" => ..., "properties" => %{...}}, ...]}` on success.
  """
  @spec search_contacts(credential(), binary(), keyword()) ::
          {:ok, [contact_result()]} | {:error, term()}
  def search_contacts(%UserCredential{} = credential, query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, @default_limit)

    cond do
      String.trim(query) == "" ->
        {:ok, []}

      true ->
        search_body = build_search_body(query, limit)

        with {:ok, token} <- ensure_valid_token(credential),
             {:ok, response} <-
               Tesla.post(
                 client(token),
                 @search_path,
                 search_body
               ) do
          handle_search_response(response, credential, fn fresh_credential ->
            Tesla.post(
              client(fresh_credential.token),
              @search_path,
              search_body
            )
          end)
        else
          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Fetch a single HubSpot contact by ID.
  """
  @spec get_contact(credential(), binary(), keyword()) ::
          {:ok, contact_result()} | {:error, term()}
  def get_contact(%UserCredential{} = credential, contact_id, _opts \\ [])
      when is_binary(contact_id) do
    with {:ok, token} <- ensure_valid_token(credential),
         {:ok, response} <-
           Tesla.get(
             client(token),
             "#{@contacts_path}/#{contact_id}",
             query: [properties: Enum.join(@default_properties, ",")]
           ) do
      handle_get_contact_response(response, credential, contact_id)
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Update a HubSpot contact with the provided properties.
  """
  @spec update_contact(credential(), binary(), map()) :: :ok | {:error, term()}
  def update_contact(%UserCredential{} = credential, contact_id, properties)
      when is_binary(contact_id) and is_map(properties) and map_size(properties) > 0 do
    with {:ok, token} <- ensure_valid_token(credential),
         {:ok, response} <-
           Tesla.patch(
             client(token),
             "#{@contacts_path}/#{contact_id}",
             %{properties: properties}
           ) do
      handle_update_response(response, credential, contact_id, properties)
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  def update_contact(_credential, _contact_id, _properties),
    do: {:error, :no_properties_to_update}

  defp build_search_body(query, limit) do
    %{
      properties: @default_properties,
      limit: limit,
      query: query
    }
  end

  defp decode_search_response(%Tesla.Env{status: 200, body: %{"results" => results}}) do
    {:ok, results}
  end

  defp decode_search_response(%Tesla.Env{status: status, body: body}) do
    {:error, {:hubspot_error, status, body}}
  end

  defp decode_update_response(%Tesla.Env{status: status}) when status in 200..299, do: :ok

  defp decode_update_response(%Tesla.Env{status: status, body: body}) do
    {:error, {:hubspot_error, status, body}}
  end

  # Handle search API responses, automatically refreshing token on 401 errors
  defp handle_search_response(
         %Tesla.Env{status: 200, body: %{"results" => _results}} = response,
         _credential,
         _retry_fn
       ) do
    decode_search_response(response)
  end

  defp handle_search_response(
         %Tesla.Env{status: 401} = response,
         credential,
         retry_fn
       ) do
    Logger.warning(
      "HubSpot API returned 401 for user_id: #{credential.user_id}. Attempting token refresh."
    )

    # Try to refresh the token and retry the request
    case refresh_token(credential) do
      {:ok, _fresh_token} ->
        # Reload the credential to get the updated token
        case Repo.get(UserCredential, credential.id) do
          nil ->
            Logger.error("Could not reload credential after refresh")
            decode_search_response(response)

          fresh_credential ->
            case retry_fn.(fresh_credential) do
              {:ok, retry_response} ->
                handle_search_response(retry_response, fresh_credential, retry_fn)

              {:error, reason} ->
                Logger.error("Retry after token refresh failed: #{inspect(reason)}")
                decode_search_response(response)
            end
        end

      {:error, reason} ->
        # Don't log configuration errors as errors since we already logged a warning
        case reason do
          {:refresh_failed, :missing_client_id} ->
            # Return refresh_failed error so LiveView can show appropriate message
            {:error, {:refresh_failed, :missing_client_id}}

          {:refresh_failed, :missing_client_secret} ->
            # Return refresh_failed error so LiveView can show appropriate message
            {:error, {:refresh_failed, :missing_client_secret}}

          {:refresh_failed, _} = refresh_error ->
            Logger.error("Token refresh failed: #{inspect(reason)}")
            # Return refresh_failed error so LiveView can show appropriate message
            {:error, refresh_error}

          _ ->
            Logger.error("Token refresh failed: #{inspect(reason)}")
            # Return refresh_failed error so LiveView can show appropriate message
            {:error, {:refresh_failed, reason}}
        end
    end
  end

  defp handle_search_response(%Tesla.Env{status: status, body: body}, _credential, _retry_fn) do
    {:error, {:hubspot_error, status, body}}
  end

  # Handle get_contact API responses, automatically refreshing token on 401 errors
  defp handle_get_contact_response(
         %Tesla.Env{status: 200, body: %{"id" => _id}} = response,
         _credential,
         _contact_id
       ) do
    {:ok, response.body}
  end

  defp handle_get_contact_response(
         %Tesla.Env{status: 401} = response,
         credential,
         contact_id
       ) do
    Logger.warning(
      "HubSpot API returned 401 for user_id: #{credential.user_id}. Attempting token refresh."
    )

    # Try to refresh the token and retry the request
    case refresh_token(credential) do
      {:ok, _fresh_token} ->
        # Reload the credential to get the updated token
        case Repo.get(UserCredential, credential.id) do
          nil ->
            Logger.error("Could not reload credential after refresh")
            {:error, {:hubspot_error, 401, response.body}}

          fresh_credential ->
            case Tesla.get(
                   client(fresh_credential.token),
                   "#{@contacts_path}/#{contact_id}",
                   query: [properties: Enum.join(@default_properties, ",")]
                 ) do
              {:ok, retry_response} ->
                handle_get_contact_response(retry_response, fresh_credential, contact_id)

              {:error, reason} ->
                Logger.error("Retry after token refresh failed: #{inspect(reason)}")
                {:error, {:hubspot_error, 401, response.body}}
            end
        end

      {:error, reason} ->
        # Don't log configuration errors as errors since we already logged a warning
        case reason do
          {:refresh_failed, :missing_client_id} ->
            # Return refresh_failed error so LiveView can show appropriate message
            {:error, {:refresh_failed, :missing_client_id}}

          {:refresh_failed, :missing_client_secret} ->
            # Return refresh_failed error so LiveView can show appropriate message
            {:error, {:refresh_failed, :missing_client_secret}}

          {:refresh_failed, _} = refresh_error ->
            Logger.error("Token refresh failed: #{inspect(reason)}")
            # Return refresh_failed error so LiveView can show appropriate message
            {:error, refresh_error}

          _ ->
            Logger.error("Token refresh failed: #{inspect(reason)}")
            # Return refresh_failed error so LiveView can show appropriate message
            {:error, {:refresh_failed, reason}}
        end
    end
  end

  defp handle_get_contact_response(
         %Tesla.Env{status: status, body: body},
         _credential,
         _contact_id
       ) do
    {:error, {:hubspot_error, status, body}}
  end

  # Handle update API responses, automatically refreshing token on 401 errors
  defp handle_update_response(
         %Tesla.Env{status: status} = response,
         _credential,
         _contact_id,
         _properties
       )
       when status in 200..299 do
    decode_update_response(response)
  end

  defp handle_update_response(
         %Tesla.Env{status: 401} = response,
         credential,
         contact_id,
         properties
       ) do
    Logger.warning(
      "HubSpot API returned 401 for user_id: #{credential.user_id}. Attempting token refresh."
    )

    # Try to refresh the token and retry the request
    case refresh_token(credential) do
      {:ok, _fresh_token} ->
        # Reload the credential to get the updated token
        case Repo.get(UserCredential, credential.id) do
          nil ->
            Logger.error("Could not reload credential after refresh")
            decode_update_response(response)

          fresh_credential ->
            case Tesla.patch(
                   client(fresh_credential.token),
                   "#{@contacts_path}/#{contact_id}",
                   %{properties: properties}
                 ) do
              {:ok, retry_response} ->
                handle_update_response(retry_response, fresh_credential, contact_id, properties)

              {:error, reason} ->
                Logger.error("Retry after token refresh failed: #{inspect(reason)}")
                decode_update_response(response)
            end
        end

      {:error, reason} ->
        # Don't log configuration errors as errors since we already logged a warning
        case reason do
          {:refresh_failed, :missing_client_id} ->
            # Return refresh_failed error so LiveView can show appropriate message
            {:error, {:refresh_failed, :missing_client_id}}

          {:refresh_failed, :missing_client_secret} ->
            # Return refresh_failed error so LiveView can show appropriate message
            {:error, {:refresh_failed, :missing_client_secret}}

          {:refresh_failed, _} = refresh_error ->
            Logger.error("Token refresh failed: #{inspect(reason)}")
            # Return refresh_failed error so LiveView can show appropriate message
            {:error, refresh_error}

          _ ->
            Logger.error("Token refresh failed: #{inspect(reason)}")
            # Return refresh_failed error so LiveView can show appropriate message
            {:error, {:refresh_failed, reason}}
        end
    end
  end

  defp handle_update_response(
         %Tesla.Env{status: status, body: body},
         _credential,
         _contact_id,
         _properties
       ) do
    {:error, {:hubspot_error, status, body}}
  end

  defp client(token) when is_binary(token) do
    Tesla.client([
      {Tesla.Middleware.BaseUrl, @base_url},
      {Tesla.Middleware.Headers,
       [
         {"Authorization", "Bearer #{token}"},
         {"Content-Type", "application/json"},
         {"Accept", "application/json"}
       ]},
      Tesla.Middleware.JSON
    ])
  end

  defp ensure_valid_token(%UserCredential{} = credential) do
    # First check if token exists and is not empty
    cond do
      is_nil(credential.token) or credential.token == "" ->
        Logger.error("HubSpot credential missing access token for user_id: #{credential.user_id}")
        {:error, :missing_token}

      # If expires_at is nil, assume token doesn't expire (or is a long-lived token)
      is_nil(credential.expires_at) ->
        {:ok, credential.token}

      # Token is still valid
      DateTime.compare(credential.expires_at, DateTime.utc_now()) == :gt ->
        {:ok, credential.token}

      # Token is expired, try to refresh
      true ->
        refresh_token(credential)
    end
  end

  defp refresh_token(%UserCredential{} = credential) do
    # Check if refresh_token exists before attempting refresh
    if is_nil(credential.refresh_token) or credential.refresh_token == "" do
      Logger.error(
        "HubSpot credential missing refresh token for user_id: #{credential.user_id}. Re-authentication required."
      )

      {:error, :missing_refresh_token}
    else
      # Check if OAuth config exists before attempting refresh
      oauth_config = Application.get_env(:ueberauth, Ueberauth.Strategy.Hubspot.OAuth, [])
      client_id = Keyword.get(oauth_config, :client_id)
      client_secret = Keyword.get(oauth_config, :client_secret)

      cond do
        is_nil(client_id) or client_id == "" ->
          Logger.warning(
            "HubSpot OAuth configuration missing (client_id) for user_id: #{credential.user_id}. Cannot refresh token. Please set HUBSPOT_CLIENT_ID environment variable."
          )

          {:error, {:refresh_failed, :missing_client_id}}

        is_nil(client_secret) or client_secret == "" ->
          Logger.warning(
            "HubSpot OAuth configuration missing (client_secret) for user_id: #{credential.user_id}. Cannot refresh token. Please set HUBSPOT_CLIENT_SECRET environment variable."
          )

          {:error, {:refresh_failed, :missing_client_secret}}

        true ->
          case HubspotTokenRefresher.refresh_token(credential.refresh_token) do
            {:ok, %{"access_token" => _token} = token_data} ->
              case Accounts.update_credential_tokens(credential, token_data) do
                {:ok, updated} ->
                  {:ok, updated.token}

                {:error, changeset} ->
                  Logger.error("Failed to persist refreshed HubSpot token: #{inspect(changeset)}")
                  {:error, {:credential_update_failed, changeset}}
              end

            {:error, reason} ->
              # Don't log configuration errors as errors since we already logged a warning
              case reason do
                :missing_client_id ->
                  {:error, {:refresh_failed, reason}}

                :missing_client_secret ->
                  {:error, {:refresh_failed, reason}}

                _ ->
                  Logger.error("Failed to refresh HubSpot token: #{inspect(reason)}")
                  {:error, {:refresh_failed, reason}}
              end
          end
      end
    end
  end
end
