# ConFellow download website

A buildless, responsive landing page using the app's black/blue phosphor palette, radar geometry, and note-to-topic discovery flow. All preview activity is labeled illustrative; the shipped APK defaults to demo discovery. No attendee data or microphone access is used by the website.

## Local preview

From this workspace's root:

```sh
node website/serve.mjs
```

Open http://127.0.0.1:4173. There are no npm dependencies or build steps. Run release selection tests with `node --test website/release.test.js`.

## GitHub hosting

The `download-website` workflow publishes the five public site files through GitHub Pages. The `github-pages` environment records deployments. In repository Settings → Pages, choose GitHub Actions as the build source. The default address is https://tsarcharchar.github.io/WeMakeDevs-Jam-SLC-2026/.

Both `main` and `feat/confellow-download-site` are allowed to publish so this isolated branch can be previewed without merging the app or deploying the Kubernetes backend. Once merged, remove the feature branch from both new workflows' `push.branches`. The environment must allow the publishing branch. Pull requests only validate and package the website; they cannot deploy it.

## APK releases

`android-demo-release` builds an ARM64 release-mode APK using the project's existing development signing configuration, runs Flutter analysis/tests, fetches the checksum-pinned model through the existing download script, and publishes a GitHub **prerelease** tagged `android-demo-<version>-<run number>`. A separate publish job has `contents: write`; the build job has read-only repository permission. GitHub Actions artifacts are temporary build outputs. GitHub Releases is the durable APK download location; the `android-demo` environment records publication.

The website queries the 30 most recent public releases and selects the newest complete `android-demo-*` release containing `confellow-demo.apk`. It uses the exact asset URL and actual size, and links to its release notes/checksum. It does not use `/releases/latest`, because GitHub excludes prereleases there. Missing releases, rate limits, offline browsers, and disabled JavaScript retain a working link to the Releases page without pretending an APK is available.

The current committed baseline bundles the large Whisper model (roughly 574 MB before packaging). The original checkout's uncommitted smaller-model changes are intentionally not copied into this branch. The release workflow follows the checked-in model script, so those changes will be picked up after they are committed and merged.

Demo signing keys can change on clean CI runners. See `DEMO-RELEASE.md` for installation and upgrade limitations. Production distribution needs a permanent signing key stored in GitHub secrets and a dedicated Gradle signing configuration before publishing production releases.

Design tokens originate in `lib/ui/wavelength_theme.dart`. Product behavior was checked against `lib/main.dart`, `lib/ui/note_capture_and_undo.dart`, and `lib/ui/space_discovery_sheet.dart`.

References: [GitHub release downloads](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases), [GitHub Pages workflows](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).
