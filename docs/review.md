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

git runs as a `Process` without a shell, with a 10 s timeout (SIGTERM, then SIGKILL) and a 16 MB output cap. Its environment is minimal: `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_ATTR_NOSYSTEM=1`, `GIT_ATTR_SOURCE=<empty tree>`, `GIT_OPTIONAL_LOCKS=0`, `GIT_TERMINAL_PROMPT=0`, `GIT_NO_REPLACE_OBJECTS=1`, `GIT_NO_LAZY_FETCH=1`, `LC_ALL=C`, and a pager of `cat`. Every call passes the following:

- `-c core.fsmonitor=false`, `core.untrackedCache=false`, `core.hooksPath=/dev/null`, `core.attributesFile=/dev/null`, `diff.external=`, `color.ui=false`, `submodule.recurse=false`;
- `protocol.allow=never` plus `protocol.{ext,file,ssh,http,https}.allow=never`, so a partial clone's promisor remote is never fetched from;
- every other configurable program pinned: `core.sshCommand=`, `core.askPass=`, `credential.helper=`, `gpg.program=` (and the openpgp, x509 and ssh variants), and `core.editor=true`/`sequence.editor=true`, since an empty editor would fall back to vi;
- prefix and quoting options for stable parsing.

Diffs also pass `--no-ext-diff --no-textconv --no-color`, so `diff.<driver>.command` and `textconv` don't run.

**Filter and diff drivers.** A working-tree diff runs `filter.<name>.clean` or `.process` for any path whose attributes name that filter, and a diff can run `diff.<name>.textconv`, `diff.<name>.command` or `diff.external`. Haunt never builds `-c filter.<name>...` overrides from the repo's names: a name can hold `=`, `.`, quotes or a newline and be misparsed. Instead it reads `git config --show-scope -z --get-regexp '^(filter|diff)\.'` (reading config runs nothing; the `command` scope is Haunt's own pins):

- If any filter, textconv, diff command or external diff is configured, or the list can't be read, the working tree and untracked files aren't read. Only the committed range is diffed (`git diff <base> <head>`, which compares blobs and runs no filter), and the screen says why.
- Otherwise, the working tree is read. `GIT_ATTR_SOURCE` points attributes at the empty tree, so a `.gitattributes` written after the check can't name a filter either.
- `GIT_ATTR_SOURCE` needs git 2.40 or newer. With an older git (Apple's `/usr/bin/git` is 2.39), Haunt shows committed changes only and says so.
- Residual: `$GIT_DIR/info/attributes` is still read under `GIT_ATTR_SOURCE`. It can only name a filter that is configured, and a configured filter turns the working tree off, so a filter set up between the check and the diff (milliseconds) is the remaining window.

**Untracked files.** Each path from `git ls-files --others` is `lstat`ed first. Only regular files are diffed with `git diff --no-index`. A symlink shows its target, read without git and without following it. Anything else (a FIFO, socket or device) is listed as "special" with a note and never handed to git, which would block reading it. git's own listing already skips FIFOs; the check covers one that replaces a file after the listing.

**Hidden characters (Trojan Source).** Every repo-derived string drawn on screen goes through `Visible.text`: paths, hunk headers, diff lines, branch, upstream and repo names, and the turn's prompt, commands, tasks and files. It replaces each character `PastePreview.hidden` flags with a visible `⟨U+202E⟩`. That covers C0/C1 controls, format characters (bidi overrides and isolates, zero-width characters, the BOM, soft hyphens), any whitespace but the space (U+2028/2029, NBSP) and default-ignorables that draw as nothing (Hangul fillers, variation selectors). A literal `⟨` is escaped too, as `⟨U+27E8⟩`, so every `⟨` on screen starts a placeholder and a filename can't fake one. A file whose path or lines hold a hidden character is tagged "hidden chars" in its header and "hidden" in the file lists, and those lines are flagged. Paths are only escaped where drawn: viewed state, comments and de-duplication use the raw path, so two files never share state through a look-alike name.

`/usr/bin/git` is used only when the developer tools are installed, so it never triggers the install prompt. `macos/tests/review.sh` covers the following. Each hostile fixture is first run through plain git to show it really fires, so the test is live.

- A repo's own `core.fsmonitor` doesn't run. A repo's `diff.external` limits the review to the committed range and doesn't run either.
- `diff.<x>.textconv`, `diff.<x>.command` and `diff.external` each count as drivers. `diff.renames` and Haunt's own `-c` pins don't.
- With clean and process filters configured, including ones named `Ev.il` and `x=y.z`, only the committed range is shown, and no filter runs.
- With the filters still configured, a direct working-tree diff runs none of them, because `GIT_ATTR_SOURCE` is set. This simulates a filter that appears after the check.
- A partial clone with a deleted blob and an `ext::` promisor remote fetches nothing, and loads promptly.
- A FIFO among the untracked files doesn't stall loading. A symlink shows its target.
- Bidi, zero-width and escape characters in lines, names and hunk headers are spelled out and flagged. So are separators, Hangul fillers and variation selectors.
- A file named with a literal `⟨U+202E⟩` next to one holding a real U+202E: both are listed, drawn differently, flagged correctly, and don't share viewed state.
- CRLF lines split cleanly.

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
