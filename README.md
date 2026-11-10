# ConFellow — Find Your Conference Wavelength

**ConFellow** is a privacy-first native mobile app (Flutter for Android & iOS) backed by **Elasticsearch Serverless** (`semantic_text` / `.jina-embeddings-v5-text-small`) and **FastAPI** on Kubernetes (`https://grindset.cnh.radarhq.io`). Attendees speak or type quick personal notes, tune into KubeCon schedule topics and talks on a standing-wave constellation scope, match semantically with shared attendee notes, and jump into topic or session chat rooms — without accounts, passwords, or uploading raw audio.

---

## Install the Android Demo APK (No Build Required)

Download `ConFellow-demo-arm64.apk` (`137 MB`, includes the quantized offline Whisper speech model and 600-session KubeCon schedule):

- **Google Drive (Anyone with the link):** [Download `ConFellow-demo-arm64.apk` from Google Drive](https://drive.google.com/file/d/1fxSIh_kZ5mCSnpYdxE_DqtGNze2UPKq1/view?usp=sharing)
- **GitHub Release (`v1.0.0`):** [Direct APK Download](https://github.com/TsarCharChar/WeMakeDevs-Jam-SLC-2026/releases/download/v1.0.0/ConFellow-demo-arm64.apk) · [Release Notes](https://github.com/TsarCharChar/WeMakeDevs-Jam-SLC-2026/releases/tag/v1.0.0)
- **SHA-256:** `f2cdde37fb9f0f08381c469c9af6a2284a48cda191022c17c7b7b18337f9ccfd` (`143,256,368` bytes)

### Installation Steps on an Android Phone

1. **Android 64-bit ARM phones only (`arm64-v8a`):** Open either link above directly on your Android phone and download `ConFellow-demo-arm64.apk`. *(This release APK targets physical ARM64 phones rather than `x86_64` desktop emulators.)*
2. Tap the downloaded `.apk` file in your browser downloads or **Files** app.
3. When Android asks, **allow your browser / Files app to install unknown apps**.
4. If Google Play Protect warns that it does not recognize the developer, tap **More details → Install anyway**.
5. Launch **ConFellow**, optionally enter a display name and pick a few starter topics (or tap **Skip**), and grant microphone access when recording a voice note.

---

## How ConFellow Works

### 1. First Launch & Zero-Account Identity
- Every phone generates an opaque attendee handle (`cf_<20-hex>`) and claims an attendee bearer token via `PUT /me`, stored exclusively in platform-encrypted storage (`FlutterSecureStorage` — Keystore on Android, Keychain on iOS).
- On first launch you can optionally enter a **display name** (`display_name`, shown next to messages you send in chat rooms; otherwise `guest-xxxxxx` is used) and pick starter topics, or tap **Skip** to start immediately.

### 2. Note Tab (On-Device Voice + Text Capture & Undo)
- **Voice notes (`MicHalo` + offline Whisper):** Tap the `128×128` microphone button once to record (up to 3 minutes; coral `#FF7A59` indicates live mic capture) and tap again to stop. Speech is transcribed **on your phone** using quantized `whisper.cpp` (`ggml-base.en-q5_1.bin`). Raw audio stays in memory on your phone and is never written to disk or sent to the server.
- **Typed notes:** Tap **Type a note** to type or paste text (text is the only supported input format; there are no file uploads).
- **Undo & Review before sending:** Finishing a note immediately previews matched KubeCon schedule tags (`Tuned: Cilium · Observability`, or `Note saved` when no schedule tag matches — never invented topics) with an **Undo** countdown ring. Enabling **Review before sending** in Settings (`⚙`) holds every note for explicit **Send** or **Discard** (and backgrounding the app automatically holds any pending note for manual review).
- **Private by default, opt-in sharing:** Saved notes upload to your private stream (`PUT /transcripts/{stream_id}/segments/{sequence}`). Toggling **Share this note** marks that finalized segment conference-visible (`PUT /transcripts/{stream_id}/segments/{sequence}/sharing`) so other attendees can match with it semantically without exposing your handle.
- **Find my wavelength:** Syncs your profile (`PUT /me`), refreshes live topic graph counts and co-occurrence links (`GET /graph`), and queries Elasticsearch `semantic_text` vectors (`POST /matches`) using your note or interests.

### 3. Wavelength Scope Tab (Standing-Wave Constellation Map)
- Swipe right or tap **Wavelength** to view `WavelengthScope`: three concentric harmonic rings plotting topics from innermost (strongest personal match) to outer ring, dotted co-occurrence filaments, scheduled talks (diamonds), and your saved notes (orbiting aqua squares).
- Tap any topic or talk node on the scope to open its **Space Discovery Sheet**, which explains *in words* why it is on your wavelength (never opaque match scores or unverified `"nearby"` claims), displays session time & room with an **I'm going** toggle, and provides a **Join the chat** button.

### 4. Interests, Spaces & Topic/Talk Chat Rooms
- **Interests (`InterestsScreen`):** Browse drifting topic bubbles sized by session activity (an aqua dot marks topics co-occurring with your picks), cycle pages with **More**, type custom interests, and tap **Retune my wavelength**.
- **Spaces (`SpacesScreen`) & Chat (`RoomChatScreen`):** View **Your Topics** (with direct **Chat** pills), **Talks You're Going To** (with room and time), and **Shared Notes on Your Wavelength** (280-character excerpts from opted-in attendees). Tapping **Join the chat** or **Chat** enters `topic:<name>` or `talk:<id>` (`GET` / `POST /rooms/{room}/messages`).

---

## Dynamic sessions

Built from a conference organizer's feedback today: when enough people care about a topic right now, the conference gives it a room from space the organizers set aside for live-decided sessions.

Every five minutes, a Kubernetes job counts how many distinct attendees shared a note on each topic in the last 30 minutes (**only shared notes count; private notes are never read**). A topic triggers at **50 people**, or at **5% of attendees with a profile** (with a floor of 3 people). The backend proposes a discussion session and books the earliest free room that organizers designated for dynamic sessions and that fits the group, at least 15 minutes ahead and within four hours; if no room is free yet, the proposal waits and retries on later runs.

Attendees who shared a note on the topic or carry it on their profile receive an alert on `GET /feed` (for example, *"Kubernetes Autoscaling Discussion starts at 3:30 PM in Dynamic Room A."*), and scheduled sessions are listed by `GET /dynamic-sessions`. Organizers control which rooms are eligible and whether booking is automatic, and with an admin token can run a dry run or approve a waiting proposal into a room; `GET /rooms` also lists active chat rooms, busiest first, and flags rooms with high distinct-person activity. Dynamic sessions can be demonstrated with seeded data.

### Status

- The routes and CronJob are deployed. The job does nothing until someone creates the `dynamic_sessions` index and adds designated rooms in Kibana; [docs/dynamic-sessions.md](docs/dynamic-sessions.md) has the steps.
- The mobile app does not show dynamic sessions or alerts yet.
- Organizers are not sent a message; they see activity through the admin dry run, the job's log in Radar, and the traces in Dash0.
- It does not pick a person to lead the session.

Full specification and setup guide: [docs/dynamic-sessions.md](docs/dynamic-sessions.md).

---

## Prerequisites & Building from Source (Flutter Mobile App)

### Prerequisites

- Install the [Flutter SDK](https://docs.flutter.dev/install) (includes Dart) and add its `bin` directory to `PATH`.
- **Android:** Follow the [Android tooling setup](https://docs.flutter.dev/platform-integration/android/setup) (Android Studio, SDK Command-line Tools, API 24+, NDK `29.0.14206865`, and CMake `3.22.1` for native `whisper_ggml` compilation).
- **iOS:** Use a Mac with [Xcode and the iOS tooling](https://docs.flutter.dev/platform-integration/ios/setup) (deployment target iOS 15.6+; an Apple Silicon Mac can also test on the iOS Simulator or Android Studio's ARM64 Android Emulator).
- Install Git, `curl` (`curl.exe` on Windows), and PowerShell (`powershell` on Windows or `pwsh` on macOS/Linux) if using `scripts/download-model.ps1`.

Validate your Flutter toolchain:

```powershell
flutter doctor --android-licenses
flutter doctor -v
flutter devices
```

*(If Flutter is not on `PATH` on Windows, invoke `& 'C:\Users\Char\flutter\bin\flutter.bat'` instead of `flutter`.)*

### 1. Download the Offline Speech Model

We bundle **Whisper `base.en` (`Q5_1` quantization)** in `whisper.cpp` GGML format (`59,721,011` bytes / ~57 MB). Model weights are excluded from Git (`.gitignore` ignores `/assets/models/*.bin`) and verified by byte size and SHA-256 both at download time and before first on-device load.

**Windows (PowerShell):**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\download-model.ps1
```

**macOS / Linux (with PowerShell `pwsh`):**

```bash
pwsh -NoProfile -File ./scripts/download-model.ps1
```

**macOS / Linux (`curl` fallback without PowerShell):**

```bash
mkdir -p assets/models
curl -L --fail --retry 3 \
  -o assets/models/ggml-base.en-q5_1.bin \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.en-q5_1.bin?download=true"
echo "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f  assets/models/ggml-base.en-q5_1.bin" | sha256sum -c -
```

*(On macOS, use `shasum -a 256 -c -` instead of `sha256sum -c -`.)*

#### Model Provenance

- **Original model:** [openai/whisper-base.en](https://huggingface.co/openai/whisper-base.en) (MIT License)
- **Converted weights:** [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp) ([whisper.cpp LICENSE](https://github.com/ggml-org/whisper.cpp/blob/master/LICENSE))
- **Pinned revision:** `5359861c739e955e79d9a303bcbc70fb988958b1`
- **File:** `assets/models/ggml-base.en-q5_1.bin`
- **Size:** `59721011` bytes (~57 MB)
- **SHA-256:** `4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f`

### 2. Run & Build the App

```bash
flutter pub get
flutter run -d <device-id>
```

To build a standalone ARM64 Android release APK for physical phones:

```bash
flutter build apk --release --target-platform android-arm64
```

To build an `x86_64` debug APK for desktop Android emulators:

```bash
flutter build apk --debug --target-platform android-x64
```

To point the app at a custom HTTPS backend origin (never pass Elasticsearch keys or service tokens into Flutter):

```bash
flutter run --dart-define=API_BASE_URL=https://your-api.example
```

### 3. Validate & Smoke-Test

```bash
flutter analyze
flutter test
```

For an opt-in end-to-end private transcript sync check on a connected Android device (uses an isolated storage key, cleans up afterward, and prints `TRANSCRIPT_SMOKE PASS` or `FAIL`):

```bash
flutter run -d <device-id> -t test_driver/transcript_smoke.dart --no-resident
flutter run -d <device-id> -t lib/main.dart --no-resident
```

### Realtime Transcript Saving Details

Opening **Settings (`⚙`) → Saved transcripts** (or using `CloudSyncPanel`) gives access to ordered private transcript history (`GET /transcripts/{stream_id}`) and session renewal. Durable outbox persistence holds up to 8 pending segments (up to 20,000 characters per segment) in `FlutterSecureStorage` with idempotent revision compare-and-set retries, 7-day server TTL expiry, and background pause safety. Android backups are disabled (`android:allowBackup="false"`) and iOS Keychain entitlements are configured for secure credential storage.

---

## Backend, Elasticsearch & Kubernetes Deployment

The backend (`backend/` FastAPI service) runs in Kubernetes namespace `team-grindset` on the Cloud Native Hackathon `grindset` cluster (`https://grindset.cnh.radarhq.io`), deployed via GitHub Actions (`.github/workflows/deploy.yaml`) and Argo CD (`argocd/application.yaml` + `deploy/`).

### Local Backend & Elasticsearch Setup

1. **Environment variables:** Copy `.env.example` to `.env` (gitignored) on the server/workstation and configure `ELASTICSEARCH_URL` and `ELASTICSEARCH_API_KEY` (keep all Elastic credentials strictly server-side).
2. **Initialize & verify indices (`.jina-embeddings-v5-text-small`, 1024-dim `semantic_text`):**
   ```bash
   node --env-file-if-exists=.env scripts/elastic.mjs setup
   node --env-file-if-exists=.env scripts/elastic.mjs status
   node --test server/elastic/store.test.mjs
   ```
   Or run `docs/elastic-setup.http` in Kibana Dev Tools.
3. **Optional live index mappings (`backend/mappings/`):**
   - Display names on `people`: apply `backend/mappings/people-display-name.json` (`PUT people/_mapping` in Kibana Dev Tools). Until applied, the Flutter app automatically retries `PUT /me` without `display_name` on `422`/`503` so onboarding never blocks.
   - Opt-in geospatial presence: apply `backend/mappings/attendee-locations.json` (`PUT /attendee-locations`) and `backend/mappings/conversation-presence.json` (see [docs/geospatial.md](docs/geospatial.md)).
4. **Python backend tests:**
   ```bash
   pytest backend/tests
   ```

### Architecture & API Reference (`docs/`)

- [Architecture Outline](docs/architecture.md)
- [Attendee API (`PUT/GET /me`, `/graph`, `/search`, `/rooms`, `/matches`)](docs/attendee-api.md)
- [Realtime Transcript & Sharing API (`/transcripts`)](docs/transcript-api.md)
- [Elasticsearch Schema & Setup](docs/elasticsearch.md)
- [Dynamic Trending Sessions](docs/dynamic-sessions.md)
- [Geospatial Conversation Presence](docs/geospatial.md)
- [Vector Backend Contract](docs/vector-backend.md)

---

## AI Tools Disclosure

Built at the **Cloud Native Hackathon / WeMakeDevs Jam SLC 2026** with assistance from **Claude Code (Anthropic Claude)**, **Antigravity (Google Gemini)**, and **OpenAI Codex**.
