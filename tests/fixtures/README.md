# live-smoke sandbox fixture

A tiny, committed seed tree for the opt-in live harness (`tests/live-smoke.sh`).
`make_sandbox` copies this directory into a disposable git-initialized temp tree so a
real read-only agent run has something to look at while the harness proves the agent
left the tree byte-identical. Nothing here is imported or executed by the plugin.
