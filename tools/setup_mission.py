#!/usr/bin/env python3
"""
setup_mission — OMOS Team Composition Tool

Creates MC project + mission, then registers openclaw agents with
role-specific AGENTS.md and cron jobs for each team member.

Every mission gets three supervisor agents (monitor, brain, escalator)
in addition to the worker agents specified by --roles.

Agents are named {project}-{mission}-{role} to ensure isolation per mission.
Cleanup: mc -p <project> -m <mission> mission complete

Usage:
  setup_mission <project> <mission> "<goal>" --roles role1,role2,...
  setup_mission ec-site prototype "Django EC prototype" --roles researcher,backend,frontend,reviewer
  setup_mission my-app mvp "Build MVP" --roles analyst --role-config roles.json
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

_PROFILE = os.environ.get("OPENCLAW_PROFILE", "")
CONFIG_DIR = Path.home() / f".openclaw-{_PROFILE}" if _PROFILE else Path.home() / ".openclaw"
TEMPLATE_DIR = CONFIG_DIR / "mc-templates"
SUPERVISOR_MODEL = os.environ.get("OMOS_SUPERVISOR_MODEL", "anthropic/claude-sonnet-4-5-20250929")

# Fallback descriptions when no role-config is provided
BUILTIN_DESCRIPTIONS = {
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


def safe_render(template: str, **kwargs: str) -> str:
    """Render template using str.replace() — safe for content containing braces."""
    result = template
    for key, value in kwargs.items():
        result = result.replace(f"{{{key}}}", value)
    return result


def load_role_config(path: str) -> dict:
    """Load roles.json file and return the roles dict."""
    p = Path(path)
    if not p.exists():
        print(f"ERROR: Role config not found: {path}", file=sys.stderr)
        sys.exit(1)
    try:
        data = json.loads(p.read_text())
    except json.JSONDecodeError as e:
        print(f"ERROR: Invalid JSON in {path}: {e}", file=sys.stderr)
        sys.exit(1)
    return data.get("roles", {})


def load_template() -> str:
    """Load base.md template."""
    base_path = TEMPLATE_DIR / "base.md"
    if base_path.exists():
        return base_path.read_text()

    # Minimal fallback if no templates installed
    return """# {agent_id}

## Identity
You are **{agent_id}**, a {role_description} working on project **{project}**.

## Mission Context
- **Project**: {project}
- **Mission**: {mission}
- **Goal**: {goal}
- **Working Directory**: {config_dir}/projects/{project}/
- **Role**: {role}

{role_specialization}

## Workflow
0. Cron Guard: `cron_id=$(openclaw cron list --json | python3 -c "import sys,json; [print(j['id']) for j in json.load(sys.stdin).get('jobs',[]) if j.get('name')=='{agent_id}']") && openclaw cron disable "$cron_id" && echo "[CRON_GUARD] {agent_id}: cron disabled — session started"`
1. `mc -p {project} -m {mission} checkin` — if PAUSED/COMPLETED/ARCHIVED, re-enable cron and stop
2. `mc -p {project} -m {mission} list --mine --status pending`
3. Claim highest-priority task: `mc -p {project} -m {mission} claim <id>`
4. Start work: `mc -p {project} -m {mission} start <id>`
5. Complete: `mc -p {project} -m {mission} done <id> -m "what I did"`
6. Re-enable cron: `openclaw cron enable "$cron_id" && echo "[CRON_GUARD] {agent_id}: cron re-enabled"`
"""


def generate_role_description(role: str, role_config: dict | None = None, custom_desc: str | None = None) -> str:
    """Generate a role description from role-config, custom description, or builtin fallback."""
    if custom_desc:
        return custom_desc
    if role_config and role in role_config:
        return role_config[role].get("description", f"{role} specialist")
    return BUILTIN_DESCRIPTIONS.get(role, f"{role} specialist")


def generate_role_specialization(role: str, role_config: dict | None = None) -> str:
    """Get role specialization from role-config. Returns empty string if not defined."""
    if role_config and role in role_config:
        return role_config[role].get("specialization", "")
    return ""


def generate_agents_md(
    agent_id: str,
    role: str,
    project: str,
    mission: str,
    goal: str,
    role_config: dict | None = None,
    role_desc: str | None = None,
    config_dir: str = "",
) -> str:
    """Generate AGENTS.md for a specific agent by filling template placeholders."""
    template = load_template()
    role_description = generate_role_description(role, role_config, role_desc)
    role_specialization = generate_role_specialization(role, role_config)

    # role_specialization must be replaced first so that placeholders
    # like {project} inside the specialization text are also rendered.
    return safe_render(
        template,
        role_specialization=role_specialization,
        role_description=role_description,
        agent_id=agent_id,
        role=role,
        project=project,
        mission=mission,
        goal=goal,
        config_dir=config_dir,
    )


def generate_cron_message(agent_id: str, project: str, mission: str, profile_env: str = "") -> str:
    """Generate the cron invocation message for an agent."""
    mc = f"{profile_env}mc" if profile_env else "mc"
    return (
        f"You are {agent_id}. Read your AGENTS.md, then execute your workflow: "
        f"{mc} -p {project} -m {mission} checkin — "
        f"if output contains MISSION_PAUSED, MISSION_COMPLETED, or MISSION_ARCHIVED then stop. "
        f"Otherwise: {mc} -p {project} -m {mission} list --mine --status pending && "
        f"claim and work on your highest-priority task. "
        f"If no tasks, check {mc} -p {project} -m {mission} list --status pending for unclaimed work. "
        f"日本語で応答すること。"
    )


def load_monitor_template() -> str:
    """Load monitor.md template."""
    monitor_path = TEMPLATE_DIR / "monitor.md"
    if monitor_path.exists():
        return monitor_path.read_text()

    # Inline fallback — observation-only monitor
    return """# {agent_id}

## Identity
You are **{agent_id}**, a mission observer (sensor), working on project **{project}**.
Your role is to observe and report anomalies to the brain agent. You do NOT make judgment calls or create tasks.

## Mission Context
- **Project**: {project}
- **Mission**: {mission}
- **Goal**: {goal}
- **Working Directory**: {config_dir}/projects/{project}/
- **Role**: monitor

## Monitoring Workflow
0. Cron Guard: `cron_id=$(openclaw cron list --json | python3 -c "import sys,json; [print(j['id']) for j in json.load(sys.stdin).get('jobs',[]) if j.get('name')=='{agent_id}']") && openclaw cron disable "$cron_id" && echo "[CRON_GUARD] {agent_id}: cron disabled — session started"`
1. `mc -p {project} -m {mission} checkin` — if PAUSED/COMPLETED/ARCHIVED, re-enable cron and stop
2. `mc -p {project} -m {mission} board` — check task progress
3. `mc -p {project} fleet` — check agent statuses for stale detection
4. `mc -p {project} -m {mission} inbox --unread` — check messages from brain
5. Observe and report: blocked tasks → msg brain; stale tasks → msg brain; all done → msg brain; stale agent crons → re-enable directly
6. Re-enable cron: `openclaw cron enable "$cron_id" && echo "[CRON_GUARD] {agent_id}: cron re-enabled"`

{monitor_policy}
"""


def load_brain_template() -> str:
    """Load brain.md template."""
    brain_path = TEMPLATE_DIR / "brain.md"
    if brain_path.exists():
        return brain_path.read_text()

    # Inline fallback — brain (commander) agent
    return """# {agent_id}

## Identity
You are **{agent_id}**, the mission brain (commander), working on project **{project}**.
You receive observation reports from the monitor agent and make all judgment and action decisions.

## Mission Context
- **Project**: {project}
- **Mission**: {mission}
- **Goal**: {goal}
- **Working Directory**: {config_dir}/projects/{project}/
- **Role**: brain

## Brain Workflow
0. Cron Guard: `cron_id=$(openclaw cron list --json | python3 -c "import sys,json; [print(j['id']) for j in json.load(sys.stdin).get('jobs',[]) if j.get('name')=='{agent_id}']") && openclaw cron disable "$cron_id" && echo "[CRON_GUARD] {agent_id}: cron disabled — session started"`
1. `mc -p {project} -m {mission} checkin` — if PAUSED/COMPLETED/ARCHIVED, re-enable cron and stop
2. `mc -p {project} -m {mission} mission status` — review state and user instructions
3. `mc -p {project} -m {mission} board` — check task progress
4. `mc -p {project} -m {mission} inbox --unread` — check monitor reports and agent questions
5. Judge and act: all tasks done → checkpoint or follow-up; user instructions → tasks; monitor alerts → reassign; escalation → escalator task; agent questions → answer
6. Task assignment: `mc -p {project} -m {mission} add "desc" --for <agent>` + re-enable target cron
7. Re-enable cron: `openclaw cron enable "$cron_id" && echo "[CRON_GUARD] {agent_id}: cron re-enabled"`

{brain_policy}
"""


def load_escalator_template() -> str:
    """Load escalator.md template."""
    escalator_path = TEMPLATE_DIR / "escalator.md"
    if escalator_path.exists():
        return escalator_path.read_text()

    # Inline fallback if template not installed
    return """# {agent_id}

## Identity
You are **{agent_id}**, the human escalation agent for project **{project}**.
You are the **sole channel** between the AI agent team and the human operator.

## Mission Context
- **Project**: {project}
- **Mission**: {mission}
- **Goal**: {goal}
- **Working Directory**: {config_dir}/projects/{project}/
- **Role**: escalator
- **Human Slack User**: <@{slack_user_id}>

## Escalation Policy
**MUST escalate:** human judgment needed, credentials needed, budget approval, destructive actions, unclear goals.
**Do NOT escalate:** technical choices, bug fixes, code review, task prioritization.

{escalation_policy}

## Workflow
0. Cron Guard: `cron_id=$(openclaw cron list --json | python3 -c "import sys,json; [print(j['id']) for j in json.load(sys.stdin).get('jobs',[]) if j.get('name')=='{agent_id}']") && openclaw cron disable "$cron_id" && echo "[CRON_GUARD] {agent_id}: cron disabled — session started"`
1. `mc -p {project} -m {mission} checkin` — if PAUSED/COMPLETED/ARCHIVED, re-enable cron and stop
2. `mc -p {project} -m {mission} mission status` — relay human instructions to requesting agents
3. `mc -p {project} -m {mission} list --mine --status pending` — process escalation tasks
4. No tasks → cron stays disabled (brain will re-enable when needed)
5. After processing tasks: `openclaw cron enable "$cron_id" && echo "[CRON_GUARD] {agent_id}: cron re-enabled"`
"""


def generate_monitor_cron_message(agent_id: str, project: str, mission: str, profile_env: str = "") -> str:
    """Generate the cron message for the monitor agent."""
    return (
        f"You are {agent_id}. Execute your monitoring workflow as described in your AGENTS.md. "
        f"日本語で応答すること。"
    )


def generate_brain_cron_message(agent_id: str, project: str, mission: str, profile_env: str = "") -> str:
    """Generate the cron message for the brain agent."""
    return (
        f"You are {agent_id}. Execute your brain workflow as described in your AGENTS.md. "
        f"日本語で応答すること。"
    )


def generate_escalator_cron_message(agent_id: str, project: str, mission: str, profile_env: str = "") -> str:
    """Generate the cron message for the escalator agent."""
    return (
        f"You are {agent_id}. Execute your escalation workflow as described in your AGENTS.md. "
        f"日本語で応答すること。"
    )


def register_agent(
    agent_id: str,
    role: str,
    project: str,
    ws_dir: Path,
    agents_md: str,
    cron_schedule: str,
    cron_msg: str,
    slack_channel: str,
    oc_profile_flag: str,
    profile_env: str,
    dry_run: bool,
    model: str | None = None,
) -> None:
    """Register a single agent: workspace, AGENTS.md, openclaw agent, MC fleet, cron."""
    # a. Create workspace
    print(f"  Creating workspace: {ws_dir}")
    if not dry_run:
        ws_dir.mkdir(parents=True, exist_ok=True)

    # b. Write AGENTS.md
    agents_md_path = ws_dir / "AGENTS.md"
    print(f"  Writing AGENTS.md")
    if not dry_run:
        agents_md_path.write_text(agents_md)

    # c. Register openclaw agent
    print(f"  Registering openclaw agent: {agent_id}")
    model_flag = f"--model {model} " if model else ""
    if not dry_run:
        run(
            f"openclaw {oc_profile_flag} agents add {agent_id} "
            f"--workspace {ws_dir} "
            f"{model_flag}"
            f"--non-interactive".strip(),
            check=False,
        )

    # d. Register in MC fleet
    print(f"  Registering in MC fleet")
    if not dry_run:
        run(
            f"{profile_env}MC_AGENT={agent_id} mc -p {project} register {agent_id} --role {role}",
            check=False,
        )

    # e. Add cron job
    print(f"  Adding cron job ({cron_schedule})")
    if not dry_run:
        escaped_msg = cron_msg.replace('"', '\\"')
        run(
            f'openclaw {oc_profile_flag} cron add '
            f'--agent {agent_id} '
            f'--name {agent_id} '
            f'--cron "{cron_schedule}" '
            f'--session isolated '
            f'--announce --channel slack --to {slack_channel} '
            f'--message "{escaped_msg}"'.strip(),
            check=False,
        )

    print(f"  OK — {agent_id} ready")


def main():
    parser = argparse.ArgumentParser(
        description="OMOS Team Composition Tool — create MC project, mission, and agent team"
    )
    parser.add_argument("project", help="Project name (used as MC project name)")
    parser.add_argument("mission", help="Mission name")
    parser.add_argument("goal", help="Mission goal description")
    parser.add_argument(
        "--roles", required=True,
        help="Comma-separated list of roles (e.g., researcher,backend,frontend,reviewer)"
    )
    parser.add_argument(
        "--role-config",
        help="Path to roles.json defining role descriptions and specializations"
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
        "--supervisor-cron", default="0 */6 * * *",
        help="Cron schedule for monitor and brain agents (default: every 6 hours)"
    )
    parser.add_argument(
        "--slack-channel", required=True,
        help="Slack channel ID for cron delivery (e.g., C0AD97HHZD3)"
    )
    parser.add_argument(
        "--slack-user-id", required=True,
        help="Slack user ID for @mention in escalation (e.g., U01ABCDEF)"
    )
    parser.add_argument(
        "--monitor-policy",
        help="Additional monitoring policy text for the monitor agent"
    )
    parser.add_argument(
        "--brain-policy",
        help="Brain policy text (how brain judges task creation, course correction)"
    )
    parser.add_argument(
        "--escalation-policy",
        help="Additional escalation policy text for the escalator agent"
    )
    parser.add_argument(
        "--plan",
        help="Path to plan.md file to copy into the project directory"
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
    projects_dir = CONFIG_DIR / "projects"

    project = args.project
    mission = args.mission
    goal = args.goal
    roles = [r.strip() for r in args.roles.split(",") if r.strip()]
    cron_schedule = args.cron
    supervisor_schedule = args.supervisor_cron
    dry_run = args.dry_run

    if not roles:
        print("ERROR: At least one role is required", file=sys.stderr)
        sys.exit(1)

    # Load role config if provided
    role_config = None
    if args.role_config:
        role_config = load_role_config(args.role_config)

    print(f"═══ OMOS Team Setup ═══")
    print(f"  Project:  {project}")
    print(f"  Mission:  {mission}")
    print(f"  Goal:     {goal}")
    print(f"  Roles:    {', '.join(roles)}")
    if args.role_config:
        print(f"  Config:   {args.role_config}")
    if profile:
        print(f"  Profile:  {profile}")
    print(f"  Cron:     {cron_schedule}")
    print(f"  Supervisor: {supervisor_schedule}")
    print(f"  Slack:    {args.slack_channel}")
    print(f"  Slack User: {args.slack_user_id}")
    print()

    if dry_run:
        print("[DRY RUN] No changes will be made.\n")

    # ─── Step 1: Create MC project ───
    print(f"[1/6] Creating MC project '{project}'...")
    if not dry_run:
        run(f'{profile_env}mc -p {project} init')
    print(f"  OK")

    # ─── Step 2: Create mission ───
    print(f"[2/6] Creating mission '{mission}'...")
    if not dry_run:
        escaped_goal = goal.replace("'", "'\\''")
        run(f"{profile_env}mc -p {project} mission create {mission} -d '{escaped_goal}'")
    print(f"  OK")

    # ─── Step 3: Create project directory ───
    project_dir = projects_dir / project
    print(f"[3/6] Creating project directory '{project_dir}'...")
    if not dry_run:
        project_dir.mkdir(parents=True, exist_ok=True)
    print(f"  OK")

    # ─── Step 3.5: Copy plan (if provided) ───
    if args.plan:
        plan_src = Path(args.plan)
        if not plan_src.exists():
            print(f"ERROR: Plan file not found: {args.plan}", file=sys.stderr)
            sys.exit(1)
        plan_dest = project_dir / "plan.md"
        print(f"  Copying plan to '{plan_dest}'...")
        if not dry_run:
            plan_dest.write_text(plan_src.read_text())
        print(f"  OK")

    # ─── Step 4: Register worker agents ───
    print(f"[4/6] Registering worker agents...")
    agents_created = []

    for role in roles:
        agent_id = f"{project}-{mission}-{role}"
        ws_dir = CONFIG_DIR / "agent_workspaces" / agent_id

        print(f"\n  --- {agent_id} ---")

        agents_md = generate_agents_md(
            agent_id=agent_id,
            role=role,
            project=project,
            mission=mission,
            goal=goal,
            role_config=role_config,
            role_desc=args.role_desc if len(roles) == 1 else None,
            config_dir=str(CONFIG_DIR),
        )
        cron_msg = generate_cron_message(agent_id, project, mission, profile_env)

        register_agent(
            agent_id=agent_id,
            role=role,
            project=project,
            ws_dir=ws_dir,
            agents_md=agents_md,
            cron_schedule=cron_schedule,
            cron_msg=cron_msg,
            slack_channel=args.slack_channel,
            oc_profile_flag=oc_profile_flag,
            profile_env=profile_env,
            dry_run=dry_run,
        )
        agents_created.append(agent_id)

    # ─── Step 5: Register supervisor agents (always: monitor, brain, escalator) ───
    print(f"\n[5/6] Registering supervisor agents...")

    # --- Monitor ---
    monitor_id = f"{project}-{mission}-monitor"
    ws_dir = CONFIG_DIR / "agent_workspaces" / monitor_id
    print(f"\n  --- {monitor_id} ---")

    monitor_template = load_monitor_template()
    monitor_md = safe_render(
        monitor_template,
        agent_id=monitor_id,
        project=project,
        mission=mission,
        goal=goal,
        monitor_policy=args.monitor_policy or "",
        slack_user_id=args.slack_user_id,
        config_dir=str(CONFIG_DIR),
    )
    monitor_msg = generate_monitor_cron_message(monitor_id, project, mission, profile_env)

    register_agent(
        agent_id=monitor_id,
        role="monitor",
        project=project,
        ws_dir=ws_dir,
        agents_md=monitor_md,
        cron_schedule=supervisor_schedule,
        cron_msg=monitor_msg,
        slack_channel=args.slack_channel,
        oc_profile_flag=oc_profile_flag,
        profile_env=profile_env,
        dry_run=dry_run,
        model=SUPERVISOR_MODEL,
    )
    agents_created.append(monitor_id)

    # --- Brain ---
    brain_id = f"{project}-{mission}-brain"
    ws_dir = CONFIG_DIR / "agent_workspaces" / brain_id
    print(f"\n  --- {brain_id} ---")

    brain_template = load_brain_template()
    brain_md = safe_render(
        brain_template,
        agent_id=brain_id,
        project=project,
        mission=mission,
        goal=goal,
        brain_policy=args.brain_policy or "",
        slack_user_id=args.slack_user_id,
        config_dir=str(CONFIG_DIR),
    )
    brain_msg = generate_brain_cron_message(brain_id, project, mission, profile_env)

    register_agent(
        agent_id=brain_id,
        role="brain",
        project=project,
        ws_dir=ws_dir,
        agents_md=brain_md,
        cron_schedule=supervisor_schedule,
        cron_msg=brain_msg,
        slack_channel=args.slack_channel,
        oc_profile_flag=oc_profile_flag,
        profile_env=profile_env,
        dry_run=dry_run,
        model=SUPERVISOR_MODEL,
    )
    agents_created.append(brain_id)

    # --- Escalator ---
    escalator_id = f"{project}-{mission}-escalator"
    ws_dir = CONFIG_DIR / "agent_workspaces" / escalator_id
    print(f"\n  --- {escalator_id} ---")

    escalator_template = load_escalator_template()
    escalator_md = safe_render(
        escalator_template,
        agent_id=escalator_id,
        project=project,
        mission=mission,
        goal=goal,
        slack_user_id=args.slack_user_id,
        escalation_policy=args.escalation_policy or "",
        config_dir=str(CONFIG_DIR),
    )
    escalator_msg = generate_escalator_cron_message(escalator_id, project, mission, profile_env)

    register_agent(
        agent_id=escalator_id,
        role="escalator",
        project=project,
        ws_dir=ws_dir,
        agents_md=escalator_md,
        cron_schedule=cron_schedule,
        cron_msg=escalator_msg,
        slack_channel=args.slack_channel,
        oc_profile_flag=oc_profile_flag,
        profile_env=profile_env,
        dry_run=dry_run,
        model=SUPERVISOR_MODEL,
    )
    agents_created.append(escalator_id)

    # ─── Step 6: Summary ───
    mc_prefix = f"{profile_env}mc" if profile_env else "mc"
    print(f"\n[6/6] Summary")
    print(f"")
    print(f"═══ Team Ready ═══")
    print(f"  Project:    {mc_prefix} -p {project}")
    print(f"  Mission:    {mc_prefix} -p {project} -m {mission}")
    print(f"  Project:    {project_dir}/")
    if args.plan:
        print(f"  Plan:       {project_dir / 'plan.md'}")
    if args.role_config:
        print(f"  Roles:      {args.role_config}")
    if profile:
        print(f"  Profile:    {profile}")
    print(f"  Agents:     {len(agents_created)}")
    for a in agents_created:
        print(f"    - {a}")
    print(f"  Monitor:    {project}-{mission}-monitor ({supervisor_schedule})")
    print(f"  Brain:      {project}-{mission}-brain ({supervisor_schedule})")
    print(f"  Escalator:  {project}-{mission}-escalator ({cron_schedule})")
    print(f"")
    if args.plan:
        print(f"Brain will read plan.md and create Phase 1 tasks automatically.")
        print(f"  View plan: {mc_prefix} -p {project} plan show")
        print(f"")
        print(f"Immediate start (optional):")
        oc_cmd = f"openclaw {oc_profile_flag} agents run {brain_id}".replace("  ", " ")
        print(f"  {oc_cmd}")
    else:
        print(f"Next: Use mc to add tasks for the team:")
        for role in roles:
            agent_id = f"{project}-{mission}-{role}"
            print(f'  {mc_prefix} -p {project} -m {mission} add "Task description" --for {agent_id}')
    print(f"")
    print(f"Monitor:")
    print(f"  {mc_prefix} -p {project} -m {mission} board")
    print(f"  {mc_prefix} -p {project} fleet")
    print(f"")
    print(f"Cleanup (when mission is done):")
    print(f"  {mc_prefix} -p {project} -m {mission} mission complete")


if __name__ == "__main__":
    main()
