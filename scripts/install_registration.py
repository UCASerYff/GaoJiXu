"""Pure inventory checks for one candidate's explicitly recorded registration."""

import base64
import binascii
import hashlib
import math


_MACL_KEY = base64.b64encode(b'com.apple.macl').decode('ascii')
_TYPES = {type(None): 'null', bool: 'bool', int: 'int', float: 'float',
          str: 'string', list: 'array', dict: 'object'}


def _snapshot(value):
    """Validate typed JSON and return an independent copy."""
    kind = type(value)
    if kind in (type(None), bool, int, str):
        return value
    if kind is float and math.isfinite(value):
        return value
    if kind is list:
        return [_snapshot(item) for item in value]
    if kind is dict and all(type(key) is str for key in value):
        return {key: _snapshot(item) for key, item in value.items()}
    raise ValueError('Inventory must contain finite, string-keyed JSON values')


def exact_diff(before, after):
    """Return typed leaf/presence differences with unambiguous key/index paths."""
    before, after = _snapshot(before), _snapshot(after)
    changes = []

    def visit(previous, current, path, previous_present=True, current_present=True):
        if previous_present and current_present and type(previous) is type(current):
            if type(previous) is dict:
                for key in sorted(previous.keys() | current.keys()):
                    visit(previous.get(key), current.get(key), path + [key],
                          key in previous, key in current)
                return
            if type(previous) is list:
                for index in range(max(len(previous), len(current))):
                    has_previous, has_current = index < len(previous), index < len(current)
                    visit(previous[index] if has_previous else None,
                          current[index] if has_current else None, path + [index],
                          has_previous, has_current)
                return
            if previous == current:
                return
        changes.append({'path': path, 'beforePresent': previous_present,
                        'afterPresent': current_present,
                        'beforeType': _TYPES[type(previous)] if previous_present else None,
                        'afterType': _TYPES[type(current)] if current_present else None,
                        'before': previous, 'after': current})

    visit(before, after, [])
    return changes


def _validate_macl(value):
    if (type(value) is not dict or set(value) != {'bytes', 'sha256', 'rawBase64'}
            or type(value['bytes']) is not int or type(value['rawBase64']) is not str
            or type(value['sha256']) is not str):
        raise ValueError('MACL evidence requires exact bytes, SHA-256 and raw base64')
    try:
        raw = base64.b64decode(value['rawBase64'], validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError('Invalid MACL base64') from error
    if (base64.b64encode(raw).decode('ascii') != value['rawBase64']
            or len(raw) != value['bytes'] or hashlib.sha256(raw).hexdigest() != value['sha256']):
        raise ValueError('MACL raw bytes do not match the recorded size and SHA-256')


def _validate_observed_macl(value):
    if type(value) is dict and set(value) == {'bytes', 'sha256'}:
        if (type(value['bytes']) is not int or value['bytes'] < 0
                or type(value['sha256']) is not str or len(value['sha256']) != 64
                or any(char not in '0123456789abcdef' for char in value['sha256'])):
            raise ValueError('Invalid observed MACL summary')
        return
    _validate_macl(value)


def registration_transition(before_tree, after_tree, expected_macl):
    """Allow a predeclared root MACL addition, or only atime changes when expected is None."""
    before = _snapshot(before_tree)
    after = _snapshot(after_tree)
    expected = _snapshot(expected_macl)
    if expected is not None:
        _validate_macl(expected)
    if (type(before) is not dict or type(after) is not dict or '' not in before
            or before.keys() != after.keys()):
        raise ValueError('Missing root or different inventory paths')
    for tree in (before, after):
        for row in tree.values():
            if (type(row) is not dict or type(row.get('atimeNS')) is not int
                    or type(row.get('ctimeNS')) is not int or type(row.get('xattrs')) is not dict):
                raise ValueError('Incomplete inventory row')

    previous_attrs, current_attrs = before['']['xattrs'], after['']['xattrs']
    previous_present, current_present = _MACL_KEY in previous_attrs, _MACL_KEY in current_attrs
    previous_macl, current_macl = previous_attrs.get(_MACL_KEY), current_attrs.get(_MACL_KEY)
    if previous_present:
        _validate_observed_macl(previous_macl)
    if current_present:
        _validate_observed_macl(current_macl)
    added = not previous_present and current_present
    if added:
        if expected is None:
            raise ValueError('Root MACL addition was not predeclared')
        expected_summary = {'bytes': expected['bytes'], 'sha256': expected['sha256']}
        if current_macl != expected_summary and current_macl != expected:
            raise ValueError('Added root MACL differs from its predeclared exact value')

    differences = exact_diff(before, after)
    for difference in differences:
        path = difference['path']
        if len(path) == 2 and path[1] == 'atimeNS':
            continue
        if added and path in (['', 'ctimeNS'], ['', 'xattrs', _MACL_KEY]):
            continue
        raise ValueError('Unexpected registration inventory change at ' + repr(path))
    return {'schemaVersion': 1, 'entryCount': len(before), 'maclAdded': added,
            'expectedMACL': expected, 'rootMACLBefore': previous_macl,
            'rootMACLAfter': current_macl, 'exactDelta': differences}
