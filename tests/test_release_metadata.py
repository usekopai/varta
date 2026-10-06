"""Release gates must reject mismatched or unfinished version metadata."""
import importlib.util
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from release_metadata import read_version
spec = importlib.util.spec_from_file_location('release_notes', ROOT / '.github/scripts/release-notes.py')
notes_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes_module)


class ReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.plist_path = self.root / 'app/Support/Info.plist'
        self.swift_path = self.root / 'app/Sources/VartaCore/Version.swift'
        self.plist_path.parent.mkdir(parents=True)
        self.swift_path.parent.mkdir(parents=True)
        self.info = plistlib.loads((ROOT / 'app/Support/Info.plist').read_bytes())
        self.info['CFBundleShortVersionString'] = '1.2.3'
        self.write_info()
        self.swift_path.write_text('public static let version = "1.2.3"')
        (self.root / 'CHANGELOG.md').write_text('## [Unreleased]\n\nFuture work.\n\n## [1.2.3] - 2026-10-05\n\nReleased change.\n\n## [1.2.2] - 2026-10-01\n\nOld change.\n')

    def write_info(self):
        self.plist_path.write_bytes(plistlib.dumps(self.info))

    def test_matching_metadata(self):
        self.assertEqual(read_version(self.root, '1.2.3'), '1.2.3')

    def test_wrong_tag_rejected(self):
        with self.assertRaises(ValueError):
            read_version(self.root, '1.2.4')

    def test_wrong_swift_version_rejected(self):
        self.swift_path.write_text('public static let version = "0.0.1"')
        with self.assertRaises(ValueError):
            read_version(self.root)

    def test_malformed_app_metadata_rejected(self):
        cases = [('CFBundleShortVersionString', '../escape'), ('CFBundleVersion', 'dev'),
                 ('CFBundleIdentifier', 'wrong.app'), ('LSMinimumSystemVersion', '26.0')]
        for field, value in cases:
            with self.subTest(field=field):
                original = self.info[field]
                self.info[field] = value
                self.write_info()
                with self.assertRaises(ValueError):
                    read_version(self.root)
                self.info[field] = original
                self.write_info()

    def test_only_requested_release_notes_included(self):
        notes = notes_module.release_notes(self.root, '1.2.3')
        self.assertIn('Released change.', notes)
        self.assertNotIn('Future work.', notes)
        self.assertNotIn('Old change.', notes)
        self.assertIn('Varta-1.2.3-arm64.dmg', notes)
        self.assertIn('not signed with a Developer ID certificate', notes)
        self.assertIn('not notarized by Apple', notes)

    def test_unreleased_or_empty_changelog_rejected(self):
        for text in ['## [Unreleased]\n\nPending\n', '## [1.2.3] - 2026-10-05\n\n', '## [1.2.3]\n\nUndated\n']:
            with self.subTest(text=text):
                (self.root / 'CHANGELOG.md').write_text(text)
                with self.assertRaises(ValueError):
                    notes_module.release_notes(self.root, '1.2.3')


if __name__ == '__main__':
    unittest.main()
