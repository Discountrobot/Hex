# Meeting Dictation & Diarized Notes — Plan (Draft v1)

> Status: **scoping draft**. Written to be argued with. Open decisions are tracked
> in [§9](#9-open-decisions-scope-these-first) — resolve those before we cut tasks.

## 1. Goal

A new **Meeting** mode in Hex that records a multi-person conversation, figures out
**who spoke when** (diarization), and produces clean **meeting notes** by handing the
diarized transcript to **Claude headless (`claude -p`)** for summarization and speaker
attribution. The app keeps a **memory of known speakers** so that the next time the same
voice appears it is recognized automatically ("that's Lasse again").

The three user requirements, restated:

1. **Diarization** — in the generated notes we can tell Person A from Person B and see
   who said what.
2. **Summarization** — use our already-powerful LLM via `claude -p` (prompt injection over
   stdin) to summarize the transcript and assign/refine speaker names after the fact.
3. **Speaker memory** — persist a per-speaker voice profile so a returning speaker is
   re-identified across meetings, with a short rolling summary of who they are.
4. **Live capture view** — while a meeting records, show the transcript streaming into a
   **notepad-style window** so it's visibly clear recording is happening, and you can glance at
   what's being captured. Primary purpose is a *recording indicator with content*, not a
   precise live record (the canonical transcript is produced in batch after stop).

This is explicitly a **new mode**, not a change to quick tap-to-talk dictation. Quick
dictation stays exactly as it is.

> Note on "live": **live transcript text** (req #4) is in scope for v1. **Live speaker labels**
> (diarization shown in real time) is *not* a hard requirement — it's a "killer feature" we
> defer; v1 diarizes in batch after stop. See §9.3.

## 2. The key finding (this is mostly already in the box)

Hex already depends on **FluidAudio** for Parakeet ASR and Kokoro TTS, and the **app target
already links the `FluidAudio` product** (`Hex/Clients/ParakeetClient.swift:5` →
`import FluidAudio`). That product ships a **complete on-device speaker-diarization +
speaker-memory stack** in the currently pinned revision (`47552dde…`, tracking `main`).
**No dependency bump, no new SPM package, no FluidAudio re-pin is required** — which also
means we do *not* trigger the ASR/TTS pin-coupling migration noted in project memory.

What FluidAudio gives us, ready to import:

| Need | FluidAudio API | Notes |
|------|----------------|-------|
| Who spoke when | `DiarizerManager.performCompleteDiarization(samples, sampleRate:)` → `DiarizationResult` | Batch over the whole recording. `samples` = 16 kHz mono `[Float]` (exactly what we already record). |
| Per-utterance speaker + timing | `TimedSpeakerSegment { speakerId, embedding: [Float], startTimeSeconds, endTimeSeconds, qualityScore }` | One per detected speech span. `embedding` is the 256-D voiceprint. |
| Cross-meeting recognition | `SpeakerManager.initializeKnownSpeakers([Speaker])`, `findSpeaker(with: embedding)`, `assignSpeaker(...)`, `makeSpeakerPermanent(_:)` | Seed the diarizer with everyone we already know before a meeting starts. |
| Persistable voice profile | `Speaker: Codable` `{ id, name, currentEmbedding: [Float], duration, createdAt, updatedAt, isPermanent, … }` | Serializes straight to JSON. Embedding updated via EMA as more audio arrives, so profiles *improve* with use. |
| Diarizer models | `DiarizerModels.downloadIfNeeded()` / `.download()` → `pyannote_segmentation.mlmodelc` + `wespeaker_v2.mlmodelc` | Two small CoreML models, cached under the same container `FluidAudio/Models` dir as Parakeet (we already set `XDG_CACHE_HOME`). |
| Live transcript (req #4) | `StreamingAsrManager` `{ streamAudio(_:AVAudioPCMBuffer), transcriptionUpdates: AsyncStream<StreamingTranscriptionUpdate>, finish() }` (Parakeet streaming) | Feed mic buffers in, consume partial-text updates out → drive the notepad. (`StreamingEouAsrManager` adds end-of-utterance + partial callbacks if we want them.) |

**Implication:** requirements #1 (diarization) and #3 (speaker memory) are largely a *wiring*
job on top of an existing, on-device library. The genuinely new engineering is (a) aligning
ASR text to diarization segments, (b) the outbound `claude -p` path for #2, and (c) the
UX/data model for meetings and the speaker directory.

## 3. What we build on (current architecture)

- **Recording** — `Hex/Clients/RecordingClient.swift`. Captures **16 kHz PCM mono float WAV**
  via `SuperFastCaptureController` (AVAudioEngine) with an `AVAudioRecorder` fallback. This is
  already the exact format the diarizer wants. Audio is retained on disk when
  `saveTranscriptionHistory` is on.
- **Transcription** — `Hex/Features/Transcription/TranscriptionFeature.swift` (TCA reducer:
  `startRecording` / `stopRecording` / `transcriptionResult` …) drives
  `Hex/Clients/TranscriptionClient.swift`, which routes Parakeet → `ParakeetClient`
  (`Hex/Clients/ParakeetClient.swift`) and everything else → WhisperKit.
  **Gap:** `transcribe(...)` currently returns a flat `String` — it joins segment `.text`
  and **throws away timestamps**. We need timestamps to align text with speakers.
- **History** — `Hex/Features/History/HistoryFeature.swift`. `Transcript { id, timestamp,
  text, audioPath, duration, sourceApp… }` persisted as JSON via `@Shared(.fileStorage)` in
  `~/Library/Application Support/com.kitlangton.Hex/transcription_history.json`. Meetings are
  a different shape, so they get their own store (see §6).
- **Settings** — `HexCore/.../Settings/HexSettings.swift` (`Codable` struct + `HexSettingsSchema`
  field registry, persisted as JSON via `@Shared(.hexSettings)`). New options are added by
  appending a property + a `SettingsField`. The Settings UI is a sectioned `Form`
  (`Hex/Features/Settings/SettingsView.swift`); a new section is one SwiftUI view bound to
  `StoreOf<SettingsFeature>`.
- **Agent plugin / Claude bridge** — `Hex/Clients/ClaudePluginClient.swift`,
  `Hex/Features/Agent/AgentFeature.swift`, `Hex/Views/AgentPanel.swift`. **Crucial:** this is
  an **inbound** bridge — Claude Code runs a hook that calls *into* sandboxed Hex via
  `hex://` deeplinks and a file rendezvous in the container. There is **no existing outbound
  `claude -p` call**, and a sandboxed app cannot spawn the `claude` binary directly (PATH,
  network, and `~/.claude` auth all live outside the sandbox). See §5 for how we get around this.
- **TTS** — `Hex/Clients/SpeechSynthesizerClient.swift` (Kokoro). Reusable later if we want to
  read summaries aloud; not in v1 scope.

## 4. Proposed pipeline (end to end)

```
[Meeting hotkey / menu] 
      │
      ▼
Record long-form 16 kHz mono WAV  ──────────────►  meeting.wav (kept on disk)
      │ (stop)
      ▼
┌─────────────────────────────┐     ┌──────────────────────────────────┐
│ ASR (Parakeet/Whisper)      │     │ Diarization (FluidAudio)         │
│ → timestamped text segments │     │ DiarizerManager.performComplete… │
│   [(t0,t1,"…"), …]          │     │ → [TimedSpeakerSegment]          │
└──────────────┬──────────────┘     └────────────────┬─────────────────┘
               │                                      │
               └───────────────┬──────────────────────┘
                               ▼
               Align by time overlap  →  speaker-attributed transcript
                  "S1: …", "S2: …"   (Speaker = matched known speaker or new "Speaker N")
                               │
        ┌──────────────────────┴───────────────────────┐
        ▼                                               ▼
 Update speaker memory                          Summarize via `claude -p`
 (EMA-update embeddings,                         (diarized transcript on stdin +
  upsert Speaker JSON,                            prompt asking for summary, action
  match returning voices)                         items, decisions, and best-guess
        │                                          speaker names)
        ▼                                               │
 Speaker directory (names,                              ▼
 rolling bio, voiceprints)  ◄───── reconcile ──── Meeting note (markdown + per-segment
                                   names back     speaker labels + summary)
                                   into directory
```

### 4.0 Two ASR passes: live + canonical
- **Live pass (during recording, req #4):** the capture engine forks each mic buffer — one copy
  to the meeting WAV (below), one to `StreamingAsrManager.streamAudio(_:)`. We consume
  `transcriptionUpdates` and append text to the notepad window. This pass is **for display**;
  partial results may be revised and it does not need to be the final record.
- **Canonical pass (after stop):** the full WAV is transcribed in batch for the highest-quality
  text *with timestamps* (needed for diarization alignment, §4.2). The canonical transcript +
  diarization is what gets stored, summarized, and fed to speaker memory.
- v1 keeps these separate (simplest, and they have different quality/latency needs). A later
  optimization could reuse the streaming result as the canonical text if quality proves equal.

### 4.1 Diarization (req #1)
- After `stopRecording`, decode `meeting.wav` to `[Float]` @ 16 kHz mono and call
  `performCompleteDiarization`. Output is `[TimedSpeakerSegment]` with stable `speakerId`s
  for the session.
- `DiarizerConfig` knobs we'll likely expose/tune: `clusteringThreshold` (0.7 default; lower =
  more speakers), `minSpeechDuration`, optional `numClusters` if the user tells us "2 people".

### 4.2 ASR ↔ diarization alignment (the real new work)
- Extend `TranscriptionClient.transcribe` (or add a sibling `transcribeSegments`) to return
  **timestamped segments** instead of a joined string. WhisperKit already exposes segment
  timings; Parakeet TDT exposes token timings via FluidAudio's `AsrManager` (needs
  confirmation of the exact result shape — research task in §8).
- Merge: for each ASR segment, assign the diarization speaker whose `[startTime,endTime]`
  overlaps it most. Produce an ordered list of `(speakerId, text, t0, t1)`.
- This alignment is the main correctness risk and deserves its own tests with a fixed fixture.

### 4.3 Speaker memory (req #3)
- A **Speaker Directory**: `[StoredSpeaker]` persisted as JSON in Application Support
  (`meeting_speakers.json`, via `@Shared(.fileStorage)`), where `StoredSpeaker` wraps
  FluidAudio's `Speaker` (Codable embedding) + our metadata (display name, optional rolling
  bio/summary, last-seen date, meeting count).
- **Before** each meeting: load the directory and call `initializeKnownSpeakers(...)` so the
  diarizer reuses existing identities; new voices become new `Speaker`s.
- **After** each meeting: persist updated embeddings (FluidAudio EMA-updates them as it sees
  more audio, so recognition gets better over time), bump last-seen/meeting-count, and store
  any name the user (or Claude) assigned.
- Matching is by embedding distance (`findSpeaker(with:)` / `clusteringThreshold`). We surface
  low-confidence matches to the user as "is this <name>?" rather than silently merging.

### 4.4 Summarization & name assignment (req #2)
- Build a prompt that injects the diarized transcript (labeled `Speaker 1/2/…` or known names)
  plus the known-speaker directory, and asks Claude for: a summary, decisions, action items,
  and a best-guess mapping of `Speaker N → real name` using in-meeting cues ("Thanks, Lasse").
- Run it through `claude -p` (prompt/transcript on **stdin**, headless). The transport for that
  call is the main open decision — see §5.
- Claude's suggested names are **proposals**: we reconcile them back into the speaker directory,
  but the user confirms before a name sticks to a voiceprint.

## 5. The summarization transport problem (most important design fork)

Hex is sandboxed. It **cannot** just run `Process("/usr/bin/env", ["claude", "-p"])`: the
`claude` binary, its network egress, and its `~/.claude` credentials all live outside the
sandbox. The existing agent plugin only works because Claude Code (already unsandboxed) reaches
*into* Hex. For summarization we need the reverse. Options:

- **Option A — Outbound helper via the existing rendezvous pattern (recommended).**
  Extend `ClaudePluginClient`'s install flow with a small **unsandboxed runner** (a LaunchAgent
  or the same one-time `install.sh` the user already pastes for Agent Plugins) that *watches* a
  request file Hex drops in the container (`agent/io/summarize.*.json`), runs
  `claude -p < transcript`, and writes the result back as `.response` — exactly mirroring the
  inbound hook rendezvous we already ship. **Pros:** uses the user's existing Claude
  subscription/CLI (no API key, no per-token cost), all on the user's machine, reuses a proven
  pattern and the same "paste one command once" UX. **Cons:** requires the helper to be
  installed/running; more moving parts than a network call.

- **Option B — Anthropic API over HTTPS, directly from Hex.**
  The `network.client` entitlement is already set. User pastes an API key (stored in
  Integrations / Keychain). **Pros:** simplest code path, no helper, streaming is easy.
  **Cons:** costs money per token, needs key management, and is *not* "our already powerful LLM"
  (the subscription CLI) that the requirement calls for.

- **Option C — Relax the sandbox so Hex spawns `claude` directly.** Rejected: regresses the
  security/notarization posture for the whole app.

**Recommendation:** Option A as the primary (it matches the stated "use `claude -p`" intent and
the existing install UX), with Option B as an optional fallback for users who'd rather paste an
API key than install a helper. Worth confirming with you before we commit (§9).

## 6. Data model & storage

New, separate from `Transcript` history:

- `MeetingNote { id, title, startedAt, duration, audioPath, segments: [AttributedSegment],
  rawTranscript: String, summaryMarkdown: String?, speakerNames: [SpeakerID: String] }`
- `AttributedSegment { speakerID, text, startSeconds, endSeconds }`
- `StoredSpeaker { speaker: Speaker /*FluidAudio, Codable*/, displayName, bio: String?,
  lastSeen: Date, meetingCount: Int }`

Persistence follows the existing `@Shared(.fileStorage)` convention in the container:
`meetings.json` (or a `Meetings/` dir of per-meeting files) + `meeting_speakers.json`. Meeting
audio is retained (diarization/replay need it); add a retention setting.

## 7. UX surface

- **Entry point:** a dedicated **Meeting** trigger (separate hotkey and/or menu-bar item),
  defaulting to a **lock/long-form** recording mode (start → … → explicit stop), distinct from
  press-and-hold dictation. Reuses `HotKeyProcessor`'s double-tap-lock concept.
- **During recording (req #4):** a **notepad window** showing the live streaming transcript +
  elapsed time + a clear recording indicator. Floating, non-activating panel (reuse the
  `AgentPanel`/overlay window pattern). Text is appended from `StreamingAsrManager` updates.
- **After stop:** progress through transcribe → diarize → summarize; then a **Meeting Note view**
  showing the summary, the speaker-attributed transcript, and an inline control to **name/confirm
  speakers** (which writes back to the directory).
- **Settings:** a new "Meeting Notes" section (toggle, model choice, summarization transport &
  credentials, diarizer model download, speaker-memory on/off + "manage speakers").
- **Speaker Directory view:** list known speakers, rename, merge (`mergeSpeaker`), delete,
  mark permanent.

## 8. Research tasks to close before/within Phase 1

- [ ] Confirm Parakeet **batch** ASR exposes per-token/segment **timestamps** through FluidAudio,
  and the exact result type — this gates §4.2 alignment. (WhisperKit timings are known-good;
  streaming `StreamingAsrManager` is confirmed present, but the canonical pass needs timestamps.)
- [ ] Confirm forking the capture engine's mic buffers to both the WAV writer and
  `StreamingAsrManager` works cleanly (format/sample-rate match; the engine already taps at
  16 kHz mono). Check `StreamingTranscriptionUpdate` fields (confirmed vs. volatile text).
- [ ] Confirm `DiarizerModels.defaultModelsDirectory()` lands inside the container under our
  `XDG_CACHE_HOME`, and total model download size, so the download UX matches Parakeet's.
- [ ] Validate diarization quality + runtime on a realistic 30–60 min recording (Apple Silicon),
  including memory — `performCompleteDiarization` is batch over the whole file.

## 9. Decisions

1. **Audio source — DECIDED: in-person, mic only (v1).** Diarization runs on the existing
   single-mic 16 kHz capture; no recording-path changes. **System-audio capture for remote
   calls (ScreenCaptureKit) is explicitly out of scope for v1** and deferred (see §10, future).
2. **Summarization transport — DECIDED: Option A (helper running `claude -p`).** Matches the
   "use our own powerful LLM" intent and reuses the existing install/rendezvous UX; no API key,
   no per-token cost, all local. (Option B / API key remains a possible later fallback.) See §5.
3. **Live vs. batch — DECIDED.** **Live transcript text is shown during recording** via Parakeet
   streaming ASR (req #4). **Diarization runs in batch after stop.** **Live speaker labels** are a
   deferred "killer feature," not a v1 requirement.
4. **Naming authority — DECIDED: user confirms.** Claude proposes `Speaker N → name`, but a name
   only binds to a voiceprint after the user confirms, to avoid mislabeling the directory.

## 10. Suggested phasing

- **Phase 0 — Spike (de-risk):** two threads, behind a hidden dev flag:
  - *Diarization:* run `DiarizerManager` on a saved recording, dump `TimedSpeakerSegment`s to a
    log; confirm the diarizer models download into the container and quality is acceptable;
    confirm batch ASR timestamp availability (for §4.2 alignment).
  - *Live notepad:* fork mic buffers into `StreamingAsrManager` and render
    `transcriptionUpdates` into a minimal always-visible **notepad window** — this is the req #4
    de-risk (proves we can show live text + a clear "recording" signal) and gives us something
    tangible to look at early.
- **Phase 1 — Diarized transcript:** Meeting recording mode + ASR-timestamp plumbing + alignment
  → a speaker-attributed transcript (`Speaker 1/2/…`), stored as a `MeetingNote`, shown in a basic
  view. No memory, no LLM yet.
- **Phase 2 — Speaker memory:** Speaker Directory persistence, `initializeKnownSpeakers` seeding,
  cross-meeting recognition, naming/confirm UI, merge/delete.
- **Phase 3 — Summarization:** chosen `claude -p` transport, prompt design, summary + action items
  in the note, Claude-proposed names reconciled into the directory.
- **Phase 4 — Polish / future:** retention settings, read-aloud (Kokoro) of summaries, streaming
  labels, and **system-audio capture for remote calls (ScreenCaptureKit)** — deferred from v1
  per §9.1; revisit once in-person meetings ship.

## 11. Risks

- **ASR↔diarization alignment accuracy** — the main correctness risk; needs fixtures + tests.
- **Long-recording performance/memory** — batch diarization over an hour of audio; validate early.
- **Remote-meeting audio** — without system-audio capture, only the local mic is diarized; set
  expectations or take on the ScreenCaptureKit work.
- **Summarization transport friction** — Option A needs a resident helper; Option B costs money.
- **Speaker-memory false merges** — wrong voice match binds the wrong name; mitigate with
  confirmation UX and conservative thresholds.
- **Privacy** — meeting audio + transcripts + voiceprints are sensitive; keep everything local,
  gate any outbound send (even to `claude -p`) clearly, and use `HexLog` privacy annotations.
