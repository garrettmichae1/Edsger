# Agent restore points and project conversation history

The IDE agent panel now has three quiet actions: restore points (backward arrow),
conversation history (clock), and new chat (compose). New chat clears model context
and the input, while preserving prior conversations. Opening a conversation never
restores or edits files; rollback is a separate, explicitly confirmed action.

## Project scope

History and checkpoints belong to the current language workspace and project path.
Nested files and empty directories are included. A named project restore affects
that folder and its descendants, not sibling projects. At the workspace root, the
agent already has access to the entire language workspace; its restore point also
covers that entire tree, including project folders. The restore sheet and
confirmation explain that scope and that edits made after the snapshot are replaced.

## Capture and restoration

- Capture immediately before the first write, replacement, directory creation,
  deletion, or program run in a request. Runs are included because user code can
  create or modify files. Read-only conversations incur no project snapshot cost.
- The snapshot must be atomically committed before the tool executes. Capture failures
  fail the request before its first mutation. Editor/disk discrepancies also fail
  capture rather than silently backing up different code than the user sees.
- Preserve exact file bytes (including binary artifacts and mixed line endings),
  relative paths, and directory structure. Symlinks, special files, unsafe paths,
  and invalid checkpoint structures are rejected. File permissions/extended
  attributes are not versioned by this content-based snapshot.
- A restore first commits a recovery checkpoint of the current project, then stages
  the restored tree beside the workspace. A persisted journal precedes moving the
  old tree aside and installing the staged tree. Failed installs move the original
  back. Startup recovers a missing destination from the original or finishes cleanup
  of an installed restore. Unresolved recovery blocks further agent mutations.
- Refresh the workspace from disk, restore the prior selection when it exists,
  invalidate stale error highlights/output, archive the conversation, and start a
  fresh chat. Prior tool context should not claim rolled-back changes remain applied.
- The recovery entry appears as **Undo rollback**, survives app restart, and can
  restore the later files. Programs must stop before snapshotting/restoring. Stopping
  an agent that owns a program run also requests that program stop; restore remains
  disabled until its runtime completion arrives.

Each snapshot is limited to 32 MB of file bytes and 5,000 entries. Keep the latest
10 restore points per project; no-op tasks drop their temporary checkpoint. Stopped
tasks with a running program retain their checkpoint because later writes may still
arrive. Capture/restore currently serialize with workspace operations on the main
actor; measure unusually large projects before introducing asynchronous staging.

## Storage and migration

Metadata lives in a hidden sibling of each language workspace, outside the tree
being restored. Thus a root rollback cannot overwrite its backups or history.
Snapshots are JSON with byte data in atomically committed checkpoint folders;
list rows read a separate small metadata file rather than loading source payloads. Saved
conversations retain up to 100 messages each and normally 20 conversations per
project. Pinned conversations and the active chat are protected from pruning,
even when that exceeds the limit. Pins sort first and persist across restart.
Both Chat and Agent history offer a visible options menu, long-press menu, and
swipes for Pin/Unpin and Delete. Deletion asks for confirmation. Deleting an agent
conversation does not delete project files or restore points; deleting the active
conversation clears its transcript/draft and leaves a fresh chat. Pin/delete
storage failures leave the agent history unchanged and display a notice.
The active chat selection persists too, including a fresh empty chat
after rollback, so restarting does not revive stale tool context. Existing single-conversation files migrate when that project is opened;
the old files remain untouched. Corrupt history is not overwritten, and new/open
conversation actions are disabled when the archive cannot be read. Saving errors
produce a notice and keep conversations in memory.

## Validation

`bash scripts/test-agent-history.sh` compiles the production store, workspace,
and agent session under Swift 6 complete concurrency checking. Tests exercise:

- Persistent restore/restart, nested helpers, empty folders, Unicode filenames,
  binary data, line endings, additions/deletions, selection, and sibling isolation.
- Recovery copy/undo rollback, a simulated installation failure, and an interrupted
  directory swap; unsafe paths, symlinks, malformed payloads, and storage failure.
- New chat/history retention, scoped history, fresh model context after restore,
  corrupt archive preservation, root metadata isolation, and editor/disk mismatch.
- Backward-compatible pin decoding, ordering, restart, unpin, protected retention,
  active/inactive/last-chat deletion, stale-row rejection, project and restore-point
  preservation, and failed pin/delete storage writes.

Linux stubs replace iOS Python/JavaScript/Lua and the default inference/settings
boundaries. Actual snapshot/filesystem/session operations run against temporary
directories; the PicoC bridge is linked. Asynchronous agent inference/dispatch is
not executed by that host harness. Added iOS tests use the scripted agent client to
verify automatic capture before actual tool writes and first-write rejection on
backup failure. Those iOS tests have not run here: Xcode/SDK/simulator are unavailable.

Before release, build/test in Xcode. On a device, request a multi-file change,
close/reopen the app, restore it, undo the rollback, and check history/new chat.
Also stop a request during a program run, test nested helper selection, and resize
the panel with each sheet and keyboard. Verify storage limits and long history.
