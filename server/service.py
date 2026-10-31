"""Minimal medical-provider gateway. No built-in medical facts, mock fallback or AI.
Deploy behind HTTPS with authentication; keys exist only in server environment.
Provider adapters must implement the documented contract and be appropriately licensed.
"""
import json
import os
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlencode, urlparse
from urllib.request import Request, build_opener, HTTPRedirectHandler
from threading import Lock

MAX_BYTES = 2_000_000
SECTIONS = {'Main uses', 'Common side effects', 'Serious adverse effects', 'Contraindications', 'Precautions', 'Monitoring', 'Interactions', 'Food and timing'}
UNITS = {'mg', 'microgram', 'g', 'mL', 'IU', 'tablet', 'capsule', 'serving'}
class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise Unavailable("Provider redirect rejected")

class Unavailable(Exception): pass
class Invalid(Exception): pass

def source(value):
    if not isinstance(value, dict): raise Invalid('Invalid source')
    parsed = urlparse(value.get('url', ''))
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password:
        raise Invalid('Sources must use HTTPS without credentials')
    for key in ('id', 'title', 'checked', 'jurisdiction'):
        if not isinstance(value.get(key), str) or not value[key]: raise Invalid('Missing source metadata')
    try:
        checked = datetime.fromisoformat(value['checked'].replace('Z', '+00:00'))
        if checked.tzinfo is None or checked.timestamp() > time.time() + 300: raise ValueError()
    except (ValueError, OverflowError): raise Invalid('Invalid source checked date')

def product(value):
    if not isinstance(value, dict): raise Invalid('Invalid product')
    for key in ('id', 'brand', 'generic', 'strength', 'formulation', 'route'):
        if not isinstance(value.get(key), str) or len(value[key]) > 500: raise Invalid('Missing product identity')
    if not all(value[k].strip() for k in ('id', 'brand', 'strength', 'formulation', 'route')): raise Invalid('Ambiguous product data')
    ingredients = value.get('ingredients')
    if not isinstance(ingredients, list) or len(ingredients) > 100: raise Invalid('Invalid ingredients')
    for i in ingredients:
        if not isinstance(i, dict) or not i.get('id') or not i.get('name'): raise Invalid('Missing ingredient identity')
        if i.get('unit') not in UNITS or i.get('productUnit') not in UNITS: raise Invalid('Unknown unit')
        for key in ('amount', 'per'):
            if type(i.get(key)) not in (int, float) or not 0 < i[key] < 1e12: raise Invalid('Invalid ingredient amount')
        if not isinstance(i.get('form'), str): raise Invalid('Missing ingredient form field')
    for key in ('sources', 'missing', 'conflicts'):
        if not isinstance(value.get(key), list): raise Invalid('Missing provenance or uncertainty')
    for s in value['sources']: source(s)
    if not all(isinstance(x, str) and len(x) < 10000 for x in value['missing'] + value['conflicts']): raise Invalid('Invalid uncertainty metadata')
    if type(value.get('verified')) is not bool: raise Invalid('Missing verification status')
    if value['verified'] and (not ingredients or not value['sources'] or value['conflicts']): raise Invalid('Cannot verify incomplete or conflicting composition')
    if not isinstance(value.get('sections'), dict): raise Invalid('Missing information sections')
    if any(k not in SECTIONS or not isinstance(v, str) or len(v) > 100000 for k, v in value['sections'].items()): raise Invalid('Invalid product information')
    # Every omitted section is explicitly represented as missing information.
    for section in sorted(SECTIONS - value['sections'].keys()):
        message = section + ': not provided by source'
        if message not in value['missing']: value['missing'].append(message)
    return value

def clinical(value):
    if not isinstance(value, dict) or not isinstance(value.get('coverage'), str) or not value['coverage'] or type(value.get('complete')) is not bool or not isinstance(value.get('findings'), list): raise Invalid('Missing clinical coverage')
    source({'id': 'result', 'title': 'Result', 'url': 'https://example.org', 'checked': value.get('checked'), 'jurisdiction': 'AU'})
    if len(value['findings']) > 500: raise Invalid('Too many findings')
    for finding in value['findings']:
        for key in ('id', 'title', 'consequence', 'severity', 'evidence', 'advice', 'spacing'):
            if not isinstance(finding.get(key), str) or not finding[key] or len(finding[key]) > 100000: raise Invalid('Incomplete clinical finding')
        if finding['severity'] not in ('Urgent review', 'Review', 'Information'): raise Invalid('Unknown severity')
        if finding['evidence'] not in ('Documented', 'Theoretical', 'Limited evidence'): raise Invalid('Evidence strength required')
        for key in ('products', 'ingredients'):
            if not isinstance(finding.get(key), list) or not all(isinstance(x, str) for x in finding[key]): raise Invalid('Missing affected products')
        if not finding.get('sources'): raise Invalid('Unsourced clinical finding')
        for s in finding['sources']: source(s)
    return value

class Gateway:
    def __init__(self, base=None, key=None, licence=None, fetch=None, clock=time.time):
        self.base = base if base is not None else os.getenv('MEDICAL_PROVIDER_URL', '')
        self.key = key if key is not None else os.getenv('MEDICAL_PROVIDER_KEY', '')
        self.licence = licence if licence is not None else os.getenv('MEDICAL_PROVIDER_LICENCE_REFERENCE', '')
        self.fetch = fetch or self._fetch
        self.clock = clock
        self.cache = {}
        self.lock = Lock()
    def _fetch(self, path, body=None):
        parsed = urlparse(self.base)
        if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or not self.licence:
            raise Unavailable('No appropriately licensed HTTPS medical provider configured')
        payload = None if body is None else json.dumps(body, allow_nan=False).encode()
        request = Request(self.base.rstrip('/') + path, data=payload, headers={'Authorization': 'Bearer ' + self.key, 'Content-Type': 'application/json', 'Accept': 'application/json'})
        try:
            with build_opener(NoRedirect).open(request, timeout=15) as response:
                # Never follow a redirect to another host with the server credential.
                if urlparse(response.url).netloc != parsed.netloc: raise Unavailable('Provider redirect rejected')
                raw = response.read(MAX_BYTES + 1)
                if len(raw) > MAX_BYTES: raise Invalid('Provider response too large')
                return json.loads(raw, parse_constant=lambda x: (_ for _ in ()).throw(Invalid('Non-finite number')))
        except (HTTPError, URLError, TimeoutError): raise Unavailable('Provider unavailable or rate limited; no substitute data used')
    def products(self, query):
        query = query.strip()
        if not 2 <= len(query) <= 120: raise Invalid('Search term must contain 2–120 characters')
        key = query.casefold()
        with self.lock: cached = self.cache.get(key)
        if cached and self.clock() - cached[0] < 86400: return json.loads(cached[1])
        value = self.fetch('/products?' + urlencode({'q': query, 'jurisdiction': 'AU'}))
        if not isinstance(value, list) or len(value) > 20: raise Invalid('Invalid product results')
        value = [product(p) for p in value]
        value.sort(key=lambda p: not any(s['jurisdiction'] == 'AU' for s in p['sources']))
        encoded = json.dumps(value, allow_nan=False)
        with self.lock:
            if len(self.cache) >= 500: self.cache.pop(next(iter(self.cache)))
            self.cache[key] = (self.clock(), encoded)
        return value
    def check(self, request):
        # Identity and free text are not accepted. Patient details require an explicitly
        # consented clinical provider, never a general search or language model endpoint.
        if not isinstance(request, dict) or set(request) != {'products'}: raise Invalid('Only product regimens accepted; no patient identity')
        if not isinstance(request['products'], list) or len(request['products']) > 100: raise Invalid('Invalid regimen')
        for row in request['products']:
            if set(row) != {'id', 'quantity', 'unit', 'weekdays', 'times', 'asNeeded'}: raise Invalid('Unexpected regimen fields')
            if not isinstance(row['id'], str) or len(row['id']) > 500 or row['id'].startswith(('manual:', 'legacy:')): raise Invalid('Clinical checks require provider-resolved products')
            if type(row['quantity']) not in (int, float) or not 0 < row['quantity'] < 1e9 or row['unit'] not in UNITS: raise Invalid('Invalid dose')
            if type(row['asNeeded']) is not bool or not isinstance(row['weekdays'], list) or any(type(x) is not int or x not in range(1, 8) for x in row['weekdays']): raise Invalid('Invalid schedule')
            if not isinstance(row['times'], list) or len(row['times']) > 24: raise Invalid('Invalid times')
            for t in row['times']:
                try:
                    h, m = t.split(':')
                    if len(h) != 2 or len(m) != 2 or not 0 <= int(h) < 24 or not 0 <= int(m) < 60: raise ValueError()
                except (ValueError, AttributeError): raise Invalid('Invalid time')
        return clinical(self.fetch('/check', request))

class Handler(BaseHTTPRequestHandler):
    gateway = Gateway()
    def log_message(self, *_): pass # Never log product queries, regimens or bearer credentials.
    def respond(self, status, value):
        raw = json.dumps(value, allow_nan=False).encode()
        self.send_response(status); self.send_header('Content-Type', 'application/json'); self.send_header('Cache-Control', 'no-store'); self.send_header('X-Content-Type-Options', 'nosniff'); self.end_headers(); self.wfile.write(raw)
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path != '/products': self.respond(404, {'error': 'Not found'}); return
        try: self.respond(200, self.gateway.products(parse_qs(parsed.query).get('q', [''])[0]))
        except Invalid as e: self.respond(422, {'error': str(e)})
        except (Unavailable, ValueError, KeyError, TypeError): self.respond(503, {'error': 'Product data unavailable. Manual entry is unverified.'})
    def do_POST(self):
        if self.path != '/check': self.respond(404, {'error': 'Not found'}); return
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 100000: raise Invalid('Invalid request size')
            body = json.loads(self.rfile.read(length), parse_constant=lambda _: None)
            self.respond(200, self.gateway.check(body))
        except (Invalid, json.JSONDecodeError) as e: self.respond(422, {'error': str(e)})
        except (Unavailable, ValueError, KeyError, TypeError): self.respond(503, {'error': 'Clinical coverage unavailable. No comprehensive check performed.'})

if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', int(os.getenv('PORT', '8080'))), Handler).serve_forever()
