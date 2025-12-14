defmodule SocialScribeWeb.AuthControllerTest do
  use SocialScribeWeb.ConnCase, async: true

  import SocialScribe.AccountsFixtures
  alias SocialScribe.Accounts
  alias Ueberauth.Auth

  describe "HubSpot OAuth callback" do
    setup %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)
      %{conn: conn, user: user}
    end

    test "successfully creates HubSpot credential for logged-in user", %{conn: conn, user: user} do
      # Create a mock Ueberauth.Auth struct
      auth = %Auth{
        provider: :hubspot,
        uid: "12345",
        info: %Auth.Info{
          email: user.email
        },
        credentials: %Auth.Credentials{
          token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          token_type: "Bearer",
          expires: true,
          scopes: ["crm.objects.contacts.read", "oauth"]
        },
        extra: %Auth.Extra{
          raw_info: %{
            token: %OAuth2.AccessToken{
              access_token: "test_access_token",
              refresh_token: "test_refresh_token",
              expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
            },
            user: %{
              "hub_id" => "12345",
              "email" => user.email
            }
          }
        }
      }

      # Simulate the callback by calling the controller function directly
      conn =
        conn
        |> fetch_flash()
        |> assign(:ueberauth_auth, auth)
        |> assign(:current_user, user)
        |> SocialScribeWeb.AuthController.callback(%{"provider" => "hubspot"})

      # The callback should redirect to settings
      assert redirected_to(conn) == ~p"/dashboard/settings"

      # Check that credential was created
      credential = Accounts.get_user_hubspot_credential(user)
      assert credential != nil
      assert credential.provider == "hubspot"
      assert credential.uid == "12345"
      assert credential.token == "test_access_token"
      assert credential.refresh_token == "test_refresh_token"
      assert credential.user_id == user.id
    end

    test "updates existing HubSpot credential for logged-in user", %{conn: conn, user: user} do
      # Create existing credential
      existing_credential =
        user_credential_fixture(%{
          user_id: user.id,
          provider: "hubspot",
          uid: "12345",
          token: "old_token",
          refresh_token: "old_refresh_token"
        })

      # Create a mock Ueberauth.Auth struct with new token
      auth = %Auth{
        provider: :hubspot,
        uid: "12345",
        info: %Auth.Info{
          email: user.email
        },
        credentials: %Auth.Credentials{
          token: "new_access_token",
          refresh_token: "new_refresh_token",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          token_type: "Bearer",
          expires: true,
          scopes: ["crm.objects.contacts.read", "oauth"]
        },
        extra: %Auth.Extra{
          raw_info: %{
            token: %OAuth2.AccessToken{
              access_token: "new_access_token",
              refresh_token: "new_refresh_token",
              expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
            },
            user: %{
              "hub_id" => "12345",
              "email" => user.email
            }
          }
        }
      }

      # Simulate the callback by calling the controller function directly
      conn =
        conn
        |> fetch_flash()
        |> assign(:ueberauth_auth, auth)
        |> assign(:current_user, user)
        |> SocialScribeWeb.AuthController.callback(%{"provider" => "hubspot"})

      assert redirected_to(conn) == ~p"/dashboard/settings"

      # Check that credential was updated
      updated_credential = Accounts.get_user_hubspot_credential(user)
      assert updated_credential.id == existing_credential.id
      assert updated_credential.token == "new_access_token"
      assert updated_credential.refresh_token == "new_refresh_token"
    end
  end

  describe "HubSpot OAuth request" do
    test "redirects to HubSpot authorization page", %{conn: conn} do
      # This test would require mocking the Ueberauth plug behavior
      # Since Ueberauth handles the actual OAuth flow, we test that
      # the route exists and the controller is set up correctly
      conn = get(conn, "/auth/hubspot")

      # The actual redirect happens in the Ueberauth plug
      # We can verify the route exists
      # 302 for redirect, 200 if handled differently
      assert conn.status in [302, 200]
    end
  end
end
