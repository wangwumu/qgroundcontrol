#!/usr/bin/env python3
"""Apply translations from a results file to .ts files.

Usage:
    python3 tools/translations/qgc_apply_translations.py <translations_file>

The translations file should have lines in format:
    context ||| source ||| translation
"""

import re
import sys
from xml.etree import ElementTree as ET

SRC_TS = 'translations/qgc_source_zh_CN.ts'
JSON_TS = 'translations/qgc_json_zh_CN.ts'


def parse_translations(path):
    """Parse translations file into dict: (context, source) -> translation"""
    result = {}
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split('|||')
            if len(parts) == 3:
                ctx = parts[0].strip()
                src = parts[1].strip()
                trans = parts[2].strip()
                result[(ctx, src)] = trans
    return result


def apply_to_file(ts_path, translations, label):
    """Apply translations to a .ts file."""
    tree = ET.parse(ts_path)
    root = tree.getroot()
    applied = 0
    skipped_because_has_chinese = 0
    skipped_because_same = 0

    for context in root:
        ctx_name = context.findtext('name', '')
        for msg in context:
            if msg.tag != 'message':
                continue
            source_elem = msg.find('source')
            trans_elem = msg.find('translation')
            if source_elem is None or trans_elem is None:
                continue

            source = (source_elem.text or '').strip()
            is_unfinished = trans_elem.get('type') == 'unfinished'

            if not is_unfinished:
                continue

            # Look up translation
            key = (ctx_name, source)
            if key in translations:
                translation = translations[key]
                # Skip mixed Chinese-English results (word-by-word replacements)
                has_chinese = bool(re.search(r'[一-鿿]', translation))
                mixed = has_chinese and bool(re.search(r'[a-zA-Z]{3,}', translation)) and translation != source

                if not has_chinese or translation == source:
                    skipped_because_same += 1
                    continue

                # Skip if result looks like word-by-word (more than 3 English words mixed in)
                eng_words = len(re.findall(r'[a-zA-Z]{3,}', translation))
                if eng_words > 3:
                    skipped_because_same += 1
                    continue

                trans_elem.text = translation
                if 'type' in trans_elem.attrib:
                    del trans_elem.attrib['type']
                applied += 1

    tree.write(ts_path, encoding='utf-8', xml_declaration=True)
    print(f'{label}: Applied {applied} translations')
    return applied


def count_remaining(ts_path):
    """Count unfinished translations."""
    tree = ET.parse(ts_path)
    count = 0
    for context in tree.getroot():
        for msg in context:
            if msg.tag != 'message':
                continue
            trans = msg.find('translation')
            if trans is not None and trans.get('type') == 'unfinished':
                count += 1
    return count


def extract_remaining(ts_path):
    """Extract remaining untranslated strings as a text prompt."""
    tree = ET.parse(ts_path)
    lines = []
    for context in tree.getroot():
        ctx_name = context.findtext('name', '')
        for msg in context:
            if msg.tag != 'message':
                continue
            trans = msg.find('translation')
            source = msg.find('source')
            if trans is not None and source is not None and trans.get('type') == 'unfinished':
                s = (source.text or '').strip()
                if s:
                    lines.append(f'{ctx_name} ||| {s}')
    return lines


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--extract':
        # Extract mode: print prompt for agent
        src_lines = extract_remaining(SRC_TS)
        json_lines = extract_remaining(JSON_TS)
        total = len(src_lines) + len(json_lines)
        print(f'You are a professional drone/GCS translator. Translate EACH of these {total} strings to fluent Chinese.')
        print(f'Use drone industry terminology. Keep %1 placeholders and acronyms unchanged.')
        print('Output exactly one line per string: context ||| source ||| translation')
        print()
        for line in src_lines:
            print(line)
        for line in json_lines:
            print(line)
    elif len(sys.argv) > 1:
        # Apply mode
        trans_path = sys.argv[1]
        print(f'Loading translations from {trans_path}')
        translations = parse_translations(trans_path)
        print(f'Found {len(translations)} translation entries')

        total = 0
        for ts_path, label in [(SRC_TS, 'Source'), (JSON_TS, 'JSON')]:
            before = count_remaining(ts_path)
            n = apply_to_file(ts_path, translations, label)
            after = count_remaining(ts_path)
            print(f'  {label}: {before} -> {after} remaining')
            total += n
        print(f'Total applied: {total}')
    else:
        # Show status
        src_rem = count_remaining(SRC_TS)
        json_rem = count_remaining(JSON_TS)
        print(f'Source remaining: {src_rem}')
        print(f'JSON remaining: {json_rem}')
        print(f'Total remaining: {src_rem + json_rem}')
        print()
        print('Usage:')
        print(f'  python3 {sys.argv[0]} --extract  # Generate translation prompt')
        print(f'  python3 {sys.argv[0]} <translations_file>  # Apply translations')
