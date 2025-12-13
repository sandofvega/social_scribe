defmodule Ueberauth.Strategy.Hubspot do
  @moduledoc """
  HubSpot OAuth 2.0 strategy for Ueberauth.
  """

  use Ueberauth.Strategy,
    uid_field: :hub_id,
    default_scope:
      "crm.objects.contacts.read crm.objects.contacts.write crm.schemas.contacts.read crm.schemas.contacts.write oauth",
    oauth2_module: Ueberauth.Strategy.Hubspot.OAuth

  alias Ueberauth.Auth.Info
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Extra

  @doc """
  Handles the initial redirect to the HubSpot authorization page.
  """
  def handle_request!(conn) do
    scopes = conn.params["scope"] || option(conn, :default_scope)
    opts = [scope: scopes]

    # Use Ueberauth's helper to properly include the state parameter for CSRF protection
    opts = with_state_param(opts, conn)

    auth_url = OAuth2.Client.authorize_url!(oauth2_client(conn), opts)
    redirect!(conn, auth_url)
  end

  @doc """
  Handles the callback from HubSpot.
  """
  def handle_callback!(%Plug.Conn{params: %{"code" => code}} = conn) do
    client = oauth2_client(conn)

    # HubSpot requires redirect_uri to be included in the token exchange request
    # and it must match the redirect_uri used in the authorization request
    token_params = [
      code: code,
      redirect_uri: client.redirect_uri,
      grant_type: "authorization_code"
    ]

    client_with_token = OAuth2.Client.get_token!(client, token_params)

    # If access_token is a JSON string, parse it manually
    token =
      if client_with_token.token &&
           client_with_token.token.access_token &&
           is_binary(client_with_token.token.access_token) &&
           String.starts_with?(client_with_token.token.access_token, "{") do
        # Parse the JSON string and create a new AccessToken
        parsed = Jason.decode!(client_with_token.token.access_token)
        OAuth2.AccessToken.new(parsed)
      else
        client_with_token.token
      end

    if token == nil || token.access_token == nil do
      error_params = if token, do: token.other_params || %{}, else: %{}

      set_errors!(conn, [
        error(error_params["error"], error_params["error_description"])
      ])
    else
      fetch_user(conn, token)
    end
  end

  @doc false
  def handle_callback!(conn) do
    set_errors!(conn, [error("missing_code", "No code received")])
  end

  @doc false
  def handle_cleanup!(conn) do
    conn
    |> put_private(:hubspot_token, nil)
    |> put_private(:hubspot_user, nil)
  end

  defp fetch_user(conn, token) do
    # HubSpot token response includes hub_id (portal ID) and user info
    # The token response structure: %{"hub_id" => ..., "user" => ..., "scopes" => ...}
    token_params = token.other_params || %{}
    hub_id = token_params["hub_id"] || token_params["hubId"]

    # Convert hub_id to string (database expects string, but HubSpot returns integer)
    hub_id_string = if hub_id, do: to_string(hub_id), else: nil

    # HubSpot token response doesn't include email, so we fetch it from the API
    # Fallback to current_user email if API call fails (user is already logged in)
    user_email =
      fetch_user_email_from_hubspot(token.access_token) ||
        get_in(conn.assigns, [:current_user, :email])

    user_info = %{
      "hub_id" => hub_id_string,
      "email" => user_email
    }

    conn
    |> put_private(:hubspot_user, user_info)
    |> put_private(:hubspot_token, token)
  end

  # Fetch user email from HubSpot's access token metadata endpoint
  defp fetch_user_email_from_hubspot(access_token) when is_binary(access_token) do
    url = "https://api.hubapi.com/oauth/v1/access-tokens/#{access_token}"

    client =
      Tesla.client([
        {Tesla.Middleware.Headers, [{"Authorization", "Bearer #{access_token}"}]},
        Tesla.Middleware.JSON
      ])

    case Tesla.get(client, url) do
      {:ok, %Tesla.Env{status: 200, body: body}} when is_map(body) ->
        Map.get(body, "user")

      _ ->
        nil
    end
  end

  defp fetch_user_email_from_hubspot(_), do: nil

  @doc """
  Provides the uid for the user.
  HubSpot uses hub_id (portal ID) as the unique identifier.
  """
  def uid(conn) do
    user = conn.private.hubspot_user || %{}
    hub_id = user["hub_id"] || user["hubId"]
    # Ensure hub_id is always a string (database expects string type)
    if hub_id, do: to_string(hub_id), else: ""
  end

  @doc """
  Provides the credentials for the user.
  """
  def credentials(conn) do
    token = conn.private.hubspot_token
    token_params = token.other_params || %{}
    scopes = token_params["scopes"] || token_params["scope"] || ""

    # HubSpot returns expires_in (seconds), OAuth2 should convert it to expires_at
    # But if it's not converted, we'll handle it
    expires_at =
      if token.expires_at do
        token.expires_at
      else
        # If expires_in is provided, calculate expires_at
        if expires_in = token_params["expires_in"] do
          DateTime.add(DateTime.utc_now(), expires_in, :second)
        else
          nil
        end
      end

    %Credentials{
      token: token.access_token,
      refresh_token: token.refresh_token,
      expires_at: expires_at,
      token_type: token.token_type || "Bearer",
      expires: !!expires_at,
      scopes: if(is_binary(scopes), do: String.split(scopes, " "), else: [])
    }
  end

  @doc """
  Provides the info for the user.
  """
  def info(conn) do
    user = conn.private.hubspot_user || %{}

    %Info{
      email: user["email"]
    }
  end

  @doc """
  Provides extra information for the user.
  """
  def extra(conn) do
    %Extra{
      raw_info: %{
        token: conn.private.hubspot_token,
        user: conn.private.hubspot_user
      }
    }
  end

  defp oauth2_client(conn) do
    app_config = Application.get_env(:ueberauth, Ueberauth.Strategy.Hubspot.OAuth, [])

    # Get client_secret from option or fall back to Application config
    final_client_secret = option(conn, :client_secret) || Keyword.get(app_config, :client_secret)
    # Get client_id from option or fall back to Application config
    final_client_id = option(conn, :client_id) || Keyword.get(app_config, :client_id)

    Ueberauth.Strategy.Hubspot.OAuth.client(
      client_id: final_client_id,
      client_secret: final_client_secret,
      redirect_uri: option(conn, :redirect_uri)
    )
  end

  defp option(conn, key) do
    default = Keyword.get(options(conn), key, Keyword.get(default_options(), key))
    Keyword.get(options(conn), key, default)
  end
end

defmodule Ueberauth.Strategy.Hubspot.OAuth do
  @moduledoc false
  use OAuth2.Strategy

  def client(opts \\ []) do
    config = Application.get_env(:ueberauth, __MODULE__, [])

    opts_client_id = Keyword.get(opts, :client_id)
    opts_client_secret = Keyword.get(opts, :client_secret)
    config_client_id = Keyword.get(config, :client_id)
    config_client_secret = Keyword.get(config, :client_secret)

    final_client_id = opts_client_id || config_client_id
    final_client_secret = opts_client_secret || config_client_secret

    # HubSpot requires client_id and client_secret to be sent in the request body
    # NOT via Basic Auth header. We override get_token/3 to achieve this.
    # HubSpot returns JSON, so we need a JSON serializer for the response
    OAuth2.Client.new(
      strategy: __MODULE__,
      client_id: final_client_id,
      client_secret: final_client_secret,
      redirect_uri: Keyword.get(opts, :redirect_uri) || Keyword.get(config, :redirect_uri),
      site: "https://api.hubapi.com",
      authorize_url: "https://app.hubspot.com/oauth/authorize",
      token_url: "https://api.hubapi.com/oauth/v1/token",
      serializers: %{
        "application/x-www-form-urlencoded" => OAuth2.Serializer.Form,
        "application/json" => Jason
      }
    )
  end

  def authorize_url(client, params \\ []) do
    OAuth2.Strategy.AuthCode.authorize_url(client, params)
  end

  # Remove any authorization header - HubSpot requires credentials in POST body, not headers
  defp remove_authorization_header(%OAuth2.Client{headers: headers} = client) do
    filtered_headers =
      Enum.reject(headers, fn {key, _value} ->
        String.downcase(key) == "authorization"
      end)

    %{client | headers: filtered_headers}
  end

  def get_token(client, params, headers \\ []) do
    # HubSpot requires client_id and client_secret in POST body, NOT Basic Auth header.
    # OAuth2.Strategy.AuthCode.get_token always calls basic_auth(), so we override it here.
    {code, params} = Keyword.pop(params, :code, client.params["code"])

    unless code do
      raise OAuth2.Error, reason: "Missing required key `code` for `#{inspect(__MODULE__)}`"
    end

    # Add credentials to params (will be in POST body) instead of Basic Auth header
    # CRITICAL: Remove any authorization headers that might have been set
    updated_client =
      client
      |> OAuth2.Client.put_header("Content-Type", "application/x-www-form-urlencoded")
      |> OAuth2.Client.put_param(:code, code)
      |> OAuth2.Client.put_param(:grant_type, "authorization_code")
      |> OAuth2.Client.put_param(:client_id, client.client_id)
      |> OAuth2.Client.put_param(:client_secret, client.client_secret)
      |> OAuth2.Client.put_param(:redirect_uri, client.redirect_uri)
      |> OAuth2.Client.merge_params(params)
      |> OAuth2.Client.put_headers(headers)
      |> remove_authorization_header()

    updated_client
  end
end
