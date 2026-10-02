# Read-only WooCommerce connector for Agent Studio agents (MCP)

**Assignment option 3 - private connector for a merchant tool (WooCommerce).**

A zero-dependency Python connector that lets an AI agent *read* orders, products and inventory from a WooCommerce store, exposed as an **MCP server** (stdio) with 9 tools. It includes API-key auth, WooCommerce's merchant-approval authorize flow, rate-limit handling, PII masking, input validation, tests, and a mock store so everything runs offline.

```
Agent Studio / any MCP client
        |  JSON-RPC over stdio (initialize, tools/list, tools/call)
   wc_connector.mcp_server      <- protocol, structured errors
        |
   wc_connector.tools           <- 9 read-only tools, validation, projection, PII masking
        |
   wc_connector.client          <- GET-only, token bucket, 429/5xx retry (Retry-After + jittered backoff)
        |  HTTPS, Basic auth (consumer key/secret)
   WooCommerce REST API  /wp-json/wc/v3/{orders,products,...}
```

## Quick start (no installs; Python 3.9+)

```bash
python3 -m unittest -v          # 29 tests against the bundled mock store
python3 scripts/demo.py         # guided demo (saved output: docs/demo_output.txt)
python3 -m mock_wc --port 8099  # optional: run the mock store yourself
```

Try the MCP server against the mock store:

```bash
python3 -m mock_wc --port 8099 &
export WC_BASE_URL=http://127.0.0.1:8099 WC_CONSUMER_KEY=ck_mock_key WC_CONSUMER_SECRET=cs_mock_secret
python3 -m wc_connector check
python3 -m wc_connector call get_order --args '{"order_id": 1001}'
python3 -m wc_connector call get_inventory --args '{"sku": "BTL-STL"}'
```

## Connecting a real store

**Option A - API keys.** In WordPress admin: *WooCommerce > Settings > Advanced > REST API > Add key*, permission **Read**. Put the key/secret in the environment (see `.env.example`). The store must be on **HTTPS**; the connector refuses plain http for non-local hosts.

**Option B - authorize flow (no secrets pasted anywhere).**
```bash
python3 -m wc_connector connect --store https://shop.example.com \
    --callback-url https://<public-https-host>/callback --open-browser
```
The merchant approves in their browser; WooCommerce then POSTs a new **read-only** key pair to the callback URL (server-to-server, so it must be publicly reachable over HTTPS - for local dev use a tunnel forwarding to port 8765). The callback is bound to a random `user_id` nonce (forged callbacks are rejected), the granted permission must equal what was requested, and keys are saved to `~/.wc_connector/credentials.json` with mode `0600`. After that, only `WC_BASE_URL` is needed.

Verify: `python3 -m wc_connector check`, then `python3 -m wc_connector call list_orders --args '{"per_page":3}'`.

## Registering with an agent platform

MCP client configuration:
```json
{ "mcpServers": { "woocommerce": {
    "command": "python3", "args": ["-m", "wc_connector", "serve"],
    "cwd": "/path/to/woocommerce-agent-connector",
    "env": { "WC_BASE_URL": "https://shop.example.com",
             "WC_CONSUMER_KEY": "ck_...", "WC_CONSUMER_SECRET": "cs_..." } } } }
```
The tool specification (names, descriptions, JSON Schemas, read-only annotations) is in [`docs/mcp_tools.json`](docs/mcp_tools.json) (regenerate with `make spec`). I don't know Agent Studio's native connector manifest, so MCP is the "equivalent"; the schemas map 1:1 onto function-calling definitions if a different format is needed.

## Tools

`list_orders` `search_orders` `get_order` `list_products` `search_products` `get_product` `list_variations` `get_inventory` `list_low_stock_products` - details, limits and agent guidance in [`docs/AGENT_CAPABILITIES.md`](docs/AGENT_CAPABILITIES.md).

## Design decisions

- **Read-only by construction**: the HTTP layer rejects anything but GET; tools carry `readOnlyHint`; docs tell the merchant to issue Read keys.
- **Rate limits, two layers**: a client-side token bucket (`WC_RATE_LIMIT_RPS`) plus retry on 429/502/503/504/network errors honouring `Retry-After` (seconds or HTTP-date), else exponential backoff with jitter; capped at `WC_MAX_RETRIES`. Auth/validation errors are never retried. When retries are exhausted the agent gets `retryable: true` and `retry_after_seconds`.
- **Compact projections** instead of raw 5-10 KB WooCommerce payloads: cheaper tokens, smaller PII surface.
- **PII masked by default**; free-text fields flagged as untrusted (prompt-injection hygiene).
- **Safe credential handling**: secrets never logged (`Config.__repr__` hides them), never in URLs by default, redirects refused so credentials can't be forwarded to another host, 0600 credential file, https enforced.
- **Standard library only**: nothing to install in a locked-down deployment; the MCP layer is ~100 lines.

## Assumptions

- WooCommerce 3.5+ with the `wc/v3` REST API and pretty permalinks; amounts are strings in the store currency.
- One store per server process.
- The merchant (or I, when testing) can create a *Read* API key.

## Limitations (honest list)

1. **Not yet verified against a live WooCommerce store.** This was built and tested against the bundled mock, which reproduces the documented wc/v3 behaviour (auth, pagination headers, filters, error bodies, `/wc-auth`). Run the "Connecting a real store" steps once before relying on it; `search_orders` matching fields and variation-SKU lookup are the most likely places for version differences.
2. **Search is only as good as WooCommerce's `search`** parameter (varies with HPOS/plugins). No fuzzy matching or customer-centric search.
3. **Variation SKUs**: `get_inventory(sku=...)` resolves product-level SKUs; for a variation SKU, find the parent then `list_variations`.
4. **Low-stock is a bounded client-side scan** (WooCommerce has no server-side quantity filter) and covers parent products only.
5. **Authorize flow needs a public HTTPS callback**; WooCommerce calls it server-to-server. Keys are stored in a local file (not a secrets manager).
6. **No webhooks/caching**: every call hits the store, so a very busy agent can still stress a small shop (mitigated by throttling, not eliminated).
7. **No write actions** by design; no multi-tenant isolation inside one process.

## Long-term fix / what I'd build next

- Run as a hosted connector with per-merchant credentials in a secrets manager (KMS/Vault), OAuth-style token rotation, and per-tenant rate budgets.
- Ingest WooCommerce **webhooks** (`order.created/updated`, `product.updated`) into a small cache/index, so agents read from a fast, rate-limit-free store and search is fuzzy and customer-aware; keep live GET as fallback.
- Add audit logging of every tool call (who/what/when, no PII), a scoped write tool set behind human approval (e.g. "draft refund"), Razorpay payment reconciliation by `transaction_id`, and contract tests that run against a disposable real WooCommerce container in CI.

## Layout

```
wc_connector/   auth.py client.py config.py tools.py mcp_server.py ratelimit.py redact.py errors.py __main__.py
mock_wc/        offline fictional WooCommerce (all data invented)
tests/          29 end-to-end tests (auth flow, pagination, redaction, retries, MCP over stdio)
scripts/demo.py guided demo        docs/  capabilities, tool spec, demo output
```
No real customer data or credentials are included; the only keys are the mock's `ck_mock_key` / `cs_mock_secret`.
