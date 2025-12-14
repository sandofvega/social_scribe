defmodule SocialScribe.HubspotTokenRefresher do
  @moduledoc """
  Refreshes HubSpot OAuth tokens.
  """

  @hubspot_token_url "https://api.hubapi.com/oauth/v1/token"

  def client do
    middlewares = [
      {Tesla.Middleware.FormUrlencoded,
       encode: &Plug.Conn.Query.encode/1, decode: &Plug.Conn.Query.decode/1},
      Tesla.Middleware.JSON
    ]

    Tesla.client(middlewares)
  end

  @doc """
  Refreshes a HubSpot access token using the refresh token.
  """
  def refresh_token(refresh_token_string) do
    oauth_config = Application.get_env(:ueberauth, Ueberauth.Strategy.Hubspot.OAuth, [])

    client_id = Keyword.get(oauth_config, :client_id)
    client_secret = Keyword.get(oauth_config, :client_secret)

    cond do
      is_nil(client_id) or client_id == "" ->
        {:error, :missing_client_id}

      is_nil(client_secret) or client_secret == "" ->
        {:error, :missing_client_secret}

      true ->
        body = %{
          grant_type: "refresh_token",
          client_id: client_id,
          client_secret: client_secret,
          refresh_token: refresh_token_string
        }

        # Use Tesla to make the POST request
        case Tesla.post(client(), @hubspot_token_url, body, opts: [form_urlencoded: true]) do
          {:ok, %Tesla.Env{status: 200, body: response_body}} ->
            {:ok, response_body}

          {:ok, %Tesla.Env{status: status, body: error_body}} ->
            {:error, {status, error_body}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
