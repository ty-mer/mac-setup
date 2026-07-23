#!/usr/bin/env bash
# macos-defaults.sh — macOS system preferences set via `defaults write`.
# Source of truth for any setting that has a CLI equivalent. Uncomment/add lines
# as you decide on preferences, then re-run: ./macos-defaults.sh
#
# Anything you toggle in System Settings.app that has NO terminal equivalent
# belongs in SETUP-LOG.md instead, not here.
#
# Some sections below need sudo (Software Update, pmset). You'll get a password
# prompt when the script reaches them. A few settings (Keyboard Shortcuts, some
# Accessibility items) need a logout or restart to fully take effect, noted inline.

set -euo pipefail

echo "Applying macOS defaults..."

# --- Finder ---
# defaults write com.apple.finder AppleShowAllFiles -bool true
# defaults write NSGlobalDomain AppleShowAllExtensions -bool true
# defaults write com.apple.finder ShowPathbar -bool true
# defaults write com.apple.finder ShowStatusBar -bool true

# Default view style: List, for any folder without its own custom view settings.
defaults write com.apple.finder FXPreferredViewStyle -string "Nlsv"

# Default sort within List view: Date Added, descending (newest at top). This is
# the same thing "Show View Options > Sort By: Date Added > Use as Defaults" does
# in the Finder UI, replicated via the underlying plist structure. sortColumn picks
# the active sort column; each column's own "ascending" flag controls its direction
# when active. Both StandardViewSettings and FK_StandardViewSettings get set since
# different macOS versions/contexts read one or the other.
FINDER_PLIST="$HOME/Library/Preferences/com.apple.finder.plist"
killall cfprefsd &>/dev/null || true   # flush any cached state before direct edits
PB="/usr/libexec/PlistBuddy"
for vs in FK_StandardViewSettings StandardViewSettings; do
  "$PB" -c "Add :${vs} dict" "$FINDER_PLIST" 2>/dev/null || true
  "$PB" -c "Add :${vs}:ListViewSettings dict" "$FINDER_PLIST" 2>/dev/null || true
  "$PB" -c "Add :${vs}:ListViewSettings:sortColumn string dateAdded" "$FINDER_PLIST" 2>/dev/null || \
    "$PB" -c "Set :${vs}:ListViewSettings:sortColumn dateAdded" "$FINDER_PLIST"
  "$PB" -c "Add :${vs}:ListViewSettings:columns dict" "$FINDER_PLIST" 2>/dev/null || true
  "$PB" -c "Add :${vs}:ListViewSettings:columns:dateAdded dict" "$FINDER_PLIST" 2>/dev/null || true
  "$PB" -c "Add :${vs}:ListViewSettings:columns:dateAdded:ascending bool false" "$FINDER_PLIST" 2>/dev/null || \
    "$PB" -c "Set :${vs}:ListViewSettings:columns:dateAdded:ascending false" "$FINDER_PLIST"
  "$PB" -c "Add :${vs}:ListViewSettings:columns:dateAdded:visible bool true" "$FINDER_PLIST" 2>/dev/null || \
    "$PB" -c "Set :${vs}:ListViewSettings:columns:dateAdded:visible true" "$FINDER_PLIST"
  "$PB" -c "Add :${vs}:ListViewSettings:columns:dateAdded:width integer 181" "$FINDER_PLIST" 2>/dev/null || true
done
killall cfprefsd &>/dev/null || true
# Note: this only governs folders that have never had their own view settings
# saved (no per-folder .DS_Store override) — on a fresh account every folder
# qualifies. If a specific folder still looks wrong later, it has its own saved
# view options that take precedence; fix it via that folder's View Options panel.

# --- Battery ---
# Energy Mode (Automatic / Low Power / High Power) is a newer System Settings
# control (macOS 14.5+) — could NOT find a confirmed pmset/defaults equivalent
# despite checking, so left unscripted. Set manually: System Settings > Battery >
# Energy Mode. On battery = Automatic, on power adapter = High Power.
#
# "Put hard disks to sleep when possible" — Only on Battery. This one IS pmset
# (disksleep = minutes idle before spinning down; mostly a legacy HDD setting,
# harmless on SSDs). Enabled (10 min) on battery, disabled (never) on AC:
sudo pmset -b disksleep 10
sudo pmset -c disksleep 0

# --- General ---
# Automatic Updates > Install macOS updates = Off. This only disables automatic
# macOS *upgrade* installs specifically — not update checks/downloads generally.
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false

# --- Accessibility: Vision > Motion ---
# Reduce motion, auto-play animated images: NOT scripted. Both live under
# com.apple.universalaccess, which is TCC-protected — `defaults write` against
# it fails outright without Terminal having Full Disk Access, and that
# permission doesn't apply retroactively to an already-running process, so
# granting it mid-script wouldn't even help the run that's already in progress.
# Not worth the hassle for four toggles total (this section + Display below) —
# set by hand at System Settings > Accessibility > Motion.

# --- Accessibility: Vision > Display ---
# Reduce transparency, show window title icons: same com.apple.universalaccess
# issue as above — set by hand at System Settings > Accessibility > Display.

# --- Appearance ---
# Dark mode:
defaults write NSGlobalDomain AppleInterfaceStyle -string "Dark"
defaults write NSGlobalDomain AppleInterfaceStyleSwitchesAutomatically -bool false
# Liquid Glass = Tinted, and "Tint window background with wallpaper color" = Off:
# NOT scripted. Both are brand-new Tahoe Appearance settings and I couldn't find a
# confirmed defaults key for either (the one Liquid Glass terminal command that
# does exist, com.apple.SwiftUI.DisableSolarium, turns the whole effect off
# entirely rather than choosing Clear vs. Tinted — not what was asked for). Set
# manually: System Settings > Appearance.
# "Show menu bar background" = On: also not scripted, no confirmed key found —
# same Tahoe-Appearance-redesign uncertainty as above. Set manually.
defaults write NSGlobalDomain AppleShowScrollBars -string "Always"
defaults write NSGlobalDomain AppleScrollerPagingBehavior -bool true

# --- Menu Bar ---
# Recent documents/applications/servers = None:
defaults write NSGlobalDomain NSRecentDocumentsLimit -int 0
defaults write NSGlobalDomain NSRecentApplicationsLimit -int 0
defaults write NSGlobalDomain NSRecentServersLimit -int 0
# Clock: display time with seconds. Moderate confidence — this key shows up
# consistently across macOS defaults references but I didn't find an authoritative
# primary source; verify at System Settings > Menu Bar > Clock Options.
defaults write com.apple.menuextra.clock ShowSeconds -bool true
# Battery: show percentage. Writing both the classic per-item key and the newer
# Control Center one since I'm not certain which one modern macOS actually reads —
# harmless to set both.
defaults write com.apple.menuextra.battery ShowPercent -string "YES"
defaults write com.apple.controlcenter BatteryShowPercentage -bool true
# Individual Control Center menu bar items (Ventura+ moved these to
# com.apple.controlcenter as "NSStatusItem Visible <Module>" booleans). Verified
# pattern, but exact module name spelling per item is best-effort beyond the one
# confirmed example (Sound) — check System Settings > Control Center after this
# runs and fix any that didn't take.
defaults write com.apple.controlcenter "NSStatusItem Visible Spotlight" -bool false
defaults write com.apple.controlcenter "NSStatusItem Visible FocusModes" -bool false
defaults write com.apple.controlcenter "NSStatusItem Visible ScreenMirroring" -bool false
defaults write com.apple.controlcenter "NSStatusItem Visible Display" -bool false
defaults write com.apple.controlcenter "NSStatusItem Visible Sound" -bool true
defaults write com.apple.controlcenter "NSStatusItem Visible NowPlaying" -bool false
defaults write com.apple.controlcenter "NSStatusItem Visible Weather" -bool true

# --- Desktop & Dock: Dock ---
# Size: you said ".25" — read as 25% along the Size slider's pixel range
# (roughly 16-128px), which computes to ~44px. This is a guess at what you meant,
# not a verified conversion — check how it looks and adjust the number below if
# it's off:
defaults write com.apple.dock tilesize -int 44
defaults write com.apple.dock orientation -string "right"
defaults write com.apple.dock launchanim -bool false
defaults write com.apple.dock show-recents -bool false
# "Show items > On Desktop" = Off (desktop icons, distinct from the widgets
# setting already handled in fresh-install.sh step 1):
defaults write com.apple.finder CreateDesktop -bool false
# Widgets > Show Widgets > On Desktop = Off: already covered by
# StandardHideWidgets in fresh-install.sh step 1, not duplicated here.

# Window tiling by dragging (macOS 15+). Moderate confidence — found the
# EnableTilingByEdgeDrag key from one source; EnableTopTilingByEdgeDrag
# (menu-bar-fill) is inferred from the same naming pattern, not independently
# confirmed. Verify at System Settings > Desktop & Dock > Windows.
defaults write com.apple.WindowManager EnableTilingByEdgeDrag -int 0
defaults write com.apple.WindowManager EnableTopTilingByEdgeDrag -int 0
# "Drag windows to top of screen to enter Mission Control": NOT scripted, couldn't
# find a confirmed key distinct from the tiling settings above. Set manually.

# --- Desktop & Dock: Mission Control ---
defaults write com.apple.dock mru-spaces -bool false
defaults write com.apple.dock expose-group-apps -bool true

# --- Desktop & Dock: Shortcuts (Mission Control / App windows / Show Desktop = none) ---
# These live in com.apple.symbolichotkeys.plist, keyed by numeric shortcut IDs:
# 32 = Mission Control, 33 = Application windows (App Exposé), 36 = Show Desktop.
# Setting "enabled" to false clears the shortcut without touching the feature
# itself. Requires logout (or `killall Dock SystemUIServer`, which this script
# does at the end) to take effect.
HOTKEYS_PLIST="$HOME/Library/Preferences/com.apple.symbolichotkeys.plist"
for hotkeyID in 32 33 36; do
  "$PB" -c "Add :AppleSymbolicHotKeys:${hotkeyID} dict" "$HOTKEYS_PLIST" 2>/dev/null || true
  "$PB" -c "Add :AppleSymbolicHotKeys:${hotkeyID}:enabled bool false" "$HOTKEYS_PLIST" 2>/dev/null || \
    "$PB" -c "Set :AppleSymbolicHotKeys:${hotkeyID}:enabled false" "$HOTKEYS_PLIST"
done

# --- Desktop & Dock: Hot Corners (all four = no action) ---
defaults write com.apple.dock wvous-tl-corner -int 0
defaults write com.apple.dock wvous-tr-corner -int 0
defaults write com.apple.dock wvous-bl-corner -int 0
defaults write com.apple.dock wvous-br-corner -int 0

# --- Spotlight ---
# "Show Related Content", "Help Apple Improve Search", and the granular
# Results-from-Apps/Results-from-System category toggles (only Calculator,
# Dictionary, System Settings on; only Apps on, etc.): NOT scripted. Category
# names for the newer per-source toggles aren't confidently confirmed (the
# orderedItems mechanism is documented for the *older* Spotlight category list,
# but I couldn't verify it maps cleanly onto the current System Settings > Spotlight
# UI, and getting 10+ individual category flags wrong silently is worse than just
# doing this by hand once). Set manually: System Settings > Spotlight.

# --- Sound ---
defaults write NSGlobalDomain com.apple.sound.uiaudio.enabled -bool false
defaults write NSGlobalDomain com.apple.sound.beep.volume -float 0
sudo nvram StartupMute=%01

# --- Notifications ---
# Per-app notification settings (Messages only on, everything else off, Messages
# sub-settings, Alert Style = Persistent, play sound off) and "show when locked":
# NOT scripted. Same issue as the Tips notification-blocking question earlier —
# this lives in ncprefs.plist as an opaque per-app binary blob, not something to
# hand-edit safely. Set manually: System Settings > Notifications.

# --- Lock Screen ---
sudo pmset -b displaysleep 30
sudo pmset -c displaysleep 180
defaults write com.apple.screensaver askForPassword -int 1
defaults write com.apple.screensaver askForPasswordDelay -int 0
# "Show user name and photo" = Off: NOT scripted. This is the Lock/wake screen's
# own toggle, distinct from the login window's SHOWFULLNAME setting (which is a
# different screen), and I don't have a confirmed key for it. Set manually.

# --- Privacy & Security ---
# Wired Accessories > Allow accessories to connect = Automatically allow when
# unlocked: NOT scripted. The only documented terminal/defaults path
# (allowUSBRestrictedMode under com.apple.applicationaccess) is explicitly an
# MDM-managed restriction, not a plain user preference — same "requires real MDM
# enrollment" situation as the Brave default-search-engine policy earlier. Set
# manually: System Settings > Privacy & Security > Wired Accessories.

# --- Game Center ---
# Turning off / signing out: NOT scripted. This is Apple ID/CloudKit session
# state, not a static preference — sign out manually via System Settings >
# Game Center.

# --- Keyboard ---
# defaults write NSGlobalDomain KeyRepeat -int 2
# defaults write NSGlobalDomain InitialKeyRepeat -int 15
# defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false
defaults write NSGlobalDomain com.apple.keyboard.fnState -bool true
# Caps Lock > No Action: NOT scripted. Modifier-key remapping is stored per
# physical keyboard (keyed by vendor/product ID), so there's no single static key
# to write — and the `hidutil`-based session remap that does exist doesn't persist
# across reboots without a separate LaunchDaemon, plus it doesn't necessarily match
# what System Settings' own toggle writes internally. Set manually: System
# Settings > Keyboard > Keyboard Shortcuts > Modifier Keys, for each keyboard you
# use (the built-in one and any external ones — this is per-device).

# --- Trackpad ---
# defaults write com.apple.AppleMultitouchTrackpad Clicking -bool true
# defaults write NSGlobalDomain com.apple.trackpad.scaling -float 1.5

# "Look up & data detectors" = Off: NOT scripted. Even the reference I found for
# trackpad gesture keys flags this one as "conditions not clearly understood" —
# not confident enough to write a value I can't verify. Set manually.

# Swipe between pages = Off:
defaults write NSGlobalDomain AppleEnableSwipeNavigateWithScrolls -bool false
defaults write com.apple.AppleMultitouchTrackpad TrackpadThreeFingerHorizSwipeGesture -int 0
defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerHorizSwipeGesture -int 0

# Notification Center (swipe left from right edge with two fingers) = Off:
defaults write com.apple.AppleMultitouchTrackpad TrackpadTwoFingerFromRightEdgeSwipeGesture -int 0
defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadTwoFingerFromRightEdgeSwipeGesture -int 0

# App Exposé = swipe down with three fingers. Gesture enabled with reasonable
# confidence; the specific 3-vs-4-finger distinction is lower confidence (my one
# source flags this exact distinction as "not clearly understood" too) — verify
# at System Settings > Trackpad > More Gestures.
defaults write com.apple.dock showAppExposeGestureEnabled -bool true
defaults write com.apple.AppleMultitouchTrackpad TrackpadThreeFingerVertSwipeGesture -int 2
defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerVertSwipeGesture -int 2

# --- Screenshots ---
# mkdir -p "${HOME}/Screenshots"
# defaults write com.apple.screencapture location -string "${HOME}/Screenshots"
# defaults write com.apple.screencapture type -string "png"

# --- Safari / Chrome / other app-specific defaults ---
#

echo "Restarting affected apps..."
for app in "Finder" "Dock" "SystemUIServer"; do
  killall "${app}" &>/dev/null || true
done
killall cfprefsd &>/dev/null || true

echo "Done. Some settings (Keyboard Shortcuts, a few Accessibility items) may need"
echo "a full logout/login to visibly take effect."
