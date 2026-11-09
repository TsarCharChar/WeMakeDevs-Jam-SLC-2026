
from fastapi import FastAPI

app = FastAPI(title="ConFellow API")


@app.get("/")
def home():
    return {"message": "ConFellow backend is running"}


@app.get("/healthz")
def health():
    return {"status": "healthy"}


@app.get("/readyz")
def readiness():
    return {"status": "ready"}


@app.get("/querysession")
def query_session(topic: str):
    sessions = [
        {"id": 1, "title": "Introduction to Kubernetes", "topic": "Kubernetes"},
        {"id": 2, "title": "Cloud Security", "topic": "Security"},
        {"id": 3, "title": "Advanced Kubernetes", "topic": "Kubernetes"},
    ]

    results = [
        session for session in sessions
        if topic.lower() in session["topic"].lower()
    ]

    return {"sessions": results}
