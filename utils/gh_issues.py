#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "typer>=0.12.0",
#     "rich>=13.7.0",
# ]
# ///
"""
GitHub Issues CLI Tool for LLM Integration
===========================================
A single-file CLI tool designed for LLM tool use with structured JSON outputs.

Usage (uv automatically handles dependencies):
    uv run gh_issues.py list
    uv run gh_issues.py view 42
    uv run gh_issues.py create --title "Bug" --body "Description"
    uv run gh_issues.py close 42 --comment "Fixed"

All commands support --output json flag for machine-readable output.

Tool Schema for LLM:
    uv run gh_issues.py schema
"""

import json
import subprocess
import sys
from enum import Enum
from typing import Annotated, Optional

import typer
from rich import print as rprint
from rich.console import Console
from rich.table import Table

app = typer.Typer(
    name="gh-issues",
    help="GitHub Issues CLI for LLM integration. Use --output json for structured output.",
    no_args_is_help=True,
)
console = Console()


# ============================================================================
# ENUMS
# ============================================================================

class IssueState(str, Enum):
    open = "open"
    closed = "closed"
    all = "all"


class IssueType(str, Enum):
    bug = "bug"
    feature = "feature"
    task = "task"
    phase = "phase"
    custom = "custom"


class Priority(str, Enum):
    critical = "critical"
    high = "high"
    medium = "medium"
    low = "low"


class OutputFormat(str, Enum):
    human = "human"
    json = "json"


# ============================================================================
# TEMPLATES
# ============================================================================

TEMPLATES = {
    "bug": {
        "title_prefix": "[Bug]",
        "labels": ["bug"],
        "body_template": """## Priority
{priority}

## Description
{description}

## Steps to Reproduce
{steps}

## Current Behavior
{current_behavior}

## Expected Behavior
{expected_behavior}
""",
    },
    "feature": {
        "title_prefix": "[Feature]",
        "labels": ["enhancement"],
        "body_template": """## Priority
{priority}

## Description
{description}

## Implementation
{implementation}

## Benefits
{benefits}
""",
    },
    "task": {
        "title_prefix": "[Task]",
        "labels": ["task"],
        "body_template": """## Priority
{priority}

## Description
{description}

## Implementation Steps
{implementation}

## Acceptance Criteria
{criteria}
""",
    },
}

# ============================================================================
# TOOL SCHEMA (for LLM consumption)
# ============================================================================

TOOL_SCHEMA = {
    "name": "gh-issues",
    "description": "GitHub Issues CLI for LLM tool integration",
    "usage": "uv run gh_issues.py <command> [options]",
    "commands": {
        "list": {
            "description": "List issues from repository",
            "options": {
                "--state/-s": "open|closed|all (default: open)",
                "--labels/-l": "Filter by labels (comma-separated)",
                "--limit/-n": "Max results (default: 30)",
                "--output/-o": "human|json (default: human)",
            },
            "example": "uv run gh_issues.py list --state open --output json",
        },
        "view": {
            "description": "View issue details",
            "args": {"ISSUE_NUMBER": "Issue number (required)"},
            "options": {
                "--comments/-c": "Include comments",
                "--output/-o": "human|json",
            },
            "example": "uv run gh_issues.py view 42 --comments --output json",
        },
        "create": {
            "description": "Create new issue",
            "options": {
                "--title/-t": "Issue title (required)",
                "--body/-b": "Issue body (markdown)",
                "--body-file/-f": "Read body from file (preserves backticks)",
                "--type": "bug|feature|task|custom",
                "--labels/-l": "Labels (comma-separated)",
                "--output/-o": "human|json",
            },
            "example": "uv run gh_issues.py create --title 'Fix bug' --body-file body.md --output json",
        },
        "close": {
            "description": "Close an issue",
            "args": {"ISSUE_NUMBER": "Issue number (required)"},
            "options": {
                "--comment/-c": "Closing comment",
                "--reason/-r": "completed|not_planned",
                "--output/-o": "human|json",
            },
            "example": "uv run gh_issues.py close 42 --comment 'Fixed' --output json",
        },
        "comment": {
            "description": "Add comment to issue",
            "args": {"ISSUE_NUMBER": "Issue number (required)"},
            "options": {
                "--body/-b": "Comment body",
                "--body-file/-f": "Read body from file (preserves backticks)",
                "--stdin": "Read body from stdin",
                "--output/-o": "human|json",
            },
            "example": "uv run gh_issues.py comment 42 --body-file comment.md --output json",
        },
        "edit": {
            "description": "Edit an issue",
            "args": {"ISSUE_NUMBER": "Issue number (required)"},
            "options": {
                "--title/-t": "New title",
                "--body/-b": "New body",
                "--body-file/-f": "Read body from file (preserves backticks)",
                "--add-labels": "Labels to add",
                "--remove-labels": "Labels to remove",
                "--output/-o": "human|json",
            },
            "example": "uv run gh_issues.py edit 42 --body-file body.md --output json",
        },
        "search": {
            "description": "Search issues",
            "args": {"QUERY": "Search query (required)"},
            "options": {
                "--state/-s": "open|closed|all",
                "--limit/-n": "Max results",
                "--output/-o": "human|json",
            },
            "example": "uv run gh_issues.py search 'multiplayer' --output json",
        },
        "labels": {
            "description": "List repository labels",
            "example": "uv run gh_issues.py labels --output json",
        },
        "schema": {
            "description": "Output tool schema as JSON for LLM",
            "example": "uv run gh_issues.py schema",
        },
    },
}


# ============================================================================
# HELPERS
# ============================================================================

def run_gh(args: list[str], check: bool = True) -> subprocess.CompletedProcess:
    """Run gh CLI command."""
    result = subprocess.run(["gh"] + args, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise typer.Exit(code=1)
    return result


def output(data: dict | list, fmt: OutputFormat, msg: str = ""):
    """Output result in requested format."""
    if fmt == OutputFormat.json:
        print(json.dumps(data, indent=2, default=str))
    else:
        if msg:
            rprint(f"[green]✓[/green] {msg}")
        if isinstance(data, list):
            if not data:
                rprint("[yellow]No results.[/yellow]")
                return
            table = Table()
            for key in data[0].keys():
                table.add_column(key.replace("_", " ").title())
            for item in data:
                table.add_row(*[str(v) for v in item.values()])
            console.print(table)
        elif isinstance(data, dict):
            for k, v in data.items():
                if k != "body":
                    rprint(f"[bold]{k}:[/bold] {v}")
                else:
                    rprint(f"[bold]{k}:[/bold]\n{v}")


def ensure_auth():
    """Check gh is authenticated."""
    if run_gh(["auth", "status"], check=False).returncode != 0:
        rprint("[red]Error:[/red] gh not authenticated. Run: gh auth login")
        raise typer.Exit(code=1)


# ============================================================================
# COMMANDS
# ============================================================================

@app.command()
def list(
    state: Annotated[IssueState, typer.Option("--state", "-s")] = IssueState.open,
    labels: Annotated[Optional[str], typer.Option("--labels", "-l")] = None,
    assignee: Annotated[Optional[str], typer.Option("--assignee", "-a")] = None,
    limit: Annotated[int, typer.Option("--limit", "-n")] = 30,
    output_fmt: Annotated[OutputFormat, typer.Option("--output", "-o")] = OutputFormat.human,
):
    """List GitHub issues. Returns: number, title, state, labels, author, dates."""
    ensure_auth()

    args = ["issue", "list", "--state", state.value, "--limit", str(limit),
            "--json", "number,title,state,labels,author,createdAt,updatedAt,assignees"]
    if labels:
        args.extend(["--label", labels])
    if assignee:
        args.extend(["--assignee", assignee])

    result = run_gh(args, check=False)
    if result.returncode != 0:
        output({"error": "Failed to list issues", "details": result.stderr.strip()}, output_fmt)
        raise typer.Exit(code=1)

    issues = json.loads(result.stdout) if result.stdout else []
    formatted = [{
        "number": i["number"],
        "title": i["title"],
        "state": i["state"],
        "labels": ", ".join(l["name"] for l in i.get("labels", [])),
        "author": i.get("author", {}).get("login", ""),
        "created": i.get("createdAt", "")[:10],
    } for i in issues]

    output(formatted, output_fmt)


@app.command()
def view(
    issue_number: Annotated[int, typer.Argument(help="Issue number")],
    comments: Annotated[bool, typer.Option("--comments", "-c")] = False,
    output_fmt: Annotated[OutputFormat, typer.Option("--output", "-o")] = OutputFormat.human,
):
    """View issue details. Returns: number, title, state, body, labels, comments."""
    ensure_auth()

    fields = "number,title,state,body,labels,author,assignees,createdAt,updatedAt,url"
    if comments:
        fields += ",comments"

    result = run_gh(["issue", "view", str(issue_number), "--json", fields], check=False)
    if result.returncode != 0:
        output({"error": f"Failed to view issue #{issue_number}"}, output_fmt)
        raise typer.Exit(code=1)

    issue = json.loads(result.stdout)
    formatted = {
        "number": issue["number"],
        "title": issue["title"],
        "state": issue["state"],
        "url": issue["url"],
        "author": issue.get("author", {}).get("login", ""),
        "labels": ", ".join(l["name"] for l in issue.get("labels", [])),
        "created": issue.get("createdAt", ""),
        "body": issue.get("body", ""),
    }
    if comments:
        formatted["comments"] = [{
            "author": c.get("author", {}).get("login", ""),
            "body": c.get("body", ""),
        } for c in issue.get("comments", [])]

    output(formatted, output_fmt)


@app.command()
def create(
    title: Annotated[str, typer.Option("--title", "-t", help="Issue title")],
    body: Annotated[Optional[str], typer.Option("--body", "-b")] = None,
    body_file: Annotated[Optional[str], typer.Option("--body-file", "-f", help="Read body from file")] = None,
    issue_type: Annotated[Optional[IssueType], typer.Option("--type")] = None,
    labels: Annotated[Optional[str], typer.Option("--labels", "-l")] = None,
    assignee: Annotated[Optional[str], typer.Option("--assignee", "-a")] = None,
    output_fmt: Annotated[OutputFormat, typer.Option("--output", "-o")] = OutputFormat.human,
):
    """Create new issue. Use --body-file for complex markdown with backticks."""
    ensure_auth()

    final_title = title
    final_labels = labels.split(",") if labels else []

    # Determine body content
    final_body = body or ""
    if body_file:
        try:
            with open(body_file, 'r', encoding='utf-8') as f:
                final_body = f.read()
        except FileNotFoundError:
            output({"error": f"File not found: {body_file}"}, output_fmt)
            raise typer.Exit(code=1)

    if issue_type and issue_type != IssueType.custom:
        template = TEMPLATES.get(issue_type.value, {})
        prefix = template.get("title_prefix", "")
        final_title = f"{prefix} {title}".strip()
        final_labels.extend(template.get("labels", []))

    args = ["issue", "create", "--title", final_title, "--body", final_body]
    for label in set(final_labels):
        args.extend(["--label", label.strip()])
    if assignee:
        args.extend(["--assignee", assignee])

    result = run_gh(args, check=False)
    if result.returncode != 0:
        output({"error": "Failed to create issue", "details": result.stderr.strip()}, output_fmt)
        raise typer.Exit(code=1)

    url = result.stdout.strip()
    issue_num = url.split("/")[-1] if url else "unknown"

    output({"success": True, "issue_number": issue_num, "url": url}, output_fmt, f"Created #{issue_num}")


@app.command()
def close(
    issue_number: Annotated[int, typer.Argument(help="Issue number")],
    comment: Annotated[Optional[str], typer.Option("--comment", "-c")] = None,
    reason: Annotated[str, typer.Option("--reason", "-r")] = "completed",
    output_fmt: Annotated[OutputFormat, typer.Option("--output", "-o")] = OutputFormat.human,
):
    """Close an issue. Returns: success, issue_number, reason."""
    ensure_auth()

    if comment:
        run_gh(["issue", "comment", str(issue_number), "--body", comment], check=False)

    result = run_gh(["issue", "close", str(issue_number), "--reason", reason], check=False)
    if result.returncode != 0:
        output({"error": f"Failed to close #{issue_number}"}, output_fmt)
        raise typer.Exit(code=1)

    output({"success": True, "issue_number": issue_number, "reason": reason}, output_fmt, f"Closed #{issue_number}")


@app.command()
def reopen(
    issue_number: Annotated[int, typer.Argument(help="Issue number")],
    comment: Annotated[Optional[str], typer.Option("--comment", "-c")] = None,
    output_fmt: Annotated[OutputFormat, typer.Option("--output", "-o")] = OutputFormat.human,
):
    """Reopen a closed issue."""
    ensure_auth()

    if comment:
        run_gh(["issue", "comment", str(issue_number), "--body", comment], check=False)

    result = run_gh(["issue", "reopen", str(issue_number)], check=False)
    if result.returncode != 0:
        output({"error": f"Failed to reopen #{issue_number}"}, output_fmt)
        raise typer.Exit(code=1)

    output({"success": True, "issue_number": issue_number, "action": "reopened"}, output_fmt, f"Reopened #{issue_number}")


@app.command()
def comment(
    issue_number: Annotated[int, typer.Argument(help="Issue number")],
    body: Annotated[Optional[str], typer.Option("--body", "-b", help="Comment body")] = None,
    body_file: Annotated[Optional[str], typer.Option("--body-file", "-f", help="Read body from file")] = None,
    body_stdin: Annotated[bool, typer.Option("--stdin", help="Read body from stdin")] = False,
    output_fmt: Annotated[OutputFormat, typer.Option("--output", "-o")] = OutputFormat.human,
):
    """Add comment to issue. Use --body-file or --stdin for complex markdown with backticks."""
    ensure_auth()

    # Determine body content
    final_body = body
    if body_stdin:
        final_body = sys.stdin.read()
    elif body_file:
        try:
            with open(body_file, 'r', encoding='utf-8') as f:
                final_body = f.read()
        except FileNotFoundError:
            output({"error": f"File not found: {body_file}"}, output_fmt)
            raise typer.Exit(code=1)
    
    if not final_body:
        output({"error": "No body provided. Use --body, --body-file, or --stdin"}, output_fmt)
        raise typer.Exit(code=1)

    result = run_gh(["issue", "comment", str(issue_number), "--body", final_body], check=False)
    if result.returncode != 0:
        output({"error": f"Failed to comment on #{issue_number}"}, output_fmt)
        raise typer.Exit(code=1)

    output({"success": True, "issue_number": issue_number, "action": "commented"}, output_fmt, f"Commented on #{issue_number}")


@app.command()
def edit(
    issue_number: Annotated[int, typer.Argument(help="Issue number")],
    title: Annotated[Optional[str], typer.Option("--title", "-t")] = None,
    body: Annotated[Optional[str], typer.Option("--body", "-b")] = None,
    body_file: Annotated[Optional[str], typer.Option("--body-file", "-f", help="Read body from file")] = None,
    add_labels: Annotated[Optional[str], typer.Option("--add-labels")] = None,
    remove_labels: Annotated[Optional[str], typer.Option("--remove-labels")] = None,
    add_assignee: Annotated[Optional[str], typer.Option("--add-assignee")] = None,
    output_fmt: Annotated[OutputFormat, typer.Option("--output", "-o")] = OutputFormat.human,
):
    """Edit an issue. Use --body-file for complex markdown with backticks."""
    ensure_auth()

    # Determine body content
    final_body = body
    if body_file:
        try:
            with open(body_file, 'r', encoding='utf-8') as f:
                final_body = f.read()
        except FileNotFoundError:
            output({"error": f"File not found: {body_file}"}, output_fmt)
            raise typer.Exit(code=1)

    args = ["issue", "edit", str(issue_number)]
    if title:
        args.extend(["--title", title])
    if final_body:
        args.extend(["--body", final_body])
    if add_labels:
        args.extend(["--add-label", add_labels])
    if remove_labels:
        args.extend(["--remove-label", remove_labels])
    if add_assignee:
        args.extend(["--add-assignee", add_assignee])

    if len(args) == 3:
        rprint("[yellow]No changes specified.[/yellow]")
        raise typer.Exit(code=0)

    result = run_gh(args, check=False)
    if result.returncode != 0:
        output({"error": f"Failed to edit #{issue_number}"}, output_fmt)
        raise typer.Exit(code=1)

    output({"success": True, "issue_number": issue_number, "action": "edited"}, output_fmt, f"Edited #{issue_number}")


@app.command()
def search(
    query: Annotated[str, typer.Argument(help="Search query")],
    state: Annotated[IssueState, typer.Option("--state", "-s")] = IssueState.open,
    limit: Annotated[int, typer.Option("--limit", "-n")] = 30,
    output_fmt: Annotated[OutputFormat, typer.Option("--output", "-o")] = OutputFormat.human,
):
    """Search issues by text."""
    ensure_auth()

    result = run_gh([
        "issue", "list", "--search", query, "--state", state.value,
        "--limit", str(limit), "--json", "number,title,state,labels,author,createdAt"
    ], check=False)

    if result.returncode != 0:
        output({"error": "Search failed"}, output_fmt)
        raise typer.Exit(code=1)

    issues = json.loads(result.stdout) if result.stdout else []
    formatted = [{
        "number": i["number"],
        "title": i["title"],
        "state": i["state"],
        "labels": ", ".join(l["name"] for l in i.get("labels", [])),
        "created": i.get("createdAt", "")[:10],
    } for i in issues]

    output(formatted, output_fmt)


@app.command()
def labels(
    output_fmt: Annotated[OutputFormat, typer.Option("--output", "-o")] = OutputFormat.human,
):
    """List repository labels."""
    ensure_auth()

    result = run_gh(["label", "list", "--json", "name,description,color"], check=False)
    if result.returncode != 0:
        output({"error": "Failed to list labels"}, output_fmt)
        raise typer.Exit(code=1)

    labels_data = json.loads(result.stdout) if result.stdout else []
    formatted = [{"name": l["name"], "description": l.get("description", "")} for l in labels_data]

    output(formatted, output_fmt)


@app.command()
def status(
    output_fmt: Annotated[OutputFormat, typer.Option("--output", "-o")] = OutputFormat.human,
):
    """Show auth and repository status."""
    auth = run_gh(["auth", "status"], check=False)
    repo = run_gh(["repo", "view", "--json", "name,owner,url"], check=False)

    data = {"authenticated": auth.returncode == 0}

    if repo.returncode == 0:
        r = json.loads(repo.stdout)
        data["repository"] = f"{r.get('owner', {}).get('login', '')}/{r.get('name', '')}"
        data["url"] = r.get("url", "")
    else:
        data["repository"] = None

    output(data, output_fmt)


@app.command()
def schema():
    """Output tool schema as JSON for LLM integration."""
    print(json.dumps(TOOL_SCHEMA, indent=2))


@app.callback()
def main(
    version: Annotated[bool, typer.Option("--version", "-v")] = False,
):
    """GitHub Issues CLI - LLM-friendly tool for managing GitHub issues."""
    if version:
        rprint("gh-issues v1.0.0")
        raise typer.Exit()


if __name__ == "__main__":
    app()

