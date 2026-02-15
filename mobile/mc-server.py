#!/usr/bin/env python3
"""Mission Control Mobile Server v0.2 — Token auth + SSE + Workspace/Mission support"""
import os
import sys
import json
import time
import secrets
import sqlite3
import argparse
from flask import Flask, jsonify, request, Response, send_from_directory

# ═══════════════════════════════════════════
# CLI ARGS
# ═══════════════════════════════════════════

parser = argparse.ArgumentParser(description='Mission Control Mobile Server')
parser.add_argument('--workspace', '-w',
    default=os.environ.get('MC_WORKSPACE', 'default'),
    help='Workspace name (default: $MC_WORKSPACE or "default")')
parser.add_argument('--mission', '-m',
    default=os.environ.get('MC_MISSION', 'default'),
    help='Mission name (default: $MC_MISSION or "default")')
parser.add_argument('--port', '-p', type=int, default=3737,
    help='Server port (default: 3737)')
parser.add_argument('--db',
    default=os.environ.get('MC_DB', ''),
    help='Direct DB path (overrides workspace resolution)')
args = parser.parse_args()

# ═══════════════════════════════════════════
# CONFIG
# ═══════════════════════════════════════════

app = Flask(__name__)
TOKEN = secrets.token_urlsafe(16)

if args.db:
    DB = args.db
    WORKSPACE = '(custom)'
else:
    WORKSPACE = args.workspace
    DB = os.path.expanduser(f'~/.openclaw/workspaces/{WORKSPACE}/mission-control.db')

MISSION_NAME = args.mission

if not os.path.exists(DB):
    print(f"Error: Database not found: {DB}", file=sys.stderr)
    print(f"Run: mc init -w {WORKSPACE}", file=sys.stderr)
    sys.exit(1)

# ═══════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════

def get_db():
    conn = sqlite3.connect(DB)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=5000")
    return conn

def row_to_dict(row):
    return dict(row) if row else None

def get_mission_id(conn):
    row = conn.execute(
        "SELECT id FROM missions WHERE name=?", (MISSION_NAME,)
    ).fetchone()
    if not row:
        return None
    return row['id']

# ═══════════════════════════════════════════
# AUTH
# ═══════════════════════════════════════════

@app.before_request
def check_token():
    if request.path == '/' or request.path.endswith('.html'):
        return
    if request.path.startswith('/api'):
        if request.args.get('token') != TOKEN:
            return jsonify({'error': 'unauthorized'}), 401

# ═══════════════════════════════════════════
# STATIC FILES
# ═══════════════════════════════════════════

@app.route('/')
def index():
    return send_from_directory('.', 'index.html')

# ═══════════════════════════════════════════
# API ENDPOINTS
# ═══════════════════════════════════════════

@app.route('/api/info')
def info():
    """Return current workspace/mission context."""
    conn = get_db()
    mid = get_mission_id(conn)
    missions = conn.execute(
        "SELECT id, name, status FROM missions ORDER BY id"
    ).fetchall()
    conn.close()
    return jsonify({
        'workspace': WORKSPACE,
        'mission': MISSION_NAME,
        'mission_id': mid,
        'missions': [row_to_dict(m) for m in missions]
    })

@app.route('/api/board')
def board():
    conn = get_db()
    mid = get_mission_id(conn)
    if mid is None:
        conn.close()
        return jsonify({'error': f'Mission "{MISSION_NAME}" not found'}), 404

    tasks = conn.execute('''
        SELECT id, subject, description, status, owner, priority,
               created_at, updated_at, claimed_at, completed_at
        FROM tasks
        WHERE mission_id = ?
        ORDER BY
            CASE status
                WHEN 'in_progress' THEN 1
                WHEN 'claimed' THEN 2
                WHEN 'pending' THEN 3
                WHEN 'blocked' THEN 4
                WHEN 'review' THEN 5
                WHEN 'done' THEN 6
            END,
            priority DESC,
            id
    ''', (mid,)).fetchall()

    agents = conn.execute('''
        SELECT name, role, status, last_seen
        FROM agents
        ORDER BY status, name
    ''').fetchall()

    conn.close()
    return jsonify({
        'tasks': [row_to_dict(t) for t in tasks],
        'agents': [row_to_dict(a) for a in agents],
        'workspace': WORKSPACE,
        'mission': MISSION_NAME,
        'timestamp': int(time.time() * 1000)
    })

@app.route('/api/task/<int:task_id>')
def task_detail(task_id):
    conn = get_db()
    mid = get_mission_id(conn)
    task = conn.execute(
        'SELECT * FROM tasks WHERE id = ? AND mission_id = ?',
        (task_id, mid)
    ).fetchone()

    messages = conn.execute('''
        SELECT id, from_agent, body, msg_type, created_at
        FROM messages
        WHERE task_id = ?
        ORDER BY created_at
    ''', (task_id,)).fetchall()

    conn.close()
    return jsonify({
        'task': row_to_dict(task),
        'messages': [row_to_dict(m) for m in messages]
    })

@app.route('/api/task/<int:task_id>/claim', methods=['POST'])
def claim_task(task_id):
    data = request.get_json() or {}
    agent = data.get('agent', 'mobile')
    conn = get_db()
    mid = get_mission_id(conn)
    conn.execute('''
        UPDATE tasks
        SET owner = ?, status = 'in_progress',
            claimed_at = datetime('now'), updated_at = datetime('now')
        WHERE id = ? AND mission_id = ?
    ''', (agent, task_id, mid))
    conn.commit()
    conn.close()
    return jsonify({'success': True})

@app.route('/api/task/<int:task_id>/complete', methods=['POST'])
def complete_task(task_id):
    data = request.get_json() or {}
    note = data.get('note', '')
    conn = get_db()
    mid = get_mission_id(conn)
    conn.execute('''
        UPDATE tasks
        SET status = 'done',
            completed_at = datetime('now'), updated_at = datetime('now')
        WHERE id = ? AND mission_id = ?
    ''', (task_id, mid))

    if note:
        conn.execute('''
            INSERT INTO messages (mission_id, from_agent, task_id, body, msg_type)
            VALUES (?, 'mobile', ?, ?, 'status')
        ''', (mid, task_id, note))

    conn.commit()
    conn.close()
    return jsonify({'success': True})

@app.route('/api/heartbeat')
def heartbeat():
    def stream():
        last_check = None
        while True:
            try:
                conn = get_db()
                mid = get_mission_id(conn)
                result = conn.execute('''
                    SELECT MAX(updated_at) as latest FROM tasks
                    WHERE mission_id = ?
                ''', (mid,)).fetchone()
                conn.close()

                latest = result['latest'] if result else None

                if latest != last_check:
                    last_check = latest
                    yield f"data: {json.dumps({'refresh': True, 'ts': int(time.time())})}\n\n"

                time.sleep(2)
            except GeneratorExit:
                break
            except Exception as e:
                yield f"data: {json.dumps({'error': str(e)})}\n\n"
                time.sleep(5)

    return Response(stream(), mimetype='text/event-stream',
                    headers={'Cache-Control': 'no-cache',
                             'X-Accel-Buffering': 'no'})

# ═══════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════

if __name__ == '__main__':
    print(f"\n{'='*50}")
    print(f"  Mission Control Mobile Server v0.2")
    print(f"{'='*50}")
    print(f"\n  Workspace: {WORKSPACE}")
    print(f"  Mission:   {MISSION_NAME}")
    print(f"  DB:        {DB}")
    print(f"\n  Local URL:")
    print(f"  http://localhost:{args.port}/?token={TOKEN}")
    print(f"\n  For Tailscale/LAN access, use your IP:")
    print(f"  http://<your-ip>:{args.port}/?token={TOKEN}")
    print(f"\n  Token: {TOKEN}")
    print(f"\n{'='*50}\n")

    app.run(host='0.0.0.0', port=args.port, threaded=True)
