# Handoff: finishing on a real Mac

For whoever picks this up on a Mac — a person, or a coding agent started in this repo
([AGENTS.md](../AGENTS.md) points here). Work through it in order: check where things stand, set
up the Mac, build and test, install and set up the app, run the checks only a real Mac can do,
then report what you found.

Written 26 November 2026 on a Windows PC with no Mac: until now everything was built and tested
only on GitHub's macOS runners.

## 1. Where things stand

**The app.** PaperKnife for Mac is an offline, open-source (Apache 2.0) PDF editor. You click any
text in a PDF and change or delete it. Every edit is verified: PaperKnife saves a copy, reads it
again and compares the whole page, and if anything else would change it refuses the edit and says
why. It also rotates, deletes and adds pages, undoes and redoes, and saves with Save As. It has no
networking code. It is the Mac version of
[PaperKnife for Windows](https://github.com/shivam098/paperknife-windows), the lead app: the
engine (`Sources/PaperKnifeCore`) is the Windows engine ported line by line to Swift
([docs/PORTING.md](PORTING.md)), and the window (`Sources/PaperKnifeApp`, AppKit with SwiftUI
views) follows the Windows window.

**Done and merged.** Everything is on `main`:

- The engine passes all 128 cases of the shared conformance corpus (`conformance/`), copied from
  paperknife-windows@f03800a, the engine of PaperKnife for Windows 0.5.1.
- The app opens PDFs (File › Open, drag and drop, Finder's Open With), asks for the password of a
  protected one, selects text with a click, edits or deletes it, shows why an edit was refused,
  rotates, deletes and adds pages, undoes and redoes, zooms, saves with Save As, and asks before
  closing with unsaved changes.
- `scripts/package-app.sh` builds one universal app (Apple silicon and Intel), signs it ad hoc
  (there is no Apple Developer ID), and packs a disk image (DMG) and a ZIP.
- CI (`.github/workflows/ci.yml`) runs on every push and pull request:

  | Job | Runs on | Checks |
  |---|---|---|
  | Test | macOS 15 (Xcode 16.4) and macOS 26 (Xcode 26.6) | `swift build` and `swift test` |
  | Package | macOS 26 | `scripts/package-app.sh`: the app, its self-check, the DMG, the ZIP and their checksums |
  | Check the app | macOS 15, on Apple silicon and on Intel | the checksums, the signature and `--self-check`, from the DMG and from the ZIP |
  | Screenshot | macOS 26 | opens a sample PDF in the packed app, clicks "Hello World", types "Hello PaperKnife" and checks that the app reports "Text updated" |

- Pushing a tag such as `v0.5.1` runs `.github/workflows/release.yml`: CI with that version, then
  a GitHub release with the DMG, the ZIP, `SHA256SUMS.txt` and the notes in
  `docs/releases/<tag>.md`.
- The first and only release is
  [PaperKnife for Mac 0.5.1](https://github.com/shivam098/paperknife-macos/releases/tag/v0.5.1),
  published on 19 November 2026 from `main` at `4db8d9f`.

**In progress.** Nothing. Before this handoff, no pull request or issue had ever been opened, and
the six work branches still on GitHub (`invalid-unicode`, `mac-app`, `port-pdfium`,
`port-session`, `port-syntax`, `swift-port`) are all merged into `main`.

**Planned** ([docs/ROADMAP.md](ROADMAP.md)). Next: Developer ID signing and notarization, the App
Sandbox without network access, a thumbnail sidebar with drag to reorder, and extract, merge and
split. The engine already has `movePage`, `PdfTools.merge` and `PdfTools.extractPages`, ported and
tested, but the app has no commands for them yet. Later: annotations and forms, compress and
image conversion, import from a scanner or iPhone, on-device text recognition, and the Mac App
Store.

**Latest CI on `main`.**
[Run 44580788488](https://github.com/shivam098/paperknife-macos/actions/runs/44580788488) for
`4db8d9f` shows "failure", but no test failed. Two jobs ("Test on macos-26" and "Check the app on
macos-15") never got a macOS runner from GitHub and were cancelled: "The job was not acquired by
Runner of type hosted even after multiple attempts". Every job passed for the same commit in the
[Release run](https://github.com/shivam098/paperknife-macos/actions/runs/44580792144) and in the
[`mac-app` run](https://github.com/shivam098/paperknife-macos/actions/runs/44575749990). When this
happens, re-run the failed jobs: `gh run rerun <run id> --failed`.

**Never checked on a real Mac.** Nobody has yet opened the downloaded app through macOS's
first-open check, used it on a Retina screen (CI's screen is 1024 × 768) or in Dark Mode, run it
on a macOS other than CI's 15 and 26 (such as 13 and 14, which the README promises, or 27),
opened its window on an Intel Mac (CI runs only `--self-check` there), saved into Desktop,
Documents, iCloud Drive or a USB drive, seen the "Save changes?" question, tried the password
prompt, or opened the owner's own PDFs with it. Section 5 covers all of these.

**Out of date.** The repository's description on GitHub still says "(planned)", and
`SECURITY.md` still says that the repository has no app code.

`main` was at `4db8d9f8b3521431ce65b1978dc185b29d9c1799` when this was written. Before you start
(in your clone, see section 2): `git pull`, `gh pr list`, `gh run list --branch main --limit 3` —
later work may have landed since this was written.

## 2. Set up this Mac

**macOS.** The app runs on macOS 13 (Ventura) or later. Building needs Xcode 16 or later
([CONTRIBUTING.md](../CONTRIBUTING.md)), which needs macOS 14.5 or later. CI builds with Xcode
16.4 on macOS 15 and with Xcode 26.6 on macOS 26. A newer macOS and Xcode are fine: write their
versions in your report (section 6).

**Xcode.** Install Xcode from the App Store: the full app, not only the Command Line Tools, as on
CI. Then select it, accept its license, let it install its components, and check the versions:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
xcodebuild -version
swift --version
```

**Homebrew and GitHub.** Install Homebrew from <https://brew.sh>. Then install the GitHub CLI and
log in as `shivam098` (choose GitHub.com, HTTPS and the browser):

```bash
brew install gh
gh auth login
gh auth setup-git
```

Only if you need them: `brew install cliclick` for CI's UI check (section 3), and
`brew install --cask powershell` for `pwsh scripts/sync-conformance.ps1`, which copies a new
corpus from paperknife-windows.

**The clone.** Put it outside Desktop and Documents, which iCloud Drive may sync, and commit as
the owner:

```bash
mkdir -p ~/Developer && cd ~/Developer
gh repo clone shivam098/paperknife-macos
cd paperknife-macos
git config user.name shivam098
git config user.email 39924466+shivam098@users.noreply.github.com
```

To compare with the Windows app or to sync the corpus, clone paperknife-windows next to it:
`gh repo clone shivam098/paperknife-windows`.

## 3. Build and test

These are CI's commands (the "Test" job in `.github/workflows/ci.yml`):

```bash
scripts/fetch-pdfium.sh   # once: downloads PDFium chromium/8152 and checks its SHA-256
swift build
swift test
```

What to expect:

- `scripts/fetch-pdfium.sh` puts `libpdfium.dylib` in `third_party/pdfium/mac/`, which git
  ignores. It needs the internet. Nothing else needs a network, an account, a secret, an
  environment variable or a permission.
- `swift build` ends with `Build complete!`. One warning is known, in `EditorModel.swift` line
  225: "capture of 'closing' with non-Sendable type 'Editor?' in a '@Sendable' closure".
- `swift test` runs 62 XCTest tests; none is skipped. Its output is long;
  `swift test 2>&1 | tail -n 15` shows the end. It ends with
  `Executed 62 tests, with 0 failures (0 unexpected)`, then prints:
  - `cases/tex-font-with-many-names.json: step 1 took … ms, within its limit of 3000 ms.`
  - `cases/content-delete-cjk-text.json: platform difference: …`, ending with
    `not compared, as the font “STSong-Light” isn't embedded`. This is expected: the corpus lets
    the bounds of text in a font that isn't embedded differ outside Windows
    ([conformance/README.md](../conformance/README.md)).
  - `Conformance corpus: 128 of 128 cases give the stored observations.`
  - `Test run with 0 tests …` from Swift Testing, because all the tests use XCTest.
- On CI the build takes about 30 seconds and the tests 2 to 3.5 minutes, on either macOS. The
  slowest are `BundledFontsTests` (about a minute) and the corpus (1 to 2 minutes).

Then build, check and pack the app as CI's "Package" job does (about 3 minutes on CI):

```bash
scripts/package-app.sh 0.0.0-dev
```

It builds for Apple silicon and for Intel, joins the two, adds PDFium and the fonts, signs the app
ad hoc and runs its self-check, whose output must end with `Passed.`. It writes
`artifacts/app/PaperKnife.app` (about 89 MB) and, in `artifacts/release/`, the DMG, the ZIP and
`SHA256SUMS.txt`. Git ignores `artifacts/`.

Test the packaged app, not `swift run PaperKnife` or Xcode's Run button: a bare executable lacks
the fonts and the glyph list that the script copies into the app, so it doesn't behave like the
app users get.

**CI's UI check on this Mac (optional).** It needs `cliclick`. Terminal needs Accessibility and
Screen Recording (System Settings › Privacy & Security), and permission to control System Events,
which macOS asks for on the first run:

```bash
mkdir -p scratch   # git ignores scratch/
open -a "$PWD/artifacts/app/PaperKnife.app" "$PWD/conformance/documents/90f66aab2200.pdf"
sleep 10
bash scripts/ci-click-page.sh 0.2191 0.1365 "Hello World" scratch/selected.png
bash scripts/ci-edit-text.sh "Hello PaperKnife" "Text updated" scratch/edited.png
```

Expect `"Hello World" is selected for editing.` and `PaperKnife reported "Text updated".` Then
quit PaperKnife and choose **Don't Save**.

**If something fails:**

- The linker can't find `pdfium`: run `scripts/fetch-pdfium.sh` first.
- `fetch-pdfium.sh` reports a checksum mismatch: never change the checksum. Try again later; if it
  stays, open an issue.
- Odd build errors after switching Xcode: `rm -rf .build` and build again. New errors from a
  newer Xcode: open an issue with the Xcode version and the exact message.
- A conformance case fails: the message names the case file and the JSON path that differs.
  Don't edit `conformance/` here; it is copied from paperknife-windows
  ([CONTRIBUTING.md](../CONTRIBUTING.md)). A failure only on this Mac's macOS version is a
  finding: report it, and ask the owner before relaxing any comparison.
- A step takes longer than its `maxMilliseconds`: record the time and report it; don't raise the
  limit.
- A CI job is cancelled because it "was not acquired by Runner": GitHub had no free Mac. Re-run
  it.

## 4. Install and set up the app

Install what users get first: the latest release's DMG, downloaded with a browser. A browser marks
the file as downloaded from the internet, which is what makes macOS check the app when it is first
opened; `curl`, `gh release download` and an app you build yourself skip that check.

1. In Safari, open the
   [latest release](https://github.com/shivam098/paperknife-macos/releases/latest) and download
   `PaperKnife-<version>-mac.dmg` and `SHA256SUMS.txt`.
2. Compare `shasum -a 256 ~/Downloads/PaperKnife-*-mac.dmg` with the DMG's line in
   `SHA256SUMS.txt`.
3. Open the DMG, drag PaperKnife onto Applications, and eject the DMG.
4. Open PaperKnife from Applications.
   - On macOS 15 or later, macOS refuses the first time: choose **Done**, not Move to Trash. Open
     **System Settings › Privacy & Security**, scroll down to **Security**, and click
     **Open Anyway** next to the message about PaperKnife (it shows for about an hour after the
     refusal). Confirm with your password or Touch ID, and confirm again when macOS asks.
   - On macOS 13 or 14, Control-click PaperKnife in Applications, choose **Open**, then **Open**.

   Later opens need nothing.
5. Check the installed copy:

   ```bash
   codesign --verify --strict --verbose=2 /Applications/PaperKnife.app   # valid on disk
   codesign -dv /Applications/PaperKnife.app 2>&1 | grep Signature        # Signature=adhoc
   /Applications/PaperKnife.app/Contents/MacOS/PaperKnife --self-check    # ends with Passed.
   ```

   The self-check prints the version, the chip and the macOS version, then checks PDFium, zlib
   and the bundled fonts, without opening a window.

To try a `main` newer than the release, build it (section 3) and replace the installed copy:

```bash
rm -rf /Applications/PaperKnife.app
ditto artifacts/app/PaperKnife.app /Applications/PaperKnife.app
```

**PaperKnife › About PaperKnife** shows which one you have: a local build is `0.0.0-dev`.

**Permissions and first run.** PaperKnife asks for no permissions of its own. It has no account,
no settings and no first-run setup: it opens straight to its window. It isn't sandboxed, so macOS
may ask once whether PaperKnife may access files in Desktop, Documents, Downloads, iCloud Drive or
on a removable or network volume, most likely when you save there (checklist item 9). It is
registered as an alternative app for PDFs: it appears in Finder's **Open With** menu, and Preview
stays the default. To make PaperKnife the default, use Finder's
**Get Info › Open with › Change All…**.

## 5. What only a real Mac can check

CI proved that the engine passes the corpus, that the packed app passes its self-check on Apple
silicon and on Intel, and that one edit works when a script drives the window on a 1024 × 768
screen. Everything below is new. Use the installed release (section 4) and write down each result
as you go (section 6). A coding agent can script a few items, like CI's UI check in section 3,
once a person has granted the permissions; the rest need a person's eyes and hands.

Use the sample PDFs in `conformance/documents/`. PaperKnife's tests generated them, so they hold
nothing private and may appear in screenshots and issues:

| File | What it holds |
|---|---|
| `90f66aab2200.pdf` | "Hello World" (Helvetica, 24 pt), "This line must not move" and a red box |
| `e38797bb5876.pdf` | An invoice drawn one letter at a time: "Invoice 2024", "$1,250.00", "Total due" |
| `058bf4358999.pdf` | Text in a Type 3 font, "abc", as in PDFs saved from Chrome |
| `0f4c2884386f.pdf` | A LaTeX-style subset of Computer Modern (CMR10): "Hello world" and "older" |
| `e6d8688f7a08.pdf` | Three pages: "Page 1", "Page 2" and "Page 3" |
| `32a4377b16a1.pdf` | One page |
| `5239cd3fd1d2.pdf` | Encrypted; its author forbids changes, so it opens without a password but can't be edited |

The messages quoted below are the ones the corpus cases (`conformance/cases/`) expect. CI's
screenshots of the window are in the `paperknife-mac-screenshot` artifact of each CI run, kept for
90 days: `gh run download <run id> -n paperknife-mac-screenshot -D scratch/ci`.

1. **First open of the download.** Follow section 4 with the DMG downloaded in Safari. Expect
   macOS to refuse the first open, **Open Anyway** to work, later opens not to ask, and the three
   commands of step 5 to print `valid on disk`, `Signature=adhoc` and `Passed.`. Note macOS's
   exact words.
2. **The empty window.** Open PaperKnife without a file. Expect the title PaperKnife, "Edit PDFs
   on this device. Your files are never uploaded.", an **Open a PDF** button, and "Your files
   stay on this device." in the status bar. Every toolbar button except **Open** is dimmed. The
   window can't be made smaller than 960 × 600 points, and it reopens at the size and place you
   left it. **PaperKnife › About PaperKnife** shows the icon and the version.
3. **Every way to open a PDF.** Open `90f66aab2200.pdf` with **File › Open…** (⌘O), the
   **Open a PDF** button, a drag onto the window, a drag onto PaperKnife's Dock icon, Finder's
   **Open With › PaperKnife** (with PaperKnife closed, and with it open), and
   `open -a PaperKnife <file>`. Expect each time: the file name as the window title, a blue
   message "Click any text on the page to edit it.", "Page 1" in the sidebar, the page, its two
   lines under "Text on this page", and "Page 1 of 1 · 100%" in the status bar. A dropped file
   that isn't a PDF is ignored.
4. **Retina.** On the Mac's own screen, expect page text as sharp as in Preview, and a click on a
   line to select that line, with the blue box exactly around it. Zoom with ⌘+ (or ⌘=) and ⌘-,
   from 50% to 300%: the box stays on the text, and the zoom buttons dim at the ends. With a
   non-Retina external screen, drag the window across and back: the page is redrawn sharp each
   time, and clicks still select the right line.
5. **Edit text.** In `90f66aab2200.pdf`, click "Hello World". Expect it in the **Selected text**
   field, ready to type over, and "Font: Helvetica · 24 pt · not embedded" under it. Type
   `Hello PaperKnife` and press Return. Expect a green "Text updated. Verified: nothing else on
   this page changed.", the new text on the page, "This line must not move" exactly where it was,
   a dot in the window's close button and "Unsaved changes" in the status bar. Also: **Apply**
   works like Return; Escape or **Reset** restores the field before you apply; ⌘Z while typing
   undoes the typing; clicking a line in "Text on this page" selects it too.
6. **A refused edit.** Change "Hello World" to `Hello Ω`. Expect a red "Nothing was changed" with
   "The font “Helvetica” in this PDF doesn't contain: Ω", and the page as it was.
7. **Delete, undo and redo.** Select "Hello World" and click **Delete Text**. Expect "Text
   deleted. Verified: nothing else on this page changed." Undo with ⌘Z, **Edit › Undo** and the
   toolbar; redo with ⇧⌘Z and the toolbar. Expect each step to show the right page. Once
   everything is undone, the dot and "Unsaved changes" go away.
8. **Hard PDFs.**
   - `e38797bb5876.pdf`: click one letter of "Invoice 2024". Expect the whole line to be
     selected, not one letter (a bug the owner once hit on Windows). Change it to
     `Invoice No. 2024`. Expect "Text updated, and the rest of the line moved to fit. Verified:
     nothing else on this page changed.", with "$1,250.00" where it was.
   - `058bf4358999.pdf`: change "abc" to `cab`. Expect "Text updated. Verified: nothing else on
     this page changed."
   - `0f4c2884386f.pdf`: change "Hello world" to `Hello Kitty`; the PDF's font has no K, i, t or
     y. Expect the "Text updated…" message, and below it "This PDF contained only the letters it
     used from the font “CMR10”, so PaperKnife added a complete copy of that font from its own
     fonts for the new text. …". This uses the fonts inside the app; the tests read them from
     `third_party/` instead.
   - `5239cd3fd1d2.pdf`: expect it to open without a password, with "Editing is off on this page"
     and "The author of this PDF restricted editing." in the edit pane, and the text field
     disabled.
9. **Save As, everywhere.** After an edit, press ⌘S (and also try ⇧⌘S). Expect a save sheet that
   suggests "<name> (edited).pdf" in the original's folder. After saving: a green "Saved" with
   the path, the new name as the window title, and no dot. Open the saved file in PaperKnife and
   in Preview: the edit is there and nothing else changed. Save into Desktop, Documents,
   Downloads, iCloud Drive (if signed in), a USB drive (if you have one) and over the opened file
   itself (choose **Replace**). Expect each save to work, or to fail with a red "Couldn't save"
   and a clear reason, leaving the destination as it was. After each, run `ls -la` on the folder:
   no `~<name>.<id>.tmp` file may be left. Saving to a read-only place, such as the mounted DMG,
   must fail clearly. Write down every macOS permission prompt and when it appeared.
10. **Pages.** Open `e6d8688f7a08.pdf` and select **Page 2** in the sidebar.
    **Page › Rotate Page** (⌘R): expect "Page 2 rotated." and the page turned clockwise.
    **Page › Delete Page…**: expect "Delete page 2?" with "You can undo this until you close the
    document."; **Delete** gives "Page 2 deleted.". **File › Add Pages from PDF…** with
    `32a4377b16a1.pdf`: expect "1 page added." and a new last page. Undo each step, redo them,
    Save As, and check the pages in Preview. In `32a4377b16a1.pdf` itself, deleting its only page
    must be refused: "Nothing was changed" with "A PDF needs at least one page."
11. **A password-protected PDF.** Make one with Preview: open `90f66aab2200.pdf`, choose
    **File › Export…**, click **Permissions…**, select **Require Password To Open Document**, set
    a password (and the owner password it asks for), and save under a new name. Open that copy
    in PaperKnife. Expect a "Password required" sheet saying "“<name>” is protected with a
    password.". A wrong password gives "That password didn't work. Try again."; **Cancel** stops
    without a message; the right password opens it. Delete a line with **Delete Text** (if
    PaperKnife refuses, note its message and save without an edit), Save As, and reopen the saved
    copy: it must still ask for the password.
12. **Unsaved changes.** After an edit, close the window (⌘W), quit (⌘Q), and open another PDF.
    Expect the same question each time: "Save changes to <name>?" ("Your changes will be lost if
    you don't save them.") with **Save As…**, **Cancel** and **Don't Save**. **Cancel** changes
    nothing; **Save As…** saves, then goes on; **Don't Save** goes on. Closing the window also
    quits PaperKnife, which edits one document at a time. Nobody has seen this question yet: on
    CI, quitting after the edit timed out (`AppleEvent timed out`).
13. **Look and feel.** Switch between Light and Dark Mode (System Settings › Appearance):
    everything stays readable, and the page stays white. Try full screen (⌃⌘F), scrolling a
    zoomed page with the trackpad, and resizing the window. Turn on VoiceOver (⌘F5) for a minute:
    it should read the toolbar buttons, the "Pages" and "Text on this page" lists, and the
    messages.
14. **The Intel half.** On Apple silicon with Rosetta
    (`softwareupdate --install-rosetta --agree-to-license` installs it), run
    `arch -x86_64 /Applications/PaperKnife.app/Contents/MacOS/PaperKnife --self-check`: expect
    "self-check on Intel" and `Passed.`. Then select **Open using Rosetta** in Finder's
    **Get Info** for PaperKnife, repeat items 3, 5 and 8 briefly, and clear the checkbox again.
    CI has never opened the window on Intel. On an Intel Mac, the whole checklist covers this.
15. **Offline.** While using PaperKnife, run `lsof -a -i -c PaperKnife` in Terminal. Expect no
    output: no network connections.
16. **The owner's own PDFs.** The PDFs the owner tested PaperKnife for Windows with have never
    been opened by the Mac app, because that would have meant uploading them to GitHub's
    runners. Copy them from the PC directly (AirDrop or a USB drive), make the same edits as on
    Windows, and compare the results and messages with PaperKnife for Windows 0.5.1. A digitally
    signed PDF, if there is one, should show an orange warning that any edit invalidates its
    signature, and ask "Edit a signed PDF?" before the first edit. Never commit these files,
    attach them anywhere, or show them in screenshots.
17. **Speed and memory.** Time opening a long PDF (100 pages or more), moving between its pages,
    and one edit; note PaperKnife's memory in Activity Monitor; note how long `swift test` took
    and the time it printed for `tex-font-with-many-names` (0.7 to 1.2 seconds on CI). Record the
    numbers as findings; the owner decides what they mean.
18. **Other macOS versions.** Record this Mac's macOS version. If a Mac or a virtual machine with
    macOS 13 or 14 is at hand, repeat items 1, 3, 5 and 9 there: the README promises those
    versions, but nothing has run the app on them.

## 6. Report what you found

1. Write `docs/test-results/<YYYY-MM-DD>-<Mac model>.md`, for example
   `docs/test-results/2026-11-27-MacBook-Air-M3.md`. Start with these facts:

   ```bash
   system_profiler SPHardwareDataType | grep -E 'Model Name|Model Identifier|Chip|Processor Name|Memory'
   sw_vers
   xcodebuild -version
   git rev-parse HEAD
   /Applications/PaperKnife.app/Contents/MacOS/PaperKnife --self-check | head -1
   ```

   Then add the results of section 3 (tests run and failed, the corpus line, the times) and one
   row per checklist item of section 5:

   ```markdown
   | # | Check | Result | Notes |
   |---|---|---|---|
   | 1 | First open of the download | Pass | macOS said "…" |
   ```

   Only the sample PDFs from `conformance/documents/` may appear in it, or in any screenshot you
   add next to it.
2. Open a pull request with that file alone (the rules are in section 7).
3. Open one GitHub issue per problem (`gh issue create`) with the steps, using a sample PDF where
   possible; what you expected and what happened; the Mac, the macOS version and the app version;
   and where the logs are. PaperKnife writes no log file of its own. After a crash, attach the
   report from `~/Library/Logs/DiagnosticReports/` (`PaperKnife-….ips`); for other problems,
   `log show --last 30m --predicate 'process == "PaperKnife"'` may help. Check that nothing you
   attach names or shows a private document.
4. Never put private documents, or screenshots or details of them, in the repository, an issue or
   a pull request.
5. Fix only what is clearly broken, each fix in its own pull request, with a test where possible.
   Everything else goes to the owner as an issue or a question.

## 7. Rules for agents working here

- One pull request per change. Before it is merged, CI must be green and someone who didn't write
  the change (a person or another agent) must review it. Merge with squash.
- A pull request's description starts with the owner's Agent assessment block, then says in plain
  English what changed and how it was checked. The block lies between
  `<!-- copilot-assessment:v1 -->` and `<!-- /copilot-assessment -->`. It holds the heading
  `### Agent assessment`, the line "Self-reported assessment, not an independent review.", the
  full 40-character head SHA as "Assessed revision" (update it after every new commit), and a
  table that scores Change confidence out of 10; bug fixes also score Diagnosis confidence and
  Evidence fit. Each rationale lists ↑ what supports the score and ↓ what is unverified,
  separated by `<br>`, with no `|` inside a cell:

  ```markdown
  <!-- copilot-assessment:v1 -->
  ### Agent assessment

  Self-reported assessment, not an independent review.

  Assessed revision: `<full 40-character head SHA>`

  | Dimension | Assessment | Rationale |
  |---|---|---|
  | Change confidence | 8/10 | ↑ swift test passed on this Mac<br>↓ not tried on Intel |
  <!-- /copilot-assessment -->
  ```

- Never commit secrets, certificates, signing or notarization material, models or build output
  (`.build/`, `artifacts/`, `third_party/pdfium/mac/`, `*.app`, `*.dmg`); `.gitignore` covers
  these.
- Don't build a reduced version of a feature, and don't add extra security measures (such as the
  App Sandbox or new entitlements), without asking the owner.
- State measurements as findings, and ask the owner before drawing conclusions from them.
- This repository's own rules ([CONTRIBUTING.md](../CONTRIBUTING.md)): no network calls,
  telemetry, analytics or ads; edits are verified or refused, never faked; no documents we don't
  own in the repository; the engine follows the Windows engine line by line
  ([docs/PORTING.md](PORTING.md)); `conformance/` changes only by syncing it from
  paperknife-windows; never change `CFBundleIdentifier` in `Resources/Info.plist`; and when a
  shipped dependency changes, update its licenses in `third_party/` and `THIRD_PARTY_NOTICES.md`.
- Commit as `shivam098 <39924466+shivam098@users.noreply.github.com>`.

## 8. Decisions waiting for the owner

1. **Developer ID signing and notarization** ([docs/ROADMAP.md](ROADMAP.md), "Next"). They need a
   paid Apple Developer Program membership. Until then, everyone who downloads PaperKnife has to
   use Open Anyway. Does the owner want to join?
2. **The App Sandbox without network access**, planned together with notarization, so that macOS
   itself keeps PaperKnife offline. Save As writes a temporary copy next to the chosen file,
   which the sandbox doesn't allow as it is ([docs/ARCHITECTURE.md](ARCHITECTURE.md)), so saving
   needs a design choice first.
3. **What comes next** from the roadmap's "Next": the thumbnail sidebar with drag to reorder, or
   extract, merge and split. The engine already has `movePage`, `PdfTools.merge` and
   `PdfTools.extractPages`.
4. **macOS 13 and 14.** The README promises them, but CI has no runner for them and nobody has run
   the app on them. Find a way to test them, or raise the minimum?
5. **The six merged branches** still on GitHub (section 1): delete them? This was offered on
   19 November; no answer is recorded.
