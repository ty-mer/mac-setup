#!/usr/bin/env bash
# fresh-install.sh — orchestrator for setting up a clean macOS install.
#
# Two kinds of step:
#   AUTOMATED — no prompts, no app-switching (the A1..A9 steps).
#   GUIDED    — a dialog with "Open" (jumps to the relevant app/pane, can be
#               clicked more than once) and "Done" (advances). Grouped by app/
#               pane so you never bounce between the same place twice.
#
# The two are interleaved on purpose, to overlap your manual time with the long
# downloads instead of idling:
#   1. Instant local tweaks (Dock, Tips).
#   2. Kick off the Xcode Command Line Tools install — but don't wait.
#   3. WHILE it downloads: apply macOS defaults and walk through the System
#      Settings toggles (none of this needs the tools or Homebrew).
#   4. Barrier — wait for the Command Line Tools to finish.
#   5. Homebrew, the Brewfile, and each app's automated config.
#   6. Per-app guided sign-ins and permission grants (needs the apps installed).
#
# When adding steps later: automated ones with no download dependency can join
# step 3; anything needing Homebrew-installed apps goes in step 5/6.
#
# Usage: ./fresh-install.sh

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Phase B has no reliable OS-checkable state for any of its steps — most are
# manual because there's no defaults key or TCC permission state isn't readable
# without Full Disk Access, and the ones that looked checkable in principle
# (`defaultbrowser`, `mas account`, `mas list`) turned out not to be either:
# `defaultbrowser` doesn't mark the current default in its own output, `mas
# account` doesn't exist in the installed mas version, and `mas list` depends
# on Spotlight indexing that isn't populated yet on a fresh account. So instead
# of checking reality, we remember which step titles you've already completed,
# in $HOME so it survives across re-downloads of this script.
PHASE_B_STATE_FILE="$HOME/.mac-setup-phase-b-done"
touch "$PHASE_B_STATE_FILE"

echo "=== Fresh install script ==="

# ---------------------------------------------------------------------------
# check "description" <command...> — runs the command, prints ✓/✗ based on its
# exit status. Typical usage is `check "desc" test "$(defaults read ...)" = "expected"`.
# ---------------------------------------------------------------------------
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ✓ ${desc}"
  else
    echo "  ✗ ${desc}"
  fi
}

# set_bool/set_int/set_string "description" domain key value — skip the write
# if the current value already matches (avoids unnecessary re-writes, and for
# sudo-gated domains, unnecessary repeat password prompts on a re-run),
# otherwise write then verify.
set_bool() {
  local desc="$1" domain="$2" key="$3" value="$4"
  local want; [ "$value" = "true" ] && want=1 || want=0
  local have; have="$(defaults read "$domain" "$key" 2>/dev/null || true)"
  if [ "$have" != "$want" ]; then
    defaults write "$domain" "$key" -bool "$value"
    have="$(defaults read "$domain" "$key" 2>/dev/null || true)"
  fi
  check "$desc" test "$have" = "$want"
}

set_int() {
  local desc="$1" domain="$2" key="$3" value="$4"
  local have; have="$(defaults read "$domain" "$key" 2>/dev/null || true)"
  if [ "$have" != "$value" ]; then
    defaults write "$domain" "$key" -int "$value"
    have="$(defaults read "$domain" "$key" 2>/dev/null || true)"
  fi
  check "$desc" test "$have" = "$value"
}

set_string() {
  local desc="$1" domain="$2" key="$3" value="$4"
  local have; have="$(defaults read "$domain" "$key" 2>/dev/null || true)"
  if [ "$have" != "$value" ]; then
    defaults write "$domain" "$key" -string "$value"
    have="$(defaults read "$domain" "$key" 2>/dev/null || true)"
  fi
  check "$desc" test "$have" = "$value"
}

# focus_terminal — bring Terminal back to the front. Used before Terminal-side
# output/prompts (e.g. a mas install's download progress) that a preceding GUI
# step may have pushed behind another window. Assumes Terminal.app, since this
# targets fresh macOS installs where that's the default (and the .command
# launcher opens in it).
focus_terminal() {
  osascript -e 'tell application "Terminal" to activate' 2>/dev/null || true
}

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
#
# Skips itself entirely (no dialog) if this exact title was already marked
# done in $PHASE_B_STATE_FILE on a previous run — see the comment above that
# file's definition for why a marker instead of a real check.
# ---------------------------------------------------------------------------

# show_step_dialog "Title" "Message" ["open target"] — shows the guided-step
# dialog (Open/Done loop if a target is given, Done-only otherwise) and blocks
# until "Done". Does NOT touch the state file — that's prompt_step's job. Split
# out so contingent one-off dialogs (e.g. an install-failure fallback) can
# reuse the exact dialog behavior without being recorded as a completed step.
show_step_dialog() {
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

prompt_step() {
  local title="$1" message="$2" target="${3:-}"

  if grep -qxF "$title" "$PHASE_B_STATE_FILE" 2>/dev/null; then
    echo "  (already done: ${title})"
    return
  fi

  show_step_dialog "$title" "$message" "$target"

  echo "$title" >> "$PHASE_B_STATE_FILE"
}

# ---------------------------------------------------------------------------
# prompt_masapp_step — confirm-then-attempt installer for paid Mac App Store
# apps (Logic Pro, Final Cut Pro).
#
#   prompt_masapp_step "Title" "App Name" <mas-id> "macappstore://..." "~6GB"
#
# `mas` has no way to check whether an app is purchased without attempting
# the actual install — it fails fast (no download) if you don't own it, but
# starts the full download immediately if you do. So this always asks first,
# with three choices:
#   "Install"  — attempts `mas install` right then (and shows a follow-up
#                Done-only dialog reporting success or failure).
#   "Not Now"  — does nothing this run; the step is offered again next run.
#   "Never"    — records the step as done so it's never offered again, for an
#                app you don't own or don't want.
#
# Skips the dialog entirely if already marked done in $PHASE_B_STATE_FILE.
# Only a genuine successful `mas install` OR an explicit "Never" marks it done;
# "Not Now" and a failed install both leave it unmarked (unlike prompt_step,
# `mas list` can't be trusted to check real installed state — see the comment
# on $PHASE_B_STATE_FILE's definition).
# ---------------------------------------------------------------------------
prompt_masapp_step() {
  local title="$1" app_name="$2" app_id="$3" store_url="$4" size_hint="$5"
  local esc_title="${title//\"/\\\"}"

  if grep -qxF "$title" "$PHASE_B_STATE_FILE" 2>/dev/null; then
    echo "  (already done: ${title})"
    return
  fi

  local ask_message="Install ${app_name} if it's purchased on this Apple ID? (~${size_hint} download if you own it — fails instantly if not. Make sure you're signed into the App Store first.) \"Not Now\" asks again next run; \"Never\" stops asking."
  local esc_ask="${ask_message//\"/\\\"}"

  local button
  button="$(osascript <<APPLESCRIPT
display dialog "${esc_ask}" with title "${esc_title}" buttons {"Never", "Not Now", "Install"} default button "Not Now"
button returned of result
APPLESCRIPT
)"
  case "$button" in
    Install) ;;  # fall through to the install attempt below
    Never)
      echo "$title" >> "$PHASE_B_STATE_FILE"
      return
      ;;
    *)  # "Not Now" — leave unmarked so it's offered again next run
      return
      ;;
  esac

  # Bring Terminal forward so the download progress (and any auth prompt) is
  # visible — a prior step's "Open" may have left it behind another window.
  focus_terminal
  echo "Attempting to install ${app_name} (mas id ${app_id})..."
  if mas install "${app_id}"; then
    osascript -e "display dialog \"${app_name} installed.\" with title \"${esc_title}\" buttons {\"Done\"} default button \"Done\"" >/dev/null
    echo "$title" >> "$PHASE_B_STATE_FILE"
  else
    # Use show_step_dialog, not prompt_step: this contingent failure notice
    # must never be recorded as done, or a later retry that fails again would
    # silently suppress it.
    show_step_dialog "${title} — Not Installed" \
      "Couldn't install ${app_name} — you may not own it on this Apple ID, might not be signed in, or something else went wrong. Click Open to check the App Store page yourself." \
      "${store_url}"
  fi
}

# =============================================================================
# Setup begins. The run is ordered to overlap your manual time with the long
# Command Line Tools download (see the header comment): instant local tweaks,
# then kick off that install and do all the no-download work (macOS defaults +
# the System Settings walk-through) while it runs, then Homebrew + apps + the
# per-app sign-ins once the tools and apps are in place.
# =============================================================================
echo ""
echo "--- Local setup ---"

# A1. Clear Dock and hide desktop widgets
echo "Clearing Dock and hiding desktop widgets..."
NEED_DOCK_KILL=false
if [ "$(defaults read com.apple.dock persistent-apps 2>/dev/null | tr -d '[:space:]')" != "()" ]; then
  defaults write com.apple.dock persistent-apps -array
  NEED_DOCK_KILL=true
fi
if [ "$(defaults read com.apple.dock persistent-others 2>/dev/null | tr -d '[:space:]')" != "()" ]; then
  defaults write com.apple.dock persistent-others -array
  NEED_DOCK_KILL=true
fi
# Widget changes need the Dock restart too — pre-check them before set_bool so
# a change here also triggers the kill below.
if [ "$(defaults read com.apple.WindowManager StandardHideWidgets 2>/dev/null)" != "1" ] || \
   [ "$(defaults read com.apple.WindowManager StageManagerHideWidgets 2>/dev/null)" != "1" ]; then
  NEED_DOCK_KILL=true
fi
set_bool "Desktop widgets hidden" com.apple.WindowManager StandardHideWidgets true
set_bool "Stage Manager widgets hidden" com.apple.WindowManager StageManagerHideWidgets true
[ "$NEED_DOCK_KILL" = true ] && killall Dock 2>/dev/null || true
check "Dock persistent apps cleared" test "$(defaults read com.apple.dock persistent-apps 2>/dev/null | tr -d '[:space:]')" = "()"
check "Dock persistent others cleared" test "$(defaults read com.apple.dock persistent-others 2>/dev/null | tr -d '[:space:]')" = "()"
# Note: StandardHideWidgets/StageManagerHideWidgets HIDE widgets, they don't delete
# them individually — there's no reliable terminal command for that (the widget
# config plist is TCC-protected). If you want specific widgets gone rather than
# all of them hidden, remove them manually via Edit Widgets.

# A2. Disable Tips (com.apple.tipsd) — before installing anything else, so it
# never gets a chance to notify you about apps/features while you're mid-setup.
launchctl bootout "gui/$(id -u)/com.apple.tipsd" 2>/dev/null || true
launchctl disable "gui/$(id -u)/com.apple.tipsd" 2>/dev/null || true
check "Tips daemon not running" bash -c '! launchctl list 2>/dev/null | grep -q com.apple.tipsd'
# To reverse: launchctl enable "gui/$(id -u)/com.apple.tipsd"

# --- Kick off the Xcode Command Line Tools install, but don't wait yet ---
# The tools are needed for Homebrew, but nothing between here and the Homebrew
# barrier below needs them — so we start the install now and do the built-in
# macOS setup (defaults + the System Settings walk-through) while it downloads,
# instead of idling on a progress bar. An already-set-up machine skips straight
# past the barrier.
CLT_INSTALLING=false
if ! xcode-select -p &>/dev/null; then
  echo "Starting the Xcode Command Line Tools install..."
  echo "A GUI installer will open — click Install. No need to wait for it; keep"
  echo "going with the steps below and it'll finish while you do them."
  xcode-select --install 2>/dev/null || true
  CLT_INSTALLING=true
fi

echo ""
if [ "$CLT_INSTALLING" = true ]; then
  echo "--- System preferences (while the Command Line Tools install) ---"
else
  echo "--- System preferences ---"
fi

# macOS system defaults — all built-in tools (defaults/pmset/PlistBuddy/nvram),
# no Homebrew needed, so this runs during the download. Executed as a subprocess
# under this script's set -e; guard so an unexpected non-zero exit can't abort
# the run. It prints its own per-setting checks.
echo "Applying macOS defaults..."
focus_terminal
bash "${DIR}/macos-defaults.sh" || true

# --- System Settings (everything with no scriptable equivalent, grouped by pane) ---
# These are guided dialogs: click Open to jump to the pane, make the changes,
# then Done to advance. Do them now while the Command Line Tools finish
# installing in the background.
echo "Next: a series of System Settings dialogs. Click Open on each to jump to"
echo "the pane, make the changes, then Done to move on."

prompt_step "System Settings — Battery" \
  $'Click Open for Battery settings, then set Energy Mode:\n\n•  On Battery — Automatic\n•  On Power Adapter — High Power' \
  "x-apple.systempreferences:com.apple.Battery-Settings.extension"

prompt_step "System Settings — Accessibility (Display)" \
  $'Click Open for Accessibility settings, then set:\n\n•  Reduce Transparency — On\n•  Show window title icons — On' \
  "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"

prompt_step "System Settings — Accessibility (Motion)" \
  $'Click Open for Accessibility settings, then set:\n\n•  Reduce Motion — On\n•  Auto-play animated images — Off' \
  "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"

prompt_step "System Settings — Appearance" \
  "Click Open for Appearance settings, then turn off Tint window background with wallpaper color." \
  "x-apple.systempreferences:com.apple.Appearance-Settings.extension"

prompt_step "System Settings — Menu Bar" \
  "Click Open for Control Center settings, then set Show menu bar background — On." \
  "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"

prompt_step "System Settings — Desktop & Dock" \
  "Click Open for Desktop & Dock settings, then turn off: Drag windows to top of screen to enter Mission Control." \
  "x-apple.systempreferences:com.apple.Desktop-Settings.extension"

prompt_step "System Settings — Spotlight" \
  $'Click Open for Spotlight settings, then set:\n\n•  Show Related Content — Off\n•  Help Apple Improve Search — Off\n•  Results from Apps — only Calculator, Dictionary, System Settings on\n•  Results from System — only Apps on' \
  "x-apple.systempreferences:com.apple.Spotlight-Settings.extension"

prompt_step "System Settings — Wallpaper" \
  $'Click Open for Wallpaper settings, then set:\n\n•  Dynamic Wallpaper — Macintosh, set to Dark\n•  Color — Dark Gray\n•  Clock — show large clock on Screen Saver and Lock Screen' \
  "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"

prompt_step "System Settings — Notifications" \
  $'Click Open for Notifications settings, then set:\n\n•  Show notifications when locked — Off\n•  Turn off every app except Messages\n•  In Messages — Desktop only, Alert Style Persistent, play sound Off, everything else off' \
  "x-apple.systempreferences:com.apple.Notifications-Settings.extension"

prompt_step "System Settings — Lock Screen" \
  "Click Open for Lock Screen settings, then set Show user name and photo — Off." \
  "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension"

prompt_step "System Settings — Privacy & Security" \
  "Click Open for Privacy & Security settings, then under Wired Accessories set Allow accessories to connect — Automatically when unlocked." \
  "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"

prompt_step "System Settings — Game Center" \
  "Click Open for Game Center settings, then sign out." \
  "x-apple.systempreferences:com.apple.Game-Center-Settings.extension"

prompt_step "System Settings — Keyboard" \
  $'Click Open for Keyboard settings, then click "Keyboard Shortcuts…" and choose Modifier Keys — the last item in the list, after Function Keys. Set the Caps Lock Key to No Action.\n\nUse the keyboard selector at the top to repeat this for each keyboard you use — the built-in one and any external keyboards.' \
  "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"

prompt_step "System Settings — Trackpad" \
  "Click Open for Trackpad settings, then turn off Look up & data detectors." \
  "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"

# --- Barrier: Homebrew needs the Command Line Tools ---
if [ "$CLT_INSTALLING" = true ]; then
  echo ""
  echo "Making sure the Command Line Tools install has finished..."
  until xcode-select -p &>/dev/null; do
    sleep 5
  done
fi
check "Xcode Command Line Tools installed" xcode-select -p

echo ""
echo "--- Installing Homebrew and apps ---"

# A4. Homebrew
if ! command -v brew &>/dev/null; then
  echo "Installing Homebrew..."
  # We run the installer with NONINTERACTIVE=1 (so it doesn't hang on its own
  # "press RETURN to continue" prompt). A side effect: in that mode Homebrew
  # verifies sudo access with `sudo -n` (non-interactive), which fails on a
  # fresh Mac that has no cached sudo credential yet — and Homebrew reports
  # that failure as a misleading "needs to be an Administrator" error even for
  # admin accounts. Prime the credential cache first so that check passes —
  # but only if it isn't already primed (`sudo -n -v` succeeds silently when a
  # valid cached credential exists), so a quick re-run doesn't re-prompt.
  if ! sudo -n -v 2>/dev/null; then
    echo "Homebrew needs administrator access. Enter your login password if prompted."
    if ! sudo -v; then
      echo "Could not obtain administrator access — this account must be an" >&2
      echo "Administrator to install Homebrew. Fix that, then re-run." >&2
      exit 1
    fi
  fi
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi
check "Homebrew installed" command -v brew

# The installer prints shellenv instructions but doesn't act on them — add it to
# .zprofile ourselves so brew (and anything it installs) is on PATH in new
# shells too. Checked unconditionally (not just on fresh install above) so a
# re-run still fixes this even if brew was already present from an earlier
# attempt.
if ! grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null; then
  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
fi
check ".zprofile has brew shellenv" grep -q 'brew shellenv' "$HOME/.zprofile"

# A5. Packages from Brewfile
echo "Installing packages from Brewfile..."
# Don't let one failed/interrupted formula or cask abort the rest of Phase A —
# the check below reports the real state, and a re-run retries anything missing.
brew bundle --file="${DIR}/Brewfile" || true
check "All Brewfile packages installed" brew bundle check --file="${DIR}/Brewfile"

# A6. Brave — everything scriptable with zero clicks (policies, prefs, headless
# profile init). Setting Brave as default browser and opening it for sign-in
# both require you to look at the screen, so those are Phase B steps instead.
if [ -d "/Applications/Brave Browser.app" ]; then
  echo "Configuring Brave (automated policies)..."

  # Disable autoplay globally. Real Chromium/Brave managed policy
  # (AutoplayAllowed) — applies even before Brave's first launch.
  set_bool "Brave autoplay disabled" com.brave.Browser AutoplayAllowed false

  # Telemetry: disable P3A analytics, the daily stats ping, and Web Discovery.
  set_string "Brave P3A analytics disabled" com.brave.Browser BraveP3AEnabled "Disabled"
  set_bool "Brave stats ping disabled" com.brave.Browser BraveStatsPingEnabled false
  set_bool "Brave Web Discovery disabled" com.brave.Browser BraveWebDiscoveryEnabled false

  # Optional features: disable Rewards, Wallet, VPN promo, and AI Chat (Leo).
  set_bool "Brave Rewards disabled" com.brave.Browser BraveRewardsDisabled true
  set_bool "Brave Wallet disabled" com.brave.Browser BraveWalletDisabled true
  set_bool "Brave VPN promo disabled" com.brave.Browser BraveVPNDisabled true
  set_bool "Brave AI Chat (Leo) disabled" com.brave.Browser BraveAIChatEnabled false

  # Password manager: disable Brave's own entirely — no reads from it, no
  # writes to it. On a brand new profile there's nothing saved yet, so this
  # fully blocks both saving new passwords and autofill from Brave's store.
  set_bool "Brave's own password manager disabled" com.brave.Browser PasswordManagerEnabled false

  # iCloud Passwords extension: force-install it via mandatory managed policy
  # so it's ready without a manual "Add extension" click. Signing into it is
  # still a Phase B step (see the Brave group below).
  ICLOUD_PASSWORDS_EXT_ID="pejdijmoenmkgeppbflobdenhhabjlaj"
  MANAGED_DIR="/Library/Managed Preferences"
  MANAGED_PLIST="${MANAGED_DIR}/com.brave.Browser.plist"
  # The plist is root-owned but world-readable (644), so reading it needs no
  # sudo — a re-run where the policy is already set skips the whole sudo chain
  # below without ever prompting for a password.
  if ! /usr/libexec/PlistBuddy -c "Print :ExtensionInstallForcelist:0" "$MANAGED_PLIST" 2>/dev/null | grep -q "$ICLOUD_PASSWORDS_EXT_ID"; then
    echo "Installing iCloud Passwords extension (admin password required)..."
    sudo mkdir -p "$MANAGED_DIR"
    sudo chown root:wheel "$MANAGED_DIR"
    sudo chmod 755 "$MANAGED_DIR"
    sudo /usr/libexec/PlistBuddy -c "Add :ExtensionInstallForcelist array" "$MANAGED_PLIST" 2>/dev/null || true
    sudo /usr/libexec/PlistBuddy -c "Add :ExtensionInstallForcelist:0 string ${ICLOUD_PASSWORDS_EXT_ID};https://clients2.google.com/service/update2/crx" "$MANAGED_PLIST" 2>/dev/null || \
      sudo /usr/libexec/PlistBuddy -c "Set :ExtensionInstallForcelist:0 ${ICLOUD_PASSWORDS_EXT_ID};https://clients2.google.com/service/update2/crx" "$MANAGED_PLIST"
    sudo killall cfprefsd 2>/dev/null || true
  fi
  check "iCloud Passwords extension installed" \
    bash -c "/usr/libexec/PlistBuddy -c 'Print :ExtensionInstallForcelist:0' '${MANAGED_PLIST}' 2>/dev/null | grep -q '${ICLOUD_PASSWORDS_EXT_ID}'"

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

  # Beyond MRU cycling: toolbar/UI preferences, shields-by-default toggles,
  # download prompt, and vertical tabs — all pulled from this machine's own
  # Brave config on 2026-07-23.
  #
  # Decide whether to rewrite by comparing VALUES, not file bytes: Brave writes
  # Preferences as compact single-line JSON while jq pretty-prints, so a byte
  # comparison would always differ and needlessly rewrite + kill Brave on every
  # run. `jq -e` exits 0 only if every target key already holds its value (a
  # missing key compares as null != target, so it correctly counts as needing
  # an update).
  if [ -f "$BRAVE_PREFS" ] && command -v jq &>/dev/null; then
    if ! jq -e '
        (.brave.mru_cycling_enabled == true) and
        (.brave.enable_window_closing_confirm == false) and
        (.brave.show_bookmarks_button == false) and
        (.brave.show_side_panel_button == false) and
        (.brave.location_bar_is_wide == false) and
        (.brave.top_site_suggestions_enabled == false) and
        (.brave.wayback_machine_enabled == true) and
        (.brave.no_script_default == false) and
        (.brave.fb_embed_default == false) and
        (.brave.twitter_embed_default == false) and
        (.brave.google_login_default == false) and
        (.download.prompt_for_download == false) and
        (.brave.tabs.vertical_tabs_enabled == true) and
        (.brave.tabs.vertical_tabs_floating_enabled == true) and
        (.brave.tabs.vertical_tabs_show_scrollbar == true)
      ' "$BRAVE_PREFS" >/dev/null 2>&1; then
      tmp="$(mktemp)"
      jq '.brave.mru_cycling_enabled = true
        | .brave.enable_window_closing_confirm = false
        | .brave.show_bookmarks_button = false
        | .brave.show_side_panel_button = false
        | .brave.location_bar_is_wide = false
        | .brave.top_site_suggestions_enabled = false
        | .brave.wayback_machine_enabled = true
        | .brave.no_script_default = false
        | .brave.fb_embed_default = false
        | .brave.twitter_embed_default = false
        | .brave.google_login_default = false
        | .download.prompt_for_download = false
        | .brave.tabs.vertical_tabs_enabled = true
        | .brave.tabs.vertical_tabs_floating_enabled = true
        | .brave.tabs.vertical_tabs_show_scrollbar = true' "$BRAVE_PREFS" > "$tmp"
      killall "Brave Browser" 2>/dev/null || true
      sleep 1
      mv "$tmp" "$BRAVE_PREFS"
      echo "Brave preferences updated (tabs, toolbar, shields defaults, downloads)."
    fi

    check "Ctrl-Tab MRU cycling enabled" test "$(jq -r '.brave.mru_cycling_enabled' "$BRAVE_PREFS" 2>/dev/null)" = "true"
    check "Window-closing confirmation off" test "$(jq -r '.brave.enable_window_closing_confirm' "$BRAVE_PREFS" 2>/dev/null)" = "false"
    check "Bookmarks bar button hidden" test "$(jq -r '.brave.show_bookmarks_button' "$BRAVE_PREFS" 2>/dev/null)" = "false"
    check "Side panel button hidden" test "$(jq -r '.brave.show_side_panel_button' "$BRAVE_PREFS" 2>/dev/null)" = "false"
    check "Wide location bar off" test "$(jq -r '.brave.location_bar_is_wide' "$BRAVE_PREFS" 2>/dev/null)" = "false"
    check "New Tab top site suggestions off" test "$(jq -r '.brave.top_site_suggestions_enabled' "$BRAVE_PREFS" 2>/dev/null)" = "false"
    check "Wayback Machine offer enabled" test "$(jq -r '.brave.wayback_machine_enabled' "$BRAVE_PREFS" 2>/dev/null)" = "true"
    check "NoScript-by-default off" test "$(jq -r '.brave.no_script_default' "$BRAVE_PREFS" 2>/dev/null)" = "false"
    check "Facebook embeds-by-default off" test "$(jq -r '.brave.fb_embed_default' "$BRAVE_PREFS" 2>/dev/null)" = "false"
    check "Twitter embeds-by-default off" test "$(jq -r '.brave.twitter_embed_default' "$BRAVE_PREFS" 2>/dev/null)" = "false"
    check "Google login embeds-by-default off" test "$(jq -r '.brave.google_login_default' "$BRAVE_PREFS" 2>/dev/null)" = "false"
    check "Downloads don't prompt for save location" test "$(jq -r '.download.prompt_for_download' "$BRAVE_PREFS" 2>/dev/null)" = "false"
    check "Vertical tabs enabled" test "$(jq -r '.brave.tabs.vertical_tabs_enabled' "$BRAVE_PREFS" 2>/dev/null)" = "true"
    check "Vertical tabs floating mode enabled" test "$(jq -r '.brave.tabs.vertical_tabs_floating_enabled' "$BRAVE_PREFS" 2>/dev/null)" = "true"
    check "Vertical tabs scrollbar shown" test "$(jq -r '.brave.tabs.vertical_tabs_show_scrollbar' "$BRAVE_PREFS" 2>/dev/null)" = "true"
  else
    echo "Could not initialize Brave's profile automatically — enable these"
    echo "preferences manually at brave://settings/braveContent and"
    echo "brave://settings/appearance (vertical tabs)."
  fi
fi

# A7. Clipy preferences — replicated from this machine's config on 2026-07-22
# (`defaults read com.clipy-app.Clipy`). All plain prefs writes, no clicking.
if [ -d "/Applications/Clipy.app" ]; then
  echo "Configuring Clipy (automated preferences)..."
  set_bool "Clipy numeric key equivalents enabled" com.clipy-app.Clipy addNumericKeyEquivalents true
  set_bool "Clipy beta screenshot capture enabled" com.clipy-app.Clipy kCPYBetaObserveScreenshot true
  set_int "Clipy history cap = 90" com.clipy-app.Clipy kCPYPrefMaxHistorySizeKey 90
  set_int "Clipy inline menu items = 10" com.clipy-app.Clipy kCPYPrefNumberOfItemsPlaceInlineKey 10
  set_bool "Clipy launch at login enabled" com.clipy-app.Clipy loginItem true

  CLIPY_PLIST="$HOME/Library/Preferences/com.clipy-app.Clipy.plist"
  PB="/usr/libexec/PlistBuddy"
  NEED_STORE_TYPES_WRITE=false
  for storeType in Filenames PDF RTF RTFD String TIFF URL; do
    if [ "$("$PB" -c "Print :kCPYPrefStoreTypesKey:${storeType}" "$CLIPY_PLIST" 2>/dev/null)" != "true" ]; then
      NEED_STORE_TYPES_WRITE=true
    fi
  done
  if [ "$NEED_STORE_TYPES_WRITE" = true ]; then
    killall cfprefsd 2>/dev/null || true
    "$PB" -c "Add :kCPYPrefStoreTypesKey dict" "$CLIPY_PLIST" 2>/dev/null || true
    for storeType in Filenames PDF RTF RTFD String TIFF URL; do
      "$PB" -c "Add :kCPYPrefStoreTypesKey:${storeType} bool true" "$CLIPY_PLIST" 2>/dev/null || \
        "$PB" -c "Set :kCPYPrefStoreTypesKey:${storeType} true" "$CLIPY_PLIST"
    done
    killall cfprefsd 2>/dev/null || true
  fi
  for storeType in Filenames PDF RTF RTFD String TIFF URL; do
    check "Clipy stores ${storeType}" test "$("$PB" -c "Print :kCPYPrefStoreTypesKey:${storeType}" "$CLIPY_PLIST" 2>/dev/null)" = "true"
  done

  # Keyboard shortcuts: leave Main as whatever Clipy ships with, clear History,
  # Snippet, and Clear History. Confirmed against Clipy's own source
  # (HotKeyService.swift / Constants.swift): a shortcut is "unset" when its key
  # is simply absent, so `defaults delete` is correct here, not an empty value.
  defaults delete com.clipy-app.Clipy kCPYHotKeyHistoryKeyCombo 2>/dev/null || true
  defaults delete com.clipy-app.Clipy kCPYHotKeySnippetKeyCombo 2>/dev/null || true
  defaults delete com.clipy-app.Clipy kCPYClearHistoryKeyCombo 2>/dev/null || true
  check "Clipy History shortcut cleared" bash -c '! defaults read com.clipy-app.Clipy kCPYHotKeyHistoryKeyCombo &>/dev/null'
  check "Clipy Snippet shortcut cleared" bash -c '! defaults read com.clipy-app.Clipy kCPYHotKeySnippetKeyCombo &>/dev/null'
  check "Clipy Clear History shortcut cleared" bash -c '! defaults read com.clipy-app.Clipy kCPYClearHistoryKeyCombo &>/dev/null'
fi

# A8. Scroll Reverser preferences — app-owned prefs, not TCC-protected, so
# these are safe to set before the Accessibility/Input Monitoring permission
# grant (Phase B) — they just won't do anything until that's granted.
if [ -d "/Applications/Scroll Reverser.app" ]; then
  echo "Configuring Scroll Reverser (automated preferences)..."
  # Quit it first if it's running (e.g. a re-run where it's already a login
  # item) and wait for it to fully exit: a live instance holds its settings in
  # memory and rewrites the plist on quit, which would clobber what we set
  # here. Then flush cfprefsd so the on-disk values are authoritative when it
  # next launches.
  if pgrep -x "Scroll Reverser" >/dev/null 2>&1; then
    killall "Scroll Reverser" 2>/dev/null || true
    sleep 1
  fi
  set_bool "Scroll Reverser enabled" com.pilotmoon.scroll-reverser InvertScrollingOn true
  set_bool "Scroll Reverser: Reverse Trackpad off" com.pilotmoon.scroll-reverser ReverseTrackpad false
  killall cfprefsd 2>/dev/null || true
fi

# A9. VS Code settings and baseline extensions — settings.json copied from
# this machine's config on 2026-07-23, with machine/project-specific entries
# dropped (a Flutter SDK path, an iTerm reference — iTerm isn't in the
# Brewfile — and a Copilot autocompletion setting, deliberately not carried
# forward). Only written if no settings.json already exists, so a re-run
# never clobbers changes made since. Extensions are curated to general editor
# experience — stack-specific ones (Dart, Python, C++, Docker, etc.) are left
# out; `code --install-extension` is idempotent, it no-ops if already there.
if [ -d "/Applications/Visual Studio Code.app" ] && command -v code &>/dev/null; then
  echo "Configuring VS Code (settings + baseline extensions)..."

  VSCODE_SETTINGS="$HOME/Library/Application Support/Code/User/settings.json"
  mkdir -p "$(dirname "$VSCODE_SETTINGS")"
  if [ ! -f "$VSCODE_SETTINGS" ]; then
    cat > "$VSCODE_SETTINGS" <<'EOF'
{
  "editor.acceptSuggestionOnEnter": "on",
  "editor.tabCompletion": "onlySnippets",
  "editor.formatOnType": true,
  "editor.cursorBlinking": "phase",
  "editor.cursorStyle": "line",
  "tslint.rulesDirectory": "./node_modules/codelyzer",
  "typescript.tsdk": "node_modules/typescript/lib",
  "files.exclude": {
    "**/.DS_Store": true,
    "**/.git": true,
    "**/.hg": true,
    "**/.svn": true,
    "/var/**": true,
    "app/**/*.js.map": true
  },
  "workbench.iconTheme": "vs-seti",
  "editor.dragAndDrop": true,
  "tslint.autoFixOnSave": true,
  "explorer.confirmDragAndDrop": false,
  "nativescript.analytics.enabled": false,
  "explorer.confirmDelete": false,
  "gitlens.advanced.messages": {
    "suppressLineUncommittedWarning": true,
    "suppressShowKeyBindingsNotice": true
  },
  "gitlens.keymap": "alternate",
  "vsintellicode.modify.editor.suggestSelection": "automaticallyOverrodeDefaultValue",
  "terminal.integrated.fontFamily": "Monaco",
  "todohighlight.keywords": [
    {
      "text": "TODO:",
      "color": "black"
    }
  ],
  "debug.console.fontSize": 12,
  "terminal.integrated.fontSize": 14,
  "editor.suggest.shareSuggestSelections": true,
  "workbench.settings.openDefaultKeybindings": true,
  "editor.suggestSelection": "first",
  "editor.insertSpaces": false,
  "files.trimTrailingWhitespace": true,
  "[markdown]": {
    "files.trimTrailingWhitespace": false,
    "editor.defaultFormatter": "esbenp.prettier-vscode"
  },
  "html.format.wrapAttributes": "force-aligned",
  "html.format.wrapLineLength": 255,
  "azureFunctions.showProjectWarning": false,
  "extensions.ignoreRecommendations": false,
  "[dart]": {
    "editor.formatOnSave": true,
    "editor.formatOnType": true,
    "editor.rulers": [120],
    "editor.selectionHighlight": false,
    "editor.suggest.snippetsPreventQuickSuggestions": false,
    "editor.suggestSelection": "first",
    "editor.tabCompletion": "onlySnippets",
    "editor.wordBasedSuggestions": "off"
  },
  "editor.fontFamily": "Dank Mono, Menlo, Monaco, 'Courier New', monospace",
  "dart.debugExternalLibraries": true,
  "dart.debugSdkLibraries": true,
  "window.titleBarStyle": "native",
  "terminal.integrated.tabs.enabled": true,
  "terminal.integrated.cursorStyle": "line",
  "terminal.integrated.unicodeVersion": "6",
  "terminal.integrated.defaultProfile.osx": "/bin/zsh",
  "dart.warnWhenEditingFilesOutsideWorkspace": false,
  "security.workspace.trust.untrustedFiles": "open",
  "svg.preview.mode": "svg",
  "redhat.telemetry.enabled": false,
  "editor.minimap.enabled": false,
  "debug.toolBarLocation": "docked",
  "workbench.editor.wrapTabs": true,
  "dart.showInspectorNotificationsForWidgetErrors": false,
  "editor.fontSize": 14,
  "editor.formatOnSave": true,
  "dart.warnWhenEditingFilesInPubCache": false,
  "workbench.startupEditor": "none",
  "files.associations": {
    "*.ts": "typescript",
    "*.arb": "json",
    "*.svg": "svg"
  },
  "security.workspace.trust.startupPrompt": "always",
  "[scss]": {
    "editor.defaultFormatter": "vscode.css-language-features"
  },
  "html.autoCreateQuotes": false,
  "search.useGlobalIgnoreFiles": true,
  "search.useParentIgnoreFiles": true,
  "search.exclude": {
    "/var/**": true
  },
  "editor.stickyScroll.enabled": true,
  "dart.devToolsLogFile": "~/devtools.txt",
  "explorer.autoRevealExclude": {
    "/var/**": true
  },
  "typescript.workspaceSymbols.scope": "currentProject",
  "git.openRepositoryInParentFolders": "never",
  "editor.rulers": [],
  "dart.lineLength": 120,
  "[typescript]": {
    "editor.defaultFormatter": "esbenp.prettier-vscode"
  },
  "[javascript]": {
    "editor.defaultFormatter": "vscode.typescript-language-features"
  },
  "diffEditor.ignoreTrimWhitespace": false,
  "editor.tabSize": 2,
  "[css]": {
    "editor.defaultFormatter": "esbenp.prettier-vscode"
  },
  "diffEditor.maxComputationTime": 0,
  "[json]": {
    "editor.defaultFormatter": "esbenp.prettier-vscode"
  },
  "window.zoomLevel": -1,
  "dart.debugExternalPackageLibraries": true,
  "[html]": {
    "editor.defaultFormatter": "vscode.html-language-features"
  },
  "[svg]": {
    "editor.defaultFormatter": "jock.svg"
  },
  "xml.symbols.maxItemsComputed": 50000,
  "typescript.updateImportsOnFileMove.enabled": "always",
  "C_Cpp.default.cppStandard": "c++23",
  "window.commandCenter": false,
  "workbench.layoutControl.enabled": false,
  "prisma.showPrismaDataPlatformNotification": false,
  "spellright.notificationClass": "warning",
  "html.format.wrapAttributesIndentSize": 2,
  "workbench.editor.enablePreview": false,
  "editor.renderWhitespace": "all",
  "terminal.integrated.mouseWheelScrollSensitivity": 3,
  "terminal.integrated.gpuAcceleration": "off"
}
EOF
  fi
  check "VS Code settings.json present" test -f "$VSCODE_SETTINGS"

  # Baseline extensions — general editor experience, not tied to any one
  # project's stack.
  VSCODE_EXTENSIONS=(
    adiessl.vscode-backtix
    ban.spellright
    davidanson.vscode-markdownlint
    davidmorais.dark-magic-themes
    dbaeumer.vscode-eslint
    eamodio.gitlens
    esbenp.prettier-vscode
    fractalbrew.backticks
    wayou.vscode-todo-highlight
    yzhang.markdown-all-in-one
  )
  for ext in "${VSCODE_EXTENSIONS[@]}"; do
    code --install-extension "$ext" >/dev/null 2>&1 || true
  done
  for ext in "${VSCODE_EXTENSIONS[@]}"; do
    check "VS Code extension: ${ext}" bash -c "code --list-extensions | grep -qi '^${ext}\$'"
  done
fi

# =============================================================================
# App sign-ins & permissions — guided manual steps, one at a time, grouped by
# app. Each is a dialog with Open (jump to the right place) and Done (advance).
# These come last because they need the apps Homebrew just installed. The
# System Settings walk-through already happened earlier, during the Command
# Line Tools download.
# =============================================================================
echo ""
echo "--- App sign-ins and permissions ---"
echo "A dialog will appear for each step. Click Open to jump to the right place,"
echo "then Done when you've finished that step, to move to the next one."

# --- Brave ---
if [ -d "/Applications/Brave Browser.app" ]; then

  # `defaultbrowser`'s own output doesn't reliably indicate the current
  # default (no marker in its listing), so there's no real check possible here
  # either — gate the whole block (including the `defaultbrowser brave` call
  # itself, which can re-trigger macOS's native confirmation popup) behind the
  # same done-marker used everywhere else in Phase B, checking both possible
  # outcome titles since which one fires depends on the attempt below.
  if grep -qxF "Brave — Default Browser" "$PHASE_B_STATE_FILE" 2>/dev/null || \
     grep -qxF "Brave — Default Browser (manual)" "$PHASE_B_STATE_FILE" 2>/dev/null; then
    echo "  (already done: Brave — Default Browser)"
  elif command -v defaultbrowser &>/dev/null; then
    # Homebrew-cask-installed apps aren't always registered with Launch
    # Services as HTTP handlers right away — force a registration pass so
    # `defaultbrowser` can actually see Brave as a candidate.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Brave Browser.app" 2>/dev/null || true

    if defaultbrowser brave; then
      prompt_step "Brave — Default Browser" \
        "macOS just showed a confirmation dialog asking to make Brave your default browser. Click \"Use Brave Browser\" on it, then click Done here."
    else
      prompt_step "Brave — Default Browser (manual)" \
        "Couldn't set Brave as default automatically. Set it by hand: in Brave's own Settings under \"Set as default browser,\" or in System Settings > Desktop & Dock > Default web browser. Click Open for Desktop & Dock settings." \
        "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
    fi
  fi

  prompt_step "Brave — iCloud Passwords Sign-In" \
    "The iCloud Passwords extension is installed. Open its icon in the toolbar and sign in with your Apple ID. Click Open to bring Brave forward." \
    "/Applications/Brave Browser.app"

  prompt_step "Brave — Kagi Search Engine" \
    "Install the Kagi Search extension from the Chrome Web Store, pin it, then log into Kagi. iCloud Passwords can autofill the login now that you're signed into it. Click Open for the extension page." \
    "https://chromewebstore.google.com/detail/kagi-search-for-chrome/cpeeggjhicnjfkjkkegblnadobhikphd"

  prompt_step "Brave — Gmail Sign-In" \
    "Sign into ty1470@gmail.com. iCloud Passwords can autofill the login now that you're signed into it. Click Open to go to Gmail." \
    "https://mail.google.com/"
fi

# --- Clipy ---
if [ -d "/Applications/Clipy.app" ]; then
  prompt_step "Clipy — Accessibility Permission" \
    "Launch Clipy — it needs a first launch to register itself as a login item and pick up its hotkeys, and it'll prompt you for Accessibility permission itself. Click Open to launch it, then grant the permission when it asks." \
    "/Applications/Clipy.app"
fi

# --- Scroll Reverser ---
if [ -d "/Applications/Scroll Reverser.app" ]; then
  prompt_step "Scroll Reverser — Accessibility Permission" \
    "Launch Scroll Reverser — it'll prompt you for Accessibility permission itself. Click Open to launch it, then grant the permission when it asks." \
    "/Applications/Scroll Reverser.app"

  prompt_step "Scroll Reverser — Input Monitoring Permission" \
    "Grant Scroll Reverser Input Monitoring permission — its scroll-reversal options are already set. Click Open for the Privacy & Security settings pane, then choose Input Monitoring from the list." \
    "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
fi

# --- Keyboard Maestro ---
if [ -d "/Applications/Keyboard Maestro.app" ]; then
  prompt_step "Keyboard Maestro — License Activation" \
    "Launch Keyboard Maestro and activate your license, or start the trial. Click Open to launch it." \
    "/Applications/Keyboard Maestro.app"

  prompt_step "Keyboard Maestro — Accessibility Permission" \
    "Grant Accessibility permission to both Keyboard Maestro and Keyboard Maestro Engine — two separate entries in the list. Click Open for the Privacy & Security settings pane, then choose Accessibility from the list." \
    "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"

  prompt_step "Keyboard Maestro — Input Monitoring Permission" \
    "Grant Keyboard Maestro Engine Input Monitoring permission. Click Open for the Privacy & Security settings pane, then choose Input Monitoring from the list." \
    "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"

  prompt_step "Keyboard Maestro — Macro Sync" \
    "In Keyboard Maestro's preferences, go to the Syncing tab, choose \"Start Syncing Macros,\" then \"Open Existing Synchronized Macros,\" and select: iCloud Drive/Google Drive/Keyboard Maestro Macros.kmsync. Click Open to launch Keyboard Maestro." \
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

# ---------------------------------------------------------------------------
echo ""
echo "Setup complete. Anything outside this script's scope (licensed software,"
echo "dotfiles, dev environment, etc.) is still on you."
