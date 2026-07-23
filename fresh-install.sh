#!/usr/bin/env bash
# fresh-install.sh — orchestrator for setting up a clean macOS install.
#
# Structure:
#   PHASE A — fully automated. No prompts, no app-switching. Runs top to bottom.
#   PHASE B — guided manual steps. Each step is a dialog with "Open" (jumps to the
#             relevant app/pane, can be clicked more than once) and "Done" (advances
#             to the next step). Steps are grouped by app, then by section within
#             that app, so you never have to bounce back and forth between the same
#             app twice. When adding new steps later: fully-automated ones go in
#             Phase A; anything needing a click/login/permission grant goes in
#             Phase B, filed under the right app group (respecting any real
#             order-of-operations dependency), not just appended at the end.
#
# Usage: ./fresh-install.sh

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Fresh install script ==="

# ---------------------------------------------------------------------------
# prompt_step — guided-step dialog helper for Phase B.
#
#   prompt_step "Title" "Message" ["open target"]
#
# If an open target is given (a URL, an x-apple.systempreferences: deep link,
# or a path to a .app bundle), the dialog shows two buttons: "Open" and
# "Done". Clicking "Open" runs `open <target>` and re-shows the same dialog
# (so you can click it again if you need to get back to that pane) without
# advancing the script. Clicking "Done" closes the dialog and lets the script
# move on to the next step. "Done" is the default button (Enter key), so
# pressing Enter never accidentally re-triggers the open.
#
# If no open target is given, the dialog just shows a single "Done" button —
# for steps where the relevant window/dialog already opened itself as a side
# effect of the previous command (e.g. macOS's own default-browser prompt).
# ---------------------------------------------------------------------------
prompt_step() {
  local title="$1" message="$2" target="${3:-}"
  local esc_title="${title//\"/\\\"}"
  local esc_message="${message//\"/\\\"}"

  if [ -n "$target" ]; then
    while true; do
      local button
      button="$(osascript <<APPLESCRIPT
display dialog "${esc_message}" with title "${esc_title}" buttons {"Open", "Done"} default button "Done"
button returned of result
APPLESCRIPT
)"
      if [ "$button" = "Open" ]; then
        open "$target" 2>/dev/null || true
        continue
      fi
      break
    done
  else
    osascript -e "display dialog \"${esc_message}\" with title \"${esc_title}\" buttons {\"Done\"} default button \"Done\"" >/dev/null
  fi
}

# ---------------------------------------------------------------------------
# prompt_masapp_step — confirm-then-attempt installer for paid Mac App Store
# apps (Logic Pro, Final Cut Pro).
#
#   prompt_masapp_step "Title" "App Name" <mas-id> "macappstore://..." "~6GB"
#
# `mas` has no way to check whether an app is purchased without attempting
# the actual install — it fails fast (no download) if you don't own it, but
# starts the full download immediately if you do. So this always asks first:
# "Install" attempts `mas install` right then (and shows a follow-up Done-only
# dialog reporting success or failure); "Skip" does nothing and moves on.
# ---------------------------------------------------------------------------
prompt_masapp_step() {
  local title="$1" app_name="$2" app_id="$3" store_url="$4" size_hint="$5"
  local esc_title="${title//\"/\\\"}"
  local ask_message="Install ${app_name} if it's purchased on this Apple ID? (~${size_hint} download if you own it — fails instantly if not. Make sure you're signed into the App Store first.)"
  local esc_ask="${ask_message//\"/\\\"}"

  local button
  button="$(osascript <<APPLESCRIPT
display dialog "${esc_ask}" with title "${esc_title}" buttons {"Skip", "Install"} default button "Skip"
button returned of result
APPLESCRIPT
)"
  if [ "$button" != "Install" ]; then
    return
  fi

  echo "Attempting to install ${app_name} (mas id ${app_id})..."
  if mas install "${app_id}"; then
    osascript -e "display dialog \"${app_name} installed.\" with title \"${esc_title}\" buttons {\"Done\"} default button \"Done\"" >/dev/null
  else
    prompt_step "${title} — Not Installed" \
      "Couldn't install ${app_name} — you may not own it on this Apple ID, might not be signed in, or something else went wrong. Click Open to check the App Store page yourself." \
      "${store_url}"
  fi
}

# =============================================================================
# PHASE A — fully automated
# =============================================================================
echo ""
echo "--- Phase A: automated setup ---"

# A1. Clear Dock and hide desktop widgets
echo "Clearing Dock and hiding desktop widgets..."
defaults write com.apple.dock persistent-apps -array
defaults write com.apple.dock persistent-others -array
defaults write com.apple.WindowManager StandardHideWidgets -bool true
defaults write com.apple.WindowManager StageManagerHideWidgets -bool true
killall Dock 2>/dev/null || true
# Note: StandardHideWidgets/StageManagerHideWidgets HIDE widgets, they don't delete
# them individually — there's no reliable terminal command for that (the widget
# config plist is TCC-protected). If you want specific widgets gone rather than
# all of them hidden, remove them manually via Edit Widgets.

# A2. Disable Tips (com.apple.tipsd) — before installing anything else, so it
# never gets a chance to notify you about apps/features while you're mid-setup.
launchctl bootout "gui/$(id -u)/com.apple.tipsd" 2>/dev/null || true
launchctl disable "gui/$(id -u)/com.apple.tipsd" 2>/dev/null || true
# To reverse: launchctl enable "gui/$(id -u)/com.apple.tipsd"

# A3. Xcode Command Line Tools (needed for Homebrew, git, etc.)
if ! xcode-select -p &>/dev/null; then
  echo "Installing Xcode Command Line Tools..."
  xcode-select --install
  echo "Waiting for the Xcode Command Line Tools install to finish (a separate GUI"
  echo "installer window should have opened) — this script will keep polling and"
  echo "continue automatically once it's done. No need to re-run anything."
  until xcode-select -p &>/dev/null; do
    sleep 5
  done
  echo "Xcode Command Line Tools installed."
fi

# A4. Homebrew
if ! command -v brew &>/dev/null; then
  echo "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# A5. Packages from Brewfile
echo "Installing packages from Brewfile..."
brew bundle --file="${DIR}/Brewfile"

# A6. macOS system defaults
echo "Applying macOS defaults..."
bash "${DIR}/macos-defaults.sh"

# A7. Brave — everything scriptable with zero clicks (policies, prefs, headless
# profile init). Setting Brave as default browser and opening it for sign-in
# both require you to look at the screen, so those are Phase B steps instead.
if [ -d "/Applications/Brave Browser.app" ]; then
  echo "Configuring Brave (automated policies)..."

  # Disable autoplay globally. Real Chromium/Brave managed policy
  # (AutoplayAllowed) — applies even before Brave's first launch.
  defaults write com.brave.Browser AutoplayAllowed -bool false

  # Telemetry: disable P3A analytics, the daily stats ping, and Web Discovery.
  defaults write com.brave.Browser BraveP3AEnabled -string "Disabled"
  defaults write com.brave.Browser BraveStatsPingEnabled -bool false
  defaults write com.brave.Browser BraveWebDiscoveryEnabled -bool false

  # Optional features: disable Rewards, Wallet, VPN promo, and AI Chat (Leo).
  defaults write com.brave.Browser BraveRewardsDisabled -bool true
  defaults write com.brave.Browser BraveWalletDisabled -bool true
  defaults write com.brave.Browser BraveVPNDisabled -bool true
  defaults write com.brave.Browser BraveAIChatEnabled -bool false

  # Password manager: disable Brave's own entirely — no reads from it, no
  # writes to it. On a brand new profile there's nothing saved yet, so this
  # fully blocks both saving new passwords and autofill from Brave's store.
  defaults write com.brave.Browser PasswordManagerEnabled -bool false

  # iCloud Passwords extension: force-install it via mandatory managed policy
  # so it's ready without a manual "Add extension" click. Signing into it is
  # still a Phase B step (see the Brave group below).
  ICLOUD_PASSWORDS_EXT_ID="pejdijmoenmkgeppbflobdenhhabjlaj"
  MANAGED_DIR="/Library/Managed Preferences"
  MANAGED_PLIST="${MANAGED_DIR}/com.brave.Browser.plist"
  echo "Installing iCloud Passwords extension (admin password required)..."
  sudo mkdir -p "$MANAGED_DIR"
  sudo chown root:wheel "$MANAGED_DIR"
  sudo chmod 755 "$MANAGED_DIR"
  sudo /usr/libexec/PlistBuddy -c "Add :ExtensionInstallForcelist array" "$MANAGED_PLIST" 2>/dev/null || true
  sudo /usr/libexec/PlistBuddy -c "Add :ExtensionInstallForcelist:0 string ${ICLOUD_PASSWORDS_EXT_ID};https://clients2.google.com/service/update2/crx" "$MANAGED_PLIST" 2>/dev/null || \
    sudo /usr/libexec/PlistBuddy -c "Set :ExtensionInstallForcelist:0 ${ICLOUD_PASSWORDS_EXT_ID};https://clients2.google.com/service/update2/crx" "$MANAGED_PLIST"
  sudo killall cfprefsd 2>/dev/null || true

  # Enable "Cycle through the most recently used tabs with Ctrl-Tab" by
  # patching Brave's profile JSON directly — needs a profile to exist first,
  # so force one via a headless, invisible launch.
  BRAVE_APP="/Applications/Brave Browser.app"
  BRAVE_PREFS="$HOME/Library/Application Support/BraveSoftware/Brave-Browser/Default/Preferences"

  if [ ! -f "$BRAVE_PREFS" ]; then
    echo "Launching Brave headlessly once to initialize its profile..."
    "$BRAVE_APP/Contents/MacOS/Brave Browser" --headless --disable-gpu --no-first-run about:blank &>/dev/null &
    BRAVE_PID=$!
    for i in $(seq 1 20); do
      [ -f "$BRAVE_PREFS" ] && break
      sleep 1
    done
    kill "$BRAVE_PID" 2>/dev/null || true
    killall "Brave Browser" 2>/dev/null || true
    sleep 1
  fi

  if [ -f "$BRAVE_PREFS" ] && command -v jq &>/dev/null; then
    killall "Brave Browser" 2>/dev/null || true
    sleep 1
    tmp="$(mktemp)"
    jq '.brave.mru_cycling_enabled = true' "$BRAVE_PREFS" > "$tmp" && mv "$tmp" "$BRAVE_PREFS"
    echo "Ctrl-Tab MRU cycling enabled."
  else
    echo "Could not initialize Brave's profile automatically — enable Ctrl-Tab MRU"
    echo "manually at brave://settings/braveContent."
  fi
fi

# A8. Clipy preferences — replicated from this machine's config on 2026-07-22
# (`defaults read com.clipy-app.Clipy`). All plain prefs writes, no clicking.
if [ -d "/Applications/Clipy.app" ]; then
  echo "Configuring Clipy (automated preferences)..."
  defaults write com.clipy-app.Clipy addNumericKeyEquivalents -bool true
  defaults write com.clipy-app.Clipy kCPYBetaObserveScreenshot -bool true
  defaults write com.clipy-app.Clipy kCPYPrefMaxHistorySizeKey -int 90
  defaults write com.clipy-app.Clipy kCPYPrefNumberOfItemsPlaceInlineKey -int 10
  defaults write com.clipy-app.Clipy loginItem -bool true

  CLIPY_PLIST="$HOME/Library/Preferences/com.clipy-app.Clipy.plist"
  killall cfprefsd 2>/dev/null || true
  PB="/usr/libexec/PlistBuddy"
  "$PB" -c "Add :kCPYPrefStoreTypesKey dict" "$CLIPY_PLIST" 2>/dev/null || true
  for storeType in Filenames PDF RTF RTFD String TIFF URL; do
    "$PB" -c "Add :kCPYPrefStoreTypesKey:${storeType} bool true" "$CLIPY_PLIST" 2>/dev/null || \
      "$PB" -c "Set :kCPYPrefStoreTypesKey:${storeType} true" "$CLIPY_PLIST"
  done
  killall cfprefsd 2>/dev/null || true

  # Keyboard shortcuts: leave Main as whatever Clipy ships with, clear History,
  # Snippet, and Clear History. Confirmed against Clipy's own source
  # (HotKeyService.swift / Constants.swift): a shortcut is "unset" when its key
  # is simply absent, so `defaults delete` is correct here, not an empty value.
  defaults delete com.clipy-app.Clipy kCPYHotKeyHistoryKeyCombo 2>/dev/null || true
  defaults delete com.clipy-app.Clipy kCPYHotKeySnippetKeyCombo 2>/dev/null || true
  defaults delete com.clipy-app.Clipy kCPYClearHistoryKeyCombo 2>/dev/null || true
fi

echo ""
echo "Phase A complete: apps installed, all scriptable preferences applied."

# =============================================================================
# PHASE B — guided manual steps (one at a time, grouped by app)
# =============================================================================
echo ""
echo "--- Phase B: guided manual steps ---"
echo "A dialog will appear for each step. Click Open to jump to the right place,"
echo "then Done when you've finished that step, to move to the next one."

# --- Brave ---
if [ -d "/Applications/Brave Browser.app" ]; then

  if command -v defaultbrowser &>/dev/null; then
    defaultbrowser brave
    prompt_step "Brave — Default Browser" \
      "macOS just showed a confirmation dialog asking to make Brave your default browser. Click \"Use Brave Browser\" on it, then click Done here."
  fi

  prompt_step "Brave — Kagi Search Engine" \
    "Install the Kagi Search extension from the Chrome Web Store, pin it, then log into Kagi. (Not scripted: Brave's default-search policy only works with real MDM enrollment.) Click Open for the extension page." \
    "https://chromewebstore.google.com/detail/kagi-search-for-chrome/cpeeggjhicnjfkjkkegblnadobhikphd"

  prompt_step "Brave — iCloud Passwords Sign-In" \
    "The iCloud Passwords extension was force-installed already. Open its icon in the toolbar and sign in with your Apple ID. Click Open to bring Brave forward." \
    "/Applications/Brave Browser.app"

  prompt_step "Brave — Gmail Sign-In" \
    "Sign into ty1470@gmail.com. Once you're signed into iCloud Passwords it can offer to autofill, but entering credentials/2FA is on you. Click Open to go to Gmail." \
    "https://mail.google.com/"
fi

# --- Clipy ---
if [ -d "/Applications/Clipy.app" ]; then
  prompt_step "Clipy — Accessibility Permission" \
    "Grant Clipy Accessibility permission, then launch Clipy once (it needs a first launch to register itself as a login item and pick up its hotkeys). Click Open for the Accessibility settings pane." \
    "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"
fi

# --- Scroll Reverser ---
if [ -d "/Applications/Scroll Reverser.app" ]; then
  prompt_step "Scroll Reverser — Accessibility Permission" \
    "Grant Scroll Reverser Accessibility permission. Click Open for the Accessibility settings pane." \
    "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"

  prompt_step "Scroll Reverser — Input Monitoring Permission" \
    "Grant Scroll Reverser Input Monitoring permission, then launch it and set your preferred scroll-reversal options. Click Open for the Privacy & Security settings pane, then choose Input Monitoring from the list." \
    "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
fi

# --- Keyboard Maestro ---
if [ -d "/Applications/Keyboard Maestro.app" ]; then
  prompt_step "Keyboard Maestro — License Activation" \
    "Launch Keyboard Maestro and activate your license (or start the trial). Click Open to launch it." \
    "/Applications/Keyboard Maestro.app"

  prompt_step "Keyboard Maestro — Accessibility Permission" \
    "Grant Accessibility permission to both Keyboard Maestro and Keyboard Maestro Engine (two separate entries in the list). Click Open for the Accessibility settings pane." \
    "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"

  prompt_step "Keyboard Maestro — Input Monitoring Permission" \
    "Grant Keyboard Maestro Engine Input Monitoring permission. Click Open for the Privacy & Security settings pane, then choose Input Monitoring from the list." \
    "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"

  prompt_step "Keyboard Maestro — Macro Sync" \
    "In Keyboard Maestro's preferences, go to the Syncing tab, choose \"Start Syncing Macros,\" then \"Open Existing Synchronized Macros,\" and select: ~/Library/Mobile Documents/com~apple~CloudDocs/Google Drive/Keyboard Maestro Macros.kmsync. (Not scripted — destructive/versioned, no safe preference key.) Click Open to launch Keyboard Maestro." \
    "/Applications/Keyboard Maestro.app"
fi

# --- App Store ---
if command -v mas &>/dev/null; then
  prompt_step "App Store — Sign In" \
    "Sign into the App Store with your Apple ID — needed before either install below will work. Click Open to launch the App Store." \
    "macappstore://"

  prompt_masapp_step "App Store — Logic Pro" "Logic Pro" "634148309" \
    "macappstore://apps.apple.com/app/id634148309" "6GB"

  prompt_masapp_step "App Store — Final Cut Pro" "Final Cut Pro" "424389933" \
    "macappstore://apps.apple.com/app/id424389933" "4GB"
fi

# --- System Settings (everything with no scriptable equivalent, grouped by pane) ---

prompt_step "System Settings — Battery" \
  "Energy Mode: On battery = Automatic, on power adapter = High Power. (No confirmed pmset/defaults equivalent for this macOS 14.5+ control.) Click Open for Battery settings." \
  "x-apple.systempreferences:com.apple.Battery-Settings.extension"

prompt_step "System Settings — Appearance" \
  "Liquid Glass = Tinted. Tint window background with wallpaper color = Off. (Both are new Tahoe controls with no confirmed defaults key.) Click Open for Appearance settings." \
  "x-apple.systempreferences:com.apple.Appearance-Settings.extension"

prompt_step "System Settings — Menu Bar" \
  "Show menu bar background = On. (No confirmed defaults key.) Click Open for Menu Bar / Control Center settings." \
  "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"

prompt_step "System Settings — Desktop & Dock" \
  "Drag windows to top of screen to enter Mission Control = Off. (Distinct from the window-tiling keys already scripted; no confirmed key found for this one specifically.) Click Open for Desktop & Dock settings." \
  "x-apple.systempreferences:com.apple.Dock-Settings.extension"

prompt_step "System Settings — Spotlight" \
  "Show Related Content = Off. Help Apple Improve Search = Off. Results from Apps: only Calculator, Dictionary, System Settings on. Results from System: only Apps on. (Granular per-category keys not confidently confirmed for the current UI.) Click Open for Spotlight settings." \
  "x-apple.systempreferences:com.apple.Spotlight-Settings.extension"

prompt_step "System Settings — Wallpaper" \
  "Dynamic Wallpapers > Macintosh, set to Dark. Color = Dark Gray. Clock Appearance: show large clock On Screen Saver and Lock Screen. Click Open for Wallpaper settings." \
  "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"

prompt_step "System Settings — Notifications" \
  "Show notifications when screen is locked = Off. Application Notifications: only Messages on (Desktop only, everything else off within Messages), Alert Style = Persistent, play sound = Off, everything else off. (Lives in ncprefs.plist as an opaque per-app blob — not safely scriptable.) Click Open for Notifications settings." \
  "x-apple.systempreferences:com.apple.Notifications-Settings.extension"

prompt_step "System Settings — Lock Screen" \
  "Show user name and photo = Off. (Distinct from the login window's SHOWFULLNAME setting; no confirmed key for this one.) Click Open for Lock Screen settings." \
  "x-apple.systempreferences:com.apple.LockScreen-Settings.extension"

prompt_step "System Settings — Privacy & Security" \
  "Wired Accessories > Allow accessories to connect = Automatically allow when unlocked. (The only documented terminal path is MDM-only.) Click Open for Privacy & Security settings." \
  "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"

prompt_step "System Settings — Game Center" \
  "Sign out of Game Center. (Apple ID/CloudKit session state, not a static preference.) Click Open for Game Center settings." \
  "x-apple.systempreferences:com.apple.GameCenter-Settings.extension"

prompt_step "System Settings — Keyboard" \
  "Caps Lock = No Action, for each keyboard you use (built-in + any external — this is stored per physical keyboard, no single key to script). Click Open for Keyboard settings." \
  "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"

prompt_step "System Settings — Trackpad" \
  "Look up & data detectors = Off. (Flagged even in the reference source as poorly understood — not confident enough to script.) Click Open for Trackpad settings." \
  "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"

# ---------------------------------------------------------------------------
echo ""
echo "Phase B complete. See SETUP-LOG.md for anything outside this script's scope"
echo "(App Store apps, licensed software, dotfiles, dev environment, etc.)."
