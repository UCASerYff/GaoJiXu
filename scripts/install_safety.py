#!/usr/bin/env python3
"""Own only the inode promoted by this installation; never remove a formal-path object."""
import argparse
import ctypes
import errno
import json
import os
from pathlib import Path
import plistlib
import stat
import sys


def identity(path):
    s = path.lstat()
    if not stat.S_ISDIR(s.st_mode):
        raise ValueError('Expected a real directory, never a symlink')
    return {'device': s.st_dev, 'inode': s.st_ino, 'uid': s.st_uid,
            'type': stat.S_IFMT(s.st_mode)}


def exclusive_rename(source, target):
    # Public Darwin API, sys/stdio.h: RENAME_EXCL = 0x00000004.
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(target), 0x00000004) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))


def existing_identity(path):
    try:
        return identity(path)
    except FileNotFoundError:
        return None  # Only ENOENT means absent. Other errors must preserve everything.


def binding_at(path):
    data = json.loads(path.read_text())
    value = data['identity']
    if set(value) != {'device', 'inode', 'uid', 'type'}:
        raise ValueError('Invalid transaction identity')
    return value


def bind(source, binding):
    bound = identity(source)
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'com.gaojixu.savings':
        raise ValueError('Candidate bundle identity changed')
    with binding.open('x') as handle:
        json.dump({'identity': bound, 'candidateVersion': info['CFBundleShortVersionString'],
                   'candidateBuild': info['CFBundleVersion']}, handle)
        handle.flush()
        os.fsync(handle.fileno())
    return {'bound': True}


def promote(source, target, binding):
    expected = binding_at(binding)
    if identity(source) != expected:
        raise ValueError('Candidate inode changed; formal path untouched')
    if existing_identity(target) is not None:
        raise FileExistsError('Formal path occupied; nothing replaced')
    exclusive_rename(source, target)
    if identity(target) != expected:
        raise ValueError('Promoted path identity changed; preserve for inspection')
    return {'promoted': True}


def recover(target, safety, binding, quarantine):
    current = existing_identity(target)
    quarantined = False
    if current is not None:
        expected = binding_at(binding)
        if current != expected:
            raise ValueError('Formal path is not this transaction; preserve it and recovery data')
        exclusive_rename(target, quarantine)
        # Source identity may race with rename: preserve a changed object, never delete it.
        if identity(quarantine) != expected:
            try:
                exclusive_rename(quarantine, target)
            except OSError:
                pass  # Occupied or unqueryable: preserve both paths for manual recovery.
            raise ValueError('Identity changed during quarantine; no program deleted')
        quarantined = True
    restored = False
    if existing_identity(safety) is not None:
        exclusive_rename(safety, target)  # Never overwrite a concurrent later object.
        restored = True
    return {'restoredOriginal': restored, 'retainedFailedCandidate': quarantined}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['bind', 'promote', 'recover'])
    parser.add_argument('--source', type=Path)
    parser.add_argument('--target', type=Path)
    parser.add_argument('--safety', type=Path)
    parser.add_argument('--binding', type=Path, required=True)
    parser.add_argument('--quarantine', type=Path)
    args = parser.parse_args()
    required = {'bind': ['source'], 'promote': ['source', 'target'],
                'recover': ['target', 'safety', 'quarantine']}[args.operation]
    if any(getattr(args, field) is None for field in required):
        parser.error('Missing exact transaction paths')
    try:
        if args.operation == 'bind':
            result = bind(args.source, args.binding)
        elif args.operation == 'promote':
            result = promote(args.source, args.target, args.binding)
        else:
            result = recover(args.target, args.safety, args.binding, args.quarantine)
        print(json.dumps(result))
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('Installation safety check failed: ' + type(error).__name__ +
              '; existing objects and recovery data are retained.', file=sys.stderr)
        return 3
    return 0


if __name__ == '__main__':
    sys.exit(main())
