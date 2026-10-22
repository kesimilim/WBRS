"""Additive reviewed contacts migration. Dry-run is default; no source writes.

CLI configuration contains the existing database credentials outside Git.
Only counts and checksums are printed, never account IDs or source payloads.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import hmac
import json
from pathlib import Path
import ssl

from legacy_conversation_payload import document, payload_digest, identifier, timestamp_ns


def guest_row(path, encoded, digest):
    parts = path.split('/')
    if len(parts)!=4 or parts[0]!='users' or parts[2]!='visiters': raise ValueError('guest_path')
    owner, visitor = identifier(parts[1],uid=True), identifier(parts[3],uid=True)
    payload = document(encoded)
    if not hmac.compare_digest(payload_digest(payload),bytes(digest).hex()): raise ValueError('source_digest')
    saved = payload['fields'].get('uid')
    if saved != {'stringValue':visitor}: raise ValueError('guest_identity')
    value = payload['fields'].get('lastVisitTs')
    if type(value) is not dict or set(value)!={'timestampValue'}: raise ValueError('guest_time')
    nanos = timestamp_ns(value['timestampValue'])
    seconds, remainder = divmod(nanos,1_000_000_000)
    stamp = datetime.fromtimestamp(seconds,timezone.utc).replace(microsecond=remainder//1000,tzinfo=None)
    return owner,visitor,stamp


def prepare(connection):
    counts = Counter(); rows = []; digest = hashlib.sha256()
    with connection.cursor() as c:
        c.execute('START TRANSACTION READ ONLY')
        for table in ('friendships','friend_requests'):
            c.execute('SELECT COUNT(*) FROM '+table)
            if c.fetchone()[0]: raise ValueError('existing_friend_data_requires_projection')
        c.execute("SELECT COUNT(*) FROM legacy_documents WHERE SUBSTRING_INDEX(collection_path,'/',-1) IN ('friends','friend_requests','friend_requests_sent')")
        if c.fetchone()[0]: raise ValueError('retained_friend_data_requires_projection')
        c.execute('SELECT uid FROM accounts'); accounts={r[0] for r in c.fetchall()}
        c.execute("SELECT firebase_path,encoded_payload,payload_sha256 FROM legacy_documents WHERE collection_path LIKE '%/visiters' ORDER BY archive_id")
        pairs=set()
        for path,encoded,source_hash in c.fetchall():
            counts['source']+=1
            row=guest_row(path,encoded,source_hash)
            digest.update(bytes(source_hash))
            if row[0]==row[1]: counts['selfVisits']+=1;continue
            if row[0] not in accounts or row[1] not in accounts: counts['missingAccounts']+=1;continue
            if row[:2] in pairs: raise ValueError('duplicate_guest_pair')
            pairs.add(row[:2]);rows.append(row)
    connection.rollback()
    counts['eligible']=len(rows)
    return rows,{'counts':dict(counts),'sourceDigest':digest.hexdigest()}


def apply(connection, rows):
    schema=Path(__file__).parent.parent/'db'/'019_contacts_mysql84.sql'
    # Strip comments, then execute the two fixed CREATE statements only.
    raw='\n'.join(line for line in schema.read_text().splitlines() if not line.lstrip().startswith('--'))
    with connection.cursor() as c:
        for sql in raw.split(';'):
            if sql.strip(): c.execute(sql)
    connection.begin()
    try:
        with connection.cursor() as c:
            for offset in range(0,len(rows),250):
                c.executemany('INSERT INTO profile_visits(owner_uid,visitor_uid,last_visit_at) VALUES(%s,%s,%s) '
                    'ON DUPLICATE KEY UPDATE last_visit_at=IF(last_visit_at IS NULL,VALUES(last_visit_at),'
                    'GREATEST(last_visit_at,VALUES(last_visit_at)))',rows[offset:offset+250])
            c.execute('SELECT owner_uid,visitor_uid,last_visit_at FROM profile_visits')
            saved={(r[0],r[1]):r[2] for r in c.fetchall()}
            if any(saved.get(r[:2]) is None or saved[r[:2]]<r[2] for r in rows): raise ValueError('guest_readback_mismatch')
        connection.commit()
    except BaseException:
        connection.rollback();raise


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--config',type=Path,required=True)
    parser.add_argument('--password-file',type=Path)
    parser.add_argument('--ca',type=Path,required=True)
    parser.add_argument('--apply',action='store_true')
    args=parser.parse_args()
    import pymysql
    config=json.loads(args.config.read_text())
    config={k:config[k] for k in ('host','port','user','password','database')}
    if args.password_file:config['password']=args.password_file.read_text().strip()
    if config['database']!='clrs_staging':raise ValueError('wrong_database')
    context=ssl.create_default_context(cafile=str(args.ca))
    connection=pymysql.connect(**config,ssl=context,connect_timeout=8,read_timeout=20,write_timeout=20)
    try:
        rows,proof=prepare(connection)
        if args.apply:apply(connection,rows)
        print(json.dumps({**proof,'applied':args.apply,'sourceWrites':0},sort_keys=True))
    finally:connection.close()


if __name__=='__main__':
    try:main()
    except Exception as error:
        # SQL errors may include private row values; never print their text.
        print(json.dumps({'error':'contacts_migration_failed','type':type(error).__name__}))
        raise SystemExit(1)
