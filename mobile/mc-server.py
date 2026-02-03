#!/usr/bin/env python3
"""Mission Control Mobile Server — Token auth + SSE"""
import os
import json
import time
import secrets
import sqlite3
from flask import Flask, jsonify, request, Response, send_from_directory

app = Flask(__name__)
DB = os.path.expanduser('~/.openclaw/mission-control.db')
TOKEN = secrets.token_urlsafe(16)

# ═══════════════════════════════════════════
# AUTH
# ═══════════════════════════════════════════

@app.before_request
def check_token():
    # Allow static files and index without token
    if request.path == '/' or request.path.endswith('.html'):
        return
    # Check token for API routes
    if request.path.startswith('/api'):
        if request.args.get('token') != TOKEN:
            return jsonify({'error': 'unauthorized'}), 401

# ═══════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════

def get_db():
    conn = sqlite3.connect(DB)
    conn.row_factory = sqlite3.Row
    return conn

def row_to_dict(row):
    return dict(row) if row else None

# ═══════════════════════════════════════════
# STATIC FILES
# ═══════════════════════════════════════════

@app.route('/')
def index():
    return send_from_directory('.', 'index.html')

# ═══════════════════════════════════════════
# API ENDPOINTS
# ═══════════════════════════════════════════

@app.route('/api/board')
def board():
    conn = get_db()
    tasks = conn.execute('''
        SELECT id, subject, description, status, owner, priority,
               created_at, updated_at, claimed_at, completed_at
        FROM tasks
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
    ''').fetchall()

    agents = conn.execute('''
        SELECT name, role, status, last_seen
        FROM agents
        ORDER BY status, name
    ''').fetchall()

    conn.close()
    return jsonify({
        'tasks': [row_to_dict(t) for t in tasks],
        'agents': [row_to_dict(a) for a in agents],
        'timestamp': int(time.time() * 1000)
    })

@app.route('/api/task/<int:task_id>')
def task_detail(task_id):
    conn = get_db()
    task = conn.execute(
        'SELECT * FROM tasks WHERE id = ?', (task_id,)
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
    conn.execute('''
        UPDATE tasks
        SET owner = ?, status = 'in_progress',
            claimed_at = datetime('now'), updated_at = datetime('now')
        WHERE id = ?
    ''', (agent, task_id))
    conn.commit()
    conn.close()
    return jsonify({'success': True})

@app.route('/api/task/<int:task_id>/complete', methods=['POST'])
def complete_task(task_id):
    data = request.get_json() or {}
    note = data.get('note', '')
    conn = get_db()
    conn.execute('''
        UPDATE tasks
        SET status = 'done',
            completed_at = datetime('now'), updated_at = datetime('now')
        WHERE id = ?
    ''', (task_id,))

    if note:
        conn.execute('''
            INSERT INTO messages (from_agent, task_id, body, msg_type)
            VALUES ('mobile', ?, ?, 'status')
        ''', (task_id, note))

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
                result = conn.execute('''
                    SELECT MAX(updated_at) as latest FROM tasks
                ''').fetchone()
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
    print(f"  Mission Control Mobile Server")
    print(f"{'='*50}")
    print(f"\n  Local URL:")
    print(f"  http://localhost:3737/?token={TOKEN}")
    print(f"\n  For Tailscale/LAN access, use your IP:")
    print(f"  http://<your-ip>:3737/?token={TOKEN}")
    print(f"\n  Token: {TOKEN}")
    print(f"\n{'='*50}\n")

    app.run(host='0.0.0.0', port=3737, threaded=True)
