# QAP.ia AI research

This directory contains reproducible, reviewable assets for the local speech and meeting-intelligence initiative.

## Versioned in Git

- `configs/`: candidate models and experiment settings;
- `data-manifests/`: provenance receipts, licenses, revisions and checksums;
- `evals/`: human and automatic quality gates;
- `schemas/`: contracts shared by training, evaluation and the application;
- `scripts/`: deterministic preparation, training, conversion and benchmark tools;
- `model-cards/`: evidence and limitations for candidates that reach release review.

## Never versioned

Raw audio, real transcripts, personal data, model weights, adapters, caches, credentials and run outputs must remain outside Git. The root `.gitignore` reserves dedicated local directories for them.

## Promotion rule

A model may move toward app integration only when its data receipt is complete and every gate in `evals/quality-gates.yaml` passes on the locked PT-BR test set. No aggregate score can compensate for a critical unsupported claim or an invented owner, deadline or decision.

The current production pipeline remains the rollback baseline until the candidate passes a shadow-mode release gate.
