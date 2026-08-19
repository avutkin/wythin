# Wythin — session rules

Multiple Claude sessions work this repo in parallel. Every rule below is a
fossil of a real incident where sessions regressed each other's work.

## Worktrees: one per session, never shared

- Never work in `/Users/alexutkin/Code/Wythin` directly — other sessions
  switch branches and commit there. Create your own worktree:
  `git worktree add .claude/worktrees/<topic> -b <branch> origin/main`
- At session start (and whenever a build breaks on a file you never touched):
  `git log --oneline -1 && git status --porcelain`. If another session's WIP
  is in your worktree, do NOT stash/revert/fix it — branch a fresh worktree
  off the committed HEAD and continue there.
- `.claude/worktrees/release` belongs to `tools/ship.sh`. Never edit,
  commit, or build manually in it; it is hard-reset to origin/main on every
  ship.

## Shipping: tools/ship.sh is the only path to devices

- **Never run `devicectl device install` or `xcodebuild -exportArchive` by
  hand.** Installs from feature branches erased shipped features from Alex's
  phone more than once (a feature is not "delivered" until it is on
  origin/main — anyone else's install will otherwise remove it).
- `tools/ship.sh status` — audit local main vs origin/main, dirty worktrees,
  latest TestFlight builds, iPhone reachability. Run it when anything about
  versions looks confusing.
- `tools/ship.sh phone` — sync release worktree to origin/main, full test
  suite, build, install + launch on Alex's iPhone.
- `tools/ship.sh testflight` — same sync + tests, then: query ASC for the
  real build high-water mark (the repo's CURRENT_PROJECT_VERSION lies),
  bump, push the bump, archive, upload with the K2R557DK2R API key, wait for
  processing, set export compliance.
- Therefore: to get your feature onto the phone or TestFlight, **merge it to
  main, push, then run ship.sh** — never build around the script.

## Facts the hard way

- Full WythinTests suite green is the bar for merging to main. Treat iOS
  test failures as real.
- `xcodebuild` from a relative path builds whatever checkout your cwd
  happens to be in — always pass absolute `-project` paths.
- `altool --generate-jwt` prints the token to stderr. The working ASC key is
  `K2R557DK2R`; `F536X67SF4` is dead.
- Internal TestFlight testers cannot be added via API (409) — ASC UI only.
  The `External Testers` group has ~11 real people; never assign builds to
  it without Alex's explicit OK.
- Adding a Swift file requires a manual `project.pbxproj` edit; the
  file-reference tokens are hand-assigned — scan for free ones.
