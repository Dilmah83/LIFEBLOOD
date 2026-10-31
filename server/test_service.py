"""Contract tests use explicitly fictional fixtures, never shipped as medical results."""
import copy
import unittest
from unittest.mock import patch
from service import Gateway, Invalid, Unavailable, product, clinical, NoRedirect


def fixture(name='Fixture tablet', amount=1, formulation='tablet'):
    return dict(id=name, brand=name, generic='Fixture ingredient', strength=str(amount) + ' mg', formulation=formulation, route='Oral',
                ingredients=[dict(id='fixture-substance', name='Fixture ingredient', amount=amount, unit='mg', form='test form', per=1, productUnit='tablet')],
                verified=True, sources=[dict(id='fixture-source', title='Fictional test source', url='https://example.org/fixture', checked='2026-10-01T00:00:00Z', jurisdiction='AU')],
                sections={'Main uses': 'TEST ONLY <script>untrusted text</script>'}, missing=[], conflicts=[])


def check_fixture():
    return dict(coverage='Fixture only: fictional drug pair, no supplement coverage', complete=False, checked='2026-10-01T00:00:00Z', findings=[dict(
        id='fictional-interaction', title='Fixture interaction', products=['Fixture A', 'Fixture B'], ingredients=['Fixture ingredient'], consequence='Fictional test consequence', severity='Review', evidence='Documented', advice='Professional review', spacing='Spacing not established', sources=fixture()['sources'])])

class ServiceTests(unittest.TestCase):
    def test_no_provider_fails_closed(self):
        with self.assertRaises(Unavailable): Gateway(base='', licence='').products('test')
    def test_no_licence_rejects_provider(self):
        with self.assertRaises(Unavailable): Gateway(base='https://example.org', licence='').products('test')
    def test_ambiguous_brand_and_formulations_remain_separate(self):
        a, b = fixture('Fixture 1 mg tablet'), fixture('Fixture 2 mg injection', 2, 'injection')
        g = Gateway(fetch=lambda _: [a, b])
        self.assertEqual(len(g.products('Fixture')), 2)
        self.assertNotEqual(g.products('Fixture')[0]['id'], g.products('Fixture')[1]['id'])
    def test_combination_and_multivitamin_all_ingredients_retained(self):
        p = fixture(); extra = copy.deepcopy(p['ingredients'][0]); extra['id'] = 'fixture-b'; extra['name'] = 'Second ingredient'; extra['unit'] = 'microgram'; p['ingredients'].append(extra)
        self.assertEqual(len(product(p)['ingredients']), 2)
    def test_concentration_not_inferred(self):
        p = fixture(formulation='injection'); del p['ingredients'][0]['per']
        with self.assertRaises(Invalid): product(p)
        p = fixture(); p['ingredients'][0]['unit'] = 'unknown'
        with self.assertRaises(Invalid): product(p)
    def test_conflicting_sources_cannot_be_verified(self):
        p = fixture(); p['conflicts'] = ['Conflicting strength']
        with self.assertRaises(Invalid): product(p)
        p['verified'] = False
        self.assertEqual(product(p)['conflicts'], ['Conflicting strength'])
    def test_missing_sections_explicit(self):
        p = product(fixture())
        self.assertIn('Serious adverse effects: not provided by source', p['missing'])
        self.assertIn('<script>', p['sections']['Main uses']) # plain text contract; SwiftUI never interprets HTML
    def test_cache_expiry_never_hides_failed_refresh(self):
        now = [100]
        count = [0]
        def fetch(_):
            count[0] += 1
            if count[0] > 1: raise Unavailable('rate limited')
            return [fixture()]
        g = Gateway(fetch=fetch, clock=lambda: now[0])
        self.assertEqual(g.products('fixture')[0]['sources'][0]['checked'], '2026-10-01T00:00:00Z')
        g.products('fixture'); self.assertEqual(count[0], 1)
        now[0] += 86401
        with self.assertRaises(Unavailable): g.products('fixture')
    def test_citation_scheme_and_future_checked_date_rejected(self):
        for url in ['javascript:alert(1)', 'http://example.org', 'https://user:secret@example.org']:
            p = fixture(); p['sources'][0]['url'] = url
            with self.assertRaises(Invalid): product(p)
        p = fixture(); p['sources'][0]['checked'] = '2099-01-01T00:00:00Z'
        with self.assertRaises(Invalid): product(p)
    def test_clinical_finding_requires_evidence_and_coverage(self):
        p = check_fixture()
        self.assertFalse(clinical(p)['complete'])
        self.assertEqual(p['findings'][0]['evidence'], 'Documented')
        p['findings'][0]['sources'] = []
        with self.assertRaises(Invalid): clinical(p)
    def test_theoretical_separate_from_documented(self):
        p = check_fixture(); p['findings'][0]['evidence'] = 'Theoretical'
        self.assertEqual(clinical(p)['findings'][0]['evidence'], 'Theoretical')
        p['findings'][0]['evidence'] = 'Guaranteed safe'
        with self.assertRaises(Invalid): clinical(p)
    def test_regimen_payload_has_no_identity_and_preserves_weekly_prn(self):
        submitted = []
        def fetch(path, body): submitted.append(body); return check_fixture()
        row = dict(id='provider:fixture', quantity=0.5, unit='mL', weekdays=[2], times=['08:00'], asNeeded=False)
        gateway = Gateway(fetch=fetch)
        gateway.check({'products': [row]})
        self.assertEqual(submitted[0]['products'][0]['weekdays'], [2])
        row['asNeeded'] = True; row['times'] = []
        gateway.check({'products': [row]})
        with self.assertRaises(Invalid): gateway.check({'products': [row], 'patientName': 'private'})
        row['id'] = 'manual:unresolved'
        with self.assertRaises(Invalid): gateway.check({'products': [row]})
    def test_provider_redirect_cannot_forward_credentials(self):
        with self.assertRaises(Unavailable): NoRedirect().redirect_request(None, None, 307, '', {}, 'https://another-host.test')
    def test_nan_and_boolean_strength_not_accepted(self):
        for value in [float('nan'), float('inf'), True, -1, 0]:
            p = fixture(); p['ingredients'][0]['amount'] = value
            with self.assertRaises(Invalid): product(p)

if __name__ == '__main__': unittest.main()
