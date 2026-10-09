#!/usr/bin/env python3
"""Prepare the pinned dependencies/datasets for site-bench.py, outside the repo.

Run with the pinned Haxe compiler and its matching haxelib on PATH. System
dependencies: gcc/g++, make, git, Python 3, Node, Java, Neko, libpng-dev,
libturbojpeg0-dev, libvorbis-dev, zlib1g-dev. The submodule must be initialized.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def run(args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("directory", type=Path, help="external directory for sources and data")
    o = p.parse_args()
    dest = o.directory.resolve()
    dest.mkdir(parents=True, exist_ok=True)
    lock = json.loads((ROOT / "bench/site-bench-lock.json").read_text())
    head = subprocess.check_output(["git", "-C", str(ROOT / "haxe"), "rev-parse", "HEAD"], text=True).strip()
    if head != lock["haxe_commit"]:
        raise SystemExit("haxe/ does not match the locked reference commit")
    run(["haxelib", "setup", dest / "haxelib"])
    for name, entry in lock["repos"].items():
        repo = dest / name
        if not repo.exists():
            run(["git", "clone", "--no-checkout", entry["url"], repo])
        run(["git", "-C", repo, "checkout", "--detach", entry["commit"]])
        if name not in ("benchmark-runner", "hashlink", "api-data", "dox", "openfl", "lime"):
            run(["haxelib", "dev", name, repo])
    for name, entry in lock["haxelib_archives"].items():
        archive = dest / (name + ".zip")
        if not archive.exists():
            urllib.request.urlretrieve(entry["url"], archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != entry["sha256"]:
            raise SystemExit("Checksum mismatch: " + str(archive))
        lib = dest / name / "release"
        lib.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(archive) as z:
            z.extractall(lib)
        run(["haxelib", "dev", name, lib])
    # hxtemplo explicitly requests hxparse's git version; dev registration
    # alone does not satisfy that version-qualified dependency in haxelib.
    run(["haxelib", "git", "hxparse", (dest / "hxparse").as_uri(), lock["repos"]["hxparse"]["commit"]])
    run(["haxelib", "dev", "hashlink", dest / "hashlink/other/haxelib"])
    run(["make", "-j4", "hl", "libhl.so", "fmt.hdll"], cwd=dest / "hashlink")
    for tool in ("run", "hxcpp"):
        run(["haxe", "compile.hxml"], cwd=dest / "hxcpp/tools" / tool)
    cases = dest / "benchmark-runner/cases"
    (cases / "json/data").mkdir(exist_ok=True)
    shutil.copy2(dest / "formatter/resources/hxformat-schema.json", cases / "json/data/hxformat-schema.json")
    for source, target in [(dest / "formatter/src", cases / "formatter_noio/data"),
                           (dest / "api-data/xml/4.1.0", cases / "dox/data")]:
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(source, target)
    (cases / "formatter/data").mkdir(exist_ok=True)
    for name, source in [("haxe", ROOT / "haxe"), ("openfl", dest / "openfl"), ("lime", dest / "lime")]:
        target = cases / "formatter/data" / name
        if target.exists():
            shutil.rmtree(target)
        # Keep git metadata so each timed formatter run starts from pristine sources.
        # A submodule .git is a relative pointer, so give this copy its own repository.
        shutil.copytree(source, target, ignore=shutil.ignore_patterns(".git", "_build"))
        run(["git", "init", target])
        run(["git", "-C", target, "add", "."])
        run(["git", "-C", target, "-c", "user.name=Benchmark", "-c", "user.email=benchmark@localhost", "commit", "-m", "Dataset snapshot"])
    print("Ready. Build backend/wbk.js with backend/build.sh or the documented command, then run site-bench.py.")

if __name__ == "__main__":
    main()
