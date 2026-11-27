# Uninstalling an App with SweetMX

SweetMX can uninstall the app you selected in app search. It moves the app,
and the related files you choose, to Trash. It deletes nothing for good.

This guide has two parts. The first part is for users. The second part is for
maintainers.

## Contents

- [Turn it on](#turn-it-on)
- [What Cmd+U does](#what-cmdu-does)
- [Choose what to move](#choose-what-to-move)
- [Related files](#related-files)
- [What SweetMX never removes](#what-sweetmx-never-removes)
- [Notices](#notices)
- [When your account cannot move the app](#when-your-account-cannot-move-the-app)
- [Apps that are open](#apps-that-are-open)
- [The result view](#the-result-view)
- [How to restore](#how-to-restore)
- [Security promises](#security-promises)
- [For maintainers](#for-maintainers)

## Turn it on

Uninstall is off by default. Its use on a real Mac is not proven yet, so
nobody reaches it by accident. While it is off, `⌘U` does nothing in
SweetMX, and the row menu and the footer do not show it.

To turn it on, run this command in Terminal:

```sh
defaults write com.sagmans.sweetmx Uninstall.enabled -bool true
```

To turn it off again, run this command:

```sh
defaults delete com.sagmans.sweetmx Uninstall.enabled
```

SweetMX reads the setting each time you use it. You do not need to restart
SweetMX.

## What Cmd+U does

Uninstall works in app search only. Clipboard history has no uninstall key.

1. Open app search and select an app.
2. Press `⌘U`. You can also open the context menu of the row and choose
   **Uninstall…**.
3. Read the sheet. It shows the app name, its path, and its size.
4. Choose what to move (see the next section).
5. Press `⌘Return`, or click the button that starts with **Move**.

The button counts what moves, for example **Move 3 items to Trash (140 MB)**.
When a size is not known, the button says **at least** and shows the sum of
the known sizes.

`Return` alone does nothing in this sheet. A removal must be a deliberate act.
Press `Esc` or click **Cancel** to close the sheet. Nothing moves until you
confirm.

When you press `⌘U` while an earlier uninstall still runs, the footer says
"An uninstall is still running." SweetMX runs one uninstall at a time.

After all items reach Trash, the sheet closes. The footer of the launcher says
"Moved 1 item to Trash" or "Moved N items to Trash". The count includes the app.

## Choose what to move

The sheet has a two-way choice named **What to move**.

| Choice | What moves |
| ------ | ---------- |
| **App only** | The app. No related file. |
| **App and all related files** | The app and every related file that is not locked. |

The sheet starts on **App only**. Press `⌘A` to switch between the two
choices. You can also click a segment.

You can also tick related files one by one:

- Press `Up Arrow` or `Down Arrow` to move between the rows.
- Press `Space`, or click a row, to tick or untick it.
- When every row is ticked, `⌘A` unticks all rows.

When you tick some rows but not all, neither segment is selected. Then `⌘A`
selects **App and all related files**.

The choice shows, and `⌘A` works, only when at least one row can be ticked.
A locked row never changes.

The list has two groups. **Also move to Trash** holds the rows you can tick.
**Not removed by SweetMX** holds the locked rows. Each row shows its kind, its
path, and its size. A row that you can tick also shows what removal costs.
A locked row shows its reason. The mark **Matched by name** shows a
row that SweetMX found by the app name. The mark **Listed by Homebrew** shows
a row that came from the Homebrew cleanup list.

## Related files

SweetMX looks for files that the app left in your `~/Library` folder. It
looks only in the folders below. It uses the exact bundle ID of the app, for
example `com.example.sample`.

| Kind | Where | What removal costs |
| ---- | ----- | ------------------ |
| Settings | `Preferences/<bundle ID>.plist` | The app starts with default settings. |
| Cache | `Caches/<bundle ID>` | The app makes it again when needed. |
| Web data | `HTTPStorages/<bundle ID>`, `WebKit/<bundle ID>` | Sessions and site data of the app. A sign-in can be lost. |
| Logs | `Logs/<bundle ID>` | Diagnostic history. |
| App data | `Application Support/<bundle ID>` | Can hold accounts, history and documents. The app cannot make it again. |
| Sandbox data | `Containers/<bundle ID>`, `Application Scripts/<bundle ID>` | Data that macOS keeps for the app in a protected folder. |

The kinds and the cost sentences are the words that the sheet shows.

SweetMX also finds some rows in two other ways:

- **Matched by name.** A folder in `Application Support`, `Caches` or `Logs`
  that has the same name as the app. SweetMX offers it only when the name has
  at least four characters and no other installed app has that name, either
  as its Finder name or as its file name. Otherwise the row is locked.
- **Listed by Homebrew.** The cleanup list of the Homebrew receipt (the `zap`
  entries). SweetMX reads only paths that point one level inside the folders
  in the table or inside `Group Containers`, without wildcards and without
  `..`. You can tick such a row only when its name is exactly the bundle ID
  or the certain app name. A sandbox or `Group Containers` row is always
  locked.

SweetMX reads the size of each row with a limit. When a folder is too large
to read cheaply, the row shows "size unknown".

### Locked rows

A locked row stays on your Mac. The row shows the reason. It also has a
**Show in Finder** button, so you can look at it yourself.

| Reason shown | Why SweetMX locks the row |
| ------------ | ------------------------- |
| The app’s signature does not confirm which files are its own. | The code signature of the app does not match its bundle ID. SweetMX cannot prove who owns the files. |
| Another copy of this app uses these files. | Another app has the same bundle ID, under any name, or SweetMX cannot read its ID. SweetMX reads the ID of every other app in the list and asks macOS for every copy it knows, also outside the app folders. Removal could break that app. |
| Protected by macOS. | The row is in a sandbox folder. macOS guards these folders. SweetMX shows them but never opens them. |
| SweetMX has not finished listing your apps, so it cannot tell whether another app uses these files. | The app list is not ready. SweetMX cannot rule out a second copy. |
| Matches the app name only. Another app can use the same name. | The name is short, or another app has the same name. |

When more than one reason applies, SweetMX shows the first reason in this
table, from the top.

## What SweetMX never removes

| Item | What you see | Why |
| ---- | ------------ | --- |
| An app that is part of macOS | "This app is part of macOS." | It lives under `/System/`. Removal can break macOS. |
| A required Apple app | "macOS needs this Apple app, so SweetMX keeps it." | Every `com.apple.*` app is kept, except the Apple developer tools, GarageBand, iMovie, Keynote, Numbers and Pages. |
| SweetMX itself | "SweetMX cannot remove itself. Move it to Trash in Finder." | An app cannot remove itself safely. |
| A symlinked app | "This is a link to an app. Moving it would remove only the link." | A link can point the removal at another place. |
| An app with an unreadable bundle ID | "SweetMX cannot read which app this is, so it keeps it." | SweetMX cannot find the files of an app it cannot identify. |
| An item that is not an app | "This item is not an app." | Only `.app` folders are accepted. |
| Sandbox data | Locked row, "Protected by macOS." | See the table of locked rows. |
| A folder of `~/Library` itself | Not shown | An item must sit at least two levels below `~/Library`. |
| Anything outside `~/Library` (except the app) | Not shown | The scan reads only the folders in the table of related files. |

For a refused app, the sheet title is “Can’t uninstall “name””. The sheet has
no Move button. It has a **Show in Finder** button.

## Notices

A notice appears above the choice when the app needs more than a move to Trash.

### Installed with Homebrew

SweetMX shows this notice when one Homebrew cask receipt belongs to this very
copy of the app. The notice shows this command:

```bash
brew uninstall --cask <token>
```

The notice says, "This command also updates Homebrew’s records:". You run the
command in Terminal. You can select the text of the command to copy it.
SweetMX never runs this command.

This notice does not block the move. The command also updates the records of
Homebrew, which a move to Trash does not do.

### This app has its own uninstaller

Some apps run background parts that Trash leaves behind. SweetMX knows these
apps:

| App | Result |
| --- | ------ |
| Docker Desktop | Notice with a link. You can still move the app. |
| Karabiner-Elements | Notice with a link. You can still move the app. |
| Little Snitch | Blocked, see the next notice. |

The notice says, "It removes background parts that Trash leaves. Docker Desktop
explains the steps." (with the name of the vendor). The link **Open uninstall
instructions** opens the vendor page in your browser. SweetMX opens `https`
pages only.

### Use Finder or the app’s own uninstaller

SweetMX does not move an app when a half removal does harm. The sheet has no
Move button. The title is “Can’t uninstall “name””.

| Cause | Message |
| ----- | ------- |
| The app holds a system extension, or SweetMX cannot rule one out | "This app installs a system extension. Only its own uninstaller or Finder removes it, so SweetMX does not move this app." |
| The app is security software (Little Snitch) | "This app installs a security component. Only its own uninstaller removes it, so SweetMX does not move this app." |

For security software, the button **Open uninstall instructions** opens the
vendor page. Otherwise the button **Show in Finder** shows the app.

When a block and other notices apply, the block shows first.

## When your account cannot move the app

Some apps sit in a folder that your account cannot write, for example an app
that an administrator installed. Then the sheet shows this line under the
button:

> Your account may need an administrator for this app. If the move fails,
> finish in Finder.

SweetMX does not ask Finder to move the app. No administrator prompt appears
from SweetMX. If the move fails with a permission error, the result view says
so:

> SweetMX does not have permission to move this item. Move it to Trash in
> Finder; Finder asks for an administrator password.

Do these steps:

1. Click **Show in Finder** on the row of the app.
2. In Finder, move the app to Trash.
3. When Finder asks, type an administrator name and password.

The related files that you ticked stay in place. Their rows say, "Kept because
the app did not move." SweetMX keeps them so that you do not get a
half-removed app.

When SweetMX cannot move a related file, its row says, "SweetMX could not move
this item. Move it to Trash in Finder."

## Apps that are open

When the app runs, the sheet says: "“name” is open. SweetMX asks it to quit
first and never forces it."

After you confirm, SweetMX asks the app to quit and waits up to 10 seconds.
An app with an unsaved document can stay open. SweetMX never forces a quit,
because it must not discard your work.

If the app is still open after 10 seconds, nothing moves. The result view
shows "The app did not quit. Quit it and try again." Quit the app yourself
and start the uninstall again.

## The result view

If everything moved, the sheet closes and the footer says so. If one item did
not move, the result view opens. It has the title “Some items were not moved”
and the text "Items that moved are in Trash. The others stay where they are."

Each row has a mark and one sentence:

| Sentence | Meaning |
| -------- | ------- |
| "Moved to Trash." | The item is in Trash. |
| "The item changed after you confirmed, so it was left in place." | The item or the app changed while the sheet was open. |
| "The item is now a link, so it was left in place." | A link replaced the item, or a folder above it. |
| "The item is no longer there." | The item was already gone. |
| "SweetMX does not have permission to move this item. Move it to Trash in Finder; Finder asks for an administrator password." | Your account cannot move the app. See the section above. |
| "SweetMX could not move this item. Move it to Trash in Finder." | Your account cannot move a related file. |
| "Kept because the app did not move." | A related file stays because the app stayed. |
| "The app did not quit. Quit it and try again." | The app was still open after the wait. |
| "macOS protects this item." | The item is protected. |
| "macOS could not move this item." | The system gave another error. |
| "The move stopped before anything moved." | The move was cancelled while the app quit. |

A row that did not move has a **Show in Finder** button, unless the item is
gone. Click **Done** or press `Return` to close the view.

If the launcher closed while the move ran, the move still ends. SweetMX shows
the results the next time you open the launcher.

## How to restore

Everything goes to Trash. Nothing is deleted for good.

1. Open Trash in the Dock.
2. Select the item.
3. In Finder, choose **File → Put Back**.

You can restore items until you empty Trash. The sheet says the same:
"Items go to Trash. You can restore them until you empty it."

## Security promises

- SweetMX never runs as root.
- SweetMX never runs a shell or a script. It runs no `brew` command.
- SweetMX never sees an administrator password. Finder asks for it, and only
  when you move the app in Finder yourself.
- SweetMX moves items to Trash only. The code has no permanent delete.
- SweetMX checks the app and each ticked item again, right before the move.
  It refuses a link, an item outside `~/Library`, and a changed app.
- SweetMX logs the operation, the path (as private data), and the error code.
  It never logs file contents.

## For maintainers

### Where the code lives

| Path | Holds |
| ---- | ----- |
| `Sources/SweetMX/Uninstall/` | The decisions: target, related files, Homebrew receipt, notices, Trash move, policy switch |
| `Sources/SweetMX/UI/UninstallPrompt.swift` | The sheet host and the key rules of the sheet |
| `Sources/SweetMX/UI/UninstallSheetModel.swift` | Every decision of the sheet, without views |
| `Sources/SweetMX/UI/UninstallSheet.swift` | The confirmation view |
| `Sources/SweetMX/UI/UninstallResultSheet.swift` | The result view |
| `Sources/SweetMX/UI/DesignTokens+Uninstall.swift` | The copy, the timeouts and the sizes |
| `Sources/SweetMX/Shell/LauncherPanel.swift` | The `⌘U` key |
| `Sources/SweetMX/UI/ResultsList.swift` | The context menu item |

Put every new sentence for the user in `DesignTokens.Copy`. Each case of an
enum maps to one sentence through an exhaustive `switch`, so a new case fails
to compile until it has text.

### Order of checks

An app passes these steps in this order. A step that fails stops the steps
after it.

1. `UninstallTargetResolver` refuses a link, an app under `/System/`, a path
   that is not an `.app` folder, an unreadable or malformed bundle ID,
   SweetMX itself, and a required Apple app. It also reads the code
   signature and sets `identityConfirmed`.
2. `HomebrewReceipt.find` accepts one receipt only when the Caskroom links to
   this exact copy.
3. `RelatedItemScanner` lists the related files. A second copy is any other
   listed app with the same bundle ID, or any copy that
   `WorkspaceProtocol.urlsForApplications(withBundleIdentifier:)` reports at
   another path. Each row goes through one gate that refuses links and items
   that live elsewhere. The lock order is:
   identity, second copy, protected by macOS, app list not ready, name not
   certain.
4. `UninstallNotice` adds the Homebrew, vendor and blocking notices.
5. `UninstallSheetModel` blocks the sheet for a refusal or a blocking notice.
   Only rows that are ticked and not locked go into the request.
6. `UninstallExecutor` resolves the target again, asks the app to quit and
   waits, resolves the target again, and moves the app. If the app moved, it
   checks each item again (depth, links, location) and moves it.

A process that already runs as the same user can swap a folder for a link
between the last check and the move. It can delete those files anyway, so
this race crosses no privilege boundary.

### Protected folders

For a row in `Containers` or `Application Scripts`, the scan takes one look
at the item without following links (`FileSystemProtocol.itemKind`). It never
reads the size, resolves links or lists inside these folders, because such
reads could make macOS ask for access to the data of another app. It does not
look up `Group Containers` by bundle ID at all: the folders there are named
after group IDs, which are almost never the bundle ID. A Homebrew row in
`Group Containers` is shown locked and is never read.

### Seams

Every decision sits behind a protocol: `FileSystemProtocol`,
`WorkspaceProtocol`, `CodeIdentityProtocol` and `FinderTrashProtocol`.
`UninstallDependencies` gathers them. Tests pass mocks, so no test touches a
real app, the real Trash or the real home folder. See
[TESTING.md](TESTING.md#uninstall-tests).

`WorkspaceProtocol` has no force-quit method. A force quit is impossible
through the type.

### The Finder hand-off

`UninstallPolicy.finderHandOffEnabled` is `false`. The Finder hand-off code
exists behind that switch. It is off because it is not yet proven on a real
Mac, and it must stay off until it is.
