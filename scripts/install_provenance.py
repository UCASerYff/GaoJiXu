"""Compare inventories immediately before and after a same-volume App rename."""

import base64
import binascii
import hashlib
import json


_NAME = 'com.apple.provenance'
_KEY = base64.b64encode(_NAME.encode('ascii')).decode('ascii')


def _root_provenance(attrs):
    if _KEY not in attrs:
        return None
    value = attrs[_KEY]
    if (not isinstance(value, dict) or set(value) != {'bytes', 'sha256', 'rawBase64'}
            or type(value['bytes']) is not int or not isinstance(value['rawBase64'], str)):
        raise ValueError('Incomplete root provenance evidence')
    try:
        raw = base64.b64decode(value['rawBase64'], validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError('Invalid root provenance encoding') from error
    if (base64.b64encode(raw).decode('ascii') != value['rawBase64']
            or len(raw) != value['bytes'] or hashlib.sha256(raw).hexdigest() != value['sha256']):
        raise ValueError('Root provenance bytes do not match their receipt')
    return value.copy()


def _strict_fields(row, root):
    if (not isinstance(row, dict) or type(row.get('atimeNS')) is not int
            or type(row.get('ctimeNS')) is not int or not isinstance(row.get('xattrs'), dict)):
        raise ValueError('Incomplete inventory row')
    fixed = row.copy()
    del fixed['atimeNS']
    if root:
        del fixed['ctimeNS']
        fixed['xattrs'] = {name: value for name, value in row['xattrs'].items() if name != _KEY}
    # Compare typed JSON values, including opaque fields introduced by the inventory producer.
    try:
        return json.dumps(fixed, sort_keys=True, allow_nan=False)
    except (TypeError, ValueError) as error:
        raise ValueError('Invalid JSON inventory row') from error


def transition(before_tree, after_tree):
    """Return exact observed deltas for an allowed rename, without modifying either inventory."""
    if (not isinstance(before_tree, dict) or not isinstance(after_tree, dict)
            or '' not in before_tree or before_tree.keys() != after_tree.keys()
            or any(not isinstance(path, str) for path in before_tree)):
        raise ValueError('Missing root or different inventory paths')

    delta = []
    for path in sorted(before_tree):
        before, after = before_tree[path], after_tree[path]
        root = path == ''
        if _strict_fields(before, root) != _strict_fields(after, root):
            raise ValueError('Unexpected inventory change at ' + repr(path))
        for field in (('atimeNS', 'ctimeNS') if root else ('atimeNS',)):
            if before[field] != after[field]:
                delta.append({'path': path, 'field': field, 'before': before[field], 'after': after[field]})

    previous = _root_provenance(before_tree['']['xattrs'])
    current = _root_provenance(after_tree['']['xattrs'])
    if (previous is None) != (current is None):
        raise ValueError('Root provenance was added or removed')
    if previous != current:
        delta.append({'path': '', 'field': _NAME, 'before': previous, 'after': current})
    return {'schemaVersion': 1, 'entryCount': len(before_tree),
            'rootProvenanceBefore': previous, 'rootProvenanceAfter': current, 'exactDelta': delta}
