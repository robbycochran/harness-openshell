#!/usr/bin/env python3
"""Verify all sandbox integrations work."""
import os
import subprocess
import json

def section(name):
    print(f"\n{'='*10} {name} {'='*10}")

# 1. Jira
section("JIRA (project=ROX)")
try:
    from atlassian import Jira
    j = Jira(
        url=os.environ["JIRA_URL"],
        username=os.environ["JIRA_USERNAME"],
        password=os.environ["JIRA_API_TOKEN"],
        cloud=True,
    )
    results = j.jql("project = ROX ORDER BY updated DESC", limit=3, fields="summary,status")
    for issue in results["issues"]:
        key = issue["key"]
        status = issue["fields"]["status"]["name"]
        summary = issue["fields"]["summary"]
        print(f"  {key}: [{status}] {summary}")
    print("OK")
except Exception as e:
    print(f"FAILED: {e}")

# 2. Confluence
section("CONFLUENCE (Stackrox)")
try:
    from atlassian import Confluence
    c = Confluence(
        url=os.environ["JIRA_URL"].replace(".atlassian.net", ".atlassian.net/wiki"),
        username=os.environ["JIRA_USERNAME"],
        password=os.environ["JIRA_API_TOKEN"],
        cloud=True,
    )
    results = c.cql("space = STACKROX AND type = page", limit=3)
    for r in results.get("results", []):
        title = r["content"]["title"]
        print(f"  {title}")
    print("OK")
except Exception as e:
    print(f"FAILED: {e}")

# 3. Gmail
section("GMAIL")
try:
    out = subprocess.run(
        ["gws", "gmail", "users", "messages", "list", "--params", json.dumps({"userId": "me", "maxResults": 3})],
        capture_output=True, text=True, timeout=15,
    )
    data = json.loads(out.stdout)
    count = len(data.get("messages", []))
    print(f"  {count} messages returned")
    print("OK")
except Exception as e:
    print(f"FAILED: {e}")

# 4. Calendar
section("CALENDAR")
try:
    out = subprocess.run(
        ["gws", "calendar", "events", "list", "--params", json.dumps({"calendarId": "primary", "maxResults": 3, "timeMin": "2026-04-28T00:00:00Z"})],
        capture_output=True, text=True, timeout=15,
    )
    data = json.loads(out.stdout)
    count = len(data.get("items", []))
    print(f"  {count} events returned")
    print("OK")
except Exception as e:
    print(f"FAILED: {e}")

# 5. Drive
section("DRIVE")
try:
    out = subprocess.run(
        ["gws", "drive", "files", "list", "--params", json.dumps({"pageSize": 3})],
        capture_output=True, text=True, timeout=15,
    )
    data = json.loads(out.stdout)
    for f in data.get("files", []):
        print(f"  {f['name']}")
    print("OK")
except Exception as e:
    print(f"FAILED: {e}")

# 6. GitHub
section("GITHUB (stackrox/collector)")
try:
    out = subprocess.run(
        ["gh", "issue", "list", "-R", "stackrox/collector", "--limit", "3", "--json", "number,title"],
        capture_output=True, text=True, timeout=15,
    )
    issues = json.loads(out.stdout)
    for i in issues:
        print(f"  #{i['number']}: {i['title']}")
    print("OK")
except Exception as e:
    print(f"FAILED: {e}")

section("GITHUB (stackrox/fact)")
try:
    out = subprocess.run(
        ["gh", "pr", "list", "-R", "stackrox/fact", "--limit", "3", "--json", "number,title"],
        capture_output=True, text=True, timeout=15,
    )
    prs = json.loads(out.stdout)
    for p in prs:
        print(f"  PR #{p['number']}: {p['title']}")
    print("OK")
except Exception as e:
    print(f"FAILED: {e}")

section("SUMMARY")
print("All integration checks complete.")
