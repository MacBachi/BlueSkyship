#!/usr/bin/env python3
"""Refuses secrets and signing material before they can reach GitHub.

Usage: check-secrets.py --staged | --all | --history
Needs only the Python standard library, so it also runs on GitHub. The hooks in .githooks call it.
"""
import fnmatch
import re
import subprocess
import sys

CONTENT = {
    "GitHub token": r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})",
    "private key": r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY",
    "JWT, such as a Bluesky session token": r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.",
    "Bluesky or Apple app password": r"\b(?!x{4}-)[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}\b",
    "AWS key": r"\bAKIA[0-9A-Z]{16}\b",
    "Slack token": r"\bxox[abprs]-[A-Za-z0-9-]{10,}",
    "API key": r"\bsk-(?:ant-)?[A-Za-z0-9_-]{20,}",
    "password in clear text": r"""(?i)\b(?:password|passwd|secret|api_?key|access_?token)\b["']?\s*[:=]\s*["'][^"'\s\\]{8,}["']""",
}
CONTENT = {name: re.compile(pattern) for name, pattern in CONTENT.items()}

FILES = [
    "*.p12", "*.pfx", "*.cer", "*.pem", "*.key", "*.p8", "*.keychain", "*.keychain-db",
    "*.certSigningRequest", "*.mobileprovision", "*.provisionprofile",
    ".env", ".env.*", "*.dmg", "*.xcarchive", "*.xcuserstate",
]
# For a proven false alarm, such as a harmless word-word-word-word. Put it on that line only.
ALLOW = "secret-scan:" + "allow"
# The rules themselves have to name what they forbid.
NOT_SCANNED = {"scripts/check-secrets.py", ".gitignore"}


def git(*args, binary=False):
    output = subprocess.run(["git", *args], check=True, capture_output=True).stdout
    return output if binary else output.decode("utf-8", "replace")


def file_problems(path):
    name = path.rsplit("/", 1)[-1]
    return [f"{path}: file type must not be in the repository"] if any(fnmatch.fnmatch(name, p) for p in FILES) else []


def text_problems(where, text):
    found = []
    for number, line in enumerate(text.splitlines(), 1):
        if ALLOW in line:
            continue
        for name, pattern in CONTENT.items():
            # The value is never printed: this output can end up in logs.
            if pattern.search(line):
                found.append(f"{where}:{number}: looks like a {name}")
    return found


def read(spec):
    data = git("show", spec, binary=True)
    return None if b"\0" in data[:8000] else data.decode("utf-8", "replace")


def check_paths(paths, prefix):
    problems = []
    for path in paths:
        problems += file_problems(path)
        if path not in NOT_SCANNED:
            text = read(prefix + path)
            if text is not None:
                problems += text_problems(path, text)
    return problems


def check_history():
    problems, commit, path = [], "", ""
    for line in git("log", "--all", "-p", "--no-color", "--format=commit %h").splitlines():
        if line.startswith("commit "):
            commit = line.split()[1]
        elif line.startswith("+++ b/"):
            path = line[6:]
            problems += [f"{commit} {p}" for p in file_problems(path)]
        elif line.startswith("+") and not line.startswith("+++") and path not in NOT_SCANNED:
            problems += text_problems(f"{commit} {path}", line[1:])
    return sorted(set(problems))


def main():
    mode = sys.argv[1] if len(sys.argv) == 2 else ""
    if mode == "--staged":
        problems = check_paths(git("diff", "--cached", "--name-only", "--diff-filter=ACMR").splitlines(), ":")
    elif mode == "--all":
        problems = check_paths(git("ls-files").splitlines(), ":")
    elif mode == "--history":
        problems = check_history()
    else:
        sys.exit(__doc__)
    for problem in problems:
        print(f"BLOCKED  {problem}", file=sys.stderr)
    if problems:
        sys.exit(f"{len(problems)} possible secrets. Nothing was committed or pushed. Remove them, and replace any real secret.")
    print(f"check-secrets {mode}: nothing found")


if __name__ == "__main__":
    main()
