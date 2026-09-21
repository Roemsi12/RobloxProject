"""
Uploads the avatar textures to Roblox as Image assets and writes their ids
into src/shared/AvatarTextures.luau.

    python art/avatar/upload.py --user-id 12345
    python art/avatar/upload.py --group-id 67890
    python art/avatar/upload.py --user-id 12345 --force shirt_tunic

Needs an Open Cloud API key in the ROBLOX_API_KEY environment variable, made
at create.roblox.com -> Open Cloud -> API Keys with the Assets API's read and
write permissions, owned by the same user or group you pass here. The images
must be owned by the experience's owner (or a group it belongs to) to be sure
they load in it.

Only textures whose id is still 0 are uploaded; name textures after --force
to replace particular ones (they get new ids, the old images stay). Standard
library only.
"""

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
TEXTURES = os.path.join(HERE, "textures")
REGISTRY = os.path.normpath(os.path.join(HERE, "..", "..", "src", "shared", "AvatarTextures.luau"))

API = "https://apis.roblox.com/assets/v1"


def request(method, url, key, body=None, content_type=None):
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("x-api-key", key)
    if content_type:
        req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req) as res:
            return json.loads(res.read() or b"{}")
    except urllib.error.HTTPError as err:
        raise SystemExit(f"{method} {url} failed: {err.code} {err.read().decode(errors='replace')}")


def upload(path, name, creator, key):
    boundary = uuid.uuid4().hex
    meta = {
        "assetType": "Image",
        "displayName": name,
        "description": "Dungeon crawler avatar texture",
        "creationContext": {"creator": creator},
    }
    with open(path, "rb") as f:
        data = f.read()
    body = (
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"request\"\r\n\r\n{json.dumps(meta)}\r\n"
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"fileContent\"; filename=\"{name}.png\"\r\n"
        f"Content-Type: image/png\r\n\r\n"
    ).encode() + data + f"\r\n--{boundary}--\r\n".encode()
    op = request("POST", f"{API}/assets", key, body, f"multipart/form-data; boundary={boundary}")

    # Uploads are asynchronous: poll the operation until it has an asset id.
    for _ in range(60):
        if op.get("done") and "response" in op:
            return int(op["response"]["assetId"])
        time.sleep(1.5)
        op = request("GET", f"{API}/{op['path']}", key)
    raise SystemExit(f"{name}: upload never finished ({op})")


def main():
    args = sys.argv[1:]
    creator = None
    force = []
    i = 0
    while i < len(args):
        if args[i] == "--user-id":
            creator = {"userId": args[i + 1]}
            i += 2
        elif args[i] == "--group-id":
            creator = {"groupId": args[i + 1]}
            i += 2
        elif args[i] == "--force":
            force = args[i + 1 :]
            break
        else:
            raise SystemExit(f"unknown argument {args[i]}")
    if not creator:
        raise SystemExit("pass --user-id <id> or --group-id <id>")
    key = os.environ.get("ROBLOX_API_KEY")
    if not key:
        raise SystemExit("set ROBLOX_API_KEY to an Open Cloud API key with Assets read/write")

    source = open(REGISTRY, encoding="utf-8").read()
    ids = dict((m.group(1), int(m.group(2))) for m in re.finditer(r"^\t(\w+) = (\d+),", source, re.M))

    for name, current in ids.items():
        if current and name not in force:
            continue
        path = os.path.join(TEXTURES, f"{name}.png")
        if not os.path.exists(path):
            print(f"skip {name}: no {path}")
            continue
        asset = upload(path, name, creator, key)
        source = re.sub(rf"^(\t{name} = )\d+,", rf"\g<1>{asset},", source, flags=re.M)
        # Written after every upload, so an interrupted run keeps what it did.
        open(REGISTRY, "w", encoding="utf-8").write(source)
        print(f"{name} -> {asset}")

    print("done")


if __name__ == "__main__":
    main()
