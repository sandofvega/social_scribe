defmodule SocialScribeWeb.MeetingLive.Show do
  use SocialScribeWeb, :live_view

  require Logger

  import SocialScribeWeb.PlatformLogo
  import SocialScribeWeb.ClipboardButton

  alias SocialScribe.Accounts
  alias SocialScribe.Meetings
  alias SocialScribe.Automations
  alias SocialScribe.Hubspot
  alias SocialScribe.Hubspot.Api, as: HubspotApi

  @category_mapping [
    {"identity", ["first_name", "last_name", "date_of_birth"]},
    {"contact_information", ["email", "phone_number", "time_zone"]},
    {"location", ["city", "state", "country", "postal_code"]},
    {"profession", ["job_title", "company_name"]},
    {"personal_information", ["marital_status"]}
  ]

  @max_categories 4

  @hubspot_property_map %{
    "first_name" => "firstname",
    "last_name" => "lastname",
    "email" => "email",
    "phone_number" => "phone",
    "time_zone" => "timezone",
    "city" => "city",
    "state" => "state",
    "country" => "country",
    "postal_code" => "zip",
    "job_title" => "jobtitle",
    "company_name" => "company",
    "date_of_birth" => "dateofbirth",
    "marital_status" => "maritalstatus"
  }

  @impl true
  def mount(%{"id" => meeting_id}, _session, socket) do
    meeting = Meetings.get_meeting_with_details(meeting_id)

    user_has_automations =
      Automations.list_active_user_automations(socket.assigns.current_user.id)
      |> length()
      |> Kernel.>(0)

    automation_results = Automations.list_automation_results_for_meeting(meeting_id)

    extracted_contact_info =
      if meeting.meeting_transcript do
        Hubspot.get_extracted_contact_info_by_transcript(meeting.meeting_transcript.id)
      else
        nil
      end

    contact_info_map = extract_contact_info_map(extracted_contact_info)
    organized_categories = organize_by_categories(contact_info_map)
    default_selected_fields = build_initial_selected_fields(organized_categories)

    selected_categories =
      derive_selected_categories(organized_categories, default_selected_fields)

    if meeting.calendar_event.user_id != socket.assigns.current_user.id do
      socket =
        socket
        |> put_flash(:error, "You do not have permission to view this meeting.")
        |> redirect(to: ~p"/dashboard/meetings")

      {:error, socket}
    else
      socket =
        socket
        |> assign(:page_title, "Meeting Details: #{meeting.title}")
        |> assign(:meeting, meeting)
        |> assign(:automation_results, automation_results)
        |> assign(:user_has_automations, user_has_automations)
        |> assign(:extracted_contact_info, extracted_contact_info)
        |> assign(:contact_info_map, contact_info_map)
        |> assign(:organized_categories, organized_categories)
        |> assign(:selected_fields, default_selected_fields)
        |> assign(:selected_categories, selected_categories)
        |> assign(:selected_field_count, count_selected_fields(default_selected_fields))
        |> assign(
          :selected_category_count,
          count_categories_with_selected_fields(organized_categories, default_selected_fields)
        )
        |> assign(:max_categories, @max_categories)
        |> assign(
          :hubspot_credential,
          Accounts.get_user_hubspot_credential(socket.assigns.current_user)
        )
        |> assign(:selected_contact, nil)
        |> assign(:hubspot_update_loading, false)
        |> assign(:hubspot_update_error, nil)
        |> assign(:hubspot_update_success, false)
        |> assign(:contact_search_query, "")
        |> assign(:contact_search_results, [])
        |> assign(:contact_search_loading, false)
        |> assign(:contact_fetch_loading, false)
        |> assign(:contact_search_error, nil)
        |> assign(:contact_fetch_error, nil)
        |> assign(:contact_search_no_results, false)
        |> assign(
          :follow_up_email_form,
          to_form(%{
            "follow_up_email" => ""
          })
        )

      {:ok, socket}
    end
  end

  @impl true
  def handle_params(%{"automation_result_id" => automation_result_id}, _uri, socket) do
    automation_result = Automations.get_automation_result!(automation_result_id)
    automation = Automations.get_automation!(automation_result.automation_id)

    socket =
      socket
      |> assign(:automation_result, automation_result)
      |> assign(:automation, automation)

    {:noreply, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    socket =
      case socket.assigns[:live_action] do
        :review_update ->
          # When opening the modal, select all fields
          organized_categories = socket.assigns.organized_categories
          all_fields_selected = build_initial_selected_fields(organized_categories)
          assign_selection(socket, all_fields_selected)

        _ ->
          # When closing the modal (or not in review_update), reset the selected contact
          socket
          |> assign(:selected_contact, nil)
          |> assign(:contact_search_query, "")
          |> assign(:contact_search_results, [])
          |> assign(:hubspot_update_success, false)
          |> assign(:hubspot_update_error, nil)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("search-contacts", %{"query" => query}, socket) do
    query = query || ""
    trimmed_query = String.trim(query)

    socket =
      socket
      |> assign(:contact_search_query, query)
      |> assign(:contact_search_error, nil)
      |> assign(:contact_search_no_results, false)

    if trimmed_query == "" do
      {:noreply,
       socket
       |> assign(:contact_search_results, [])
       |> assign(:contact_search_loading, false)
       |> assign(:contact_search_no_results, false)}
    else
      case socket.assigns.hubspot_credential do
        nil ->
          {:noreply,
           socket
           |> assign(:contact_search_results, [])
           |> assign(:contact_search_loading, false)
           |> assign(:contact_search_no_results, false)
           |> assign(:contact_search_error, "Connect your HubSpot account to search contacts.")}

        credential ->
          socket = assign(socket, :contact_search_loading, true)

          # Send intermediate reply to trigger render with loading state
          send(self(), {:perform_search, credential, trimmed_query})

          {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_event("clear-contact-search", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_contact, nil)
     |> assign(:contact_search_query, "")
     |> assign(:contact_search_results, [])
     |> assign(:contact_search_loading, false)
     |> assign(:contact_search_no_results, false)
     |> assign(:contact_search_error, nil)
     |> assign(:hubspot_update_success, false)
     |> assign(:hubspot_update_error, nil)}
  end

  @impl true
  def handle_info({:perform_search, credential, query}, socket) do
    case HubspotApi.search_contacts(credential, query) do
      {:ok, results} ->
        {:noreply,
         socket
         |> assign(:contact_search_results, results)
         |> assign(:contact_search_loading, false)
         |> assign(:contact_search_no_results, Enum.empty?(results))}

      {:error, reason} ->
        Logger.error("HubSpot contact search failed: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:contact_search_loading, false)
         |> assign(:contact_search_results, [])
         |> assign(:contact_search_no_results, false)
         |> assign(:contact_search_error, "Unable to search contacts right now.")}
    end
  end

  @impl true
  def handle_event("select-contact", %{"contact_id" => contact_id}, socket) do
    case socket.assigns.hubspot_credential do
      nil ->
        {:noreply,
         socket
         |> assign(:contact_fetch_error, "Connect your HubSpot account to select a contact.")
         |> assign(:contact_fetch_loading, false)}

      credential ->
        socket = assign(socket, :contact_fetch_loading, true)

        case HubspotApi.get_contact(credential, contact_id) do
          {:ok, contact} ->
            {:noreply,
             socket
             |> assign(:selected_contact, contact)
             |> assign(:contact_fetch_loading, false)
             |> assign(:contact_fetch_error, nil)
             |> assign(:contact_search_results, [])
             |> assign(:contact_search_query, contact_display_name(contact))
             |> assign(:contact_search_no_results, false)
             |> assign(:hubspot_update_success, false)
             |> assign(:hubspot_update_error, nil)}

          {:error, reason} ->
            Logger.error("Failed to load HubSpot contact #{contact_id}: #{inspect(reason)}")

            {:noreply,
             socket
             |> assign(:contact_fetch_loading, false)
             |> assign(:contact_fetch_error, "Unable to load that contact. Please try again.")
             |> assign(:contact_search_no_results, false)}
        end
    end
  end

  @impl true
  def handle_event("toggle-field", %{"field" => field}, socket) do
    selected_fields = socket.assigns.selected_fields
    current_value = Map.get(selected_fields, field, false)
    updated_fields = Map.put(selected_fields, field, !current_value)

    {:noreply, assign_selection(socket, updated_fields)}
  end

  @impl true
  def handle_event("toggle-category", %{"category" => category}, socket) do
    fields = Map.get(socket.assigns.organized_categories, category, [])
    selected_fields = socket.assigns.selected_fields
    turn_on = !Map.get(socket.assigns.selected_categories, category, false)

    updated_fields =
      Enum.reduce(fields, selected_fields, fn field, acc ->
        Map.put(acc, field, turn_on)
      end)

    {:noreply, assign_selection(socket, updated_fields)}
  end

  @impl true
  def handle_event("validate-follow-up-email", params, socket) do
    socket =
      socket
      |> assign(:follow_up_email_form, to_form(params))

    {:noreply, socket}
  end

  @impl true
  def handle_event("update-hubspot", _params, socket) do
    cond do
      socket.assigns.hubspot_update_loading ->
        {:noreply, socket}

      is_nil(socket.assigns.hubspot_credential) ->
        {:noreply,
         socket
         |> put_flash(:error, "Connect your HubSpot account to sync updates.")
         |> assign(:hubspot_update_success, false)}

      is_nil(socket.assigns.selected_contact) ->
        {:noreply,
         socket
         |> put_flash(:error, "Select a HubSpot contact before updating.")
         |> assign(:hubspot_update_success, false)}

      socket.assigns.selected_field_count == 0 ->
        {:noreply,
         socket
         |> put_flash(:error, "Select at least one field to update.")
         |> assign(:hubspot_update_success, false)}

      true ->
        updates =
          build_hubspot_update_payload(
            socket.assigns.selected_fields,
            socket.assigns.contact_info_map
          )

        if map_size(updates) == 0 do
          {:noreply,
           socket
           |> put_flash(:error, "No extracted values available for the selected fields.")
           |> assign(:hubspot_update_success, false)}
        else
          credential = socket.assigns.hubspot_credential
          contact_id = socket.assigns.selected_contact["id"]
          socket = assign(socket, :hubspot_update_loading, true)

          case HubspotApi.update_contact(credential, contact_id, updates) do
            :ok ->
              {:noreply,
               socket
               |> assign(:hubspot_update_loading, false)
               |> assign(:hubspot_update_success, true)
               |> put_flash(:info, "HubSpot contact updated successfully.")
               |> push_patch(to: ~p"/dashboard/meetings/#{socket.assigns.meeting}")}

            {:error, reason} ->
              Logger.error("HubSpot contact update failed: #{inspect(reason)}")

              {:noreply,
               socket
               |> assign(:hubspot_update_loading, false)
               |> put_flash(:error, "Unable to update HubSpot right now. Please try again.")
               |> assign(:hubspot_update_success, false)}
          end
        end
    end
  end

  defp extract_contact_info_map(nil), do: %{}

  defp extract_contact_info_map(%{contact_info: %{} = contact_info}), do: contact_info

  defp extract_contact_info_map(_), do: %{}

  defp organize_by_categories(contact_info_map) when map_size(contact_info_map) == 0, do: %{}

  defp organize_by_categories(contact_info_map) do
    Enum.reduce(@category_mapping, %{}, fn {category, fields}, acc ->
      available_fields =
        fields
        |> Enum.filter(&Map.has_key?(contact_info_map, &1))

      if Enum.empty?(available_fields) do
        acc
      else
        Map.put(acc, category, available_fields)
      end
    end)
  end

  defp ordered_categories(categories) do
    @category_mapping
    |> Enum.reduce([], fn {category, _fields}, acc ->
      case Map.get(categories, category) do
        nil -> acc
        fields -> [{category, fields} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp build_initial_selected_fields(categories) do
    categories
    |> Enum.flat_map(fn {_category, fields} -> fields end)
    |> Enum.reduce(%{}, fn field, acc -> Map.put(acc, field, true) end)
  end

  defp derive_selected_categories(categories, selected_fields) do
    Enum.reduce(categories, %{}, fn {category, fields}, acc ->
      Map.put(acc, category, Enum.all?(fields, &Map.get(selected_fields, &1, false)))
    end)
  end

  defp assign_selection(socket, selected_fields) do
    categories = socket.assigns.organized_categories
    selected_categories = derive_selected_categories(categories, selected_fields)

    socket
    |> assign(:selected_fields, selected_fields)
    |> assign(:selected_categories, selected_categories)
    |> assign(:selected_field_count, count_selected_fields(selected_fields))
    |> assign(
      :selected_category_count,
      count_categories_with_selected_fields(categories, selected_fields)
    )
    |> assign(:hubspot_update_success, false)
    |> assign(:hubspot_update_error, nil)
  end

  defp count_selected_fields(selected_fields) do
    selected_fields
    |> Enum.count(fn {_field, selected?} -> selected? end)
  end

  defp count_categories_with_selected_fields(categories, selected_fields) do
    categories
    |> Enum.count(fn {_category, fields} ->
      Enum.any?(fields, &Map.get(selected_fields, &1, false))
    end)
  end

  defp selected_count_for_category(fields, selected_fields) do
    Enum.count(fields, &Map.get(selected_fields, &1, false))
  end

  defp updates_selected_label(fields, selected_fields) do
    count = selected_count_for_category(fields, selected_fields)
    suffix = if count == 1, do: "update", else: "updates"
    "#{count} #{suffix} selected"
  end

  defp format_duration(nil), do: "N/A"

  defp format_duration(seconds) when is_integer(seconds) do
    minutes = div(seconds, 60)
    remaining_seconds = rem(seconds, 60)

    cond do
      minutes > 0 && remaining_seconds > 0 -> "#{minutes} min #{remaining_seconds} sec"
      minutes > 0 -> "#{minutes} min"
      seconds > 0 -> "#{seconds} sec"
      true -> "Less than a second"
    end
  end

  defp humanize_category(category) do
    category
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp humanize_field(field) do
    field
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp contact_display_name(%{"properties" => properties}) do
    first = String.trim(to_string(Map.get(properties, "firstname", "")))
    last = String.trim(to_string(Map.get(properties, "lastname", "")))
    email = Map.get(properties, "email")

    cond do
      first != "" and last != "" -> "#{first} #{last}"
      first != "" -> first
      email -> email
      true -> "Unknown contact"
    end
  end

  defp contact_display_name(_), do: "Unknown contact"

  defp contact_initials(%{"properties" => properties}) do
    first = String.first(String.trim(to_string(Map.get(properties, "firstname", ""))))
    last = String.first(String.trim(to_string(Map.get(properties, "lastname", ""))))

    ((first || "") <> (last || ""))
    |> String.upcase()
    |> String.slice(0, 2)
    |> case do
      "" -> "?"
      initials -> initials
    end
  end

  defp contact_initials(_), do: "?"

  defp get_hubspot_field_value(nil, _field), do: nil

  defp get_hubspot_field_value(%{"properties" => properties}, field) do
    property_key = Map.get(@hubspot_property_map, field, field)
    Map.get(properties, property_key)
  end

  defp get_hubspot_field_value(_contact, _field), do: nil

  defp get_extracted_field_value(contact_info_map, field) do
    Map.get(contact_info_map, field)
  end

  defp build_hubspot_update_payload(selected_fields, contact_info_map) do
    contact_info_map = contact_info_map || %{}

    selected_fields
    |> Enum.filter(fn {_field, selected?} -> selected? end)
    |> Enum.reduce(%{}, fn {field, _}, acc ->
      case normalize_extracted_value(get_extracted_field_value(contact_info_map, field)) do
        nil ->
          acc

        value ->
          property_key = Map.get(@hubspot_property_map, field, field)
          Map.put(acc, property_key, value)
      end
    end)
  end

  defp normalize_extracted_value(nil), do: nil
  defp normalize_extracted_value(""), do: nil

  defp normalize_extracted_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_extracted_value(value), do: value

  defp format_field_value(nil), do: "No existing value"
  defp format_field_value(""), do: "No existing value"
  defp format_field_value(value) when is_binary(value), do: value
  defp format_field_value(value), do: to_string(value)

  attr :meeting_transcript, :map, required: true

  defp transcript_content(assigns) do
    has_transcript =
      assigns.meeting_transcript &&
        assigns.meeting_transcript.content &&
        Map.get(assigns.meeting_transcript.content, "data") &&
        Enum.any?(Map.get(assigns.meeting_transcript.content, "data"))

    assigns =
      assigns
      |> assign(:has_transcript, has_transcript)

    ~H"""
    <div class="bg-white shadow-xl rounded-lg p-6 md:p-8">
      <h2 class="text-2xl font-semibold mb-4 text-slate-700">
        Meeting Transcript
      </h2>
      <div class="prose prose-sm sm:prose max-w-none h-96 overflow-y-auto pr-2">
        <%= if @has_transcript do %>
          <div :for={segment <- @meeting_transcript.content["data"]} class="mb-3">
            <p>
              <span class="font-semibold text-indigo-600">
                {segment["speaker"] || "Unknown Speaker"}:
              </span>
              {Enum.map_join(segment["words"] || [], " ", & &1["text"])}
            </p>
          </div>
        <% else %>
          <p class="text-slate-500">
            Transcript not available for this meeting.
          </p>
        <% end %>
      </div>
    </div>
    """
  end
end
