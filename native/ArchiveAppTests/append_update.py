"""Inject an update into an explicitly synthetic fixture for live-refresh checks."""
import json
from pathlib import Path
import sqlite3
import sys

archive = Path(sys.argv[1])
with sqlite3.connect(f"file:{archive / 'archive.db'}?mode=rw", uri=True) as db:
    assert db.execute("SELECT value FROM metadata WHERE key='kind'").fetchone() == ('ui_fixture',), 'Synthetic fixtures only'
    timestamp, payload = db.execute("SELECT timestamp,payload FROM messages WHERE id='alex-0244'").fetchone()
    newest = json.loads(payload)
    newest.update(outgoing=False,status='INCOMING_COMPLETE',id='live-fixture-arrival', body='A new booking update arrived while you were reading.', timestamp='2026-09-10T08:01:00Z')
    db.execute('INSERT INTO messages VALUES(?,?,?,?,?,?)', (newest['id'], 'alex', timestamp + 60_000_000, newest['body'], newest['sender'], json.dumps(newest)))
    if db.execute("SELECT count(*) FROM sqlite_master WHERE name='arrivals'").fetchone()[0]:
        db.execute('INSERT INTO arrivals(message_id,conversation_id,timestamp) VALUES(?,?,?)',(newest['id'],'alex',timestamp+60_000_000))
        db.execute("INSERT INTO outbox VALUES('fixture-unconfirmed','alex','A synthetic send with a lost response.','unknown','response_lost',?,?, '')",(timestamp+120_000_000,timestamp+120_000_000))
        db.execute("INSERT INTO outbox VALUES('fixture-failed','alex','A synthetic draft that was not sent.','failed','offline',?,?, '')",(timestamp+121_000_000,timestamp+121_000_000))
    old = json.loads(db.execute("SELECT payload FROM messages WHERE id='alex-0000'").fetchone()[0])
    old['body'] = 'The old lighthouse booking reference is BOOKING-BETA. Updated live.'
    old['reactions'] = [{'emoji':'👍','participants':['fixture-me']}]
    db.execute('UPDATE messages SET body=?,payload=? WHERE id=?', (old['body'], json.dumps(old), old['id']))
    db.execute('UPDATE conversations SET last_message=? WHERE id=?', (timestamp + 60_000_000, 'alex'))
print('Applied one synthetic arrival and one edit/reaction.')
