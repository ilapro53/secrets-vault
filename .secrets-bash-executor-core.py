#!/usr/bin/env python3
"""secrets-bash-executor core — OTP-gated bash executor with secret injection.
Called by the bash wrapper. Reads stdin body from SCR_BODY_FILE env var."""
import os, sys, hmac, hashlib, time, struct, subprocess

b32secret = os.environ.get("TOTP_SECRET", "")
if not b32secret:
    print("❌ TOTP_SECRET env var not set", file=sys.stderr)
    sys.exit(2)


def b32decode(s):
    b32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    s = s.upper().strip()
    bits = "".join(format(b32.index(c), "05b") for c in s if c in b32)
    return bytes(int(bits[i*8:(i+1)*8], 2) for i in range(len(bits)//8))


def gen_code(key, msg, tw):
    text = f"{msg}|{tw}"
    h = hmac.new(key, text.encode(), hashlib.sha1).digest()
    off = h[-1] & 0xf
    p = struct.unpack(">I", h[off:off+4])[0] & 0x7fffffff
    return f"{p % 1000000:06d}"


def verify_code(key, msg, code_input):
    code_parts = code_input.split("-")
    codes_to_check = [p.strip() for p in code_parts if len(p.strip()) == 6 and p.strip().isdigit()]
    if not codes_to_check:
        return False
    now = int(time.time())
    expected = set()
    for offset in (0, -1, 1):
        tw = now // 300 + offset
        expected.add(gen_code(key, msg, tw))
        expected.add(gen_code(key, msg, tw + 1))
        expected.add(gen_code(key, msg, tw - 1))
    return any(c in expected for c in codes_to_check)


def main():
    key = b32decode(b32secret)

    args = sys.argv[1:]
    secrets_list = None
    code = None
    i = 0
    while i < len(args):
        if args[i] == "--secrets" and i + 1 < len(args):
            secrets_list = args[i + 1]; i += 2
        elif args[i] == "--code" and i + 1 < len(args):
            code = args[i + 1]; i += 2
        else:
            i += 1

    if not secrets_list:
        print("Usage: secrets-bash-executor --secrets VAR1,VAR2 --code XXXXXX-XXXXXX - <<SCRIPT", file=sys.stderr)
        sys.exit(1)

    # Read script body from temp file
    tempfile = os.environ.get("SCR_BODY_FILE", "")
    if not tempfile or not os.path.isfile(tempfile):
        print("❌ Script body file not found (SCR_BODY_FILE)", file=sys.stderr)
        sys.exit(2)
    with open(tempfile) as f:
        stdin_body = f.read()

    # Reconstruct full text WITHOUT --code
    arg_parts = []
    si = 0
    while si < len(args):
        if args[si] == "--code":
            si += 2
        else:
            arg_parts.append(args[si])
            si += 1
    header = "secrets-bash-executor " + " ".join(arg_parts)

    full_text = f"{header} <<'SCRIPT'\n{stdin_body}SCRIPT"
    full_text = full_text.rstrip()

    # OTP verification
    if not code:
        print("ERROR: --code XXXXXX-XXXXXX is required", file=sys.stderr)
        sys.exit(1)
    if not verify_code(key, full_text, code):
        print("❌ ACCESS DENIED: wrong or expired code", file=sys.stderr)
        sys.exit(1)
    print("✅ CODE VERIFIED", file=sys.stderr)

    # Export secrets from pass
    secret_vars = [v.strip() for v in secrets_list.split(",") if v.strip()]
    for var in secret_vars:
        result = subprocess.run(["pass", "show", var], capture_output=True, text=True)
        if result.returncode != 0:
            print(f"❌ Secret '{var}' not found in pass", file=sys.stderr)
            print(f"   Add it: pass insert {var}", file=sys.stderr)
            sys.exit(1)
        value = result.stdout.strip().split("\n")[0]
        os.environ[var] = value
        print(f"  → ${var} loaded from pass", file=sys.stderr)

    # Execute script
    proc = subprocess.run(["bash"], input=stdin_body, text=True)
    sys.exit(proc.returncode)


if __name__ == "__main__":
    main()
