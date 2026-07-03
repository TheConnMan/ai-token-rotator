# claude-token-rotator

Automatically rotates the active Claude Code OAuth account across N logged-in Max
accounts by hot-swapping `~/.claude/.credentials.json` on a systemd timer, so
unattended background work keeps running against whichever account has budget.

See `SPEC.md` for the full behavior and acceptance criteria. Implementation is
built to that spec (test-first). This README is expanded by the build.
