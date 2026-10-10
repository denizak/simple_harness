# T2 — Make model switches affect actual requests

**Status:** done

## Why
Switching model or provider at runtime did not reliably change the requests the client sent.

## Scope
Runtime-state work so the active model/endpoint is what each request uses. T5 builds on it.

## Acceptance
A scripted-model test shows a switch changes the next request's model and endpoint.
