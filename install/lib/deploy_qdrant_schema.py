#!/usr/bin/env python3
"""
AIRKit Qdrant schema deployment helper.

Reads schema/qdrant/collections.yaml and creates any collection that
doesn't already exist, with hybrid (dense + BM25 sparse) search enabled
per the config. Invoked from install/lib/deploy_qdrant_schema.sh rather
than called directly — this is the one place in the installer where
Bash hands off to Python, because parsing YAML and calling a typed
client library in Bash would be worse than the cost of the handoff.

Idempotent: skips any collection that already exists rather than
recreating it, since re-creating a live collection would drop existing
embeddings.
"""

import sys
from pathlib import Path

import yaml
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, SparseVectorParams, VectorParams

AIRKIT_ROOT = Path(__file__).resolve().parents[2]
COLLECTIONS_CONFIG = AIRKIT_ROOT / "schema" / "qdrant" / "collections.yaml"

_DISTANCE_MAP = {
    "Cosine": Distance.COSINE,
    "Euclid": Distance.EUCLID,
    "Dot": Distance.DOT,
}


def deploy(qdrant_endpoint: str) -> None:
    if not COLLECTIONS_CONFIG.exists():
        print(f"[airkit] FATAL: collections config not found at {COLLECTIONS_CONFIG}", file=sys.stderr)
        raise SystemExit(1)

    with open(COLLECTIONS_CONFIG) as f:
        config = yaml.safe_load(f)

    client = QdrantClient(url=qdrant_endpoint)
    existing = {c.name for c in client.get_collections().collections}

    for collection in config["collections"]:
        name = collection["name"]
        if name in existing:
            print(f"[airkit] collection '{name}' already exists, skipping")
            continue

        distance = _DISTANCE_MAP.get(collection["distance"])
        if distance is None:
            print(f"[airkit] FATAL: unknown distance metric {collection['distance']!r} for collection {name!r}", file=sys.stderr)
            raise SystemExit(1)

        sparse_config = {}
        if collection.get("hybrid_search", {}).get("enabled"):
            # Sparse vector name convention: "<collection>_bm25". Kept
            # consistent so the qdrant_tool MCP server doesn't need
            # per-collection special-casing to know the sparse vector name.
            sparse_config["bm25"] = SparseVectorParams()

        print(f"[airkit] creating collection '{name}'...")
        client.create_collection(
            collection_name=name,
            vectors_config=VectorParams(size=collection["vector_size"], distance=distance),
            sparse_vectors_config=sparse_config or None,
        )
        print(f"[airkit] created collection '{name}' (vector_size={collection['vector_size']}, distance={collection['distance']})")

    print("[airkit] Qdrant schema deployment complete")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: deploy_qdrant_schema.py <qdrant_endpoint>", file=sys.stderr)
        raise SystemExit(1)
    deploy(sys.argv[1])
