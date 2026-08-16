# Repository instructions

## Project Zomboid development client

Use the managed `pzmod` workflow for every interactive in-game test of a
feature worktree.

1. Make sure all Project Zomboid client and server processes are stopped before
   activating, deactivating, or smoke-testing a worktree. Request a graceful
   client close; do not force-kill a running game because it may be saving.
2. Activate the intended feature worktree:

   ```powershell
   pzmod dev activate --repo <repo> --source <feature-worktree> --json
   ```

3. Verify the activation before launching:

   ```powershell
   pzmod dev status --repo <repo> --json
   ```

   Require `active: true`, `consistent: true`, the intended feature branch,
   and the expected HEAD OID. The active target must be that worktree's
   `Contents/mods/myspatialrefuge` directory.
4. Launch the client only through `pzmod`:

   ```powershell
   pzmod dev launch --debug --detach --repo <feature-worktree> --json
   ```

   Do not launch this test through Steam, a desktop shortcut, or the raw game
   executable. The process command line must contain
   `-modfolders mods,workshop,steam`. This puts the development junction in
   `Zomboid/mods` before Workshop copies with the same `id=myspatialrefuge`.
   The wrong order can mix current Lua with stale Workshop textures and other
   resources even when the startup marker reports the current mod version.
5. Verify the running process and `C:\Users\<user>\Zomboid\console.txt` after
   launch. The process must contain the required `-modfolders` order, and the
   log must contain both `loading myspatialrefuge` and the expected
   `[MSR] My Spatial Refuge v<mod-version>` marker.
6. If the active branch HEAD is rewritten with `commit --amend`, rebase, or a
   reset, close the client and refresh the managed state with `pzmod dev
   deactivate` followed by `pzmod dev activate`; then verify the new OID before
   relaunching.

For a dedicated-server startup check, stop the client and use only:

```powershell
pzmod dev smoke --repo <repo> --source <feature-worktree> --version <mod-version> --json
```

`--version` is the mod version from the `[MSR]` startup marker, not a Project
Zomboid build or layout such as `42.15` or `42.20`.
