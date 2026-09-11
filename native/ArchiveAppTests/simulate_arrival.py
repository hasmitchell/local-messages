"""Add repeatable fictional arrivals for foreground and scrolled-history UI checks."""
import datetime
import json
from pathlib import Path
import sqlite3
import sys
import uuid

root = Path(sys.argv[1])
with sqlite3.connect(f"file:{root / 'archive.db'}?mode=rw", uri=True) as db:
    assert db.execute("SELECT value FROM metadata WHERE key='kind'").fetchone() == ('ui_fixture',), 'Synthetic archives only'
    body = sys.argv[2] if len(sys.argv) > 2 else 'A fictional reply arrived automatically.'
    mid = 'ui-arrival-' + str(uuid.uuid4())
    stamp = int(datetime.datetime.now().timestamp() * 1e6)
    payload = dict(id=mid, conversation_id='alex', body=body, sender='Alex Morgan', outgoing=False, transport='RCS', status='INCOMING_COMPLETE')
    db.execute('INSERT INTO messages VALUES(?,?,?,?,?,?)', (mid, 'alex', stamp, body, 'Alex Morgan', json.dumps(payload)))
    db.execute('INSERT INTO arrivals(message_id,conversation_id,timestamp) VALUES(?,?,?)', (mid, 'alex', stamp))
    db.execute("UPDATE conversations SET last_message=? WHERE id='alex'", (stamp,))
print('Inserted one fictional incoming message.')
