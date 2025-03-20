from azure.core.credentials import AzureKeyCredential
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient
from openai import AzureOpenAI
import re
import time
from azure.search.documents import SearchClient
from azure.storage.filedatalake import DataLakeServiceClient
import pypdf
from io import BytesIO
from azure.search.documents.indexes import SearchIndexClient

key_vault_name = 'kv_to-be-replaced'
managed_identity_client_id = 'mici_to-be-replaced'
file_system_client_name = "data"
directory = 'pdf'


def get_secrets_from_kv(kv_name, secret_name):
    credential = DefaultAzureCredential(managed_identity_client_id=managed_identity_client_id)
    secret_client = SecretClient(vault_url=f"https://{kv_name}.vault.azure.net/", credential=credential)
    return secret_client.get_secret(secret_name).value


search_endpoint = get_secrets_from_kv(key_vault_name, "AZURE-SEARCH-ENDPOINT")
search_key = get_secrets_from_kv(key_vault_name, "AZURE-SEARCH-KEY")
openai_api_key = get_secrets_from_kv(key_vault_name, "AZURE-OPENAI-KEY")
openai_api_base = get_secrets_from_kv(key_vault_name, "AZURE-OPENAI-ENDPOINT")
openai_api_version = get_secrets_from_kv(key_vault_name, "AZURE-OPENAI-PREVIEW-API-VERSION")
deployment = get_secrets_from_kv(key_vault_name, "AZURE-OPEN-AI-DEPLOYMENT-MODEL")


def get_embeddings(text: str, openai_api_base, openai_api_version, openai_api_key):
    model_id = "text-embedding-ada-002"
    client = AzureOpenAI(
        api_version=openai_api_version,
        azure_endpoint=openai_api_base,
        api_key=openai_api_key
    )
    return client.embeddings.create(input=text, model=model_id).data[0].embedding


def clean_spaces_with_regex(text):
    cleaned_text = re.sub(r'\s+', ' ', text)
    cleaned_text = re.sub(r'\.{2,}', '.', cleaned_text)
    return cleaned_text


def chunk_data(text):
    tokens_per_chunk = 1024
    text = clean_spaces_with_regex(text)
    sentences = text.split('. ')
    chunks = []
    current_chunk = ''
    current_chunk_token_count = 0

    for sentence in sentences:
        tokens = sentence.split()
        if current_chunk_token_count + len(tokens) <= tokens_per_chunk:
            if current_chunk:
                current_chunk += '. ' + sentence
            else:
                current_chunk += sentence
            current_chunk_token_count += len(tokens)
        else:
            chunks.append(current_chunk)
            current_chunk = sentence
            current_chunk_token_count = len(tokens)

    if current_chunk:
        chunks.append(current_chunk)

    return chunks


account_name = get_secrets_from_kv(key_vault_name, "ADLS-ACCOUNT-NAME")
account_url = f"https://{account_name}.dfs.core.windows.net"
credential = DefaultAzureCredential()
service_client = DataLakeServiceClient(account_url, credential=credential, api_version='2023-01-03')
file_system_client = service_client.get_file_system_client(file_system_client_name)
paths = file_system_client.get_paths(path=directory)
index_name = "pdf_index"
search_credential = AzureKeyCredential(search_key)
search_client = SearchClient(search_endpoint, index_name, search_credential)
index_client = SearchIndexClient(endpoint=search_endpoint, credential=search_credential)


def prepare_search_doc(content, document_id):
    chunks = chunk_data(content)
    docs = []
    for chunk_num, chunk in enumerate(chunks, start=1):
        chunk_id = f"{document_id}_{str(chunk_num).zfill(2)}"
        try:
            v_contentVector = get_embeddings(chunk, openai_api_base, openai_api_version, openai_api_key)
        except Exception:
            time.sleep(30)
            try:
                v_contentVector = get_embeddings(chunk, openai_api_base, openai_api_version, openai_api_key)
            except Exception:
                v_contentVector = []
        result = {
            "id": chunk_id,
            "chunk_id": chunk_id,
            "content": chunk,
            "sourceurl": path.name.split('/')[-1],
            "contentVector": v_contentVector
        }
        docs.append(result)
    return docs


docs = []
counter = 0
for path in paths:
    file_client = file_system_client.get_file_client(path.name)
    pdf_file = file_client.download_file()
    stream = BytesIO()
    pdf_file.readinto(stream)
    pdf_reader = pypdf.PdfReader(stream)
    filename = path.name.split('/')[-1]
    document_id = filename.split('_')[1].replace('.pdf', '')
    text = ''.join(page.extract_text() for page in pdf_reader.pages)
    docs.extend(prepare_search_doc(text, document_id))
    counter += 1
    if docs and counter % 10 == 0:
        search_client.upload_documents(documents=docs)
        docs = []
        print(f'{counter} uploaded')

if docs:
    search_client.upload_documents(documents=docs)
