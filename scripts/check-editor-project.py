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
expected = {'ZIPFoundation', 'Runestone', 'TreeSitterCRunestone', 'TreeSitterPythonRunestone', 'TreeSitterJavaScriptRunestone', 'TreeSitterLuaRunestone'}
assert expected <= products.keys()
linked = {objects[ref].get('productRef') for ref in objects['100000000000000000000601']['files']}
assert {products[p] for p in expected} <= linked
for name, phase in [('Domain/DocumentText.swift', '100000000000000000000901'),
                    ('Domain/DocumentTutorClient.swift', '100000000000000000000901'),
                    ('Infrastructure/ChatDocumentStore.swift', '100000000000000000000901'),
                    ('Presentation/ChatFilesSheet.swift', '100000000000000000000901'),
                    ('Resources/ZIPFoundation-LICENSE.txt', '100000000000000000000A01'),
                    ('Domain/IDEHomeLayout.swift', '100000000000000000000901'),
                    ('Presentation/IDEHomeGrid.swift', '100000000000000000000901'),
                    ('Domain/EditorSupport.swift', '100000000000000000000901'),
                    ('Domain/AgentProjectHistory.swift', '100000000000000000000901'),
                    ('Resources/Runestone-LICENSES.txt', '100000000000000000000A01')]:
    refs = {key for key, obj in objects.items() if obj.get('path') == name}
    assert len(refs) == 1 and (root / 'lilC' / name).is_file()
    assert any(objects[build].get('fileRef') in refs for build in objects[phase]['files'])

# Both large assets are staged locally by the fetch scripts, then copied into the app.
# Git/CI checkouts need not contain the ignored binaries to validate resource membership.
resources = objects['100000000000000000000A01']['files']
for filename in ['Qwen3.5-4B-Q4_K_M.gguf', 'LFM2.5-1.2B-Instruct-Q4_K_M.gguf']:
    refs = {key for key, obj in objects.items()
            if obj.get('path') == 'lilC/Resources/Models/' + filename and obj.get('sourceTree') == 'SOURCE_ROOT'}
    assert len(refs) == 1, f'Missing or duplicate bundled model: {filename}'
    assert sum(objects[build].get('fileRef') in refs for build in resources) == 1
asset_source = (root / 'lilC/Domain/ChatModel.swift').read_text()
fetch_source = (root / 'scripts/fetch-mini-assets.sh').read_text()
for key in ['revision', 'filename', 'sha256']:
    pin = re.search(r'static let ' + key + r' = "([^"\n]+)"', asset_source).group(1)
    assert pin in fetch_source, f'Mini asset fetch disagrees with runtime {key}'
assert 'fetch-mini-assets.sh' in (root / 'scripts/fetch-agent-assets.sh').read_text()

pins = json.loads((root / 'lilC.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())['pins']
pins = {p['identity']: p['state'] for p in pins}
for identity, version, revision in [('zipfoundation', '0.9.20', '22787ffb59de99e5dc1fbfe80b19c97a904ad48d'),
                                   ('runestone', '0.5.2', '592434a103a4d1ab83e14f87ac6eef569dd7a99d'),
                                   ('treesitterlanguages', '0.1.10', '15cf3a9ec3ab95e0d058b7df9f35619123c9e02d'),
                                   ('tree-sitter', '0.20.9', '98be227227af10cc7a269cb3ffb23686c0610b17')]:
    assert pins[identity] == dict(version=version, revision=revision)
print('PASS: Xcode project references, linked language products, bundled models/licenses, and pinned revisions')
