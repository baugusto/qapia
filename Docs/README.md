# QAP.ia Documentation

This directory captures the product reasoning and engineering decisions behind QAP.ia.

## Start here

1. [Product Definition](qapia-product-definition.md) explains the problem, audience, product principles and intended experience.
2. [Technical Architecture](qapia-technical-architecture.md) describes the application layers, data flow and major design decisions.
3. [Testing Checklist](qapia-testing-checklist.md) covers the main product and privacy scenarios.

## Artificial intelligence research

1. [Local AI Discovery and Specialization Plan](qapia-ai-discovery.md) records the target architecture, prior-adapter diagnosis, model shortlist, quality gates and execution plan.
2. [Dataset Registry](qapia-ai-dataset-registry.yaml) is the machine-readable commercial-use screening and provenance allowlist.
3. [Private Recording Baseline](qapia-private-audio-baseline.md) records the privacy-preserving inventory, sample selection and annotation gates for existing app recordings.
4. [Private Annotation Guide](qapia-private-annotation-guide.md) defines the secure human-review workflow and ASR approval rules.

## Integration and distribution

1. [Google Calendar Setup](qapia-google-calendar-setup.md) explains OAuth configuration and the read only permission model.
2. [Distribution Guide](qapia-distribution.md) covers application packaging and release preparation.
3. [Online Update Roadmap](qapia-online-update-roadmap.md) records the planned update strategy.

## Product history

1. [Experience Specification](qapia-sprint-0-ux-ui-spec.md) documents the original interaction and interface direction.
2. [Decision Log](qapia-decision-log.md) records important product and technical choices.
3. [Implementation Backlog](qapia-sprint-backlog.md) preserves the delivery history of the initial product cycles.

## Privacy principle

Meeting audio, transcripts and summaries remain on the device. Any future architecture change that affects this principle should be documented before implementation.
