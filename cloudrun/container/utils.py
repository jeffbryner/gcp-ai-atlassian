import logging
from google.cloud import secretmanager
import google_crc32c
import google.auth
import vertexai
from vertexai.language_models import TextEmbeddingModel, TextGenerationModel
from tenacity import retry, stop_after_attempt, wait_random_exponential


logging.basicConfig(level=logging.DEBUG)
logger = logging.getLogger()
credentials, PROJECT_ID = google.auth.default()


def get_secret(project_id=PROJECT_ID, secret_id="", version_id="latest"):
    """
    Access the payload for the given secret version if one exists. The version
    can be a version number as a string (e.g. "5") or an alias (e.g. "latest").
    """
    secret_client = secretmanager.SecretManagerServiceClient()

    # Build the resource name of the secret version.
    name = ""
    # terraform likes to send project id as fully qualified projects/project-id-xxxx
    # set the name of the secret accordingly
    if "projects/" in project_id:
        name = f"{project_id}/secrets/{secret_id}/versions/{version_id}"
    else:
        name = f"projects/{project_id}/secrets/{secret_id}/versions/{version_id}"

    # Access the secret version.
    response = secret_client.access_secret_version(request={"name": name})

    # Verify payload checksum.
    crc32c = google_crc32c.Checksum()
    crc32c.update(response.payload.data)
    if response.payload.data_crc32c != int(crc32c.hexdigest(), 16):
        logger.error(f"Data corruption detected when retrieving secret {secret_id}.")
        return "error"
    payload = response.payload.data.decode("UTF-8")
    return f"{payload}"


@retry(wait=wait_random_exponential(min=1, max=60), stop=stop_after_attempt(5))
def text_generation_model_with_backoff(**kwargs):
    vertexai.init(project=PROJECT_ID, location="us-central1")
    generation_model = TextGenerationModel.from_pretrained("text-bison")
    return generation_model.predict(**kwargs).text
