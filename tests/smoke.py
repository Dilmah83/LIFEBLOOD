"""Run with: python tests/smoke.py (requires Playwright and Chromium)."""
import json
from pathlib import Path
from playwright.sync_api import sync_playwright

html = Path(__file__).resolve().parents[1] / 'index.html'
with sync_playwright() as p:
    browser = p.chromium.launch(executable_path='/usr/bin/chromium', args=['--no-sandbox'])
    page = browser.new_page(accept_downloads=True)
    errors = []
    page.on('pageerror', lambda e: errors.append(str(e)))
    page.route('https://lifeblood.test/', lambda route: route.fulfill(body=html.read_text(), content_type='text/html'))
    page.goto('https://lifeblood.test/')
    page.get_by_role('button', name='Get started').click()
    page.get_by_role('button', name='Add', exact=True).click()
    page.locator('#f_name').fill('Test medicine')
    page.locator('#f_ing').fill('ibuprofen')
    page.get_by_role('button', name='Save item', exact=True).click()
    page.get_by_role('button', name='Medicine info & side effects').click()
    assert page.locator('#medicineQuery').input_value() == 'ibuprofen'
    page.route('https://api.fda.gov/**', lambda route: route.fulfill(json={
        'results': [{'openfda': {'brand_name': ['Test product'], 'generic_name': ['ibuprofen'], 'route': ['ORAL']},
                     'adverse_reactions': ['Nausea <script>alert(1)</script>'], 'indications_and_usage': ['Pain relief']}]}))
    page.get_by_role('button', name='Find medicine information', exact=True).click()
    page.get_by_role('button', name='View uses, side effects & warnings').click()
    assert 'Nausea <script>alert(1)</script>' in page.locator('#medicineResults').inner_text()
    assert page.locator('#medicineResults script').count() == 0
    page.get_by_role('button', name='Back to matching products').click()
    page.get_by_role('button', name='View uses, side effects & warnings').wait_for()
    page.unroute('https://api.fda.gov/**')
    page.route('https://api.fda.gov/**', lambda route: route.fulfill(status=404, json={}))
    page.get_by_role('button', name='Find medicine information', exact=True).click()
    page.get_by_text('No matching label found.', exact=False).wait_for()
    page.unroute('https://api.fda.gov/**')
    page.route('https://api.fda.gov/**', lambda route: route.abort())
    page.get_by_role('button', name='Find medicine information', exact=True).click()
    page.get_by_text('Could not connect.', exact=False).wait_for()
    page.get_by_role('button', name='Settings', exact=False).click()
    with page.expect_download() as download:
        page.get_by_role('button', name='Export to Calendar', exact=True).click()
    text = Path(download.value.path()).read_text()
    assert 'BEGIN:VEVENT' in text and 'BEGIN:VALARM' in text
    assert 'SUMMARY:Health reminder' in text and 'Test medicine' not in text
    assert page.get_by_role('link', name='Open calendar file').is_visible()
    # Export only eligible schedules and preserve weekly recurrence/end dates.
    result = page.evaluate('''() => {
      S.items=[{id:'weekly',name:'💊'.repeat(50)+' A,B;C\\nD',times:['08:00','20:00'],days:[1,3],start:'2099-01-01',end:'2099-02-01'},
        {id:'stopped',stopped:true,times:['09:00']},
        {id:'expired',end:'2000-01-01',times:['10:00']}];
      S.settings.private=false;return buildICS();
    }''')
    assert result['count'] == 2
    assert 'BYDAY=MO,WE;UNTIL=20990201T235959' in result['text']
    assert all(len(line.encode()) <= 75 for line in result['text'].split('\r\n'))
    assert '\\,B\\;C\\nD' in result['text'].replace('\r\n ', '')
    page.evaluate('S.items=[];exportCal()')
    assert 'No reminder times' in page.locator('#toast').inner_text()
    assert not errors, errors
    browser.close()
print('PASS: medicine lookup, escaped labels, no results/offline, calendar download, privacy, recurrence, UTF-8 folding, empty export')
