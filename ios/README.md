# Native LIFEBLOOD for iPhone

Open `Lifeblood.xcodeproj` in Xcode 16 or newer, select the Lifeblood scheme and an iPhone simulator, then Run. For a physical iPhone, select your own signing team and unique bundle identifier. Minimum iOS 17. No third-party iOS dependencies. `python3 generate_project.py` regenerates the committed Xcode project after source additions; `project.yml` is an optional XcodeGen alternative.

## Delivered behaviour

SwiftUI tabs provide a daily schedule, actual-dose log (including as-needed doses and injection notes), editable product list, exact-product confirmation, source disclosure, safety findings, ingredient totals, optional profile and blood-test records, assessment prompts, full JSON backups and a shareable pharmacist summary. Native files use iOS complete file protection and atomic writes. Historical doses retain the composition recorded at that time. No server keys or AI-generated facts are present in the app.

Mass units normalise to mg using decimal arithmetic. mL is never treated as mass. Ingredient delivery uses confirmed strength amount divided by strength basis, multiplied by the quantity actually taken. For example, 10 mg per 1 mL and a 0.5 mL dose yields 5 mg. Supplement serving sizes use the same explicit basis. Incompatible units are reported as missing, not guessed. IU stays separate. Weekly schedules remain weekly; scheduled totals exclude as-needed intake and actual totals include only logs. Food is not quantified, so totals are explicitly incomplete.

Local safety checks compare canonical ingredient IDs (or exact, normalised manual names), identify duplicates across brands, retain contributing products, and flag missing, stale and conflicting information. Manual synonyms are not resolved. These checks do not establish clinical safety. A dose change is never advised.

## Existing records and calendar

1. In the existing browser app, Settings → Export all records (JSON). The browser's localStorage cannot be read directly by a native app.
2. In an empty native tracker, Settings → Import existing LIFEBLOOD archive.
3. Review imported records and confirm structured ingredients and amounts from original packs. Free-text doses are deliberately not parsed into guessed concentrations.
4. Enable native notification permission explicitly. Native reminders preserve the imported times, weekdays, dates and discontinued status. A maximum of 64 pending iOS alerts is scheduled; the app shows the actual horizon and replenishes when opened.
5. Existing browser calendar imports are untouched. Native Calendar export reconciles only native-marked events in the selected calendar and next 60 days. Review old imports to avoid duplicate alerts. Calendar export and notifications require device verification.

The original browser JSON is retained byte-for-byte, including profile, reminder/privacy settings, deleted-item logs, skipped/not-taken entries, refill/prescriber information and symptom notes. Native taken-dose history imports identifiable taken records; other historical details remain in the exportable original archive, not all in native screens. This is a preservation path, not a complete field-for-field UI migration. Native notification text is private by default. Import refuses to overwrite a nonempty tracker. Do not clear browser storage until the import and backup have been verified.

## Medical data and privacy

Settings accepts a trusted HTTPS backend URL, not an API key. Search requires consent and sends only the entered product name. `ProductService` expects `GET /products?q=…&jurisdiction=AU`, returning exact structured products with ingredient identities, amounts, basis units, sources, checked dates and missing/conflicting information. Australian products sort first. Data is displayed as text, never HTML or executable instructions. There is no mock or AI fallback. Confirm the exact product before dose entry.

Optional automatic clinical checks require separate consent. Only provider-resolved products, quantities, units, weekdays, times and as-needed flags are sent to `POST /check`; name, notes, profile, blood tests and actual logs are excluded. Any unverified or stale product blocks submission of a partial regimen. Results are invalidated on changes, validated for evidence and source links, and discarded if another check supersedes them. Missing patient details still limit personalised checking. Review the provider's privacy and licence terms before enabling.

`../server/service.py` is a configurable gateway with no production medical data. It needs a licensed medical-provider adapter, HTTPS, appropriate deployment authentication and rate limiting. No provider is configured or claimed to have been verified live. Existing web FDA research remains US general label information and is not repurposed as an Australian product or interaction engine.

## Unfinished clinical capabilities

- Automatic AU product research/autocomplete is dependent on a configured licensed adapter; search is currently explicit-submit, not keystroke autocomplete.
- Comprehensive drug/supplement/food/alcohol/absorption and therapeutic-overlap checking requires the clinical provider. Gateway fixtures are tests, not medical facts.
- No reviewed Australian/New Zealand reference-value dataset is bundled. Age/sex/pregnancy/form/scope-specific nutrient upper limits, dietary totals, medication maximum-dose comparisons and excess-intake alerts are not implemented. The UI states this rather than inventing thresholds.
- “Vitamins to consider” offers cautious assessment prompts and a valid no-additional-supplement result. It does not interpret blood tests, diagnose deficiencies, prescribe doses or automatically add suggestions. Personalised, interaction-screened recommendations are not implemented.
- No comprehensive clinical validation has occurred. Do not use this build as a substitute for pharmacist/prescriber assessment.

## Validation

`xcodebuild -project ios/Lifeblood.xcodeproj -scheme Lifeblood -destination 'platform=iOS Simulator,name=<installed iPhone>' CODE_SIGNING_ALLOWED=NO test` from repository root runs the XCTest suite. The macOS CI workflow chooses an installed iPhone automatically. Tests cover combinations, overlap, unit conversion, injection calculations, serving sizes, weekly/as-needed schedules, date bounds, unsupported coverage, stale/conflicting data, invalid sources, ambiguous formulations, missing profile data, recommendation duplication, failed provider configuration, lossless legacy retention and dose snapshots.

On Linux, Swift/Xcode are unavailable. Gateway tests and the existing browser regression suite run here; native XCTest and the full search → confirm → dose → save → safety → sources flow require the macOS CI or Xcode. On-device tests are still required for notification permission/delivery, Focus modes, background scheduling horizon, Calendar permission/export/re-export, protected file persistence and Share Sheet behaviour.
