# Reads ours.zip (from zipharness) with every reader the scan zip meets and compares each file with
# the source folder: Python zipfile (texbake, openings), bsdtar (cut-worker's `tar -xf`), unzip,
# ditto, fflate (MeshCut; skipped when node / fflate are missing), plus a front-to-back walk of the
# local headers (streaming readers). Same entry names as old.zip (NSFileCoordinator's zip).
#   python3 tools/zip-harness/check.py <work dir> [<fflate dir with node_modules>]
import hashlib, json, os, shutil, struct, subprocess, sys, tempfile, zipfile

root = sys.argv[1]
top = "CedarScan-3D-TEST01"
ours, old = os.path.join(root, "ours.zip"), os.path.join(root, "old.zip")


def tree(folder):
    out = {}
    for dp, _, fn in os.walk(folder):
        for f in fn:
            p = os.path.join(dp, f)
            rel = os.path.relpath(p, os.path.dirname(folder)).replace(os.sep, "/")
            with open(p, "rb") as h:
                out[rel] = hashlib.sha256(h.read()).hexdigest()
    return out


want = tree(os.path.join(root, top))
assert len(want) > 100, len(want)

z = zipfile.ZipFile(ours)
assert z.testzip() is None, "CRC"
infos = z.infolist()
names = [i.filename for i in infos]
assert len(names) == len(set(names)), "duplicate names"
assert set(names) == set(want), set(names) ^ set(want)
for i in infos:
    assert i.compress_type == zipfile.ZIP_DEFLATED, i.filename
    assert i.flag_bits & 0x08 == 0, i.filename
    assert hashlib.sha256(z.read(i)).hexdigest() == want[i.filename], i.filename
old_names = set(zipfile.ZipFile(old).namelist())
assert old_names == set(names), old_names ^ set(names)
print("zipfile OK:", len(names), "entries, same names as old.zip")

# Local headers front to back: sizes and CRC in place, each header where the central directory says.
data = open(ours, "rb").read()
offsets, pos = {}, 0
while data[pos:pos + 4] == b"PK\x03\x04":
    _, flags, method, _, _, crc, csize, usize, nlen, xlen = struct.unpack("<HHHHHIIIHH", data[pos + 4:pos + 30])
    name = data[pos + 30:pos + 30 + nlen].decode("utf-8")
    info = z.getinfo(name)
    assert (crc, csize, usize, method) == (info.CRC, info.compress_size, info.file_size, 8), name
    offsets[name] = pos
    pos += 30 + nlen + xlen + csize
assert data[pos:pos + 4] == b"PK\x01\x02", "central directory right after the last entry"
assert offsets == {i.filename: i.header_offset for i in infos}
print("local headers OK")

for tool, cmd in (("bsdtar", ["bsdtar", "-xf", ours, "-C"]), ("ditto", ["ditto", "-x", "-k", ours])):
    d = tempfile.mkdtemp()
    subprocess.run(cmd + [d], check=True)
    assert tree(os.path.join(d, top)) == want, tool
    shutil.rmtree(d)
    print(tool, "OK")
subprocess.run(["unzip", "-tq", ours], check=True)
print("unzip -t OK")

if len(sys.argv) > 2:
    js = ("const fs=require('fs'),c=require('crypto'),{unzipSync}=require('fflate');"
          "const f=unzipSync(new Uint8Array(fs.readFileSync(process.argv[1])));const o={};"
          "for(const k in f){if(!k.endsWith('/'))o[k]=c.createHash('sha256').update(f[k]).digest('hex')}"
          "console.log(JSON.stringify(o))")
    got = subprocess.run(["node", "-e", js, ours], check=True, capture_output=True, text=True,
                         env=dict(os.environ, NODE_PATH=os.path.join(sys.argv[2], "node_modules"))).stdout
    assert json.loads(got) == want, "fflate"
    print("fflate OK")
print("ALL READERS OK")
