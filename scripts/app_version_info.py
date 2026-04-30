#!/usr/bin/env python3
from __future__ import annotations

import argparse
import getpass
import http.client
import io
import json
import mimetypes
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from collections import Counter
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any
from xml.etree import ElementTree as ET

try:
    import tomllib
except ModuleNotFoundError:
    tomllib = None


SKIP_DIRS = {
    ".git",
    ".gradle",
    ".idea",
    ".swiftpm",
    ".vscode",
    "Carthage",
    "DerivedData",
    "Pods",
    "build",
    "node_modules",
    "target",
}

DEFAULT_ZEALOT_URL = "https://zealot.tongshike.cn/"

UPLOAD_EXTENSIONS = {
    ".aab",
    ".apk",
    ".appx",
    ".deb",
    ".dmg",
    ".exe",
    ".hap",
    ".hsp",
    ".ipa",
    ".msi",
    ".msix",
    ".pkg",
    ".rpm",
    ".zip",
}

UPLOAD_SKIP_DIRS = {
    ".git",
    ".gradle",
    ".idea",
    ".swiftpm",
    ".vscode",
    "node_modules",
    "Pods",
}


@dataclass
class VersionInfo:
    path: str
    kind: str
    platform: str | None = None
    release_version: str | None = None
    build_version: str | None = None
    name: str | None = None
    bundle_id: str | None = None
    source: str | None = None
    warnings: list[str] = field(default_factory=list)
    extra: dict[str, Any] = field(default_factory=dict)

    def complete(self) -> "VersionInfo":
        self.release_version = clean_value(self.release_version)
        self.build_version = clean_value(self.build_version)
        if not self.release_version and self.build_version:
            self.release_version = release_from_build(self.build_version)
        if not self.build_version and self.release_version:
            self.build_version = self.release_version
        return self

    def as_json(self) -> dict[str, Any]:
        return asdict(self)


def clean_value(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, bool):
        return str(value).lower()
    value = str(value).strip().strip('"').strip("'").strip()
    value = value.strip("\x00").strip()
    return value or None


def first_present(*values: Any) -> str | None:
    for value in values:
        cleaned = clean_value(value)
        if cleaned:
            return cleaned
    return None


def version_like(value: str | None) -> str | None:
    value = clean_value(value)
    if not value:
        return None
    match = re.search(r"\d+(?:[._-]\d+)+(?:[-+][0-9A-Za-z._-]+)?|\d+", value)
    return match.group(0).replace("_", ".") if match else value


def release_from_build(value: str | None) -> str | None:
    value = clean_value(value)
    if not value:
        return None
    parts = re.split(r"[._-]", value)
    if len(parts) >= 4 and all(part.isdigit() for part in parts[:4]):
        return ".".join(parts[:3])
    return value


def best_value(values: list[str]) -> str | None:
    cleaned = [clean_value(value) for value in values]
    cleaned = [value for value in cleaned if value and value != "$(inherited)"]
    if not cleaned:
        return None
    counts = Counter(cleaned)
    return counts.most_common(1)[0][0]


def run_command(args: list[str], timeout: int = 30) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
            check=False,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 127, "", str(exc)


def git_metadata(path: Path) -> dict[str, str]:
    base = path if path.is_dir() else path.parent
    code, root, _ = run_command(["git", "-C", str(base), "rev-parse", "--show-toplevel"])
    if code != 0:
        return {}
    repo = root.strip()
    metadata: dict[str, str] = {}
    commands = {
        "branch": ["git", "-C", repo, "branch", "--show-current"],
        "git_commit": ["git", "-C", repo, "rev-parse", "HEAD"],
    }
    for key, command in commands.items():
        code, stdout, _ = run_command(command)
        if code == 0 and stdout.strip():
            metadata[key] = stdout.strip()
    return metadata


def walk_files(root: Path, max_depth: int = 8) -> list[Path]:
    root = root.resolve()
    files: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root):
        current = Path(dirpath)
        rel_parts = current.relative_to(root).parts
        if len(rel_parts) >= max_depth:
            dirnames[:] = []
        dirnames[:] = [name for name in dirnames if name not in SKIP_DIRS]
        for filename in filenames:
            files.append(current / filename)
    return files


def find_latest_upload_artifact(root: Path) -> Path | None:
    if root.is_file():
        return root
    candidates: list[Path] = []
    root = root.resolve()
    for dirpath, dirnames, filenames in os.walk(root):
        current = Path(dirpath)
        rel_parts = current.relative_to(root).parts
        if len(rel_parts) >= 10:
            dirnames[:] = []
        dirnames[:] = [name for name in dirnames if name not in UPLOAD_SKIP_DIRS]
        for filename in filenames:
            path = current / filename
            if path.suffix.lower() in UPLOAD_EXTENSIONS:
                candidates.append(path)
    if not candidates:
        return None
    candidates.sort(key=lambda path: path.stat().st_mtime, reverse=True)
    return candidates[0]


def merge_version_info(primary: VersionInfo, fallback: VersionInfo) -> VersionInfo:
    primary.release_version = first_present(primary.release_version, fallback.release_version)
    primary.build_version = first_present(primary.build_version, fallback.build_version)
    primary.name = first_present(primary.name, fallback.name)
    primary.bundle_id = first_present(primary.bundle_id, fallback.bundle_id)
    primary.platform = first_present(primary.platform, fallback.platform)
    if primary.path != fallback.path:
        primary.extra["project_info"] = fallback.as_json()
    return primary.complete()


def parse_path(path: Path) -> VersionInfo:
    path = path.expanduser()
    if not path.exists():
        raise FileNotFoundError(path)
    if path.is_dir():
        suffix = path.suffix.lower()
        if suffix == ".app":
            return parse_app_dir(path).complete()
        if suffix == ".xcarchive":
            return parse_xcarchive(path).complete()
        return parse_project_dir(path).complete()
    return parse_file(path).complete()


def parse_file(path: Path) -> VersionInfo:
    suffix = path.suffix.lower()
    if suffix == ".ipa":
        return parse_ipa(path)
    if suffix == ".apk":
        return parse_apk(path)
    if suffix == ".aab":
        return parse_aab(path)
    if suffix in {".hap", ".hsp"}:
        info = parse_generic_zip(path)
        info.kind = suffix.lstrip(".")
        return info
    if suffix in {".appx", ".msix"}:
        return parse_appx_package(path)
    if suffix == ".appxmanifest" or path.name.lower() == "appxmanifest.xml":
        return parse_appx_manifest_file(path)
    if suffix == ".exe":
        return parse_pe_file(path)
    if suffix == ".msi":
        return parse_msi(path)
    if suffix == ".deb":
        return parse_deb(path)
    if suffix == ".rpm":
        return parse_rpm(path)
    if suffix == ".pkg":
        return parse_pkg(path)
    if suffix == ".dmg":
        return parse_dmg(path)
    if suffix == ".zip":
        return parse_generic_zip(path)
    if suffix in {".csproj", ".vbproj", ".fsproj", ".vcxproj", ".wapproj"}:
        return parse_windows_project_file(path)
    if suffix == ".sln":
        return parse_solution(path)
    if suffix == ".plist":
        return info_from_plist_file(path, "plist", "plist_file")
    if suffix in {".json", ".json5", ".toml"} and path.name.startswith("tauri.conf"):
        return parse_tauri_project(path.parent)
    return parse_from_filename(path, "unknown_file", "unknown")


def parse_project_dir(root: Path) -> VersionInfo:
    if is_tauri_project(root):
        return parse_tauri_project(root)
    if is_android_project(root):
        return parse_android_project(root)
    if is_ios_project(root):
        return parse_ios_project(root)
    if is_windows_project(root):
        return parse_windows_project_dir(root)

    for parser in (parse_tauri_project, parse_android_project, parse_ios_project, parse_windows_project_dir):
        info = parser(root)
        if info.release_version or info.build_version:
            return info

    return parse_from_filename(root, "project_dir", "unknown")


def is_tauri_project(root: Path) -> bool:
    return (root / "src-tauri").exists() or any(
        (root / name).exists()
        for name in ("tauri.conf.json", "tauri.conf.json5", "tauri.conf.toml")
    )


def is_android_project(root: Path) -> bool:
    return any(
        (root / name).exists()
        for name in (
            "settings.gradle",
            "settings.gradle.kts",
            "build.gradle",
            "build.gradle.kts",
            "app/build.gradle",
            "app/build.gradle.kts",
        )
    )


def is_ios_project(root: Path) -> bool:
    return any(root.glob("*.xcodeproj")) or any(root.glob("*.xcworkspace"))


def is_windows_project(root: Path) -> bool:
    return bool(
        list(root.glob("*.sln"))
        or list(root.glob("*.csproj"))
        or list(root.glob("*.vcxproj"))
        or list(root.glob("*.wapproj"))
    )


def read_plist_bytes(data: bytes) -> dict[str, Any]:
    return plistlib.loads(data)


def read_plist_file(path: Path) -> dict[str, Any]:
    with path.open("rb") as handle:
        return plistlib.load(handle)


def info_from_plist_data(
    data: bytes,
    path: Path,
    kind: str,
    platform: str,
    source: str,
    variables: dict[str, str] | None = None,
) -> VersionInfo:
    plist = read_plist_bytes(data)
    return info_from_plist(plist, path, kind, platform, source, variables)


def info_from_plist_file(
    path: Path,
    platform: str,
    kind: str,
    variables: dict[str, str] | None = None,
) -> VersionInfo:
    plist = read_plist_file(path)
    return info_from_plist(plist, path, kind, platform, str(path), variables)


def info_from_plist(
    plist: dict[str, Any],
    path: Path,
    kind: str,
    platform: str,
    source: str,
    variables: dict[str, str] | None = None,
) -> VersionInfo:
    variables = variables or {}
    release = resolve_build_setting(
        first_present(plist.get("CFBundleShortVersionString"), plist.get("CFBundleVersion")),
        variables,
    )
    build = resolve_build_setting(
        first_present(plist.get("CFBundleVersion"), plist.get("CFBundleShortVersionString")),
        variables,
    )
    name = resolve_build_setting(
        first_present(
            plist.get("CFBundleDisplayName"),
            plist.get("CFBundleName"),
            plist.get("CFBundleExecutable"),
        ),
        variables,
    )
    bundle_id = resolve_build_setting(first_present(plist.get("CFBundleIdentifier")), variables)
    return VersionInfo(
        path=str(path),
        kind=kind,
        platform=platform,
        release_version=release,
        build_version=build,
        name=name,
        bundle_id=bundle_id,
        source=source,
    )


def resolve_build_setting(value: str | None, variables: dict[str, str]) -> str | None:
    value = clean_value(value)
    if not value:
        return None

    def replace(match: re.Match[str]) -> str:
        key = match.group(1) or match.group(2)
        return variables.get(key, match.group(0))

    previous = None
    while previous != value:
        previous = value
        value = re.sub(r"\$\(([^)]+)\)|\$\{([^}]+)\}", replace, value)
    return clean_value(value)


def parse_ipa(path: Path) -> VersionInfo:
    try:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            candidates = [
                name
                for name in names
                if re.match(r"Payload/[^/]+\.app/Info\.plist$", name)
            ]
            if not candidates:
                candidates = [
                    name for name in names if name.endswith(".app/Info.plist")
                ]
            if not candidates:
                return VersionInfo(
                    path=str(path),
                    kind="ipa",
                    platform="ios",
                    source=str(path),
                    warnings=["Info.plist not found in ipa"],
                )
            source = sorted(candidates, key=len)[0]
            return info_from_plist_data(
                archive.read(source),
                path,
                "ipa",
                "ios",
                source,
            )
    except Exception as exc:
        return VersionInfo(
            path=str(path),
            kind="ipa",
            platform="ios",
            source=str(path),
            warnings=[f"failed to parse ipa: {exc}"],
        )


def parse_app_dir(path: Path) -> VersionInfo:
    info_plist = path / "Contents" / "Info.plist"
    platform = "macos"
    if not info_plist.exists():
        info_plist = path / "Info.plist"
        platform = "ios"
    if not info_plist.exists():
        return VersionInfo(
            path=str(path),
            kind="app_dir",
            platform=platform,
            source=str(path),
            warnings=["Info.plist not found"],
        )
    return info_from_plist_file(info_plist, platform, "app_dir")


def parse_xcarchive(path: Path) -> VersionInfo:
    candidates = list((path / "Products" / "Applications").glob("*.app/Info.plist"))
    if not candidates:
        candidates = list(path.glob("**/*.app/Info.plist"))
    if not candidates:
        return VersionInfo(
            path=str(path),
            kind="xcarchive",
            platform="ios",
            source=str(path),
            warnings=["Info.plist not found in xcarchive"],
        )
    return info_from_plist_file(candidates[0], "ios", "xcarchive")


def parse_generic_zip(path: Path) -> VersionInfo:
    try:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            appx = next((name for name in names if name.endswith("AppxManifest.xml")), None)
            if appx:
                return parse_appx_manifest_bytes(path, archive.read(appx), "zip", appx)

            ipa_info = [
                name
                for name in names
                if re.match(r"Payload/[^/]+\.app/Info\.plist$", name)
            ]
            if ipa_info:
                return info_from_plist_data(archive.read(ipa_info[0]), path, "zip", "ios", ipa_info[0])

            mac_info = next((name for name in names if name.endswith(".app/Contents/Info.plist")), None)
            if mac_info:
                return info_from_plist_data(archive.read(mac_info), path, "zip", "macos", mac_info)

            manifest = next((name for name in names if name.endswith("AndroidManifest.xml")), None)
            if manifest:
                return parse_android_manifest_bytes(path, archive.read(manifest), "zip", manifest)

            harmony = next(
                (
                    name
                    for name in names
                    if name.endswith("module.json") or name.endswith("config.json") or name.endswith("app.json")
                ),
                None,
            )
            if harmony:
                return parse_harmony_json(path, archive.read(harmony), "zip", harmony)
    except Exception as exc:
        return VersionInfo(path=str(path), kind="zip", source=str(path), warnings=[f"failed to parse zip: {exc}"])
    return parse_from_filename(path, "zip", "unknown")


def parse_appx_package(path: Path) -> VersionInfo:
    try:
        with zipfile.ZipFile(path) as archive:
            manifest = next((name for name in archive.namelist() if name.endswith("AppxManifest.xml")), None)
            if not manifest:
                return VersionInfo(
                    path=str(path),
                    kind="appx",
                    platform="windows",
                    source=str(path),
                    warnings=["AppxManifest.xml not found"],
                )
            return parse_appx_manifest_bytes(path, archive.read(manifest), "appx", manifest)
    except Exception as exc:
        return VersionInfo(
            path=str(path),
            kind="appx",
            platform="windows",
            source=str(path),
            warnings=[f"failed to parse appx/msix: {exc}"],
        )


def parse_appx_manifest_file(path: Path) -> VersionInfo:
    return parse_appx_manifest_bytes(path, path.read_bytes(), "appx_manifest", str(path))


def parse_appx_manifest_bytes(path: Path, data: bytes, kind: str, source: str) -> VersionInfo:
    root = ET.fromstring(data)
    identity = find_xml_child(root, "Identity")
    props = find_xml_child(root, "Properties")
    version = xml_attr(identity, "Version") if identity is not None else None
    name = None
    if props is not None:
        display = find_xml_child(props, "DisplayName")
        name = display.text if display is not None else None
    bundle_id = xml_attr(identity, "Name") if identity is not None else None
    return VersionInfo(
        path=str(path),
        kind=kind,
        platform="windows",
        release_version=release_from_build(version),
        build_version=version,
        name=name,
        bundle_id=bundle_id,
        source=source,
    )


def parse_android_project(root: Path) -> VersionInfo:
    files = walk_files(root, max_depth=6)
    gradle_files = [
        path
        for path in files
        if path.name in {"build.gradle", "build.gradle.kts"} and "test" not in path.parts
    ]
    gradle_files.sort(key=lambda path: (0 if path.parent.name == "app" else 1, len(path.parts)))

    props = read_gradle_properties(root)
    texts: list[tuple[Path, str]] = []
    for file in gradle_files:
        try:
            texts.append((file, file.read_text(encoding="utf-8", errors="ignore")))
        except OSError:
            pass
    variables = collect_gradle_variables(texts, props)

    for file, text in texts:
        release = find_gradle_value(text, "versionName", variables)
        build = find_gradle_value(text, "versionCode", variables)
        app_id = find_gradle_value(text, "applicationId", variables)
        namespace = find_gradle_value(text, "namespace", variables)
        if release or build:
            return VersionInfo(
                path=str(root),
                kind="android_project",
                platform="android",
                release_version=release,
                build_version=build,
                bundle_id=first_present(app_id, namespace),
                source=str(file),
            )

    manifest = next((path for path in files if path.name == "AndroidManifest.xml"), None)
    if manifest:
        try:
            return parse_android_manifest_bytes(root, manifest.read_bytes(), "android_project", str(manifest))
        except Exception:
            pass

    return parse_from_filename(root, "android_project", "android")


def read_gradle_properties(root: Path) -> dict[str, str]:
    props: dict[str, str] = {}
    for path in walk_files(root, max_depth=4):
        if path.name != "gradle.properties":
            continue
        try:
            for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                props[key.strip()] = value.strip()
        except OSError:
            pass
    return props


def collect_gradle_variables(texts: list[tuple[Path, str]], props: dict[str, str]) -> dict[str, str]:
    variables = dict(props)
    assignment_patterns = [
        r"(?:def|val|var)?\s*([A-Za-z_][\w.]*)\s*=\s*[\"']([^\"']+)[\"']",
        r"(?:def|val|var)?\s*([A-Za-z_][\w.]*)\s*=\s*([0-9]+)",
        r"ext\.([A-Za-z_][\w.]*)\s*=\s*[\"']([^\"']+)[\"']",
        r"ext\.([A-Za-z_][\w.]*)\s*=\s*([0-9]+)",
        r"set\([\"']([^\"']+)[\"']\s*,\s*[\"']([^\"']+)[\"']\)",
        r"set\([\"']([^\"']+)[\"']\s*,\s*([0-9]+)\)",
    ]
    for _, text in texts:
        for pattern in assignment_patterns:
            for key, value in re.findall(pattern, text):
                variables[key] = value
    return variables


def find_gradle_value(text: str, key: str, variables: dict[str, str]) -> str | None:
    patterns = [
        rf"\b{re.escape(key)}\s*\(\s*[\"']([^\"']+)[\"']\s*\)",
        rf"\b{re.escape(key)}\s+[\"']([^\"']+)[\"']",
        rf"\b{re.escape(key)}\s*=\s*[\"']([^\"']+)[\"']",
        rf"\b{re.escape(key)}\s+([A-Za-z_][\w.]*(?:\([^)]*\))?(?:\.\w+\(\))*)",
        rf"\b{re.escape(key)}\s*=\s*([A-Za-z_][\w.]*(?:\([^)]*\))?(?:\.\w+\(\))*)",
        rf"\b{re.escape(key)}\s+([0-9]+)",
        rf"\b{re.escape(key)}\s*=\s*([0-9]+)",
    ]
    for pattern in patterns:
        match = re.search(pattern, text)
        if match:
            return resolve_gradle_value(match.group(1), variables)
    return None


def resolve_gradle_value(value: str, variables: dict[str, str]) -> str | None:
    value = clean_value(value)
    if not value:
        return None
    value = re.sub(r"\s+as\s+\w+", "", value).strip()
    value = re.sub(r"\.to(Int|Integer|String)\(\)$", "", value)
    value = re.sub(r"\.get\(\)$", "", value)

    property_match = re.search(r"(?:findProperty|property|gradleProperty)\([\"']([^\"']+)[\"']\)", value)
    if property_match:
        return variables.get(property_match.group(1))

    def replace_var(match: re.Match[str]) -> str:
        key = match.group(1)
        return variables.get(key, match.group(0))

    value = re.sub(r"\$\{([A-Za-z_][\w.]*)\}", replace_var, value)
    simplified = value
    for prefix in ("project.", "rootProject.ext.", "rootProject.", "ext."):
        if simplified.startswith(prefix):
            simplified = simplified[len(prefix) :]
    return clean_value(variables.get(simplified, value))


def parse_apk(path: Path) -> VersionInfo:
    external = parse_apk_with_aapt(path)
    if external.release_version or external.build_version:
        return external
    try:
        with zipfile.ZipFile(path) as archive:
            data = archive.read("AndroidManifest.xml")
        parsed = parse_android_manifest_bytes(path, data, "apk", "AndroidManifest.xml")
        parsed.warnings.extend(external.warnings)
        return parsed
    except Exception as exc:
        return VersionInfo(
            path=str(path),
            kind="apk",
            platform="android",
            source=str(path),
            warnings=external.warnings + [f"failed to parse apk manifest: {exc}"],
        )


def parse_apk_with_aapt(path: Path) -> VersionInfo:
    warnings: list[str] = []
    for tool in ("aapt", "aapt2"):
        command = shutil.which(tool)
        if not command:
            continue
        code, stdout, stderr = run_command([command, "dump", "badging", str(path)])
        if code != 0:
            warnings.append(f"{tool} failed: {stderr.strip()}")
            continue
        first = next((line for line in stdout.splitlines() if line.startswith("package:")), "")
        if not first:
            continue
        return VersionInfo(
            path=str(path),
            kind="apk",
            platform="android",
            release_version=regex_attr(first, "versionName"),
            build_version=regex_attr(first, "versionCode"),
            bundle_id=regex_attr(first, "name"),
            source=tool,
        )
    return VersionInfo(path=str(path), kind="apk", platform="android", source=str(path), warnings=warnings)


def regex_attr(text: str, name: str) -> str | None:
    match = re.search(rf"{re.escape(name)}='([^']*)'", text)
    if not match:
        match = re.search(rf'{re.escape(name)}="([^"]*)"', text)
    return match.group(1) if match else None


def parse_aab(path: Path) -> VersionInfo:
    external = parse_aab_with_bundletool(path)
    if external.release_version or external.build_version:
        return external
    try:
        with zipfile.ZipFile(path) as archive:
            manifest = next(
                (
                    name
                    for name in archive.namelist()
                    if name.endswith("manifest/AndroidManifest.xml")
                ),
                None,
            )
            if manifest:
                parsed = parse_android_manifest_bytes(path, archive.read(manifest), "aab", manifest)
                parsed.warnings.extend(external.warnings)
                return parsed
    except Exception as exc:
        external.warnings.append(f"failed to inspect aab zip: {exc}")
    external.warnings.append("aab protobuf manifest needs bundletool when it is not plain XML/AXML")
    return external


def parse_aab_with_bundletool(path: Path) -> VersionInfo:
    tool = os.environ.get("BUNDLETOOL") or shutil.which("bundletool")
    if not tool:
        return VersionInfo(path=str(path), kind="aab", platform="android", source=str(path))
    base_args = ["java", "-jar", tool] if tool.endswith(".jar") else [tool]
    code, stdout, stderr = run_command(base_args + ["dump", "manifest", f"--bundle={path}", "--module=base"])
    if code != 0:
        return VersionInfo(
            path=str(path),
            kind="aab",
            platform="android",
            source="bundletool",
            warnings=[f"bundletool failed: {stderr.strip()}"],
        )
    try:
        return parse_android_manifest_bytes(path, stdout.encode("utf-8"), "aab", "bundletool")
    except Exception as exc:
        return VersionInfo(
            path=str(path),
            kind="aab",
            platform="android",
            source="bundletool",
            warnings=[f"bundletool output parse failed: {exc}"],
        )


def parse_android_manifest_bytes(path: Path, data: bytes, kind: str, source: str) -> VersionInfo:
    data = data.lstrip()
    if data.startswith(b"<"):
        return parse_android_manifest_xml(path, data, kind, source)
    return parse_android_manifest_axml(path, data, kind, source)


def parse_android_manifest_xml(path: Path, data: bytes, kind: str, source: str) -> VersionInfo:
    root = ET.fromstring(data)
    android_ns = "{http://schemas.android.com/apk/res/android}"
    release = first_present(
        root.attrib.get(android_ns + "versionName"),
        root.attrib.get("android:versionName"),
        root.attrib.get("versionName"),
    )
    build = first_present(
        root.attrib.get(android_ns + "versionCode"),
        root.attrib.get("android:versionCode"),
        root.attrib.get("versionCode"),
    )
    package = root.attrib.get("package")
    return VersionInfo(
        path=str(path),
        kind=kind,
        platform="android",
        release_version=release,
        build_version=build,
        bundle_id=package,
        source=source,
    )


def parse_android_manifest_axml(path: Path, data: bytes, kind: str, source: str) -> VersionInfo:
    parser = AndroidBinaryXml(data)
    attrs = parser.manifest_attributes()
    warnings: list[str] = []
    release = attrs.get("versionName")
    build = attrs.get("versionCode")
    if release and release.startswith("@"):
        warnings.append("versionName is a resource reference; install aapt/aapt2 to resolve it")
    return VersionInfo(
        path=str(path),
        kind=kind,
        platform="android",
        release_version=release,
        build_version=build,
        bundle_id=attrs.get("package"),
        source=source,
        warnings=warnings,
    )


class AndroidStringPool:
    UTF8_FLAG = 0x00000100

    def __init__(self, data: bytes, offset: int):
        self.data = data
        self.offset = offset
        self.chunk_type, self.header_size, self.chunk_size = struct.unpack_from("<HHI", data, offset)
        (
            self.string_count,
            self.style_count,
            self.flags,
            self.strings_start,
            self.styles_start,
        ) = struct.unpack_from("<IIIII", data, offset + 8)
        self.offsets = [
            struct.unpack_from("<I", data, offset + self.header_size + index * 4)[0]
            for index in range(self.string_count)
        ]
        self.is_utf8 = bool(self.flags & self.UTF8_FLAG)

    def get(self, index: int) -> str | None:
        if index < 0 or index >= self.string_count:
            return None
        start = self.offset + self.strings_start + self.offsets[index]
        if self.is_utf8:
            _, pos = self._read_length8(start)
            byte_len, pos = self._read_length8(pos)
            raw = self.data[pos : pos + byte_len]
            return raw.decode("utf-8", errors="replace")
        char_len, pos = self._read_length16(start)
        raw = self.data[pos : pos + char_len * 2]
        return raw.decode("utf-16le", errors="replace")

    def _read_length8(self, pos: int) -> tuple[int, int]:
        first = self.data[pos]
        pos += 1
        if first & 0x80:
            second = self.data[pos]
            pos += 1
            return ((first & 0x7F) << 8) | second, pos
        return first, pos

    def _read_length16(self, pos: int) -> tuple[int, int]:
        first = struct.unpack_from("<H", self.data, pos)[0]
        pos += 2
        if first & 0x8000:
            second = struct.unpack_from("<H", self.data, pos)[0]
            pos += 2
            return ((first & 0x7FFF) << 16) | second, pos
        return first, pos


class AndroidBinaryXml:
    RES_STRING_POOL_TYPE = 0x0001
    RES_XML_TYPE = 0x0003
    RES_XML_RESOURCE_MAP_TYPE = 0x0180
    RES_XML_START_ELEMENT_TYPE = 0x0102
    TYPE_STRING = 0x03
    TYPE_ATTRIBUTE = 0x02
    TYPE_REFERENCE = 0x01
    TYPE_FLOAT = 0x04
    TYPE_INT_DEC = 0x10
    TYPE_INT_HEX = 0x11
    TYPE_INT_BOOLEAN = 0x12

    def __init__(self, data: bytes):
        self.data = data
        chunk_type, _, chunk_size = struct.unpack_from("<HHI", data, 0)
        if chunk_type != self.RES_XML_TYPE:
            raise ValueError("not an Android binary XML document")
        self.chunk_size = chunk_size
        self.string_pool: AndroidStringPool | None = None
        self.resource_map: list[int] = []
        self._load_header_chunks()

    def _load_header_chunks(self) -> None:
        offset = 8
        while offset < len(self.data):
            chunk_type, header_size, chunk_size = struct.unpack_from("<HHI", self.data, offset)
            if chunk_type == self.RES_STRING_POOL_TYPE:
                self.string_pool = AndroidStringPool(self.data, offset)
            elif chunk_type == self.RES_XML_RESOURCE_MAP_TYPE:
                count = (chunk_size - header_size) // 4
                self.resource_map = [
                    struct.unpack_from("<I", self.data, offset + header_size + index * 4)[0]
                    for index in range(count)
                ]
            elif chunk_type == self.RES_XML_START_ELEMENT_TYPE:
                return
            offset += chunk_size
        if self.string_pool is None:
            raise ValueError("string pool not found")

    def string(self, index: int) -> str | None:
        if self.string_pool is None:
            return None
        return self.string_pool.get(index)

    def manifest_attributes(self) -> dict[str, str]:
        offset = 8
        while offset < len(self.data):
            chunk_type, header_size, chunk_size = struct.unpack_from("<HHI", self.data, offset)
            if chunk_type != self.RES_XML_START_ELEMENT_TYPE:
                offset += chunk_size
                continue

            name_index = struct.unpack_from("<I", self.data, offset + 20)[0]
            tag_name = self.string(name_index)
            if tag_name != "manifest":
                offset += chunk_size
                continue

            attr_ext_offset = offset + 16
            attr_start, attr_size, attr_count = struct.unpack_from("<HHH", self.data, attr_ext_offset + 8)
            attr_offset = attr_ext_offset + attr_start
            attrs: dict[str, str] = {}
            for index in range(attr_count):
                current = attr_offset + index * attr_size
                _, attr_name_index, raw_value_index = struct.unpack_from("<III", self.data, current)
                value_type = self.data[current + 15]
                value_data = struct.unpack_from("<I", self.data, current + 16)[0]
                attr_name = self.string(attr_name_index)
                if not attr_name:
                    continue
                attrs[attr_name] = self._typed_value(raw_value_index, value_type, value_data)
            return attrs

        return {}

    def _typed_value(self, raw_value_index: int, value_type: int, value_data: int) -> str:
        if raw_value_index != 0xFFFFFFFF:
            raw = self.string(raw_value_index)
            if raw is not None:
                return raw
        if value_type == self.TYPE_STRING:
            return self.string(value_data) or ""
        if value_type in (self.TYPE_INT_DEC, self.TYPE_INT_HEX):
            return str(value_data)
        if value_type == self.TYPE_INT_BOOLEAN:
            return "true" if value_data else "false"
        if value_type in (self.TYPE_REFERENCE, self.TYPE_ATTRIBUTE):
            return f"@0x{value_data:08x}"
        if value_type == self.TYPE_FLOAT:
            return str(struct.unpack("<f", struct.pack("<I", value_data))[0])
        return str(value_data)


def parse_harmony_json(path: Path, data: bytes, kind: str, source: str) -> VersionInfo:
    parsed = json.loads(data.decode("utf-8", errors="ignore"))
    app = parsed.get("app", {}) if isinstance(parsed, dict) else {}
    module = parsed.get("module", {}) if isinstance(parsed, dict) else {}
    release = first_present(app.get("versionName"), module.get("versionName"), parsed.get("versionName"))
    build = first_present(app.get("versionCode"), module.get("versionCode"), parsed.get("versionCode"))
    bundle_id = first_present(app.get("bundleName"), module.get("bundleName"), parsed.get("bundleName"))
    name = first_present(app.get("label"), module.get("name"), parsed.get("name"))
    return VersionInfo(
        path=str(path),
        kind=kind,
        platform="harmonyos",
        release_version=release,
        build_version=build,
        name=name,
        bundle_id=bundle_id,
        source=source,
    )


def parse_tauri_project(root: Path) -> VersionInfo:
    tauri_root = root / "src-tauri" if (root / "src-tauri").exists() else root
    warnings: list[str] = []
    config_paths = [
        tauri_root / "tauri.conf.json",
        tauri_root / "tauri.conf.json5",
        tauri_root / "tauri.conf.toml",
        root / "tauri.conf.json",
        root / "tauri.conf.json5",
        root / "tauri.conf.toml",
    ]
    for config in config_paths:
        if not config.exists():
            continue
        try:
            data = read_tauri_config(config)
        except Exception as exc:
            warnings.append(f"failed to parse {config}: {exc}")
            continue
        release = first_present(
            data.get("version"),
            nested_get(data, ["package", "version"]),
            nested_get(data, ["bundle", "version"]),
        )
        name = first_present(data.get("productName"), nested_get(data, ["package", "productName"]))
        bundle_id = first_present(data.get("identifier"), nested_get(data, ["tauri", "bundle", "identifier"]), nested_get(data, ["bundle", "identifier"]))
        if release:
            return VersionInfo(
                path=str(root),
                kind="tauri_project",
                platform="tauri",
                release_version=release,
                build_version=release,
                name=name,
                bundle_id=bundle_id,
                source=str(config),
                warnings=warnings,
            )

    cargo = tauri_root / "Cargo.toml"
    if cargo.exists() and tomllib:
        try:
            with cargo.open("rb") as handle:
                data = tomllib.load(handle)
            release = nested_get(data, ["package", "version"])
            name = nested_get(data, ["package", "name"])
            if release:
                return VersionInfo(
                    path=str(root),
                    kind="tauri_project",
                    platform="tauri",
                    release_version=release,
                    build_version=release,
                    name=name,
                    source=str(cargo),
                    warnings=warnings,
                )
        except Exception as exc:
            warnings.append(f"failed to parse {cargo}: {exc}")

    package_json = root / "package.json"
    if package_json.exists():
        try:
            data = json.loads(package_json.read_text(encoding="utf-8"))
            release = data.get("version")
            if release:
                return VersionInfo(
                    path=str(root),
                    kind="tauri_project",
                    platform="tauri",
                    release_version=release,
                    build_version=release,
                    name=data.get("name"),
                    source=str(package_json),
                    warnings=warnings,
                )
        except Exception as exc:
            warnings.append(f"failed to parse {package_json}: {exc}")

    return VersionInfo(path=str(root), kind="tauri_project", platform="tauri", source=str(root), warnings=warnings)


def read_tauri_config(path: Path) -> dict[str, Any]:
    if path.suffix == ".toml":
        if not tomllib:
            raise RuntimeError("tomllib is unavailable; use Python 3.11+ for tauri.conf.toml")
        with path.open("rb") as handle:
            return tomllib.load(handle)
    text = path.read_text(encoding="utf-8")
    if path.suffix == ".json5":
        text = strip_json5(text)
    return json.loads(text)


def strip_json5(text: str) -> str:
    result: list[str] = []
    in_string = False
    quote = ""
    escaped = False
    index = 0
    while index < len(text):
        char = text[index]
        next_char = text[index + 1] if index + 1 < len(text) else ""
        if in_string:
            result.append('"' if char == quote and quote == "'" else char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                in_string = False
            index += 1
            continue
        if char in {'"', "'"}:
            in_string = True
            quote = char
            result.append('"')
            index += 1
            continue
        if char == "/" and next_char == "/":
            index = text.find("\n", index)
            if index == -1:
                break
            continue
        if char == "/" and next_char == "*":
            end = text.find("*/", index + 2)
            index = len(text) if end == -1 else end + 2
            continue
        result.append(char)
        index += 1
    cleaned = "".join(result)
    cleaned = re.sub(r"([{,]\s*)([A-Za-z_$][\w$-]*)\s*:", r'\1"\2":', cleaned)
    return re.sub(r",\s*([}\]])", r"\1", cleaned)


def nested_get(data: dict[str, Any], keys: list[str]) -> Any:
    current: Any = data
    for key in keys:
        if not isinstance(current, dict) or key not in current:
            return None
        current = current[key]
    return current


def parse_ios_project(root: Path) -> VersionInfo:
    variables = collect_xcode_build_settings(root)
    files = walk_files(root, max_depth=7)
    plist_candidates = [
        path
        for path in files
        if path.name == "Info.plist"
        and not any(part in {"Tests", "UITests", "Pods"} for part in path.parts)
    ]
    plist_candidates.sort(key=lambda path: (len(path.parts), str(path)))
    warnings: list[str] = []
    for plist in plist_candidates:
        try:
            info = info_from_plist_file(plist, "ios", "ios_project", variables)
        except Exception as exc:
            warnings.append(f"failed to parse {plist}: {exc}")
            continue
        if info.release_version or info.build_version:
            info.path = str(root)
            info.warnings.extend(warnings)
            return info

    release = variables.get("MARKETING_VERSION")
    build = variables.get("CURRENT_PROJECT_VERSION")
    bundle_id = variables.get("PRODUCT_BUNDLE_IDENTIFIER")
    return VersionInfo(
        path=str(root),
        kind="ios_project",
        platform="ios",
        release_version=release,
        build_version=build,
        bundle_id=bundle_id,
        source="project.pbxproj" if variables else str(root),
        warnings=warnings,
    )


def collect_xcode_build_settings(root: Path) -> dict[str, str]:
    variables: dict[str, str] = {}
    keys = {
        "ASSETCATALOG_COMPILER_APPICON_NAME",
        "CURRENT_PROJECT_VERSION",
        "INFOPLIST_KEY_CFBundleDisplayName",
        "MARKETING_VERSION",
        "PRODUCT_BUNDLE_IDENTIFIER",
        "PRODUCT_NAME",
    }
    files = list(root.glob("*.xcodeproj/project.pbxproj")) + list(root.glob("**/*.xcodeproj/project.pbxproj"))
    for file in files:
        try:
            text = file.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for key in keys:
            values = re.findall(rf"\b{re.escape(key)}\s*=\s*([^;]+);", text)
            selected = best_value([strip_xcode_value(value) for value in values])
            if selected:
                variables[key] = selected
    return variables


def strip_xcode_value(value: str) -> str:
    value = value.strip().strip('"').strip("'")
    value = value.replace("\\", "")
    return value


def parse_windows_project_dir(root: Path) -> VersionInfo:
    solution = next(iter(root.glob("*.sln")), None)
    if solution:
        info = parse_solution(solution)
        if info.release_version or info.build_version:
            info.path = str(root)
            return info

    files = walk_files(root, max_depth=6)
    manifest = next((path for path in files if path.name.lower() in {"package.appxmanifest", "appxmanifest.xml"}), None)
    if manifest:
        info = parse_appx_manifest_file(manifest)
        info.path = str(root)
        return info

    projects = [
        path
        for path in files
        if path.suffix.lower() in {".csproj", ".vbproj", ".fsproj", ".vcxproj", ".wapproj"}
    ]
    projects.sort(key=lambda path: (0 if path.suffix.lower() != ".vcxproj" else 1, len(path.parts)))
    for project in projects:
        info = parse_windows_project_file(project)
        if info.release_version or info.build_version:
            info.path = str(root)
            return info

    rc_file = next((path for path in files if path.suffix.lower() == ".rc"), None)
    if rc_file:
        info = parse_rc_file(rc_file)
        info.path = str(root)
        return info

    return parse_from_filename(root, "windows_project", "windows")


def parse_solution(path: Path) -> VersionInfo:
    warnings: list[str] = []
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError as exc:
        return VersionInfo(path=str(path), kind="sln", platform="windows", source=str(path), warnings=[str(exc)])
    project_paths = []
    for match in re.finditer(r'Project\("[^"]+"\)\s*=\s*"[^"]+",\s*"([^"]+)",', text):
        rel = match.group(1).replace("\\", os.sep)
        if Path(rel).suffix.lower() in {".csproj", ".vbproj", ".fsproj", ".vcxproj", ".wapproj"}:
            project_paths.append(path.parent / rel)
    for project in project_paths:
        if not project.exists():
            warnings.append(f"project not found: {project}")
            continue
        info = parse_windows_project_file(project)
        if info.release_version or info.build_version:
            info.kind = "sln"
            info.source = str(project)
            info.warnings.extend(warnings)
            return info
    return VersionInfo(path=str(path), kind="sln", platform="windows", source=str(path), warnings=warnings)


def parse_windows_project_file(path: Path) -> VersionInfo:
    suffix = path.suffix.lower()
    if suffix == ".vcxproj":
        rc_info = find_rc_near_project(path)
        if rc_info.release_version or rc_info.build_version:
            rc_info.kind = "vcxproj"
            rc_info.source = rc_info.source or str(path)
            return rc_info

    if suffix == ".wapproj":
        manifest = next(path.parent.glob("**/Package.appxmanifest"), None)
        if manifest:
            info = parse_appx_manifest_file(manifest)
            info.kind = "wapproj"
            info.source = str(manifest)
            return info

    try:
        root = ET.parse(path).getroot()
    except Exception as exc:
        return VersionInfo(
            path=str(path),
            kind=suffix.lstrip("."),
            platform="windows",
            source=str(path),
            warnings=[f"failed to parse project xml: {exc}"],
        )

    props = xml_property_map(root)
    release = first_present(
        props.get("Version"),
        props.get("PackageVersion"),
        props.get("ApplicationDisplayVersion"),
        props.get("ProductVersion"),
        props.get("InformationalVersion"),
        props.get("AssemblyVersion"),
        props.get("FileVersion"),
    )
    build = first_present(
        props.get("FileVersion"),
        props.get("AssemblyVersion"),
        props.get("ApplicationVersion"),
        props.get("Version"),
        props.get("PackageVersion"),
    )
    name = first_present(props.get("ProductName"), props.get("AssemblyName"), path.stem)
    bundle_id = first_present(props.get("ApplicationId"), props.get("PackageCertificateKeyFile"))
    return VersionInfo(
        path=str(path),
        kind=suffix.lstrip("."),
        platform="windows",
        release_version=release,
        build_version=build,
        name=name,
        bundle_id=bundle_id,
        source=str(path),
    )


def xml_property_map(root: ET.Element) -> dict[str, str]:
    props: dict[str, str] = {}
    for elem in root.iter():
        name = local_name(elem.tag)
        if elem.text and elem.text.strip() and name not in props:
            props[name] = elem.text.strip()
    return props


def find_rc_near_project(path: Path) -> VersionInfo:
    candidates = list(path.parent.glob("*.rc")) + list(path.parent.glob("**/*.rc"))
    for candidate in candidates:
        info = parse_rc_file(candidate)
        if info.release_version or info.build_version:
            return info
    return VersionInfo(path=str(path), kind="vcxproj", platform="windows", source=str(path))


def parse_rc_file(path: Path) -> VersionInfo:
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError as exc:
        return VersionInfo(path=str(path), kind="rc", platform="windows", source=str(path), warnings=[str(exc)])
    product = find_rc_string(text, "ProductVersion")
    file_version = find_rc_string(text, "FileVersion")
    if not product:
        product = find_rc_numeric(text, "PRODUCTVERSION")
    if not file_version:
        file_version = find_rc_numeric(text, "FILEVERSION")
    name = find_rc_string(text, "ProductName")
    return VersionInfo(
        path=str(path),
        kind="rc",
        platform="windows",
        release_version=product,
        build_version=file_version,
        name=name,
        source=str(path),
    )


def find_rc_string(text: str, key: str) -> str | None:
    match = re.search(rf'VALUE\s+"{re.escape(key)}"\s*,\s*"([^"]+)"', text)
    return match.group(1).replace("\\0", "").strip() if match else None


def find_rc_numeric(text: str, key: str) -> str | None:
    match = re.search(rf"\b{re.escape(key)}\s+([0-9,\s]+)", text)
    if not match:
        return None
    return ".".join(part.strip() for part in match.group(1).split(",") if part.strip())


def parse_pe_file(path: Path) -> VersionInfo:
    try:
        parser = PEVersionParser(path.read_bytes())
        strings, fixed = parser.version_info()
    except Exception as exc:
        return VersionInfo(
            path=str(path),
            kind="pe",
            platform="windows",
            source=str(path),
            warnings=[f"failed to parse PE version info: {exc}"],
        )
    product = first_present(strings.get("ProductVersion"), fixed.get("ProductVersion"))
    file_version = first_present(strings.get("FileVersion"), fixed.get("FileVersion"))
    return VersionInfo(
        path=str(path),
        kind="pe",
        platform="windows",
        release_version=version_like(product),
        build_version=version_like(file_version),
        name=first_present(strings.get("ProductName"), strings.get("FileDescription")),
        source="version_resource",
        extra={"raw": strings},
    )


class PEVersionParser:
    RT_VERSION = 16

    def __init__(self, data: bytes):
        self.data = data
        self.sections: list[dict[str, int]] = []
        self.resource_rva = 0
        self.resource_size = 0
        self.resource_offset = 0
        self._parse_headers()

    def _parse_headers(self) -> None:
        if self.data[:2] != b"MZ":
            raise ValueError("missing MZ header")
        pe_offset = self.u32(0x3C)
        if self.data[pe_offset : pe_offset + 4] != b"PE\x00\x00":
            raise ValueError("missing PE header")
        file_header = pe_offset + 4
        _, section_count, _, _, _, optional_size, _ = struct.unpack_from("<HHIIIHH", self.data, file_header)
        optional = file_header + 20
        magic = self.u16(optional)
        data_dir = optional + (112 if magic == 0x20B else 96)
        self.resource_rva = self.u32(data_dir + 2 * 8)
        self.resource_size = self.u32(data_dir + 2 * 8 + 4)
        section_offset = optional + optional_size
        for index in range(section_count):
            current = section_offset + index * 40
            name = self.data[current : current + 8].rstrip(b"\x00").decode("ascii", errors="ignore")
            virtual_size, virtual_address, raw_size, raw_ptr = struct.unpack_from("<IIII", self.data, current + 8)
            self.sections.append(
                {
                    "name": name,
                    "virtual_size": virtual_size,
                    "virtual_address": virtual_address,
                    "raw_size": raw_size,
                    "raw_ptr": raw_ptr,
                }
            )
        self.resource_offset = self.rva_to_offset(self.resource_rva)

    def u16(self, offset: int) -> int:
        return struct.unpack_from("<H", self.data, offset)[0]

    def u32(self, offset: int) -> int:
        return struct.unpack_from("<I", self.data, offset)[0]

    def rva_to_offset(self, rva: int) -> int:
        for section in self.sections:
            start = section["virtual_address"]
            size = max(section["virtual_size"], section["raw_size"])
            if start <= rva < start + size:
                return section["raw_ptr"] + (rva - start)
        raise ValueError(f"RVA not mapped: 0x{rva:x}")

    def version_info(self) -> tuple[dict[str, str], dict[str, str]]:
        blob = self._version_resource()
        strings, fixed = parse_version_resource_blob(blob)
        return strings, fixed

    def _version_resource(self) -> bytes:
        for type_id, type_entry in self._resource_entries(self.resource_offset):
            if type_id != self.RT_VERSION:
                continue
            type_dir = self._entry_dir_offset(type_entry)
            for _, name_entry in self._resource_entries(type_dir):
                name_dir = self._entry_dir_offset(name_entry)
                for _, lang_entry in self._resource_entries(name_dir):
                    data_rva, size, _, _ = struct.unpack_from("<IIII", self.data, self._entry_data_offset(lang_entry))
                    data_offset = self.rva_to_offset(data_rva)
                    return self.data[data_offset : data_offset + size]
        raise ValueError("version resource not found")

    def _resource_entries(self, directory_offset: int) -> list[tuple[int | str, int]]:
        named_count = self.u16(directory_offset + 12)
        id_count = self.u16(directory_offset + 14)
        entries = []
        for index in range(named_count + id_count):
            current = directory_offset + 16 + index * 8
            name_or_id, offset_to_data = struct.unpack_from("<II", self.data, current)
            if name_or_id & 0x80000000:
                name = self._resource_name(self.resource_offset + (name_or_id & 0x7FFFFFFF))
            else:
                name = name_or_id & 0xFFFF
            entries.append((name, offset_to_data))
        return entries

    def _resource_name(self, offset: int) -> str:
        length = self.u16(offset)
        raw = self.data[offset + 2 : offset + 2 + length * 2]
        return raw.decode("utf-16le", errors="replace")

    def _entry_dir_offset(self, entry_value: int) -> int:
        if not entry_value & 0x80000000:
            raise ValueError("resource entry is not a directory")
        return self.resource_offset + (entry_value & 0x7FFFFFFF)

    def _entry_data_offset(self, entry_value: int) -> int:
        if entry_value & 0x80000000:
            raise ValueError("resource entry is not data")
        return self.resource_offset + entry_value


def parse_version_resource_blob(blob: bytes) -> tuple[dict[str, str], dict[str, str]]:
    strings: dict[str, str] = {}
    fixed: dict[str, str] = {}

    def parse_block(offset: int, limit: int) -> int:
        if offset + 6 > limit:
            return limit
        start = offset
        length, value_length, value_type = struct.unpack_from("<HHH", blob, offset)
        if length == 0:
            return limit
        offset += 6
        key, offset = read_utf16_key(blob, offset, start + length)
        value_offset = align4(offset)
        value_bytes = value_length * 2 if value_type == 1 else value_length
        value_end = min(value_offset + value_bytes, start + length)
        if key == "VS_VERSION_INFO" and value_bytes >= 52:
            fixed.update(parse_fixed_file_info(blob[value_offset:value_end]))
        elif value_type == 1 and value_bytes > 0 and key not in {"StringFileInfo", "VarFileInfo"}:
            raw = blob[value_offset:value_end]
            strings[key] = raw.decode("utf-16le", errors="ignore").rstrip("\x00")

        child_offset = align4(value_end)
        while child_offset + 6 <= start + length:
            next_offset = parse_block(child_offset, start + length)
            if next_offset <= child_offset:
                break
            child_offset = align4(next_offset)
        return start + length

    parse_block(0, len(blob))
    return strings, fixed


def read_utf16_key(data: bytes, offset: int, limit: int) -> tuple[str, int]:
    start = offset
    while offset + 1 < limit:
        if data[offset : offset + 2] == b"\x00\x00":
            raw = data[start:offset]
            return raw.decode("utf-16le", errors="replace"), offset + 2
        offset += 2
    return "", offset


def parse_fixed_file_info(data: bytes) -> dict[str, str]:
    if len(data) < 52:
        return {}
    signature = struct.unpack_from("<I", data, 0)[0]
    if signature != 0xFEEF04BD:
        return {}
    file_ms, file_ls, product_ms, product_ls = struct.unpack_from("<IIII", data, 8)
    return {
        "FileVersion": version_from_ms_ls(file_ms, file_ls),
        "ProductVersion": version_from_ms_ls(product_ms, product_ls),
    }


def version_from_ms_ls(ms: int, ls: int) -> str:
    return ".".join(str(part) for part in ((ms >> 16) & 0xFFFF, ms & 0xFFFF, (ls >> 16) & 0xFFFF, ls & 0xFFFF))


def align4(value: int) -> int:
    return (value + 3) & ~3


def parse_msi(path: Path) -> VersionInfo:
    if os.name == "nt":
        info = parse_msi_with_powershell(path)
        if info.release_version or info.build_version:
            return info
    info = parse_msi_with_msiinfo(path)
    if info.release_version or info.build_version:
        return info
    info.warnings.append("msi parsing needs Windows Installer COM or msiinfo")
    return info


def parse_msi_with_powershell(path: Path) -> VersionInfo:
    shell = shutil.which("powershell") or shutil.which("pwsh")
    if not shell:
        return VersionInfo(path=str(path), kind="msi", platform="windows", source=str(path))
    quoted_path = str(path).replace("'", "''")
    script = f"""
$path = '{quoted_path}'
$installer = New-Object -ComObject WindowsInstaller.Installer
$db = $installer.GetType().InvokeMember('OpenDatabase','InvokeMethod',$null,$installer,@($path,0))
function Get-Prop($name) {{
  $view = $db.OpenView("SELECT Value FROM Property WHERE Property='$name'")
  $view.Execute()
  $record = $view.Fetch()
  if ($record) {{ $record.StringData(1) }} else {{ $null }}
}}
[pscustomobject]@{{
  ProductName = Get-Prop 'ProductName'
  ProductVersion = Get-Prop 'ProductVersion'
  ProductCode = Get-Prop 'ProductCode'
}} | ConvertTo-Json -Compress
"""
    code, stdout, stderr = run_command([shell, "-NoProfile", "-NonInteractive", "-Command", script])
    if code != 0:
        return VersionInfo(
            path=str(path),
            kind="msi",
            platform="windows",
            source="powershell",
            warnings=[stderr.strip()],
        )
    try:
        data = json.loads(stdout)
    except json.JSONDecodeError as exc:
        return VersionInfo(
            path=str(path),
            kind="msi",
            platform="windows",
            source="powershell",
            warnings=[f"failed to parse PowerShell JSON: {exc}"],
        )
    return VersionInfo(
        path=str(path),
        kind="msi",
        platform="windows",
        release_version=data.get("ProductVersion"),
        build_version=data.get("ProductVersion"),
        name=data.get("ProductName"),
        bundle_id=data.get("ProductCode"),
        source="powershell",
    )


def parse_msi_with_msiinfo(path: Path) -> VersionInfo:
    tool = shutil.which("msiinfo")
    if not tool:
        return VersionInfo(path=str(path), kind="msi", platform="windows", source=str(path))
    code, stdout, stderr = run_command([tool, "export", str(path), "Property"])
    if code != 0:
        return VersionInfo(path=str(path), kind="msi", platform="windows", source="msiinfo", warnings=[stderr.strip()])
    props: dict[str, str] = {}
    for line in stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            props[parts[0]] = parts[1]
    return VersionInfo(
        path=str(path),
        kind="msi",
        platform="windows",
        release_version=props.get("ProductVersion"),
        build_version=props.get("ProductVersion"),
        name=props.get("ProductName"),
        bundle_id=props.get("ProductCode"),
        source="msiinfo",
    )


def parse_deb(path: Path) -> VersionInfo:
    try:
        members = read_ar_members(path.read_bytes())
        control_name = next(name for name in members if name.startswith("control.tar"))
        control_data = members[control_name]
        with tarfile.open(fileobj=io.BytesIO(control_data), mode="r:*") as archive:
            control_member = next(member for member in archive.getmembers() if member.name.lstrip("./") == "control")
            extracted = archive.extractfile(control_member)
            if not extracted:
                raise ValueError("control member is empty")
            props = parse_debian_control(extracted.read().decode("utf-8", errors="replace"))
        full_version = props.get("Version")
        return VersionInfo(
            path=str(path),
            kind="deb",
            platform="linux",
            release_version=debian_upstream_version(full_version),
            build_version=full_version,
            name=props.get("Package"),
            source="control",
        )
    except Exception as exc:
        return VersionInfo(
            path=str(path),
            kind="deb",
            platform="linux",
            source=str(path),
            warnings=[f"failed to parse deb: {exc}"],
        )


def read_ar_members(data: bytes) -> dict[str, bytes]:
    if not data.startswith(b"!<arch>\n"):
        raise ValueError("invalid ar archive")
    offset = 8
    members: dict[str, bytes] = {}
    while offset + 60 <= len(data):
        header = data[offset : offset + 60]
        name = header[:16].decode("utf-8", errors="replace").strip().rstrip("/")
        size = int(header[48:58].decode("ascii").strip())
        offset += 60
        members[name] = data[offset : offset + size]
        offset += size + (size % 2)
    return members


def parse_debian_control(text: str) -> dict[str, str]:
    props: dict[str, str] = {}
    current_key = None
    for line in text.splitlines():
        if line.startswith((" ", "\t")) and current_key:
            props[current_key] += "\n" + line.strip()
            continue
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        current_key = key.strip()
        props[current_key] = value.strip()
    return props


def debian_upstream_version(value: str | None) -> str | None:
    value = clean_value(value)
    if not value:
        return None
    if ":" in value:
        value = value.split(":", 1)[1]
    if "-" in value:
        value = value.rsplit("-", 1)[0]
    return value


def parse_rpm(path: Path) -> VersionInfo:
    tool = shutil.which("rpm")
    if not tool:
        return VersionInfo(
            path=str(path),
            kind="rpm",
            platform="linux",
            source=str(path),
            warnings=["rpm command not found"],
        )
    fmt = "%{NAME}\n%{VERSION}\n%{RELEASE}\n"
    code, stdout, stderr = run_command([tool, "-qp", "--queryformat", fmt, str(path)])
    if code != 0:
        return VersionInfo(path=str(path), kind="rpm", platform="linux", source="rpm", warnings=[stderr.strip()])
    name, version, release = (stdout.splitlines() + ["", "", ""])[:3]
    return VersionInfo(
        path=str(path),
        kind="rpm",
        platform="linux",
        release_version=version,
        build_version=f"{version}-{release}" if release else version,
        name=name,
        source="rpm",
    )


def parse_pkg(path: Path) -> VersionInfo:
    tool = shutil.which("pkgutil")
    if not tool:
        return VersionInfo(
            path=str(path),
            kind="pkg",
            platform="macos",
            source=str(path),
            warnings=["pkgutil command not found"],
        )
    code, stdout, stderr = run_command([tool, "--pkg-info-plist", str(path)])
    if code != 0:
        return VersionInfo(path=str(path), kind="pkg", platform="macos", source="pkgutil", warnings=[stderr.strip()])
    try:
        data = plistlib.loads(stdout.encode("utf-8"))
    except Exception as exc:
        return VersionInfo(path=str(path), kind="pkg", platform="macos", source="pkgutil", warnings=[str(exc)])
    version = data.get("pkg-version")
    return VersionInfo(
        path=str(path),
        kind="pkg",
        platform="macos",
        release_version=version,
        build_version=version,
        name=data.get("pkgid"),
        bundle_id=data.get("pkgid"),
        source="pkgutil",
    )


def parse_dmg(path: Path) -> VersionInfo:
    if sys.platform != "darwin" or not shutil.which("hdiutil"):
        return VersionInfo(
            path=str(path),
            kind="dmg",
            platform="macos",
            source=str(path),
            warnings=["dmg parsing is only supported on macOS with hdiutil"],
        )
    mount_point = None
    try:
        code, stdout, stderr = run_command(["hdiutil", "attach", "-nobrowse", "-readonly", "-plist", str(path)], timeout=60)
        if code != 0:
            raise RuntimeError(stderr.strip())
        plist = plistlib.loads(stdout.encode("utf-8"))
        entities = plist.get("system-entities", [])
        for entity in entities:
            if entity.get("mount-point"):
                mount_point = Path(entity["mount-point"])
                break
        if not mount_point:
            raise RuntimeError("mount point not found")
        app = next(mount_point.glob("*.app"), None)
        if not app:
            raise RuntimeError(".app not found in dmg")
        info = parse_app_dir(app)
        info.path = str(path)
        info.kind = "dmg"
        info.source = str(app / "Contents" / "Info.plist")
        return info
    except Exception as exc:
        return VersionInfo(path=str(path), kind="dmg", platform="macos", source=str(path), warnings=[str(exc)])
    finally:
        if mount_point:
            run_command(["hdiutil", "detach", str(mount_point)], timeout=30)


def parse_from_filename(path: Path, kind: str, platform: str | None) -> VersionInfo:
    stem = path.stem
    match = re.search(r"(?<!\d)(\d+\.\d+(?:\.\d+){0,3})(?:[-_+.]?(?:build|b)?(\d+))?(?!\d)", stem, re.I)
    release = match.group(1) if match else None
    build = match.group(2) if match and match.group(2) else None
    return VersionInfo(
        path=str(path),
        kind=kind,
        platform=platform,
        release_version=release,
        build_version=build,
        name=path.stem,
        source="filename" if match else str(path),
        warnings=[] if match else ["no supported version metadata found"],
    )


def find_xml_child(root: ET.Element, local: str) -> ET.Element | None:
    for elem in root.iter():
        if local_name(elem.tag) == local:
            return elem
    return None


def local_name(tag: str) -> str:
    if "}" in tag:
        return tag.rsplit("}", 1)[1]
    if ":" in tag:
        return tag.rsplit(":", 1)[1]
    return tag


def xml_attr(elem: ET.Element | None, local: str) -> str | None:
    if elem is None:
        return None
    for key, value in elem.attrib.items():
        if local_name(key) == local:
            return value
    return None


def normalize_zealot_url(value: str) -> str:
    value = value.strip()
    if not value:
        return DEFAULT_ZEALOT_URL.rstrip("/")
    if not re.match(r"^https?://", value):
        value = "https://" + value
    return value.rstrip("/")


def get_required_value(value: str | None, env_name: str, prompt: str, secret: bool = False) -> str:
    selected = clean_value(value) or clean_value(os.environ.get(env_name))
    if selected:
        return selected
    if secret:
        selected = getpass.getpass(prompt)
    else:
        selected = input(prompt)
    selected = clean_value(selected)
    if not selected:
        raise ValueError(f"{env_name} is required")
    return selected


def prompt_changelog() -> str:
    if not sys.stdin.isatty():
        changelog = sys.stdin.read().strip()
        if not changelog:
            raise ValueError("更新说明不能为空")
        return changelog

    print("请输入更新说明，支持多行；单独输入一行 . 结束：", file=sys.stderr)
    while True:
        lines: list[str] = []
        while True:
            line = input("> ")
            if line.strip() == ".":
                break
            lines.append(line)
        changelog = "\n".join(lines).strip()
        if changelog:
            return changelog
        print("更新说明不能为空，请重新输入。", file=sys.stderr)


def multipart_field_part(boundary: str, key: str, value: str) -> bytes:
    return (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="{key}"\r\n\r\n'
        f"{value}\r\n"
    ).encode("utf-8")


def multipart_file_header(boundary: str, file_path: Path) -> bytes:
    filename = file_path.name
    content_type = mimetypes.guess_type(filename)[0] or "application/octet-stream"
    return (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'
        f"Content-Type: {content_type}\r\n\r\n"
    ).encode("utf-8")


def post_multipart_json(url: str, fields: dict[str, str], file_path: Path) -> dict[str, Any]:
    boundary = "----zealot-python-" + os.urandom(16).hex()
    field_parts = [
        multipart_field_part(boundary, key, str(value))
        for key, value in fields.items()
        if value is not None
    ]
    file_header = multipart_file_header(boundary, file_path)
    file_footer = b"\r\n"
    closing = f"--{boundary}--\r\n".encode("utf-8")
    content_length = (
        sum(len(part) for part in field_parts)
        + len(file_header)
        + file_path.stat().st_size
        + len(file_footer)
        + len(closing)
    )

    parsed = urllib.parse.urlparse(url)
    if parsed.scheme == "https":
        connection: http.client.HTTPConnection = http.client.HTTPSConnection(parsed.netloc, timeout=300)
    elif parsed.scheme == "http":
        connection = http.client.HTTPConnection(parsed.netloc, timeout=300)
    else:
        raise ValueError(f"unsupported URL scheme: {parsed.scheme}")

    target = urllib.parse.urlunparse(("", "", parsed.path or "/", parsed.params, parsed.query, ""))
    try:
        connection.putrequest("POST", target)
        connection.putheader("Content-Type", f"multipart/form-data; boundary={boundary}")
        connection.putheader("Content-Length", str(content_length))
        connection.putheader("User-Agent", "zealot-app-version-info/1.0")
        connection.endheaders()
        for part in field_parts:
            connection.send(part)
        connection.send(file_header)
        with file_path.open("rb") as handle:
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                connection.send(chunk)
        connection.send(file_footer)
        connection.send(closing)
        response = connection.getresponse()
        payload = response.read()
    finally:
        connection.close()

    if response.status >= 400:
        text = payload.decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {response.status}: {text}")
    if not payload:
        return {}
    try:
        return json.loads(payload.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"invalid JSON response from {url}: {payload[:200]!r}") from exc


def request_json(url: str, method: str, body: bytes, headers: dict[str, str]) -> dict[str, Any]:
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            payload = response.read()
    except urllib.error.HTTPError as exc:
        payload = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code}: {payload}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"request failed: {exc}") from exc

    if not payload:
        return {}
    try:
        return json.loads(payload.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"invalid JSON response from {url}: {payload[:200]!r}") from exc


def upload_to_zealot(
    base_url: str,
    token: str,
    channel_key: str,
    artifact: Path,
    info: VersionInfo,
    changelog: str,
    *,
    app_name: str | None = None,
    release_type: str | None = None,
    source: str = "python-script",
    ci_url: str | None = None,
) -> dict[str, Any]:
    git = git_metadata(artifact)
    fields = {
        "token": token,
        "channel_key": channel_key,
        "changelog": changelog,
        "source": source,
        "branch": git.get("branch", ""),
        "git_commit": git.get("git_commit", ""),
        "ci_url": ci_url or "",
        "release_type": release_type or "",
        "name": app_name or info.name or "",
    }
    fields = {key: value for key, value in fields.items() if value}

    upload_url = f"{base_url}/api/apps/upload"
    upload_response = post_multipart_json(upload_url, fields, artifact)

    release_id = upload_response.get("id")
    if not release_id:
        raise RuntimeError(f"upload response missing release id: {upload_response}")

    update_fields = {
        "release_version": info.release_version,
        "build_version": info.build_version,
        "changelog": changelog,
        "source": source,
        "branch": git.get("branch"),
        "git_commit": git.get("git_commit"),
        "ci_url": ci_url,
        "release_type": release_type,
    }
    update_fields = {key: value for key, value in update_fields.items() if value}
    update_url = f"{base_url}/api/releases/{release_id}?{urllib.parse.urlencode({'token': token})}"
    update_body = json.dumps(update_fields, ensure_ascii=False).encode("utf-8")
    update_response = request_json(
        update_url,
        "PUT",
        update_body,
        {
            "Content-Type": "application/json",
            "Content-Length": str(len(update_body)),
            "User-Agent": "zealot-app-version-info/1.0",
        },
    )

    return {
        "zealot_url": base_url,
        "artifact": str(artifact),
        "release_id": release_id,
        "upload_response": upload_response,
        "update_response": update_response,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Parse release_version and build_version from app packages or project files."
    )
    parser.add_argument("paths", nargs="+", help="App artifact, project directory, or project file")
    parser.add_argument("--upload", action="store_true", help="Upload one artifact to Zealot after parsing")
    parser.add_argument("--zealot-url", default=os.environ.get("ZEALOT_URL", DEFAULT_ZEALOT_URL), help="Zealot base URL")
    parser.add_argument("--token", help="Zealot user token; defaults to ZEALOT_TOKEN or interactive prompt")
    parser.add_argument("--channel-key", help="Zealot channel key; defaults to ZEALOT_CHANNEL_KEY or interactive prompt")
    parser.add_argument("--name", help="Override app name when Zealot creates a new app")
    parser.add_argument("--release-type", help="Override Zealot release_type, e.g. debug, beta, adhoc, release")
    parser.add_argument("--source", default="python-script", help="Zealot upload source")
    parser.add_argument("--ci-url", default=os.environ.get("CI_JOB_URL") or os.environ.get("BUILD_URL"), help="CI build URL")
    parser.add_argument("--fail-on-missing", action="store_true", help="Exit 2 if version metadata is missing")
    args = parser.parse_args(argv)

    if args.upload and len(args.paths) != 1:
        parser.error("--upload supports exactly one path")

    infos = [parse_path(Path(path)) for path in args.paths]
    missing = [info for info in infos if not info.release_version and not info.build_version]

    if args.upload:
        input_path = Path(args.paths[0]).expanduser()
        artifact = find_latest_upload_artifact(input_path)
        if not artifact:
            parser.error(f"no uploadable artifact found under {input_path}")

        artifact_info = parse_path(artifact)
        info = merge_version_info(artifact_info, infos[0])
        if not info.release_version and not info.build_version:
            parser.error("未解析到版本号/构建号，已停止上传")

        base_url = normalize_zealot_url(args.zealot_url)
        token = get_required_value(args.token, "ZEALOT_TOKEN", "Zealot token: ", secret=True)
        channel_key = get_required_value(args.channel_key, "ZEALOT_CHANNEL_KEY", "Zealot channel key: ")
        changelog = prompt_changelog()

        print(f"Uploading {artifact} to {base_url} ...", file=sys.stderr)
        upload = upload_to_zealot(
            base_url,
            token,
            channel_key,
            artifact,
            info,
            changelog,
            app_name=args.name,
            release_type=args.release_type,
            source=args.source,
            ci_url=args.ci_url,
        )
        payload = {
            "version_info": info.as_json(),
            "upload": upload,
        }
    else:
        payload = infos[0].as_json() if len(infos) == 1 else [info.as_json() for info in infos]
    print(json.dumps(payload, ensure_ascii=False, indent=2))

    if args.upload:
        return 0
    return 2 if args.fail_on_missing and missing else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
