#!/usr/bin/env python3
"""Fail closed around the CLI's human-readable offline evaluation report."""
import argparse
import csv
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]

# Curated test inventory, not a contributor's installed-app snapshot. Changes require review.
PUBLIC_APPS = {
    "Calculator", "Calendar", "ChatGPT", "Chess", "Claude", "Clock", "Console", "Cursor", "Dictionary",
    "Docker", "FaceTime", "Finder", "Google Chrome", "Home", "Keynote", "Mail", "Maps", "Messages",
    "Microsoft Excel", "Microsoft PowerPoint", "Microsoft Teams", "Microsoft Word", "Music",
    "News", "Notes", "Notion", "Numbers", "OneDrive", "Pages", "Passwords", "Phone", "Preview",
    "Reminders", "Safari", "Siri", "Spotify", "Stats", "Stocks", "System Settings", "Telegram", "Terminal",
    "Tips", "Weather", "iTerm", "zoom.us",
}


def public_sites():
    source = (ROOT / "app/Sources/VartaCore/Sources.swift").read_text()
    section = source.split("public static let builtinSites:", 1)[1].split("public static let builtinURLs:", 1)[0]
    sites = dict(re.findall(r'\("([^"]+)", "([^"]+)"\)', section))
    require(bool(sites), "Could not load built-in public site inventory")
    return sites


def site_label(site):
    title = " ".join(site["title"].split())
    title = title if len(title) <= 60 else title[:57] + "..."
    domain = urlsplit(site["url"]).netloc.removeprefix("www.")
    return title if title.lower() in domain.lower() else f"{title} ({domain})"


def check_candidate_privacy(row, builtin):
    require(set(row) == {"command", "apps", "sites", "answers", "expect"}, "Unexpected fixture fields; privacy review required")
    require(row["apps"] == sorted(PUBLIC_APPS), "App candidates must use the curated public test inventory")
    labels = {"none"}
    for site in row["sites"]:
        require(set(site) == {"url", "title"}, "Unexpected site fields; privacy review required")
        url, title = site["url"], site["title"]
        synthetic = re.fullmatch(r"https://candidate-([0-9]{3})\.example", url)
        require((url in builtin and title == builtin[url]) or
                (synthetic is not None and title == f"Synthetic bookmark {synthetic[1]}"),
                "Site candidates must be exact built-in pairs or reserved synthetic placeholders")
        labels.add(site_label(site))
    # Choice values AND probability dictionary keys can retain bookmark titles/domains.
    for question, allowed in (("site", labels), ("app", PUBLIC_APPS | {"none"}),
                              ("app_for_task", PUBLIC_APPS | {"none"})):
        answer = row["answers"].get(question)
        require(isinstance(answer, dict) and set(answer) <= {"choice", "confidence", "probabilities", "type"},
                "Unexpected candidate answer fields; privacy review required")
        require(answer.get("type") == "choice" and answer.get("choice") in allowed,
                "Unapproved candidate choice; privacy review required")
        probabilities = answer.get("probabilities")
        require(isinstance(probabilities, dict) and set(probabilities) <= allowed,
                "Unapproved candidate probability label; privacy review required")
        require(all(type(value) in (int, float) and 0 <= value <= 1 for value in probabilities.values()),
                "Invalid candidate probabilities")
        require(type(answer.get("confidence")) in (int, float) and 0 <= answer["confidence"] <= 1,
                "Invalid candidate confidence")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_inputs():
    builtin = public_sites()
    with (ROOT / "eval/all-commands.csv").open(newline="") as handle:
        reader = csv.DictReader(handle)
        require(reader.fieldnames and {"id", "command", "intent"} <= set(reader.fieldnames), "Missing CSV columns")
        rows = list(reader)
    require(len(rows) >= 114, "Label set shrank below the 114-command baseline")
    for row in rows:
        require(None not in row and all(value is not None for value in row.values()), "Malformed CSV row")
        require(all(row[key].strip() for key in ("id", "command", "intent")), "Empty label field")
    commands = [row["command"] for row in rows]
    require(len(set(commands)) == len(rows), "Duplicate labelled command")
    require(len({row["id"] for row in rows}) == len(rows), "Duplicate label ID")
    records = []
    for number, line in enumerate((ROOT / "eval/fixtures/router-replay.jsonl").read_text().splitlines(), 1):
        require(bool(line.strip()), f"Empty fixture line {number}")
        row = json.loads(line)
        require(isinstance(row, dict), f"Invalid fixture row {number}")
        require(isinstance(row.get("command"), str) and row["command"].strip(), "Missing fixture command")
        require(isinstance(row.get("answers"), dict) and row["answers"], "Missing fixture answers")
        require(isinstance(row.get("expect"), dict) and row["expect"], "Missing expected plan")
        require(isinstance(row.get("apps"), list) and all(isinstance(a, str) for a in row["apps"]), "Missing/invalid fixture apps")
        require(isinstance(row.get("sites"), list), "Missing fixture sites")
        require(all(isinstance(s, dict) and isinstance(s.get("url"), str) and isinstance(s.get("title"), str) for s in row["sites"]), "Invalid fixture site")
        check_candidate_privacy(row, builtin)
        records.append(row["command"])
    require(len(records) == len(set(records)), "Duplicate fixture command")
    require(set(records) == set(commands), "Fixture and labels must cover exactly the same commands")
    return len(rows)


def check_report(report, count):
    total = re.search(r"^\s*all\s+(\d+)\s+\d+/\d+\s+\(\d+%\)\s+(\d+)/(\d+)", report, re.MULTILINE)
    require(total is not None, "Could not parse whole-plan score; update the gate for the new report format")
    size, correct, denominator = map(int, total.groups())
    require(size == denominator == count, "Evaluation skipped labelled commands")
    require(correct * 114 >= 112 * count, "Whole-plan accuracy fell below 112/114")
    auto = re.search(r"current thresholds[^\n]*: runs (\d+)/(\d+), (\d+)/(\d+) right", report)
    require(auto is not None, "Could not parse current automatic-execution score")
    runs, total, right, scored = map(int, auto.groups())
    require(total == count and runs == scored and right == runs, "Automatic-execution plans must all be correct")
    require(runs * 114 >= 85 * count, "Automatic-execution coverage fell below 85/114")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    args = parser.parse_args()
    count = check_inputs()
    command = ["swift", "run", "--skip-build", "-c", args.configuration, "--package-path", "app", "varta-cli"]
    replay = subprocess.run(command + ["interpret", "eval/fixtures/router-replay.jsonl"], cwd=ROOT, text=True, capture_output=True, check=True)
    print(replay.stdout, end="")
    require(f"{count}/{count} plans match the recorded answers" in replay.stdout, "Replay did not check every fixture plan")
    result = subprocess.run(command + ["eval", "eval/all-commands.csv", "eval/fixtures/router-replay.jsonl"], cwd=ROOT, text=True, capture_output=True, check=True)
    print(result.stdout, end="")
    require("skipped:" not in result.stderr, "CLI skipped a fixture entry")
    check_report(result.stdout, count)
    print("Offline evaluation gates passed.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Evaluation gate failed: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stdout or "", file=sys.stderr)
            print(error.stderr or "", file=sys.stderr)
        sys.exit(1)
