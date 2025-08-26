# TODO

An unsorted and unorganized list of possible future fixes, research, or improvements.

- docs for using nsenter for debugging
- documentation more generally
- nebula support (or other mesh vpns)
- switch from systemd templates to static nix templating
  - big change, but should unlock a lot of these other todos
- more per-service overrides
- make having groups of (systemd) services all wrapped in the same namespace with the same (single) mesh sidecar easy or possible
  - might mean less special handling of `paperless`-like services.
- existing TODOs
  - cleanup and debugging post PrivateTmp/PrivateMounts
- TESTS!
- improve ux around config mismatches, services not enabled, etc.
- security/hardening review, tightening, etc.
- more DNS options
- udhcp cleanup or drop?
