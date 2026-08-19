# Herdr Crash Course

A self-paced course for your setup: herdr 0.7.5, Ghostty, the Wythin iOS repo at
`~/Code/Wythin`, and your friend's custom keymap.

**Time:** ~110 minutes. **Prerequisite:** none — you are already inside herdr.

Every drill ends with a verification command and the expected output. Nothing here
depends on anyone watching you. If a check fails, the drill tells you the most
likely cause.

Keep this file open in a second pane while you work. Module 2 teaches you how.

---

## How to use this document

| Marker | Meaning |
|---|---|
| **Drill** | Do it. Verify it. Don't move on until it passes. |
| **Quiz** | Answer from memory, then check. Answers at each module's end. |
| **Lab** | Longer, on the real repo. Produces real commits. |
| **Trap** | Something that will bite you. Read even when skimming. |

Notation: `prefix` means **`ctrl+b`**. Press and release it, *then* press the
action key. It is not a held modifier. `prefix+shift+j` = press `ctrl+b`, release,
then press `shift+j`.

---

## Module 0 — Orientation and escape hatches (5 min)

Before learning to move, learn how to not get stuck.

### The four things that always work

| Key | Does |
|---|---|
| `prefix` then `?` | Help overlay — **the authoritative keymap for your config** |
| `esc` | Leaves prefix mode without doing anything |
| `prefix` then `q` | **Detach.** Session keeps running, you get your shell back |
| `prefix` then `b` | Toggle the sidebar |

**Detach is not quit.** `prefix+q` drops you back to Ghostty; everything keeps
running. Type `herdr` to come back exactly where you were. This is the single most
reassuring fact about herdr: you cannot lose your work by leaving.

To actually stop everything: `herdr server stop` from outside.

> **Trap — the help overlay outranks this document.** Your friend's config
> overrides some defaults, and I derived the merged keymap by reading
> `~/.config/herdr/config.toml` against `herdr --default-config`. Where this
> document and `prefix+?` disagree, **the overlay is right.** You will use it to
> settle a real ambiguity in Module 3.

### Drill 0.1 — find yourself

Run in this pane:

```sh
herdr pane current
```

Expect a JSON blob containing `"pane_id"`, `"tab_id"`, `"workspace_id"`. Those
three IDs are your address. Everything in Module 1 is about changing one of them.

Make it convenient — you'll run it constantly. Append this function to `~/.zshrc`
(paste the whole block; the quoting matters):

```sh
cat >> ~/.zshrc <<'EOF'

hw() {
  herdr pane current | python3 -c 'import json,sys
p = json.load(sys.stdin)["result"]["pane"]
print("pane=%s tab=%s ws=%s agent=%s cwd=%s" % (
    p["pane_id"], p["tab_id"], p["workspace_id"], p.get("agent") or "-", p["cwd"]))'
}
EOF
source ~/.zshrc
hw
```

Expect one line like:

```
pane=w2:p1 tab=w2:t1 ws=w2 agent=claude cwd=/Users/alexutkin
```

`hw` reports the pane **you run it in**, so it always answers "where am I" honestly
— run it in the pane you just navigated to.

### Drill 0.2 — open and dismiss the help overlay

Press `prefix` then `?`. Read it. Dismiss with `esc`.

You just saw your real keymap. Don't memorize it — Module 1 gives you the pattern
that makes memorizing unnecessary.

---

## Module 1 — The three-tier mental model (12 min)

This is the whole course. Everything after it is practice.

### The hierarchy

```
Workspace              "a project" — has its own cwd, its own identity
 └── Tab               "a task within it"
      └── Pane         "a terminal"
           └── Agent   a pane that has Claude/Codex running in it
```

A **workspace** is the unit of *context*. Your session has three right now:
"Repo Relocation to Proper Folder", "Herdr Workout", "smart clothing". A **tab**
splits a workspace into tasks. A **pane** is one shell. An **agent** is a pane
that happens to be running a coding agent.

### The grammar

Your friend's config encodes one consistent rule. Learn the rule, not the keys:

```
  prefix + h j k l          → move between PANES        (within a tab)
  prefix + shift + h  l     → move between TABS         (within a workspace)
  prefix + shift + j  k     → move between WORKSPACES   (the top level)
  prefix + alt   + j  k     → move between AGENTS       (across everything)

  prefix + 1..9             → jump to AGENT n
  prefix + alt   + 1..9     → jump to TAB n
  prefix + shift + 1..9     → jump to WORKSPACE n
```

Three rules:

1. **Bare = the thing in front of you** (panes, and agents by number).
2. **Shift = go up a level** (tabs and workspaces).
3. **Alt = the agent dimension** (walking agents, and tabs by number).

And `h/l` vs `j/k` is spatial: **horizontal keys move sideways within a level,
vertical keys move up and down a list.** Panes get all four because panes are
genuinely 2-D on screen. Tabs are a horizontal strip, so `h/l`. Workspaces are a
vertical sidebar list, so `j/k`.

> **Trap — the numbers are not symmetrical with the letters.** Letter navigation
> puts tabs on `shift` and agents on `alt`. Number navigation puts *workspaces* on
> `shift` and *tabs* on `alt`. This is the one genuinely arbitrary thing in your
> keymap and it is where you will make mistakes for the first hour. In particular:
> **`prefix+2` is not "go to tab 2"** — it focuses *agent 2*. Tab 2 is
> `prefix+alt+2`.

### Why "agent" is a tier at all

This is what makes herdr different from tmux. An agent is **not a location — it's
a state**. Your sidebar is sorted by priority (`agent_panel_sort = "priority"`),
so agents that need you float up.

`prefix+alt+j` doesn't mean "go right." It means **"take me to the next agent that
matters, wherever it lives."** It crosses tab and workspace boundaries freely.
When you run four features in parallel in Module 5, this is the key you'll live
on: you stop navigating *places* and start servicing *whoever is asking*.

### Quiz 1

Answer before reading on.

1. You want tab 3 in your current workspace. What do you press?
2. You press `prefix+3`. What actually happens?
3. You want to move from the left pane to the right pane in your current tab.
4. Two agents are working; one is waiting on you in another workspace. What is the
   fastest key to reach it?
5. What's the difference between `prefix+q` and `herdr server stop`?

<details>
<summary>Answers</summary>

1. `prefix+alt+3` — tabs by number are on **alt**.
2. It focuses **agent 3**, not tab 3. Most common early mistake.
3. `prefix+l` — bare `h/j/k/l` is pane focus.
4. `prefix+alt+j` (or `k`) — agent-walk crosses workspaces. You do not need to know
   where it is.
5. `prefix+q` detaches; everything keeps running and `herdr` reattaches you.
   `herdr server stop` actually terminates the session.
</details>

---

## Module 2 — Navigation drills (20 min)

Do these in order. Verify each.

### Drill 2.1 — split a pane and get this document open

```
prefix then v      (split vertical)
```

You now have two panes. In the new one:

```sh
cd ~/Code/Wythin && less docs/herdr-crash-course.md
```

Leave it there for the rest of the course. Move between the two with `prefix+h`
and `prefix+l`.

**Verify:** `herdr pane list` shows two panes sharing your `tab_id`.

### Drill 2.2 — pane focus, all four directions

Split again with `prefix+minus` (horizontal). You should have three panes.

Walk them: `prefix+h`, `prefix+j`, `prefix+k`, `prefix+l`. Then cycle with
`prefix+tab`.

**Verify:** run `hw` in each pane; the `pane_id` changes, `tab_id` stays the same.

**If h/j/k/l does nothing:** you're probably not in prefix mode. Press `ctrl+b`,
release it, *then* the letter.

### Drill 2.3 — zoom

Focus any pane, press `prefix+z`. It fills the tab. Press `prefix+z` again.

**Verify:** `herdr pane list` — the zoomed pane reports `"zoomed": true`.

Zoom is how you read a long build log without closing your layout. Use it
constantly.

### Drill 2.4 — cross workspaces

You have three workspaces. Go to workspace 1:

```
prefix then shift+1
```

Then walk with `prefix+shift+j` / `prefix+shift+k`.

**Verify:** `hw` in a pane there — it should report `ws=w1`.

**If you landed somewhere unexpected:** you may have pressed `prefix+1`, which
focuses agent 1. Workspaces by number need **shift**.

### Drill 2.5 — the picker (your safety net)

```
prefix then w
```

A searchable workspace picker. Also try `prefix+g` (goto).

**This is the key that makes memorization optional.** When you can't recall a
chord, `prefix+w` gets you anywhere by typing a name. Every expert user still
uses it.

### Drill 2.6 — agent-walk

With a Claude agent running somewhere, press `prefix+alt+j` a few times.

**Verify:** `hw` — you'll see the `workspace_id` change without you having chosen
a workspace. That's the point.

### Quiz 2

1. You're in workspace 3 and want workspace 1. Two different ways?
2. You split a pane by accident. Which key closes just that pane?
3. You want to read a 400-line build log in a small pane. Best key?
4. `prefix+w` vs `prefix+shift+1..9` — when is each better?

<details>
<summary>Answers</summary>

1. `prefix+shift+1`, or `prefix+shift+k` twice, or `prefix+w` and type the name.
2. `prefix+x` (close_pane). Note `prefix+shift+x` is something much bigger — see
   Module 3.
3. `prefix+z` to zoom, read, `prefix+z` to restore.
4. Numbers are faster when you know the position and there are few workspaces. The
   picker wins when there are many, when you know the name but not the number, or
   when you're unsure — which early on is most of the time.
</details>

---

## Module 3 — Creating, renaming, closing (20 min)

Navigation is safe. Creation and destruction are where you need to be precise.

### Creating

| Key | Creates |
|---|---|
| `prefix+v` | pane, split vertically |
| `prefix+minus` | pane, split horizontally |
| `prefix+c` | new tab (prompts for a name) |
| `prefix+shift+n` | new workspace |
| `prefix+shift+g` | new **git worktree** workspace (Module 4) |

### Renaming — do this more than feels necessary

| Key | Renames |
|---|---|
| `prefix+shift+p` | pane |
| `prefix+shift+t` | tab |
| `prefix+shift+w` | workspace |

Your config sets `show_agent_labels_on_pane_borders = true`, so pane names are
visible on the borders at all times. With four parallel agents in Module 5, the
difference between "zsh / zsh / zsh / zsh" and "build / test / claude-a / claude-b"
is the difference between a workspace you can read and one you can't.

**Drill 3.1:** rename this workspace to `herdr-course` with `prefix+shift+w`.
Rename your document pane to `notes` with `prefix+shift+p`.

**Verify:** `herdr workspace list` shows the new name.

### Closing — and the collision your friend left you

Here is where your config has a genuine problem.

| Action | Herdr default | Your friend's config |
|---|---|---|
| `close_pane` | `prefix+x` | unchanged |
| `close_tab` | `prefix+shift+x` | *not overridden* → still `prefix+shift+x` |
| `close_workspace` | `prefix+shift+d` | **changed to `prefix+shift+x`** |
| `remove_worktree` | unset | **set to `prefix+shift+d`** |

Your friend moved `close_workspace` onto `prefix+shift+x` — which is already
`close_tab`'s default. **Two actions, one chord.** Their `prefix+shift+d` for
`remove_worktree` is fine, because moving `close_workspace` freed it.

I am not going to guess which one wins. You're going to find out, because
"how do I know what a key really does" is the most useful skill in this course.

### Drill 3.2 — settle the collision

1. Press `prefix` then `?`.
2. Find the entries for `prefix+shift+x`. Note what the overlay says.
3. Dismiss with `esc`.

Whatever the overlay reports is the truth for your build.

### Drill 3.3 — fix it

Regardless of who wins, one action is currently unreachable or ambiguous — and
it's the one that destroys a whole workspace. Give them separate keys.

Edit `~/.config/herdr/config.toml` and add an explicit `close_tab` line next to
the other key settings:

```toml
[keys]
  close_tab = "prefix+alt+x"       # was colliding with close_workspace
  close_workspace = "prefix+shift+x"
```

Now: `prefix+x` closes a pane, `prefix+alt+x` closes a tab, `prefix+shift+x`
closes a workspace. Escalating scope, escalating modifier.

Apply it **without restarting**:

```sh
herdr server reload-config
```

**Verify:** press `prefix+?` again. `prefix+alt+x` should now appear as
`close_tab`, and `prefix+shift+x` should be `close_workspace` alone.

> If `reload-config` reports an error, you have a TOML syntax problem. The file is
> parsed as a whole — a stray quote anywhere kills the reload. Your previous
> config stays active until a valid one loads, so you can't lock yourself out.

### Drill 3.4 — practice destruction safely

Create a throwaway workspace with `prefix+shift+n`, name it `scratch`. Add a tab
with `prefix+c`. Split a pane with `prefix+v`.

Now dismantle it in order: `prefix+x` (pane), `prefix+alt+x` (tab),
`prefix+shift+x` (workspace).

`confirm_close` defaults to `true`, so you'll get a confirmation on the workspace.

**Verify:** `herdr workspace list` no longer shows `scratch`.

### Drill 3.5 — the lazygit popup

Your friend bound `prefix+alt+g` to lazygit in a popup at 85%.

Go to a pane inside `~/Code/Wythin` and press `prefix+alt+g`. Quit lazygit with
`q`; the popup vanishes and your layout is untouched.

Popups are session-modal — they don't disturb your panes. This is the best way to
stage and commit during Modules 4 and 5.

---

## Module 4 — Worktrees, and one feature solo (25 min)

### Theory: why worktrees, for you specifically

A git worktree is **a second working directory for the same repository**, on a
different branch, sharing one `.git`. Not a clone — no duplicated history, no
second remote.

You need them for a reason documented in your own notes: **more than one Claude
session operates on this repo at once.** On 2026-07-28 a parallel session's commit
swallowed an uncommitted `git mv` from another run, and the next commit landed on
the wrong branch. That's not a git quirk; it's the inevitable result of two agents
sharing one working tree. `git checkout` from one session silently captures the
other's uncommitted changes and nothing warns you.

Worktrees fix that: one working directory per line of work, no shared index.

### Your current state

The repo moved to `~/Code/Wythin` on 2026-07-30 (it used to be `$HOME` itself).
The worktrees survived and were re-pointed, but they're split across two
directories:

| Path | Branch | Ahead of main | Dirty |
|---|---|---|---|
| `~/.claude/worktrees/anchor-cadence-fix` | `fix/anchor-cadence` | 19 | clean |
| `~/.claude/worktrees/block-a-metrics` | `feat/block-a-full-fidelity-metrics` | 9 | clean |
| `~/.claude/worktrees/practices-hub` | `worktree-practices-hub` | **0** | 10 files |
| `~/.worktrees/activities` | `feat/day-potential` | 11 | clean |
| `~/.worktrees/activity-end-time` | `feat/activity-end-time` | 3 | clean |
| `~/.worktrees/ble-background` | `feature/ble-background` | **0** | clean |
| `~/.worktrees/live-date-nav` | `feature/live-date-navigation` | **0** | clean |

Three of those are dead: zero commits ahead of `main` means they contain nothing
`main` doesn't already have.

> **One good thing the relocation did for you:** worktrees now live *outside* the
> repo root. When the repo was `$HOME`, `~/.worktrees/` and `~/.claude/worktrees/`
> sat inside it and had to be gitignored — and `wythin-track/` wasn't, so it
> polluted `git status` permanently. That whole class of problem is now gone.
> Keep it that way: **never put a worktree inside the repo.**

### Lab 4.1 — clean up

Remove the three dead worktrees. `ble-background` and `live-date-nav` are clean
and 0 ahead. `practices-hub` has 10 uncommitted files but is also 0 ahead — you've
confirmed that work is junk, so it goes too, and that needs `--force` because git
refuses to discard uncommitted changes silently.

```sh
cd ~/Code/Wythin
git worktree remove ~/.worktrees/ble-background
git worktree remove ~/.worktrees/live-date-nav
git worktree remove --force ~/.claude/worktrees/practices-hub
```

Then delete the now-unreferenced branches:

```sh
git branch -d feature/ble-background feature/live-date-navigation
git branch -D worktree-practices-hub     # -D: never merged, discard it
```

**Verify:**

```sh
git worktree list
```

Expect 5 entries: the main checkout plus `anchor-cadence-fix`, `block-a-metrics`,
`activities`, `activity-end-time`.

> `git branch -d` refuses if the branch isn't merged — that's a safety net, not an
> obstacle. `-D` overrides it. Reach for `-D` only when you've confirmed the work
> is disposable, as you have here.

### Lab 4.2 — one convention

You have two worktree directories for no reason. Standardize on `~/.worktrees/`
and tell herdr about it, so `prefix+shift+g` creates them in the right place.

Move the two stragglers — use `git worktree move`, never `mv`, because git records
the path internally:

```sh
cd ~/Code/Wythin
git worktree move ~/.claude/worktrees/anchor-cadence-fix ~/.worktrees/anchor-cadence
git worktree move ~/.claude/worktrees/block-a-metrics    ~/.worktrees/block-a-metrics
```

Add to `~/.config/herdr/config.toml`:

```toml
[worktrees]
directory = "~/.worktrees"
```

Then `herdr server reload-config`.

**Verify:** `git worktree list` shows every linked worktree under `~/.worktrees/`,
and `ls ~/.claude/worktrees` is empty.

> **Why `git worktree move` and not `mv`:** git stores each worktree's path in
> `.git/worktrees/<name>/gitdir`, and the worktree stores a pointer back. A plain
> `mv` breaks both halves and the worktree goes stale. If you ever do this by
> accident, `git worktree repair <new-path>` fixes the link.
>
> **Expect `~/.claude/worktrees/` to reappear.** That directory is Claude Code's
> own worktree isolation, not yours — agents run with `isolation: "worktree"` will
> keep creating them there. That's fine; they're ephemeral and self-cleaning. The
> convention you're setting is for **worktrees you create by hand or with
> `prefix+shift+g`**. Don't fight the tool over its scratch space.

### Trap 4.3 — your worktree keybindings are currently dead

Your friend bound three worktree actions:

| Key | Action |
|---|---|
| `prefix+shift+g` | new worktree |
| `prefix+shift+o` | open existing worktree |
| `prefix+shift+d` | remove worktree |

**None of them work right now.** All three of your workspaces have their identity
cwd set to `/Users/alexutkin`, and since the relocation that directory is no longer
a git repository. Herdr's worktree actions require the workspace to be *inside* a
git work tree. Confirm it:

```sh
herdr worktree list
```

Expect: `{"error":{"code":"not_git_worktree", ...}}`

**Fix:** worktree keys operate on the workspace's directory, so you need a
workspace rooted in the repo. Create one:

```
prefix+shift+n      → name it "wythin"
```

then in its first pane:

```sh
cd ~/Code/Wythin
```

**Verify:** from a pane in that workspace, `herdr worktree list` now returns JSON
with a `worktrees` array instead of an error.

This is the single most valuable thing in this module. Half of your custom keymap
was inert and nothing told you.

### Lab 4.4 — one small feature, end to end

Now the actual workflow, once, slowly.

**1. Create the worktree.** From your `wythin` workspace, press `prefix+shift+g`.
Name the branch `feat/settings-os-row`. Herdr creates the worktree *and* opens
a workspace pointed at it.

Equivalent by hand, if you prefer to see it:

```sh
git -C ~/Code/Wythin worktree add ~/.worktrees/settings-os -b feat/settings-os-row main
```

**2. Confirm where you are.**

```sh
hw
pwd            # expect ~/.worktrees/settings-os
git status -sb # expect ## feat/settings-os-row
```

**3. Make the change.** Open `ios/Wythin/UI/Settings/SettingsView.swift` and find
`Section("ABOUT")` (around line 262). It already has **Version** and **Device**
rows. Add a third for the OS version, immediately after the `Device` row's
closing brace:

```swift
HStack {
    Text("iOS")
        .font(Theme.monoBody)
        .foregroundStyle(Theme.text)
    Spacer()
    Text(UIDevice.current.systemVersion)
        .font(Theme.monoLabel)
        .foregroundStyle(Theme.dim)
}
```

Note it copies the existing rows exactly — `Theme.monoBody`/`Theme.text` for the
label, `Theme.monoLabel`/`Theme.dim` for the value. **Matching the surrounding
idiom is the job**, not writing the SwiftUI you'd write from scratch. This app has
a design system (`ios/Wythin/UI/Design/Theme.swift`); stock `.foregroundStyle(.secondary)`
would look wrong next to it.

No new file, so `project.pbxproj` is untouched. That's deliberate — Module 5 is
where that gets interesting.

**4. Build it.** Note the absolute path and the isolated derived data:

```sh
cd ~/.worktrees/settings-os
xcodebuild -project /Users/alexutkin/.worktrees/settings-os/ios/Wythin.xcodeproj \
           -scheme Wythin \
           -destination 'generic/platform=iOS Simulator' \
           -derivedDataPath /tmp/dd-settings-os \
           build
```

> **Trap — relative `-project` paths.** Passing `-project ios/Wythin.xcodeproj`
> resolves against whatever the shell's cwd happens to be, which drifts. You can
> build a *different worktree's* project and watch tests pass for code you didn't
> change. Always pass the absolute path. This is in your notes because it has
> already happened.

**5. Commit** — `prefix+alt+g` for the lazygit popup, or plain `git commit`.

**6. Merge and clean up.**

```sh
cd ~/Code/Wythin
git checkout main && git merge feat/settings-os-row
git worktree remove ~/.worktrees/settings-os
git branch -d feat/settings-os-row
```

**Verify:** `git worktree list` is back to 5 entries and `git log --oneline -1 main`
shows your commit.

That's the complete loop: **create → work → build isolated → commit → merge →
remove.** Module 5 runs two of these at once.

---

## Module 5 — Two features in parallel (28 min)

### The three things that break when you parallelize iOS work

1. **`project.pbxproj` conflicts.** Any new Swift file edits this one file in four
   places. Two branches adding files always collide here.
2. **DerivedData contention.** Two `xcodebuild` runs sharing one derived data
   directory corrupt each other's incremental state.
3. **Simulator contention.** One booted simulator, two test runs — they fight.

You have felt #1 already. Your last commit was
`fix(build): commit PracticeImpactGauge, whose project reference I committed`, and
there's a `project.pbxproj.bak-gauge` still sitting in your tree. This module is
the fix for a wound you actually have.

### Lab 5.1 — set up two worktrees

From your `wythin` workspace, `prefix+shift+g` twice:

- branch `lab/relative-date-text` → `~/.worktrees/lab-a`
- branch `lab/metric-badge` → `~/.worktrees/lab-b`

**Verify:** `git worktree list` shows both, and you have two new herdr workspaces.

Rename them (`prefix+shift+w`) to `lab-a` and `lab-b`. With parallel work, unnamed
workspaces become unusable within minutes.

### Lab 5.2 — work both, alternating

In **lab-a**, create `ios/Wythin/UI/Design/RelativeDateText.swift`:

```swift
import SwiftUI

struct RelativeDateText: View {
    let date: Date
    var body: some View {
        Text(date, format: .relative(presentation: .named))
            .font(Theme.monoLabel)
            .foregroundStyle(Theme.dim)
    }
}
```

In **lab-b**, create `ios/Wythin/UI/Design/MetricBadge.swift`:

```swift
import SwiftUI

struct MetricBadge: View {
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.dim)
            Text(value)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Theme.card, in: Capsule())
    }
}
```

Both live in `ios/Wythin/UI/Design/`, next to the existing `MetricTile.swift`, and
both use `Theme` tokens for the same reason as Lab 4.4.

Add each file to the Xcode target in its own worktree (open that worktree's
`.xcodeproj`, or let an agent do it). Commit in both.

**Move between them with `prefix+shift+j` / `prefix+shift+k`** — this is the
rhythm you're building. Two workspaces, one keystroke apart.

If you put a Claude agent in each, `prefix+alt+j` becomes your primary key: it
takes you to whichever agent is waiting, and you stop tracking where things are.

### Lab 5.3 — build both without collision

Each worktree gets its own derived data. Run these in separate panes,
simultaneously:

```sh
# lab-a pane
xcodebuild -project /Users/alexutkin/.worktrees/lab-a/ios/Wythin.xcodeproj \
  -scheme Wythin -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/dd-lab-a build
```

```sh
# lab-b pane
xcodebuild -project /Users/alexutkin/.worktrees/lab-b/ios/Wythin.xcodeproj \
  -scheme Wythin -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/dd-lab-b build
```

**Both must succeed.** Without `-derivedDataPath` they share
`~/Library/Developer/Xcode/DerivedData` and produce intermittent, unreproducible
failures.

> **Why `generic/platform=iOS Simulator`?** A *build* doesn't need a specific
> device, and naming one makes two parallel builds resolve to the same simulator.
> Generic sidesteps that completely. (It also means the command doesn't rot when
> Apple retires a device name — `iPhone 16` isn't even installed on this machine.)
>
> **Tests are different.** `xcodebuild test` does need a real device, and two test
> runs against the same one will contend for a single booted simulator. Your
> installed devices:
>
> ```sh
> xcrun simctl list devices available | grep iPhone
> ```
>
> For parallel tests, give each worktree its own:
>
> ```sh
> # lab-a
> -destination 'platform=iOS Simulator,name=iPhone 17'
> # lab-b
> -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
> ```
>
> Or just run tests sequentially — usually the simpler call.

### Lab 5.4 — the conflict, on purpose

Merge both. The first is clean; the second is not.

```sh
cd ~/Code/Wythin
git checkout main
git merge lab/relative-date-text     # clean
git merge lab/metric-badge           # CONFLICT in project.pbxproj
```

**Expect:** `CONFLICT (content): Merge conflict in ios/Wythin.xcodeproj/project.pbxproj`

> **If it merges cleanly instead — don't celebrate, verify.** The conflict is
> *likely*, not certain: git merges by line proximity, so if Xcode happened to
> insert the two entries far enough apart in each region, it will splice both in
> without complaint. That's the good outcome. But a clean merge of a pbxproj is
> exactly when people skip checking, and it's also possible for git to produce a
> *syntactically valid file that drops one side's entry from a single region*.
> Either way, run the verification at the end of this lab. The check matters more
> than the conflict.

Both branches added a file, so both edited the same four regions:

| Region | What it holds |
|---|---|
| `PBXBuildFile` | "compile this file" |
| `PBXFileReference` | "this file exists, here's its type" |
| group `children` | where it appears in the navigator |
| `Sources` build phase | the compile list for the target |

**How to resolve: keep both sides.** This conflict is almost always additive —
neither branch is *replacing* the other's line, they just landed adjacently. So:

```sh
git checkout --merge ios/Wythin.xcodeproj/project.pbxproj   # if you need to restart
```

Open the file and remove the conflict markers, keeping **both** the
`RelativeDateText` and `MetricBadge` lines in all four regions. Never pick one
side wholesale — `--ours` or `--theirs` on a pbxproj silently drops the other
feature's file from the build, which compiles fine and then crashes at runtime with
"unknown symbol."

Then:

```sh
git add ios/Wythin.xcodeproj/project.pbxproj
git commit
```

**Verify — and this is the important part.** A resolved pbxproj can be *valid TOML
nonsense*. Prove it:

```sh
xcodebuild -project /Users/alexutkin/Code/Wythin/ios/Wythin.xcodeproj \
  -scheme Wythin -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/dd-merged build
```

Then confirm both files are actually compiled:

```sh
grep -c "RelativeDateText.swift in Sources" ios/Wythin.xcodeproj/project.pbxproj  # expect 1
grep -c "MetricBadge.swift in Sources"      ios/Wythin.xcodeproj/project.pbxproj  # expect 1
```

If either is `0`, you dropped a side. That is exactly the failure that produced
your `PracticeImpactGauge` commit.

### Lab 5.5 — tear down

```sh
cd ~/Code/Wythin
git worktree remove ~/.worktrees/lab-a
git worktree remove ~/.worktrees/lab-b
git branch -d lab/relative-date-text lab/metric-badge
rm -rf /tmp/dd-lab-a /tmp/dd-lab-b /tmp/dd-settings-os /tmp/dd-merged
```

Close the two herdr workspaces with `prefix+shift+x`.

**Verify:** `git worktree list` → 5 entries. `herdr workspace list` → no `lab-*`.

### How to avoid the conflict entirely

Now that you've resolved one, here's how to not have them:

- **Merge often.** Two branches that both add files conflict once per merge. Daily
  merges mean small, obvious conflicts; week-old branches mean four-region puzzles.
- **Partition by directory.** If parallel features touch disjoint areas, only
  pbxproj collides — and that resolution is mechanical.
- **Sequence the file-adding step.** If feature A and B each need one new file,
  add both files on `main` first (empty stubs, one commit), then branch. Both
  worktrees then only *edit* files, and pbxproj never conflicts.

That third one is the professional move and it costs 30 seconds.

---

## Module 6 — Final exam (10 min)

No looking.

1. You're in `lab-a` workspace, tab 1, and want tab 3. Key?
2. You want workspace 2. Key?
3. An agent in another workspace needs input. Fastest key?
4. Name the escalating close chords, pane → tab → workspace (post-fix).
5. Why must `xcodebuild -project` take an absolute path?
6. Two worktrees, `xcodebuild` in both simultaneously. What single flag prevents
   corruption?
7. You merge two branches that each added a Swift file. Which file conflicts, and
   what's the resolution rule?
8. You resolved a pbxproj conflict and it builds. What must you still check?
9. Your worktree keybindings return `not_git_worktree`. Why?
10. How do you leave herdr without stopping anything?

<details>
<summary>Answers</summary>

1. `prefix+alt+3`
2. `prefix+shift+2`
3. `prefix+alt+j` (or `k`) — agent-walk crosses workspaces
4. `prefix+x` → `prefix+alt+x` → `prefix+shift+x`
5. Relative paths resolve against a drifting cwd; you can build another worktree's
   project and believe you tested your change
6. `-derivedDataPath`, unique per worktree
7. `project.pbxproj`. Keep **both** sides — the conflict is additive; never
   `--ours`/`--theirs`
8. That both files still appear in the `Sources` build phase — a dropped side
   compiles clean and fails at runtime
9. The workspace's cwd isn't inside a git work tree. Yours point at
   `/Users/alexutkin`, which stopped being a repo after the relocation
10. `prefix+q` to detach; `herdr` to return
</details>

---

## Appendix A — Your effective keymap

Defaults merged with your friend's overrides, plus the Module 3 fix. **Verify
against `prefix+?`** — the overlay is authoritative.

### Navigation

| Key | Action |
|---|---|
| `prefix+h/j/k/l` | focus pane left/down/up/right |
| `prefix+tab` / `prefix+shift+tab` | cycle panes |
| `prefix+shift+h` / `prefix+shift+l` | previous / next tab |
| `prefix+shift+j` / `prefix+shift+k` | next / previous workspace |
| `prefix+alt+j` / `prefix+alt+k` | next / previous **agent** |
| `prefix+1..9` | focus agent N |
| `prefix+alt+1..9` | switch to tab N |
| `prefix+shift+1..9` | switch to workspace N |
| `prefix+w` | workspace picker |
| `prefix+g` | goto |

### Create / rename / close

| Key | Action |
|---|---|
| `prefix+v` / `prefix+minus` | split vertical / horizontal |
| `prefix+c` | new tab |
| `prefix+shift+n` | new workspace |
| `prefix+shift+g` | new worktree |
| `prefix+shift+o` | open worktree |
| `prefix+shift+d` | remove worktree |
| `prefix+shift+p/t/w` | rename pane / tab / workspace |
| `prefix+x` | close pane |
| `prefix+alt+x` | close tab *(your fix)* |
| `prefix+shift+x` | close workspace |

### Utility

| Key | Action |
|---|---|
| `prefix+?` | help overlay |
| `prefix+z` | zoom pane |
| `prefix+r` | resize mode |
| `prefix+b` | toggle sidebar |
| `prefix+e` | edit scrollback |
| `prefix+s` | settings |
| `prefix+o` | open notification target |
| `prefix+shift+r` | reload config |
| `prefix+q` | detach |
| `prefix+alt+g` | lazygit popup |

---

## Appendix B — Command reference

```sh
hw                              # where am I (alias from Drill 0.1)
herdr pane current              # full pane JSON
herdr workspace list            # all workspaces
herdr tab list                  # all tabs, focused flag
herdr worktree list             # worktrees (needs repo-rooted workspace)
herdr agent list                # agents and their states
herdr server reload-config      # apply config.toml live
herdr status                    # client/server version + health
herdr server stop               # actually stop everything
```

Git worktree:

```sh
git worktree list
git worktree add ~/.worktrees/<slug> -b <branch> main
git worktree move <old> <new>              # never plain mv
git worktree remove <path>                 # --force if dirty
git worktree prune                         # clean stale metadata
```

---

## Appendix C — Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Keys do nothing | Not in prefix mode | Press `ctrl+b`, **release**, then the key |
| `prefix+N` goes to the wrong place | Agent, not tab | Tabs are `prefix+alt+N` |
| `not_git_worktree` | Workspace cwd isn't in a repo | Make a workspace rooted at `~/Code/Wythin` |
| `reload-config` errors | TOML syntax | Fix the file; old config stays live |
| Build succeeded but change absent | Relative `-project` path | Use absolute paths |
| Intermittent build failures | Shared DerivedData | `-derivedDataPath` per worktree |
| Runtime "unknown symbol" after a merge | Dropped a pbxproj side | `grep -c "<File>.swift in Sources"` |
| `git worktree remove` refuses | Uncommitted changes | Commit, or `--force` to discard |
| Worktree path wrong after moving | Used `mv` | `git worktree repair <path>` |

---

## What to do next

1. Do Modules 0–3 in one sitting (~60 min). That's navigation and it's the part
   that has to become automatic.
2. Take a break. Come back for 4–5 (~55 min) with a clear head — those produce
   real commits.
3. For a week, force yourself to use `prefix+w` instead of hunting. The picker
   builds the map that makes the chords feel obvious later.
4. When the relocation settles, re-read Lab 4.2 — if you ever move the repo again,
   `git worktree repair` is the command that saves you.
