#!/bin/sh
# check-env-encrypted.sh
# Verify that the dotenvx-managed .env files that ARE committed to this repo
# are encrypted (ciphertext), never plaintext.
#
# These files are whitelisted in .gitignore so they CAN be committed — but only
# after `dotenvx encrypt` turns their values into ciphertext. A plaintext copy
# (real secrets OR placeholders) must never land in a commit.
#
# Usage:
#   sh .githooks/check-env-encrypted.sh            # check the files on disk
#   sh .githooks/check-env-encrypted.sh --staged   # check what's staged (used by the pre-commit hook)
#
# Exit 0 = all good (or nothing to check). Exit 1 = a naked .env was found.

set -eu

# The env files that are allowed in git AND must be encrypted.
# Keep in sync with the "!...env" whitelist lines in .gitignore.
COMMITTABLE_ENV="mongo/.env auth0/.env.prod auth0/.env.dev"

MODE="disk"
[ "${1:-}" = "--staged" ] && MODE="staged"

fail=0

# Read a file's content either from the git index (staged) or from disk.
read_content() {
    f="$1"
    if [ "$MODE" = "staged" ]; then
        # ':file' = the staged (index) version of the blob.
        git show ":$f" 2>/dev/null || return 1
    else
        cat "$f" 2>/dev/null || return 1
    fi
}

# Is this file part of the change we're checking?
#  - staged mode: only files staged for commit
#  - disk mode:   any committable env file that exists on disk
is_relevant() {
    f="$1"
    if [ "$MODE" = "staged" ]; then
        git diff --cached --name-only --diff-filter=ACM | grep -Fxq "$f"
    else
        [ -f "$f" ]
    fi
}

for f in $COMMITTABLE_ENV; do
    is_relevant "$f" || continue

    content="$(read_content "$f")" || continue

    # An encrypted dotenvx file carries a DOTENV_PUBLIC_KEY line and wraps every
    # secret value as encrypted:.... If the public key is missing, it's plaintext.
    if printf '%s\n' "$content" | grep -q '^DOTENV_PUBLIC_KEY='; then
        # Public key present. Now make sure no secret value is still naked:
        # every KEY=value line (other than the public key + comments/blanks)
        # must have a value that starts with "encrypted:".
        naked_vals="$(printf '%s\n' "$content" \
            | grep -v '^[[:space:]]*#' \
            | grep -v '^[[:space:]]*$' \
            | grep -v '^DOTENV_PUBLIC_KEY=' \
            | grep -v '="encrypted:' \
            | grep '=' || true)"
        if [ -n "$naked_vals" ]; then
            echo "BLOCKED: $f has a DOTENV_PUBLIC_KEY but some values are NOT encrypted:"
            printf '%s\n' "$naked_vals" | sed 's/^/    /'
            echo "    -> run: npx dotenvx encrypt -f $f"
            fail=1
        fi
    else
        echo "BLOCKED: $f is plaintext (no DOTENV_PUBLIC_KEY). It must be encrypted before commit."
        echo "    -> run: npx dotenvx encrypt -f $f"
        echo "    (this catches both real secrets AND unfilled <placeholder> templates)"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo ""
    echo "Commit aborted. Encrypt the file(s) above, then 'git add' and commit again."
    echo "The decryption key lands in <dir>/.env.keys, which is gitignored — keep it in your password manager."
    exit 1
fi

exit 0
