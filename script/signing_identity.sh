#!/usr/bin/env bash
# Prints the SHA-1 of the codesigning identity to use, or "-" for ad hoc.
# Order: $SIGN_IDENTITY, then the valid "Developer ID Application" identity
# that expires last, then ad hoc. Hashes, not names, because one keychain can
# hold several Developer ID certificates with the same name.
set -euo pipefail

if [ -n "${SIGN_IDENTITY:-}" ]; then
  printf '%s\n' "$SIGN_IDENTITY"
  exit 0
fi

VALID="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Developer ID Application: / { print $2 }')"
BEST_HASH=""
BEST_EXPIRY=0
HASH=""
PEM=""
while IFS= read -r LINE; do
  case "$LINE" in
    "SHA-1 hash: "*) HASH="${LINE#SHA-1 hash: }" ;;
    "-----BEGIN CERTIFICATE-----") PEM="$LINE"$'\n' ;;
    "-----END CERTIFICATE-----")
      PEM+="$LINE"$'\n'
      grep -qxF "$HASH" <<<"$VALID" || continue
      NOT_AFTER="$(openssl x509 -noout -enddate <<<"$PEM")"
      EXPIRY="$(LC_ALL=C date -j -u -f '%b %e %T %Y %Z' "${NOT_AFTER#notAfter=}" +%s)"
      if [ "$EXPIRY" -gt "$BEST_EXPIRY" ]; then
        BEST_HASH="$HASH"
        BEST_EXPIRY="$EXPIRY"
      fi
      ;;
    *) PEM+="$LINE"$'\n' ;;
  esac
done < <(security find-certificate -a -Z -p -c "Developer ID Application: " 2>/dev/null)

if [ -n "$BEST_HASH" ]; then
  printf '%s\n' "$BEST_HASH"
  exit 0
fi

cat >&2 <<'WARN'
WARNING: no valid "Developer ID Application" identity in the keychain. Signing ad hoc.
  macOS ties Full Disk Access to the code signature, so the grant will not survive a rebuild.
  Set SIGN_IDENTITY to a certificate SHA-1 from `security find-identity -v -p codesigning` to choose one.
WARN
printf '%s\n' "-"
