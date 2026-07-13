# Rolling Long-Text TTS Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Start long cloud reads after the first natural segment is ready and keep playback continuous with no more than two future segments prepared.

**Architecture:** A pure planner splits text; a provider-neutral rolling coordinator bounds preparation and recovery; provider adapters produce ordered PCM or MP3 segments; `ReadAloudManager` maps callbacks to one continuous UI session.

**Tech Stack:** Swift concurrency, URLSession streaming, AVFoundation, AppKit, Swift Testing.

## Global Constraints

- Prefer paragraphs, then sentences, then whitespace; hard cap 750 characters unless a provider cap is smaller.
- Keep at most two future segments in flight or buffered.
- Never replay text whose audio has started.
- Never reintroduce byte-at-a-time work on the MainActor.
- Apple TTS keeps its existing local path.
- Preserve retry, opt-in fallback, queue, speed, pause, skip, and stop behavior.

---

### Task 1: Natural segment planner

**Files:**
- Create: `VoiceInk/ReadAloud/ReadAloudSegmentPlanner.swift`
- Modify: `VoiceInkTests/VoiceInkTests.swift`
- Modify: `VoiceInk/ReadAloud/CloudTTSChunkedPlayer.swift`

**Interfaces:**
- Produces: `ReadAloudSegment`, `ReadAloudSegmentPlan`, and `ReadAloudSegmentPlanner.plan(text:maxCharacters:)`.

- [ ] **Step 1: Write failing planner tests**

```swift
@Test func segmentPlannerPrefersParagraphsAndPreservesContent() throws {
    let text = String(repeating: "First paragraph sentence. ", count: 18) + "\n\n" + String(repeating: "Second paragraph sentence. ", count: 18)
    let plan = ReadAloudSegmentPlanner.plan(text: text)
    #expect(plan.segments.count > 1)
    #expect(plan.segments.allSatisfy { $0.text.count <= 750 })
    #expect(plan.reconstructedText == text.trimmingCharacters(in: .whitespacesAndNewlines))
}
```

- [ ] **Step 2: Run `make test` and verify the planner types are missing.**

- [ ] **Step 3: Implement the planner**

```swift
struct ReadAloudSegment: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    let characterRange: Range<Int>
}

struct ReadAloudSegmentPlan: Equatable, Sendable {
    let originalText: String
    let segments: [ReadAloudSegment]
    var reconstructedText: String
    func text(fromSegment index: Int) -> String
}

enum ReadAloudSegmentPlanner {
    static let singleRequestThreshold = 200
    static let targetCharacters = 600
    static let maximumCharacters = 750
    static func plan(text: String, maxCharacters: Int = maximumCharacters) -> ReadAloudSegmentPlan
}
```

Make `SentenceChunker` a compatibility wrapper until provider call sites migrate.

- [ ] **Step 4: Run `make test`, then commit**

```bash
git add VoiceInk/ReadAloud/ReadAloudSegmentPlanner.swift VoiceInk/ReadAloud/CloudTTSChunkedPlayer.swift VoiceInkTests/VoiceInkTests.swift
git commit -m "Add natural read-aloud segment planning"
```

---

### Task 2: Bounded rolling coordinator

**Files:**
- Create: `VoiceInk/ReadAloud/CloudTTSRollingPipeline.swift`
- Modify: `VoiceInkTests/VoiceInkTests.swift`

**Interfaces:**
- Consumes: `ReadAloudSegmentPlan`.
- Produces: `RollingSegmentScheduler`, `RollingSegmentEvent`, and `RollingRecoveryPosition`.

- [ ] **Step 1: Write fake-provider tests**

```swift
@Test func rollingRecoveryNeverReplaysStartedSegment() {
    let position = RollingRecoveryPosition(completedThrough: 1, activeIndex: 2, activeAudioStarted: true)
    #expect(position.firstSafeFallbackIndex == 3)
}

@Test func rollingWindowNeverExceedsTwoFutureSegments() {
    #expect(RollingPrefetchWindow.maximumFutureSegments == 2)
    #expect(RollingPrefetchWindow.indices(current: 2, total: 8) == [3, 4])
}
```

- [ ] **Step 2: Run `make test` and verify the scheduler types are missing.**

- [ ] **Step 3: Implement the bounded state machine**

```swift
enum RollingSegmentEvent: Equatable, Sendable {
    case startedPreparing(Int)
    case audioStarted(Int)
    case completed(Int)
    case buffering(Int)
    case resumed(Int)
}

struct RollingRecoveryPosition: Equatable, Sendable {
    var completedThrough: Int
    var activeIndex: Int?
    var activeAudioStarted: Bool
    var firstSafeFallbackIndex: Int
}

enum RollingPrefetchWindow {
    static let maximumFutureSegments = 2
    static func indices(current: Int, total: Int) -> [Int]
}
```

The coordinator starts index 0, fills only the two allowed future indices, consumes in order, cancels every child on termination, and emits buffering only when the next ordered result is not ready after current playback drains.

- [ ] **Step 4: Run `make test`, then commit**

```bash
git add VoiceInk/ReadAloud/CloudTTSRollingPipeline.swift VoiceInkTests/VoiceInkTests.swift
git commit -m "Add bounded rolling TTS scheduler"
```

---

### Task 3: Integrate cloud providers

**Files:**
- Modify: `VoiceInk/ReadAloud/CloudTTSProvider.swift`
- Modify: `VoiceInk/ReadAloud/CloudTTSChunkedPlayer.swift`
- Modify: `VoiceInk/ReadAloud/ReadAloudUsageTracker.swift`
- Modify: `VoiceInkTests/VoiceInkTests.swift`

- [ ] **Step 1: Add failing ordering and early-playback tests**

```swift
@Test func orderedSegmentBufferWaitsForZeroWhenOneFinishesFirst() {
    var buffer = OrderedSegmentBuffer<Data>(count: 3)
    buffer.insert(Data([1]), at: 1)
    #expect(buffer.popNext() == nil)
    buffer.insert(Data([0]), at: 0)
    #expect(buffer.popNext() == Data([0]))
    #expect(buffer.popNext() == Data([1]))
}
```

- [ ] **Step 2: Add focused provider segment adapters**

```swift
struct PreparedPCMStream: Sendable {
    let stream: AsyncStream<Data>
    let cancel: @Sendable () -> Void
}

struct PreparedMP3Segment: Sendable {
    let index: Int
    let data: Data
}
```

Gemini 2.5 returns PCM per segment instead of building `combinedPCM`; Gemini 3.1 and ElevenLabs return cancellable PCM streams; OpenAI returns MP3 per segment. Run them through the rolling window and the existing continuous PCM or ordered MP3 player.

- [ ] **Step 3: Aggregate usage once per selection/provider**

```swift
struct ReadAloudUsageAccumulator: Sendable {
    mutating func record(provider: String, model: String, voiceId: String, characters: Int)
    func flush(to tracker: ReadAloudUsageTracker)
}
```

Successful prefetched requests count toward provider usage, including work completed before cancellation; fallback text is not double-counted under the same provider.

- [ ] **Step 4: Run `make test`, then commit**

```bash
git add VoiceInk/ReadAloud/CloudTTSProvider.swift VoiceInk/ReadAloud/CloudTTSChunkedPlayer.swift VoiceInk/ReadAloud/ReadAloudUsageTracker.swift VoiceInkTests/VoiceInkTests.swift
git commit -m "Pipeline long cloud reads by segment"
```

---

### Task 4: Buffering UI and safe recovery

**Files:**
- Modify: `VoiceInk/ReadAloud/ReadAloudManager.swift`
- Modify: `VoiceInk/ReadAloud/ReadAloudIndicatorWindow.swift`
- Modify: `VoiceInk/ReadAloud/ReadAloudSettings.swift`
- Modify: `VoiceInkTests/VoiceInkTests.swift`

- [ ] **Step 1: Add failing state and fallback-position tests**

```swift
@Test func bufferingRemainsAnActiveReadAloudState() {
    #expect(ReadAloudState.buffering.isActive)
}

@Test func fallbackTextBeginsAtTheFirstSafeSegment() {
    let plan = ReadAloudSegmentPlanner.plan(text: String(repeating: "A complete sentence. ", count: 100))
    #expect(plan.text(fromSegment: 1).hasPrefix(plan.segments[1].text))
}
```

- [ ] **Step 2: Implement state mapping**

```swift
enum ReadAloudState: Equatable {
    case idle, capturing, loading, speaking, buffering, paused
    var isActive: Bool { self != .idle }
}
```

Map buffering/resumed events without hiding the player. Fallback receives only `plan.text(fromSegment: recovery.firstSafeFallbackIndex)`. A no-fallback error stops the current selection without clearing separately queued selections.

- [ ] **Step 3: Update the AppKit status label**

```swift
case .buffering:
    statusLabel.stringValue = String(localized: "Buffering next section")
    statusImage.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
```

Keep pause/resume, speed, next, and stop mounted while buffering.

- [ ] **Step 4: Run `make test`, then commit**

```bash
git add VoiceInk/ReadAloud/ReadAloudManager.swift VoiceInk/ReadAloud/ReadAloudIndicatorWindow.swift VoiceInk/ReadAloud/ReadAloudSettings.swift VoiceInkTests/VoiceInkTests.swift
git commit -m "Add buffering and segment-aware TTS recovery"
```

---

### Task 5: Full signed verification

- [ ] Run `git diff --check` and `make test`; require all unit and UI tests to pass.
- [ ] Run `make local`, stop any stale Speakeasy-Voice process, and open `~/Downloads/Speakeasy-Voice.app`.
- [ ] Verify a multi-page read begins after its first segment, remains one miniplayer session, and Stop cancels pending work.
- [ ] Confirm no raw provider JSON appears and `git status --short --branch` contains no unrelated changes.
