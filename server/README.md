# Medical-provider gateway

Run `python3 -m unittest -v` here. Run locally with `python3 service.py`; it binds only to 127.0.0.1:8080. This is a gateway, not a clinical database. No live medical results are bundled. Missing configuration returns 503 without mock substitutions.

Deployment must provide:

- `MEDICAL_PROVIDER_URL`: HTTPS URL of a trusted structured medical-data adapter that implements `/products` and `/check`.
- `MEDICAL_PROVIDER_KEY`: secret service credential, server only.
- `MEDICAL_PROVIDER_LICENCE_REFERENCE`: your actual licence/agreement reference. This is an operational gate, not independent legal verification.
- TLS termination, deployment authentication/access control and request rate limiting. The included local HTTP server is not an internet-facing production service.

The upstream adapter must resolve Australian pack-level products, all active ingredients and canonical IDs; use appropriately licensed maintained clinical interactions; preserve evidence, severity, scope, source URLs and checked dates; disclose incomplete coverage and distinguish documented from theoretical concerns. General web search or a model must not implement the interaction engine. The gateway cannot independently certify an upstream's clinical correctness.

Product schema follows Swift `Product` in `ios/Lifeblood/Models.swift`. All stored properties must be present in provider JSON, including empty arrays/maps and `form`, `per`, `productUnit` on ingredients. Dates use UTC ISO 8601 without fractional seconds. Ingredient quantities are JSON numbers, not strings. Allowed units: mg, microgram, g, mL, IU, tablet, capsule, serving. `verified` refers to source-confirmed composition, not clinical suitability. Exact product strength, formulation and route are required. Conflicting or missing composition cannot be marked verified. Sections: Main uses, Common side effects, Serious adverse effects, Contraindications, Precautions, Monitoring, Interactions, Food and timing. Missing sections are labelled rather than generated.

`POST /check` accepts `{ "products": [...] }`; each product contains only `id`, `quantity`, `unit`, `weekdays` (Sunday 1), `times` (HH:mm), and `asNeeded`. No identity/free-text fields are accepted. There is no logging of request bodies or query strings. Upstream is trusted to use its licensed engine and preserve the submitted schedule. This payload omits patient details and start/end dates, so conditional dose/age/renal/pregnancy-specific clinical assessments must be disclosed as unavailable, not inferred.

The response follows Swift `ClinicalResult`: `coverage`, `complete`, `checked`, `findings`. Each finding includes `id`, `title`, `products`, `ingredients`, `consequence`, `severity` (Urgent review/Review/Information), `evidence` (Documented/Theoretical/Limited evidence), `advice`, `spacing`, `sources`. Findings require HTTPS source links and checked dates. Never say spacing resolves all interactions. Never claim no interactions when coverage is unavailable. Product information is cached in memory for 24 hours, preserving original source checked dates; expired results are not silently served after refresh failure. Clinical results are never cached. Outbound redirects are rejected before forwarding credentials.

Tests use fictional fixtures at example.org. They never act as a production fallback or validate medical facts.
