# Changelog

## Unreleased — iPhone release slice (#150)

### Included

- One universal iPhone and iPad app with phone-specific Home, reader, inspector, and tab switcher layouts.
- Continue Reading position handoff through the coordinated storage layer.
- Safari share capture through an App Group, with a 1 MiB DOM limit, URL fallback, and app-side archive creation.
- Background read-later prefetch and retention that protects opened, saved, and annotated items.
- Recent and Read Later Home Screen widgets, Lock Screen accessories, and validated App Intent/deep-link entry points.
- Local, custom-folder, and iCloud-ready coordinated storage. The iCloud entitlement remains unwired pending #149, and live Scratchpad data now follows the same coordinated storage location (#165).

### Manual verification still required

- Reader chrome taps and PDF gestures on a touch device.
- A real Safari share, including the extension-to-app payload threshold.
- A suspended-app background wake that drains the Safari capture inbox and creates the archive.
- Widget gallery and Lock Screen placement on a physical iPhone; simulator deep-link routing is covered separately.
- Real iCloud conflicts, metadata discovery, evicted downloads, and a third-party custom folder provider after iCloud cutover.
