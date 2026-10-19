"""Fail-closed, local-only staging and bundle checks for the pinned Orukeet SDK."""
import hashlib
import json
import os
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
MODEL_NAME = "orukeet-v0.1.0-q8.gguf"
MODEL_SHA256 = "93ce19c6d8244acbfea980eeaf970531d4f216171578ef8e041dcc2d070a45bd"
MODEL_BYTES = 714456704
HEADER_SHA256 = "61057814efd3da0a25282e1f4b83719e938f5debe9ec29d442e1cf90cdd7d50e"
SDK_BUILD_SHA256 = "4559c9dcd3ccf5cf21c214dfb10ddc2d65340428c7729e1dd25ecd789063a60f"
SDK = json.loads((HERE / "sdk-build.json").read_text())
LIBRARIES = SDK["libraries"]


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_hash(path, expected):
    if not Path(path).is_file() or sha256(path) != expected:
        raise RuntimeError(f"Orukeet asset missing or checksum mismatch: {path}")


def license_hashes():
    return {"licenses/" + str(p.relative_to(HERE / "licenses")): sha256(p)
            for p in sorted((HERE / "licenses").rglob("*")) if p.is_file()}


def checked_sdk(sdk, model):
    sdk, model = Path(sdk).resolve(strict=True), Path(model).resolve(strict=True)
    require_hash(sdk / "share/orukeet/build.json", SDK_BUILD_SHA256)
    require_hash(sdk / "include/nemo_speech/asr.h", HEADER_SHA256)
    for name, digest in LIBRARIES.items():
        path = sdk / "lib" / name
        if not path.resolve(strict=True).is_relative_to(sdk / "lib"):
            raise RuntimeError("Orukeet SDK library escapes its lib directory")
        require_hash(path, digest)
    if model.stat().st_size != MODEL_BYTES:
        raise RuntimeError("Orukeet Q8 model has the wrong byte length")
    require_hash(model, MODEL_SHA256)
    return sdk, model


def file_hashes(root):
    root = Path(root)
    result = {}
    for p in sorted(root.rglob("*")):
        if p.is_symlink():
            raise RuntimeError(f"Orukeet asset symlink is not permitted: {p}")
        if p.is_dir():
            continue
        if not p.is_file():
            raise RuntimeError(f"Orukeet asset is not a regular file: {p}")
        relative = p.relative_to(root).as_posix()
        if relative != "asset-manifest.json":
            result[relative] = sha256(p)
    return result


def write_manifest(root):
    manifest = {"schema_version": 1, "model_sha256": MODEL_SHA256,
                "model_bytes": MODEL_BYTES, "sdk_version": "0.1.1",
                "sdk_build_sha256": SDK_BUILD_SHA256,
                "worker_source_sha256": sha256(HERE / "orukeet_worker.cpp"),
                "native_punctuation": True, "files": file_hashes(root)}
    (Path(root) / "asset-manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


def validate_assets(root, *, unsigned=True, model_external=False):
    """model_external: a download-mode bundle ships everything except the weights (build 77)."""
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise RuntimeError("--orukeet-assets must be a real staged directory")
    path = root / "asset-manifest.json"
    if path.is_symlink() or not path.is_file():
        raise RuntimeError("Missing regular Orukeet asset-manifest.json")
    manifest = json.loads(path.read_text())
    if (manifest.get("schema_version") != 1 or manifest.get("model_sha256") != MODEL_SHA256
            or manifest.get("model_bytes") != MODEL_BYTES
            or manifest.get("sdk_build_sha256") != SDK_BUILD_SHA256
            or manifest.get("worker_source_sha256") != sha256(HERE / "orukeet_worker.cpp")
            or manifest.get("native_punctuation") is not True):
        raise RuntimeError("Orukeet manifest does not match the pinned model/SDK/worker source")
    expected = {"orukeet-worker", "sdk-build.json", *license_hashes(),
                *("lib/" + name for name in LIBRARIES)} | (set() if model_external else {MODEL_NAME})
    actual = file_hashes(root)
    if set(actual) != expected or manifest.get("files") != actual:
        raise RuntimeError("Orukeet asset inventory/checksums differ from the complete manifest")
    if not model_external and ((root / MODEL_NAME).stat().st_size != MODEL_BYTES or actual[MODEL_NAME] != MODEL_SHA256):
        raise RuntimeError("Orukeet Q8 model differs from the pinned bytes")
    if actual["sdk-build.json"] != SDK_BUILD_SHA256:
        raise RuntimeError("Orukeet SDK provenance differs from the pinned manifest")
    for name, digest in license_hashes().items():
        if actual[name] != digest:
            raise RuntimeError("Orukeet license missing or altered: " + name)
    if unsigned:
        for name, digest in LIBRARIES.items():
            if actual["lib/" + name] != digest:
                raise RuntimeError("Orukeet SDK library differs from official input: " + name)
    if not os.access(root / "orukeet-worker", os.X_OK):
        raise RuntimeError("Orukeet worker is not executable")
    return manifest


def inspect_native(root, run):
    """Inspect every Mach-O without executing it; return dependency-first signing order."""
    root = Path(root)
    targets = {"lib/" + name: root / "lib" / name for name in LIBRARIES}
    targets["orukeet-worker"] = root / "orukeet-worker"
    dependencies = {}
    for name, target in targets.items():
        if run("lipo", "-archs", str(target)).strip() != "arm64":
            raise RuntimeError("Orukeet native component is not arm64: " + name)
        load = run("otool", "-l", str(target))
        rpaths = re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (\S+)", load)
        allowed_rpaths = ({"@executable_path/lib"} if name == "orukeet-worker"
                          else {"@loader_path", "@loader_path/../lib"})
        if not rpaths or not set(rpaths).issubset(allowed_rpaths):
            raise RuntimeError("Orukeet component has unsafe/missing relative rpath: " + name)
        minimum = re.findall(r"\bminos (\d+(?:\.\d+)*)", load)
        if len(minimum) != 1 or tuple(map(int, minimum[0].split("."))) > (14, 0, 0):
            raise RuntimeError("Orukeet component exceeds the app's macOS 14 minimum: " + name)
        linked = [line.strip().split(" (", 1)[0]
                  for line in run("otool", "-L", str(target)).splitlines()[1:]]
        deps = set()
        for link in linked:
            if link.startswith(("/usr/lib/", "/System/Library/")):
                continue
            if not link.startswith("@rpath/") or link.removeprefix("@rpath/") not in LIBRARIES:
                raise RuntimeError("Orukeet component has unreviewed linkage: " + link)
            dep = "lib/" + link.removeprefix("@rpath/")
            # dylib's first otool -L item is its own install name, including aliases.
            if name.startswith("lib/") and LIBRARIES[name[4:]] == LIBRARIES[dep[4:]]:
                continue
            deps.add(dep)
        dependencies[name] = deps
    ordered, active = [], set()
    def visit(name):
        if name in active:
            raise RuntimeError("Orukeet native dependency cycle")
        if name in ordered:
            return
        active.add(name)
        for dep in sorted(dependencies[name]):
            visit(dep)
        active.remove(name)
        ordered.append(name)
    for name in sorted(targets):
        visit(name)
    return [targets[name] for name in ordered]
