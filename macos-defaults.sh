#!/usr/bin/env bash
# macos-defaults.sh — macOS system preferences set via `defaults write`.
# Source of truth for any setting that has a CLI equivalent. Uncomment/add lines
# as you decide on preferences, then re-run: ./macos-defaults.sh
#
# Anything you toggle in System Settings.app that has NO terminal equivalent
# gets a comment in its section below (and a Phase B dialog in fresh-install.sh),
# not a command.
#
# Some sections below need sudo (Software Update, pmset). You'll get a password
# prompt when the script reaches them — but only if the value isn't already
# correct (see the set_* helpers below), so a clean re-run shouldn't re-prompt.
# A few settings (Keyboard Shortcuts, some Accessibility items) need a logout or
# restart to fully take effect, noted inline.
#
# Every setting is read back before writing (skipped if already correct — safe
# and fast to re-run) and again after (printed as ✓/✗, so a silent failure like
# a wrong key, a TCC block, or a typo doesn't slip by).

set -euo pipefail

# Set to true by any helper/section that actually writes something, so the
# app-restart block at the end only runs when a restart is actually warranted —
# a fully-converged re-run exits without flashing Finder/Dock.
CHANGED=false

# check "description" <command...> — runs the command, prints ✓/✗ based on its
# exit status. Typical usage is `check "desc" test "$have" = "$want"`.
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ✓ ${desc}"
  else
    echo "  ✗ ${desc}"
  fi
}

# set_bool/set_int/set_string/set_float "description" domain key value — skip
# the write if the current value already matches, otherwise write then verify.
set_bool() {
  local desc="$1" domain="$2" key="$3" value="$4"
  local want; [ "$value" = "true" ] && want=1 || want=0
  local have; have="$(defaults read "$domain" "$key" 2>/dev/null || true)"
  if [ "$have" != "$want" ]; then
    defaults write "$domain" "$key" -bool "$value"
    CHANGED=true
    have="$(defaults read "$domain" "$key" 2>/dev/null || true)"
  fi
  check "$desc" test "$have" = "$want"
}

set_int() {
  local desc="$1" domain="$2" key="$3" value="$4"
  local have; have="$(defaults read "$domain" "$key" 2>/dev/null || true)"
  if [ "$have" != "$value" ]; then
    defaults write "$domain" "$key" -int "$value"
    CHANGED=true
    have="$(defaults read "$domain" "$key" 2>/dev/null || true)"
  fi
  check "$desc" test "$have" = "$value"
}

set_string() {
  local desc="$1" domain="$2" key="$3" value="$4"
  local have; have="$(defaults read "$domain" "$key" 2>/dev/null || true)"
  if [ "$have" != "$value" ]; then
    defaults write "$domain" "$key" -string "$value"
    CHANGED=true
    have="$(defaults read "$domain" "$key" 2>/dev/null || true)"
  fi
  check "$desc" test "$have" = "$value"
}

set_float() {
  local desc="$1" domain="$2" key="$3" value="$4"
  local have; have="$(defaults read "$domain" "$key" 2>/dev/null || true)"
  if [ "$have" != "$value" ]; then
    defaults write "$domain" "$key" -float "$value"
    CHANGED=true
    have="$(defaults read "$domain" "$key" 2>/dev/null || true)"
  fi
  check "$desc" test "$have" = "$value"
}

# set_pmset "description" -b|-c "AC Power:"|"Battery Power:" <key> <value>
set_pmset() {
  local desc="$1" flag="$2" source="$3" key="$4" value="$5"
  local have
  have="$(pmset -g custom | awk -v src="$source" -v k="$key" '$0==src{f=1;next} /Power:/{f=0} f && $1==k{print $2}')"
  if [ "$have" != "$value" ]; then
    sudo pmset "$flag" "$key" "$value"
    CHANGED=true
    have="$(pmset -g custom | awk -v src="$source" -v k="$key" '$0==src{f=1;next} /Power:/{f=0} f && $1==k{print $2}')"
  fi
  check "$desc" test "$have" = "$value"
}

echo "Applying macOS defaults..."

# --- Finder ---
# defaults write com.apple.finder AppleShowAllFiles -bool true
# defaults write NSGlobalDomain AppleShowAllExtensions -bool true
# defaults write com.apple.finder ShowPathbar -bool true
# defaults write com.apple.finder ShowStatusBar -bool true

# Default view style: List, for any folder without its own custom view settings.
set_string "Finder default view = List" com.apple.finder FXPreferredViewStyle "Nlsv"

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
  if [ "$("$PB" -c "Print :${vs}:ListViewSettings:sortColumn" "$FINDER_PLIST" 2>/dev/null)" != "dateAdded" ] || \
     [ "$("$PB" -c "Print :${vs}:ListViewSettings:columns:dateAdded:ascending" "$FINDER_PLIST" 2>/dev/null)" != "false" ] || \
     [ "$("$PB" -c "Print :${vs}:ListViewSettings:columns:dateAdded:visible" "$FINDER_PLIST" 2>/dev/null)" != "true" ]; then
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
    CHANGED=true
  fi
done
killall cfprefsd &>/dev/null || true
for vs in FK_StandardViewSettings StandardViewSettings; do
  check "$vs sortColumn = dateAdded" test "$("$PB" -c "Print :${vs}:ListViewSettings:sortColumn" "$FINDER_PLIST" 2>/dev/null)" = "dateAdded"
  check "$vs dateAdded column ascending = false" test "$("$PB" -c "Print :${vs}:ListViewSettings:columns:dateAdded:ascending" "$FINDER_PLIST" 2>/dev/null)" = "false"
  check "$vs dateAdded column visible = true" test "$("$PB" -c "Print :${vs}:ListViewSettings:columns:dateAdded:visible" "$FINDER_PLIST" 2>/dev/null)" = "true"
done
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
set_pmset "Battery disksleep = 10 min" -b "Battery Power:" disksleep 10
set_pmset "AC disksleep = never (0)" -c "AC Power:" disksleep 0

# --- General ---
# Automatic Updates > Install macOS updates = Off. This only disables automatic
# macOS *upgrade* installs specifically — not update checks/downloads generally.
if [ "$(defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates 2>/dev/null)" != "0" ]; then
  sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
  CHANGED=true
fi
check "Automatic macOS upgrade installs = off" test "$(defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates 2>/dev/null)" = "0"

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
set_string "Dark mode enabled" NSGlobalDomain AppleInterfaceStyle "Dark"
set_bool "Auto light/dark switching = off" NSGlobalDomain AppleInterfaceStyleSwitchesAutomatically false
# Liquid Glass = Tinted, and "Tint window background with wallpaper color" = Off:
# NOT scripted. Both are brand-new Tahoe Appearance settings and I couldn't find a
# confirmed defaults key for either (the one Liquid Glass terminal command that
# does exist, com.apple.SwiftUI.DisableSolarium, turns the whole effect off
# entirely rather than choosing Clear vs. Tinted — not what was asked for). Set
# manually: System Settings > Appearance.
# "Show menu bar background" = On: also not scripted, no confirmed key found —
# same Tahoe-Appearance-redesign uncertainty as above. Set manually.
set_string "Scroll bars = Always" NSGlobalDomain AppleShowScrollBars "Always"
set_bool "Click scroll bar to jump to click location" NSGlobalDomain AppleScrollerPagingBehavior true

# --- Menu Bar ---
# Recent documents/applications/servers = None:
set_int "Recent documents limit = 0" NSGlobalDomain NSRecentDocumentsLimit 0
set_int "Recent applications limit = 0" NSGlobalDomain NSRecentApplicationsLimit 0
set_int "Recent servers limit = 0" NSGlobalDomain NSRecentServersLimit 0
# Clock: display time with seconds. Moderate confidence — this key shows up
# consistently across macOS defaults references but I didn't find an authoritative
# primary source; verify at System Settings > Menu Bar > Clock Options.
set_bool "Menu bar clock shows seconds" com.apple.menuextra.clock ShowSeconds true
# Battery: show percentage. Writing both the classic per-item key and the newer
# Control Center one since I'm not certain which one modern macOS actually reads —
# harmless to set both.
set_string "Battery percentage (legacy key)" com.apple.menuextra.battery ShowPercent "YES"
set_bool "Battery percentage (Control Center key)" com.apple.controlcenter BatteryShowPercentage true
# Individual Control Center menu bar items (Ventura+ moved these to
# com.apple.controlcenter as "NSStatusItem Visible <Module>" booleans). Verified
# pattern, but exact module name spelling per item is best-effort beyond the one
# confirmed example (Sound) — check System Settings > Control Center after this
# runs and fix any that didn't take.
set_bool "Control Center: Spotlight hidden" com.apple.controlcenter "NSStatusItem Visible Spotlight" false
set_bool "Control Center: Focus hidden" com.apple.controlcenter "NSStatusItem Visible FocusModes" false
set_bool "Control Center: Screen Mirroring hidden" com.apple.controlcenter "NSStatusItem Visible ScreenMirroring" false
set_bool "Control Center: Display hidden" com.apple.controlcenter "NSStatusItem Visible Display" false
set_bool "Control Center: Sound shown" com.apple.controlcenter "NSStatusItem Visible Sound" true
set_bool "Control Center: Now Playing hidden" com.apple.controlcenter "NSStatusItem Visible NowPlaying" false
set_bool "Control Center: Weather shown" com.apple.controlcenter "NSStatusItem Visible Weather" true

# --- Desktop & Dock: Dock ---
# Size: you said ".25" — read as 25% along the Size slider's pixel range
# (roughly 16-128px), which computes to ~44px. This is a guess at what you meant,
# not a verified conversion — check how it looks and adjust the number below if
# it's off:
set_int "Dock tile size = 44" com.apple.dock tilesize 44
set_string "Dock position = right" com.apple.dock orientation "right"
set_bool "Dock launch animation = off" com.apple.dock launchanim false
set_bool "Dock show recent apps = off" com.apple.dock show-recents false
# "Show items > On Desktop" = Off (desktop icons, distinct from the widgets
# setting already handled in fresh-install.sh step 1):
set_bool "Desktop icons hidden" com.apple.finder CreateDesktop false
# Widgets > Show Widgets > On Desktop = Off: already covered by
# StandardHideWidgets in fresh-install.sh step 1, not duplicated here.

# Window tiling by dragging (macOS 15+). Moderate confidence — found the
# EnableTilingByEdgeDrag key from one source; EnableTopTilingByEdgeDrag
# (menu-bar-fill) is inferred from the same naming pattern, not independently
# confirmed. Verify at System Settings > Desktop & Dock > Windows.
set_int "Tile windows by dragging to screen edges = off" com.apple.WindowManager EnableTilingByEdgeDrag 0
set_int "Tile windows by dragging to menu bar = off" com.apple.WindowManager EnableTopTilingByEdgeDrag 0
# "Drag windows to top of screen to enter Mission Control": NOT scripted, couldn't
# find a confirmed key distinct from the tiling settings above. Set manually.

# --- Desktop & Dock: Mission Control ---
set_bool "Mission Control: don't rearrange Spaces by recent use" com.apple.dock mru-spaces false
set_bool "Mission Control: group windows by app" com.apple.dock expose-group-apps true

# --- Desktop & Dock: Shortcuts (Mission Control / App windows / Show Desktop = none) ---
# These live in com.apple.symbolichotkeys.plist, keyed by numeric shortcut IDs:
# 32 = Mission Control, 33 = Application windows (App Exposé), 36 = Show Desktop.
# Setting "enabled" to false clears the shortcut without touching the feature
# itself. Requires logout (or `killall Dock SystemUIServer`, which this script
# does at the end) to take effect.
HOTKEYS_PLIST="$HOME/Library/Preferences/com.apple.symbolichotkeys.plist"
for hotkeyID in 32 33 36; do
  if [ "$("$PB" -c "Print :AppleSymbolicHotKeys:${hotkeyID}:enabled" "$HOTKEYS_PLIST" 2>/dev/null)" != "false" ]; then
    "$PB" -c "Add :AppleSymbolicHotKeys:${hotkeyID} dict" "$HOTKEYS_PLIST" 2>/dev/null || true
    "$PB" -c "Add :AppleSymbolicHotKeys:${hotkeyID}:enabled bool false" "$HOTKEYS_PLIST" 2>/dev/null || \
      "$PB" -c "Set :AppleSymbolicHotKeys:${hotkeyID}:enabled false" "$HOTKEYS_PLIST"
    CHANGED=true
  fi
done
for hotkeyID in 32 33 36; do
  check "Hotkey ${hotkeyID} cleared" test "$("$PB" -c "Print :AppleSymbolicHotKeys:${hotkeyID}:enabled" "$HOTKEYS_PLIST" 2>/dev/null)" = "false"
done

# --- Desktop & Dock: Hot Corners (all four = no action) ---
set_int "Hot corner top-left = none" com.apple.dock wvous-tl-corner 0
set_int "Hot corner top-right = none" com.apple.dock wvous-tr-corner 0
set_int "Hot corner bottom-left = none" com.apple.dock wvous-bl-corner 0
set_int "Hot corner bottom-right = none" com.apple.dock wvous-br-corner 0

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
set_bool "UI sound effects = off" NSGlobalDomain com.apple.sound.uiaudio.enabled false
set_float "Alert volume = 0" NSGlobalDomain com.apple.sound.beep.volume 0
if [ "$(nvram StartupMute 2>/dev/null | cut -f2)" != "%01" ]; then
  sudo nvram StartupMute=%01
  CHANGED=true
fi
check "Startup chime muted (nvram)" bash -c '[ "$(nvram StartupMute 2>/dev/null | cut -f2)" = "%01" ]'

# --- Notifications ---
# Per-app notification settings (Messages only on, everything else off, Messages
# sub-settings, Alert Style = Persistent, play sound off) and "show when locked":
# NOT scripted. Same issue as the Tips notification-blocking question earlier —
# this lives in ncprefs.plist as an opaque per-app binary blob, not something to
# hand-edit safely. Set manually: System Settings > Notifications.

# --- Lock Screen ---
set_pmset "Battery display sleep = 30 min" -b "Battery Power:" displaysleep 30
set_pmset "AC display sleep = 180 min" -c "AC Power:" displaysleep 180
set_int "Require password after sleep/screensaver" com.apple.screensaver askForPassword 1
set_int "Require password immediately (no delay)" com.apple.screensaver askForPasswordDelay 0
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
set_bool "Fn key: use F1/F2 etc as standard function keys" NSGlobalDomain com.apple.keyboard.fnState true
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
set_bool "Swipe between pages = off" NSGlobalDomain AppleEnableSwipeNavigateWithScrolls false
set_int "3-finger horizontal swipe = off (built-in trackpad)" com.apple.AppleMultitouchTrackpad TrackpadThreeFingerHorizSwipeGesture 0
set_int "3-finger horizontal swipe = off (Bluetooth trackpad)" com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerHorizSwipeGesture 0

# Notification Center (swipe left from right edge with two fingers) = Off:
set_int "2-finger edge swipe (Notification Center) = off (built-in trackpad)" com.apple.AppleMultitouchTrackpad TrackpadTwoFingerFromRightEdgeSwipeGesture 0
set_int "2-finger edge swipe (Notification Center) = off (Bluetooth trackpad)" com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadTwoFingerFromRightEdgeSwipeGesture 0

# App Exposé = swipe down with three fingers. Gesture enabled with reasonable
# confidence; the specific 3-vs-4-finger distinction is lower confidence (my one
# source flags this exact distinction as "not clearly understood" too) — verify
# at System Settings > Trackpad > More Gestures.
set_bool "App Exposé gesture enabled" com.apple.dock showAppExposeGestureEnabled true
set_int "3-finger vertical swipe = App Exposé (built-in trackpad)" com.apple.AppleMultitouchTrackpad TrackpadThreeFingerVertSwipeGesture 2
set_int "3-finger vertical swipe = App Exposé (Bluetooth trackpad)" com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerVertSwipeGesture 2

# --- Screenshots ---
# mkdir -p "${HOME}/Screenshots"
# defaults write com.apple.screencapture location -string "${HOME}/Screenshots"
# defaults write com.apple.screencapture type -string "png"

# --- Safari / Chrome / other app-specific defaults ---
#

if [ "$CHANGED" = true ]; then
  echo "Restarting affected apps..."
  for app in "Finder" "Dock" "SystemUIServer"; do
    killall "${app}" &>/dev/null || true
  done
  killall cfprefsd &>/dev/null || true
else
  echo "Nothing changed — skipping app restarts."
fi

echo "Done. Some settings (Keyboard Shortcuts, a few Accessibility items) may need"
echo "a full logout/login to visibly take effect."
