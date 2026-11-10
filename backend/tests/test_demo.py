from fastapi.testclient import TestClient

from backend.config import Settings
from backend.main import create_app


def test_web_preview_and_schedule_are_served():
    with TestClient(create_app(Settings())) as client:
        page = client.get("/demo/")
        assert page.status_code == 200
        assert "<title>ConFellow</title>" in page.text
        schedule = client.get("/demo/schedule.json")
        assert schedule.status_code == 200
        assert schedule.json()[0]["title"]
        bare = client.get("/demo", follow_redirects=False)
        assert bare.headers["location"] == "/demo/"
