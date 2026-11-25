import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
EXAMPLE = ROOT / 'Examples/DemoBots'


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value


checker = module('demobots_setup', EXAMPLE / 'Tools/check-game-center-testing.py')
schemes = module('demobots_schemes', EXAMPLE / 'Tools/configure-game-center-schemes.py')


class DemoBotsGameCenterSetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for source in [EXAMPLE / 'App/DemoBotsLocal.gamekit', EXAMPLE / 'DemoBots.xcodeproj/xcshareddata/xcschemes']:
            shutil.copytree(source, self.root / source.relative_to(EXAMPLE))
        (self.root / 'Game').mkdir()
        for relative in ['project.yml', 'Game/DemoBotsGameCenterLab.swift']:
            shutil.copyfile(EXAMPLE / relative, self.root / relative)
        self.json = self.root / 'App/DemoBotsLocal.gamekit/gameCenterResources.json'

    def update(self, action):
        data = json.loads(self.json.read_text()); action(data['resources']); self.json.write_text(json.dumps(data))

    def test_repository_fixture_and_schemes_are_consistent(self):
        self.assertEqual(checker.check(self.root), [])

    def test_bad_resource_ids_and_challenge_links_fail(self):
        self.update(lambda resources: resources['achievements'][0].update(vendorIdentifier='wrong'))
        self.update(lambda resources: resources['challengeLeaderboardRelationships']['dev.spriteui.demobots.repair_challenge'][0].update(leaderboardLocalID='missing'))
        errors = ' '.join(checker.check(self.root))
        self.assertIn('identifiers', errors); self.assertIn('Repair Score', errors)

    def test_party_size_and_raw_play_style_are_validated(self):
        self.update(lambda resources: resources['gameActivities'][1].update(minimumPlayersCount=1, playStyle='synchronous'))
        self.assertIn('player counts', ' '.join(checker.check(self.root)))

    def test_native_challenge_duration_field_is_required(self):
        self.update(lambda resources: resources['challenges'][0].pop('allowedDurations', None))
        self.assertIn('allowedDurations', ' '.join(checker.check(self.root)))

    def test_native_challenge_durations_reject_invalid_or_duplicate_values(self):
        for values in ([], ['oneDay', 'threeDays', 'oneWeek'], ['ONE_DAY'] * 3, 'ONE_DAY'):
            with self.subTest(values=values):
                self.update(lambda resources: resources['challenges'][0].update(allowedDurations=values))
                self.assertIn('allowedDurations', ' '.join(checker.check(self.root)))

    def test_missing_art_or_escape_path_is_rejected(self):
        image = self.root / 'App/DemoBotsLocal.gamekit/repair.png'; image.unlink()
        self.assertIn('missing local image', ' '.join(checker.check(self.root)))
        self.update(lambda resources: resources['gameActivityDefaultImages']['dev.spriteui.demobots.coop'].update(url='../../project.yml'))
        self.assertIn('missing local image', ' '.join(checker.check(self.root)))

    def test_scheme_regeneration_restores_isolation_and_is_idempotent(self):
        directory = self.root / 'DemoBots.xcodeproj/xcshareddata/xcschemes'
        for path in directory.glob('*.xcscheme'):
            tree = ET.parse(path); tree.getroot().find('LaunchAction').set('enableGameKitDebugMode', 'YES'); tree.write(path)
        self.assertTrue(checker.check(self.root))
        schemes.configure(self.root); self.assertEqual(checker.check(self.root), [])
        first = {path.name: path.read_bytes() for path in directory.glob('*.xcscheme')}
        schemes.configure(self.root)
        self.assertEqual(first, {path.name: path.read_bytes() for path in directory.glob('*.xcscheme')})

    def test_broken_json_and_missing_release_exclusion_fail_closed(self):
        self.json.write_text('invalid'); self.assertTrue(checker.check(self.root))
        shutil.copyfile(EXAMPLE / 'App/DemoBotsLocal.gamekit/gameCenterResources.json', self.json)
        path = self.root / 'project.yml'; path.write_text(path.read_text().replace('EXCLUDED_SOURCE_FILE_NAMES: DemoBotsLocal.gamekit', ''))
        self.assertIn('Release targets', ' '.join(checker.check(self.root)))
