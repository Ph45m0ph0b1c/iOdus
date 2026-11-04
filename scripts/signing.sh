# Sourced by build-app.sh and sign-backend.sh. Sets:
#   IDENTITY      the signing identity: $IDENTITY if set, else the first
#                 "Developer ID Application" identity, else "iOdus Local Signing"
#   DEVELOPER_ID  1 for a Developer ID identity
#   SIGN_FLAGS    the hardened runtime; a secure timestamp for a Developer ID
if [ -z "${IDENTITY:-}" ]; then
  IDENTITY=$(security find-identity -v -p codesigning |
    sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
  [ -n "$IDENTITY" ] || IDENTITY="iOdus Local Signing"
fi
case "$IDENTITY" in
  "Developer ID Application:"*) DEVELOPER_ID=1; SIGN_FLAGS="--options runtime --timestamp" ;;
  *) DEVELOPER_ID=0; SIGN_FLAGS="--options runtime" ;;
esac
