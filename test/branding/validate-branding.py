#!/usr/bin/env python3
"""Validate Split Capture public identity and configuration isolation."""

from __future__ import annotations

import json
import re
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APP_ID = "io.github.georgeqle.splitcapture"
PRODUCT = "Split Capture"
REPOSITORY = "https://github.com/GeorgeQLe/split-capture"


def fail(message: str) -> None:
    raise AssertionError(message)


def text(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def require(haystack: str, needle: str, label: str) -> None:
    if needle not in haystack:
        fail(f"{label}: missing {needle!r}")


def png_size(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        fail(f"{path}: not a PNG")
    return struct.unpack(">II", data[16:24])


def validate_metadata() -> None:
    bootstrap = text("cmake/common/bootstrap.cmake")
    for expected in ("GeorgeQLe", PRODUCT, REPOSITORY):
        require(bootstrap, expected, "CMake product identity")

    desktop = text(f"frontend/cmake/linux/{APP_ID}.desktop")
    fields = {
        "Name": PRODUCT,
        "Exec": "split-capture",
        "Icon": APP_ID,
        "StartupWMClass": "split-capture",
    }
    parsed = dict(
        line.split("=", 1)
        for line in desktop.splitlines()
        if "=" in line and not line.startswith(("GenericName[", "Comment["))
    )
    for key, value in fields.items():
        if parsed.get(key) != value:
            fail(f"desktop metadata: {key}={parsed.get(key)!r}, expected {value!r}")

    metainfo_path = ROOT / f"frontend/cmake/linux/{APP_ID}.metainfo.xml.in"
    metainfo = ET.parse(metainfo_path).getroot()
    if metainfo.findtext("id") != APP_ID:
        fail("AppStream ID is stale")
    if metainfo.findtext("name") != PRODUCT:
        fail("AppStream product name is stale")
    if metainfo.findtext("developer/name") != "GeorgeQLe":
        fail("AppStream publisher is stale")
    urls = {element.text for element in metainfo.findall("url")}
    if REPOSITORY not in urls:
        fail("AppStream homepage is stale")

    manifest = json.loads(text(f"build-aux/{APP_ID}.json"))
    if manifest["id"] != APP_ID or manifest["command"] != "split-capture":
        fail("Flatpak identity or command is stale")

    flatpak_exceptions = json.loads(text(".github/actions/flatpak-builder-lint/exceptions.json"))
    app_exceptions = flatpak_exceptions.get(APP_ID, [])
    if "appid-url-not-reachable" not in app_exceptions:
        fail("Flatpak must allow the permanent splitcapture ID / split-capture repository slug mismatch")


def validate_icons() -> None:
    mac_directory = ROOT / "frontend/cmake/macos/Assets.xcassets/AppIcon.appiconset"
    mac_slots = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }
    for filename, expected in mac_slots.items():
        size = png_size(mac_directory / filename)
        if size != (expected, expected):
            fail(f"{filename}: {size}, expected {expected}x{expected}")

    for expected in (128, 256, 512):
        path = ROOT / f"frontend/cmake/linux/icons/split-capture-{expected}.png"
        if png_size(path) != (expected, expected):
            fail(f"{path}: incorrect dimensions")

    svg = text("frontend/cmake/linux/icons/split-capture-scalable.svg")
    for color in ("#071A2B", "#2DD4F7", "#FF6B5E"):
        require(svg, color, "scalable icon palette")

    ico = (ROOT / "frontend/cmake/windows/split-capture.ico").read_bytes()
    reserved, icon_type, count = struct.unpack("<HHH", ico[:6])
    if (reserved, icon_type) != (0, 1):
        fail("Windows app icon has an invalid header")
    sizes: set[int] = set()
    for index in range(count):
        width, height = struct.unpack("BB", ico[6 + index * 16 : 8 + index * 16])
        if width != height:
            fail("Windows app icon contains a non-square layer")
        sizes.add(width or 256)
    if not {16, 24, 32, 48, 64, 128, 256}.issubset(sizes):
        fail(f"Windows app icon layers are incomplete: {sorted(sizes)}")

    icns = (ROOT / "branding/assets/SplitCapture.icns").read_bytes()
    if icns[:4] != b"icns" or struct.unpack(">I", icns[4:8])[0] != len(icns):
        fail("macOS packaging ICNS is invalid")


def validate_public_identifiers() -> None:
    stale_checks = {
        "Split OBS": (
            "frontend/cmake/split-capture-updater-options.cmake",
            "test/branding/validate-branding.py",
        ),
        "split-obs": (
            "docs/dual-capture-qualification.md",
            "test/branding/validate-branding.py",
        ),
        "com.obsproject.obs-studio": ("test/branding/validate-branding.py",),
        "OBS.app": ("test/branding/validate-branding.py",),
        "obs64.exe": ("test/branding/validate-branding.py",),
        "OBS-Studio-": (
            ".github/actions/windows-patches/action.yaml",
            "test/branding/validate-branding.py",
        ),
        "flathub.org/apps/details/com.obsproject.Studio": (
            "test/branding/validate-branding.py",
        ),
    }
    suffixes = {
        ".cmake",
        ".cpp",
        ".h",
        ".hpp",
        ".in",
        ".ini",
        ".json",
        ".md",
        ".mm",
        ".ps1",
        ".py",
        ".rst",
        ".sh",
        ".toml",
        ".yaml",
    }
    ignored_prefixes = (
        ".git/",
        "deps/",
        "docs/sphinx/",
        "libobs",
        "plugins/",
        "shared/",
        "tasks/",
        "test-reports/",
    )
    for path in ROOT.rglob("*"):
        if not path.is_file() or path.suffix not in suffixes:
            continue
        relative = path.relative_to(ROOT).as_posix()
        if relative.startswith(ignored_prefixes) or any(part.startswith("build") for part in path.relative_to(ROOT).parts):
            continue
        contents = path.read_text(encoding="utf-8", errors="ignore")
        for stale, allowed in stale_checks.items():
            if stale in contents and relative not in allowed:
                fail(f"{relative}: stale public identifier {stale!r}")

    app_sources = [
        path
        for path in (ROOT / "frontend").rglob("*")
        if path.suffix in {".c", ".cpp", ".h", ".hpp", ".m", ".mm"}
    ]
    config_pattern = re.compile(
        r"(GetAppConfigPath(?:Ptr)?|userConfigLocation|ProfilePath|SceneCollectionPath).*obs-studio"
    )
    for path in app_sources:
        if path.relative_to(ROOT).as_posix().startswith(("frontend/importer/", "frontend/importers/")):
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8", errors="ignore").splitlines(), 1):
            if config_pattern.search(line):
                fail(f"{path.relative_to(ROOT)}:{number}: OBS configuration access is forbidden")

    app_cpp = text("frontend/OBSApp.cpp")
    for required in (
        '"split-capture/global.ini"',
        '"/split-capture/user.ini"',
        '"split-capture/basic"',
        '"split-capture/plugin_config"',
    ):
        require(app_cpp, required, "configuration isolation")


def validate_updater_aliases() -> None:
    module = (ROOT / "frontend/cmake/split-capture-updater-options.cmake").as_posix()
    with tempfile.TemporaryDirectory(prefix="split-capture-updater-test-") as directory:
        driver = Path(directory) / "driver.cmake"
        driver.write_text(
            f"""
if(CASE STREQUAL "old")
  set(SPLIT_OBS_ENABLE_CUSTOM_UPDATER ON)
  set(SPLIT_OBS_UPDATE_FEED_URL "https://example.invalid/feed")
  set(SPLIT_OBS_UPDATE_PUBLIC_KEY "old-key")
elseif(CASE STREQUAL "same")
  set(SPLIT_CAPTURE_UPDATE_FEED_URL "same")
  set(SPLIT_OBS_UPDATE_FEED_URL "same")
elseif(CASE STREQUAL "conflict")
  set(SPLIT_CAPTURE_UPDATE_FEED_URL "new")
  set(SPLIT_OBS_UPDATE_FEED_URL "old")
endif()
include("{module}")
if(CASE STREQUAL "old")
  if(NOT SPLIT_CAPTURE_ENABLE_CUSTOM_UPDATER
     OR NOT SPLIT_CAPTURE_UPDATE_FEED_URL STREQUAL "https://example.invalid/feed"
     OR NOT SPLIT_CAPTURE_UPDATE_PUBLIC_KEY STREQUAL "old-key")
    message(FATAL_ERROR "deprecated updater aliases were not adopted")
  endif()
endif()
""",
            encoding="utf-8",
        )
        for case, should_pass in (("old", True), ("same", True), ("conflict", False)):
            result = subprocess.run(
                ["cmake", f"-DCASE={case}", "-P", str(driver)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            if (result.returncode == 0) != should_pass:
                fail(f"updater alias case {case!r} behaved incorrectly:\n{result.stdout}")


def main() -> int:
    validate_metadata()
    validate_icons()
    validate_public_identifiers()
    validate_updater_aliases()
    print("Split Capture branding and configuration isolation validation passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
