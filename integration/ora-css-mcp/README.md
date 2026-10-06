# Ora model integration

A local Model Context Protocol (MCP) server lets compatible language-model clients edit Ora's native appearance, browser preferences, and persistent Cascading Style Sheets (CSS) Boosts. No network listener or account token is required. It follows the [standard input/output transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports#stdio).

## Connect Claude Code

From this repository, register the server for all projects:

```sh
claude mcp add --scope user ora-css -- python "$PWD/integration/ora-css-mcp/server.py"
```

Use an absolute Python interpreter path if the client cannot find `python`. The directory can also be loaded as a local Claude Code plugin with `claude --plugin-dir "$PWD/integration/ora-css-mcp"`. Use one registration method to avoid duplicate tools.

For Claude desktop, add the same command and absolute script path as an `ora-css` entry under `mcpServers` in its configuration. Restart the client to load newly configured tools.

## Connect Codex

Codex supports the same local server. Register the installed app's bundled server with an absolute Python interpreter path:

```sh
codex mcp add ora -- "$PYTHON_EXECUTABLE" "$ORA_APP_PATH/Contents/Resources/OraMCP/server.py"
codex mcp get ora
```

Set `PYTHON_EXECUTABLE` to your Python 3.10 or newer interpreter and `ORA_APP_PATH` to the installed Ora development app. Registration persists in Codex's user configuration. New Codex sessions discover the server; restart an existing editor extension to reload its tools. See [OpenAI's Codex MCP documentation](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).

The opt-in live test launches the actual Codex command-line client using its existing login. It asks the model to discover settings, change sidebar color and tab height, wait for the native runtime's acknowledgment, undo, and verify restoration. It uses a disposable store and an offscreen native test host, leaving the installed app's settings and windows untouched. It can consume model usage. An installed, signed-in Codex client is required:

```sh
TEST_RUNNER_ORA_CODEX_PATH="$CODEX_EXECUTABLE" \
TEST_RUNNER_ORA_CODEX_SERVER_PATH="$ORA_APP_PATH/Contents/Resources/OraMCP/server.py" \
TEST_RUNNER_ORA_CODEX_OUTPUT_DIRECTORY="$OUTPUT_DIRECTORY" \
ORA_DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
scripts/test-headless.sh -only-testing:oraTests/CodexLiveTests
```

The output directory contains private Codex event logs, native preference evidence, and before/change/undo images. Other MCP servers are disabled for this test. This test does not access passwords or launch a visible browser. A local Codex registration does not add tools to a hosted ChatGPT web conversation.

If the account rejects its configured model, set `TEST_RUNNER_ORA_CODEX_MODEL` to a model available to that account for this invocation. This override leaves the user's default model unchanged. Without `TEST_RUNNER_ORA_CODEX_PATH`, the account-backed test is skipped during ordinary test runs.

## Native customization

Settings > Customize & MCP exposes the same validated catalog and persistent store as the server. It also provides copyable setup commands and client configuration. The signed app bundles the server under `Contents/Resources/OraMCP/server.py`; use the installed app's stable path when configuring a client. Python 3.10 or newer is required, with no third-party dependencies. Existing `ora-css` registrations remain compatible and now discover 13 tools.

Ask your model: "Make Ora's sidebar darker, increase tab rows to 48 points, and use a rounded font." The model should:

1. Read `list_settings_schema` and `get_settings`.
2. Select keys from the catalog rather than inventing settings.
3. Optionally call `preview_settings` to validate and inspect a batch without applying it.
4. Call `update_settings` with `settings` and the current `expectedRevision`.
5. Check `get_settings` for the app's applied revision and timestamp.

For example:

```json
{
  "settings": {
    "theme.dark.sidebar": "#202020",
    "theme.rowHeight": 48,
    "theme.fontDesign": "rounded"
  },
  "expectedRevision": 2
}
```

The catalog describes 58 global settings and per-space templates: appearance mode, light/dark theme colors, font size/design, spacing, corners, sidebar size/position/visibility, toolbar visibility, tab retention, media behavior, privacy, custom ad-block lists, password preferences, search providers, keyboard shortcuts, site permissions, and space metadata/defaults. Replace `{spaceId}` using the spaces returned by `get_settings`. Space identifiers are normalized consistently. Global privacy defaults seed new spaces; existing spaces retain their own privacy choices. Built-in filter catalogs stay managed by Ora; custom filter lists and per-space enabled selections are editable.

Theme and layout edits apply live. Privacy changes apply on the next navigation. The catalog identifies application timing for each setting. Software updates remain disabled by the development build regardless of the stored preference. Apple Passwords settings select or enable its existing integration; these tools neither expose stored credentials nor bypass Apple's authentication.

`reset_settings` restores only named settings. `undo_settings` reverses the last batch without replacing unrelated preferences. Native controls and MCP share an undo history of up to 50 batches, retained across restarts. `export_settings_profile` returns portable JSON, optionally limited to selected keys; `import_settings_profile` validates the complete profile and applies it as one undoable batch. The native editor imports and exports the same profile files. Exports contain preferences, not vault credentials or webpage contents.

Preferences use `Customization/preferences.json` next to the existing `Boosts` directory. Both processes lock `preferences.lock`, validate every value, and atomically replace the document. Invalid batches, stale expected revisions, and corrupt files are rejected without destroying saved settings. Native controls are reconciled before editor transactions and during the half-second poll. While Ora is closed, edits persist for its next launch; app status and page context can be stale.

## Website styles

Ask Claude: "Make the current Ora webpage darker using a CSS Boost."

Claude should read `get_active_page` and `list_css_boosts` first, then call `upsert_css_boost`. Reuse an existing rule's id when changing it. Choose the current host for a site-specific request. `*.example.com` includes the parent domain and its subdomains. `*` applies to every HTTP or HTTPS website. Rules are ordered; later styles can override earlier styles. Use `!important` where needed to override the site's declarations.

`import_arc_css_boosts` transfers custom CSS from Arc's local Firestore cache, including completed write-ahead updates. It copies source files before reading, respects the database manifest and record sequence numbers, and preserves enabled states. It skips already imported ids so later Ora edits are kept. Color-wheel settings are not imported.

`delete_css_boost` removes a rule. Alternatively, save the same id with `enabled: false` to disable it and keep its CSS. Settings > CSS Boosts provides a native editor for the same rules.

Ora checks for changes every half second and applies them to open main-frame pages without refreshing. Rules are also injected at document start on subsequent navigations and refreshes. CSS is inserted as text into a stylesheet, not evaluated as JavaScript. Embedded frames retain their own site styles.

## Storage

The default server targets the sandboxed Ora development build. Data lives under the app's container in `Data/Library/Application Support/OraDev/Boosts`. Pass `--directory "$ORA_BOOST_DIRECTORY"` to use another build or a test store. The server and native editor use a shared file lock and atomic replacements. Malformed stores are preserved rather than overwritten.

The active page context includes URL, host, title, and timestamp, never page contents. Private tabs clear the context. Context can become stale when Ora closes, so check its timestamp before applying styles to the current tab. Boosts persist even when Ora or Claude is closed.

## Background behavior

Ora uses a dark neutral WebKit under-page canvas and provides a dark fallback for documents without their own background. Website-authored themes remain under site control; use a CSS Boost to override an explicit white theme. The default does not invert images or rewrite website colors.

## Validation

```sh
python -m pytest integration/ora-css-mcp/tests -q
ORA_DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" python scripts/test-web-styles.py
```

The second command runs actual WebKit pages offscreen against a local server. It checks load, redirects, repeated refresh, pixel backgrounds, persistent CSS, and live removal and updates. No normal browser window is launched.
