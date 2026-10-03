#!/usr/bin/env python3
"""Validate Xcode references, linked editor products, bundled notices, and immutable pins."""
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
text = (root / 'lilC.xcodeproj/project.pbxproj').read_text()
pattern = re.compile(r'\s+|//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+')
tokens = [m.group() for m in pattern.finditer(text) if not m.group().isspace() and not m.group().startswith(('//', '/*'))]
cursor = 0

def take(expected=None):
    global cursor
    value = tokens[cursor]
    cursor += 1
    if expected is not None:
        assert value == expected, (value, expected)
    return value

def parse():
    if tokens[cursor] == '{':
        take('{')
        result = {}
        while tokens[cursor] != '}':
            key = take()
            take('=')
            value = parse()
            take(';')
            assert key not in result, f'Duplicate Xcode object/key: {key}'
            result[key] = value
        take('}')
        return result
    if tokens[cursor] == '(':
        take('(')
        result = []
        while tokens[cursor] != ')':
            result.append(parse())
            if tokens[cursor] == ',':
                take(',')
        take(')')
        return result
    value = take()
    return json.loads(value) if value.startswith('"') else value

project = parse()
assert cursor == len(tokens)
objects = project['objects']
for key, obj in objects.items():
    if obj.get('isa') == 'PBXBuildFile':
        ref = obj.get('fileRef') or obj.get('productRef')
        assert ref in objects, f'Unresolved build reference: {key}'
    for field in ['buildPhases', 'children', 'files', 'packageProductDependencies', 'packageReferences']:
        for ref in obj.get(field, []):
            assert ref in objects, f'Unresolved {field} reference: {key}/{ref}'

app = objects['100000000000000000000401']
products = {objects[ref]['productName']: ref for ref in app['packageProductDependencies']}
expected = {'Runestone', 'TreeSitterCRunestone', 'TreeSitterPythonRunestone', 'TreeSitterJavaScriptRunestone', 'TreeSitterLuaRunestone'}
assert expected <= products.keys()
linked = {objects[ref].get('productRef') for ref in objects['100000000000000000000601']['files']}
assert {products[p] for p in expected} <= linked
for name, phase in [('Domain/EditorSupport.swift', '100000000000000000000901'),
                    ('Resources/Runestone-LICENSES.txt', '100000000000000000000A01')]:
    refs = {key for key, obj in objects.items() if obj.get('path') == name}
    assert len(refs) == 1 and (root / 'lilC' / name).is_file()
    assert any(objects[build].get('fileRef') in refs for build in objects[phase]['files'])

pins = json.loads((root / 'lilC.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())['pins']
pins = {p['identity']: p['state'] for p in pins}
for identity, version, revision in [('runestone', '0.5.2', '592434a103a4d1ab83e14f87ac6eef569dd7a99d'),
                                   ('treesitterlanguages', '0.1.10', '15cf3a9ec3ab95e0d058b7df9f35619123c9e02d'),
                                   ('tree-sitter', '0.20.9', '98be227227af10cc7a269cb3ffb23686c0610b17')]:
    assert pins[identity] == dict(version=version, revision=revision)
print('PASS: Xcode project references, linked language products, bundled licenses, and pinned revisions')
