# Claude CLI image tools

`imagegen-mcp.mjs` is a dependency-free Node stdio MCP server for the fork's
existing, opt-in Images API. It exposes `generate_image` and `edit_image`, using
the existing ChatGPT login and fixed `gpt-image-2` backend. The normal Claude
conversation model and effort are unchanged. No Platform API key is needed.
This is the fork's internal Codex image integration; account entitlement and the
upstream contract must be verified independently of protocol fixtures.

Run the server with an explicit loopback origin and output directory:

```powershell
node.exe imagegen-mcp.mjs --base-url http://127.0.0.1:8317 --output-root D:\Tools\claudegpt-imagegen\images
```

The existing proxy must have `codex.imagesApi: true` or
`CCP_CODEX_IMAGES_API=1` when it starts. Enabling this gate on the live service
requires its ordinary safe-idle supervisor lifecycle and exact config rollback.
Do not replace the binary or build Rust just to enable this existing route.

Install a versioned ordinary-file copy and configure Claude's user-scoped stdio
MCP entry through its supported `claude mcp add-json` command. Preserve existing
MCP entries and settings. Give that child explicit tool-owned TEMP/TMP and Node
compile-cache paths on D:, separate from expendable task scratch. The client owns
the stdio child; it exits on stdin EOF. No daemon, browser bridge, updater, new
schedule or permission bypass is needed. Deploy `SKILL.md` as
`~/.claude/skills/claudegpt-imagegen/SKILL.md` and verify the installed copy.

Each call creates a new file and returns path/hash/format metadata, avoiding
large base64 conversation content. Edits accept one to five absolute local image
paths, at most 20 MiB each and 50 MiB total. Neither existing images nor output
files are overwritten. The adapter sends no retries and returns actual proxy
errors as MCP `isError` results. It does not log prompts, uploads or generated
base64. The skill requires exact outgoing prompt/reference disclosure, image
inspection, and no provider switching after refusal.

Focused protocol/file tests use a fictional local HTTP service, including a
fictional policy response without invoking any real rejection:

```powershell
$env:IMAGEGEN_TEST_ROOT='E:\Temp\exact-task\fixtures'
node.exe --test imagegen-mcp.test.mjs
```

Keep the generated fixture directory until the test's client and HTTP service
have exited; then clean it through transactional-cleanup. Production qualification
also requires a real image and actual Claude CLI tool call, not only these tests.

Retain a versioned installed package, exact source revision/hashes, activation
receipt and original MCP/config/skill state with a restore procedure. Retire an
older package only after checking current references and rollback consumers.
