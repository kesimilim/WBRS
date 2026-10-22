"""Regression guard: published catalogs must rebuild from tracked sources."""
import json
import unittest

import build_l10n_catalogs as source


class CatalogSourceTests(unittest.TestCase):
    def test_catalogs_rebuild_without_local_inventory(self):
        for code in source.CODES:
            with self.subTest(locale=code):
                delivered = json.loads((source.ROOT / 'assets/l10n' / f'{code}.json').read_text())
                self.assertEqual(source.CAT[code], delivered)
                self.assertEqual(set(source.CAT['ru']), set(delivered))

    def test_native_labels_are_complete_and_nonempty(self):
        for code in source.CODES:
            for key in ('Сохранённая история', 'Открыть меню навигации', 'Получатель выбран'):
                with self.subTest(locale=code, key=key):
                    self.assertIsInstance(source.CAT[code][key], str)
                    self.assertTrue(source.CAT[code][key].strip())


if __name__ == '__main__':
    unittest.main()
