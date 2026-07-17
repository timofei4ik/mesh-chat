import unittest

from server.server import app_version_supported


class MeshPrivacyVersionTests(unittest.TestCase):
    def test_minimum_version_is_enforced(self):
        self.assertFalse(app_version_supported(None, "1.3.0"))
        self.assertFalse(app_version_supported("1.2.9", "1.3.0"))
        self.assertTrue(app_version_supported("1.3.0", "1.3.0"))
        self.assertTrue(app_version_supported("1.4.1+7", "1.3.0"))


if __name__ == "__main__":
    unittest.main()
