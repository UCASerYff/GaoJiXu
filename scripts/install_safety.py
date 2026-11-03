#!/usr/bin/env python3
"""Retain and restore this install's exact original inodes. Never restore user data."""
import argparse
import base64
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import struct
import subprocess
import sys
import time
import uuid

BID = 'com.gaojixu.savings'
WIDGET_BID = BID + '.widgets'
WIDGET = 'Contents/PlugIns/GaoJiXuWidgets.appex'
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
LIBC = ctypes.CDLL(None, use_errno=True)
_spec = importlib.util.spec_from_file_location('savings_install_provenance', Path(__file__).with_name('install_provenance.py'))
_provenance = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_provenance)
_regspec = importlib.util.spec_from_file_location('savings_install_registration', Path(__file__).with_name('install_registration.py'))
_registration = importlib.util.module_from_spec(_regspec)
_regspec.loader.exec_module(_registration)
MACL = base64.b64encode(b'com.apple.macl').decode()


class InventoryChanged(ValueError):
    def __init__(self, detail):
        self.detail = detail
        super().__init__('Program metadata changed during inventory at '+repr(detail['relativePath'])+
                         ': '+json.dumps(detail['diff'], sort_keys=True))


class InventoryReadError(ValueError):
    def __init__(self, root, relative, error):
        self.detail = {'operation': 'inventory-read', 'root': str(root), 'relativePath': relative,
                       'path': str(root/relative), 'completeTree': False,
                       'cause': {'type': type(error).__name__, 'message': str(error),
                                 'errno': error.errno if isinstance(error, OSError) else None}}
        super().__init__('Cannot inventory '+str(root/relative)+': '+str(error))


class TreeDifference(ValueError):
    def __init__(self, operation, path, expected, actual, cause):
        self.detail = {'operation': operation, 'path': str(path), 'expectedTree': expected,
                       'actualTree': actual, 'diff': _registration.exact_diff(expected, actual),
                       'cause': str(cause)}
        super().__init__(operation+' inventory mismatch at '+str(path)+': '+str(cause))


def registration_check(expected, actual, allowed_macl, operation, path):
    try:
        return _registration.registration_transition(expected, actual, allowed_macl)
    except ValueError as error:
        raise TreeDifference(operation, path, expected, actual, error) from error


def canonical(path):
    path = Path(path)
    if not path.is_absolute() or path != path.resolve(strict=False):
        raise ValueError('Use an absolute path without symlink ancestors')
    return path


def noindex(path):
    path = canonical(path)
    if not any(p.name.endswith('.noindex') for p in path.parents):
        raise ValueError('Expanded recovery programs require a real .noindex ancestor')


def birth(path):
    # Darwin attr.h: ATTR_CMN_CRTIME, packed attribute values start after uint32 length.
    class AttrList(ctypes.Structure):
        _fields_ = [('count', ctypes.c_ushort), ('reserved', ctypes.c_ushort)] + [
            (n, ctypes.c_uint32) for n in ('common', 'volume', 'directory', 'file', 'fork')]
    attr = AttrList(5, 0, 0x00000200, 0, 0, 0, 0)
    buffer = ctypes.create_string_buffer(24)
    f = LIBC.getattrlist
    f.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_ulong]
    f.restype = ctypes.c_int
    if f(os.fsencode(path), ctypes.byref(attr), buffer, len(buffer), 1) != 0:
        raise OSError(ctypes.get_errno(), 'Cannot read exact birth time')
    if struct.unpack_from('=I', buffer.raw)[0] != 20:
        raise ValueError('Unexpected Darwin birth-time layout')
    return list(struct.unpack_from('=qq', buffer.raw, 4))


def identity(path):
    s = Path(path).lstat()
    if not stat.S_ISDIR(s.st_mode):
        raise ValueError('Expected a real directory, never a symlink')
    return {'device': s.st_dev, 'inode': s.st_ino, 'uid': s.st_uid,
            'type': stat.S_IFMT(s.st_mode), 'birth': birth(path)}


def existing_identity(path):
    try:
        Path(path).lstat()
    except FileNotFoundError:
        return None
    # A later birth/stat read failure is an unknown state, not an absent object.
    return identity(path)


def exclusive_rename(source, target):
    rename = LIBC.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(target), 4) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))
    sync_directory(Path(source).parent)
    if Path(source).parent != Path(target).parent:
        sync_directory(Path(target).parent)


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def regular_data(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise ValueError('Expected a regular receipt/file')
        chunks = []
        while True:
            data = os.read(fd, 1024 * 1024)
            if not data:
                break
            chunks.append(data)
        after = os.fstat(fd)
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
                after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise ValueError('File changed while reading')
        return b''.join(chunks)
    finally:
        os.close(fd)


def json_write(path, value, replace=False):
    path = Path(path)
    raw = (json.dumps(value, ensure_ascii=True, sort_keys=True, indent=2) + '\n').encode()
    temp = path.parent / ('.receipt-' + str(uuid.uuid4()) + '.tmp') if replace else path
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(raw); f.flush(); os.fsync(f.fileno())
        if replace:
            s = path.lstat()
            if not stat.S_ISREG(s.st_mode) or s.st_uid != os.getuid():
                raise ValueError('Recovery pointer is not an owned regular file')
            os.replace(temp, path)
        sync_directory(path.parent)
    finally:
        if replace and temp.exists():
            temp.unlink()


def xattrs(path, raw_provenance=False, raw_macl=False):
    # Include compression metadata, and do not follow symlinks (Darwin sys/xattr.h).
    opts = 0x0001 | 0x0020
    names = LIBC.listxattr
    names.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    names.restype = ctypes.c_ssize_t
    get = LIBC.getxattr
    get.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
                   ctypes.c_uint32, ctypes.c_int]
    get.restype = ctypes.c_ssize_t
    p = os.fsencode(path)
    size = names(p, None, 0, opts)
    if size < 0:
        raise OSError(ctypes.get_errno(), 'Cannot enumerate all xattrs')
    buffer = ctypes.create_string_buffer(max(size, 1))
    actual = names(p, buffer, size, opts)
    if actual != size:
        raise ValueError('xattr names changed or could not be enumerated')
    result = {}
    for name in sorted(n for n in buffer.raw[:size].split(b'\0') if n):
        count = get(p, name, None, 0, 0, opts)
        if count < 0:
            raise OSError(ctypes.get_errno(), 'Cannot read xattr')
        value = ctypes.create_string_buffer(max(count, 1))
        if get(p, name, value, count, 0, opts) != count:
            raise ValueError('xattr value changed or could not be read')
        item = {'bytes': count, 'sha256': digest(value.raw[:count])}
        if raw_provenance and name == b'com.apple.provenance' or raw_macl and name == b'com.apple.macl':
            item['rawBase64'] = base64.b64encode(value.raw[:count]).decode()
        result[base64.b64encode(name).decode()] = item
    return result


def acl(path):
    # Request ATTR_CMN_EXTENDED_SECURITY plus RETURNED_ATTRS: absence is an explicit
    # returned zero-length attribute, never an acl_get_link_np ENOENT guess.
    class AttrList(ctypes.Structure):
        _fields_ = [('count', ctypes.c_ushort), ('reserved', ctypes.c_ushort)] + [
            (n, ctypes.c_uint32) for n in ('common', 'volume', 'directory', 'file', 'fork')]
    attr = AttrList(5, 0, 0x80000000 | 0x00400000, 0, 0, 0, 0)
    buffer = ctypes.create_string_buffer(65536)
    f = LIBC.getattrlist
    f.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_ulong]
    f.restype = ctypes.c_int
    if f(os.fsencode(path), ctypes.byref(attr), buffer, len(buffer), 1) != 0:
        raise OSError(ctypes.get_errno(), 'Cannot read extended-security attribute')
    length = struct.unpack_from('=I', buffer.raw)[0]
    returned_common = struct.unpack_from('=I', buffer.raw, 4)[0]
    if length < 32 or length > len(buffer):
        raise ValueError('Extended-security attribute was truncated')
    offset, count = struct.unpack_from('=iI', buffer.raw, 24)
    if not returned_common & 0x00400000:
        # APFS reports no attached ACL by clearing this bit with a zero-length reference.
        # Separately confirm ACL support on the containing filesystem, never convert a
        # failed get/read or an unsupported volume into an empty ACL.
        pathconf = LIBC.pathconf
        pathconf.argtypes = [ctypes.c_char_p, ctypes.c_int]; pathconf.restype = ctypes.c_long
        if count != 0 or pathconf(os.fsencode(Path(path).parent), 13) != 1:
            raise ValueError('ACL absent/unavailable status could not be verified')
        return None
    if count == 0:
        return ''  # Explicit empty ACL from a successful, nofollow filesystem query.
    start = 24 + offset
    if start < 32 or start + count > length:
        raise ValueError('Truncated or invalid ACL payload')
    return base64.b64encode(buffer.raw[start:start+count]).decode()


def inventory(root):
    root = canonical(root)
    identity(root)
    result = {}
    def stat_fields(s):
        return {k: getattr(s, v) for k, v in (
            ('device','st_dev'), ('inode','st_ino'), ('mode','st_mode'), ('uid','st_uid'),
            ('gid','st_gid'), ('mtimeNS','st_mtime_ns'), ('ctimeNS','st_ctime_ns'),
            ('flags','st_flags'), ('nlink','st_nlink'))}
    def changed(path, relative, before, after, row):
        detail = {'operation': 'inventory', 'path': str(path), 'root': str(root),
                  'relativePath': relative, 'beforeStat': before, 'afterStat': after,
                  'diff': _registration.exact_diff(before, after), 'observedRow': row,
                  'completeTree': False}
        if relative == '' and set(k for k in before if before[k] != after[k]) == {'ctimeNS'}:
            # A retry is possible only with complete, successfully reread root attributes.
            # Every other node is checked again after the entire traversal.
            for name, child in result.items():
                if name == '':
                    continue
                try:
                    end = stat_fields((root/name).lstat())
                except OSError as error:
                    raise InventoryReadError(root, name, error) from error
                if end != {k: child[k] for k in end}:
                    raise InventoryChanged({'operation': 'inventory-final-stat', 'path': str(root/name),
                        'root': str(root), 'relativePath': name, 'beforeStat': {k: child[k] for k in end},
                        'afterStat': end, 'diff': _registration.exact_diff({k: child[k] for k in end}, end),
                        'completeTree': False})
            try:
                last = dict(row, **after, birth=birth(path), xattrs=xattrs(path, raw_provenance=True),
                            aclBase64=acl(path))
                if stat_fields(path.lstat()) != after:
                    raise InventoryChanged(detail)
            except OSError as error:
                raise InventoryReadError(root, relative, error) from error
            detail.update(completeTree=True, beforeTree=dict(result, **{'': row}),
                          afterTree=dict(result, **{'': last}),
                          rootAttributeDiff=_registration.exact_diff(row, last))
        raise InventoryChanged(detail)
    def read_visit(path, relative):
        first = path.lstat()
        kind = stat.S_IFMT(first.st_mode)
        if kind not in (stat.S_IFDIR, stat.S_IFREG, stat.S_IFLNK):
            raise ValueError('Unsupported object in program tree')
        row = {'device': first.st_dev, 'inode': first.st_ino, 'mode': first.st_mode,
               'uid': first.st_uid, 'gid': first.st_gid, 'nlink': first.st_nlink,
               'flags': first.st_flags, 'birth': birth(path), 'mtimeNS': first.st_mtime_ns,
               'ctimeNS': first.st_ctime_ns, 'atimeNS': first.st_atime_ns,
               'xattrs': xattrs(path, raw_provenance=relative == ''), 'aclBase64': acl(path)}
        if kind == stat.S_IFREG:
            raw = regular_data(path); row.update(bytes=len(raw), sha256=digest(raw))
        elif kind == stat.S_IFLNK:
            row['linkTargetBase64'] = base64.b64encode(os.readlink(os.fsencode(path))).decode()
        else:
            children = sorted(os.listdir(path))
            for name in children:
                visit(path/name, name if not relative else relative+'/'+name)
            if children != sorted(os.listdir(path)):
                raise ValueError('Program directory changed while enumerating')
        after = path.lstat()
        if stat_fields(first) != stat_fields(after):
            changed(path, relative, stat_fields(first), stat_fields(after), row)
        result[relative] = row
    def visit(path, relative):
        try:
            read_visit(path, relative)
        except (InventoryChanged, InventoryReadError):
            raise
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise InventoryReadError(root, relative, error) from error
    visit(root, '')
    # Detect a previously visited node changing while a later sibling was read.
    for name, row in result.items():
        try:
            after = stat_fields((root/name).lstat())
        except OSError as error:
            raise InventoryReadError(root, name, error) from error
        before = {k: row[k] for k in after}
        if before != after:
            changed(root/name, name, before, after, row)
    return result


def comparable(tree):
    result = {}
    for name, row in tree.items():
        result[name] = {k: v for k, v in row.items() if k != 'atimeNS' and not (name == '' and k == 'ctimeNS')}
    return result


def check_tree(path, expected):
    actual = inventory(path)
    if comparable(actual) != comparable(expected):
        raise TreeDifference('check-tree', path, expected, actual,
                             'Program inode/content/metadata/ACL/xattrs differ; preserved without replacement')


def bundle_info(path):
    values = {}
    for relative, bid in [('Contents/Info.plist', BID), (WIDGET+'/Contents/Info.plist', WIDGET_BID)]:
        info = plistlib.loads(regular_data(Path(path)/relative))
        if info.get('CFBundleIdentifier') != bid:
            raise ValueError('Program bundle identity differs')
        values[bid] = {k: info[k] for k in ('CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion')}
    return values


def signature_record(path):
    result = {}
    for relative in ['', WIDGET, 'Contents/Frameworks/Savings.framework']:
        app = Path(path)/relative
        p = subprocess.run(['codesign', '-d', '-r-', '--verbose=4', '--entitlements', ':-', str(app)], capture_output=True)
        if p.returncode:
            raise ValueError('Cannot capture complete program signature')
        result[relative] = {'display': p.stderr.decode('utf-8', 'strict'), 'entitlementsBase64': base64.b64encode(p.stdout).decode()}
    return result


def binding_at(path):
    value = json.loads(regular_data(path))
    if value.get('schemaVersion') != 2 or value.get('bundleID') != BID:
        raise ValueError('Unknown candidate binding format; preserve legacy evidence')
    return value


def bind(source, binding):
    source, binding = canonical(source), canonical(binding)
    noindex(source); noindex(binding)
    info = bundle_info(source)
    json_write(binding, {'schemaVersion': 2, 'bundleID': BID, 'identity': identity(source),
                         'source': str(source), 'sourceParent': identity(source.parent),
                         'info': info, 'tree': inventory(source)})
    return {'bound': True}


def promote(source, target, binding):
    source, target = canonical(source), canonical(target)
    bound = binding_at(binding)
    if str(canonical(source)) != bound['source'] or identity(source) != bound['identity']:
        raise ValueError('Candidate inode or location changed')
    check_tree(source, bound['tree'])
    if existing_identity(target) is not None:
        raise FileExistsError('Formal path occupied; nothing replaced')
    before = inventory(source)
    move = canonical(binding).parent/'candidate-promotion-intent.json'
    json_write(move, {'schemaVersion': 1, 'source': str(source), 'target': str(target),
        'bindingSHA256': digest(regular_data(binding)), 'before': before, 'startedAt': time.time()})
    exclusive_rename(source, target)
    if identity(target) != bound['identity']:
        raise ValueError('Promoted identity changed; preserve for inspection')
    after = inventory(target)
    proof = _provenance.transition(before, after)
    json_write(canonical(binding).parent/'candidate-promotion.json', {'schemaVersion': 1,
        'intentSHA256': digest(regular_data(move)), 'after': after, 'proof': proof,
        'completedAt': time.time()})
    return {'promoted': True}


def clean_stage(binding):
    bound = binding_at(binding)
    source = canonical(bound['source']); parent = source.parent
    noindex(source)
    if identity(parent) != bound['sourceParent'] or os.path.lexists(source):
        raise ValueError('Stage is occupied or no longer this transaction')
    marker = parent/'.metadata_never_index'
    names = os.listdir(parent)
    if names != ['.metadata_never_index'] and names != []:
        raise ValueError('Unknown stage contents retained')
    if names:
        s = marker.lstat()
        if not stat.S_ISREG(s.st_mode) or s.st_size != 0 or s.st_uid != os.getuid() or s.st_nlink != 1:
            raise ValueError('Stage marker changed; retained')
        marker.unlink()
    parent.rmdir(); sync_directory(parent.parent)
    return {'emptyStageRemoved': True}


def pointer_path(receipt):
    return Path(receipt).parent/'recovery-pointer.json'


def load_original(receipt, target=None, safety=None):
    receipt = canonical(receipt); noindex(receipt)
    raw = regular_data(receipt); value = json.loads(raw)
    if value.get('schemaVersion') != 2 or value.get('bundleID') != BID:
        raise ValueError('Missing full original-object receipt; legacy ZIP is auxiliary only')
    formal, retained = canonical(value['target']), canonical(value['safety'])
    if target is not None and canonical(target) != formal or safety is not None and canonical(safety) != retained:
        raise ValueError('Recovery locators differ')
    if retained != receipt.parent/'Program.noindex'/formal.name:
        raise ValueError('Retained original is outside this transaction')
    noindex(retained)
    if identity(retained.parent) != value['safetyParent'] or identity(formal.parent) != value['targetParent']:
        raise ValueError('Recovery or installation parent changed')
    binding = receipt.parent/'new-program-identity.json'
    if digest(regular_data(binding)) != value['candidateBindingSHA256']:
        raise ValueError('Candidate binding changed')
    pointer = json.loads(regular_data(pointer_path(receipt)))
    if (pointer.get('schemaVersion'), pointer.get('receipt'), pointer.get('receiptSHA256'), pointer.get('transactionID'),
            pointer.get('target'), pointer.get('safety')) != (
            2, str(receipt), digest(raw), value['transactionID'], str(formal), str(retained)):
        raise ValueError('Recovery pointer does not match the immutable receipt')
    return value


def mark(receipt, value, state):
    load_original(receipt)
    p = json.loads(regular_data(pointer_path(receipt)))
    p.setdefault('history', []).append({'state': state, 'at': time.time()})
    p.update(state=state, observedAt=time.time())
    json_write(pointer_path(receipt), p, replace=True)


def capture_original(target, safety, receipt, signatures=None):
    target, safety, receipt = canonical(target), canonical(safety), canonical(receipt)
    noindex(safety); noindex(receipt)
    if safety != receipt.parent/'Program.noindex'/target.name or existing_identity(safety) is not None:
        raise ValueError('Recovery destination is occupied or not the exact transaction path')
    if identity(safety.parent)['device'] != identity(target.parent)['device']:
        raise ValueError('Original must stay on the same volume')
    binding = receipt.parent/'new-program-identity.json'; bound = binding_at(binding)
    original = existing_identity(target)
    tree = inventory(target) if original is not None else None
    value = {'schemaVersion': 2, 'bundleID': BID, 'transactionID': str(uuid.uuid4()),
             'target': str(target), 'safety': str(safety), 'hadOriginal': original is not None,
             'originalIdentity': original, 'info': bundle_info(target) if original is not None else None,
             'tree': tree, 'signatureRecord': signatures, 'archiveIsAuxiliaryOnly': True,
             'targetParent': identity(target.parent), 'safetyParent': identity(safety.parent),
             'candidateBindingSHA256': digest(regular_data(binding)), 'capturedAt': time.time()}
    if identity(Path(bound['source'])) != bound['identity']:
        raise ValueError('Staged candidate changed before original capture')
    (receipt.parent/'original-moves.noindex').mkdir(mode=0o700)
    json_write(receipt, value)
    json_write(pointer_path(receipt), {'schemaVersion': 2, 'transactionID': value['transactionID'],
        'receipt': str(receipt), 'receiptSHA256': digest(regular_data(receipt)),
        'target': str(target), 'safety': str(safety), 'state': 'prepared', 'history': [],
        'moves': [], 'activeMove': None, 'observedAt': time.time()})
    return {'captured': True, 'hadOriginal': value['hadOriginal'], 'pointer': str(pointer_path(receipt))}


def move_record(receipt, reference):
    path = canonical(reference['path'])
    if path.parent != Path(receipt).parent/'original-moves.noindex' or path.suffix != '.json':
        raise ValueError('Move record is outside this transaction')
    raw = regular_data(path)
    if digest(raw) != reference['sha256']:
        raise ValueError('Move record changed')
    return json.loads(raw)


def expected_original_tree(receipt, value, pointer=None):
    pointer = pointer or json.loads(regular_data(pointer_path(receipt)))
    tree = value['tree']
    for ref in pointer.get('moves', []):
        moved = move_record(receipt, ref)
        if comparable(moved['before']) != comparable(tree):
            raise ValueError('Original move history is not a continuous chain')
        if {moved['source'], moved['destination']} != {value['target'], value['safety']}:
            raise ValueError('Original move locators changed')
        if _provenance.transition(moved['before'], moved['after']) != moved['proof']:
            raise ValueError('Original provenance transition proof differs')
        tree = moved['after']
    return tree


def resolve_pending_move(receipt):
    value = load_original(receipt)
    pointer = json.loads(regular_data(pointer_path(receipt)))
    active = pointer.get('activeMove')
    if not active:
        return
    intent = move_record(receipt, active)
    source, destination = Path(intent['source']), Path(intent['destination'])
    if {str(source), str(destination)} != {value['target'], value['safety']} or comparable(intent['before']) != comparable(expected_original_tree(receipt, value, pointer)):
        raise ValueError('Pending move does not match the exact original')
    old = existing_identity(source); new = existing_identity(destination)
    if old == value['originalIdentity'] and new is None:
        # No completed rename; a static object must match strictly, including root provenance.
        check_tree(source, intent['before'])
        pointer['activeMove'] = None
        pointer.setdefault('abortedMoves', []).append(active)
        json_write(pointer_path(receipt), pointer, replace=True)
        return
    if new != value['originalIdentity'] or old is not None:
        raise ValueError('Pending rename has ambiguous locations; all objects retained')
    after = inventory(destination)
    proof = _provenance.transition(intent['before'], after)
    complete = Path(receipt).parent/'original-moves.noindex'/('complete-'+str(uuid.uuid4())+'.json')
    json_write(complete, {'schemaVersion': 1, 'source': str(source), 'destination': str(destination),
        'intent': active, 'before': intent['before'], 'after': after, 'proof': proof,
        'basis': 'durable pre-rename intent, same original inodes, exclusive Darwin rename; no xattr written',
        'completedAt': time.time()})
    pointer.setdefault('moves', []).append({'path': str(complete), 'sha256': digest(regular_data(complete))})
    pointer['activeMove'] = None
    json_write(pointer_path(receipt), pointer, replace=True)


def move_original(source, destination, receipt):
    resolve_pending_move(receipt)
    value = load_original(receipt)
    verify_original(source, receipt)
    pointer = json.loads(regular_data(pointer_path(receipt)))
    before = inventory(source)
    if comparable(before) != comparable(expected_original_tree(receipt, value, pointer)):
        raise ValueError('Original changed before rename intent')
    intent = Path(receipt).parent/'original-moves.noindex'/('intent-'+str(uuid.uuid4())+'.json')
    json_write(intent, {'schemaVersion': 1, 'source': str(source), 'destination': str(destination),
                       'before': before, 'originalIdentity': value['originalIdentity'], 'startedAt': time.time()})
    pointer['activeMove'] = {'path': str(intent), 'sha256': digest(regular_data(intent))}
    json_write(pointer_path(receipt), pointer, replace=True)
    exclusive_rename(source, destination)
    try:
        resolve_pending_move(receipt)
        verify_original(destination, receipt)
    except (OSError, ValueError, KeyError, TypeError):
        # A race may have moved an alien object. Return only that unchanged observed object,
        # exclusively, if the source is still empty; otherwise retain both for inspection.
        try:
            observed = Path(destination).lstat()
            token = (observed.st_dev, observed.st_ino, observed.st_mode, observed.st_uid)
            current = Path(destination).lstat()
            if token == (current.st_dev, current.st_ino, current.st_mode, current.st_uid) and not os.path.lexists(source):
                exclusive_rename(destination, source)
        except OSError:
            pass
        raise


def verify_original(safety, receipt):
    resolve_pending_move(receipt)
    value = load_original(receipt)
    if not value['hadOriginal'] or canonical(safety) not in (Path(value['safety']), Path(value['target'])):
        raise ValueError('No original at this recorded location')
    if identity(safety) != value['originalIdentity']:
        raise ValueError('Original inode changed')
    check_tree(safety, expected_original_tree(receipt, value))
    if bundle_info(safety) != value['info']:
        raise ValueError('Original bundle information changed')
    return {'originalVerified': True, 'path': str(safety)}


def retain_original(target, safety, receipt):
    resolve_pending_move(receipt)
    value = load_original(receipt, target, safety)
    if not value['hadOriginal']:
        if existing_identity(target) is not None or existing_identity(safety) is not None:
            raise ValueError('First-install absence evidence no longer matches')
        mark(receipt, value, 'original-absent')
        return {'retainedOriginal': False, 'originalWasAbsent': True}
    if existing_identity(safety) is not None:
        verify_original(safety, receipt)
        if existing_identity(target) is not None:
            raise ValueError('Formal path occupied; do not repeat retention')
    else:
        verify_original(target, receipt)
        move_original(target, safety, receipt)
        verify_original(safety, receipt)
    mark(receipt, value, 'original-retained')
    return {'retainedOriginal': True, 'authority': str(safety)}


def recover(target, safety, binding, quarantine, original_receipt):
    target, safety, quarantine = canonical(target), canonical(safety), canonical(quarantine)
    noindex(quarantine)
    if quarantine != canonical(original_receipt).parent/'failed-new-program.noindex':
        raise ValueError('Quarantine must be the exact directory of this transaction')
    resolve_pending_move(original_receipt)
    value = load_original(original_receipt, target, safety)
    if canonical(binding) != Path(original_receipt).parent/'new-program-identity.json':
        raise ValueError('Wrong candidate binding path')
    expected = binding_at(binding)['identity']
    current = existing_identity(target)
    if value['hadOriginal']:
        if existing_identity(safety) is None:
            if current == value['originalIdentity']:
                verify_original(target, original_receipt)
                mark(original_receipt, value, 'original-restored')
                return {'restoredOriginal': True, 'originalAlreadyInstalled': True}
            raise ValueError('Original missing; installed candidate and all evidence retained')
        verify_original(safety, original_receipt)  # MUST precede moving a current candidate.
    elif existing_identity(safety) is not None:
        raise ValueError('Unexpected original at recorded absent location')
    quarantined = existing_identity(quarantine)
    if quarantined is not None and quarantined != expected:
        raise ValueError('Quarantine occupied by another object')
    if current is not None:
        if current != expected:
            raise ValueError('Formal path is not this candidate; preserve it')
        if quarantined is not None:
            raise ValueError('Both candidate locations are occupied')
        exclusive_rename(target, quarantine)
        if identity(quarantine) != expected:
            try: exclusive_rename(quarantine, target)
            except OSError: pass
            raise ValueError('Candidate changed during quarantine; nothing deleted')
        quarantined = expected
    if value['hadOriginal']:
        verify_original(safety, original_receipt)
        move_original(safety, target, original_receipt)
        verify_original(target, original_receipt)
    mark(original_receipt, value, 'original-restored' if value['hadOriginal'] else 'first-install-reverted')
    return {'restoredOriginal': value['hadOriginal'], 'retainedFailedCandidate': quarantined is not None}


def bundle_records(text):
    result = []
    for block in re.split(r'\n-+\n', text):
        if not re.search(r'^bundle id:', block, re.M): continue
        bid = re.search(r'^identifier:\s*(.*?)\s*$', block, re.M)
        path = re.search(r'^path:\s*(.*?)\s*$', block, re.M)
        if bid is None: continue
        if path is None:
            if bid.group(1) in (BID, WIDGET_BID): raise ValueError('Own LS record lacks its path')
            continue
        p = re.sub(r'\s+\(0x[0-9a-fA-F]+\)$', '', path.group(1))
        if not p.startswith('/'): raise ValueError('Invalid LS bundle path')
        result.append({'bundleID': bid.group(1), 'path': p})
    return result


def plugin_records(text):
    records = []; current = None
    for line in text.splitlines():
        header = re.match(r'^\s*([+!=\-]?)\s*([A-Za-z0-9_.-]+)\(([^)]+)\)', line)
        if header:
            if current is not None: records.append(current)
            current = {'state': header.group(1), 'bundleID': header.group(2), 'version': header.group(3), 'path': None}
            continue
        path = re.match(r'^\s*Path\s*=\s*(.*?)\s*$', line, re.I)
        if path and current is not None:
            if current['path'] is not None: raise ValueError('Duplicate widget path field')
            current['path'] = path.group(1)
    if current is not None: records.append(current)
    return [x for x in records if x['bundleID'] == WIDGET_BID]


def registry_baseline(target, receipt, output, run=subprocess.run):
    value = load_original(receipt, target)
    if value['hadOriginal']: verify_original(target, receipt)
    query = run([LSREGISTER, '-dump'], capture_output=True, text=True)
    if query.returncode: raise ValueError('LS query failed; no observable baseline')
    records = bundle_records(query.stdout)
    witnesses = sorted({digest(json.dumps(x, sort_keys=True).encode()) for x in records
                        if x['bundleID'] not in (BID, WIDGET_BID)})[:8]
    if not witnesses or value['hadOriginal'] and {'bundleID': BID, 'path': str(target)} not in records:
        raise ValueError('Empty or restricted LS view, or formal application not positively visible')
    data = {'schemaVersion': 2, 'target': str(target), 'receiptSHA256': digest(regular_data(receipt)),
            'witnesses': witnesses, 'ownRecords': [x for x in records if x['bundleID'] in (BID, WIDGET_BID)]}
    json_write(output, data)
    return {'registryBaselineCaptured': True}


def error_detail(error):
    value = {'type': type(error).__name__, 'message': str(error)}
    if isinstance(error, OSError):
        value.update(errno=error.errno, filename=str(error.filename) if error.filename else None)
    if isinstance(error, (InventoryChanged, InventoryReadError)):
        value['inventory'] = error.detail
    if isinstance(error, TreeDifference):
        value['treeDifference'] = error.detail
    return value


def promoted_tree(receipt, value):
    parent = Path(receipt).parent
    binding = parent/'new-program-identity.json'
    bound = binding_at(binding)
    raw = regular_data(parent/'candidate-promotion-intent.json')
    intent = json.loads(raw)
    complete = json.loads(regular_data(parent/'candidate-promotion.json'))
    if (intent.get('schemaVersion') != 1 or complete.get('schemaVersion') != 1 or
        intent.get('source') != bound['source'] or intent.get('target') != value['target'] or
        intent.get('bindingSHA256') != digest(regular_data(binding)) or
        complete.get('intentSHA256') != digest(raw)):
        raise ValueError('Candidate promotion is not this immutable binding')
    # The staging tree remains the original authority. Only its witnessed rename may differ.
    if comparable(intent['before']) != comparable(bound['tree']):
        raise ValueError('Pre-promotion candidate differs from the original binding')
    if _provenance.transition(intent['before'], complete['after']) != complete['proof']:
        raise ValueError('Candidate promotion proof differs')
    return complete['after']


def register_candidate(receipt, baseline, run=subprocess.run, wait=time.sleep, sign=signature_record,
                       widget_election=None):
    """One bounded registration transaction; never learns a new arbitrary metadata baseline."""
    if widget_election not in (None, 'use'):
        raise ValueError('Only an explicit use election is supported; positive + verification is unchanged')
    receipt = canonical(receipt)
    directory = receipt.parent/'candidate-registration.noindex'
    # A failed/interrupted attempt is immutable evidence. A fresh installer uses a fresh recovery root.
    directory.mkdir(mode=0o700)
    event = {'schemaVersion': 1, 'operation': 'register-candidate', 'status': 'failed',
             'startedAt': time.time(), 'phase': 'preflight', 'samples': [], 'commands': [],
             'requestedWidgetElection': widget_election}
    def command(args):
        n = len(event['commands'])
        intent = directory/('command-%02d-intent.json' % n)
        json_write(intent, {'argv': args, 'startedAt': time.time(),
                           'registrationIntentSHA256': digest(regular_data(directory/'intent.json'))})
        outcome = run(args, capture_output=True, text=True)
        output = directory/('command-%02d-complete.json' % n)
        json_write(output, {'intentSHA256': digest(regular_data(intent)), 'argv': args,
            'returncode': outcome.returncode, 'stdout': outcome.stdout, 'stderr': outcome.stderr,
            'completedAt': time.time()})
        event['commands'].append({'path': str(output), 'sha256': digest(regular_data(output))})
        return outcome
    try:
        value = load_original(receipt)
        target, safety = Path(value['target']), Path(value['safety'])
        bound = binding_at(receipt.parent/'new-program-identity.json')
        event.update(transactionID=value['transactionID'], target=str(target), safety=str(safety),
                     receiptSHA256=digest(regular_data(receipt)),
                     bindingSHA256=value['candidateBindingSHA256'])
        if value['hadOriginal']:
            verify_original(safety, receipt)
        elif existing_identity(safety) is not None:
            raise ValueError('Unexpected original in first-install transaction')
        if identity(target) != bound['identity'] or bundle_info(target) != bound['info']:
            raise ValueError('Formal path is not this promoted candidate')
        before = inventory(target)
        promoted = promoted_tree(receipt, value)
        event['preflight'] = {'promotionTree': promoted, 'observedTree': before,
                              'diff': _registration.exact_diff(promoted, before)}
        _registration.registration_transition(promoted, before, None)
        base = json.loads(regular_data(baseline))
        if (base.get('schemaVersion') != 2 or base.get('target') != str(target) or
            base.get('receiptSHA256') != digest(regular_data(receipt)) or not base.get('witnesses')):
            raise ValueError('Registration baseline is not this transaction')
        expected_macl = None
        if value['hadOriginal'] and MACL not in before['']['xattrs']:
            original = expected_original_tree(receipt, value)
            recorded = original['']['xattrs'].get(MACL)
            if recorded is not None:
                actual = xattrs(safety, raw_provenance=True, raw_macl=True).get(MACL)
                if actual is None or {k: actual[k] for k in ('bytes','sha256')} != recorded:
                    raise ValueError('Original MACL does not match its immutable receipt')
                # Confirm that reading the controlled value did not observe a different original.
                verify_original(safety, receipt)
                expected_macl = actual
        signatures = sign(target)
        json_write(directory/'intent.json', {'schemaVersion': 1, **event,
            'baselineSHA256': digest(regular_data(baseline)),
            'promotionSHA256': digest(regular_data(receipt.parent/'candidate-promotion.json')),
            'before': before, 'expectedMACL': expected_macl, 'signaturesBefore': signatures,
            'allowedChange': 'candidate root MACL absent -> exact original MACL; associated root ctime only',
            'doesNotProveHistoricalFailureCause': True})
        event['phase'] = 'registration-commands'
        if command([LSREGISTER, '-f', '-R', str(target)]).returncode:
            raise ValueError('Formal application registration failed')
        if command(['/usr/bin/pluginkit', '-a', str(target/WIDGET)]).returncode:
            raise ValueError('Formal widget registration failed')
        if value['hadOriginal']:
            verify_original(safety, receipt)
            # Already absent yields nonzero on some releases. Positive post-query evidence is required.
            command([LSREGISTER, '-u', str(safety)])
            command(['/usr/bin/pluginkit', '-r', str(safety/WIDGET)])
        if widget_election == 'use':
            # -a does not undo the identifier-wide ignore used by maintenance. Election
            # changes are explicit, and permitted only after a unique formal-path anchor.
            view = command(['/usr/bin/pluginkit', '-m', '-A', '-D', '-vv', '-i', WIDGET_BID])
            plugins = plugin_records(view.stdout)
            expected_fields = {'bundleID': WIDGET_BID,
                'version': bound['info'][WIDGET_BID]['CFBundleShortVersionString'],
                'path': str(target/WIDGET)}
            if (view.returncode or len(plugins) != 1 or plugins[0]['state'] not in ('', '+', '-') or
                {k:plugins[0][k] for k in expected_fields} != expected_fields):
                raise ValueError('Widget election requires one positively observed formal candidate')
            if command(['/usr/bin/pluginkit', '-e', 'use', '-i', WIDGET_BID]).returncode:
                raise ValueError('Explicit formal Widget use election failed')
        event['phase'] = 'bounded-observation'
        stable = []
        anchor = before
        inheritance_sealed = False
        for number, delay in enumerate((0, 1, 4)):
            if delay: wait(delay)
            sample = {'number': number, 'startedAt': time.time(),
                      'inheritanceAlreadySealed': inheritance_sealed}
            try:
                if value['hadOriginal']: verify_original(safety, receipt)
                if identity(target) != bound['identity'] or bundle_info(target) != bound['info']:
                    raise ValueError('Candidate identity changed during registration')
                try:
                    tree = inventory(target)
                except InventoryChanged as error:
                    sample['error'] = error_detail(error)
                    detail = error.detail
                    if not detail.get('completeTree') or detail['relativePath'] != '':
                        raise
                    # A complete reread may justify another observation, never acceptance itself.
                    proof = _registration.registration_transition(anchor, detail['afterTree'],
                                                                  None if inheritance_sealed else expected_macl)
                    if not proof['maclAdded']:
                        raise ValueError('Root ctime race was not the predeclared exact MACL addition') from error
                    race_before = detail['beforeTree']
                    if MACL in race_before['']['xattrs']:
                        # The xattr read can see the new value after the first lstat. This is
                        # still bounded by the durable pre-registration absent->exact-value proof.
                        adjusted = {p: dict(row) for p,row in race_before.items()}
                        adjusted[''] = dict(adjusted[''], ctimeNS=detail['afterTree']['']['ctimeNS'])
                        _registration.registration_transition(adjusted, detail['afterTree'], None)
                    else:
                        _registration.registration_transition(race_before, detail['afterTree'], expected_macl)
                    sample.update(status='exact-macl-addition-race-observed', transition=proof)
                    anchor = detail['afterTree']
                    inheritance_sealed = True
                    sample['sealedTree'] = anchor
                    stable = []
                    continue
                sample.update(tree=tree, diff=_registration.exact_diff(before, tree))
                proof = _registration.registration_transition(anchor, tree,
                                                              None if inheritance_sealed else expected_macl)
                sample['transition'] = proof
                if proof['maclAdded']:
                    anchor = tree
                    inheritance_sealed = True
                    sample['sealedTree'] = anchor
                ls = command([LSREGISTER, '-dump'])
                rows = bundle_records(ls.stdout)
                hashes = {digest(json.dumps(x, sort_keys=True).encode()) for x in rows}
                own = [x for x in rows if x['bundleID'] in (BID, WIDGET_BID)]
                expected_host = {'bundleID': BID, 'path': str(target)}
                allowed = [expected_host, {'bundleID': WIDGET_BID, 'path': str(target/WIDGET)}]
                if (ls.returncode or not set(base['witnesses']).issubset(hashes) or
                    own.count(expected_host) != 1 or any(x not in allowed or own.count(x) != 1 for x in own)):
                    raise ValueError('LS view lacks unique formal anchors or baseline witnesses')
                pk = command(['/usr/bin/pluginkit', '-m', '-A', '-D', '-vv', '-i', WIDGET_BID])
                expected_plugin = {'state': '+', 'bundleID': WIDGET_BID,
                    'version': bound['info'][WIDGET_BID]['CFBundleShortVersionString'], 'path': str(target/WIDGET)}
                plugins = plugin_records(pk.stdout)
                sample.update(ownLS=own, plugins=plugins)
                if pk.returncode or plugins != [expected_plugin]:
                    raise ValueError('Widget registration is not positively unique at the formal path')
                if stable and _registration.exact_diff(
                    {p: {k:v for k,v in r.items() if k != 'atimeNS'} for p,r in stable[-1].items()},
                    {p: {k:v for k,v in r.items() if k != 'atimeNS'} for p,r in tree.items()}):
                    stable = []
                stable.append(tree)
                sample['status'] = 'complete'
            except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
                sample.update(status='rejected', error=error_detail(error))
                raise
            finally:
                sample['completedAt'] = time.time()
                path = directory/('sample-%02d.json' % number)
                json_write(path, sample)
                event['samples'].append({'path': str(path), 'sha256': digest(regular_data(path))})
        if len(stable) < 2:
            raise ValueError('Registration did not reach two complete stable inventories within three observations')
        event['phase'] = 'final-verification'
        if value['hadOriginal']: verify_original(safety, receipt)
        final_signatures = sign(target)
        if signatures != final_signatures:
            raise ValueError('Candidate signature information changed during registration')
        after = inventory(target)
        registration_check(stable[-1], after, None, 'registration-final-verification', target)
        result = {'schemaVersion': 1, 'status': 'registered-with-stable-exact-inventory',
            'transactionID': value['transactionID'], 'intentSHA256': digest(regular_data(directory/'intent.json')),
            'before': before, 'after': after, 'proof': _registration.registration_transition(before, after, expected_macl),
            'signaturesAfter': final_signatures, 'samples': event['samples'], 'commands': event['commands'],
            'completedAt': time.time()}
        json_write(receipt.parent/'candidate-registration.json', result)
        event['status'] = result['status']
        return {'candidateRegistered': True, 'originalRetained': value['hadOriginal'],
                'registrationReceipt': str(receipt.parent/'candidate-registration.json')}
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        event['error'] = error_detail(error)
        raise
    finally:
        event['completedAt'] = time.time()
        json_write(directory/'outcome.json', event)


def verify_registered(receipt):
    value = load_original(receipt)
    parent = Path(receipt).parent
    raw = regular_data(parent/'candidate-registration.noindex/intent.json')
    intent = json.loads(raw)
    complete = json.loads(regular_data(parent/'candidate-registration.json'))
    bound = binding_at(parent/'new-program-identity.json')
    if (intent.get('schemaVersion') != 1 or complete.get('schemaVersion') != 1 or
        complete.get('status') != 'registered-with-stable-exact-inventory' or
        complete.get('transactionID') != value['transactionID'] or
        complete.get('intentSHA256') != digest(raw) or intent.get('receiptSHA256') != digest(regular_data(receipt)) or
        intent.get('bindingSHA256') != value['candidateBindingSHA256'] or
        intent.get('promotionSHA256') != digest(regular_data(parent/'candidate-promotion.json')) or
        intent.get('target') != value['target']):
        raise ValueError('Candidate registration completion is not this exact transaction')
    _registration.registration_transition(promoted_tree(receipt, value), intent['before'], None)
    expected_macl = intent['expectedMACL']
    if expected_macl is not None:
        if not value['hadOriginal'] or MACL in intent['before']['']['xattrs']:
            raise ValueError('MACL inheritance was not available before registration')
        recorded = expected_original_tree(receipt, value)['']['xattrs'].get(MACL)
        if recorded != {k: expected_macl[k] for k in ('bytes','sha256')}:
            raise ValueError('Registration MACL expectation differs from the exact original receipt')
    if _registration.registration_transition(intent['before'], complete['after'], intent['expectedMACL']) != complete['proof']:
        raise ValueError('Candidate registration transition proof differs')
    if complete.get('signaturesAfter') != intent['signaturesBefore']:
        raise ValueError('Registration signature evidence differs')
    for ref in complete['samples']+complete['commands']:
        path = canonical(ref['path'])
        if path.parent != parent/'candidate-registration.noindex' or digest(regular_data(path)) != ref['sha256']:
            raise ValueError('Registration observation evidence changed')
    target = Path(value['target'])
    if identity(target) != bound['identity'] or bundle_info(target) != bound['info']:
        raise ValueError('Registered candidate identity changed')
    actual = inventory(target)
    registration_check(complete['after'], actual, None, 'verify-registered', target)
    if value['hadOriginal']: verify_original(Path(value['safety']), receipt)
    return {'registeredCandidateVerified': True}


def retire_registration(app, receipt, baseline, record, run=subprocess.run, wait=time.sleep):
    app = canonical(app); value = load_original(receipt, safety=app)
    verify_original(app, receipt)
    base = json.loads(regular_data(baseline))
    if base.get('schemaVersion') != 2 or base.get('target') != value['target'] or base.get('receiptSHA256') != digest(regular_data(receipt)) or not base.get('witnesses'):
        raise ValueError('Registration baseline is not this transaction')
    observations = []
    def observe():
        verify_original(app, receipt)
        bound = binding_at(Path(receipt).parent/'new-program-identity.json')
        if identity(Path(value['target'])) != bound['identity'] or bundle_info(value['target']) != bound['info']:
            raise ValueError('Formal application is absent or not this installed candidate')
        check_tree(Path(value['target']), bound['tree'])
        result = run([LSREGISTER, '-dump'], capture_output=True, text=True)
        if result.returncode: raise ValueError('LS query failed; absence is not proof')
        rows = bundle_records(result.stdout)
        hashes = {digest(json.dumps(x, sort_keys=True).encode()) for x in rows}
        if not set(base['witnesses']).issubset(hashes) or {'bundleID': BID, 'path': value['target']} not in rows:
            raise ValueError('LS view lost witnesses or formal-path anchor')
        own = [x for x in rows if x['bundleID'] in (BID, WIDGET_BID)]
        observations.append(own)
        return own
    event = {'app': str(app), 'bundleID': BID, 'status': 'failed', 'observations': observations}
    try:
        observe()
        command = run([LSREGISTER, '-u', str(app)], capture_output=True, text=True)
        plugin = run(['/usr/bin/pluginkit', '-r', str(app/WIDGET)], capture_output=True, text=True)
        event['unregisterReturncode'] = command.returncode; event['pluginRemoveReturncode'] = plugin.returncode
        # Register only the official existing extension, then require it to be visible in pluginkit.
        add = run(['/usr/bin/pluginkit', '-a', str(Path(value['target'])/WIDGET)], capture_output=True, text=True)
        if add.returncode: raise ValueError('Official widget could not be registered')
        for delay in (0, 1, 4):
            if delay: wait(delay)
            own = observe()
            if any(x['path'] == str(app) or x['path'].startswith(str(app)+'/') for x in own):
                raise ValueError('Retained backup still has an effective LS registration')
            if any(x['path'] not in (value['target'], str(Path(value['target'])/WIDGET)) for x in own):
                raise ValueError('Another own-bundle registration remains; do not report uniqueness')
            pk = run(['/usr/bin/pluginkit', '-m', '-A', '-D', '-vv', '-i', WIDGET_BID], capture_output=True, text=True)
            plugins = plugin_records(pk.stdout)
            expected_plugin = {'state': '+', 'bundleID': WIDGET_BID,
                'version': binding_at(Path(receipt).parent/'new-program-identity.json')['info'][WIDGET_BID]['CFBundleShortVersionString'],
                'path': str(Path(value['target'])/WIDGET)}
            if pk.returncode or plugins != [expected_plugin]:
                raise ValueError('Widget registrations not positively unique at the formal path')
        verify_original(app, receipt)
        event['status'] = 'exact-backup-path-absent-with-formal-anchors'
        return {'backupRegistrationRetired': True, 'originalRetained': True}
    finally:
        json_write(record, event)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('operation', choices=['bind', 'promote', 'capture-original', 'retain-original', 'verify-original', 'recover', 'registry-baseline', 'register-candidate', 'verify-registered', 'retire-registration', 'clean-stage'])
    for name in ('source', 'target', 'safety', 'binding', 'quarantine', 'receipt', 'baseline', 'record'):
        p.add_argument('--'+name, type=Path)
    p.add_argument('--widget-election', choices=['use'])
    a = p.parse_args()
    if a.widget_election is not None and a.operation != 'register-candidate':
        p.error('Widget election applies only to register-candidate')
    required = {'bind': ['source','binding'], 'promote': ['source','target','binding'],
        'capture-original': ['target','safety','receipt','binding'], 'retain-original': ['target','safety','receipt'],
        'verify-original': ['safety','receipt'], 'recover': ['target','safety','binding','quarantine','receipt'],
        'registry-baseline': ['target','receipt','baseline'], 'retire-registration': ['safety','receipt','baseline','record'],
        'register-candidate': ['receipt','baseline'], 'verify-registered': ['receipt'],
        'clean-stage': ['binding']}[a.operation]
    if any(getattr(a, n) is None for n in required): p.error('Missing exact transaction paths')
    try:
        if a.operation == 'bind': result = bind(a.source,a.binding)
        elif a.operation == 'promote': result = promote(a.source,a.target,a.binding)
        elif a.operation == 'capture-original':
            if canonical(a.binding) != canonical(a.receipt).parent/'new-program-identity.json': raise ValueError('Wrong candidate binding path')
            signatures = signature_record(a.target) if existing_identity(a.target) is not None else None
            result = capture_original(a.target,a.safety,a.receipt,signatures)
        elif a.operation == 'retain-original': result = retain_original(a.target,a.safety,a.receipt)
        elif a.operation == 'verify-original': result = verify_original(a.safety,a.receipt)
        elif a.operation == 'recover': result = recover(a.target,a.safety,a.binding,a.quarantine,a.receipt)
        elif a.operation == 'registry-baseline': result = registry_baseline(a.target,a.receipt,a.baseline)
        elif a.operation == 'register-candidate': result = register_candidate(a.receipt,a.baseline,widget_election=a.widget_election)
        elif a.operation == 'verify-registered': result = verify_registered(a.receipt)
        elif a.operation == 'retire-registration': result = retire_registration(a.safety,a.receipt,a.baseline,a.record)
        else: result = clean_stage(a.binding)
        print(json.dumps(result)); return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        # Additive diagnostics only. Never overwrite old receipts or turn a failed read into absence.
        locator = a.receipt or a.binding
        if locator is not None:
            try:
                parent = canonical(locator).parent
                noindex(locator)
                diagnostic = parent/('failure-'+a.operation+'-'+str(uuid.uuid4())+'.json')
                json_write(diagnostic, {'operation': a.operation, 'at': time.time(),
                    'arguments': {name: str(getattr(a,name)) if getattr(a,name) else None
                                  for name in ('source','target','safety','binding','receipt','baseline')},
                    'error': error_detail(error)})
                print('Failure receipt: '+str(diagnostic), file=sys.stderr)
            except (OSError, ValueError, TypeError) as diagnostic_error:
                print('Could not persist failure receipt: '+str(diagnostic_error), file=sys.stderr)
        print('Installation safety check failed: '+str(error)+'; existing objects and recovery evidence retained.',file=sys.stderr)
        return 3


if __name__ == '__main__':
    sys.exit(main())
