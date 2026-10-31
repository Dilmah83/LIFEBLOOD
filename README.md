# LIFEBLOOD

Static medication tracker. Open `index.html` or serve it over HTTPS. Data stays in browser storage; medicine label searches send the entered search term to api.fda.gov.

## Calendar export

Settings → Export to Calendar opens/downloads one `.ics` file containing all active scheduled reminders. Open it and confirm Add / Import in your calendar app. A visible file link remains available if automatic opening is blocked. Google Calendar web imports files through Settings → Import & export. A browser cannot silently add events to the device calendar; final import and alert permissions belong to the calendar app. iPhone/iPad use a calendar preview link; if the Home Screen app cannot open it, use Safari. Actual iOS import requires device verification.

Exports respect selected weekdays, start/end dates, discontinued items and notification privacy. Re-export after changing schedules; check previously imported events because calendar apps vary in their handling of duplicate UIDs and updates.

## Medicine information

My items → Medicine info & side effects → Find medicine information. Confirm the matching product before viewing uses, side effects, warnings, contraindications and interactions from its published US FDA label. Some labels lack sections. US products can differ from Australian medicines; the view also links to Healthdirect for Australian information. No matching result does not imply a product is safe. This is general product information, not a personalised interaction check.

## Validation

Run `python tests/smoke.py` with Playwright and Chromium installed at `/usr/bin/chromium`. Tests mock FDA responses and cover label rendering, HTML escaping, no results, offline errors, calendar download, privacy, recurrence, expired/discontinued items and UTF-8 line folding. A live FDA ibuprofen lookup was also checked during development. Native iPhone Calendar import is not automated by this test.


## Native iPhone / Xcode implementation

Open [`ios/Lifeblood.xcodeproj`](ios/Lifeblood.xcodeproj). See [native setup, migration, coverage and validation](ios/README.md) and [medical-provider gateway requirements](server/README.md).

The original web app remains available. Settings now exports a full JSON archive for explicit migration into the native tracker. The native build offers structured ingredient/dose tracking, actual logs, schedules, source views, local duplicate screening, calendar export and opt-in licensed-provider integration. It includes a keyless public FDA product finder, explicitly marked as US data, and runs clinical checks in clearly labelled limited mode without a licensed provider. Australian nutrient-limit comparisons and personalised interaction-screened supplement prescribing remain unimplemented; no clinical validation is claimed.

Prescription photo scanning: Products → Scan prescription photo. Camera or selected-photo text recognition runs on-device, populates editable drafts, and requires review and explicit save. See ios/README.md for supported extraction and device-test requirements.

Vitamin and supplement bottle/pack labels can now be scanned in Products → Scan vitamin or supplement label. The generated pill app icon is included in the Xcode asset catalog. Loose pills are not identified from appearance.
