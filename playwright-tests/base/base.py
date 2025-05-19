import json
import os

import requests
from dotenv import load_dotenv

from config.constants import URL


class BasePage:
    def __init__(self, page=None):
        self.page = page

    def scroll_into_view(self, locator):
        reference_list = locator
        locator.nth(reference_list.count() - 1).scroll_into_view_if_needed()

    def is_visible(self, locator):
        locator.is_visible()

    def validate_response_status(self, question_api=""):
        load_dotenv()  # Ensure environment variables are loaded
        # URL of the API endpoint
        url = f"{URL}/conversation"

        # Prepare headers
        headers = {
            "Content-Type": "application/json",
            "Accept": "*/*",
        }

        # Payload (data) to be sent in the POST request
        payload = {
            "chat_type": "browse",
            "messages": [
                {
                    "id": "cb9e6c49-0e8c-5f3e-4928-57e55e26896f",
                    "role": "user",
                    "content": question_api,  # Use the passed question
                    "date": "2024-12-18T07:49:23.413Z",
                }
            ],
        }

        # Make the POST request
        response = self.page.request.post(
            url, headers=headers, data=json.dumps(payload), timeout=120000
        )
        assert response.status == 200, (
            "response code is " + str(response.status) + " " + str(response.json())
        )

    def validate_draft_response_status(self, section_title, topic_text):
        load_dotenv()  # Ensure environment variables are loaded

        client_id = os.getenv("client_id")
        client_secret = os.getenv("client_secret")
        tenant_id = os.getenv("tenant_id")
        token_url = f"https://login.microsoft.com/{tenant_id}/oauth2/v2.0/token"

        # URL for generating draft section
        url = f"{URL}/draft_document/generate_section"

        # Prepare data for token request
        data = {
            "grant_type": "client_credentials",
            "client_id": client_id,
            "client_secret": client_secret,
            "scope": f"api://{client_id}/.default",
        }

        try:
            # Request the token
            response = requests.post(token_url, data=data)

            if response.status_code == 200:
                token_info = response.json()
                access_token = token_info["access_token"]
                headers = {
                    "Authorization": f"Bearer {access_token}",
                    "Content-Type": "application/json",
                }
                payload = {
                    "grantTopic": topic_text,
                    "sectionContext": "",
                    "sectionTitle": section_title,
                }

                # Make the POST request for draft section generation
                response = requests.post(url, headers=headers, data=json.dumps(payload))

                # Check if the response status is not 200
                if response.status_code != 200:
                    print(
                        f"Error: {response.status_code}, Response Text: {response.text}"
                    )
                    raise Exception(
                        f"Request failed with status code {response.status_code}"
                    )

                # Attempt to parse the response as JSON
                response_data = response.json()
                print(f"Response JSON: {json.dumps(response_data, indent=2)}")

            else:
                print(f"Error: Failed to get token. Response: {response.text}")
                raise Exception(f"Failed to get token: {response.text}")

        except requests.exceptions.RequestException as e:
            print(f"Request failed: {e}")
            raise Exception(f"Request failed: {e}")

        except requests.exceptions.JSONDecodeError:
            raise Exception(f"Failed to decode JSON from response: {response.text}")
