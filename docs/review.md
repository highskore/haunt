# Review screen

Open it with the `[keys]` action `review` (default `cmd+shift+r`), View > Review Changes, or the palette. It opens on the inbox (haunt-review-2 version 11), with the current tab's entry selected. Enter opens that entry's full review: the diff (01), line comments that collect into a follow-up prompt (06), and an overview of the turn (09). In the full review, keys `1` and `2`, the crumb, and the Overview's "Files" tab switch between Files and Overview. Esc goes back to the inbox, and Esc in the inbox closes the screen.

## Inbox (11)

There is one entry per agent tab whose latest turn has a verified cwd. Entries are grouped from real state only:

- **Changes requested**: notes were sent back from this review, and the agent either hasn't started on them or is in the turn that follows. The row says "N notes sent" or "agent working on N notes".
- **Waiting on checks**: the unfinished turn is running a test or build command right now.
- **Approved**: approved in this review, in memory.
- **Ready for review**: everything else, including a turn that is still running something that isn't a check.

There is no "Merged today" group, because Haunt doesn't know what was merged. Row stats and the file count come from each entry's git diff, loaded in the background. "tests ✓" means every check the agent ran passed. A check with an unknown result, as from Codex, reads "tests ran".

Keys: `j`/`k` (or the arrow keys) move between entries, Enter opens one, `a` approves, `r` opens the follow-up prompt (06) for it. There is no snooze (`x`), because it would hide data without a reason Haunt can show. Opening an entry switches to its tab, so a follow-up is pasted where the user can see it.

The detail pane shows the following:

- the prompt's first line as the title, because the hooks carry no summary;
- repo/branch → upstream, the tab, commits made during the turn, and when it finished;
- the prompt, tasks done, the test run's result (with no pass counts, which the hooks don't give), the number of subagents, and how long the turn took;
- the files, then the checks with their result in place of a duration, then every file's diff, read-only.

`ReviewDiff` keeps `base` and `head` per entry, ready for a merge-order view.

## Data

- **Turn**: `HauntCore::review_turn(surface_id)`, built only from nonce-verified hook events (`core/src/turn.rs`). It holds the prompt, tasks, Bash commands with their outcome, edited files, subagents and `head_at_start` (HEAD read from `.git` when the prompt arrived; no git process).
- **Checks**: test and build commands the agent ran (`Checks.isCheck`). An outcome is `passed` only when Claude's hooks reported a success and no failure. Other agents give `result unknown`, and a command still running at the stop also gives `result unknown`. The project's standard checks (Cargo.toml, Package.swift, go.mod, package.json `test`, .swiftlint.yml) are listed as `not run` when the turn didn't run them. A narrowed run (`--filter`, `-k`, `-p`, ...) doesn't count as the full suite.
- **Diff**: git runs in the turn's verified cwd, off the main thread. It diffs the working tree and index against `head_at_start` when that commit is an ancestor of HEAD, so commits made during the turn are included. Otherwise it diffs against HEAD and says so in a note. Untracked files are included, up to 100. Each file is truncated at 2000 lines with a note. Binary files are listed, not rendered.
- **Viewed, comments, verdict**: kept per tab in memory, until the tab's next turn.

## git safety (`GitRunner`)

git runs as a `Process` without a shell, with a 10 s timeout (SIGTERM, then SIGKILL) and a 16 MB output cap. Its environment is minimal: `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_ATTR_NOSYSTEM=1`, `GIT_OPTIONAL_LOCKS=0`, `GIT_TERMINAL_PROMPT=0`, `GIT_NO_REPLACE_OBJECTS=1`, `LC_ALL=C`, and a pager of `cat`. Every call passes the following:

- `-c core.fsmonitor=false`, `core.untrackedCache=false`, `core.hooksPath=/dev/null`, `core.attributesFile=/dev/null`, `diff.external=`, `color.ui=false`, `submodule.recurse=false`, `protocol.allow=never`;
- every other configurable program pinned: `core.sshCommand=`, `core.askPass=`, `credential.helper=`, `gpg.program=` (and the openpgp, x509 and ssh variants), and `core.editor=true`/`sequence.editor=true`, since an empty editor would fall back to vi;
- prefix and quoting options for stable parsing.

Diffs also pass `--no-ext-diff --no-textconv --no-color`, so `diff.<driver>.command` and `textconv` don't run.

**Filter drivers.** A working-tree diff runs `filter.<name>.clean` or `.process` for any path whose `.gitattributes` names that filter. Before diffing, Haunt reads `git config --name-only -z --get-regexp '^filter\.'`; reading config runs nothing. Every driver it lists is then overridden on all later calls with `filter.<name>.clean=`, `.smudge=`, `.process=` and `.required=false`, and git skips a filter whose command is empty. If that list can't be read, Haunt shows no diff and says why.

`/usr/bin/git` is used only when the developer tools are installed, so it never triggers the install prompt. `macos/tests/review.sh` checks that a repo's own `diff.external` and `core.fsmonitor` don't run, and that hostile clean and process filters named by `.gitattributes` don't run either. The test first checks that plain git does run them, so the test is live.

## Sending a follow-up (06)

The drafted prompt is shown in full in an editable text view. Nothing is sent until the user clicks Send to agent (or presses ⌘⇧S). Then:

1. `SendBack.check` normalises CRLF and trims surrounding whitespace, then blocks the send with a message for empty text, a bracketed-paste end (`ESC[201~`), or anything `PastePreview` flags as a control or invisible character (tabs are allowed).
2. The send is refused unless the reviewed tab is still selected and is an agent row, not a shell. It is also refused while the row needs you, so the text can't land in a permission prompt.
3. `core.onUserInput(surface)` runs first, because a send counts as user input and retires any pending permission request. Then the text goes through `ghostty_surface_text`, the same path as a paste. Ghostty wraps it in bracketed paste when the program enabled that mode. Claude Code and Codex do enable it, which is one reason sending is limited to agent rows: Haunt can't query the mode.
4. No newline or Enter is appended. The user presses Return in the terminal.

## Not built yet

- 09's "Squash and merge into main" and "Commit and open PR on GitHub" are drawn as in the mockup but do nothing. They beep, with the tooltip "Coming soon: Haunt doesn't merge, commit or push yet."
- Approve marks the review approved in memory only. It has no git side effects.
- The agent's closing summary isn't in any hook payload, so 09 says so instead of showing one. The Turn tab is shown but inert.
