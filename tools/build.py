#!/usr/bin/env python3
"""Build the release folder + zip from src/, with safety checks.

Usage: python3 tools/build.py      (output: dist/nvme-ssd-rescue/ and dist/nvme-ssd-rescue-v6.zip)

- fix_win.cmd : UTF-8 source -> GBK + CRLF (Chinese WinPE runs code page 936)
- *.txt       : UTF-8 with BOM + CRLF (Notepad-friendly)
- *.sh        : UTF-8 + LF, executable
"""
import os, re, shutil, subprocess, sys, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'src')
TOOLS = os.path.join(ROOT, 'tools')
VERSION = 'v6'
OUT = os.path.join(ROOT, 'dist', 'nvme-ssd-rescue')
ZIP = os.path.join(ROOT, 'dist', f'nvme-ssd-rescue-{VERSION}.zip')
SC = os.environ.get('SHELLCHECK') or shutil.which('shellcheck')

errors = []

def check_cmd(text):
    lines = text.split('\n')
    # 1. every char encodable in GBK, and no double-byte char whose trail byte is a cmd metachar
    for i, l in enumerate(lines, 1):
        for c in l:
            try:
                b = c.encode('gbk')
            except UnicodeEncodeError:
                errors.append(f'cmd:{i}: not GBK-encodable: {c!r}')
                continue
            if len(b) == 2 and b[1] in b'|^&<>%!"':
                errors.append(f'cmd:{i}: GBK trail byte is a cmd metachar: {c!r}')
    # 2. goto / call targets exist
    labels = set(m.lower() for m in re.findall(r'^:(\w+)', text, re.M))
    for i, l in enumerate(lines, 1):
        s = l.strip()
        if s.lower().startswith('rem') or s.startswith('::'):
            continue
        for m in re.finditer(r'\b(?:goto|call)\s+:?(\w+)', s, re.I):
            t = m.group(1).lower()
            if t != 'eof' and t not in labels:
                errors.append(f'cmd:{i}: jump target missing: {t}')
    # 3. echo/set-p text must not contain unescaped metachars or stray '!'
    setvars = set(re.findall(r'set\s+(?:/[ap]\s+)?"?(\w+)[-+]?=', text, re.I)) | {'errorlevel'}
    setvars |= set(re.findall(r'set\s+"?(\w+)%~?\w+%?=', text, re.I))   # e.g. set "SZ%~1=..."
    allowed_bang = r'!(?:' + '|'.join(sorted(setvars)) + r')(?:%\w+%)?(?::[^!]*)?!'
    depth = 0
    for i, l in enumerate(lines, 1):
        s = l.strip()
        low = s.lower()
        body = None
        if low.startswith('echo'):
            body = s[4:]
        elif re.match(r'^>>?"?%\w+%"?\s+echo\s', s, re.I):
            body = re.sub(r'^>>?"?%\w+%"?\s+echo', '', s, flags=re.I)
        elif low.startswith('set /p'):
            body = s
        if body is not None:
            bare = re.sub(allowed_bang, '', body)
            bare = re.sub(r'%~?[A-Za-z0-9_]+(?::~?-?\d+(?:,-?\d+)?)?%|%%~?\w|%~[a-z]*\d|%\*', '', bare)
            bare = bare.replace('^^', '').replace('^&', '').replace('^|', '').replace('^<', '').replace('^>', '').replace('^)', '').replace('^(', '')
            if low.startswith('set /p'):
                bare = bare.split('=', 1)[-1]
            if '!' in bare:
                errors.append(f'cmd:{i}: stray ! in text: {s}')
            for ch in '&|<>%':
                if ch in bare:
                    errors.append(f'cmd:{i}: unescaped {ch} in text: {s}')
            if depth > 0 and re.search(r'(?<!\^)[()]', bare):
                errors.append(f'cmd:{i}: unescaped paren inside ( ) block: {s}')
        if not (low.startswith('echo') or low.startswith('rem') or low.startswith('set /p')):
            code = re.sub(r'"[^"]*"', '', s)
            depth += code.count('(') - code.count(')')
            if depth < 0:
                errors.append(f'cmd:{i}: paren depth < 0')
                depth = 0
    if depth != 0:
        errors.append(f'cmd: unbalanced parens at EOF (depth {depth})')

def main():
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    for root, _, files in os.walk(SRC):
        for f in files:
            sp = os.path.join(root, f)
            rel = os.path.relpath(sp, SRC)
            dp = os.path.join(OUT, rel)
            os.makedirs(os.path.dirname(dp), exist_ok=True)
            if os.sep + 'bcd' + os.sep in sp:
                shutil.copyfile(sp, dp)          # 启动配置模板：原样复制，不转换编码
                continue
            text = open(sp, encoding='utf-8').read().replace('\r\n', '\n')
            if f.endswith('.cmd'):
                check_cmd(text)
                open(dp, 'wb').write(text.replace('\n', '\r\n').encode('gbk', errors='replace'))
            elif f.endswith('.sh') or f.endswith('.yaml') or '.' not in f:
                open(dp, 'wb').write(text.encode('utf-8'))
                os.chmod(dp, 0o755)
                if f.endswith('.yaml'):
                    continue
                r = subprocess.run(['bash', '-n', dp], capture_output=True, text=True)
                if r.returncode:
                    errors.append('bash -n: ' + r.stderr)
                if not SC:
                    print('warning: shellcheck not found, skipped')
                    continue
                r = subprocess.run([SC, '-S', 'info', '-e', 'SC1111,SC2002', dp], capture_output=True, text=True)
                if r.returncode:
                    errors.append('shellcheck:\n' + r.stdout)
            else:
                open(dp, 'wb').write(b'\xef\xbb\xbf' + text.replace('\n', '\r\n').encode('utf-8'))
    # Windows-side helpers go to the zip root: .ps1 must be UTF-8 with BOM (PowerShell 5.1), CRLF
    for f in ('make_usb.ps1', '制作U盘.cmd'):
        text = open(os.path.join(TOOLS, f), encoding='utf-8-sig').read().replace('\r\n', '\n')
        bom = b'\xef\xbb\xbf' if f.endswith('.ps1') else b''
        open(os.path.join(OUT, f), 'wb').write(bom + text.replace('\n', '\r\n').encode('utf-8' if bom else 'ascii'))
    if not open(os.path.join(TOOLS, 'make_usb.ps1'), 'rb').read(3) == b'\xef\xbb\xbf':
        errors.append('tools/make_usb.ps1 must be saved as UTF-8 with BOM (Windows PowerShell 5.1)')
    if errors:
        print('\n'.join(errors))
        sys.exit(1)
    if os.path.exists(ZIP):
        os.remove(ZIP)
    with zipfile.ZipFile(ZIP, 'w', zipfile.ZIP_DEFLATED) as z:
        for root, _, files in sorted(os.walk(OUT)):
            for f in sorted(files):
                p = os.path.join(root, f)
                arc = 'nvme-ssd-rescue/' + os.path.relpath(p, OUT)
                zi = zipfile.ZipInfo.from_file(p, arc)
                if f.endswith('.sh') or '.' not in f:
                    zi.external_attr = 0o100755 << 16
                z.writestr(zi, open(p, 'rb').read(), zipfile.ZIP_DEFLATED)
    for i in zipfile.ZipFile(ZIP).infolist():
        print(f'{i.file_size:>7}  {i.filename}')
    print('BUILD OK')

main()
