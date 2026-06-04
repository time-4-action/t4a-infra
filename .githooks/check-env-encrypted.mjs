#!/usr/bin/env node
// check-env-encrypted.mjs
// Verify that the dotenvx-managed .env files that ARE committed to this repo
// are encrypted (ciphertext), never plaintext.
//
// These files are whitelisted in .gitignore so they CAN be committed — but only
// after `dotenvx encrypt` turns their values into ciphertext. A plaintext copy
// (real secrets OR placeholders) must never land in a commit.
//
// Pure Node (no `sh` dependency) so it runs the same on Windows, macOS and Linux.
//
// Usage:
//   node .githooks/check-env-encrypted.mjs            # check the files on disk
//   node .githooks/check-env-encrypted.mjs --staged   # check what's staged (used by the pre-commit hook)
//
// Exit 0 = all good (or nothing to check). Exit 1 = a naked .env was found.

import { readFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";

// The env files that are allowed in git AND must be encrypted.
// Keep in sync with the "!...env" whitelist lines in .gitignore.
const COMMITTABLE_ENV = ["mongo/.env", "auth0/.env.prod", "auth0/.env.dev"];

const MODE = process.argv.includes("--staged") ? "staged" : "disk";

let fail = false;

// Run git and return stdout, or null if it exits non-zero (e.g. file not in index).
function git(args) {
  try {
    return execFileSync("git", args, { encoding: "utf8" });
  } catch {
    return null;
  }
}

// Read a file's content either from the git index (staged) or from disk.
// Returns null when the file can't be read.
function readContent(f) {
  if (MODE === "staged") {
    // ':file' = the staged (index) version of the blob.
    return git(["show", `:${f}`]);
  }
  try {
    return readFileSync(f, "utf8");
  } catch {
    return null;
  }
}

// Is this file part of the change we're checking?
//  - staged mode: only files staged for commit
//  - disk mode:   any committable env file that exists on disk
function isRelevant(f) {
  if (MODE === "staged") {
    const staged = git(["diff", "--cached", "--name-only", "--diff-filter=ACM"]);
    if (staged === null) return false;
    return staged.split(/\r?\n/).includes(f);
  }
  return existsSync(f);
}

for (const f of COMMITTABLE_ENV) {
  if (!isRelevant(f)) continue;

  const content = readContent(f);
  if (content === null) continue;

  const lines = content.split(/\r?\n/);

  // An encrypted dotenvx file carries a DOTENV_PUBLIC_KEY line and wraps every
  // secret value as encrypted:.... If the public key is missing, it's plaintext.
  const hasPublicKey = lines.some((l) => l.startsWith("DOTENV_PUBLIC_KEY="));

  if (hasPublicKey) {
    // Public key present. Now make sure no secret value is still naked:
    // every KEY=value line (other than the public key + comments/blanks)
    // must have a value that starts with "encrypted:".
    const nakedVals = lines.filter((l) => {
      if (/^\s*#/.test(l)) return false; // comment
      if (/^\s*$/.test(l)) return false; // blank
      if (l.startsWith("DOTENV_PUBLIC_KEY=")) return false;
      if (l.includes('="encrypted:')) return false; // already ciphertext
      return l.includes("="); // any remaining KEY=value is naked
    });
    if (nakedVals.length > 0) {
      console.log(`BLOCKED: ${f} has a DOTENV_PUBLIC_KEY but some values are NOT encrypted:`);
      for (const l of nakedVals) console.log(`    ${l}`);
      console.log(`    -> run: npx dotenvx encrypt -f ${f}`);
      fail = true;
    }
  } else {
    console.log(`BLOCKED: ${f} is plaintext (no DOTENV_PUBLIC_KEY). It must be encrypted before commit.`);
    console.log(`    -> run: npx dotenvx encrypt -f ${f}`);
    console.log("    (this catches both real secrets AND unfilled <placeholder> templates)");
    fail = true;
  }
}

if (fail) {
  console.log("");
  console.log("Commit aborted. Encrypt the file(s) above, then 'git add' and commit again.");
  console.log("The decryption key lands in <dir>/.env.keys, which is gitignored — keep it in your password manager.");
  process.exit(1);
}

process.exit(0);
