#!/usr/bin/env bash
# Notarization, shared by the two things that get submitted: the .app and the
# disk image that carries it.
#
# Sourced, never run. It exists because both submissions need the same
# credential handling, the same "Accepted is the only word that counts" check
# and the same log retrieval, and two hand-maintained copies of that would be
# free to drift until a release failed in a way neither script could explain.

# Resolves credentials into DDCC_NOTARY_ARGS. Call it before doing any work:
# the point is to fail on a missing credential in the first second rather than
# after a universal build.
#
# Two forms, because the two callers have different footing. A workstation has
# a keychain and can hold a profile made by `notarytool store-credentials`. A
# CI runner has neither, so it passes the three parts of an App Store Connect
# key directly -- which is also why the key is a file path and not the key
# body: notarytool reads a .p8 from disk.
ddcc_notary_resolve() {
  if [ -n "${DDCC_NOTARY_PROFILE:-}" ]; then
    DDCC_NOTARY_ARGS=(--keychain-profile "$DDCC_NOTARY_PROFILE")
  elif [ -n "${DDCC_NOTARY_KEY:-}" ]; then
    if [ ! -f "$DDCC_NOTARY_KEY" ]; then
      echo "error: DDCC_NOTARY_KEY is '$DDCC_NOTARY_KEY', which is not a file." >&2
      echo "It names the App Store Connect .p8 on disk, not the key's contents." >&2
      return 1
    fi
    DDCC_NOTARY_ARGS=(--key "$DDCC_NOTARY_KEY"
                      --key-id "${DDCC_NOTARY_KEY_ID:?DDCC_NOTARY_KEY set without DDCC_NOTARY_KEY_ID}"
                      --issuer "${DDCC_NOTARY_ISSUER:?DDCC_NOTARY_KEY set without DDCC_NOTARY_ISSUER}")
  else
    echo "error: no notarization credentials." >&2
    echo "Set DDCC_NOTARY_PROFILE, or DDCC_NOTARY_KEY with its key id and issuer." >&2
    return 1
  fi
}

# Submits one container -- a .zip, a .dmg or a .pkg. A bare .app is not one of
# them: handed a bundle directly, notarytool answers "The path could not be
# read", which reads like a permissions fault rather than a wrong argument.
ddcc_notarize_container() {
  local container="$1"
  local log status_ok

  echo "submitting $container to the notary service (this takes a few minutes)"
  log="$(mktemp -t ddcc-notary)"

  # The verdict is read out of the output rather than taken from the exit
  # code. `submit --wait` returns 0 for a submission that reached a terminal
  # state, and a rejected submission has reached one. Accepted is the only
  # word that means shippable.
  status_ok=1
  if ! xcrun notarytool submit "$container" "${DDCC_NOTARY_ARGS[@]}" --wait 2>&1 | tee "$log"; then
    status_ok=0
  elif ! grep -q "status: Accepted" "$log"; then
    status_ok=0
  fi

  if [ "$status_ok" != "1" ]; then
    echo "error: notarization of $container did not return Accepted" >&2
    # The summary names the failure; only the log names the binary and the
    # reason. Fetching it here is what lets a CI failure carry its own
    # diagnosis instead of requiring someone to go and ask Apple by hand.
    local submission_id
    submission_id="$(awk '/id: / {print $2; exit}' "$log")"
    if [ -n "$submission_id" ]; then
      echo "--- notarization log for $submission_id ---" >&2
      xcrun notarytool log "$submission_id" "${DDCC_NOTARY_ARGS[@]}" >&2 || true
    fi
    rm -f "$log"
    return 1
  fi

  rm -f "$log"
}

# Attaches the ticket and proves it attached.
#
# Not a formality. An unstapled build is notarized only in the sense that Apple
# would say so if asked, so its first launch on a machine with no network shows
# the unidentified-developer refusal -- the precise failure this whole path
# exists to prevent. The ticket has to travel inside the artifact.
ddcc_staple() {
  local artifact="$1"
  xcrun stapler staple "$artifact"
  xcrun stapler validate "$artifact"
}
