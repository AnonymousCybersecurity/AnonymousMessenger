# Android builds and releases

Gradle/Kotlin owns Android builds, checks and version preparation. Ruby 3.3/Fastlane owns release orchestration, Google Play, notes, GitHub and artifact verification. Windows uses GitHub CLI directly to dispatch CI: no local Ruby is required. No npm, Node, Expo or React Native is introduced. Messenger's existing Python native-alignment checker remains an artifact quality gate.

## Audited existing setup

Inspection on 2026-10-23 confirmed:

- `AnonymousCybersecurity/AnonymousMessenger`, repository ID `1198767196`, default branch `main`, organization ID `272907184`.
- Application ID `it.aitechnology.anonymous` from `app/gradle.properties`; namespace `org.thoughtcrime.securesms`. Modules include `app`, `core`, `core-gms`, `lib`, `feature`, lint and build logic; see `settings.gradle.kts`.
- Gradle 9.4.1, AGP 9.2.1, Kotlin 2.2.20, JDK/bytecode 21, Android platform 36.1, build-tools 36.0.0, target SDK 35, minimum SDK 27, NDK 28.0.13004108. Argon2/native-utils retain their ndk-build sources and 16 KB checks.
- `prodStoreRelease` builds Play AAB/APK with `MANAGE_ANONYMOUS_UPDATES=false`. `prodWebsiteRelease` enables the self-updater. Both use the same package but have different signing identities.
- Existing `v26.10.09-5` assets are `app-prod-website-release-signed.apk` and `index-v1.json`. `ApkUpdateJob` reads them through `/releases/latest/download`. Play APKs must not replace that updater's APK/index.
- Existing secrets are `GH_PAT`, `KEYSTORE_B64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`; no repository variables existed. Values were not read. Website secrets are retained. New GitHub operations use `github.token`; the unused `GH_PAT` secret is not deleted.
- The pre-existing revision edit `5 → 6` and untracked `app/prodStore/release/app-prod-store-release.aab` are preserved. `update.bat` has unrelated merge/commit/force-push behavior and remains unchanged; launchers never invoke it. Existing Makefile/Docker entry points remain available. No existing local build wrapper needed consolidation.

`release-foss.yml` now runs website checks/build on `main` pushes and PRs. Only its manual dispatch signs/publishes website assets. `android-play.yml` has only `workflow_dispatch`. Commits, version changes and tag pushes do not publish. Both publishing workflows serialize in `messenger-publishing`.

The existing published website APK's verified certificate is `6B:09:4A:3D:5F:98:B7:D1:BC:F3:6A:8A:A4:18:05:B0:C8:4B:05:85:82:AE:E6:89:BD:27:08:CC:21:13:51:A4`, pinned in `scripts/artifact-verification.rb`. The saved local AAB has certificate `95:94:6B:99:6D:4D:1E:6E:9D:A0:7F:C2:FA:B8:96:6A:37:6A:15:29:8A:93:62:7C:5F:B7:1A:A1:B3:62:9D:A2`. Actual file signature/package/version checks passed for those artifacts. During guided setup the user supplied the same upload fingerprint from Play Console, and it was compared with the saved AAB again. The user also supplied Messenger's separate Play app signing SHA-256: `BB:61:44:69:31:3A:37:27:4B:F2:00:54:20:65:FD:4C:22:B1:56:4C:1C:9C:9B:2F:7E:88:D1:98:FA:DD:54:9D`. Actual verification of a Google-generated APK against that signing pin remains pending an authorized Both run. Access to the private upload key still needs the signing preflight.

## Build commands

Use JDK 21, the existing Android SDK and the existing registered upload keystore. Set these privately:

| Variable | Meaning |
| --- | --- |
| `CI_KEYSTORE_PATH` | Existing keystore; absolute path or relative to `app/` |
| `CI_KEYSTORE_PASSWORD` | Store password |
| `CI_KEYSTORE_ALIAS` | Existing private-key alias |
| `CI_KEY_PASSWORD` | Key password; defaults to store password for existing callers |

Local shortcuts and CI's `-PrequireReleaseSigning=true` reject missing signing inputs/files. Ordinary Gradle signing behavior is preserved. No key is generated/replaced and no machine configuration or `local.properties` is rewritten.

| Command | Native task and output |
| --- | --- |
| `.\build apk` | `buildLocalApk` → `:app:assembleProdStoreRelease`; `app/build/outputs/apk/prodStore/release/app-prod-store-release.apk` |
| `.\build aab` | `buildLocalAab` → `:app:bundleProdStoreRelease`; `app/build/outputs/bundle/prodStoreRelease/app-prod-store-release.aab` |
| `.\build both` | Both outputs above |
| `.\build ci` | Checks and one signed AAB on pushed `main`; Actions artifact only |
| `.\build --help` | Help; also `help`, `-h`, or no arguments |

Local builds use current files, including uncommitted edits, and need no completed notes. On Linux/macOS use `bash ./gradlew buildLocalApk`, `buildLocalAab`, or `buildLocalBoth`. A local APK signed with the upload key cannot be assumed to update a Play-signed installation.

Windows `.cmd` files call PowerShell 5.1 from their own repository directory, including paths containing spaces. They reject invalid arguments before dispatch and preserve Gradle/CLI exit codes. Dispatch validates `origin`, discovers GitHub's default branch, checks the audited repository/`main`, and calls `gh workflow run android-play.yml --repo AnonymousCybersecurity/AnonymousMessenger --ref main`. A changed identity/default branch requires guard review. Run `gh auth login` first. Dispatch uses pushed source; it never sends local edits or requires local Ruby.

## Prepare a version and separate notes

Order: **bump → write/review both notes → commit/push → explicitly dispatch**.

```powershell
.\release bump
.\release bump --version-name 26.10.10-0 --version-code 26101000
# Native equivalents:
.\gradlew.bat versionBump
.\gradlew.bat versionBump -PversionName=26.10.10-0 -PversionCode=26101000
```

Messenger uses `versionName = canonicalVersionName + '-' + anonymousRevision` and `versionCode = canonicalVersionCode * 100 + anonymousRevision + currentHotfixVersion`. Default bump advances revision beyond revision plus hotfix and resets hotfix to zero. The currently edited `26.10.09-6` / `26100906` would become `26.10.09-7` / `26100907`; this task does not perform that bump.

Explicit names use a valid `YY.MM.DD-REV`, revision 0–99. Name and code must increase and satisfy the formula. A changed canonical date defaults its canonical code to `YYMMDD`; an explicit code can select the base while retaining the formula. Code-only bumps stay within the current canonical hundred. Exhaustion requires an explicit next canonical version. Comments/aliases and prepared notes are preserved. The legacy Docker `-PCI=true` exact-tag naming behavior is unchanged; new builds use source versions and require no tag just to compile.

The bump creates UTF-8 templates only if absent:

| Destination | Exact file | Content |
| --- | --- | --- |
| GitHub | `release-notes/<versionName>.md` | Detailed reviewed Markdown |
| Play | `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt` | Reviewed plain text, maximum 500 Unicode code points |

Replace `RELEASE_NOTES_TODO`. Missing, blank, comment-only, or unfinished notes (`TODO`, `TBD`, `PLACEHOLDER`) fail validation. Additional locales use `fastlane/metadata/android/<locale>/changelogs/<exactCode>.txt`; every supplied exact-code locale has the same limit. Emoji count as Unicode code points, not UTF-16 units. Play notes reject Markdown/HTML formatting. Historical files and `default.txt` never substitute. Optional Ruby validation: `ruby scripts/release.rb notes github`, `notes play`, or `notes both`.

The developer or coding agent writes notes during preparation; publishing reads committed files. GitHub requires GitHub notes, Play requires exact-code English notes plus supplied translations, Both requires both destinations, all **before tagging or publishing**. Build-only can succeed without notes, but later reuse requires completed Play notes in that build's original commit. Today's notes cannot repair an old build's original source.

## Release commands and Actions inputs

Use **Actions → Android Google Play → Run workflow**, on `main`, or:

| Command | Inputs/result |
| --- | --- |
| `.\release github` | `action=release`, `destination=github`: page/tag only, no Android build |
| `.\release play` | `action=release`, `destination=play`, `play_track=internal` |
| `.\release both` | `action=release`, `destination=both`, internal; page first, upload, verified APK |
| `.\release play --play-track production` | Play-only direct production; same checks |
| `.\release both --play-track production` | Page first, production upload, verified APK |
| `.\release promote` | `action=promote`; highest internal code to production, no rebuild |
| `.\release promote <versionCode>` | `action=promote`, exact `version_code` |
| `.\release verify` | `action=verify`; configuration/private key/OIDC/Play read checks only |
| `.\release internal <successful-run-id>` | `action=internal`, `build_run_id`; saved AAB to internal without rebuilding |
| `.\release --help` | Help; also `help`, `-h`, or no arguments |

Actions defaults to **build**, saving an AAB without publication. New uploads default to **internal**. Production must be selected explicitly and remains subject to Google review, eligibility, policies and managed publishing. Review errors are not silently retried with deferred review. Track applies only to Play/Both; saved-build reuse always targets internal. Run ID applies only to reuse and versionCode only to promotion. There is no standalone APK attachment/recovery mode.

### Release order, tags and retry behavior

1. Run mocked release tooling checks, isolated native Kotlin tasks and real Java key fixtures.
2. Validate required committed notes and Messenger identity variables. Create/reuse `v<versionName>` pointing at the exact workflow commit. Annotated tags resolve too; a tag pointing elsewhere fails and is never moved.
3. GitHub/Both publishes the page with prepared Markdown followed by GitHub's generated changelog. Retries preserve nonempty existing descriptions, including drafts; empty bodies are filled. GitHub-only stops here.
4. Play/Both verifies the private upload key/pin, runs Messenger's app/media-send unit tests and release lint, builds one `prodStoreRelease` AAB and checks native alignment. Verify the actual AAB manifest and every payload entry's signature, then save it with provenance.
5. Authenticate through short-lived OIDC after compilation and upload the AAB with only exact-code notes to the selected track.
6. Both polls Play's generated-APK API for up to ten minutes, selecting `generatedUniversalApk` under the expected app signing certificate. It downloads Google's APK without a second Android build.
7. Verify actual APK signature with `apksigner`, and package/name/code with `aapt2`; reject unexpected signers, split/debug APKs. Attach `AnonymousMessenger-Play-<versionName>.apk`. Existing assets are reused only when name/state/size/SHA-256 match; conflicts fail without overwriting/deletion.

GitHub failure stops Both before building/uploading. Later failure can leave the page/tag published. Retry the same tagged source only before Play accepted the code. If upload succeeded but attachment failed, inspect Play state before retrying; do not upload the code again. New uploads need unused codes. The lane rejects codes at/below internal/production; Play also enforces uniqueness across other tracks, drafts and previously uploaded codes.

Promotion reads current Play tracks, selects highest/exact internal code, rejects absent/superseded versions, and promotes the original TrackRelease with its stored notes unchanged. It reads no local notes, builds/uploads no bundle, creates no tag/page. Verification reads tracks using temporary Play edits that are aborted without committing; read access does not prove publishing permission.

### Saved builds, outputs and retention

Successful builds save **`anonymous-messenger-<full source SHA>` for 14 days** in the run's Artifacts section. It contains `app-prod-store-release.aab` and `release-build.json`: schema, package/name/code, source SHA, repository/workflow/branch, run ID/attempt, variant, upload pin and AAB SHA-256. Reports remain under each module's `build/reports/` during the job, without separate retention or Release attachment. Local outputs persist until cleaned; existing `app/prodStore/release` is not a new build output path.

Reuse requires a completed successful manual run from this repository/head repository, this workflow and `main`, a full source SHA, and exactly one unexpired expected artifact with a GitHub SHA-256 digest. Load version inputs and every supplied exact-code locale from the original commit, validate original notes, download with strict archive digest verification, compare provenance, and verify the actual AAB signature/package/version. Tag the original build SHA, then upload with original notes. No rebuild or private signing secret is needed. Reuse needs the public upload pin and Google authentication. A rotated upload pin intentionally rejects older artifacts pending review.

Official bundletool 1.18.3 is downloaded from `google/bundletool`, pinned to SHA-256 `a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29`. It and restored signing files use `RUNNER_TEMP`. Keystores are removed by always-run cleanup; the auth action cleans OIDC files and hosted runners are discarded. Ruby dependencies are locked in `Gemfile.lock`. `ruby/setup-ruby` provides Ruby; Bundler restores dependencies on cache hit and installs on cache miss. Gradle has a separate cache.

### Website/FOSS distribution

Use **Actions → Website Android checks and manual release → Run workflow** on `main`. It validates GitHub notes/tag/page, checks/builds the website variant, checks alignment, verifies the private website key against the existing published certificate, signs with the original four website secrets, verifies the APK and attaches the original filename plus `index-v1.json`. The index preserves package, suggested code, filename and APK SHA-256 for `ApkUpdateJob`. Matching existing assets are reused; conflicts fail.

GitHub-only or Play/Both pages without a website index are not website updates. New pages explicitly use `make_latest=false`, preserving `/releases/latest/download` for installed website clients. Only after the website workflow verifies and attaches both updater assets does it mark that release latest. Publish website assets for that version when updating website installations. Both distribution signatures and assets remain independent; Play APKs never replace the website updater assets. The old push-triggered publication is removed, while useful ordinary CI checks/builds remain.

## Account setup, one step at a time

During guided setup the user created `publish-messenger@graphene-play-publishing.iam.gserviceaccount.com` after an account listing showed only Photos and Explorer. User-supplied Cloud Shell output confirms its repository-only federation binding, the expanded provider condition below with ACTIVE state and unchanged issuer/mappings, and all four required APIs enabled. The user also supplied both public signing fingerprints from Console. GitHub settings, private-key preflight and live CI OIDC/Play access still need verification; Play permissions have not been independently tested through the API. Account mutations were performed by the user, not by the agent.

### 1. Inspect before creating accounts

In Cloud Shell:

```sh
gcloud iam service-accounts list --project=graphene-play-publishing --format='table(email,disabled)'
gcloud iam workload-identity-pools providers describe github --project=graphene-play-publishing --location=global --workload-identity-pool=github-actions --format=json
```

Reuse a suitable Messenger-only account; avoid duplicates. Code expects `publish-messenger@graphene-play-publishing.iam.gserviceaccount.com`. Adapt/review the guard if a suitable differently named account exists. Never reuse Photos/Explorer identities or certificates. Check project number `117253714562`, ACTIVE/enabled provider, issuer `https://token.actions.githubusercontent.com`, mappings `google.subject=assertion.sub`, `attribute.repository_id=assertion.repository_id`, `attribute.repository_owner_id=assertion.repository_owner_id`.

### 2. Review the narrow provider addition

Preserve the original clause and admit only Messenger's exact repository/owner pair:

```text
assertion.repository_owner_id == '264203613' || (assertion.repository_owner_id == '272907184' && assertion.repository_id == '1198767196')
```

After reviewing the current condition, an authorized administrator can update only that condition:

```sh
gcloud iam workload-identity-pools providers update-oidc github --project=graphene-play-publishing --location=global --workload-identity-pool=github-actions --attribute-condition="assertion.repository_owner_id == '264203613' || (assertion.repository_owner_id == '272907184' && assertion.repository_id == '1198767196')"
```

Do not recreate the provider, replace mappings or change Photos/Explorer account policies. If current output differs, review it before applying this example. Photos' old local auditor may expect the original exact condition even though its runtime access is preserved; Photos files remain unchanged.

### 3. Create/reuse Messenger's account and repository-only binding

Only if absent, an authorized administrator creates the account, then adds/inspects its binding:

```sh
gcloud iam service-accounts create publish-messenger --project=graphene-play-publishing --display-name='AnonymousMessenger Play publishing'
gcloud iam service-accounts add-iam-policy-binding publish-messenger@graphene-play-publishing.iam.gserviceaccount.com --project=graphene-play-publishing --role=roles/iam.workloadIdentityUser --member='principalSet://iam.googleapis.com/projects/117253714562/locations/global/workloadIdentityPools/github-actions/attribute.repository_id/1198767196'
gcloud iam service-accounts get-iam-policy publish-messenger@graphene-play-publishing.iam.gserviceaccount.com --project=graphene-play-publishing --format=json
gcloud services list --enabled --project=graphene-play-publishing --format='value(config.name)'
```

The federation binding must contain only Messenger's numeric repository ID. No broad Cloud project role is needed merely for Play publication. Required APIs: `androidpublisher.googleapis.com`, `iam.googleapis.com`, `iamcredentials.googleapis.com`, `sts.googleapis.com`; an authorized administrator enables missing APIs after inspection. With authenticated gcloud and Ruby, `ruby scripts/verify-google-identity.rb` performs only describe/list/get-policy checks. `--configured` validates workflow variables only, not live IAM.

### 4. App-specific Play access and certificates

In **Play Console → Users and permissions**, invite the Messenger service account. Under **App permissions**, select **AnonymousMessenger (`it.aitechnology.anonymous`) only**. Grant View app information, release to testing tracks, and release to production for production/promotion. Do not grant all-app account-admin access. Tester management is only needed to change tester configuration; these commands do not do that. Reuse the app with its initial upload; do not create a different app/package.

In the app's **App integrity → App signing**, obtain **Upload key certificate SHA-256** and **App signing key certificate SHA-256** separately. Match the existing private upload keystore's public certificate to Console; do not generate/reset a key. The saved AAB's fingerprint above helps identify it but is not proof of registration/private-key access. Share only public certificates/fingerprints, never keystores/passwords. For rotated Play keys, deliberately select the certificate used for the universal APK.

### 5. Enter repository settings together

Open **GitHub → AnonymousCybersecurity/AnonymousMessenger → Settings → Secrets and variables → Actions**.

Under **Variables → New repository variable**, enter these **four** public values:

| Exact name | Value |
| --- | --- |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/117253714562/locations/global/workloadIdentityPools/github-actions/providers/github` |
| `GCP_SERVICE_ACCOUNT` | `publish-messenger@graphene-play-publishing.iam.gserviceaccount.com` |
| `PLAY_UPLOAD_CERT_SHA256` | `95:94:6B:99:6D:4D:1E:6E:9D:A0:7F:C2:FA:B8:96:6A:37:6A:15:29:8A:93:62:7C:5F:B7:1A:A1:B3:62:9D:A2` |
| `PLAY_APP_SIGNING_SHA256` | `BB:61:44:69:31:3A:37:27:4B:F2:00:54:20:65:FD:4C:22:B1:56:4C:1C:9C:9B:2F:7E:88:D1:98:FA:DD:54:9D` |

Fingerprints accept hex with or without colons. The user confirmed that the website and Play keystores use the same store password, so both workflows reuse the existing `KEYSTORE_PASSWORD` repository secret. Under **Secrets → New repository secret**, enter these **three** Play-specific values:

| Exact name | Value entered privately |
| --- | --- |
| `PLAY_UPLOAD_KEYSTORE_BASE64` | Base64 of Messenger's existing registered upload keystore |
| `PLAY_UPLOAD_KEY_ALIAS` | Existing private-key alias |
| `PLAY_UPLOAD_KEY_PASSWORD` | Key password, possibly the same as store password |

Keep the original website secrets. `PLAY_UPLOAD_KEYSTORE_PASSWORD` is no longer needed as a GitHub secret; the workflow supplies the shared `KEYSTORE_PASSWORD` value to the signing helper's internal password environment variable. An already-created duplicate secret is not deleted automatically. The website and Play certificate pins remain distinct, so retain separate keystore/alias selection until those entries are independently verified. Do not copy website key/alias values into Play slots merely because passwords match. No Photos/Explorer secret, `APPLICATION_PROPERTIES`, service-account JSON key or new PAT is needed.

### 6. Verify before publishing

After separately authorized review/commit/push, explicitly start `.\release verify`. It verifies real secret contents/private key/certificate and live OIDC/Play read access without compiling or publishing. Only a later chosen publishing command exercises write permissions. Prepare a fresh unused version and completed notes first.

## Focused verification and limits

```sh
bundle exec ruby tests/release/run.rb
bundle exec ruby tests/release/check_upload_key.rb
bundle exec ruby tests/release/check_gradle_tasks.rb
bundle exec ruby tests/release/check_android_artifacts.rb
```

Windows additionally: `powershell.exe -NoProfile -File tests/release/check_windows_launcher.ps1`. The Ruby unit suite blocks real HTTP/publishing subprocesses and evaluates the actual Fastfile with closed mocks. Native fixtures execute actual Kotlin bump/routing, Windows launchers through CLI shims, private-key verification, APK checks and signed-bundle tamper rejection using disposable keys/files. Artifact integration fixtures need SDK/JDK.

Production uses Messenger app debug unit tests, media-send unit tests, release lint with Messenger's existing baseline, one signed AAB and final 16 KB checks. Website CI uses the corresponding website checks. No Photos test exclusions or lint baseline are copied. Existing Argon2/native-utils connected device tests remain separate; hosted unit tests do not prove device behavior.

Local/mock checks, task configuration, CI success, real Play upload, review and installation are separate outcomes. Account setup and authorized pushed CI verification remain necessary. Mocks do not prove a real upload.

Local implementation validation on 2026-10-23 passed: 44 mocked tests / 333 assertions; 49 Windows launcher checks; actual native Gradle bump/template/routing fixtures; disposable Java private-key and Android artifact signature/tampering fixtures; workflow actionlint and Ruby/YAML syntax; real app/media-send test/lint task graph configuration; seven existing media-picker tests (3 `MediaSendPickerTest`, 4 `SystemMediaPickerTest`). Read-only checks also verified the saved AAB and existing published website APK identities/signatures, and the saved AAB's SHA-256 stayed unchanged. The full app unit suite, release lint execution, a new signed production build, device tests and remote CI/Play publication have not been run. Nothing was committed, pushed, dispatched or published; Photos and unrelated local work were preserved.

References: [Google WIF deployment pipelines](https://docs.cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines), [Play generated APK API](https://developers.google.com/android-publisher/api-ref/rest/v3/generatedapks/list), [Fastlane Play upload/promotion](https://docs.fastlane.tools/actions/upload_to_play_store/).
