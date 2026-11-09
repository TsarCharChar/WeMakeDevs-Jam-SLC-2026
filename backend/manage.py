"""Generate explicit provisioning input or expire a bounded batch of transcripts."""

import argparse
import asyncio
import json
from pathlib import Path

from backend.config import Settings
from backend.schema import conversation_mapping
from backend.vector_store import StoreError, VectorStore, create_client


async def expire(limit):
    settings = Settings.from_env()
    async with create_client(settings) as client:
        store = VectorStore(settings, client)
        await store.ready()
        print(json.dumps(await store.expire(limit)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    schema = commands.add_parser(
        "schema", help="Write Elastic CLI indices-create input; makes no network requests"
    )
    schema.add_argument("--inference-id", required=True)
    schema.add_argument("--alias", default="conversation-garden-conversations")
    schema.add_argument("--index", default="conversation-garden-conversations-v1")
    schema.add_argument("--output", type=Path, required=True)
    expiry = commands.add_parser("expire", help="Remove text/vectors from up to 100 expired conversations")
    expiry.add_argument("--limit", type=int, default=100, choices=range(1, 101), metavar="1..100")
    args = parser.parse_args()
    try:
        if args.command == "schema":
            if args.alias == args.index:
                parser.error("Index and alias names must differ")
            content = {
                "index": args.index,
                "aliases": {args.alias: {"is_write_index": True}},
                "mappings": conversation_mapping(args.inference_id),
            }
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(content, indent=2) + "\n", encoding="utf-8")
            print(f"Wrote provisioning input to {args.output}; no index was changed")
        else:
            asyncio.run(expire(args.limit))
    except (StoreError, ValueError) as exc:
        parser.exit(1, f"{exc}\n")


if __name__ == "__main__":
    main()
