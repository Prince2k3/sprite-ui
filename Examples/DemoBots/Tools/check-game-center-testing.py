#!/usr/bin/env python3
"""Check DemoBots' local GameKit fixtures and schemes; never contacts Game Center."""
import json
from pathlib import Path
import re
import struct
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def check(root=ROOT):
    errors = []
    try:
        ids = dict(re.findall(r'static let (\w+) = "([^"]+)"', (root / 'Game/DemoBotsGameCenterLab.swift').read_text()))
        if set(ids) != {'achievement', 'leaderboard', 'activity', 'coop', 'challenge'}:
            raise ValueError('Expected the five shared sample identifiers')
        bundle = root / 'App/DemoBotsLocal.gamekit'
        data = json.loads((bundle / 'gameCenterResources.json').read_text())
        resources = data['resources']
        for kind, names in [('achievements', ['achievement']), ('leaderboards', ['leaderboard']), ('gameActivities', ['activity', 'coop']), ('challenges', ['challenge'])]:
            values = resources[kind]
            if {item['vendorIdentifier'] for item in values} != {ids[name] for name in names} or len(values) != len(names):
                errors.append(f'{kind}: definitions do not match the shared Swift identifiers')
        for activity in resources['gameActivities']:
            coop = activity['vendorIdentifier'] == ids['coop']
            count = 2 if coop else 1
            if (activity.get('playStyle') != 'SYNCHRONOUS' or activity.get('supportsPartyCode') is not coop
                    or activity.get('minimumPlayersCount') != count or activity.get('maximumPlayersCount') != count):
                errors.append('Activity play style, party support, and player counts must match the sample')
        relationship = resources['challengeLeaderboardRelationships'][ids['challenge']]
        if len(relationship) != 1 or relationship[0]['leaderboardLocalID'] != ids['leaderboard']:
            errors.append('Repair Challenge must reference Repair Score')
        if resources['challenges'][0]['challengeType'] != 'LEADERBOARD':
            errors.append('Challenge type must be LEADERBOARD')
        for kind, names in [('gameActivityDefaultImages', ['activity', 'coop']), ('challengeDefaultImages', ['challenge'])]:
            for name in names:
                relative = resources[kind][ids[name]]['url']
                image = (bundle / relative).resolve()
                if not image.is_relative_to(bundle.resolve()) or not image.is_file():
                    errors.append(f'{name}: missing local image'); continue
                png = image.read_bytes()
                if png[:8] != b'\x89PNG\r\n\x1a\n' or struct.unpack('>IIBB', png[16:26]) != (3840, 2160, 8, 2):
                    errors.append(f'{name}: expected opaque 3840×2160 RGB PNG placeholder')
        for name in ('DemoBots', 'DemoBotsMac', 'DemoBots Local Game Center', 'DemoBotsMac Local Game Center'):
            tree = ET.parse(root / f'DemoBots.xcodeproj/xcshareddata/xcschemes/{name}.xcscheme')
            launch = tree.getroot().find('LaunchAction')
            local = name.endswith(' Local Game Center')
            if launch is None or launch.get('enableGameKitDebugMode') != ('YES' if local else 'NO'):
                errors.append(f'{name}: incorrect GameKit debug isolation')
            variables = [] if launch is None else launch.findall('EnvironmentVariables/EnvironmentVariable')
            opens_lab = any(item.get('key') == 'DEMOBOTS_GAME_CENTER_TESTING' and item.get('value') == '1' and item.get('isEnabled') == 'YES' for item in variables)
            if opens_lab != local:
                errors.append(f'{name}: incorrect test-lab launch environment')
        project = (root / 'project.yml').read_text()
        if project.count('EXCLUDED_SOURCE_FILE_NAMES: DemoBotsLocal.gamekit') != 2:
            errors.append('Both Release targets must exclude the local GameKit bundle')
    except (OSError, ValueError, KeyError, TypeError, IndexError, struct.error, ET.ParseError) as error:
        errors.append(f'Invalid local setup: {error}')
    return errors


if __name__ == '__main__':
    errors = check()
    for error in errors:
        print(f'ERROR: {error}')
    print('DemoBots local GameKit setup: ' + ('FAILED' if errors else 'PASSED'))
    print('Physical-device Game Progress Manager and signed two-account testing remain pending.')
    sys.exit(1 if errors else 0)
