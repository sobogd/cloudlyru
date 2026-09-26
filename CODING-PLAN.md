# План (plan of attack)

Максимум &lt;= N пунктов в работах (worktree, push main, ci)

## 1. П1 (P1) — `retry()`: мост недоступен → no blind second prompt
- Root: if the bridge is unavailable we don't know if busy; blindly re-sending → possible second run.
- Fix: on `AgentApiException` in `retry` → `state.withError(e.message)`, return; follow only on clean state.

## 2. П2 (P2) — bridge dedupe: `is_duplicate(text, message_id)` queue vs current
- Root: `is_duplicate` doesn't consider runs in the rewrite; if `id` in queue, dup means we push to the queue again.
- Fix: if `message_id` in the queue, `is_duplicate` should return `true` (already queued) before comparison; `current_id` is enough.

## 3. П3 (P3) — `replacePath` zone 32k line limit on long prompts
- Root: Mac text files with long prompts are truncated at 32 000 lines; UTF-8 decoding breaks UTF-16 surrogates in a macOS bundle.
- Fix: remove the 32k line limit (no limit); decode directly in native (no conversion to Array buffer).

## 4. П4 (P4) — doc update: besides the `AgentApiException` pitfall, the bridge has only 2 counts, not 4
- Root: `AgentApiException` in two places (prompt & events) is quoted as one, but it's 2: 409 busy at prompt and idle at events; removing (support doc) the 409 means only 2 counts to explain.
- Fix: update `AGENTS.md` references to "2 counts"=2; doc for `AgentApiException` "busy" `code === 'busy' | 409`.

## 5. П5 (P5) — `AgentController.retry()` call `_followRunning` after abort (session busy=false)
- Root: user aborts a session; then retry → bridge marks busy to true and the follow is lost (busy state not ready post-abort, busy resetting at that point is async: the `_prompt()` in the bridge hasn't updated yet).
- Fix: after `state.session.busy == false`; or check `session.busy` after calling refresh.
