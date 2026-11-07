# Claude CLI ImageGen through the existing proxy

Owner authorization (2026-11-04): try and integrate the existing Images API with
Claude CLI using a local MCP tool and concise skill. The authoritative initial
requirements I1–I5 and execution ledger are retained privately under
`D:/Tools/claudegpt-maintenance/client/imagegen-20261104/SPEC.md`.

Required behavior:
- Generate one image or edit with one to five explicit local image references,
  through the existing loopback proxy Images API and existing ChatGPT login.
- Fixed `gpt-image-2` image model; preserve the normal Claude client model,
  effort, provider, credentials and permission controls. No fallback or replay.
- Return newly saved file paths and content hashes; never overwrite a source
  image or put generated base64 into the conversation. Preserve provider errors.
- Disclose each exact image prompt and selected references/settings before
  sending it. Inspect actual returned files before claiming creation.
- Use an owned stdio child with explicit persistent tool scratch on Windows;
  no new recurring process or public/LAN image listener.
- Verify complete MCP generation/edit/error/file workflows, the real provider
  boundary and actual installed Claude CLI tool use. Version and qualify the
  usable local package, commit/push reusable source, retain exact rollback and
  clean expendable scratch transactionally.

First prove the existing native API in an isolated process. Enable the image
gate in the existing live service only at a fresh safe idle boundary after the
candidate workflow is qualified; record the exact config change and restore
procedure. Do not rebuild an unchanged Rust proxy or repatch an unchanged CLI.

Unavailable account access or an actual rejection is a delivery blocker, not
authorization to retry, change access programs or claim an installed workflow.
