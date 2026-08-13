# Roadmap

Planned and in-progress work for **AI Meeting Notes** - the macOS app
(`packages/meeting-engine`) and the Windows app (`packages/meeting-notes-windows`).
Items are grouped by theme and roughly ordered by priority within each group.
Nothing here is started unless marked otherwise.

See [CHANGELOG.md](CHANGELOG.md) for what's already shipped.

---

## Known bugs

- **Windows: transcription/summary silently produce an empty note.** Reported on the
  Windows app: a recording where the mic track is silent (system audio fine) finishes
  with a note but an empty transcript and summary. Two root causes in the C# port:
  1. **`WhisperTranscriber.RunAsync` drains stderr but never stdout**
     (`packages/meeting-notes-windows/.../WhisperTranscriber.cs`). With
     `RedirectStandardOutput = true` and nobody reading it, whisper-cli's stdout fills
     the OS pipe buffer on a real meeting and the process **deadlocks** on write, so
     `WaitForExitAsync` hangs; near-silent/short tracks slip under the buffer and
     "succeed" with no output. Fix: read stdout and stderr concurrently (or pass
     `--no-prints`).
  2. **`if (!File.Exists(jsonPath)) return []`** swallows a missing JSON as "no
     speech", so a whisper failure (or output written elsewhere) yields an empty note
     with no error or log. Fix: surface a real error/log when whisper exits clean but
     produced no JSON.
  Also port the two macOS transcription fixes shipped in 0.29.0 to the Windows
  `Transcriber.cs` (same gaps exist there): honor the per-language model override
  under `auto`, and the cross-track echo dedup for in-person/speakerphone meetings.

## Windows app (active)

A native Windows port in a new package `packages/meeting-notes-windows/`, leaving
the macOS app untouched. Full step-by-step plan: **[WINDOWS-PLAN.md](WINDOWS-PLAN.md)**.

- **Stack:** .NET 8 + C#, NAudio for capture, WPF UI (chosen over WinUI 3 so it
  builds on CI without the Windows App SDK workload).
- **Zero-setup system audio** via WASAPI loopback (`WasapiLoopbackCapture`) + mic
  via `WasapiCapture`, as two separate tracks - the Windows equivalent of the
  macOS Core Audio process taps, no virtual device required.
- **Reused logic (re-implemented in C#):** whisper.cpp transcription + You/Them
  two-track merge, Ollama/Claude summarization with map-reduce, Markdown note
  storage in the Obsidian vault. These are pure logic/HTTP/filesystem.
- **v1 = MVP:** record → transcribe → summarize → note (Phases 0-6 shipped:
  engine + WPF UI + in-app model download + self-contained packaging/installer).
  Diarization, auto meeting-detection, tray UI, and ETA are deferred (plan Phase 7).
- **Distribution:** the **Windows release** workflow (`win-v*` tag → publish → zip
  + Inno Setup installer → GitHub Release) is wired and green; the first build
  shipped as **win-v0.1.0** (unsigned beta, whisper-cli bundled), and the landing
  page has a Windows download. **Remaining: a real-hardware smoke-test** - the live
  WASAPI capture and WPF UI are CI-compiled but haven't run on Windows yet - then
  Authenticode signing (below).
- **Installer: verify the clean-upgrade path on real hardware.** The installer now
  carries a fixed `AppId`, `UsePreviousAppDir/Tasks`, and a `PrepareToInstall`
  `[Code]` step that silently uninstalls a prior version before copying new files
  (`scripts/installer.iss`) - but it's only been reviewed, not run (ISCC is
  Windows-only, and this repo builds on macOS/CI). Remaining: on a real Windows box,
  install an older build → install the next version → confirm settings, model path
  and the vault all survive (they live in `%APPDATA%\MeetingNotes\` and the chosen
  vault, outside `{app}`), and that no orphaned files remain in
  `Program Files\AI Meeting Notes`. Also confirm the `unins000.exe` self-copy poll
  actually waits long enough on a slow machine. Possible follow-up: a "remove my
  settings and models too" checkbox on uninstall as an opt-in escape hatch.

- **Authenticode signing + SmartScreen (the notarization analogue).**
  The release workflow already signs the published `.exe`s and the installer when
  six repo secrets are set (`AZURE_TENANT_ID`, `AZURE_CLIENT_ID`,
  `AZURE_CLIENT_SECRET`, `TRUSTED_SIGNING_ENDPOINT`, `TRUSTED_SIGNING_ACCOUNT`,
  `TRUSTED_SIGNING_PROFILE`); until then the build is unsigned and Windows
  SmartScreen warns on first run (the macOS Gatekeeper-warning equivalent). To
  enable, set up **Azure Trusted Signing** (~$10/mo, no hardware token, the modern
  path):
  1. In the Azure Portal, create a **Trusted Signing account** (the service is
     region-limited - pick a supported region) and a **certificate profile** of
     type **Public Trust**. Note the account's **endpoint URI**, account name, and
     profile name.
  2. Complete Microsoft's **identity validation** (individual or organization).
     This is the gating wait - like the Apple Developer enrollment - and can take
     a few business days; a new individual cert also carries no SmartScreen
     reputation until downloads accrue, so early users may still see a warning
     that fades over time.
  3. Create an **Azure AD app registration** (service principal) with a client
     secret, and grant it the **Trusted Signing Certificate Profile Signer** role
     on the signing account.
  4. Add the six values above as GitHub **repository secrets**. The next
     `win-v*` release then signs automatically via `azure/trusted-signing-action`
     - no code change needed.
  Alternative if Trusted Signing isn't available in your region: a classic **OV/EV
  code-signing certificate** (~$200-400/yr; EV gives instant SmartScreen
  reputation but needs a hardware token / cloud HSM) signed with `signtool` -
  would require swapping the signing steps in the workflow.

## UX polish

- **macOS: add a start handle to the Trim window (match Windows).** The Windows app
  now has a visual trim with both a start and an end handle
  (`WaveformTrimControl` + `TrimWindow`), but the macOS `TrimAudioWindow` still cuts
  the tail only (`cutTime`, "keeps the first …"). Follow-up: add a start marker to
  `TrimWaveformView`/`TrimAudioWindow` and pass a start offset through
  `RecordingController.trimAudio` so the head can be cut too.

- **Don't show the Compress button while a meeting is still processing.**
  Compression is the last pipeline step (transcribe → summarize → compress), so on a
  long meeting the note appears with its raw WAVs on disk for several minutes before
  they're compressed away. The Compress button is visible (though disabled) during
  that window, which looks like auto-compression didn't happen. Fix: hide the button
  while the meeting is busy/processing (only show it once idle *and* uncompressed WAVs
  remain - i.e. a genuinely interrupted/failed recording), and/or show a brief
  "Compressing…" status. Purely cosmetic; compression itself works correctly.

## Summary quality

- **Meeting category (1:1, daily sync, planning, …).**
  Add a `category:` frontmatter field (NOT `type:` - that's already
  `type: meeting`). Levels, in order of value:
  1. **Label only** - a dropdown (presets + custom) for organizing / searching /
     Dataview queries.
  2. **Per-category summary prompts** - the real win: tailor the summary to the
     type (1:1 → action items + growth notes; standup → updates + blockers;
     planning → decisions + owners; interview → candidate signals). Reuses the
     existing per-model prompt machinery.
  3. **Auto-detect** - infer the category from the calendar event title (once
     calendar integration lands) or via an LLM classification. Defer.

## Capture & product (the "Notion-grade" roadmap)

- **Product shape decided: the desktop app is the product; output is a folder of
  Markdown.** Obsidian is an *optional viewer* of that folder, not a dependency -
  see [NOTE-FORMAT.md](NOTE-FORMAT.md) (the output contract). The standalone
  Obsidian *plugin* (`packages/ai-meeting-notes`) is **deprecated** now that the
  apps capture with zero setup; it stays for the record but isn't developed.
- **Optional: read-only Obsidian companion (deferred).**
  If Obsidian-native querying is ever wanted, repurpose the plugin as a *read-only*
  client over the apps' output (no recording): dashboards, search, "re-summarize"
  via a small localhost API exposed by the app. Only worth it if in-app library +
  plain Markdown prove insufficient.
- **Real multi-speaker diarization** (phase 1 shipped in 0.23.0 as the
  experimental "Recognize speakers" toggle - see Completed). Remaining phases:
  - **Phase 2:** UI to **rename speakers** per meeting (and persist the mapping).
  - **Phase 3:** Auto-name from **calendar attendees** / LLM inference, once those land.

  Other follow-ups now that the pipeline exists: ~~let the user pin the speaker
  count~~ (done in 0.25.0 - per-meeting count, since auto-estimate proved
  unreliable on real audio), expose the clustering threshold, try a better
  embedding model (wespeaker over-split least in testing), and fold the mic
  "You" track into the embedding space so a remote echo of the user isn't
  counted as a separate "Them".
- **Live transcription during the meeting + chat with the running notes.**
  Today the pipeline is strictly post-hoc: stop → transcribe → summarize → note.
  The next capture-level step is showing the transcript *as the meeting happens*,
  and letting the user ask questions against it mid-meeting ("what did they commit
  to?", "summarize the last 10 minutes", "did we decide on the deadline?").
  Two halves, and the first gates the second:
  - **Streaming ASR.** whisper.cpp large-v3 can't do this - it's a batch,
    30-second-window model and takes minutes on a long file. The candidate is
    **[Moonshine v2](https://github.com/moonshine-ai/moonshine-v2)** (streaming
    ASR for edge devices): flexible input windows instead of Whisper's fixed
    30s zero-padded one, plus a streaming cache that reuses prior compute as
    audio arrives - ~73-107ms latency CPU-only on a MacBook, against seconds
    for Whisper. Runs on both tracks (mic + system loopback), so the You/Them
    split we already have carries over.
    Two caveats to settle before committing:
    1. **Licensing.** English models are MIT; **all non-English models
       (Ukrainian included) are under the non-commercial Moonshine Community
       License** - a blocker for a paid/commercial build, needs a direct
       agreement with Moonshine AI. Alternatives to evaluate if that fails:
       `whisper-streaming`/WhisperLive over a small whisper model, or
       Apple's on-device `SpeechAnalyzer` (macOS 26+).
    2. **Quality.** Moonshine tops out at ~200M params vs large-v3's 1.5B, and
       its models are per-language - so uk/en code-switching, common on our
       meetings, likely degrades. Also unclear how it handles a 40-minute
       session (docs recommend staying under ~30s of input per call, i.e. we'd
       own the VAD chunking).
    **Therefore: live ASR is a draft, not a replacement.** Keep whisper large-v3
    as the authoritative pass after the meeting ends; the streaming transcript is
    a real-time view that gets overwritten by the final one. Benchmark both on
    the real Ukrainian recordings in `input/` before any of this is committed to.
  - **In-meeting chat.** A side panel over the live transcript buffer - the same
    Ollama/Claude engines and prompt machinery the summary already uses, but with
    the running transcript as context instead of a finished one. Short meetings
    fit a context window whole; longer ones reuse the map-reduce chunking. This is
    the real-time sibling of **Chat over meetings (RAG)** under Postponed (which
    queries the finished archive) - shared retrieval/prompt layer, so worth
    designing the two together.
  Gate behind `experimentalMode` like diarization, and expect it to land Windows-side
  too (WASAPI loopback already gives the same two-track feed).
- ✅ **Native macOS notification on meeting detection.** Shipped in 0.28.0. A
  system notification ("Meeting detected", with a **Record** action) fires when
  another app starts using the mic while AI Meeting Notes is backgrounded/hidden
  (`UNUserNotificationCenter`); the in-app nudge still covers the foreground.
  Respects the "Suggest recording…" toggle, asks permission on first use, once per
  meeting.

## Completed

See [CHANGELOG.md](CHANGELOG.md) for the full shipped history. Highlights:

- ✅ **Windows: visual trim with start & end handles.** Shipped in Windows 0.5.0.
  Trimming opens a window with a loudness waveform and a draggable green start /
  red end handle, a preview transport, and "set to playhead" shortcuts - cutting
  both the head and the tail, replacing the old "keep first N seconds" text prompt.
  New `Waveform` (Audio), `WaveformTrimControl` + `TrimWindow` (App), and a
  start+end `AudioTrimmer.TrimWav` overload (Core, unit-tested). macOS follow-up
  (a start handle there too) is under UX polish.
- ✅ **Windows: installer cleans the previous version, keeps config.** Shipped in
  Windows 0.4.3. A fixed `AppId` + `UsePreviousAppDir/Tasks` + a `PrepareToInstall`
  `[Code]` step silently uninstall a prior install before copying new files, so no
  orphaned files linger; user settings/models/vault live outside `{app}` and
  survive. Real-hardware verification still pending (under Windows app).
- ✅ **Windows: settings-saved confirmation + reusable Stop button.** Shipped in
  Windows 0.4.1/0.4.2. Saving Settings now shows a green auto-fading "Saved" bar,
  and the "Stop processing" button re-arms on every run (it used to grey out after
  the first cancel).
- ✅ **macOS: Trim window closes on confirm.** Shipped in macOS 0.38.2. Confirming
  "Trim & Re-generate" now dismisses the (value-based) window and hands off to the
  meeting's processing bar, instead of leaving it open with only Cancel live.
- ✅ **Developer ID signing + notarization + DMG.** Shipped (first signed release
  0.26.0). `scripts/make-dmg.sh --release` builds, signs with Developer ID,
  notarizes, staples, and publishes a GitHub release with the DMG - gated on
  `DEVELOPER_ID_APP` / `NOTARY_PROFILE`. Apple Developer Program enrollment is
  done; the public download opens with no Gatekeeper warning. Mac App Store stays
  ruled out - the sandbox forbids process-tap system-audio capture and shelling
  out to `whisper-cli`.
- ✅ **Check for a new version.** Shipped in 0.27.0. On launch (throttled to once
  a day) the app queries the GitHub Releases API for the latest macOS `v*` release,
  and shows a dismissible "Version X is available - Download" bar plus a manual
  **Check for updates** button in Settings → About. Privacy-safe: one outbound
  request, no telemetry, no auto-install (Download opens the release page).
  Possible follow-up: one-click download + auto-relaunch (e.g. Sparkle).
- ✅ **Map-reduce summarization for long meetings.** Shipped in 0.22.0.
  Transcripts over ~40k chars are split into ~24k-char chunks (fits even modest
  context windows), each summarized into partial notes (map), then combined into
  the final summary (reduce). Even coverage regardless of length, and smaller
  models can handle long meetings. The model is kept loaded between chunks
  (`keep_alive` during map) and unloaded after the final pass. Possible
  follow-up: recursive reduce if the combined partials themselves get large.
- ✅ **Per-stage processing controls.** Shipped in 0.24.0. Settings →
  "Processing steps" toggles for Transcribe and Summarize, each disabled with an
  inline note when its dependency is missing (no whisper model → no
  transcription; no local model / Claude key → no summary). Replaced the summary
  engine "None" option (migrated to the toggle).
- ✅ **Experimental mode + per-meeting speaker count.** Shipped in 0.25.0. A
  master "Experimental features" switch gates R&D features (off by default).
  Speaker recognition now lets you set the exact number of remote speakers per
  meeting (stored in `speakers:` frontmatter), since auto-detect proved
  unreliable on real audio.
- ✅ **Multi-speaker diarization - phase 1 (experimental).** Shipped in 0.23.0
  as the "Recognize speakers" toggle. Runs sherpa-onnx (segmentation + speaker
  embeddings + clustering, native/offline) on the **system track** and relabels
  whisper's segments by time overlap into `Them 1 / Them 2 / …`; the mic track
  stays "You". Off by default; the toggle is disabled until the binary + ONNX
  models are installed (`scripts/setup-diarization.sh`), bundled into the app
  when present. Threshold-based clustering auto-estimates the speaker count.
  Remaining phases (rename UI, calendar/LLM auto-naming) are under Capture &
  product.
- ✅ **Tighter Obsidian note integration.** Shipped in 0.17.0. Notes now
  embed both audio tracks (`![[… .mic.wav]]` / `… .system.wav`) in an Audio
  section so Obsidian shows inline players, and carry `tags: [meeting]` for
  querying (alongside the existing `type: meeting`). The app hides the Audio
  section (it accesses recordings directly). Possible follow-up: auto-fill a
  `participants` field once real speaker identification exists.
- ✅ **Estimate transcription time (ETA).** Shipped. An up-front estimate from
  audio length × a **learned per-model end-to-end rate** (self-calibrating EMA,
  seeded by model size), shown counting down in the record panel and the meeting
  processing bar - covers transcription *and* the opaque summary phase. Replaced
  the 0.18.0 progress-extrapolation ETA, which couldn't see the summary phase.
  Rates persist in UserDefaults (`procRate.<model>`).

(Fixed: "processing bar showed on the wrong meeting" - 0.21.1 scopes the busy UI
to `controller.activeID == meeting.id`.)

(Fixed: "model stays in memory after processing" - 0.21.3 sends `keep_alive: 0`
so Ollama unloads the summary model right after summarizing; whisper-cli already
exits after each transcription.)

## Postponed

- **Keychain for the Claude API key.**
  Currently stored in UserDefaults as plaintext; move it to the Keychain.
- **Add more meeting languages.**
  Keep **Auto-detect** as an option (decided - it stays). Expand the explicit
  language list in `meetingLanguages` beyond English/Ukrainian in a future
  release, so users can pin other languages for best transcription quality.
- **Chat over meetings (RAG).**
  Ask questions across the meeting archive.

(The **Windows app** moved from Postponed to active - see the "Windows app"
section above and [WINDOWS-PLAN.md](WINDOWS-PLAN.md). Decided on a Windows-native
.NET/C# app rather than a cross-platform Tauri rewrite, to avoid re-doing the
mature macOS app and to use NAudio's strong WASAPI loopback support.)
