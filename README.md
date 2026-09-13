# QAP.ia

<p align="center">
  <img src="Assets/AppIcon-1024.png" width="128" alt="QAP.ia app icon">
</p>

<p align="center">
  Private by design meeting intelligence for macOS
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/macOS-15%2B-000000?logo=apple" alt="macOS 15 or newer">
  <img src="https://img.shields.io/badge/Apple%20Silicon-M1%2B-555555" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/license-PolyForm%20Strict%201.0.0-6C63FF" alt="PolyForm Strict License">
</p>

QAP.ia is a native macOS application that records meetings, transcribes audio locally and turns conversations into structured summaries. Audio, transcripts and summaries remain on the Mac.

![QAP.ia home screen](AppStore/Screenshots/UPLOAD-APPLE/01-QAPia-home-1440x900.jpg)

## Why QAP.ia

Most meeting assistants depend on cloud processing. QAP.ia takes a local first approach. It captures microphone and system audio, processes the meeting on the device and stores the complete history locally.

The project explores how product design, native macOS capabilities and private artificial intelligence can work together in a focused productivity experience.

## Core capabilities

| Capability | Implementation |
| --- | --- |
| Audio capture | Microphone and system audio through ScreenCaptureKit |
| Local transcription | Whisper runs on the Mac and processes ordered recording segments |
| Private summaries | Apple Intelligence when available, with a deterministic local alternative |
| Meeting awareness | Automatic detection for Google Meet, Microsoft Teams and Zoom |
| Calendar context | Read only Google Calendar integration using OAuth 2.0 and PKCE |
| Searchable history | Meetings, participants, transcripts and summaries stored with SwiftData |
| Summary templates | Built in and custom structures for different meeting types |
| Background processing | Interrupted transcription and summary work resumes on the next launch |

## Product experience

![QAP.ia summary templates](AppStore/Screenshots/UPLOAD-APPLE/02-QAPia-modelos-1440x900.jpg)

The interface follows a calm visual system designed for long work sessions. A compact floating indicator shows live audio activity while the main window stays out of the way.

## Privacy model

| Data | Handling |
| --- | --- |
| Meeting audio | Stored locally inside Application Support |
| Transcripts | Generated and stored locally |
| Summaries | Generated locally |
| Calendar access | Read only access to upcoming events |
| Google session | Protected by the macOS Keychain |
| Whisper model | Downloaded once, verified and stored locally |

QAP.ia does not upload meeting audio or transcripts to an artificial intelligence service.

## Architecture

| Layer | Responsibility |
| --- | --- |
| SwiftUI application | Navigation, recording controls, meeting history and settings |
| View models | Product state and user interaction orchestration |
| Capture services | ScreenCaptureKit sessions, microphone input and audio segmentation |
| Transcription services | Whisper model preparation, segment processing and transcript assembly |
| Summary services | Template rendering and local summary generation |
| Storage services | SwiftData persistence and meeting file management |
| Calendar services | OAuth authentication, Keychain storage and event retrieval |

The full design is documented in [Technical Architecture](Docs/qapia-technical-architecture.md).

## Technology

| Area | Technology |
| --- | --- |
| Language | Swift 6 |
| Interface | SwiftUI |
| Audio | ScreenCaptureKit and AVFoundation |
| Persistence | SwiftData and local files |
| Transcription | whisper.cpp |
| Local intelligence | Foundation Models when available |
| Authentication | AuthenticationServices, OAuth 2.0 and PKCE |
| Secure storage | macOS Keychain |

## Requirements

1. macOS 15 or newer
2. Apple Silicon Mac
3. Xcode 16 or newer
4. Microphone and screen recording permission

macOS 26 or newer with Apple Intelligence enables the native language model summary provider. Earlier supported versions use the local structured summary provider.

## Build and test

Run the test suite:

```zsh
swift test
```

Build the macOS application bundle:

```zsh
bash Scripts/build-app-bundle.sh
```

The generated application is placed in the local Build directory, which is intentionally excluded from version control.

## Google Calendar

Calendar integration requires a Google OAuth client identifier for the application bundle. No client secret is used or stored.

```zsh
QAPIA_GOOGLE_CLIENT_ID="your-client-id.apps.googleusercontent.com" bash Scripts/build-app-bundle.sh
```

See [Google Calendar Setup](Docs/qapia-google-calendar-setup.md) for the complete configuration.

## Documentation

The [documentation index](Docs/README.md) provides product context, architecture, testing, distribution guidance and implementation decisions.

## Repository scope

This repository contains source code, tests, application assets and technical documentation. Build products, signing certificates, provisioning profiles, meeting recordings, transcripts and local credentials are intentionally excluded.

## License

QAP.ia is publicly viewable source code and is not open source under the Open Source Initiative definition.

The software is licensed under the [PolyForm Strict License 1.0.0](LICENSE). It may be used only for noncommercial purposes. Distribution, modification and derivative works are not permitted by the license. Commercial use requires a separate written agreement from the copyright holder.

Copyright 2026 Bruno Augusto. All rights reserved.
