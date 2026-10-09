# Kaya: Task Assistant for ADHD

**Your goals. Your pace. Your independence.**

## About

Kaya is a native iOS app that helps people with ADHD, autistic people, and
people with cognitive disabilities turn everyday goals — getting ready for
school, buying groceries, leaving the house — into calm, step-by-step routines
completed at their own pace.

Kaya is **voice-first**: the home screen is a single animated press-to-talk
orb. Say a goal and Kaya generates a personalized routine with on-device AI;
inside a routine it reads each step aloud, listens, and advances when you say
"done" — hands-free, end to end. A four-tab navigation dock keeps everything
one tap away: **Kaya** (voice home), **Routines**, **Progress**, **You**.

Everything runs **on device** — routine generation via Apple Foundation
Models, voice recognition via `SFSpeechRecognizer` with
`requiresOnDeviceRecognition`, and speech via `AVSpeechSynthesizer`. No cloud
AI, no backend, no accounts, no analytics. **The whole app works offline.**

## Tech Stack

| Layer         | Technology                                                               |
| ------------- | ------------------------------------------------------------------------ |
| UI            | SwiftUI (forced dark scheme, custom warm palette + orange accent)        |
| On-device AI  | Apple Foundation Models (`@Generable`, `@Guide`, `LanguageModelSession`) |
| Voice input   | `SFSpeechRecognizer` with on-device recognition                          |
| Speech output | `AVSpeechSynthesizer` (premium/enhanced voices, tuned pacing)            |
| Persistence   | SwiftData (`Routine`, `RoutineStepRecord`, `UserProfile`)                |
| Notifications | Local notifications via `ReminderService`                                |
| Photos        | PhotosPicker, stored locally in SwiftData                                |
| Toolchain     | Xcode 26.6, Swift 6.3, iOS 26.5 deployment target                        |

## Features

### Voice-first interaction

- Large animated press-to-talk orb on the home screen
- Natural language commands: "buy bread", "done", "skip", "repeat", "pause",
  "something changed", "what's left today?"
- Voice navigation between tabs; 25-second idle timeout and silent filtering
  of filler-only transcripts ("um", "uh")
- Queued speech replies so bubbles are spoken without cutting each other off

### AI-generated, personalized routines

- Structured routine generation: title, 3–8 steps, instructions, "done when"
  criteria, minute estimates, and SF Symbol icons
- One physical action per step, gather-items-first ordering, post-generation
  validation and repair
- Onboarding distills step size, goals, hard things, and helpful strategies
  into a standing AI context applied to every generation
- Edit drafts by chat: "add a step for locking the door"

### Guided task player

- Voice-only step player: narrate → listen → advance, with a dominant
  elapsed count-up timer (no countdowns, no pressure)
- Step dots, progress ring around the mic, graphical step icons
- Adaptive mid-routine help: "say it simpler" rewrites the step,
  "break it down" inserts micro-steps, "something changed" offers alternatives
- Mid-task Q&A — ask questions about the current step

### Adaptive difficulty

- Post-completion reflection: rate routines easy / okay / hard
- A "hard" rating offers a gentler variant with smaller steps next run
- Steps running over ~2× their estimate trigger a one-time simplify offer
- Skipped-run history informs future suggestions

### Scheduling & reminders

- One-off, daily, and weekly routine schedules with weekday/time parsing
- Calendar view on the Routines tab
- Local notification reminders for scheduled routines
- In-progress nudge ~45 minutes after backgrounding, canceled on return

### Progress & momentum

- Weekly AI analysis, momentum/level ring, weekly activity dots
- Calm milestones (First step, Routine done, Ten steps…) — no streaks,
  no losses, progress only accumulates
- Photo memories (up to 3 per routine) with captions feeding AI reflections
- Post-completion journal notes distilled into learned personal facts

### Memory & personalization

- Eight-step onboarding wizard builds a `UserProfile`: name, step size,
  common goals, what makes tasks hard, what helps, encouragement style,
  speech preferences, and free-text context
- Kaya learns facts over time — always with explicit user confirmation
  before saving; viewable and deletable under "Things Kaya learned"
- Daily schedule briefing and "what should I do now?" suggestions on Home

### Privacy & accessibility

- 100% on-device: AI, voice, photos, and data never leave the iPhone
- Works fully offline, including generation
- Voice is an accelerator, never a requirement — every feature works by touch
- Dynamic Type, VoiceOver labels, ≥44 pt targets, Reduce Motion respected
- No autoplaying audio unless speech was enabled

## Requirements

- Xcode 26+ (built with Xcode 26.6, Swift 6.3)
- iOS 26.0+ deployment target (project is set to 26.5)
- AI generation requires **Apple Intelligence** enabled (capable iPhone, or
  the simulator on an Apple Silicon Mac)
- Voice control needs Microphone + Speech Recognition permission

## Run it

```bash
open Kaya/Kaya.xcodeproj
```

Pick an iPhone simulator or device and press Run. No extra setup.

## Architecture

| File                       | Responsibility                                            |
| -------------------------- | --------------------------------------------------------- |
| `KayaApp.swift`            | App entry, SwiftData container, forced dark scheme        |
| `ContentView.swift`        | Four-tab `TabView` dock, onboarding gate                  |
| `OnboardingView.swift`     | Eight-step wizard → `UserProfile` AI context              |
| `HomeView.swift`           | Voice home, chat panel, AI routing, scheduling Q&A        |
| `RoutinesView.swift`       | Calendar, in-progress and saved routines                  |
| `ProgressTabView.swift`    | Weekly AI analysis, momentum, reflections, photos         |
| `AboutYouView.swift`       | Profile editing, learned facts, toggles                   |
| `RoutineBuilderView.swift` | Goal input, deadline controls, AI generation              |
| `RoutineReviewView.swift`  | Editable/reorderable steps, finish-by time                |
| `GuidedTaskView.swift`     | Voice-only task player: timer, steps, adaptive help       |
| `RoutineModels.swift`      | SwiftData models: routines, steps, profile, learned facts |
| `RoutineStore.swift`       | Built-in templates, persistence helpers                   |
| `LocalAIService.swift`     | All Foundation Models calls with availability fallbacks   |
| `VoiceService.swift`       | On-device recognition, command parser, listening orb      |
| `SpeechService.swift`      | `AVSpeechSynthesizer` wrapper with speech queue           |
| `ReminderService.swift`    | Scheduled reminders and in-progress nudges                |
| `Momentum.swift`           | Milestones, levels, calm praise                           |
| `KayaTheme.swift`          | Dark warm palette, orange accent, shared styles           |

## Design principles

Calm, respectful, predictable. Dark warm palette (`#14100D`) with an orange
accent (`#F0973B`), graphical feedback everywhere, and no countdowns,
streaks, confetti, or infantilizing language.
