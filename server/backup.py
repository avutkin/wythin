"""Encrypted off-server snapshots. This module never restores over production."""
from __future__ import annotations

import argparse
import asyncio
from datetime import datetime, timedelta, timezone
import fcntl
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import tempfile
import time
from urllib.parse import unquote, urlparse
import uuid

MAX_RAW_BYTES = 1_500_000


def run(command, **kwargs):
    error_log = kwargs.pop('error_log', None)
    result = subprocess.run(command, stdout=kwargs.pop('stdout', subprocess.PIPE),
        stderr=subprocess.PIPE, text=kwargs.pop('text', True), timeout=kwargs.pop('timeout', 21600), **kwargs)
    if result.returncode:
        if error_log:
            Path(error_log).write_bytes(result.stderr.encode() if isinstance(result.stderr, str) else result.stderr)
        # Credentials are environment/file based. Do not echo command output,
        # which may contain record paths or connection details, into the journal.
        raise RuntimeError(f'{Path(command[0]).name} failed with exit {result.returncode}')
    return result


def file_sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def object_path(row):
    if row['storage_backend'] != 's3':
        raise ValueError('unsupported manifest backend; configure its backup before continuing')
    user, chunk = str(uuid.UUID(str(row['user_id']))), str(uuid.UUID(str(row['chunk_id'])))
    digest = row['sha256']
    if not re.fullmatch('[a-f0-9]{64}', digest) or not 0 <= row['byte_count'] <= MAX_RAW_BYTES:
        raise ValueError('invalid archive manifest')
    return f'archive/raw/v1/{user}/{chunk}/{digest}.jsonl.gz'


def verify_listing(rows, nodes):
    missing = {'/database.dump', '/manifest.json'} | {'/' + object_path(row) for row in rows}
    for node in nodes:
        missing.discard(node.get('path'))
    if missing:
        raise ValueError(f'backup is missing {len(missing)} required objects')


def verify_restore(root):
    root = Path(root)
    manifest = json.loads((root / 'manifest.json').read_text())
    if file_sha256(root / 'database.dump') != manifest['database_sha256']:
        raise ValueError('restored database integrity mismatch')
    count = 0
    for row in manifest_rows(root, manifest):
        path = root / object_path(row)
        if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
            raise ValueError('unsafe restored object')
        with gzip.open(path, 'rb') as stream:
            payload = stream.read(MAX_RAW_BYTES + 1)
        if len(payload) != row['byte_count'] or hashlib.sha256(payload).hexdigest() != row['sha256']:
            raise ValueError('restored raw integrity mismatch')
        count += 1
    return count


def manifest_rows(root, manifest):
    if manifest.get('format', 1) == 1:
        yield from manifest['raw_chunks']
        return
    path = Path(root) / 'raw-manifest.jsonl'
    if file_sha256(path) != manifest['raw_manifest_sha256']:
        raise ValueError('raw manifest integrity mismatch')
    count = 0
    with path.open() as stream:
        for line in stream:
            yield json.loads(line)
            count += 1
    if count != manifest['raw_chunks_count']:
        raise ValueError('raw manifest count mismatch')


class ContentAudit:
    """Disk-backed path and verification ledger; memory does not grow with archive size."""
    def __init__(self, path, rows, previous):
        self.db = sqlite3.connect(path)
        self.db.execute('PRAGMA cache_size=-32768')
        self.db.execute('PRAGMA temp_store=FILE')
        self.db.execute('CREATE TABLE IF NOT EXISTS state(snapshot TEXT)')
        self.db.execute('CREATE TABLE IF NOT EXISTS verified(path TEXT PRIMARY KEY)')
        self.db.execute('DROP TABLE IF EXISTS expected')
        self.db.execute('CREATE TABLE expected(path TEXT PRIMARY KEY, digest TEXT, bytes INTEGER, seen INTEGER DEFAULT 0, dirty INTEGER DEFAULT 1)')
        with self.db:
            self.db.executemany('INSERT INTO expected(path,digest,bytes) VALUES(?,?,?)',
                (('/'+object_path(row), row['sha256'], row['byte_count']) for row in rows))
            self.db.executemany('INSERT INTO expected(path,dirty) VALUES(?,0)',
                ((p,) for p in ('/database.dump','/manifest.json','/raw-manifest.jsonl')))
            if previous and self.previous() == previous:
                self.db.execute('UPDATE expected SET dirty=0 WHERE path IN (SELECT path FROM verified)')

    def previous(self):
        record = self.db.execute('SELECT snapshot FROM state').fetchone()
        return record[0] if record else None

    def listed(self, nodes):
        with self.db:
            self.db.executemany('UPDATE expected SET seen=1 WHERE path=?',
                ((node.get('path'),) for node in nodes if node.get('path')))
        missing = self.db.execute('SELECT count(*) FROM expected WHERE seen=0').fetchone()[0]
        if missing:
            raise ValueError(f'backup is missing {missing} required objects')

    def changed(self, events):
        with self.db:
            self.db.executemany('UPDATE expected SET dirty=1 WHERE path=?',
                ((event['path'],) for event in events if event.get('message_type') == 'change'))

    def verify(self, read_captured):
        checked = 0
        for path, digest, size in self.db.execute('SELECT path,digest,bytes FROM expected WHERE dirty=1 AND digest IS NOT NULL'):
            compressed = read_captured(path)
            with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as stream:
                payload = stream.read(MAX_RAW_BYTES + 1)
            if len(payload) != size or hashlib.sha256(payload).hexdigest() != digest:
                raise ValueError('captured raw integrity mismatch')
            checked += 1
        return checked

    def verify_batches(self, restore_batch, work, max_files=1000, max_bytes=128 * 1024 * 1024):
        """Read captured data in bounded batches, without one SFTP session per chunk."""
        if max_files < 1 or max_bytes < 1:
            raise ValueError('invalid verification batch limit')
        checked, batch, size = 0, [], 0

        def verify_batch(rows):
            with tempfile.TemporaryDirectory(prefix='raw-check-', dir=work) as temporary:
                target = Path(temporary)
                restore_batch([row[0] for row in rows], target)
                for path, digest, expected_size in rows:
                    restored = target / path.lstrip('/')
                    if restored.is_symlink() or not restored.resolve().is_relative_to(target.resolve()):
                        raise ValueError('unsafe captured object')
                    with gzip.open(restored, 'rb') as stream:
                        payload = stream.read(MAX_RAW_BYTES + 1)
                    if len(payload) != expected_size or hashlib.sha256(payload).hexdigest() != digest:
                        raise ValueError('captured raw integrity mismatch')

        for row in self.db.execute('SELECT path,digest,bytes FROM expected WHERE dirty=1 AND digest IS NOT NULL'):
            if batch and (len(batch) >= max_files or size + row[2] > max_bytes):
                verify_batch(batch)
                checked += len(batch)
                batch, size = [], 0
            batch.append(row)
            size += row[2]
        if batch:
            verify_batch(batch)
            checked += len(batch)
        return checked

    def commit(self, snapshot):
        with self.db:
            self.db.execute('DELETE FROM verified')
            self.db.execute('INSERT INTO verified SELECT path FROM expected WHERE digest IS NOT NULL')
            self.db.execute('DELETE FROM state')
            self.db.execute('INSERT INTO state VALUES(?)', (snapshot,))

    def close(self):
        self.db.close()


def prune_candidates(snapshots, current, previous, now):
    cutoff = now - timedelta(days=30)
    return [item['id'] for item in snapshots if item['id'] not in (current, previous)
            and datetime.fromisoformat(item['time'].replace('Z', '+00:00')) < cutoff]


def pg_environment(dsn):
    parsed = urlparse(dsn)
    if parsed.scheme not in ('postgres', 'postgresql') or not parsed.hostname:
        raise ValueError('invalid database connection configuration')
    env = os.environ.copy()
    env.update(PGHOST=parsed.hostname, PGPORT=str(parsed.port or 5432),
        PGUSER=unquote(parsed.username or ''), PGPASSWORD=unquote(parsed.password or ''),
        PGDATABASE=unquote(parsed.path.lstrip('/')))
    return env


async def export_database(dsn, source):
    import asyncpg
    connection = await asyncpg.connect(dsn)
    try:
        async with connection.transaction(isolation='repeatable_read', readonly=True):
            snapshot = await connection.fetchval('SELECT pg_export_snapshot()')
            backend_exists = await connection.fetchval("""SELECT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_schema='public' AND table_name='raw_chunks' AND column_name='storage_backend')""")
            raw_exists = await connection.fetchval("SELECT to_regclass('public.raw_chunks')")
            count = 0
            raw_manifest = source / 'raw-manifest.jsonl'
            with raw_manifest.open('w') as stream:
                if raw_exists:
                    backend = 'storage_backend' if backend_exists else "'filesystem' AS storage_backend"
                    query = 'SELECT user_id, chunk_id, sha256, byte_count, ' + backend + ' FROM raw_chunks ORDER BY user_id, chunk_id'
                    async for record in connection.cursor(query, prefetch=500):
                        row = dict(record, user_id=str(record['user_id']), chunk_id=str(record['chunk_id']))
                        object_path(row)
                        stream.write(json.dumps(row, sort_keys=True)+'\n')
                        count += 1
            with (source / 'database.dump').open('wb') as output:
                run(['pg_dump', '--format=custom', '--no-owner', '--no-acl', '--snapshot', snapshot],
                    env=pg_environment(dsn), stdout=output)
            run(['pg_restore', '--list', str(source / 'database.dump')])
            manifest = {'format': 2, 'created_at': datetime.now(timezone.utc).isoformat(),
                'raw_chunks_count': count, 'raw_manifest_sha256': file_sha256(raw_manifest),
                'database_sha256': file_sha256(source / 'database.dump')}
            (source / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True))
            return manifest
    finally:
        await connection.close()


def restic_command(config, args):
    env = os.environ.copy()
    env.update(RESTIC_PASSWORD_FILE=config['password_file'],
        RESTIC_CACHE_DIR=str(Path(config['workdir']) / 'cache'))
    return ['restic', '-r', config['repository'], '-o', 'sftp.command=' + config['ssh_command'], *args], env


def restic(config, *args, **kwargs):
    command, env = restic_command(config, args)
    return run(command, env=env, error_log=Path(config['workdir']) / 'command-errors.log', **kwargs)


def restic_lines(config, *args):
    command, env = restic_command(config, args)
    with tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=errors, text=True)
        try:
            for line in process.stdout:
                yield json.loads(line)
            if process.wait():
                raise RuntimeError('restic streaming operation failed')
        finally:
            process.stdout.close()
            if process.poll() is None:
                process.kill()
                process.wait()


def restore(config, snapshot, target):
    if not re.fullmatch('[a-f0-9]{8,64}', snapshot):
        raise ValueError('restore requires an explicit snapshot ID')
    target = Path(target)
    if target.exists():
        raise ValueError('restore target must not already exist')
    target.mkdir(parents=True, mode=0o700)
    restic(config, 'restore', snapshot, '--target', str(target), '--verify')
    return verify_restore(target)


def backup(config):
    from dotenv import dotenv_values
    work = Path(config['workdir'])
    source = Path(config['source_dir'])
    mount = source / 'archive'
    work.mkdir(parents=True, exist_ok=True, mode=0o700)
    source.mkdir(parents=True, exist_ok=True, mode=0o700)
    mount.mkdir(exist_ok=True, mode=0o700)
    if os.path.ismount(mount) or any(mount.iterdir()):
        raise RuntimeError('archive mount is stale or contains unexpected local files')
    archive = dotenv_values(config['archive_env'])
    app = dotenv_values(config['app_env'])
    if not app.get('DATABASE_URL'):
        raise ValueError('missing database configuration')
    # A failed HEAD/list must fail the run rather than produce an empty archive.
    run(['rclone', '--config', config['rclone_config'], 'lsf', 'primary:' + archive['RAW_S3_BUCKET'],
         '--max-depth', '1'])
    restic(config, 'snapshots', '--json')  # Require an already initialized, readable encrypted repo.
    if not Path(config['recovery_bundle']).is_file():
        raise RuntimeError('encrypted recovery bundle is missing')
    manifest = asyncio.run(export_database(app['DATABASE_URL'], source))
    configuration = source / 'configuration'
    configuration.mkdir(exist_ok=True, mode=0o700)
    shutil.copyfile(config['archive_env'], configuration / 'archive.env')
    shutil.copyfile(config['app_env'], configuration / 'app.env')
    shutil.copyfile(config['recovery_bundle'], configuration / 'recovery.age')
    process = subprocess.Popen(['rclone', '--config', config['rclone_config'], 'mount',
        'primary:' + archive['RAW_S3_BUCKET'], str(mount), '--read-only',
        '--vfs-cache-mode', 'off', '--file-perms', '0600', '--dir-perms', '0700',
        '--buffer-size', '4M', '--log-level', 'ERROR', '--log-file', str(work / 'mount-errors.log')],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    run_tag = 'run-' + uuid.uuid4().hex
    audit = None
    try:
        for _ in range(60):
            if process.poll() is not None:
                raise RuntimeError('archive mount failed')
            if os.path.ismount(mount):
                break
            time.sleep(0.5)
        else:
            raise RuntimeError('archive mount timed out')
        result = restic(config, 'backup', '--json', '--host', config['host'], '--ignore-inode',
            '--tag', 'wythin-managed', '--tag', 'pending', '--tag', run_tag,
            'database.dump', 'manifest.json', 'raw-manifest.jsonl', 'configuration', 'archive', cwd=source)
        summaries = [item for line in result.stdout.splitlines()
                     if (item := json.loads(line)).get('message_type') == 'summary']
        if not summaries or not summaries[-1].get('snapshot_id'):
            raise RuntimeError('backup did not return a snapshot')
        snapshot = summaries[-1]['snapshot_id']
        previous_status = work / 'last-success.json'
        previous = json.loads(previous_status.read_text())['snapshot_id'] if previous_status.exists() else None
        audit = ContentAudit(work / 'verified-content.sqlite', manifest_rows(source, manifest), previous)
        audit.listed(restic_lines(config, 'ls', '--json', snapshot))
        if previous:
            audit.changed(restic_lines(config, 'diff', '--json', previous, snapshot))
        def restore_batch(paths, target):
            with tempfile.NamedTemporaryFile(mode='w', dir=work) as includes:
                includes.write('\n'.join(paths) + '\n')
                includes.flush()
                restic(config, 'restore', snapshot, '--target', str(target), '--verify',
                    '--include-file', includes.name)
        checked = audit.verify_batches(restore_batch, work)
        # Restore and hash the captured dump/manifest, not merely their source files.
        with tempfile.TemporaryDirectory(prefix='restore-check-', dir=work) as restore_check:
            restic(config, 'restore', snapshot, '--target', restore_check, '--verify',
                '--include', '/database.dump', '--include', '/manifest.json', '--include', '/raw-manifest.jsonl')
            restored = Path(restore_check)
            if file_sha256(restored / 'database.dump') != manifest['database_sha256'] or file_sha256(restored / 'raw-manifest.jsonl') != manifest['raw_manifest_sha256']:
                raise ValueError('captured database or manifest integrity mismatch')
            if json.loads((restored / 'manifest.json').read_text()) != manifest:
                raise ValueError('captured manifest changed')
            run(['pg_restore', '--list', str(restored / 'database.dump')])
        restic(config, 'check', '--read-data-subset=5%')
        restic(config, 'tag', '--add', 'complete', '--remove', 'pending', snapshot)
        snapshots = json.loads(restic(config, 'snapshots', '--json', '--tag', run_tag).stdout)
        if len(snapshots) != 1 or 'complete' not in snapshots[0]['tags']:
            raise RuntimeError('completed snapshot was not confirmed')
        snapshot = snapshots[0]['id']
        status = {'completed_at': datetime.now(timezone.utc).isoformat(), 'snapshot_id': snapshot,
            'raw_chunks': manifest['raw_chunks_count'], 'raw_chunks_verified_now': checked,
            'database_sha256': manifest['database_sha256'], 'retention': 'pending',
            'total_bytes_processed': summaries[-1].get('total_bytes_processed'), 'status': 'success'}
        temporary = work / 'last-success.tmp'
        audit.commit(snapshot)
        with temporary.open('w') as output:
            output.write(json.dumps(status, sort_keys=True))
            output.flush()
            os.fsync(output.fileno())
        temporary.replace(work / 'last-success.json')
        directory = os.open(work, os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        snapshots = json.loads(restic(config, 'snapshots', '--json', '--host', config['host'], '--tag', 'wythin-managed').stdout)
        expired = prune_candidates(snapshots, snapshot, previous, datetime.now(timezone.utc))
        for start in range(0, len(expired), 100):
            restic(config, 'forget', '--prune', *expired[start:start+100])
        status['retention'] = 'complete'
        temporary.write_text(json.dumps(status, sort_keys=True))
        temporary.replace(work / 'last-success.json')
        return status
    finally:
        if audit:
            audit.close()
        if os.path.ismount(mount):
            subprocess.run(['fusermount3', '-u', str(mount)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        # These are disposable staging copies, never the production database.
        for path in (source / 'database.dump', source / 'manifest.json', source / 'raw-manifest.jsonl'):
            path.unlink(missing_ok=True)
        shutil.rmtree(configuration, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', default='/etc/wythin/backup/settings.json')
    parser.add_argument('action', choices=['backup', 'restore', 'check'])
    parser.add_argument('--snapshot')
    parser.add_argument('--target')
    args = parser.parse_args()
    os.umask(0o077)
    config = json.loads(Path(args.config).read_text())
    work = Path(config['workdir'])
    work.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (work / 'operation.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.action == 'backup':
            result = backup(config)
        elif args.action == 'check':
            restic(config, 'check', '--read-data')
            result = {'integrity_check': 'passed'}
        else:
            if not args.snapshot or not args.target:
                parser.error('restore requires --snapshot and --target')
            count = restore(config, args.snapshot, args.target)
            result = {'restored_raw_chunks': count, 'integrity_check': 'passed'}
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
