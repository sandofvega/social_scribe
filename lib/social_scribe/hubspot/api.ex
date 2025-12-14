defmodule SocialScribe.Hubspot.Api do
  @moduledoc """
  Lightweight HubSpot client used inside LiveViews to look up contacts.
  """

  require Logger

  alias SocialScribe.Accounts
  alias SocialScribe.Accounts.UserCredential
  alias SocialScribe.HubspotTokenRefresher

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
  @searchable_fields ~w(firstname lastname email phone company)
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
        with {:ok, token} <- ensure_valid_token(credential),
             {:ok, response} <-
               Tesla.post(
                 client(token),
                 @search_path,
                 build_search_body(query, limit)
               ) do
          decode_search_response(response)
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
      case response do
        %Tesla.Env{status: 200, body: %{"id" => _id}} ->
          {:ok, response.body}

        %Tesla.Env{status: status, body: body} ->
          {:error, {:hubspot_error, status, body}}
      end
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_search_body(query, limit) do
    %{
      filterGroups: build_filter_groups(query),
      properties: @default_properties,
      limit: limit,
      query: query
    }
  end

  defp build_filter_groups(query) do
    Enum.map(@searchable_fields, fn field ->
      %{
        filters: [
          %{
            propertyName: field,
            operator: "CONTAINS_TOKEN",
            value: query
          }
        ]
      }
    end)
  end

  defp decode_search_response(%Tesla.Env{status: 200, body: %{"results" => results}}) do
    {:ok, results}
  end

  defp decode_search_response(%Tesla.Env{status: status, body: body}) do
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
    cond do
      is_nil(credential.expires_at) ->
        {:ok, credential.token}

      DateTime.compare(credential.expires_at, DateTime.utc_now()) == :gt ->
        {:ok, credential.token}

      true ->
        refresh_token(credential)
    end
  end

  defp refresh_token(%UserCredential{} = credential) do
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
        Logger.error("Failed to refresh HubSpot token: #{inspect(reason)}")
        {:error, {:refresh_failed, reason}}
    end
  end
end
