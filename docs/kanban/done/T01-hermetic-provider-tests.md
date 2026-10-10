# T1 — Make provider resolution tests hermetic

**Status:** done

## Why
`Config.resolve(arguments:env:)` read the real home directory, so `ProviderTests.piKeyBorrowing` and `deepseekDefault` failed whenever `auth.json` existed without the expected keys.

## Scope
A Sendable snapshot of borrowed configuration (optional `PIProvider` plus a provider-to-API-key map) passed into resolution, so tests use fake credentials and temp dirs only.

## Acceptance
Tests pass regardless of the contents of the user's home directory; no real credentials are read or modified.
