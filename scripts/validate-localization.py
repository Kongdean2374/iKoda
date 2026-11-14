#!/usr/bin/env python3
"""Validate authored catalogs before Xcode compiles them; no third-party dependencies."""
import collections
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
FORMAT = re.compile(r'%(?:(\d+)\$)?([-+#0 ]*\d*(?:\.\d+)?(?:hh|ll|[hljztL])?[@diuoxXfFeEgGaAcCsSp])')

def placeholders(text):
    # Positional translations may reorder arguments, but may not change their types.
    return collections.Counter(m.group(2) for m in FORMAT.finditer(text.replace('%%', '')))

def units(node):
    if isinstance(node, dict):
        if 'stringUnit' in node:
            yield node['stringUnit']
        for key, value in node.items():
            if key != 'stringUnit':
                yield from units(value)

count = 0
for relative in ('Koda/Localizable.xcstrings', 'Koda/InfoPlist.xcstrings',
                 'Koda/AppShortcuts.xcstrings', 'KodaWidgets/Localizable.xcstrings'):
    path = ROOT / relative
    catalog = json.loads(path.read_text())
    assert catalog['sourceLanguage'] == 'en', relative
    assert catalog['version'] == '1.0', relative
    for key, entry in catalog['strings'].items():
        translations = entry.get('localizations', {})
        assert 'zh-Hant' in translations, (relative, key, 'missing zh-Hant')
        translated_units = list(units(translations['zh-Hant']))
        assert translated_units, (relative, key, 'empty translation')
        for unit in translated_units:
            assert unit['state'] == 'translated', (relative, key, 'unfinished')
            value = unit['value']
            assert value or not key, (relative, key, 'empty value')
            # Substitutions with plural variations are checked by Xcode; simple strings here.
            if 'substitutions' not in translations['zh-Hant']:
                assert placeholders(key) == placeholders(value), (relative, key, value, 'format mismatch')
            if relative.endswith('AppShortcuts.xcstrings'):
                assert sorted(re.findall(r'\$\{[^}]+\}', key)) == sorted(re.findall(r'\$\{[^}]+\}', value)), (key, value)
        count += 1
print(f'PASS: {count} catalog entries have completed zh-Hant translations and matching format arguments.')

# Swift Package Manager processes KodaCore's standard .strings resources directly.
# They need the same completeness/format checks as the app's String Catalogs.
def core_strings(language):
    path = ROOT / f'KodaCore/Sources/KodaCore/Resources/{language}.lproj/Localizable.strings'
    result = {}
    literal = r'"(?:[^"\\]|\\.)*"'
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('/*'):
            continue
        match = re.fullmatch(rf'\s*({literal})\s*=\s*({literal})\s*;\s*', line)
        assert match, (path, line, 'invalid strings entry')
        key, value = (json.loads(part) for part in match.groups())
        assert key not in result, (path, key, 'duplicate key')
        result[key] = value
    return result

english, traditional = core_strings('en'), core_strings('zh-Hant')
assert english.keys() == traditional.keys(), 'KodaCore language keys do not match'
for key, value in traditional.items():
    assert value or not key, (key, 'empty Core translation')
    assert placeholders(english[key]) == placeholders(value), (key, 'Core format mismatch')
for source in (ROOT / 'KodaCore/Sources/KodaCore').rglob('*.swift'):
    for key_literal in re.findall(r'NSLocalizedString\(\s*("(?:[^"\\]|\\.)*")\s*,\s*bundle:\s*KodaLocalization.bundle', source.read_text()):
        key = json.loads(key_literal)
        assert key in traditional, (source, key, 'missing Core translation')
print(f'PASS: {len(traditional)} KodaCore strings have matching English/zh-Hant resources and format arguments.')
