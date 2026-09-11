# UpdateAllExternals

Updates each patched external branch, pushes it, and commits the resulting
submodule gitlink in the parent repository.

When a rebase makes an ordinary push non-fast-forward, the updater only
continues if `git range-diff` proves that every patch is unchanged. It preserves
the previous remote tip as the next `tag_rebase-NNN` tag, then pushes with an
exact `--force-with-lease`. Concurrent remote changes and ambiguous patch
changes stop the update.

An interrupted run can be resumed. If the child branch was already pushed but
the parent gitlink was not committed, rerunning creates the missing
`chore(externals/<name>): update it` commit. Other parent working-tree changes
are not included because commits are restricted to the individual submodule.

Run the local integration test with:

```sh
lake build && bash tests/integration.sh
```
