"""
AIRKit Qdrant MCP tool server.

Read-only hybrid (dense + BM25 sparse) search over the three collections
defined in schema/qdrant/collections.yaml. Ingestion/indexing is
deliberately NOT exposed here — this server can only query, never write,
so an agent (or attacker-controlled text it has ingested) cannot poison
the playbook/rule/history corpus through this tool.
"""

import os
from typing import Any

from mcp.server.fastmcp import FastMCP
from qdrant_client import QdrantClient
from qdrant_client.models import FieldCondition, Filter, MatchAny

QDRANT_ENDPOINT = os.environ["AIRKIT_QDRANT_ENDPOINT"]
EMBEDDING_MODEL_NAME = os.environ.get("AIRKIT_EMBEDDING_MODEL", "bge-large-en-v1.5")

VALID_COLLECTIONS = {"playbooks", "detection_rules", "incident_history"}
# Which payload field each collection uses for category-style filtering,
# per schema/qdrant/collections.yaml. Kept here rather than hardcoded per
# call so adding a collection later is a one-line change.
CATEGORY_FIELD = {
    "playbooks": "applies_to_categories",
    "detection_rules": "mitre_attack_techniques",
    "incident_history": None,  # no category field defined for this collection
}

mcp = FastMCP("airkit-qdrant-tool")
_client = QdrantClient(url=QDRANT_ENDPOINT)


def _embed(text: str) -> list[float]:
    """
    Embeds query text with the same model used at ingestion time.
    Swapping AIRKIT_EMBEDDING_MODEL requires re-indexing every collection —
    see schema/qdrant/collections.yaml's note on embedding model consistency.
    """
    # Placeholder call-out to whatever local embedding server the
    # deployment runs (e.g. a small sentence-transformers model served
    # alongside SGLang). Left as an explicit dependency injection point
    # rather than hardcoding a specific embedding backend here.
    from airkit_embeddings import embed_text  # local module, deployment-specific

    return embed_text(text, model=EMBEDDING_MODEL_NAME)


@mcp.tool()
def search_vector_playbooks(
    query: str,
    collection: str,
    top_k: int = 5,
    category_filter: list[str] | None = None,
) -> list[dict[str, Any]]:
    """Hybrid search a Qdrant collection; returns top_k payloads with scores."""
    if collection not in VALID_COLLECTIONS:
        raise ValueError(f"Unknown collection {collection!r}. Must be one of {sorted(VALID_COLLECTIONS)}.")

    query_filter = None
    if category_filter:
        field = CATEGORY_FIELD.get(collection)
        if field is None:
            raise ValueError(f"Collection {collection!r} has no category field to filter on.")
        query_filter = Filter(must=[FieldCondition(key=field, match=MatchAny(any=category_filter))])

    vector = _embed(query)

    results = _client.query_points(
        collection_name=collection,
        query=vector,
        query_filter=query_filter,
        limit=top_k,
        with_payload=True,
        # Hybrid search per collections.yaml: dense vector + BM25 sparse
        # fusion. Exact fusion API depends on the Qdrant client version in
        # use at deploy time; this call assumes a server-side hybrid
        # search config attached to the collection itself (RRF fusion),
        # so the client only needs to supply the dense query vector.
    )

    return [
        {
            "score": point.score,
            "payload": point.payload,
        }
        for point in results.points
    ]


if __name__ == "__main__":
    mcp.run()
