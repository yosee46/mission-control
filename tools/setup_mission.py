#!/usr/bin/env python3
"""
setup_mission — OMOS Team Composition Tool

Creates MC workspace + mission, then registers openclaw agents with
role-specific AGENTS.md and cron jobs for each team member.

Usage:
  setup_mission <project> <mission> "<goal>" --roles role1,role2,...
  setup_mission ec-site prototype "Django EC prototype" --roles researcher,backend,frontend,reviewer
  setup_mission my-app mvp "Build MVP" --roles coder --role-desc "Full-stack Python developer"
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

_PROFILE = os.environ.get("OPENCLAW_PROFILE", "")
CONFIG_DIR = Path.home() / f".openclaw-{_PROFILE}" if _PROFILE else Path.home() / ".openclaw"
TEMPLATE_DIR = CONFIG_DIR / "mc-templates"
PROJECTS_DIR = Path.home() / "projects"


def run(cmd: str, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess:
    """Run a shell command."""
    result = subprocess.run(
        cmd, shell=True, capture_output=capture, text=True,
    )
    if check and result.returncode != 0:
        if capture:
            print(f"  WARN: {cmd}", file=sys.stderr)
            if result.stderr:
                print(f"  {result.stderr.strip()}", file=sys.stderr)
        # Don't exit on non-zero — some commands may already exist
    return result


def load_template(role: str) -> str:
    """Load role-specific template, falling back to base.md."""
    # Map common role names to template files
    role_template_map = {
        "researcher": "researcher.md",
        "research": "researcher.md",
        "coder": "coder.md",
        "backend": "coder.md",
        "frontend": "coder.md",
        "developer": "coder.md",
        "engineer": "coder.md",
        "reviewer": "reviewer.md",
        "review": "reviewer.md",
        "qa": "reviewer.md",
    }

    template_file = role_template_map.get(role, None)

    if template_file and (TEMPLATE_DIR / template_file).exists():
        return (TEMPLATE_DIR / template_file).read_text()

    # Fallback to base template
    base_path = TEMPLATE_DIR / "base.md"
    if base_path.exists():
        return base_path.read_text()

    # Minimal fallback if no templates installed
    return """# {agent_id}

## Identity
You are **{agent_id}**, a {role_description} working on project **{project}**.

## Mission
- **Project**: {project}
- **Mission**: {mission}
- **Goal**: {goal}
- **Working Directory**: ~/projects/{project}/

## Workflow
1. `mc -w {project} -m {mission} checkin`
2. `mc -w {project} -m {mission} list --mine --status pending`
3. Claim highest-priority task: `mc -w {project} -m {mission} claim <id>`
4. Start work: `mc -w {project} -m {mission} start <id>`
5. Complete: `mc -w {project} -m {mission} done <id> -m "what I did"`
"""


def generate_role_description(role: str, custom_desc: str | None = None) -> str:
    """Generate a role description from role name or custom description."""
    if custom_desc:
        return custom_desc

    descriptions = {
        "researcher": "research and analysis specialist — technology investigation, library evaluation, best practices research",
        "coder": "implementation specialist — writing code, tests, and fixing bugs",
        "backend": "backend developer — server-side implementation, API design, database work",
        "frontend": "frontend developer — UI implementation, templates, CSS, client-side logic",
        "developer": "full-stack developer — implementation across the entire stack",
        "engineer": "software engineer — design and implementation of system components",
        "reviewer": "code reviewer and quality specialist — code review, security checks, quality assurance",
        "qa": "quality assurance specialist — testing, validation, and quality checks",
        "designer": "design specialist — UI/UX design, wireframes, and visual design",
        "devops": "DevOps engineer — deployment, infrastructure, CI/CD pipelines",
        "lead": "team lead — coordination, architecture decisions, and task management",
    }
    return descriptions.get(role, f"{role} specialist")


def generate_agents_md(
    agent_id: str,
    role: str,
    project: str,
    mission: str,
    goal: str,
    role_desc: str | None = None,
) -> str:
    """Generate AGENTS.md for a specific agent by filling template placeholders."""
    template = load_template(role)
    role_description = generate_role_description(role, role_desc)

    return template.format(
        agent_id=agent_id,
        role=role,
        project=project,
        mission=mission,
        goal=goal,
        role_description=role_description,
    )


def generate_cron_message(agent_id: str, project: str, mission: str, profile_env: str = "") -> str:
    """Generate the cron invocation message for an agent."""
    mc = f"{profile_env}mc" if profile_env else "mc"
    return (
        f"You are {agent_id}. Read your AGENTS.md, then execute your workflow: "
        f"{mc} -w {project} -m {mission} checkin && "
        f"{mc} -w {project} -m {mission} list --mine --status pending && "
        f"claim and work on your highest-priority task. "
        f"If no tasks, check {mc} -w {project} -m {mission} list --status pending for unclaimed work."
    )


def main():
    parser = argparse.ArgumentParser(
        description="OMOS Team Composition Tool — create MC workspace, mission, and agent team"
    )
    parser.add_argument("project", help="Project name (used as workspace name)")
    parser.add_argument("mission", help="Mission name")
    parser.add_argument("goal", help="Mission goal description")
    parser.add_argument(
        "--roles", required=True,
        help="Comma-separated list of roles (e.g., researcher,backend,frontend,reviewer)"
    )
    parser.add_argument(
        "--role-desc",
        help="Custom role description (applied to all roles if single role, otherwise ignored)"
    )
    parser.add_argument(
        "--cron", default="*/10 * * * *",
        help="Cron schedule for agents (default: every 10 minutes)"
    )
    parser.add_argument(
        "--profile",
        help="OpenClaw profile name (overrides OPENCLAW_PROFILE env var)"
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Show what would be done without executing"
    )

    args = parser.parse_args()

    # Resolve profile: CLI flag > env var
    profile = args.profile or os.environ.get("OPENCLAW_PROFILE", "")
    oc_profile_flag = f"--profile {profile}" if profile else ""
    profile_env = f"OPENCLAW_PROFILE={profile} " if profile else ""

    # Recalculate CONFIG_DIR based on resolved profile
    global CONFIG_DIR, TEMPLATE_DIR
    if profile:
        CONFIG_DIR = Path.home() / f".openclaw-{profile}"
    else:
        CONFIG_DIR = Path.home() / ".openclaw"
    TEMPLATE_DIR = CONFIG_DIR / "mc-templates"

    project = args.project
    mission = args.mission
    goal = args.goal
    roles = [r.strip() for r in args.roles.split(",") if r.strip()]
    cron_schedule = args.cron
    dry_run = args.dry_run

    if not roles:
        print("ERROR: At least one role is required", file=sys.stderr)
        sys.exit(1)

    print(f"═══ OMOS Team Setup ═══")
    print(f"  Project:  {project}")
    print(f"  Mission:  {mission}")
    print(f"  Goal:     {goal}")
    print(f"  Roles:    {', '.join(roles)}")
    if profile:
        print(f"  Profile:  {profile}")
    print(f"  Cron:     {cron_schedule}")
    print()

    if dry_run:
        print("[DRY RUN] No changes will be made.\n")

    # ─── Step 1: Create MC workspace ───
    print(f"[1/5] Creating MC workspace '{project}'...")
    if not dry_run:
        run(f'{profile_env}mc -w {project} init')
    print(f"  OK")

    # ─── Step 2: Create mission ───
    print(f"[2/5] Creating mission '{mission}'...")
    if not dry_run:
        escaped_goal = goal.replace("'", "'\\''")
        run(f"{profile_env}mc -w {project} mission create {mission} -d '{escaped_goal}'")
    print(f"  OK")

    # ─── Step 3: Create project directory ───
    project_dir = PROJECTS_DIR / project
    print(f"[3/5] Creating project directory '{project_dir}'...")
    if not dry_run:
        project_dir.mkdir(parents=True, exist_ok=True)
    print(f"  OK")

    # ─── Step 4: Register each agent ───
    print(f"[4/5] Registering agents...")
    agents_created = []

    for role in roles:
        agent_id = f"{project}-{role}"
        ws_dir = CONFIG_DIR / f"workspace-{agent_id}"

        print(f"\n  --- {agent_id} ---")

        # a. Create workspace directory
        print(f"  Creating workspace: {ws_dir}")
        if not dry_run:
            ws_dir.mkdir(parents=True, exist_ok=True)

        # b. Generate AGENTS.md
        agents_md = generate_agents_md(
            agent_id=agent_id,
            role=role,
            project=project,
            mission=mission,
            goal=goal,
            role_desc=args.role_desc if len(roles) == 1 else None,
        )
        agents_md_path = ws_dir / "AGENTS.md"
        print(f"  Writing AGENTS.md")
        if not dry_run:
            agents_md_path.write_text(agents_md)

        # c. Register openclaw agent
        print(f"  Registering openclaw agent: {agent_id}")
        if not dry_run:
            run(
                f"openclaw {oc_profile_flag} agents add {agent_id} "
                f"--workspace {ws_dir} "
                f"--non-interactive".strip(),
                check=False,
            )

        # d. Register in MC fleet
        print(f"  Registering in MC fleet")
        if not dry_run:
            run(
                f"{profile_env}MC_AGENT={agent_id} mc -w {project} register {agent_id} --role {role}",
                check=False,
            )

        # e. Add cron job
        cron_msg = generate_cron_message(agent_id, project, mission, profile_env)
        print(f"  Adding cron job")
        if not dry_run:
            escaped_msg = cron_msg.replace('"', '\\"')
            run(
                f'openclaw {oc_profile_flag} cron add '
                f'--agent {agent_id} '
                f'--name {agent_id} '
                f'--cron "{cron_schedule}" '
                f'--session isolated '
                f'--message "{escaped_msg}"'.strip(),
                check=False,
            )

        agents_created.append(agent_id)
        print(f"  OK — {agent_id} ready")

    # ─── Step 5: Summary ───
    mc_prefix = f"{profile_env}mc" if profile_env else "mc"
    print(f"\n[5/5] Summary")
    print(f"")
    print(f"═══ Team Ready ═══")
    print(f"  Workspace:  {mc_prefix} -w {project}")
    print(f"  Mission:    {mc_prefix} -w {project} -m {mission}")
    print(f"  Project:    {project_dir}/")
    if profile:
        print(f"  Profile:    {profile}")
    print(f"  Agents:     {len(agents_created)}")
    for a in agents_created:
        print(f"    - {a}")
    print(f"")
    print(f"Next: Use mc to add tasks for the team:")
    for role in roles:
        agent_id = f"{project}-{role}"
        print(f'  {mc_prefix} -w {project} -m {mission} add "Task description" --for {agent_id}')
    print(f"")
    print(f"Monitor:")
    print(f"  {mc_prefix} -w {project} -m {mission} board")
    print(f"  {mc_prefix} -w {project} fleet")


if __name__ == "__main__":
    main()
