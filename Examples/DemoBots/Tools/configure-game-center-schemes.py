#!/usr/bin/env python3
"""Preserve Xcode's GameKit debug flag after XcodeGen (which does not expose it yet)."""
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
LOCAL = {"DemoBots Local Game Center", "DemoBotsMac Local Game Center"}


def configure(root=ROOT):
    directory = root / "DemoBots.xcodeproj/xcshareddata/xcschemes"
    for name in ("DemoBots", "DemoBotsMac", *sorted(LOCAL)):
        path = directory / f"{name}.xcscheme"
        tree = ET.parse(path)
        launch = tree.getroot().find("LaunchAction")
        if launch is None:
            raise ValueError(f"Missing LaunchAction in {path}")
        launch.set("enableGameKitDebugMode", "YES" if name in LOCAL else "NO")
        ET.indent(tree, space="   ")
        tree.write(path, encoding="UTF-8", xml_declaration=True)


if __name__ == "__main__":
    configure()
