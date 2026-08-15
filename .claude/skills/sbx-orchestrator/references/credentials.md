# Credentials: minting, revoking, ZDR

One mechanism: **OpenRouter**. A long-lived provisioning key on the host mints one disposable
runtime key per sandbox (`sbx-<run-id>`, `$50` default), which is revoked at teardown by hash.
Chosen over exe.dev's BYOK LLM integration purely on **portability** — a credential layer bound
to one provider's hostname stops being a transferable asset the moment the sandbox provider
changes, and the whole point of this system is that it moves.

One exception: `sbx run agent` runs **Claude Code** against exe.dev's key-free gateway
(`ANTHROPIC_BASE_URL=https://llm.int.exe.xyz`, `ANTHROPIC_API_KEY=implicit`). OpenRouter does not
serve the Anthropic Messages API cleanly, and that lane needs no key at all.

A manifest that declares `credential.provider: none` mints nothing at all — for a box that never
calls a model. `lib/credential.py` is the whole surface: `mint` / `spend` / `revoke` / `list`.

> **What models a sandbox runs is not sbx's business.** The roster, the per-model rates, the pi
> registry and the four blocks each entry needs belong to the repo being mounted. For
> sandbox-factory they are in its `/sssf` skill, at `references/models.md`. Read that when a gate
> fails on a model; read this when it fails on a key.

---

## Credential lifecycle

| | Provisioning key | Runtime key |
| --- | --- | --- |
| Lives in | `OPENROUTER_PROVISIONING_KEY` in host `.env` | `~/.local/state/sbx/runs/<id>.key` (600) → `app/.env` on the VM |
| Lifetime | long-lived; the only long-lived secret in the system | one sandbox |
| Can do | mint + revoke only — it **cannot do inference**, it returns `User not found` | inference only |
| Enters a sandbox | **never** | yes, that is the point |
| Killed by | manual rotation | `sbx lifecycle teardown`, or `sbx manage reap` as the backstop |

OpenRouter keys have **no native TTL**. If teardown never runs, the key outlives the sandbox
forever. Run `sbx manage reap` at the start of every session; the `sbx-` prefix is the only thing
separating managed keys from personal ones.

`manage doctor` checks that the provisioning key is a **management** key rather than an inference
one. Both are `sk-or-v1-…`, so "is it set" cannot catch the common paste error — doctor asks
OpenRouter whether the key can list keys, because the wrong one otherwise first fails in CREATE,
i.e. after a billable VM already exists.

---

## Zero data retention

| Param | Values | Effect |
| --- | --- | --- |
| `provider.zdr` | `true` / omitted | Route only to providers enforcing zero data retention |
| `provider.data_collection` | `allow` (default) / `deny` | `deny` restricts routing to providers that do not collect user data. **Independent of `zdr` — use both** |

**Enforcement is an ACCOUNT setting, not a per-request one.** Set the data policy once in the
OpenRouter dashboard (Settings → Privacy); it then applies to every request from every key,
including minted runtime keys, and covers Claude Code too. This matters because an agent runner may
not be able to send the per-request form at all — pi, for one, supports custom headers in its
`models.json` but no arbitrary request-body fields, so `provider: {...}` cannot be injected through
its config.

A repo's own health assertion can still send the per-request param on its gate pings to prove ZDR
routing resolves before real work runs. That is the repo's call, in its `health:` block, not
something sbx asserts on its behalf.
