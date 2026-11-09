"""Load a KubeCon schedule file into the `talks` index of the Elasticsearch project in .env.

GET /search, GET /graph and GET /recommendations read `talks`, and nothing else in this repo fills it.
Create the indices first with `node --env-file-if-exists=.env scripts/elastic.mjs setup`.

    python3 scripts/load-talks.py <schedule.json> .env            # dry run: shows what would be sent
    python3 scripts/load-talks.py <schedule.json> .env --write    # sends it

The schedule file is a JSON list of sessions with id, title, abstract, start, end, room and tags, as in
the Flutter app's assets/data/kubecon_schedule.json. Re-running replaces each talk by its id.

Each talk becomes one document shaped for the repo's `talks` mapping: title, abstract, content
(title and abstract together, which Elasticsearch embeds), topics, start, end, room, conference.
Speaker names are not in the schedule file and are not sent. Logistics rows are skipped.
"""

import json
import re
import sys
import urllib.error
import urllib.request

CONFERENCE = "cnh"
MOUNTAIN_STANDARD = "-07:00"  # Salt Lake City in November
BATCH = 40
# Level and format tags say how a session runs, not what it is about.
NOT_TOPICS = {
    "any level", "beginner", "intermediate", "advanced", "end user talk", "maintainer track", "sponsored",
    "cloud native theater", "project lightning talks", "sponsor demo theater", "keynote sessions",
    "solutions showcase", "experiences", "learning lounge", "cloud native university", "cloud native experience",
}
LOGISTICS = re.compile(r"registration|badge|coat \+ bag|bag check|breakfast|lunch|coffee break|shuttle|\bclosed\b", re.I)


def read_env(path):
    values = {}
    for line in open(path, encoding="utf-8"):
        if "=" in line and not line.lstrip().startswith("#"):
            key, _, value = line.strip().partition("=")
            values[key] = value
    return values["ELASTICSEARCH_URL"].rstrip("/"), values["ELASTICSEARCH_API_KEY"]


def topics_of(session):
    tags = [tag.strip() for tag in session.get("tags") or [] if isinstance(tag, str)]
    return [tag for tag in tags if tag and tag[0].isalnum() and tag.lower() not in NOT_TOPICS][:8]


def documents(schedule):
    for session in schedule:
        title, abstract = (session.get("title") or "").strip(), (session.get("abstract") or "").strip()
        topics = topics_of(session)
        if not title or not abstract or not topics or LOGISTICS.search(title):
            continue
        yield session["id"], {
            "conference": CONFERENCE,
            "title": title,
            "abstract": abstract,
            "content": f"{title}\n\n{abstract}",
            "topics": topics,
            "start": session["start"] + MOUNTAIN_STANDARD,
            "end": session["end"] + MOUNTAIN_STANDARD,
            "room": (session.get("room") or "").replace(" | ", " · "),
        }


def bulk(url, key, batch):
    lines = []
    for doc_id, source in batch:
        lines += [json.dumps({"index": {"_index": "talks", "_id": doc_id}}), json.dumps(source)]
    request = urllib.request.Request(
        url + "/_bulk?refresh=wait_for",
        data=("\n".join(lines) + "\n").encode(),
        headers={"Authorization": "ApiKey " + key, "Content-Type": "application/x-ndjson"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            body = json.load(response)
    except urllib.error.HTTPError as error:
        raise SystemExit(f"Elasticsearch refused the batch: HTTP {error.code} {error.read()[:300]!r}") from None
    failed = [item["index"] for item in body["items"] if item["index"].get("error")]
    if failed:
        raise SystemExit(f"{len(failed)} documents failed, first: {json.dumps(failed[0])[:400]}")
    return len(body["items"])


def main():
    schedule_path, env_path, write = sys.argv[1], sys.argv[2], "--write" in sys.argv[3:]
    docs = list(documents(json.load(open(schedule_path, encoding="utf-8"))))
    print(f"{len(docs)} talks to load into conference {CONFERENCE!r}")
    if not write:
        print("dry run, nothing sent. Sample:")
        print(json.dumps(docs[0][1] | {"abstract": docs[0][1]["abstract"][:90] + "…", "content": "…"}, indent=2))
        return
    url, key = read_env(env_path)
    sent = 0
    for start in range(0, len(docs), BATCH):
        sent += bulk(url, key, docs[start : start + BATCH])
        print(f"  {sent}/{len(docs)}", flush=True)
    print("done")


if __name__ == "__main__":
    main()
