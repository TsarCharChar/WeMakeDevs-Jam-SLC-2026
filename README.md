# Mobile app development

Backend geospatial search and opt-in presence preparation are documented in
[Geospatial conversation presence](docs/geospatial.md). This initial backend
slice retains synthetic-only search; attendee check-in persistence and Flutter
location controls are not connected yet.

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

The bottom blob opens a typed-interest search preview. It does not return invented matches or send requests. No server is connected. Audio is streamed in memory; the transcript is kept only in the current app session. Starting another recording clears the previous transcript. Only record with participants' permission.

The model is bundled as a Flutter asset and copied into app-private storage on first recording. This adds roughly 574 MB to the app assets and another 574 MB to app storage; first-use copying and inference require additional RAM. Real-time performance with this large model must be measured on target phones.

Validation commands: `flutter analyze` and `flutter test`. Widget tests cover denied microphone permission recovery, the home actions, search navigation, empty-interest validation, preview behavior, and narrow layouts with enlarged text. They do not validate native speech recognition.

Current verification: static analysis and all three widget tests pass. The first Android debug build stopped because the license for Whisper's NDK `29.0.13113456` has not been accepted. In Android Studio, open SDK Manager > SDK Tools, enable Show Package Details, and install that NDK version after reviewing its license. Then retry the build. No APK or on-device transcription run has been verified yet.

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
