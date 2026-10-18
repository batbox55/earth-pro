# V5 data libraries and MCP

Goal: make the new source libraries understandable by user task and usable through the existing local MCP. Scope: provider registry, bounded metadata adapters, compatible vector/scene-footprint additions, sidebar entry, MCP schemas/prompt and focused checks. Preserve existing vector catalog, map providers, saved layers and loopback authentication. No remote release or renderer replacement in this change.

Organization: Local data & utilities, Imagery & earth observation, Historical maps, Reference sources. All 31 Data libraries workbook rows retain source-row and SHA256 provenance. The 40 Code libraries are developer references, not map layers. Nine provider entries use five adapter families; 22 explicitly require source browsing/manual setup. Existing v4 vector records are unchanged because v5 did not change those sheets.

Acceptance:
1. Sidebar and MCP use the same groups, sources, access requirements and capability distinctions.
2. Listing providers is offline; live searches are explicit, bounded and cancellable. Two concurrent metadata requests, 20 search results, 2 MiB metadata limit, 15-minute result handles. Existing geometry budgets remain. OpenDataSoft interactive records cap at 100; source checks reject stale federated dataset routes before saving.
3. MCP discovers providers/collections, searches by area/date/topic, chooses numbered ArcGIS layers and adds compatible results. Search does not enable layers. References do not pretend to be directly renderable.
4. Capture dates, metadata updates and connection checks stay separate. Imagery additions are coverage footprints only; raster assets can be inspected but do not imply image rendering.
5. Added geometry persists without duplicate additions. Existing features and user library are preserved.

Verification: failing-first tests, focused fixtures, full suite with opt-in live adapter checks; real local authenticated MCP search/add/inspect and native sidebar/search-dialog checks. Evidence logs and isolated native QA state are under ~/Library/Caches/EarthPro/CatalogV5, outside the repository. Remote provider metadata is untrusted and access/terms can change. Socrata and OpenDataSoft connections retain search-area bounds; repeat the discovery search to change their area.

Completed 2026-10-18: 162 tests executed, 3 optional skips, zero failures (final-tests.log); universal Release build and strict signature verification passed (final-build.log). Live adapters returned ArcGIS datasets/layers, 7 Earth Search scenes, 4 OpenAerialMap scenes in a covered Ecuador area, Socrata candidates, and OpenDataSoft candidates with 7 loaded point geometries. Actual loopback MCP list/collections/search/layers/add_result/custom_data inspection passed. Native provider grouping and search dialog visually inspected. Installed build 8 in /Applications and launched with the original 71 saved items and provider settings retained. Source/App Store/website release not changed in this task.
