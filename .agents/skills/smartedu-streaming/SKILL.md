---
name: smartedu-streaming
description: Verified facts about basic.smartedu.cn (国家中小学智慧教育平台) streaming, auth, catalog and PDF APIs — HLS key dance with worked example, X-ND-AUTH header, CDN node failover, token refresh, and catalog endpoints. Use when debugging playback, the local proxy, login, or catalog loading in huichuang_basic, or when re-verifying changed platform behavior.
---

# smartedu-streaming — verified platform facts

All facts below were verified live against basic.smartedu.cn (2026-08). If the
platform misbehaves, re-verify with curl/browser **before** changing code, then
update this file.

## Video streaming pipeline

Lesson resource detail (public, no auth):

```
GET https://s-file-1.ykt.cbern.com.cn/zxx/ndrv2/national_lesson/resources/details/{resId}.json
→ .relations.national_course_resource[0].ti_items[0].ti_storages[0..2]
```

`ti_storages` are HLS m3u8 URLs on `r1|r2|r3-ndr-private.ykt.cbern.com.cn`
(2–3 mirrors of the same content). The same JSON embeds a jpg cover.

### Playlist shape

HLS v3, VOD, ~10s TS segments:

```
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-KEY:METHOD=AES-128,URI="https://ndvideo-key.ykt.eduyun.cn/v1/resource_keys/{keyId}",IV=0x00000000000000000000000000000000
#EXTINF:10.0,
seg-001.ts
...
```

Segments are AES-128-CBC with zero IV; they can be fetched with or without
auth (send the header anyway).

### Auth header

Every private request needs `X-ND-AUTH: {access_token}` (the raw token, no
prefix — verified 200; without it → 401).

### Key dance (the critical bit)

1. `GET {keyUri}/signs` + `X-ND-AUTH` → `{"nonce": "..."}`
2. `sign = md5(nonce + keyId).hexdigest()[0:16]` — 16 ASCII chars
3. `GET {keyUri}?nonce={nonce}&sign={sign}` + `X-ND-AUTH` → `{"key": "<base64>"}`
4. real 16-byte key = `AES-128-ECB-decrypt(base64(key), key=sign UTF-8 bytes,
   PKCS7-unpad)` → 16 ASCII chars.

Worked example (from real traffic, byte-verified):

```
nonce  = "6a3f..."  keyId = "43bc6fe335b84b37..."  (keyId is also the last
path segment of keyUri)
sign   = md5(nonce + keyId).hex()[:16]
wrapped = server base64 → ECB decrypt with sign → "43bc6fe335b84b37"
```

The unwrapped ASCII key + zero IV decrypt the TS segments (verified: decrypted
TS = h264 1920x1080 + AAC via ffprobe). `lib/src/stream/key_vault.dart`
implements this; `test/stream_test.dart` has byte-level fixtures.

### MAC-style auth (fallback only — raw token already works)

`X-ND-AUTH: MAC id="{access_token}",nonce="{nonce}",mac="{sig}"` where
`sig = HMAC-SHA256-base64(mac_key, "{nonce}\n{METHOD}\n{unquoted_path_with_query}\n{host}\n")`.

### Why official web playback fails — and the fix

videojs/hls.js + MSE is fragile against this CDN/key setup. The fix used here:
native mpv (media_kit) + a local proxy (`lib/src/stream/proxy.dart`) that
rewrites the playlist to point at itself, injects `X-ND-AUTH` upstream,
performs the key dance in-process, and fails over r1→r2→r3 with retries.

## Auth

- Login: official page in a WebView; poll localStorage key
  `ND_UC_AUTH-e5649925-441d-4a53-b525-51a2f1c4e0a8&ncet-xedu&token`
  = `{"value": "<json>", "expire": ...}`. Inner json fields used:
  `access_token`, `refresh_token`, `expires_at`, `user_id`, `mac_key`.
  Slider captcha must be completed by the human user.
- Refresh (verified 201, no auth header; **rotates refresh_token**, ~7-day
  rolling validity):
  `POST https://uc-gateway.ykt.eduyun.cn/v1.1/tokens/{refresh_token}/actions/refresh`
- Profile: `GET https://uc-gateway.ykt.eduyun.cn/v1.1/users/{user_id}?with_ext=true&session_id={access_token}`
- Browsing works logged-out; video playback and PDF require login.

## Catalog (public static JSON, hosts s-file-1 / s-file-2.ykt.cbern.com.cn)

Dual mirrors: try s-file-1 then s-file-2 on failure.

- Tag tree (courses): `zxx/ndrs/tags/national_lesson_tag.json`
  → `hierarchies[0].children[]`; node shape `{tag_id, tag_name, hierarchies:[{children:[]}]}`.
  Dimensions in order: `zxxxd` 学段 → `zxxnj` 年级 → `zxxxk` 学科 → `zxxbb` 版本
  → `zxxcc` 册次 → `zxxxjjc` 新旧教材.
- All materials: `zxx/ndrs/national_lesson/teachingmaterials/part_{100,101,102}.json`
  (array; each item has `id`, `title`, `tag_list[]` with
  tag_dimension_id/tag_id/tag_name).
- Material details: `zxx/ndrs/national_lesson/teachingmaterials/details/{tmId}.json`
- Chapter tree: `zxx/ndrv2/national_lesson/trees/{tmId}.json` — root is an
  **array**, children under `child_nodes`; lessons attach via their
  `chapter_ids` (use `.last` for the leaf chapter).
- Lessons per material: `zxx/ndrs/national_lesson/teachingmaterials/{tmId}/resources/part_100.json`
- Related resources: `zxx/ndrs/national_lesson/resources/{resId}/relation_resource.json`
- **吟唱 (singing) lessons**: the per-material lesson list also contains
  non-课程包 entries (e.g. 浪淘沙（其七）, `origin_type: 吟唱`) whose
  `custom_properties.prom_resouce_type` is `assets_video` — they are
  standalone videos. Their details **403 on the national_lesson path**
  but are public under a parallel family (verified 2026-08-27, real
  fixture `test/fixtures/singing_detail.json`):
  detail `zxx/ndrv2/singing/resources/details/{resId}.json`
  (root `ti_items[]`: m3u8 mirrors + jpg cover, same r{1,2,3}-ndr-private
  HLS + key dance as normal lessons); the site plays them at
  `/syncClassroom/detail?resourceId=…&resourceType=singing`.
  App: `SmarteduClient.getResourceDetail` falls back to the singing
  endpoint on failure; `Lesson.isVideoLike` uses prom_resouce_type.
- Stats API (`x-api.ykt.eduyun.cn/proxy/cloud/v1/res_stats/...`): **abandoned**
  (TENANT param errors, non-essential). Do not use.

## PDF textbooks (e-textbooks)

- Tag tree: `zxx/ndrs/tags/tch_material_tag.json` — root layer is a container
  ("电子教材"); real stages are one level down in `children`.
- List: `zxx/ndrs/resources/tch_material/part_{100,101,102,103}.json`
- Versions: `zxx/ndrs/resources/tch_material/version/data_version.json`
  (module_version cache busting).
- Detail: `zxx/ndrv2/resources/tch_material/details/{contentId}.json`
  → `ti_items[]` (pick `ti_is_source_file==true`; `ti_format=="pdf"`,
  `ti_size` ≈ 10–40 MB scanned textbook). Real file lives INSIDE a `.pkg`
  container path: `cs_path:${ref-path}/edu_product/esp/assets/{id}.pkg/{ISBN}_{书名}_{ts}.pdf`
  (expand prefix to `https://r1-ndr-private.ykt.cbern.com.cn`), mirrored on
  r1/r2/r3. The served bytes are a plain PDF — no decryption needed
  (verified by tchMaterial-parser, MIT; downloads open in standard viewers).
- Chapter→page bookmarks (unimplemented here, per tchMaterial-parser):
  `ti_items[].ti_file_flag=="ebook_mapping"` → `{pkg-base}/ebook_mapping.txt`
  (JSON: `ebook_id`, `mappings[].{node_id,page_number}`, X-ND-AUTH per URL) +
  tree `zxx/ndrv2/national_lesson/trees/{ebook_id}.json`.
- pdfrx gotcha: `PdfDocumentRefUri(url, preferRangeAccess: true)` parses the
  xref in ~0.5 s but page-object block reads through the local proxy went
  blank (no error). Full-download default (pdfrx disk cache) renders fine —
  keep range access OFF for these PDFs.
- Other content type endpoints (from tchMaterial-parser, MIT):
  quality_course → `/zxx/ndrv2/resources/{id}.json`;
  prepare → `/zxx/ndrv2/prepare_sub_type/resources/details/{id}.json`;
  fallback → `/zxx/ndrs/special_edu/resources/details/{id}.json`.

## Search

`POST https://x-search.ykt.eduyun.cn/v1/search/resources/combine/aggregate` is
blocked by the nd-trust-zone WAF: direct curl/python dies on TLS/IP
fingerprint; even an in-page fetch from a logged-in browser session fails;
only the site's own XHR (with MAC signature headers) succeeds. **Do not retry
remote search.** The app uses a local index over materials + textbooks +
loaded lessons, with an "open official search in browser" fallback.
