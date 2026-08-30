#!/usr/bin/env python3
import argparse, os, re, secrets, stat, tempfile
from pathlib import Path

CFG = Path('/etc/mtpadmin/config/config.toml')
NAME_RE = re.compile(r'^[A-Za-z0-9_.-]{1,64}$')
SECTION_RE = re.compile(r'^\s*\[([^\[\]]+)\]\s*(?:#.*)?$')
KEY_RE_TEMPLATE = r'^\s*(?:"{q}"|{u})\s*='


def q(s: str) -> str:
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def load_lines():
    return CFG.read_text(encoding='utf-8').splitlines(keepends=True)


def section_bounds(lines, section):
    start = None
    for i, line in enumerate(lines):
        m = SECTION_RE.match(line)
        if not m:
            continue
        if start is None:
            if m.group(1).strip() == section:
                start = i
        else:
            return start, i
    if start is not None:
        return start, len(lines)
    return None, None


def key_re(key):
    return re.compile(KEY_RE_TEMPLATE.format(q=re.escape(key), u=re.escape(key)))


def get_key(lines, section, key):
    a, b = section_bounds(lines, section)
    if a is None:
        return None
    kr = key_re(key)
    for i in range(a + 1, b):
        if kr.match(lines[i]):
            return lines[i].split('=', 1)[1].strip()
    return None


def set_key(lines, section, key, value_literal):
    a, b = section_bounds(lines, section)
    line = f'{q(key)} = {value_literal}\n'
    if a is None:
        if lines and not lines[-1].endswith('\n'):
            lines[-1] += '\n'
        if lines and lines[-1].strip():
            lines.append('\n')
        lines.extend([f'[{section}]\n', line])
        return
    kr = key_re(key)
    for i in range(a + 1, b):
        if kr.match(lines[i]):
            lines[i] = line
            return
    insert = b
    while insert > a + 1 and not lines[insert - 1].strip():
        insert -= 1
    lines.insert(insert, line)


def del_key(lines, section, key):
    a, b = section_bounds(lines, section)
    if a is None:
        return False
    kr = key_re(key)
    for i in range(a + 1, b):
        if kr.match(lines[i]):
            del lines[i]
            return True
    return False


def write_atomic(lines):
    st = CFG.stat()
    fd, tmppath = tempfile.mkstemp(prefix='.config.toml.', dir=str(CFG.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.writelines(lines)
            f.flush(); os.fsync(f.fileno())
        os.chown(tmppath, st.st_uid, st.st_gid)
        os.chmod(tmppath, stat.S_IMODE(st.st_mode))
        os.replace(tmppath, CFG)
    finally:
        try: os.unlink(tmppath)
        except FileNotFoundError: pass


def require_name(name):
    if not NAME_RE.fullmatch(name or ''):
        raise SystemExit('invalid source name; use 1..64 chars A-Z a-z 0-9 _ . -')


def source_exists(lines, name):
    return get_key(lines, 'access.users', name) is not None


def add(args):
    require_name(args.name)
    lines = load_lines()
    if source_exists(lines, args.name):
        raise SystemExit('source already exists')
    secret = (args.secret or secrets.token_hex(16)).lower()
    if not re.fullmatch(r'[0-9a-f]{32}', secret):
        raise SystemExit('secret must be exactly 32 hex chars')
    set_key(lines, 'access.users', args.name, q(secret))
    del_key(lines, 'access.user_enabled', args.name)
    if args.ad_tag:
        tag = args.ad_tag.lower()
        if not re.fullmatch(r'[0-9a-f]{32}', tag):
            raise SystemExit('ad tag must be 32 hex chars')
        set_key(lines, 'access.user_ad_tags', args.name, q(tag))
    if args.max_conns is not None:
        if args.max_conns < 1: raise SystemExit('max-conns must be >= 1')
        set_key(lines, 'access.user_max_tcp_conns', args.name, str(args.max_conns))
    if args.max_ips is not None:
        if args.max_ips < 1: raise SystemExit('max-ips must be >= 1')
        set_key(lines, 'access.user_max_unique_ips', args.name, str(args.max_ips))
    write_atomic(lines)
    print(secret)


def disable(args):
    require_name(args.name); lines = load_lines()
    if not source_exists(lines, args.name): raise SystemExit('source not found')
    set_key(lines, 'access.user_enabled', args.name, 'false')
    write_atomic(lines)


def enable(args):
    require_name(args.name); lines = load_lines()
    if not source_exists(lines, args.name): raise SystemExit('source not found')
    del_key(lines, 'access.user_enabled', args.name)
    write_atomic(lines)


def rotate(args):
    require_name(args.name); lines = load_lines()
    if not source_exists(lines, args.name): raise SystemExit('source not found')
    secret = (args.secret or secrets.token_hex(16)).lower()
    if not re.fullmatch(r'[0-9a-f]{32}', secret): raise SystemExit('secret must be exactly 32 hex chars')
    set_key(lines, 'access.users', args.name, q(secret))
    write_atomic(lines); print(secret)


def delete(args):
    require_name(args.name); lines = load_lines()
    if not source_exists(lines, args.name): raise SystemExit('source not found')
    sections = [
        'access.users','access.user_enabled','access.user_ad_tags',
        'access.user_max_tcp_conns','access.user_expirations',
        'access.user_data_quota','access.user_max_unique_ips',
        'access.user_rate_limits','access.user_source_deny'
    ]
    for sec in sections: del_key(lines, sec, args.name)
    write_atomic(lines)


def set_limits(args):
    require_name(args.name); lines = load_lines()
    if not source_exists(lines, args.name): raise SystemExit('source not found')
    if args.max_conns == 'none': del_key(lines, 'access.user_max_tcp_conns', args.name)
    elif args.max_conns is not None:
        n=int(args.max_conns); assert n>=1; set_key(lines,'access.user_max_tcp_conns',args.name,str(n))
    if args.max_ips == 'none': del_key(lines, 'access.user_max_unique_ips', args.name)
    elif args.max_ips is not None:
        n=int(args.max_ips); assert n>=1; set_key(lines,'access.user_max_unique_ips',args.name,str(n))
    write_atomic(lines)


def main():
    p=argparse.ArgumentParser()
    sub=p.add_subparsers(dest='cmd',required=True)
    a=sub.add_parser('add'); a.add_argument('name'); a.add_argument('--secret'); a.add_argument('--ad-tag'); a.add_argument('--max-conns',type=int); a.add_argument('--max-ips',type=int); a.set_defaults(fn=add)
    a=sub.add_parser('disable'); a.add_argument('name'); a.set_defaults(fn=disable)
    a=sub.add_parser('enable'); a.add_argument('name'); a.set_defaults(fn=enable)
    a=sub.add_parser('rotate'); a.add_argument('name'); a.add_argument('--secret'); a.set_defaults(fn=rotate)
    a=sub.add_parser('delete'); a.add_argument('name'); a.set_defaults(fn=delete)
    a=sub.add_parser('limits'); a.add_argument('name'); a.add_argument('--max-conns'); a.add_argument('--max-ips'); a.set_defaults(fn=set_limits)
    args=p.parse_args(); args.fn(args)

if __name__ == '__main__': main()
