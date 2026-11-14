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
