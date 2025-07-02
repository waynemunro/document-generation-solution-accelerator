import copy
import json
import logging
import os
import uuid
import re
import ast
import requests, asyncio
from typing import Dict, Any, AsyncGenerator

from azure.core.credentials import AzureKeyCredential
from azure.identity.aio import (DefaultAzureCredential,
                                get_bearer_token_provider)
from azure.identity import DefaultAzureCredential as DefaultAzureCredentialSync
from azure.search.documents import SearchClient
from openai import AsyncAzureOpenAI
from quart import (Blueprint, Quart, jsonify, make_response, render_template,
                   request, send_from_directory)

from backend.auth.auth_utils import get_authenticated_user_details
from backend.history.cosmosdbservice import CosmosConversationClient
from backend.security.ms_defender_utils import get_msdefender_user_json
from backend.settings import (
    MINIMUM_SUPPORTED_AZURE_OPENAI_PREVIEW_API_VERSION, app_settings)
from backend.utils import (ChatType, format_as_ndjson,
                           format_non_streaming_response,
                           format_stream_response)
from event_utils import track_event_if_configured
from azure.monitor.opentelemetry import configure_azure_monitor
from opentelemetry import trace
from opentelemetry.trace import Status, StatusCode
from azure.ai.projects.aio import AIProjectClient
from azure.ai.agents.models import (
    AzureAISearchQueryType, 
    AzureAISearchTool,
    AgentEventHandler,
    MessageRole,
    RunStepToolCallDetails,
    MessageDeltaChunk,
    RunStep,
    ThreadMessage,
    ThreadRun,
    AgentStreamEvent,
    RunStepDeltaChunk,
    MessageDeltaTextContent,
    MessageDeltaTextUrlCitationAnnotation
    )

bp = Blueprint("routes", __name__, static_folder="static", template_folder="static")

# Check if the Application Insights Instrumentation Key is set in the environment variables
instrumentation_key = os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING")
if instrumentation_key:
    # Configure Application Insights if the Instrumentation Key is found
    configure_azure_monitor(connection_string=instrumentation_key)
    logging.info("Application Insights configured with the provided Instrumentation Key")
else:
    # Log a warning if the Instrumentation Key is not found
    logging.warning("No Application Insights Instrumentation Key found. Skipping configuration")

# Configure logging
logging.basicConfig(level=logging.INFO)

# Suppress INFO logs from 'azure.core.pipeline.policies.http_logging_policy'
logging.getLogger("azure.core.pipeline.policies.http_logging_policy").setLevel(
    logging.WARNING
)
logging.getLogger("azure.identity.aio._internal").setLevel(logging.WARNING)

# Suppress info logs from OpenTelemetry exporter
logging.getLogger("azure.monitor.opentelemetry.exporter.export._base").setLevel(
    logging.WARNING
)


def create_app():
    app = Quart(__name__)
    app.register_blueprint(bp)
    app.config["TEMPLATES_AUTO_RELOAD"] = True
    app.config['PROVIDE_AUTOMATIC_OPTIONS'] = True
    return app


@bp.route("/")
async def index():
    return await render_template(
        "index.html", title=app_settings.ui.title, favicon=app_settings.ui.favicon
    )


@bp.route("/favicon.ico")
async def favicon():
    return await bp.send_static_file("favicon.ico")


@bp.route("/assets/<path:path>")
async def assets(path):
    return await send_from_directory("static/assets", path)


# Debug settings
DEBUG = os.environ.get("DEBUG", "false")
if DEBUG.lower() == "true":
    logging.basicConfig(level=logging.DEBUG)

USER_AGENT = "GitHubSampleWebApp/AsyncAzureOpenAI/1.0.0"


# Frontend Settings via Environment Variables
frontend_settings = {
    "auth_enabled": app_settings.base_settings.auth_enabled,
    "feedback_enabled": (
        app_settings.chat_history and app_settings.chat_history.enable_feedback
    ),
    "ui": {
        "title": app_settings.ui.title,
        "logo": app_settings.ui.logo,
        "chat_logo": app_settings.ui.chat_logo or app_settings.ui.logo,
        "chat_title": app_settings.ui.chat_title,
        "chat_description": app_settings.ui.chat_description,
        "show_share_button": app_settings.ui.show_share_button,
    },
    "sanitize_answer": app_settings.base_settings.sanitize_answer,
}


# Enable Microsoft Defender for Cloud Integration
MS_DEFENDER_ENABLED = os.environ.get("MS_DEFENDER_ENABLED", "true").lower() == "true"


# Initialize Azure OpenAI Client
def init_openai_client():
    azure_openai_client = None
    track_event_if_configured("OpenAIClientInitializationStart", {"status": "success"})
    try:
        # API version check
        if (
            app_settings.azure_openai.preview_api_version
            < MINIMUM_SUPPORTED_AZURE_OPENAI_PREVIEW_API_VERSION
        ):
            raise ValueError(
                f"The minimum supported Azure OpenAI preview API version is"
                f"'{MINIMUM_SUPPORTED_AZURE_OPENAI_PREVIEW_API_VERSION}'"
            )
        # Endpoint
        if (
            not app_settings.azure_openai.endpoint
            and not app_settings.azure_openai.resource
        ):
            track_event_if_configured("MissingOpenAIEndpointOrResource", {
                "detail": "Neither AZURE_OPENAI_ENDPOINT nor AZURE_OPENAI_RESOURCE is set"
            })
            raise ValueError(
                "AZURE_OPENAI_ENDPOINT or AZURE_OPENAI_RESOURCE is required"
            )

        endpoint = (
            app_settings.azure_openai.endpoint
            if app_settings.azure_openai.endpoint
            else f"https://{app_settings.azure_openai.resource}.openai.azure.com/"
        )
        track_event_if_configured("AzureOpenAIEndpointUsed", {
            "endpoint": endpoint
        })

        # Authentication
        ad_token_provider = None
        ad_token_provider = get_bearer_token_provider(
            DefaultAzureCredential(), "https://cognitiveservices.azure.com/.default"
        )

        # Deployment
        deployment = app_settings.azure_openai.model
        if not deployment:
            track_event_if_configured("MissingOpenAIModel", {
                "detail": "AZURE_OPENAI_MODEL not configured"
            })
            raise ValueError("AZURE_OPENAI_MODEL is required")

        # Default Headers
        default_headers = {"x-ms-useragent": USER_AGENT}

        azure_openai_client = AsyncAzureOpenAI(
            api_version=app_settings.azure_openai.preview_api_version,
            azure_ad_token_provider=ad_token_provider,
            default_headers=default_headers,
            azure_endpoint=endpoint,
        )

        return azure_openai_client
    except Exception as e:
        logging.exception("Exception in Azure OpenAI initialization", e)
        span = trace.get_current_span()
        if span is not None:
            span.record_exception(e)
            span.set_status(Status(StatusCode.ERROR, str(e)))
        azure_openai_client = None
        raise e


# Initialize Azure Foundry SDK client
async def init_ai_foundry_client():
    ai_foundry_client = None
    try:
        track_event_if_configured("AIFoundryClientInitializationStart", {"status": "success"})
        # API version check
        if (
            app_settings.azure_openai.preview_api_version
            < MINIMUM_SUPPORTED_AZURE_OPENAI_PREVIEW_API_VERSION
        ):
            raise ValueError(
                f"The minimum supported Azure OpenAI preview API version is"
                f"'{MINIMUM_SUPPORTED_AZURE_OPENAI_PREVIEW_API_VERSION}'"
            )

        # Project Endpoint check
        if (
            not app_settings.azure_ai.agent_endpoint
        ):
            raise ValueError(
                "AZURE_AI_AGENT_ENDPOINT is required"
            )

        ai_project_client = AIProjectClient(
            endpoint=app_settings.azure_ai.agent_endpoint,
            credential=DefaultAzureCredential()
        )
        track_event_if_configured("AIFoundryAgentEndpointUsed", {
            "endpoint": app_settings.azure_ai.agent_endpoint
        })
        ai_foundry_client = await ai_project_client.inference.get_azure_openai_client(
            api_version=app_settings.azure_openai.preview_api_version,
        )
        return ai_foundry_client
    except Exception as e:
        logging.exception("Exception in AI Foundry initialization", e)
        ai_foundry_client = None
        raise e

async def setup_agent_thread_with_search(user_messages: list, system_instruction: str, field_mapping: dict):
    project_client = AIProjectClient(
        endpoint=app_settings.azure_ai.agent_endpoint,
        credential=DefaultAzureCredential(exclude_interactive_browser_credential=False),
        api_version="2025-05-01"
    )

    print(f"Project Client: {project_client}", flush=True)

    print(f"Creating project index...", flush=True)
    print(f"Datasource connection name: {app_settings.datasource.connection_name}", flush=True)
    print(f"Index name: {app_settings.datasource.index}", flush=True)
    project_index = await project_client.indexes.create_or_update(
        name=f"project-index-{app_settings.datasource.connection_name}-{app_settings.datasource.index}", 
        version="1",
        body={
            "connectionName": app_settings.datasource.connection_name,
            "indexName": app_settings.datasource.index,
            "type": "AzureSearch",
            "fieldMapping": field_mapping
        }
    )
    print(f"Project Index: {project_index}", flush=True)

    ai_search = AzureAISearchTool(
        index_asset_id=f"{project_index.name}/versions/{project_index.version}",
        index_connection_id=None,
        index_name=None,
        query_type=AzureAISearchQueryType.VECTOR_SEMANTIC_HYBRID,
        top_k=app_settings.datasource.top_k,
        filter="",
    )
    print(f"AI Search Tool: {ai_search}", flush=True)

    agent = await project_client.agents.create_agent(
        model=app_settings.azure_ai.agent_model_deployment_name,
        name="DocGenAgent",
        instructions=system_instruction,
        tools=ai_search.definitions,
        tool_resources=ai_search.resources,
    )
    print(f"Agent created: {agent}", flush=True)

    thread = await project_client.agents.threads.create()
    print(f"Thread created: {thread}", flush=True)

    for msg in user_messages:
        if not msg or "role" not in msg or "content" not in msg:
            continue  # skip malformed messages
        
        if msg["role"] != "tool":
            await project_client.agents.messages.create(
                thread_id=thread.id,
                role=msg["role"],
                content=msg["content"],
            )
            
    # print("Messages in thread after creation:")
    # messages = project_client.agents.messages.list(thread_id=thread.id)

    # for msg in messages:
    #     if msg.text_messages:  # Only print if there's content
    #         print(f"[{msg.role}] {msg.text_messages[-1].text.value}", flush=True)
    print(f"Message sent to thread: {thread.id}", flush=True)

    return project_client, agent, thread

def init_ai_search_client():
    client = None

    try:
        endpoint = app_settings.datasource.endpoint
        key_credential = app_settings.datasource.key
        index_name = app_settings.datasource.index
        client = SearchClient(
            endpoint=endpoint,
            index_name=index_name,
            credential=AzureKeyCredential(key_credential),
        )
        return client
    except Exception as e:
        logging.exception("Exception in Azure AI Client initialization", e)
        span = trace.get_current_span()
        if span is not None:
            span.record_exception(e)
            span.set_status(Status(StatusCode.ERROR, str(e)))
        raise e


def init_cosmosdb_client():
    cosmos_conversation_client = None
    if app_settings.chat_history:
        try:
            cosmos_endpoint = (
                f"https://{app_settings.chat_history.account}.documents.azure.com:443/"
            )

            if not app_settings.chat_history.account_key:
                credential = DefaultAzureCredential()
            else:
                credential = app_settings.chat_history.account_key

            cosmos_conversation_client = CosmosConversationClient(
                cosmosdb_endpoint=cosmos_endpoint,
                credential=credential,
                database_name=app_settings.chat_history.database,
                container_name=app_settings.chat_history.conversations_container,
                enable_message_feedback=app_settings.chat_history.enable_feedback,
            )
        except Exception as e:
            logging.exception("Exception in CosmosDB initialization", e)
            span = trace.get_current_span()
            if span is not None:
                span.record_exception(e)
                span.set_status(Status(StatusCode.ERROR, str(e)))
            cosmos_conversation_client = None
            raise e
    else:
        logging.debug("CosmosDB not configured")

    return cosmos_conversation_client


def prepare_model_args(request_body, request_headers):
    chat_type = None
    if "chat_type" in request_body:
        chat_type = (
            ChatType.BROWSE
            if not (
                request_body["chat_type"] and request_body["chat_type"] == "template"
            )
            else ChatType.TEMPLATE
        )
        track_event_if_configured("ChatTypeDetected", {"chat_type": str(chat_type)})

    request_messages = request_body.get("messages", [])
    messages = []
    messages = [
        {
            "role": "system",
            "content": (
                app_settings.azure_openai.system_message
                if chat_type == ChatType.BROWSE or not chat_type
                else app_settings.azure_openai.template_system_message
            ),
        }
    ]

    for message in request_messages:
        if message:
            messages.append({"role": message["role"], "content": message["content"]})

    user_json = None
    if MS_DEFENDER_ENABLED:
        authenticated_user_details = get_authenticated_user_details(request_headers)
        user_json = get_msdefender_user_json(
            authenticated_user_details, request_headers
        )
        track_event_if_configured("MSDefenderUserJsonGenerated", {
            "user_id": authenticated_user_details.get("user_principal_id")
        })

    model_args = {
        "messages": messages,
        "temperature": app_settings.azure_openai.temperature,
        "max_tokens": app_settings.azure_openai.max_tokens,
        "top_p": app_settings.azure_openai.top_p,
        "stop": app_settings.azure_openai.stop_sequence,
        "stream": (
            app_settings.azure_openai.stream if chat_type == ChatType.BROWSE else False
        ),
        "model": app_settings.azure_openai.model,
        "user": user_json,
    }

    track_event_if_configured("ModelArgsInitialized", {
        "model": model_args["model"],
        "stream": model_args["stream"]
    })

    if app_settings.datasource:
        model_args["extra_body"] = {
            "data_sources": [
                app_settings.datasource.construct_payload_configuration(request=request)
            ]
        }
    model_args_clean = copy.deepcopy(model_args)
    if model_args_clean.get("extra_body"):
        secret_params = [
            "key",
            "connection_string",
            "embedding_key",
            "encoded_api_key",
            "api_key",
        ]
        for secret_param in secret_params:
            if model_args_clean["extra_body"]["data_sources"][0]["parameters"].get(
                secret_param
            ):
                model_args_clean["extra_body"]["data_sources"][0]["parameters"][
                    secret_param
                ] = "*****"
        authentication = model_args_clean["extra_body"]["data_sources"][0][
            "parameters"
        ].get("authentication", {})
        for field in authentication:
            if field in secret_params:
                model_args_clean["extra_body"]["data_sources"][0]["parameters"][
                    "authentication"
                ][field] = "*****"
        embeddingDependency = model_args_clean["extra_body"]["data_sources"][0][
            "parameters"
        ].get("embedding_dependency", {})
        if "authentication" in embeddingDependency:
            for field in embeddingDependency["authentication"]:
                if field in secret_params:
                    model_args_clean["extra_body"]["data_sources"][0]["parameters"][
                        "embedding_dependency"
                    ]["authentication"][field] = "*****"

    logging.debug(f"REQUEST BODY: {json.dumps(model_args_clean, indent=4)}")

    return model_args

# Conversion of citation markers
def convert_citation_markers(text, doc_mapping):
    def replace_marker(match):
        key = match.group(1)
        if key not in doc_mapping:
            doc_mapping[key] = f"[{len(doc_mapping) + 1}]"
        return doc_mapping[key]

    return re.sub(r'【(\d+:\d+)†source】', replace_marker, text)

async def extract_citations_from_run_steps(project_client, thread_id, run_id, answer, streamed_titles=None):
    streamed_titles = streamed_titles or set()
    
    async for run_step in project_client.agents.run_steps.list(thread_id=thread_id, run_id=run_id):
        if isinstance(run_step.step_details, RunStepToolCallDetails):
            for tool_call in run_step.step_details.tool_calls:
                if "azure_ai_search" in tool_call:
                    output_data = tool_call["azure_ai_search"].get("output")
                    if output_data:
                        tool_output = ast.literal_eval(output_data) if isinstance(output_data, str) else output_data
                        metadata = tool_output.get("metadata", {})
                        urls = metadata.get("get_urls", [])
                        titles = metadata.get("titles", [])

                        for i, title in enumerate(titles):
                            url = urls[i] if i < len(urls) else ""

                            if not streamed_titles or title in streamed_titles:
                                existing = next((c for c in answer["citations"] if c["title"] == title), None)
                                if existing:
                                    existing["url"] = url
                                else:
                                    answer["citations"].append({"title": title, "url": url})


async def send_chat_request(request_body, request_headers) -> AsyncGenerator[Dict[str, Any], None]:
    filtered_messages = []
    messages = request_body.get("messages", [])
    for message in messages:
        if message.get("role") != "tool":
            filtered_messages.append(message)
    track_event_if_configured("MessagesFiltered", {
        "original_count": len(messages),
        "filtered_count": len(filtered_messages)
    })
    request_body["messages"] = filtered_messages
    model_args = prepare_model_args(request_body, request_headers)
    chat_type = (
            ChatType.BROWSE
            if not (
                request_body["chat_type"] and request_body["chat_type"] == "template"
            )
            else ChatType.TEMPLATE
        )

    try:
        if app_settings.base_settings.use_ai_foundry_sdk:
            try:
                # Use AI Foundry SDK for response
                track_event_if_configured("Foundry_sdk_for_response", {"status": "success"})
                answer: Dict[str, Any] = {"answer": "", "citations": []}
                agent = None
                run_id = None
                streamed_titles = set()
                doc_mapping = {}
                field_mapping = {
                    "contentFields": ["content"],
                    "urlField": "sourceurl",       # make sure your index has this field
                    "titleField": "sourceurl",     # fallback to filename if needed
                }
                project_client, agent, thread = await setup_agent_thread_with_search(
                    user_messages=request_body["messages"],
                    system_instruction=(
                        app_settings.azure_openai.system_message
                        if chat_type == ChatType.BROWSE or not chat_type
                        else app_settings.azure_openai.template_system_message
                    ),
                    field_mapping=field_mapping
                )
                # Streaming Browse
                if request_body["chat_type"] == "browse" and app_settings.azure_openai.stream:
                    print("Streaming browse")
                    async with await project_client.agents.runs.stream(
                        thread_id=thread.id,
                        agent_id=agent.id,
                        tool_choice={"type": "azure_ai_search"}
                    ) as stream:
                        async for event_type, event_data, _ in stream:
                            if isinstance(event_data, ThreadRun):
                                run_id = event_data.id  # Save for post-processing

                            elif isinstance(event_data, MessageDeltaChunk):
                                if event_data.delta.content and isinstance(event_data.delta.content[0], MessageDeltaTextContent):
                                    delta_text = event_data.delta.content[0].text

                                    if delta_text and delta_text.value:
                                        answer["answer"] += delta_text.value
                                        print(f"Delta text value: {delta_text.value}", flush=True)
                                        yield {
                                            "answer": convert_citation_markers(delta_text.value, doc_mapping),
                                            "citations": answer["citations"]
                                        }

                                    if delta_text and delta_text.annotations:
                                        for annotation in delta_text.annotations:
                                            if isinstance(annotation, MessageDeltaTextUrlCitationAnnotation):
                                                citation = annotation.url_citation
                                                if citation.url not in [c["url"] for c in answer["citations"]]:
                                                    answer["citations"].append({
                                                        "title": citation.title,
                                                        "url": citation.url
                                                    })
                                                    streamed_titles.add(citation.title)  # Track titles seen in streaming

                    print(f"Streaming completed for thread: {thread.id}", flush=True)

                    # Post-processing citations from run_steps
                    if run_id:
                        await extract_citations_from_run_steps(project_client, thread.id, run_id, answer, streamed_titles)

                    yield {
                        # "answer": answer["answer"],
                        "citations": answer["citations"]
                    }
                # Non streaming Browse or Template
                else:
                    print("Non-streaming browse or template")
                    run = await project_client.agents.runs.create_and_process(
                        thread_id=thread.id,
                        agent_id=agent.id,
                        tool_choice={"type": "azure_ai_search"}
                    )
                    if run.status == "failed":
                        print(f"Run failed: {run.error_message}", flush=True)
                        raise Exception(f"Run failed: {run.error_message}")
                    else:
                        await extract_citations_from_run_steps(project_client, thread.id, run.id, answer)
                        messages = project_client.agents.messages.list(thread_id=thread.id)
                        async for msg in messages:
                            if msg.role == MessageRole.AGENT and msg.text_messages:
                                answer["answer"] = msg.text_messages[-1].text.value
                                answer["answer"] = convert_citation_markers(answer["answer"], doc_mapping)
                                break
                    yield {
                        "answer": answer["answer"],
                        "citations": answer["citations"]
                    }
            finally:
                if agent:
                    try:
                        await project_client.agents.delete_agent(agent.id)
                        print(f"Agent deleted: {agent.id}", flush=True)
                    except Exception as cleanup_error:
                        print(f"Failed to clean up agent: {cleanup_error}", flush=True)

        
        else:
            # Use Azure Open AI client for response
            track_event_if_configured("Openai_sdk_for_response", {"status": "success"})
            azure_openai_client = init_openai_client()
            raw_response = (
                await azure_openai_client.chat.completions.with_raw_response.create(
                    **model_args
                )
            )
            response = raw_response.parse()
            apim_request_id = raw_response.headers.get("apim-request-id")

            track_event_if_configured("ChatCompletionSuccess", {
                "apim_request_id": apim_request_id,
                "message_count": len(filtered_messages)
            })

    except Exception as e:
        logging.exception("Exception in send_chat_request")
        span = trace.get_current_span()
        if span is not None:
            span.record_exception(e)
            span.set_status(Status(StatusCode.ERROR, str(e)))
        raise e

async def complete_chat_request(request_body, request_headers):
    # response, apim_request_id = await send_chat_request(request_body, request_headers)
    response = None
    history_metadata = request_body.get("history_metadata", {})
    
    async for chunk in send_chat_request(request_body, request_headers):
        response = chunk  # Only the last chunk matters for non-streaming

    return format_non_streaming_response(response, history_metadata)



async def stream_chat_request(request_body, request_headers):
    track_event_if_configured("StreamChatRequestStart", {
        "has_history_metadata": "history_metadata" in request_body
    })
    # response, apim_request_id = await send_chat_request(request_body, request_headers)
    history_metadata = request_body.get("history_metadata", {})

    async def generate():
        async for chunk in send_chat_request(request_body, request_headers):
            yield format_stream_response(chunk, history_metadata)

    return generate()


async def conversation_internal(request_body, request_headers):
    try:
        chat_type = (
            ChatType.BROWSE
            if not (
                request_body["chat_type"] and request_body["chat_type"] == "template"
            )
            else ChatType.TEMPLATE
        )
        track_event_if_configured("ConversationRequestReceived", {
            "chat_type": str(chat_type),
            "streaming_enabled": app_settings.azure_openai.stream
        })
        if app_settings.azure_openai.stream and chat_type == ChatType.BROWSE:
            result = await stream_chat_request(request_body, request_headers)
            response = await make_response(format_as_ndjson(result))
            response.timeout = None
            response.mimetype = "application/json-lines"
            track_event_if_configured("ConversationStreamResponsePrepared", {
                "response": response
            })
            return response
        else:
            result = await complete_chat_request(request_body, request_headers)
            track_event_if_configured("ConversationCompleteResponsePrepared", {
                "result": json.dumps(result)
            })
            return jsonify(result)

    except Exception as ex:
        logging.exception(ex)
        span = trace.get_current_span()
        if span is not None:
            span.record_exception(ex)
            span.set_status(Status(StatusCode.ERROR, str(ex)))

        if hasattr(ex, "status_code"):
            return jsonify({"error": str(ex)}), ex.status_code
        else:
            return jsonify({"error": str(ex)}), 500


@bp.route("/conversation", methods=["POST"])
async def conversation():
    if not request.is_json:
        track_event_if_configured("InvalidRequestFormat", {
            "status_code": 415,
            "detail": "Request must be JSON"
        })
        return jsonify({"error": "request must be json"}), 415
    request_json = await request.get_json()

    return await conversation_internal(request_json, request.headers)


@bp.route("/frontend_settings", methods=["GET"])
def get_frontend_settings():
    try:
        return jsonify(frontend_settings), 200
    except Exception as e:
        logging.exception("Exception in /frontend_settings")
        span = trace.get_current_span()
        if span is not None:
            span.record_exception(e)
            span.set_status(Status(StatusCode.ERROR, str(e)))
        return jsonify({"error": str(e)}), 500


# Conversation History API #
@bp.route("/history/generate", methods=["POST"])
async def add_conversation():
    authenticated_user = get_authenticated_user_details(request_headers=request.headers)
    user_id = authenticated_user["user_principal_id"]

    if not user_id:
        track_event_if_configured("UserIdNotFound", {"status_code": 400, "detail": "no user"})

    # check request for conversation_id
    request_json = await request.get_json()
    conversation_id = request_json.get("conversation_id", None)

    try:
        # make sure cosmos is configured
        cosmos_conversation_client = init_cosmosdb_client()
        if not cosmos_conversation_client:
            track_event_if_configured("CosmosNotConfigured", {"error": "CosmosDB is not configured"})
            raise Exception("CosmosDB is not configured or not working")

        # check for the conversation_id, if the conversation is not set, we will create a new one
        history_metadata = {}
        if not conversation_id:
            title = await generate_title(request_json["messages"])
            conversation_dict = await cosmos_conversation_client.create_conversation(
                user_id=user_id, title=title
            )
            conversation_id = conversation_dict["id"]
            history_metadata["title"] = title
            history_metadata["date"] = conversation_dict["createdAt"]

        # Format the incoming message object in the "chat/completions" messages format
        # then write it to the conversation history in cosmos
        messages = request_json["messages"]
        if len(messages) > 0 and messages[-1]["role"] == "user":
            createdMessageValue = await cosmos_conversation_client.create_message(
                uuid=str(uuid.uuid4()),
                conversation_id=conversation_id,
                user_id=user_id,
                input_message=messages[-1],
            )

            track_event_if_configured("MessageCreated", {
                "conversation_id": conversation_id,
                "message_id": json.dumps(messages[-1]),
                "user_id": user_id
            })
            if createdMessageValue == "Conversation not found":
                track_event_if_configured("ConversationNotFound", {"conversation_id": conversation_id})
                raise Exception(
                    "Conversation not found for the given conversation ID: "
                    + conversation_id
                    + "."
                )
        else:
            track_event_if_configured("NoUserMessage", {"status_code": 400, "detail": "No user message found"})
            raise Exception("No user message found")

        await cosmos_conversation_client.cosmosdb_client.close()

        # Submit request to Chat Completions for response
        request_body = await request.get_json()
        history_metadata["conversation_id"] = conversation_id
        request_body["history_metadata"] = history_metadata
        track_event_if_configured("ConversationHistoryGenerated", {"conversation_id": conversation_id})
        return await conversation_internal(request_body, request.headers)

    except Exception as e:
        logging.exception("Exception in /history/generate")
        span = trace.get_current_span()
        if span is not None:
            span.record_exception(e)
            span.set_status(Status(StatusCode.ERROR, str(e)))
        return jsonify({"error": str(e)}), 500


@bp.route("/history/update", methods=["POST"])
async def update_conversation():
    authenticated_user = get_authenticated_user_details(request_headers=request.headers)
    user_id = authenticated_user["user_principal_id"]

    if not user_id:
        track_event_if_configured("UserIdNotFound", {"status_code": 400, "detail": "no user"})

    # check request for conversation_id
    request_json = await request.get_json()
    conversation_id = request_json.get("conversation_id", None)

    try:
        # make sure cosmos is configured
        cosmos_conversation_client = init_cosmosdb_client()
        if not cosmos_conversation_client:
            track_event_if_configured("CosmosNotConfigured", {"error": "CosmosDB is not configured"})
            raise Exception("CosmosDB is not configured or not working")

        # check for the conversation_id, if the conversation is not set, we will create a new one
        if not conversation_id:
            track_event_if_configured("MissingConversationId", {"error": "No conversation_id in request"})
            raise Exception("No conversation_id found")

        # Format the incoming message object in the "chat/completions" messages format
        # then write it to the conversation history in cosmos
        messages = request_json["messages"]
        if len(messages) > 0 and messages[-1]["role"] == "assistant":
            if len(messages) > 1 and messages[-2].get("role", None) == "tool":
                # write the tool message first
                await cosmos_conversation_client.create_message(
                    uuid=str(uuid.uuid4()),
                    conversation_id=conversation_id,
                    user_id=user_id,
                    input_message=messages[-2],
                )
            # write the assistant message
            await cosmos_conversation_client.create_message(
                uuid=messages[-1]["id"],
                conversation_id=conversation_id,
                user_id=user_id,
                input_message=messages[-1],
            )
        else:
            track_event_if_configured("NoAssistantMessage", {"status_code": 400, "detail": "No bot message found"})
            raise Exception("No bot messages found")

        # Submit request to Chat Completions for response
        await cosmos_conversation_client.cosmosdb_client.close()
        track_event_if_configured("ConversationHistoryUpdated", {"conversation_id": conversation_id})
        response = {"success": True}
        return jsonify(response), 200

    except Exception as e:
        logging.exception("Exception in /history/update")
        span = trace.get_current_span()
        if span is not None:
            span.record_exception(e)
            span.set_status(Status(StatusCode.ERROR, str(e)))
        return jsonify({"error": str(e)}), 500


@bp.route("/history/message_feedback", methods=["POST"])
async def update_message():
    authenticated_user = get_authenticated_user_details(request_headers=request.headers)
    user_id = authenticated_user["user_principal_id"]
    cosmos_conversation_client = init_cosmosdb_client()

    # check request for message_id
    request_json = await request.get_json()
    message_id = request_json.get("message_id", None)
    message_feedback = request_json.get("message_feedback", None)
    try:
        if not message_id:
            logging.error("Missing message_id", extra={'request_json': request_json})
            track_event_if_configured("MissingMessageId", {"status_code": 400, "request_json": request_json})
            return jsonify({"error": "message_id is required"}), 400

        if not message_feedback:
            logging.error("Missing message_feedback", extra={'request_id': request_json})
            track_event_if_configured("MissingMessageFeedback", {"status_code": 400, "request_json": request_json})
            return jsonify({"error": "message_feedback is required"}), 400

        # update the message in cosmos
        updated_message = await cosmos_conversation_client.update_message_feedback(
            user_id, message_id, message_feedback
        )
        if updated_message:
            track_event_if_configured("MessageFeedbackUpdated", {
                "message_id": message_id,
                "message_feedback": message_feedback
            })
            logging.info("Message feedback updated", extra={'message_id': message_id})
            return (
                jsonify(
                    {
                        "message": f"Successfully updated message with feedback {message_feedback}",
                        "message_id": message_id,
                    }
                ),
                200,
            )
        else:
            logging.warning("Message not found or access denied", extra={'request_json': request_json})
            track_event_if_configured("MessageNotFoundOrAccessDenied", {
                "status_code": 404,
                "request_json": request_json
            })
            return (
                jsonify(
                    {
                        "error": f"Unable to update message {message_id}. "
                        "It either does not exist or the user does not have access to it."
                    }
                ),
                404,
            )

    except Exception as e:
        logging.exception("Exception in /history/message_feedback")
        span = trace.get_current_span()
        if span is not None:
            span.record_exception(e)
            span.set_status(Status(StatusCode.ERROR, str(e)))
        return jsonify({"error": str(e)}), 500


@bp.route("/history/delete", methods=["DELETE"])
async def delete_conversation():
    # get the user id from the request headers
    authenticated_user = get_authenticated_user_details(request_headers=request.headers)
    user_id = authenticated_user["user_principal_id"]

    # check request for conversation_id
    request_json = await request.get_json()
    conversation_id = request_json.get("conversation_id", None)

    try:
        if not conversation_id:
            track_event_if_configured("MissingConversationId", {"error": "No conversation_id in request", "request_json": request_json})
            return jsonify({"error": "conversation_id is required"}), 400

        # make sure cosmos is configured
        cosmos_conversation_client = init_cosmosdb_client()
        if not cosmos_conversation_client:
            track_event_if_configured("CosmosDBNotConfigured", {
                "user_id": user_id,
                "conversation_id": conversation_id
            })
            raise Exception("CosmosDB is not configured or not working")

        # delete the conversation messages from cosmos first
        await cosmos_conversation_client.delete_messages(conversation_id, user_id)

        # Now delete the conversation
        await cosmos_conversation_client.delete_conversation(user_id, conversation_id)

        await cosmos_conversation_client.cosmosdb_client.close()

        track_event_if_configured("ConversationDeleted", {
            "user_id": user_id,
            "conversation_id": conversation_id,
            "status": "success"
        })

        return (
            jsonify(
                {
                    "message": "Successfully deleted conversation and messages",
                    "conversation_id": conversation_id,
                }
            ),
            200,
        )
    except Exception as e:
        logging.exception("Exception in /history/delete")
        span = trace.get_current_span()
        if span is not None:
            span.record_exception(e)
            span.set_status(Status(StatusCode.ERROR, str(e)))
        return jsonify({"error": str(e)}), 500


@bp.route("/history/list", methods=["GET"])
async def list_conversations():
    offset = request.args.get("offset", 0)
    authenticated_user = get_authenticated_user_details(request_headers=request.headers)
    user_id = authenticated_user["user_principal_id"]

    # make sure cosmos is configured
    cosmos_conversation_client = init_cosmosdb_client()
    if not cosmos_conversation_client:
        track_event_if_configured("CosmosDBNotConfigured", {
            "user_id": user_id,
            "error": "CosmosDB is not configured or not working"
        })
        raise Exception("CosmosDB is not configured or not working")

    # get the conversations from cosmos
    conversations = await cosmos_conversation_client.get_conversations(user_id, offset=offset, limit=25)
    await cosmos_conversation_client.cosmosdb_client.close()
    if not isinstance(conversations, list):
        track_event_if_configured("NoConversationsFound", {
            "user_id": user_id,
            "status": "No conversations found"
        })
        return jsonify({"error": f"No conversations for {user_id} were found"}), 404

    # return the conversation ids
    track_event_if_configured("ConversationsListed", {
        "user_id": user_id,
        "conversation_count": len(conversations),
        "status": "success"
    })
    return jsonify(conversations), 200


@bp.route("/history/read", methods=["POST"])
async def get_conversation():
    authenticated_user = get_authenticated_user_details(request_headers=request.headers)
    user_id = authenticated_user["user_principal_id"]

    # check request for conversation_id
    request_json = await request.get_json()
    conversation_id = request_json.get("conversation_id", None)

    if not conversation_id:
        track_event_if_configured("MissingConversationId", {
            "user_id": user_id,
            "error": "conversation_id is required"
        })
        return jsonify({"error": "conversation_id is required"}), 400

    # make sure cosmos is configured
    cosmos_conversation_client = init_cosmosdb_client()
    if not cosmos_conversation_client:
        track_event_if_configured("CosmosDBNotConfigured", {
            "user_id": user_id,
            "error": "CosmosDB is not configured or not working"
        })
        raise Exception("CosmosDB is not configured or not working")

    # get the conversation object and the related messages from cosmos
    conversation = await cosmos_conversation_client.get_conversation(
        user_id, conversation_id
    )
    # return the conversation id and the messages in the bot frontend format
    if not conversation:
        track_event_if_configured("ConversationNotFound", {
            "user_id": user_id,
            "conversation_id": conversation_id,
            "error": "Conversation not found or access denied"
        })
        return (
            jsonify(
                {
                    "error": (
                        f"Conversation {conversation_id} was not found. "
                        "It either does not exist or the logged in user does not have access to it."
                    )
                }
            ),
            404,
        )

    # get the messages for the conversation from cosmos
    conversation_messages = await cosmos_conversation_client.get_messages(
        user_id, conversation_id
    )

    # format the messages in the bot frontend format
    messages = [
        {
            "id": msg["id"],
            "role": msg["role"],
            "content": msg["content"],
            "createdAt": msg["createdAt"],
            "feedback": msg.get("feedback"),
        }
        for msg in conversation_messages
    ]

    track_event_if_configured("ConversationRead", {
        "user_id": user_id,
        "conversation_id": conversation_id,
        "message_count": len(messages),
        "status": "success"
    })
    await cosmos_conversation_client.cosmosdb_client.close()
    return jsonify({"conversation_id": conversation_id, "messages": messages}), 200


@bp.route("/history/rename", methods=["POST"])
async def rename_conversation():
    authenticated_user = get_authenticated_user_details(request_headers=request.headers)
    user_id = authenticated_user["user_principal_id"]

    # check request for conversation_id
    request_json = await request.get_json()
    conversation_id = request_json.get("conversation_id", None)

    if not conversation_id:
        track_event_if_configured("MissingConversationId", {
            "user_id": user_id,
            "error": "conversation_id is required",
            "request_json": request_json
        })
        return jsonify({"error": "conversation_id is required"}), 400

    # make sure cosmos is configured
    cosmos_conversation_client = init_cosmosdb_client()
    if not cosmos_conversation_client:
        track_event_if_configured("CosmosDBNotConfigured", {
            "user_id": user_id,
            "error": "CosmosDB not configured or not working"
        })
        raise Exception("CosmosDB is not configured or not working")

    # get the conversation from cosmos
    conversation = await cosmos_conversation_client.get_conversation(
        user_id, conversation_id
    )
    if not conversation:
        track_event_if_configured("ConversationNotFoundForRename", {
            "user_id": user_id,
            "conversation_id": conversation_id,
            "error": "Conversation not found or access denied"
        })
        return (
            jsonify(
                {
                    "error": (
                        f"Conversation {conversation_id} was not found. "
                        "It either does not exist or the logged in user does not have access to it."
                    )
                }
            ),
            404,
        )

    # update the title
    title = request_json.get("title", None)
    if not title or title.strip() == "":
        track_event_if_configured("MissingTitle", {
            "user_id": user_id,
            "conversation_id": conversation_id,
            "error": "title is required"
        })
        return jsonify({"error": "title is required"}), 400
    conversation["title"] = title
    updated_conversation = await cosmos_conversation_client.upsert_conversation(
        conversation
    )

    await cosmos_conversation_client.cosmosdb_client.close()
    track_event_if_configured("ConversationRenamed", {
        "user_id": user_id,
        "conversation_id": conversation_id,
        "new_title": title
    })
    return jsonify(updated_conversation), 200


@bp.route("/history/delete_all", methods=["DELETE"])
async def delete_all_conversations():
    # get the user id from the request headers
    authenticated_user = get_authenticated_user_details(request_headers=request.headers)
    user_id = authenticated_user["user_principal_id"]

    # get conversations for user
    try:
        # make sure cosmos is configured
        cosmos_conversation_client = init_cosmosdb_client()
        if not cosmos_conversation_client:
            track_event_if_configured("CosmosDBNotConfigured", {
                "user_id": user_id,
                "error": "CosmosDB is not configured or not working"
            })
            raise Exception("CosmosDB is not configured or not working")

        conversations = await cosmos_conversation_client.get_conversations(
            user_id, offset=0, limit=None
        )
        if not conversations:
            track_event_if_configured("NoConversationsToDelete", {
                "user_id": user_id,
                "status": "No conversations found"
            })
            return jsonify({"error": f"No conversations for {user_id} were found"}), 404

        # delete each conversation
        for conversation in conversations:
            # delete the conversation messages from cosmos first
            await cosmos_conversation_client.delete_messages(
                conversation["id"], user_id
            )

            # Now delete the conversation
            await cosmos_conversation_client.delete_conversation(
                user_id, conversation["id"]
            )
        await cosmos_conversation_client.cosmosdb_client.close()
        track_event_if_configured("AllConversationsDeleted", {
            "user_id": user_id,
            "deleted_count": len(conversations)
        })
        return (
            jsonify(
                {
                    "message": f"Successfully deleted conversation and messages for user {user_id}"
                }
            ),
            200,
        )

    except Exception as e:
        logging.exception("Exception in /history/delete_all")
        span = trace.get_current_span()
        if span is not None:
            span.record_exception(e)
            span.set_status(Status(StatusCode.ERROR, str(e)))
        return jsonify({"error": str(e)}), 500


@bp.route("/history/clear", methods=["POST"])
async def clear_messages():
    # get the user id from the request headers
    authenticated_user = get_authenticated_user_details(request_headers=request.headers)
    user_id = authenticated_user["user_principal_id"]

    # check request for conversation_id
    request_json = await request.get_json()
    conversation_id = request_json.get("conversation_id", None)

    try:
        if not conversation_id:
            return jsonify({"error": "conversation_id is required"}), 400

        # make sure cosmos is configured
        cosmos_conversation_client = init_cosmosdb_client()
        if not cosmos_conversation_client:
            raise Exception("CosmosDB is not configured or not working")

        # delete the conversation messages from cosmos
        await cosmos_conversation_client.delete_messages(conversation_id, user_id)

        return (
            jsonify(
                {
                    "message": "Successfully deleted messages in conversation",
                    "conversation_id": conversation_id,
                }
            ),
            200,
        )
    except Exception as e:
        logging.exception("Exception in /history/clear_messages")
        span = trace.get_current_span()
        if span is not None:
            span.record_exception(e)
            span.set_status(Status(StatusCode.ERROR, str(e)))
        return jsonify({"error": str(e)}), 500


@bp.route("/history/ensure", methods=["GET"])
async def ensure_cosmos():
    if not app_settings.chat_history:
        return jsonify({"error": "CosmosDB is not configured"}), 404

    try:
        cosmos_conversation_client = init_cosmosdb_client()
        success, err = await cosmos_conversation_client.ensure()
        if not cosmos_conversation_client or not success:
            if err:
                track_event_if_configured("CosmosEnsureFailed", err)
                return jsonify({"error": err}), 422
            return jsonify({"error": "CosmosDB is not configured or not working"}), 500

        track_event_if_configured("CosmosEnsureSuccess", {"status": "working"})
        await cosmos_conversation_client.cosmosdb_client.close()
        return jsonify({"message": "CosmosDB is configured and working"}), 200
    except Exception as e:
        logging.exception("Exception in /history/ensure")
        cosmos_exception = str(e)
        if "Invalid credentials" in cosmos_exception:
            return jsonify({"error": cosmos_exception}), 401
        elif "Invalid CosmosDB database name" in cosmos_exception:
            return (
                jsonify(
                    {
                        "error": f"{cosmos_exception} {app_settings.chat_history.database} for account {app_settings.chat_history.account}"
                    }
                ),
                422,
            )
        elif "Invalid CosmosDB container name" in cosmos_exception:
            return (
                jsonify(
                    {
                        "error": f"{cosmos_exception}: {app_settings.chat_history.conversations_container}"
                    }
                ),
                422,
            )
        else:
            return jsonify({"error": "CosmosDB is not working"}), 500


@bp.route("/section/generate", methods=["POST"])
async def generate_section_content():
    request_json = await request.get_json()
    try:
        # verify that section title and section description are provided
        if "sectionTitle" not in request_json:
            track_event_if_configured("GenerateSectionFailed", {"error": "sectionTitle missing", "request_json": request_json})
            return jsonify({"error": "sectionTitle is required"}), 400

        if "sectionDescription" not in request_json:
            track_event_if_configured("GenerateSectionFailed", {"error": "sectionDescription missing", "request_json": request_json})
            return jsonify({"error": "sectionDescription is required"}), 400

        content = await get_section_content(request_json, request.headers)
        track_event_if_configured("GenerateSectionSuccess", {
            "sectionTitle": request_json["sectionTitle"]
        })
        return jsonify({"section_content": content}), 200
    except Exception as e:
        logging.exception("Exception in /section/generate")
        span = trace.get_current_span()
        if span is not None:
            span.record_exception(e)
            span.set_status(Status(StatusCode.ERROR, str(e)))
        return jsonify({"error": str(e)}), 500


@bp.route("/document/<filepath>")
async def get_document(filepath):
    try:
        document = retrieve_document(filepath)
        track_event_if_configured("DocumentRetrieved", {"filepath": filepath})

        return jsonify(document), 200
    except Exception as e:
        logging.exception("Exception in /document/<filepath>")
        span = trace.get_current_span()
        if span is not None:
            span.record_exception(e)
            span.set_status(Status(StatusCode.ERROR, str(e)))
        return jsonify({"error": str(e)}), 500

@bp.route("/fetch-azure-search-content", methods=["POST"])
async def fetch_azure_search_content():
    try:
        print("Fetching content from Azure Search")
        request_json = await request.get_json()
        url = request_json.get("url")
        
        if not url:
            track_event_if_configured("FetchAzureSearchContentFailed", {"error": "URL is required"})
            return jsonify({"error": "URL is required"}), 400
        
        #Get Azure AD token
        credential = DefaultAzureCredentialSync()
        token = credential.get_token("https://search.azure.com/.default")
        access_token = token.token
        
        def fetch_content():
            try:
                response = requests.get(
                    url,
                    headers={
                        "Authorization": f"Bearer {access_token}",
                        "Content-Type": "application/json"
                    },
                    timeout=10
                )
                if response.status_code == 200:
                    data = response.json()
                    content = data.get("content", "")
                    return content
                else:
                    return 
            except Exception as e:
                logging.exception("Error fetching content from Azure Search")
                print(f"Error fetching content from Azure Search: {str(e)}")
                return f"Error: {str(e)}"
        
        content = await asyncio.to_thread(fetch_content)
        return jsonify({"content": content}), 200
                
    except Exception as e:
        logging.exception("Exception in /fetch-azure-search-content")
        return jsonify({"error": str(e)}), 500


async def generate_title(conversation_messages):
    # make sure the messages are sorted by _ts descending
    title_prompt = app_settings.azure_openai.title_prompt

    messages = [
        {"role": msg["role"], "content": msg["content"]}
        for msg in conversation_messages
    ]
    messages.append({"role": "user", "content": title_prompt})

    try:
        response = None
        if app_settings.base_settings.use_ai_foundry_sdk:
            # Use Foundry SDK for title generation
            track_event_if_configured("Foundry_sdk_for_title", {"status": "success"})
            ai_foundry_client = await init_ai_foundry_client()
            response = await ai_foundry_client.chat.completions.create(
                model=app_settings.azure_openai.model,
                messages=messages,
                temperature=1,
                max_tokens=64,
            )
        else:
            # Use Azure OpenAI client for title generation
            track_event_if_configured("Openai_sdk_for_title", {"status": "success"})
            azure_openai_client = init_openai_client()
            response = await azure_openai_client.chat.completions.create(
                model=app_settings.azure_openai.model,
                messages=messages,
                temperature=1,
                max_tokens=64,
            )
        raw_content = response.choices[0].message.content
        raw_content = raw_content.strip()
        if raw_content.startswith("{{") and raw_content.endswith("}}"):
            raw_content = raw_content[1:-1]  # Remove one set of braces

        # Extract JSON object
        json_match = re.search(r"\{.*?\}", raw_content, re.DOTALL)
        if not json_match:
            raise ValueError("No JSON object found in response")

        json_str = json_match.group()
        title = json.loads(json_str)["title"]
        track_event_if_configured("TitleGenerated", {"title": title})
        return title
    except Exception as e:
        logging.exception("Exception in generate_title" + str(e))
        return messages[-2]["content"]


async def get_section_content(request_body, request_headers):    
    user_prompt = f"""sectionTitle: {request_body['sectionTitle']}
    sectionDescription: {request_body['sectionDescription']}
    """
    print(f"Generating section content for: {request_body['sectionTitle']}")
    agent = None

    # messages = [{"role": "assistant", "content": app_settings.azure_openai.system_message}]
    messages = []
    messages.append({"role": "user", "content": user_prompt})

    request_body["messages"] = messages
    model_args = prepare_model_args(request_body, request_headers)

    try:
        raw_response = None
        if app_settings.base_settings.use_ai_foundry_sdk:
            # Use Foundry SDK for section content generation
            track_event_if_configured("Foundry_sdk_for_section", {"status": "success"})
            print("Foundry_sdk_for_section")
            # ai_foundry_client = await init_ai_foundry_client()
            # raw_response = await ai_foundry_client.chat.completions.with_raw_response.create(
            #     **model_args
            # )
            print("Draft system prompt")
            print(app_settings.azure_openai.generate_section_content_prompt)
            field_mapping = {
                    "contentFields": ["content"],
                    "urlField": "sourceurl",       # make sure your index has this field
                    "titleField": "sourceurl",     # fallback to filename if needed
                }
            project_client, agent, thread = await setup_agent_thread_with_search(
                user_messages=request_body["messages"],
                system_instruction=app_settings.azure_openai.generate_section_content_prompt,
                field_mapping=field_mapping
            )
            run = await project_client.agents.runs.create_and_process(
                        thread_id=thread.id,
                        agent_id=agent.id,
                        tool_choice={"type": "azure_ai_search"}
                    )
            if run.status == "failed":
                print(f"Run failed: {run.error_message}")
                raise Exception(f"Run failed: {run.error_message}")
            else:
                message = (
                    await project_client.agents.messages.get_last_message_text_by_role(
                        thread_id=thread.id, role=MessageRole.AGENT
                    )
                )
                if message:
                    response_text = message.text.value
        else:
            # Use Azure OpenAI client for section content generation
            track_event_if_configured("Openai_sdk_for_section", {"status": "success"})
            azure_openai_client = init_openai_client()
            raw_response = (
                await azure_openai_client.chat.completions.with_raw_response.create(
                    **model_args
                )
            )
            response = raw_response.parse()
        track_event_if_configured("SectionContentGenerated", {
            "sectionTitle": request_body["sectionTitle"]
        })

    except Exception as e:
        logging.exception("Exception in send_chat_request")
        span = trace.get_current_span()
        if span is not None:
            span.record_exception(e)
            span.set_status(Status(StatusCode.ERROR, str(e)))
        raise e
    
    finally:
        if agent:
            try:
                await project_client.agents.delete_agent(agent.id)
                print(f"Agent deleted: {agent.id}", flush=True)
            except Exception as cleanup_error:
                print(f"Failed to clean up agent: {cleanup_error}", flush=True)
            

    return response_text


def retrieve_document(filepath):
    try:
        search_client = init_ai_search_client()
        search_query = f"sourceurl eq '{filepath}'"
        # Execute the search query
        results = search_client.search(search_query)
        track_event_if_configured("DocumentSearchSuccess", {"filepath": filepath})

        # Get the full_content of the first result
        document = next(results)
        return document
    except Exception as e:
        logging.exception("Exception in retrieve_document")
        span = trace.get_current_span()
        if span is not None:
            span.record_exception(e)
            span.set_status(Status(StatusCode.ERROR, str(e)))
        raise e


app = create_app()
