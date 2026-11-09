# Mobile app development

Backend geospatial search and opt-in presence preparation are documented in
[Geospatial conversation presence](docs/geospatial.md). Optional geographic
filters work on authenticated `/matches` and synthetic `/querysession` search;
attendee check-in persistence and Flutter location controls are not connected yet.

## Prerequisites

- Install the [Flutter SDK](https://docs.flutter.dev/install) (includes Dart) and add its `bin` directory to PATH.
- For Android, follow the [Android tooling setup](https://docs.flutter.dev/platform-integration/android/setup), including Android Studio, SDK tools, and a device or emulator.
- For iOS builds, use a Mac with [Xcode and the iOS tooling](https://docs.flutter.dev/platform-integration/ios/setup).
- Install Git and PowerShell. The model download script also requires `curl` (`curl.exe` on Windows).

Validate your Flutter installation:

```powershell
flutter doctor --android-licenses
flutter doctor -v
flutter devices
```

## Run the MVP

After downloading the model below, run:

```powershell
flutter pub get
flutter run -d <device-id>
```

If Flutter is not on PATH on this machine, use `& 'C:\Users\Char\flutter\bin\flutter.bat'` instead of `flutter`.

Android requires API 24 or newer. Install Android SDK Command-line Tools in Android Studio's SDK Manager and run `flutter doctor --android-licenses` if doctor reports them missing. Native Whisper also requires NDK `29.0.13113456` and CMake `3.22.1` (Gradle may install them when SDK licenses are accepted). Use a physical ARM64 phone to evaluate speed and memory usage. For a debug APK: `flutter build apk --debug --target-platform android-arm64`.

iOS requires macOS/Xcode and deployment target 15.6 or newer. iOS builds have not been validated on this Windows machine. This MVP targets Android and iOS, not web.

The top blob starts microphone capture and on-device Whisper transcription; tap again to stop. Permission denial, model preparation, recording, and finalization have visible states. Recording stops after three minutes or when the app goes into the background. Live transcript events replace the full displayed text, rather than appending duplicate partial results. English is the current transcription language.

The bottom blob opens typed-interest search. Submitting 2–120 characters calls `GET /querysession?topic=...` on `https://grindset.cnh.radarhq.io`. The screen shows loading, results, no matches, or a retryable error. This search still uses a synthetic demo conversation; attendee matching is not implemented. Audio is streamed in memory and stays on the phone. Only record with participants' permission.

### Realtime transcript saving

Tap **Enable realtime saving**, choose a device handle and conference (default `cnh`), and explicitly agree to transcript uploads. The app claims an attendee with `PUT /me` and keeps the returned token, random stream ID, next sequence and pending text in platform secure storage. No database credentials or service token belong in Flutter. This device owns one stream; its profile is separate from profiles created on another device. A lost profile-creation response can leave the handle claimed without a usable token; choose a new handle in that case.

While recording, the latest complete text snapshot is checkpointed and uploaded around every two seconds. One request stays in flight, with newer text coalesced locally. Stopping sends a final revision immediately after any earlier pending request is acknowledged. Retries reuse the exact request; an acknowledgement means the backend accepted the Elasticsearch write. **Saved transcripts** reads ordered history from the backend, including partial recordings. Private transcripts are not published to demo search, attendee search, moments or the graph.

The outbox holds at most eight pending recordings with 20,000 characters per segment. Recording stops near the text limit or after three minutes. Offline recordings remain encrypted on the device; after five failed attempts, use **Retry sync** or resume the app to try again. Conflicts and expired segments stop automatic uploads and retain pending text; they are never overwritten by blindly increasing a revision. **Renew session** refreshes an existing attendee profile using its token. It cannot recover a deleted profile or a lost token. Disabling realtime saving pauses queued uploads and makes new recordings local only. Turning it back on resumes the previously consented queue; it does not upload recordings made while saving was disabled.

Saved history expires from API access after seven days; this is not a physical deletion guarantee. Finalized, acknowledged text is cleared from the local outbox. A normal background transition stops transcription and saves the final snapshot; the OS does not guarantee background network execution, so pending uploads resume when the app opens. Abrupt termination can lose text produced since the last durable checkpoint. Keep the app open if a secure-storage error is shown. Clearing app data or losing the secure token loses access to this device's history. Changing `API_BASE_URL` does not send saved credentials to the new server.

The Android app disables backups for secure-storage compatibility. iOS signing configurations include Keychain entitlements; native iOS validation still requires macOS/Xcode. The API contract is in [docs/transcript-api.md](docs/transcript-api.md).

For an opt-in end-to-end check on an Android device: `flutter run -d <device-id> -t test_driver/transcript_smoke.dart --no-resident`. This creates one synthetic attendee and two tiny transcripts, verifies a partial before finalization, then verifies finalization, secure-session restoration, append order and history. It uses a separate local storage key, deletes that key afterward, and prints only `TRANSCRIPT_SMOKE PASS` or `FAIL`. It does not record audio or access real attendee text. The synthetic server records expire under the backend retention policy. Restore the normal app afterward with `flutter run -d <device-id> -t lib/main.dart --no-resident`.

Override the backend origin for another HTTPS environment with `flutter run --dart-define=API_BASE_URL=https://your-api.example`. Use an HTTPS origin without a path, query, or credentials. Never put an Elasticsearch API key in a Flutter build. Search uses the backend response `{"conversations":[{"id":"...","conference":"...","transcript":"..."}]}`; the backend owns embedding and access control. Native Android includes the Internet permission; iOS uses HTTPS without transport-security exceptions.

The model is bundled as a Flutter asset and copied into app-private storage on first recording. This adds roughly 574 MB to the app assets and another 574 MB to app storage; first-use copying and inference require additional RAM. Real-time performance with this large model must be measured on target phones.

Validation commands: `flutter analyze` and `flutter test`. API and widget tests cover query encoding, validation, response parsing, network failures, loading, duplicate-submit prevention, results, empty results, retries, leaving during a request, microphone permission recovery, and narrow layouts with enlarged text. They do not validate native speech recognition.

The first Android debug build stopped because the license for Whisper's NDK `29.0.13113456` has not been accepted. In Android Studio, open SDK Manager > SDK Tools, enable Show Package Details, and install that NDK version after reviewing its license. Then retry the build. No APK or on-device transcription run has been verified yet.

## Download the offline speech model

We use **Whisper large-v3-turbo, Q5_0 quantization**, in whisper.cpp's GGML format. Model weights are downloaded separately and excluded from Git: cloning this repository does **not** download them. Git LFS is not required.

From the repository root, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\download-model.ps1
```

On macOS or Linux with PowerShell installed, run `pwsh -NoProfile -File ./scripts/download-model.ps1`.

The script downloads approximately **574 MB** to `assets/models/ggml-large-v3-turbo-q5_0.bin`, verifies its SHA-256 checksum, and skips downloading an existing verified copy. Allow enough free space for the model and a temporary download. If a download fails, rerun the command.

The model is included by `pubspec.yaml` and loaded through `whisper_ggml` 2.9.0. Download it before building or running tests. It remains excluded from Git; contributors and CI fetch it separately.

### Model provenance

- Original model: [openai/whisper-large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo)
- Converted weights: [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp)
- Pinned revision: `5359861c739e955e79d9a303bcbc70fb988958b1`
- File: `ggml-large-v3-turbo-q5_0.bin`
- Size: `574041195` bytes
- SHA-256: `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2`

The model is MIT licensed; retain the applicable license and notices when redistributing it. See the [upstream model license](https://huggingface.co/openai/whisper-large-v3-turbo) and [whisper.cpp license](https://github.com/ggml-org/whisper.cpp/blob/master/LICENSE).
