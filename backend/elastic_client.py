
import os

from elasticsearch import Elasticsearch


def get_elasticsearch_client():
    """
    Create an Elasticsearch client using environment variables.
    Credentials are stored in Kubernetes Secrets.
    """

    elastic_url = os.getenv("ELASTICSEARCH_URL")
    api_key = os.getenv("ELASTICSEARCH_API_KEY")

    # Return None if credentials are missing
    if not elastic_url or not api_key:
        return None

    return Elasticsearch(
        elastic_url,
        api_key=api_key,
        request_timeout=10,
        max_retries=1
    )
