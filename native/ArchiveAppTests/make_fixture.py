#!/usr/bin/env python3
"""Create synthetic messages only. Never overwrite an existing archive."""
import datetime as dt
import json
import os
from pathlib import Path
import sqlite3
import struct
import sys
import zlib

os.umask(0o077)
root = Path(sys.argv[1]).resolve()
root.mkdir(parents=True, exist_ok=True)
if (root / 'archive.db').exists():
    raise SystemExit('Choose a new fixture directory; archive already exists.')
(root / 'media').mkdir()

# Procedural illustration for thumbnail and Quick Look checks; no personal media.
width, height = 800, 540
pixels = bytearray()
for y in range(height):
    pixels.append(0)
    for x in range(width):
        if (x - 615) ** 2 + (y - 110) ** 2 < 48 ** 2:
            color = (255, 223, 156)
        elif y > 395 + x * 0.07:
            color = (231, 215, 180)
        elif y > 240 + 36 * ((x / width) - 0.5):
            color = (56, 132 + (y % 18), 148)
        elif y > 210 - abs(x - 210) * 0.5 and x < 500:
            color = (86, 117, 116)
        else:
            color = (188 - y // 18, 216 - y // 35, 224 - y // 48)
        pixels.extend(color)
def chunk(kind, data):
    return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b'')
(root / 'media' / 'coast.png').write_bytes(png)

# vCard fixtures exercise the same MIME casing and missing-name cases as the phone.
vcard = '\r\n'.join([
    'BEGIN:VCARD', 'VERSION:3.0', 'N:Rivera;Zoë;;;', 'FN:Zoë Rivera',
    'ORG:Coastal Studio', 'TEL;TYPE=CELL:+61 400 000 001', 'TEL;TYPE=WORK:+61 2 5550 0100',
    'EMAIL;TYPE=WORK:zoe@example.invalid', 'ADR;TYPE=WORK:;;10 Example Street;Sydney;NSW;2000;Australia',
    'URL:https://example.invalid/a-long-', ' folded-path', 'END:VCARD',
    'BEGIN:VCARD', 'VERSION:3.0', 'N:Example\\;Jr.;Sam;;;', 'FN:Sam Example\\;Jr.',
    'TEL;TYPE=HOME:+61 400 000 002', 'END:VCARD', ''
]).encode()
(root / 'media' / 'shared-contact.vcf').write_bytes(vcard)

db = sqlite3.connect(root / 'archive.db')
db.execute('PRAGMA journal_mode=WAL')
db.executescript('''
CREATE TABLE conversations(id TEXT PRIMARY KEY,name TEXT NOT NULL,folder TEXT NOT NULL,last_message INTEGER NOT NULL,unread INTEGER NOT NULL);
CREATE TABLE messages(id TEXT PRIMARY KEY,conversation_id TEXT NOT NULL,timestamp INTEGER NOT NULL,body TEXT NOT NULL,sender TEXT NOT NULL,payload BLOB NOT NULL);
CREATE INDEX messages_conversation_time ON messages(conversation_id,timestamp);
CREATE VIRTUAL TABLE message_search USING fts5(body,sender,content='messages',content_rowid='rowid',tokenize='unicode61 remove_diacritics 2');
CREATE TRIGGER messages_insert AFTER INSERT ON messages BEGIN INSERT INTO message_search(rowid,body,sender) VALUES(new.rowid,new.body,new.sender); END;
CREATE TABLE outbox(id TEXT PRIMARY KEY,conversation_id TEXT NOT NULL,body TEXT NOT NULL,state TEXT NOT NULL,reason TEXT NOT NULL,created INTEGER NOT NULL,updated INTEGER NOT NULL,remote_id TEXT NOT NULL);
CREATE TABLE arrivals(sequence INTEGER PRIMARY KEY AUTOINCREMENT,message_id TEXT NOT NULL UNIQUE,conversation_id TEXT NOT NULL,timestamp INTEGER NOT NULL);
CREATE TABLE progress(conversation_id TEXT PRIMARY KEY,payload BLOB NOT NULL);
CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE conversation_details(id TEXT PRIMARY KEY,payload BLOB NOT NULL);
CREATE TABLE outbox_commands(id TEXT PRIMARY KEY,payload BLOB NOT NULL);
INSERT INTO metadata VALUES('kind','ui_fixture');
''')
now = dt.datetime(2026, 9, 10, 8, 0, tzinfo=dt.timezone.utc)
contacts = [('alex', 'Alex Morgan', 'INBOX'), ('weekend', 'Weekend plans', 'INBOX'), ('maya', 'Maya Chen', 'INBOX'), ('dad', 'Dad', 'INBOX'), ('studio', 'Studio crew', 'INBOX'), ('sam', 'Sam Taylor', 'INBOX'), ('delivery', 'Parcel updates', 'INBOX'), ('archive', 'Old apartment', 'ARCHIVE'), ('empty', 'Earlier conversation', 'ARCHIVE')]
for n, (cid, name, folder) in enumerate(contacts):
    stamp = int((now - dt.timedelta(days=n)).timestamp() * 1e6)
    db.execute('INSERT INTO conversations VALUES(?,?,?,?,0)', (cid, name, folder, stamp))
    people = [{'id': cid, 'name': name, 'number': '+61 400 000 ' + str(n + 1).zfill(3), 'is_me': False}, {'id': 'self', 'name': 'You', 'number': '+61 400 000 000', 'is_me': True}]
    db.execute('INSERT INTO conversation_details VALUES(?,?)', (cid, json.dumps(people).encode()))
    if cid == 'empty':
        continue
    count = 245 if cid == 'alex' else 5
    for i in range(count):
        timestamp = stamp - (count - 1 - i) * 60_000_000
        outgoing = i % 3 == 1
        body = f'Synthetic message {i + 1}: a little update for our plans.'
        if i == 0 and cid == 'alex': body = 'The old lighthouse booking reference is BOOKING-ALPHA.'
        if i == 11 and cid == 'alex': body = 'Café table confirmed. Search should find cafe too.'
        if i == 10 and cid == 'alex': body = 'Shared links: https://example.invalid/weekend and https://example.invalid/photos. Email hello@example.invalid is not a website gallery item.'
        if i == 30 and cid == 'alex': body = 'Another visit to https://example.invalid/weekend.'
        if i == 20 and cid == 'alex': body = 'Quotes, punctuation, and literal OR terms are ordinary message text.'
        if cid == 'alex' and i >= count - 7:
            body = ['Are we still heading to the coast this weekend?', 'Absolutely. I found a little place near the beach.', 'That sounds perfect. Can you send me the details?', 'The booking is confirmed for Saturday. Check-in is after 2 pm.', 'Here’s a little illustration of the view 🌊', 'Love it! I’ll bring coffee for the drive.', 'Perfect. See you at nine!'][i - (count - 7)]
        if cid != 'alex':
            body = {'weekend': 'Saturday morning works for everyone ☀️', 'maya': 'Thanks! I’ll take a look this afternoon.', 'dad': 'Give me a call when you get home.', 'studio': 'The latest sketches look great.', 'sam': 'See you at the café tomorrow.', 'delivery': 'Your parcel has been delivered.', 'archive': 'The keys are ready for collection.'}[cid]
        mid = f'{cid}-{i:04d}'
        payload = {'id': mid, 'conversation_id': cid, 'body': body, 'sender': 'You' if outgoing else name, 'outgoing': outgoing, 'transport': 'RCS' if cid != 'delivery' else 'SMS', 'status': 'OUTGOING_DELIVERED' if outgoing else 'INCOMING_COMPLETE', 'timestamp': dt.datetime.fromtimestamp(timestamp / 1e6, dt.timezone.utc).isoformat()}
        if cid == 'alex' and i == count - 3:
            payload['attachments'] = [{'id': 'coast', 'name': 'Coast illustration.png', 'mime': 'image/png', 'size': len(png), 'path': 'media/coast.png', 'state': 'downloaded_original', 'key': 'PRIVATE_SYNTHETIC_KEY', 'media_id': 'PRIVATE_SYNTHETIC_REFERENCE'}]
        if cid == 'alex' and i == count - 2:
            payload['reactions'] = [{'emoji': '❤️', 'participants': ['alex']}]
            payload['reply_to'] = f'alex-{count-3:04d}'
        if cid == 'dad' and i == 2:
            body = payload['body'] = ''
            payload['attachments'] = [{'id': 'contact', 'name': 'Shared contact.vcf', 'mime': 'text/x-vCard', 'size': len(vcard), 'path': 'media/shared-contact.vcf', 'state': 'downloaded_original'}]
        db.execute('INSERT INTO messages VALUES(?,?,?,?,?,?)', (mid, cid, timestamp, body, payload['sender'], json.dumps(payload).encode()))
db.commit()
db.close()
print(root)
