# OSKO Native — Technical Specification

> *"No estoy aquí para pensar por ti. Estoy aquí para pensar contigo."*

OSKO is a native macOS digital companion built for Apple Silicon, powered locally by **Llama 3.2 (3B)** via **MLX Swift** and rendered inside a non-activating floating **`NSPanel`** anchored to the hardware notch or top screen edge.

## Architecture & Requirements
- **Language & Concurrency:** Swift (`MainActor` default actor isolation, strict member import visibility)
- **UI Framework:** SwiftUI + AppKit (`NSPanel` / `NSHostingView`)
- **AI Engine:** MLX Swift (`MLXLLM`, `MLXLMCommon`)
- **Model:** `mlx-community/Llama-3.2-3B-Instruct-4bit`
- **OS Target:** macOS 26.0+ (Apple Silicon)

## Core Modules (`OSKO-Native/OSKO/OSKO/`)

### 1. Brain & Memory
- **`AIModelManager.swift`**: Manages local cache verification, loading, streaming generation, and memory fact extraction exclusively on `mlx-community/Llama-3.2-3B-Instruct-4bit`, embedding the unified Character Bible system prompt.
- **`OSKOMemoryManager.swift`**: Off-main-thread Swift `actor` providing atomic JSON persistence (`~/Library/Application Support/OSKO/osko_memory.json`), normalized deduplication, automatic corrupt-file backup, 100-entry FIFO bounding, and bilingual (ES/EN) relevance retrieval.
- **`CharacterEngine.swift`**: Defines the 9 `OSKOEmotion` states, strips and parses `[EMOTION:...]` tags (including partial streaming prefixes), applies word-boundary fallback heuristics, and maps emotions to the 4 vocal states.

### 2. Desktop Presence & Visual Body
- **`OSKOApp.swift` & `OSKOPanel.swift`**: Runs OSKO as an `.accessory` app inside a borderless, transparent, `.statusBar`-level `NSPanel` (`OSKOPanel`). `OSKOScreenGeometry` and `OSKOPanelLayout` anchor the panel to the hardware notch or top-center screen edge across single and multi-display setups, while `OSKOHostingView` enables click-through in transparent exterior areas when collapsed.
- **`OSKOVisualBody.swift`, `OSKOEyesView.swift`, `NotchView.swift` & `OSKOColors.swift`**: Implements the slightly asymmetric organic-technological silhouette (`OSKOBodyShape`), Character Bible color palette (`#142B3B`, `#17616A`, `#D7A65B`, `#B6C9C8`), subtle two-wave floating motion, natural blinking, and smooth global screen cursor gaze tracking (`OSKOGazeMath`).

### 3. Voice Senses (STT / TTS)
- **`OSKOVoiceManager.swift`**:
  - **STT (`OSKOSpeechRecognizer`)**: Bilingual (`es`/`en`) speech recognition via `SFSpeechRecognizer` + `AVAudioEngine`, with automatic activation on panel expand, manual microphone toggle, and safe TCC permission handling.
  - **TTS (`OSKOVoiceSynthesizer` & `OSKOVocalProfile`)**: Bilingual speech synthesis via `AVSpeechSynthesizer` mapping the 4 Character Bible vocal states (`organic`, `spark`, `deep`, `playful`) to distinct rate, pitch, and delay parameters, prioritizing natural Latin American Spanish (`es-CO`, `es-419`, `es-MX`) and English voices.

### 4. ViewModel Orchestration
- **`OSKOViewModel.swift`**: Bridges UI, `AIModelManager`, `OSKOMemoryManager`, `CharacterEngine`, panel expansion state, global cursor gaze updates, and STT/TTS voice controls.

## Testing (`OSKO-Native/OSKO/OSKOTests/`)
Unit test suites built with Swift Testing (`import Testing`):
- `AIModelManagerTests.swift` — Prompt unification, model enforcement, cache validation, and memory sanitization.
- `CharacterEngineTests.swift` — `[EMOTION:...]` tag parsing, streaming tag stripping, and word-boundary emotion heuristics.
- `OSKOMemoryManagerTests.swift` — Actor persistence, deduplication, FIFO eviction, corrupt JSON recovery, and bilingual retrieval.
- `PanelGeometryTests.swift` — Notch/top-edge geometry, multi-display coordinates, `OSKOPanel` flags, and click-through hit-testing.
- `GazeTrackerTests.swift` — Cursor gaze normalization/clamping, emotion restraint, interpolation, and `OSKOBodyShape` asymmetry.
- `VoiceTests.swift` — 4-state vocal profile mapping, tag stripping, bilingual voice selection, TCC permission states, and STT lifecycle.

### Build & Run Tests
```bash
xcodebuild -project OSKO/OSKO.xcodeproj -scheme OSKO -configuration Debug -destination platform=macOS build
xcodebuild -project OSKO/OSKO.xcodeproj -scheme OSKO -configuration Debug -destination platform=macOS test
```
*(Optional: set `OSKO_RUN_LIVE_MLX_TESTS=1` to include the live local MLX weight-loading integration test.)*
