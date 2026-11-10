"""Version and tag checks for this project's releases, leaving template helpers intact."""

import unittest

from release_version import tag_version, validate


class ReleaseVersionTests(unittest.TestCase):
    def test_increasing_same_day_revisions(self):
        self.assertGreater(int(validate("2026110602")), int(validate("2026110601")))
        self.assertGreater(int(validate("2026110601")), 20261106)
        self.assertGreater(int(validate("2026110700")), int(validate("2026110699")))

    def test_tag_matches_packaged_numeric_core(self):
        for tag in ("v2026110601", "v2026110601-beta.1", "v2026110601-rc1"):
            self.assertEqual(tag_version(tag, "2026110601"), "2026110601")

    def test_invalid_or_mismatched_tags(self):
        for tag in (
            "v20261106",
            "v2026110602",
            "2026110601",
            "v2026110601-",
            "v2026110601+local",
        ):
            with self.assertRaises(ValueError):
                tag_version(tag, "2026110601")

    def test_invalid_calendar_dates_and_controller_range(self):
        for value in ("2026023001", "2026130101", "SENTINEL", "9999110101"):
            with self.assertRaises(ValueError):
                validate(value)

    def test_releases_cannot_regress_or_reuse_a_prerelease_core(self):
        self.assertEqual(
            tag_version("v2026110602-beta.1", "2026110602", ["v2026110601-beta.1"]),
            "2026110602",
        )
        for tag in ("v2026110601", "v2026110601-beta.2"):
            with self.assertRaises(ValueError):
                tag_version(tag, "2026110601", ["v2026110601-beta.1"])
        self.assertEqual(
            tag_version("v2026110601-beta.1", "2026110601", ["v2026110601-beta.1"]),
            "2026110601",
        )


if __name__ == "__main__":
    unittest.main()
