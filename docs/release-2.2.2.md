# 2.2.2 release notes (proposed; not released)

- Report `stuck` when pending changes have not been pushed successfully for
  15 minutes, even if the transport loops remain alive.
- Persist the beginning of a hard pull-failure streak, show its duration in
  health output, and report `stuck` after 15 minutes. Clear it on recovery.
- Retry relay connection timeouts through a fixed fallback. A bounded wait
  without transfer progress moves the reachable peer there too, recovering
  when a relay is unreachable from one peer. Explicit relay pins take priority.

The v2 sync payload is unchanged. Ordinary transfers with older peers remain
compatible during the initial relay window; automatic fallback needs both peers
upgraded, or the same `CROC_RELAY` pin on both sides.

Versioning follows the existing release workflow: the next patch input is
`2.2.2`, after `v2.2.1`. There is no source version constant. This change does
not create a tag, run the release workflow, or update the package tap.
