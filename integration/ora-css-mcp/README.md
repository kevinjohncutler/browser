# Ora CSS integration

A local Model Context Protocol (MCP) server lets Claude create persistent Cascading Style Sheets (CSS) Boosts in Ora. No network listener or account token is required. It follows the [standard input/output transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports#stdio).

## Connect Claude Code

From this repository, register the server for all projects:

```sh
claude mcp add --scope user ora-css -- python "$PWD/integration/ora-css-mcp/server.py"
```

Use an absolute Python interpreter path if the client cannot find `python`. The directory can also be loaded as a local Claude Code plugin with `claude --plugin-dir "$PWD/integration/ora-css-mcp"`. Use one registration method to avoid duplicate tools.

For Claude desktop, add the same command and absolute script path as an `ora-css` entry under `mcpServers` in its configuration. Restart the client to load newly configured tools.

## Use

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
