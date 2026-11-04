---
name: claudegpt-imagegen
description: Generate or edit raster images through the local ClaudeGPT ImageGen MCP tools. Use for requested image assets or edits; save results in the project when a destination is known.
---

Use `mcp__claudegpt_imagegen__generate_image` for a new image and
`mcp__claudegpt_imagegen__edit_image` for edits using local reference files.
Load the tools with ToolSearch if they are deferred. If unavailable, report that
the local integration is unavailable; do not invent another endpoint or provider.

Immediately before each image call, show the full final prompt in a fenced text
block. Separately identify the chosen reference image paths/roles and submitted
size, quality and background options. Then proceed within the user's existing
authorization. Keep prompts self-contained: requested scene/action, concrete visual
constraints, exact text and edit invariants only. Do not add project history,
implementation stages, unsupported assurances or unrelated conversation.

For edits, inspect the necessary images first and include only those references.
Use `background: transparent` for cutouts/transparent requests and preserve alpha
when requested. Set `output_directory` to an absolute project asset directory
when known; otherwise the tool saves under its configured output root. It creates
a new file and returns its path, format, dimensions when available, and SHA256.
Read the output image to inspect it; report the saved path and meaningful limits.
Never claim image creation from a tool error or an uninspected response.

Provider errors and policy interruptions remain visible. Do not retry a refused
request, conceal relevant details, switch models/providers or change access
programs. An unknown or interrupted outcome needs inspection before another call.
Ordinary revisions need the user's requested change or another concrete reason,
and the revised prompt must be shown in full before it is sent.
