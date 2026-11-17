# DockHack

A tiny menu bar app that keeps the macOS Dock on your **upper** display when it is stacked above the MacBook.

## The problem

With "Displays have separate Spaces" turned on, macOS moves the Dock to whichever display's bottom edge
you push the cursor against. When the external monitor sits *above* the MacBook, its bottom edge is shared
with the MacBook, so the cursor just slides through it. The MacBook's bottom edge is the only real
bottom edge, so the Dock keeps ending up down there and it's hard to get back.

## What DockHack does

1. **Guard.** An event tap swallows mouse-move events in a 6 px strip along the bottom edge of every
   display *except* the anchor display. The Dock never sees the "push against the bottom edge" gesture
   there, so it never jumps to the MacBook. (The cursor still moves normally. Apps just don't get hover
   events in that strip.)
2. **Relocate.** If the Dock still ends up on the wrong display (display reconnect, wake from sleep,
   Dock restart…), a watchdog notices within about 2 s. It warps the cursor to a *free* part of the anchor
   display's bottom edge (where no display sits below it), sends a few synthetic "push down" moves, and
   puts the cursor back. That takes about half a second. If the anchor's whole bottom edge is shared,
   it tries the middle, and after 3 failed attempts it stops retrying until the display setup changes.

The anchor display defaults to **the topmost display**. You can pin a specific one from the menu.

## Build & install

Requires the Xcode command line tools (`swift`).

```bash
./build.sh            # builds, installs to ~/Applications/DockHack.app and launches it
./build.sh --no-install
```

On first launch, grant **Accessibility** permission:
System Settings → Privacy & Security → Accessibility → DockHack.

> The app is ad-hoc signed, so **every rebuild needs Accessibility to be granted again**. Remove the old
> DockHack entry with "–" and turn the new one on.

Turn on "Launch at login" from the menu bar icon.

## Menu

- *Dock is on / Anchored to*: current state
- *Keep Dock on anchor display*: turns the guard and the automatic relocation on or off
- *Move Dock there now*: relocate right away
- *Anchor display*: automatic (topmost) or a specific display
- *Show log*: opens `~/Library/Logs/DockHack.log`

## Requirements / limitations

- The Dock position must be **Bottom**.
- "Displays have separate Spaces" must be **on** (the default). Otherwise the Dock can't move between
  displays at all.
- Hot corners on the bottom corners of the non-anchor display won't fire, because those events are swallowed.

## Debugging

```bash
~/Applications/DockHack.app/Contents/MacOS/DockHack --send status    # log current state
~/Applications/DockHack.app/Contents/MacOS/DockHack --send relocate  # move the Dock now
~/Applications/DockHack.app/Contents/MacOS/DockHack --send disable   # guard off
~/Applications/DockHack.app/Contents/MacOS/DockHack --send selftest  # simulate bumping the lower display's bottom edge
~/Applications/DockHack.app/Contents/MacOS/DockHack --send enable
tail -f ~/Library/Logs/DockHack.log
```
