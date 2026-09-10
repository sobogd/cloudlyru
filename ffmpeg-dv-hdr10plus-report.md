# FFmpeg, Dolby Vision and HDR10+ Dynamic Metadata — Research Report

Method note: every technical claim below is anchored to a URL I actually retrieved.
Primary sources were FFmpeg source files fetched raw from `raw.githubusercontent.com`
and `aomedia.googlesource.com` (via curl), FFmpeg's own documentation site, the FFmpeg
Trac ticket database, and the official AOM specifications. Community claims are labelled
UNCERTAIN. Where I saw a URL only in a search-result listing and could not retrieve it,
I say so explicitly rather than guessing at its content.

---

## Part A — Dolby Vision

### A1. What happens on a plain transcode (`-c:v libx264` / any re-encode)?

**Claim A1.1 — The short answer: it depends entirely on which encoder you pick.**
`-dolbyvision` is a *private per-encoder* option, present only on `libx265`, `libaom-av1`
and `libsvtav1`. It is **not** a generic `AVCodecContext` option: I read the full generic
option table and there is no `dolbyvision` entry in it.

- CERTAIN — `https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/options_table.h`
  (searched for `dolbyvision`; zero matches in the whole file).
- CERTAIN — `https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/libx265.c`:
  ```
  { "dolbyvision", "Enable Dolby Vision RPU coding", OFFSET(dovi.enable), AV_OPT_TYPE_BOOL,
    {.i64 = FF_DOVI_AUTOMATIC }, -1, 1, VE, .unit = "dovi" },
  {   "auto", NULL, 0, AV_OPT_TYPE_CONST, {.i64 = FF_DOVI_AUTOMATIC}, .flags = VE, .unit = "dovi" },
  ```
  (guarded by `#if X265_BUILD >= 167`, i.e. x265 3.5 or newer)
- CERTAIN — same block exists in
  `https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/libaomenc.c` and
  `https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/libsvtav1.c`.
- CERTAIN — `https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/libx264.c`
  contains **no** `dovi`/`dolbyvision` reference at all (grep returned nothing).

**Claim A1.2 — Therefore `ffmpeg -i dv.mp4 -c:v libx264 ...` drops the DV RPU entirely.**
x264/the H.264 encoder has no path to carry Dolby Vision metadata in FFmpeg. The RPU is
not "converted"; the output stream simply has no DV. CERTAIN by construction from A1.1
(absence of any DV code in `libx264.c`), plus the muxer will not emit a DV config record
without the side data (see A2.2).

**Claim A1.3 — Important nuance that contradicts common folklore: with `libx265`,
`libaom-av1` or `libsvtav1`, FFmpeg 7.1+ *does* preserve DV automatically by default.**
The default is `auto` = `FF_DOVI_AUTOMATIC`, documented in the header as:

> `#define FF_DOVI_AUTOMATIC -1`
> "Enable tri-state. For encoding only. `FF_DOVI_AUTOMATIC` enables Dolby Vision only if
> `avctx->decoded_side_data` contains an `AVDOVIMetadata`."

- CERTAIN — `https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/dovi_rpu.h`

So: the decode side produces `AV_FRAME_DATA_DOVI_METADATA`, and the encoder re-emits it.
FFmpeg's HEVC decoder does export it:

- CERTAIN — `https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/hevc/hevcdec.c`
  contains `ff_dovi_attach_side_data(&s->dovi_ctx, out)`,
  `AV_FRAME_DATA_DOVI_RPU_BUFFER`, `ff_dovi_rpu_parse(&s->dovi_ctx, rpu_nal->data + 2, ...)`
  and reads `AV_PKT_DATA_DOVI_CONF` from the input packet.
- CERTAIN — the encoder side then does, in `libx265.c`:
  `sd = av_frame_get_side_data(pic, AV_FRAME_DATA_DOVI_METADATA); if (ctx->dovi.cfg.dv_profile && sd) { ... ff_dovi_rpu_generate(&ctx->dovi, metadata, FF_DOVI_WRAP_NAL, ...) }`
  and warns `"Dolby Vision enabled, but received frame without AV_FRAME_DATA_DOVI_METADATA"`.
  (`FF_DOVI_WRAP_NAL = 1 << 0, ///< wrap inside NAL RBSP`,
  `FF_DOVI_WRAP_T35 = 1 << 1, ///< wrap inside T.35+EMDF` — from `dovi_rpu.h`.)

Consequence: the widely repeated statement "FFmpeg cannot preserve Dolby Vision on
re-encode" is **outdated**. It is true for `libx264` and for encoders with no DV support,
and it was true for all encoders before the DV encoder work landed (see A3/A4 for the
commit dates), but it is not true of `libx265`/`libaom-av1`/`libsvtav1` on FFmpeg ≥ 7.1.

**Claim A1.4 — What still *is* true and breaks DV in practice (CERTAIN, from source):**
- Profile 7 dual-layer: FFmpeg's `dovi_split` documentation states profile 7 carries the
  enhancement layer interleaved as `UNSPEC63` NALs and the RPU as `UNSPEC62` NALs
  (`https://ffmpeg.org/ffmpeg-bitstream-filters.html`). Re-encoding a dual-layer stream
  with a single-layer encoder cannot reconstitute the EL.
- A historical decoder limitation: Trac #9852 logs
  `[hevc @ ...] Multiple Dolby Vision RPUs found in one AU. Skipping previous.`
  (UNCERTAIN-ish but it is the ticket body — `https://trac.ffmpeg.org/ticket/9852`).
- Ticket #11150 (Dolby Vision HEVC remux corruption, closed: fixed 2024-11-22 in commit
  `5813e5aa344b8c03c83bf62e729be0f447944ed1`) shows DV handling was genuinely broken in
  2024: `https://trac.ffmpeg.org/ticket/11150`.

---

### A2. Where does the DV RPU live?

#### (a) In the HEVC bitstream — NAL units and/or ITU-T T.35 SEI

**Claim A2.1 — For single-layer DV (profiles 5, 8.x) the RPU is carried in-stream, and
FFmpeg parses it either as a dedicated NAL or as ITU-T T.35 registered user data.**
FFmpeg's T.35 dispatcher recognises Dolby as a provider and requires a specific
provider-oriented code:

- CERTAIN — `https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/itut35.h`:
  ```
  #define ITU_T_T35_COUNTRY_CODE_US 0xB5
  #define ITU_T_T35_PROVIDER_CODE_DOLBY        0x003B
  ```
- CERTAIN — `https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/itut35.c`:
  ```
  case ITU_T_T35_PROVIDER_CODE_DOLBY:
      if (bytestream2_get_bytes_left(&gb) < 4)
          return AVERROR_INVALIDDATA;
      provider_oriented_code = bytestream2_get_be32u(&gb);
      if (provider_oriented_code != 0x800)
          return 0; // ignore
      break;
  ```
  and then `ff_dovi_rpu_parse(aux->dovi, itut_t35->payload, itut_t35->payload_size, ...)`.
  This is the T.35/SEI path, i.e. **registered user data**, not "unregistered".
- CERTAIN — Trac #5688 states the NAL-level layout: comment 2 says
  "The dolby vision enhancement layer doesn't actually use NAL units 63 and 62, it uses a
  special syntax that uses 0x7E01 and 0x7C01 as separator that makes the Dolby Extension
  Layer (EL) appear as unspecified/unused NAL units (62 and 63)…", and comment 5 says
  "NAL 62 is the RPU, and NAL 63 is the EL… (Profile 5 does not have EL, so no support for
  NAL 63, only NAL 62.)" — `https://trac.ffmpeg.org/ticket/5688`.
  That ticket was **closed: fixed** on 2026-06-07.
- CERTAIN — FFmpeg's own `dovi_split` docs confirm the NAL type assignment for profile 7:
  "Profile 7 carries the enhancement-layer HEVC bitstream interleaved inside the
  base-layer access units, wrapped in user-unspecified NAL units of type 63 (UNSPEC63),
  and the RPU metadata as a sibling user-unspecified NAL of type 62 (UNSPEC62)."
  — `https://ffmpeg.org/ffmpeg-bitstream-filters.html`

So the answer to your sub-question is: **both**, depending on carriage —
profile 7 uses dedicated `UNSPEC62`/`UNSPEC63` NALs; single-layer DV can be wrapped in
ITU-T T.35 registered user data, and FFmpeg's decoder handles both.

Note on your premise "(unregistered SEI, payload type 4)": FFmpeg's code path is the
*registered* T.35 variant. I found no FFmpeg code parsing DV from an *unregistered*
user-data SEI.

#### (b) The MP4 `dvcC` / `dvvC` box — the "DOVI configuration record"

**Claim A2.2 — The configuration record lives in a `dvcC`/`dvvC` (or `dvwC`) box, a sibling
of the sample entry's codec box — not inside `hvcC`.**
CERTAIN — `https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/movenc.c`:
```c
static int mov_write_dvcc_dvvc_tag(AVFormatContext *s, AVIOContext *pb, AVDOVIDecoderConfigurationRecord *dovi)
{
    uint8_t buf[ISOM_DVCC_DVVC_SIZE];
    avio_wb32(pb, 32); /* size = 8 + 24 */
    if (dovi->dv_profile > 10)
        ffio_wfourcc(pb, "dvwC");
    else if (dovi->dv_profile > 7)
        ffio_wfourcc(pb, "dvvC");
    else
        ffio_wfourcc(pb, "dvcC");
    ff_isom_put_dvcc_dvvc(s, buf, dovi);
```
and the gating:
```c
if (dovi && mov->fc->strict_std_compliance <= FF_COMPLIANCE_UNOFFICIAL) {
    mov_write_dvcc_dvvc_tag(s, pb, (AVDOVIDecoderConfigurationRecord *)dovi->data);
} else if (dovi) {
    av_log(mov->fc, AV_LOG_WARNING, "Not writing 'dvcC'/'dvvC' box. Requires -strict unofficial.\n");
}
```
Read side (CERTAIN): `https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/mov.c`
```c
static int mov_read_dvcc_dvvc(MOVContext *c, AVIOContext *pb, MOVAtom atom)
...
{ MKTAG('d','v','c','C'), mov_read_dvcc_dvvc },
{ MKTAG('d','v','v','C'), mov_read_dvcc_dvvc },
{ MKTAG('d','v','w','C'), mov_read_dvcc_dvvc },
```
This is exactly why ticket #11193's reporter needed `-strict unofficial` to get DV written
into MP4 — `https://trac.ffmpeg.org/ticket/11193` (status: **new**).

The box is deliberately **not** `hvcC`: `hvcC` (written by `mov_write_hvcc_tag`) carries
HEVC decoder configuration; the DOVI configuration record is a separate box. FFmpeg models
it as its own side data type `AV_PKT_DATA_DOVI_CONF` (numeric value **34** in current
master, computed by me from the enum in
`https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/packet.h`).
Historical sourcing commits (CERTAIN, from the FFmpeg commit history API):
- `1483cfa81771` (2020-04-11) "lavf/mov: support dvcC/dvvC box for DOVI"
- `c0edfb514bba` / `3c3ef4159382` (2021-10-14) "support dvwC box for Dolby Vision"
- `5c16e463745e` (2022-01-01) "avformat/dovi_isom: Implement Dolby Vision configuration parsing/writing"
- `6ebe88f3a4c4` (2018-11-05) "lavf/isom: add Dolby Vision sample entry codes for HEVC and H.264"

#### (c) The `hvcC` box

**Claim A2.3 — No.** `hvcC` is the HEVC decoder configuration box; the DV config record is
in `dvcC`/`dvvC`. FFmpeg keeps them in distinct side data (`AV_PKT_DATA_DOVI_CONF` for DV,
and notably a *new* `AV_PKT_DATA_HEVC_CONF` added 2026-04-22 by commit `5f6dff5e7dbd` for
the DV enhancement layer `hvcE` box).
CERTAIN — commit list from `https://api.github.com/search/commits?q=repo:FFmpeg/FFmpeg+%22Dolby+Vision%22`;
see also `https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/movenc.c`
which writes both `mov_write_dvcc_dvvc_tag` (with `mov_write_hvce_tag` alongside it).

#### (d) AV1 — is there an equivalent?

**Claim A2.4 — Yes, but it is carried differently: as an AV1 `metadata_obu` with
`metadata_type = METADATA_TYPE_ITUT_T35`, plus a `dvcC`/`dvvC` box in ISO-BMFF.**
CERTAIN — FFmpeg's AV1 encoders wrap the RPU in T.35 and attach it as an ITU-T T.35
metadata OBU:
`https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/libaomenc.c`
```c
if ((res = ff_dovi_rpu_generate(&ctx->dovi, metadata, FF_DOVI_WRAP_T35, &t35, &size)) < 0)
    return res;
res = aom_img_add_metadata(rawimg, OBU_METADATA_TYPE_ITUT_T35, t35, size, AOM_MIF_ANY_FRAME);
```
`https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/libsvtav1.c`
```c
ret = svt_add_metadata(headerPtr, EB_AV1_METADATA_TYPE_ITUT_T35, t35, size);
```
CERTAIN — the numeric value: `OBU_METADATA_TYPE_ITUT_T35 = 4` in
`https://aomedia.googlesource.com/aom.git/+/refs/heads/main/aom/aom_codec.h`
```c
  OBU_METADATA_TYPE_AOM_RESERVED_0 = 0,
  OBU_METADATA_TYPE_HDR_CLL = 1,
  OBU_METADATA_TYPE_HDR_MDCV = 2,
  OBU_METADATA_TYPE_SCALABILITY = 3,
  OBU_METADATA_TYPE_ITUT_T35 = 4,
  OBU_METADATA_TYPE_TIMECODE = 5,
} OBU_METADATA_TYPE;
```
CERTAIN — FFmpeg's AV1 CBS can read/write that OBU:
`https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/cbs_av1_syntax_template.c`
has `FUNC(metadata_itut_t35)` writing `itu_t_t35_country_code` and
`itu_t_t35_payload_bytes`, dispatched from `case AV1_METADATA_TYPE_ITUT_T35:`.

**Claim A2.5 — `dvcC`/`dvvC` in AV1 samples: yes, and there is a dedicated MP4RA codec
tag `dav1`.**
- CERTAIN — MP4RA registration request, filed by **Dolby**, closed:
  "The desired value (typically a four-character code): `'dav1'`" …
  "Short description of the code-point's meaning: `"AV1-related Dolby Vision consistent with 'av01'"`"
  — `https://github.com/mp4ra/mp4ra.github.io/issues/101`
  (I retrieved this via `https://api.github.com/repos/mp4ra/mp4ra.github.io/issues/101`.)
- CERTAIN — FFmpeg writes the DV config box for AV1 too: `mov_write_dvcc_dvvc_tag` picks
  the fourcc purely from `dv_profile` (profile 10 → `dvvC`, since `10 > 7`), independent
  of the video codec.
- CERTAIN — FFmpeg **does not yet recognise** `dav1`:
  Trac #10862 "Register AV1-related Dolby Vision codec tag - 'dav1'", status **new**,
  `https://trac.ffmpeg.org/ticket/10862` — report shows
  `Could not find codec parameters for stream 0 (Video: none, 1 reference frame (dav1 / 0x31766164), …): unknown codec`.
  Consistent with my grep: `isom_tags.c` maps only `dvhe` for HEVC
  (`{ AV_CODEC_ID_HEVC, MKTAG('d','v','h','e') }, /* HEVC-based Dolby Vision derived from hev1 */`)
  with the note `/* dvh1 is handled within mov.c */`, and has no `dav1`
  — `https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/isom_tags.c`
- CERTAIN — FFmpeg 7.0 added "Dolby Vision profile 10 support in AV1"
  (`https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/Changelog`, `version 7.0:` section).
- CERTAIN — the AV1 ISO-BMFF binding itself does **not** define `dvcC`/`dvvC`. I read the
  full table of contents and section list of `https://aomediacodec.github.io/av1-isobmff/`
  (v1.3.0, 3 April 2024): the only optional sample-group entry is the "AV1 Metadata sample
  group entry" (`av1M`); there is no Dolby Vision box defined there. So the DV box in AV1
  files is carried as the generic visual sample entry extension, per Dolby's own spec
  (see the caveat in the sources list — the Dolby PDF URL is dead).

**Claim A2.6 — CORRECTION on your numeric premise.** `AV_PKT_DATA_DYNAMIC_HDR_PLUS` does
**not** exist. The real identifiers, computed directly from the enums in current master:
| Identifier | Value | Source |
|---|---|---|
| `AV_FRAME_DATA_DYNAMIC_HDR_PLUS` | **17** ✔ (your value was right) | `libavutil/frame.h` |
| `AV_FRAME_DATA_DOVI_METADATA` | **24** | `libavutil/frame.h` |
| `AV_FRAME_DATA_DOVI_RPU_BUFFER` | **23** | `libavutil/frame.h` |
| `AV_PKT_DATA_DOVI_CONF` | **34** | `libavcodec/packet.h` |
| `AV_PKT_DATA_DYNAMIC_HDR10_PLUS` | **36** | `libavcodec/packet.h` |
Cross-check that my enumeration is right: it reproduces the publicly documented values
`AV_FRAME_DATA_MASTERING_DISPLAY_METADATA = 11`, `AV_FRAME_DATA_CONTENT_LIGHT_LEVEL = 14`,
`AV_FRAME_DATA_ICC_PROFILE = 15`, `AV_PKT_DATA_MASTERING_DISPLAY_METADATA = 25`,
`AV_PKT_DATA_CONTENT_LIGHT_LEVEL = 27`.
Sources: `https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavutil/frame.h`,
`https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/packet.h`.

---

### A3. FFmpeg Trac tickets about Dolby Vision

Search used: Trac's own ticket search
(`https://trac.ffmpeg.org/search?q=dolby+vision&noquickjump=1&ticket=on`, pages 1–4 = 38 hits)
plus `https://trac.ffmpeg.org/search?q=dovi&noquickjump=1&ticket=on` (18 hits).

| # | Title | Status | URL |
|---|---|---|---|
| 11193 | Dolby Vision metadata not written to MPEG-TS unlike MP4 | **new** (defect) | https://trac.ffmpeg.org/ticket/11193 |
| 11150 | Issue with processing HEVC Dolby Vision | closed: **fixed** (2024-11-22, commit `5813e5aa344b`) | https://trac.ffmpeg.org/ticket/11150 |
| 10985 | Divide by zero in libavcodec/dovi_rpuenc.c:251 | closed: **fixed** | https://trac.ffmpeg.org/ticket/10985 |
| 10862 | Register AV1-related Dolby Vision codec tag - 'dav1' | **new** (enhancement) | https://trac.ffmpeg.org/ticket/10862 |
| 10585 | Seeking forward in iPhone video ends up seeking backwards | closed: **fixed** (involves "Multiple Dolby Vision RPUs found in one AU") | https://trac.ffmpeg.org/ticket/10585 |
| 10490 | HLS packaging does not preserve Dolby Vision metadata | **new** | https://trac.ffmpeg.org/ticket/10490 |
| 10257 | FFmpeg does not recognise dolby vision hevc tags | **new** | https://trac.ffmpeg.org/ticket/10257 |
| 9852 | Single TS transcoding produces incorrect results using H265 HLS | **new** | https://trac.ffmpeg.org/ticket/9852 |
| 9470 | m3u8 keepalive does not work between domains and DV + Atmos fails | **open** | https://trac.ffmpeg.org/ticket/9470 |
| 9131 | libx265 Dolby Vision options | **reopened** | https://trac.ffmpeg.org/ticket/9131 |
| 8966 | Preserve Dolby Vision metadata in mxf | **new** (enhancement) | https://trac.ffmpeg.org/ticket/8966 |
| 8632 | Remuxed iPhone MOV (HEVC) doesn't work on Apple software | **open** | https://trac.ffmpeg.org/ticket/8632 |
| 7624 | Support IPTPQc2 with chroma reshaping in Dolby Vision samples | closed: **fixed** | https://trac.ffmpeg.org/ticket/7624 |
| 7496 | Access to the reference track (dolby vision) of a stream | **new** | https://trac.ffmpeg.org/ticket/7496 |
| 7037 | ffmpeg destroys HDR metadata when encoding | **open** | https://trac.ffmpeg.org/ticket/7037 |
| 5688 | Support hevc NAL units 62 and 63 | closed: **fixed** (2026-06-07) | https://trac.ffmpeg.org/ticket/5688 |
| 11617 | heap-use-after-free in libavcodec/libaomenc.c found by AddressSanitizer | closed: **fixed** (2025-05-30, commit `8d45dc85`) | https://trac.ffmpeg.org/ticket/11617 |
| 11612 | Vulkan HEVC decode 1st frame broken | closed: **fixed** | https://trac.ffmpeg.org/ticket/11612 |
| 10644 | release/6.0 branch: build fails against lates libplacebo | closed: **worksforme** (mentions `CONFIG_DOVI_RPU 0`) | https://trac.ffmpeg.org/ticket/10644 |
| 10513 | FFmpeg makes frames with quality issues | closed: **invalid** | https://trac.ffmpeg.org/ticket/10513 |
| 10233 | Compile with libraries with MSVC | closed: **fixed** | https://trac.ffmpeg.org/ticket/10233 |
| 9145 | J2K Parser generates large (concatenated) packet when HDR metadata present | closed: **fixed** | https://trac.ffmpeg.org/ticket/9145 |
| 11036 | Videotoolbox HEVC encoding, HDR main10 profile colors corrupt | closed: **fixed** | https://trac.ffmpeg.org/ticket/11036 |

**No ticket specifically about the `dovi_rpu` bitstream filter** was surfaced by Trac search
for `dovi_rpu` (results were #10644, #10985, #11612, #11617, all incidental mentions of
`CONFIG_DOVI_RPU` / `dovi_rpuenc.c`). The BSF appears to have been added without its own
ticket — see A8 for the commit.

Verbatim from #11193 (the MP4-vs-MPEG-TS asymmetry, CERTAIN):
> "If I have an input file with a Dolby Vision video stream, it is easy to have the Dolby
> Vision metadata added to the output file if it is MP4, by adding `-strict unofficial` to it"
> … "which is good, but the same does not work for MPEG-TS"
> … "Also this is unlikely to be a MediaInfo bug, because my LG TV also does not recognize
> the output as Dolby Vision, while it does work with the one that tsMuxeR produced"

Verbatim from #11150 (CERTAIN):
> "When attempting to process video files containing HEVC Dolby Vision streams, FFMPEG
> encounters issues that result in corrupted output files." … "The problem occurs with all
> Dolby Vision profile video samples (P5, P7, P8). This issue appears to be a regression
> since commit a696b288861a09403e316f4eb33bbc7cb6c03e5c."

---

### A4. `dovi_rpu` BSF documentation and the `-dolbyvision` encoder option

**Claim A4.1 — `dovi_rpu` is documented on the official BSF page.**
CERTAIN — `https://ffmpeg.org/ffmpeg-bitstream-filters.html`, section **2.5 dovi_rpu**:
> "Manipulate Dolby Vision metadata in a HEVC/AV1 bitstream, optionally enabling metadata
> compression.
> **strip** — If enabled, strip all Dolby Vision metadata (configuration record + RPU data
> blocks) from the stream.
> **compression** — Which compression level to enable.
> 'none' No metadata compression.
> 'limited' Limited metadata compression scheme. Should be compatible with most devices.
> This is the default.
> 'extended' Extended metadata compression. Devices are not required to support this.
> Note that this level currently behaves the same as 'limited' in libavcodec."

CERTAIN — the same text is the doc source
`https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/doc/bitstream_filters.texi`
(`@section dovi_rpu`), and matches the implementation
`https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/bsf/dovi_rpu.c`:
```c
static const AVOption dovi_rpu_options[] = {
    { "strip",       "Strip Dolby Vision metadata", OFFSET(strip), AV_OPT_TYPE_BOOL, { .i64 = 0 }, 0, 1, FLAGS },
    { "compression", "DV metadata compression mode", OFFSET(compression), AV_OPT_TYPE_INT,
      { .i64 = AV_DOVI_COMPRESSION_LIMITED }, 0, AV_DOVI_COMPRESSION_EXTENDED, FLAGS, .unit = "compression" },
```
Its codec whitelist is HEVC and AV1:
```c
static const enum AVCodecID dovi_rpu_codec_ids[] = {
    AV_CODEC_ID_HEVC, AV_CODEC_ID_AV1, AV_CODEC_ID_NONE,
};
```

**Claim A4.2 — Which encoders accept `-dolbyvision`: `libx265`, `libaom-av1`, `libsvtav1`.
It is not libx265-specific.** (See A1.1 for exact source lines.)

**Claim A4.3 — `-dolbyvision` is *undocumented* in FFmpeg's manual.** I grepped the full
texinfo documentation for `dolbyvision`/`dovi`/`dolby vision`:
- `doc/ffmpeg-codecs.texi` → **no matches**
- `doc/encoders.texi` → **no matches**
- `doc/codecs.texi` → **no matches**
- `doc/bitstream_filters.texi` → matches only for `dovi_rpu` / `dovi_split`
Sources: `https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/doc/ffmpeg-codecs.texi`,
`.../doc/encoders.texi`, `.../doc/codecs.texi`, `.../doc/bitstream_filters.texi`.
So the only in-tree description is the option string
`"Enable Dolby Vision RPU coding"` in the encoder sources. The rendered libx265 section of
the codecs manual (`https://ffmpeg.org/ffmpeg-codecs.html`, section "9.20 libx265 /
9.20.1 Options" — which I confirm exists from that page's table of contents) documents
libx265's *other* options; `dolbyvision` is not among the documented ones.

**Claim A4.4 — x265's own CLI documentation describes the DV options.**
CERTAIN — `https://raw.githubusercontent.com/videolan/x265/master/doc/reST/cli.rst`:
```
.. option:: --dolby-vision-rpu <filename>

    File containing Dolby Vision RPU metadata. If given, x265's Dolby Vision
    metadata parser will fill the RPU field of input pictures with the metadata
    read from the file. The library will interleave access units with RPUs in the
    bitstream. Default NULL (disabled).

    **CLI ONLY**
```
Immediately above it, `--dolby-vision-profile` is described with:
> "Currently only profile 5, profile 8.1 and profile 8.2 enabled, Default 0 (disabled)"
The same page is rendered at `https://x265.readthedocs.io/en/master/cli.html`; note the
rendered page's own anchor `#cmdoption-dolby-vision-rpu` exists, but the rendered text of
that section was beyond the truncation point of my fetch, so I quote the reST source.
Origin of the feature (CERTAIN, x265-devel mailing list):
`https://mailman.videolan.org/pipermail/x265-devel/2018-December/012324.html` — patch
"Add support for Dolby Vision profile 8.1", with the doc diff
`- Currently only profile 5 enabled, Default 0 (disabled)` →
`+ Currently only profile 5 and profile 8.1 enabled , Default 0 (disabled)`,
and reviewer Vittorio Giovara noting "This is still wrong, the condition should be
`(param->rc.vbvMaxBitrate <= 0 && param->rc.vbvBufferSize <= 0)` since you need both
values set to something in order to have a working VBV."
Note the x265 doc explicitly marks `--dolby-vision-rpu` as **CLI ONLY** — which is exactly
why FFmpeg cannot simply forward it through `-x265-params` (see A5.2).

---

### A5. Authoritative statements that FFmpeg cannot/does not preserve DV on re-encode

This is where the evidence is genuinely mixed, and the honest answer is *"the folklore is
stale"*. Here is the evidence in both directions.

**A5.1 CERTAIN — FFmpeg's own bug tracker, #7037 "ffmpeg destroys HDR metadata when encoding".**
Status **open**, opened 2018-02-21, still open.
`https://trac.ffmpeg.org/ticket/7037` (body retrieved via
`https://trac.ffmpeg.org/ticket/7037?format=rss`).
Verbatim from the report:
> "I have a new 4k bluray with a 10 bit HDR movie and I now want to convert it to 1080p
> with x265, but keep the HDR. … While the resultsing video is indeed encoded with the
> Main10 profile, the video itself looks dull and as if the HDR information was lost.
> I notice that metadata changed." … "In my new video, these are not included any more.
> I consider this to be a BUG because I never told ffmpeg to mess with color spaces etc."
A maintainer reply in that ticket (comment 16) frames it as a real gap:
> "Adding color information to the filter chain during format negotiation in encoding
> scenarios is a huge change that no one capable of implementing has felt like doing."
This is about *static* HDR metadata (MasteringDisplay/MaxCLL/MaxFALL) primarily — the
ticket predates DV side data entirely — but it is FFmpeg's canonical "FFmpeg destroys HDR
metadata" ticket and is still open.

**A5.2 CERTAIN — Trac #9131 "libx265 Dolby Vision options" (status: reopened).**
`https://trac.ffmpeg.org/ticket/9131`. This is the key ticket for your question 4.
Verbatim from the report:
> `[libx265 @ 00000148e5ea3140] Unknown option: dolby-vision-rpu.`
> `the option dolby-vision-profile is also not used`
Reporter's repro used `-x265-params "...:dolby-vision-rpu='LA_RPU.bin':dolby-vision-profile=8.1:..."`.
Maintainer closed it as `invalid` ("This does not look like an issue that can be fixed in
the FFmpeg source code"), then a user reopened it, noting:
> "I am going to reopen this since I am sure you can hack CLI-only option somehow and we
> are planning to somehow pass RPU metadata to x265, see [changeset 54e65aa38abb37d6af92551b7e3adf6785f631ec]
> (Dolby Vision RPU data, suitable for passing to x265 or other libraries)."
And in 2023:
> "Any updates here? I also would love to have support for the
> `dolby-vision-rpu='dolby_vision.bin'` parameter directly. At least x265 supports it, but
> not ffmpeg using `-x265-params`"
This is the concrete, CERTAIN explanation of the classic failure: x265's
`--dolby-vision-rpu` is CLI-only and therefore unreachable via `-x265-params`. FFmpeg's
fix was not to forward that option but to implement RPU generation natively (A1.3/A8).

**A5.3 CERTAIN — the FFmpeg-user mailing list, 2019: the RPU was discarded.**
`https://ffmpeg.org/pipermail/ffmpeg-user/2019-December/046240.html`, Ted Park:
> "That file only has a single stream, with no enhancement layer for the dolby HDR metadata.
> It just has the base layer with the "rpu" with all of the info your TV's decoder can use,
> but are simply discarded, as far as I can tell. This is the correct behavior though…"
This is the contemporaneous correct statement — pre-2021 FFmpeg had no DV support at all.

**A5.4 CERTAIN — the dependency nature of the problem (why the ecosystem needs dovi_tool).**
x265 requires a *file* of RPUs and marks the option CLI-only; FFmpeg before 7.1 could not
supply it. Hence the extract → encode → inject workflow (A6). Also, DV RPUs are per-frame
and tied to the encoded frames, so any re-encode that changes frame count/order/cropping
invalidates them; that is why the tools exist.

**A5.5 UNCERTAIN — community/secondhand sources.** I attempted these and record their
status honestly:
- `https://forum.doom9.net/showpost.php?s=8675ef6d39d00f34225f9342d533f269&p=1987466&postcount=543`
  — RETRIEVED. Doom9 "[DDVT Tool] Dolby Vision RPU Demuxing / Injecting / Editing" thread,
  21 May 2023. Quote (about borders/RPU L5 metadata, showing the RPU must match the frame):
  > "DDVT can't letterbox a cropped .mkv file (add top and bottom black bars). It is only
  > meant for handling dynamic metadata (Dolby Vision/HDR10+). If your .mkv file is
  > 3840x1600, you should set the borders in the RPU to 0, as it originally was."
- `https://superuser.com/questions/1861730/how-can-i-transcode-a-dolby-vision-video`
  — **NOT RETRIEVED**: HTTP 403. I saw this URL and its title in search-result listings
  ("How can I transcode a Dolby Vision video?") but I did **not** read its content, so I
  make no claim based on it.
- `https://forum.makemkv.com/forum/viewtopic.php?style=3&t=26514`
  ("Dolby Vision x265 Encoding, DV Profile Advantages/Caveats?") — **NOT RETRIEVED**
  (fetch timed out). URL seen in search results only. No claim made.
- `https://lists.ffmpeg.org/pipermail/ffmpeg-devel/2025-June/344668.html`
  ("[PATCH v2 1/2] avcodec/libaom: Add HDR10+ metadata support") — **NOT RETRIEVED**:
  the host serves an Anubis proof-of-work challenge to non-browser clients. Same for
  `https://lists.ffmpeg.org/archives/list/ffmpeg-devel@ffmpeg.org/thread/3RPOTZJVYXXCEERL2DESX2BROKTOLNKF/`
  and `https://lists.mplayerhq.hu/pipermail/ffmpeg-devel/2020-April/260361.html`.
  I therefore did not quote them; I established the same facts from the git history and
  source instead, which is stronger evidence anyway.
- `https://github.com/HandBrake/HandBrake/issues/5820`
  ("Add Dolby Vision RPU.bin or Dolby Vision metadata .xml", state **open**, created
  2024-03-01) — RETRIEVED via the GitHub API
  (`https://api.github.com/repos/HandBrake/HandBrake/issues/5820`). It is a *feature
  request* asking HandBrake to accept an RPU.bin/DV XML:
  > "Is it possible to add an option that allow us to add an RPU.bin or Dolby Vision
  > metadata .xml to a HDR10 video. … So that we can encode a proper Dolby Vision Profile 5
  > or 8 video."
  UNCERTAIN as an authoritative statement (it is a user request, not a maintainer
  statement of policy), but it is strong circumstantial evidence that mainstream GUIs did
  not expose DV injection.
- **NO SOURCE FOUND** for an authoritative MakeMKV statement, and **NO SOURCE FOUND** for a
  standalone official Dolby document I could actually read (see the caveat in the URL list:
  the `dolby.com/.../dolby-vision-bitstreams-within-the-iso-base-media-file-format-v2.1.2.pdf`
  URL appears in search results but resolves to Dolby's 404 page).

**A5.6 CERTAIN — the `dovi_tool` README establishes the tool's purpose but does *not*
itself say "FFmpeg drops DV".** I read the whole README
(`https://raw.githubusercontent.com/quietvoid/dovi_tool/main/README.md`). It describes
`convert`, `demux`, `mux`, `extract-rpu`, `inject-rpu`, `remove` and RPU metadata editing,
and shows FFmpeg used only as a *pipe* to get HEVC into the tool:
```
ffmpeg -i input.mkv -c:v copy -bsf:v hevc_mp4toannexb -f hevc - | dovi_tool extract-rpu - -o RPU.bin
```
That it exists at all, and that it needs "Supports profiles 4, 5, 7, and 8" for
`extract-rpu`, is the practical evidence for the workflow in A6 — but the README contains
no explicit claim about FFmpeg dropping metadata, so I do not attribute one to it.

**A5.7 CERTAIN — the DV loss mechanism nobody mentions: cropping/rescaling invalidates L5.**
Not from a doc, but from the DDVT quote in A5.5 and from FFmpeg's `-dolbyvision` semantics:
RPUs carry canvas/border (L5) metadata, so a scale/crop filter makes the preserved RPU
wrong even when it is preserved. This is inherent to the metadata, not an FFmpeg bug.

---

### A6. Recommended workflow to preserve DV

**Canonical workflow, CERTAIN (from dovi_tool's own README, verbatim command forms):**

1. **Extract** the RPU from the source HEVC/MKV:
   `dovi_tool extract-rpu video.hevc` or `dovi_tool extract-rpu video.mkv`,
   or piped from FFmpeg:
   ```
   ffmpeg -i input.mkv -c:v copy -bsf:v hevc_mp4toannexb -f hevc - | dovi_tool extract-rpu - -o RPU.bin
   ```
   README: "Extracts Dolby Vision RPU from an HEVC file. … **Supports profiles 4, 5, 7, and 8**."
   Flags: `-l/--limit`, `-t/--track-number`. FEL→MEL example: `dovi_tool -m 1 extract-rpu video.hevc`.

2. **Re-encode** the base layer (e.g. with x265/FFmpeg). If using FFmpeg ≥ 7.1 with
   `libx265` you can rely on `-dolbyvision auto` instead of step 3 (A1.3); if using the
   x265 CLI you pass `--dolby-vision-rpu RPU.bin --dolby-vision-profile 8.1`.

3. **Inject** the RPU back:
   `dovi_tool inject-rpu -i video.hevc --rpu-in RPU.bin -o injected_output.hevc`
   README: "Interleaves RPU NAL units between slices in an HEVC encoded bitstream.
   **Global options have no effect when injecting.**" Flag: `--no-add-aud`.

Relevant RPU transformation modes (README, CERTAIN):
```
* `-m`, `--mode` Sets the mode for RPU processing.
  * Default (no mode) - Copies the RPU untouched.
  * `0` - Parses the RPU, rewrites it untouched.
  * `1` - Converts the RPU to be MEL compatible.
  * `2` - Converts the RPU to be profile 8.1 compatible.
      - Removes luma/chroma mapping for profile 7 FEL.
  * `3` - Converts profile 5 to 8.1.
  * `4` - Converts to profile 8.4.
  * `5` - Converts to profile 8.1, preserving mapping.
      - Old mode 2.
```
Plus `dovi_tool -m 2 convert --discard file.hevc` for "convert to profile 8.1 and discard EL",
and `dovi_tool mux --bl BL.hevc --el EL.hevc` to rebuild dual-layer (inverse of `demux`).

**Claim A6.1 — the FFmpeg-side equivalent now exists (CERTAIN).** Because `-dolbyvision`
defaults to `auto`, this is sufficient on FFmpeg ≥ 7.1 with a DV-capable encoder:
```
ffmpeg -i dv.mkv -c:v libx265 -x265-params ... -strict unofficial out.mkv
```
The `-strict unofficial` is needed for the MP4 muxer to emit `dvcC`/`dvvC` (A2.2, and
ticket #11193). Caveat: this only works when the RPU survives decode, so it is not
guaranteed for profile 5 (IPTPQc2 ≠ HDR10 base layer) or for profile 7 FEL reprocessing.

**Claim A6.2 — the `dovi_rpu` BSF is the in-FFmpeg way to *strip* or recompress DV.**
`-bsf:v dovi_rpu=strip=1` strips the configuration record **and** the RPU data blocks
(verbatim doc quote in A4.1). Note also the fix commit `248832dd5b79` (2024-10-15)
"avcodec/bsf/dovi_rpu: remove EL when stripping dovi metadata", whose message says:
> "When RPU is removed EL should also be removed. This only applies to HEVC as AV1 based
> Profile 10 does not support EL at all."
— `https://api.github.com/repos/FFmpeg/FFmpeg/commits?path=libavcodec/bsf/dovi_rpu.c`

---

### A7. The "hybrid Dolby Vision files lose DV metadata when re-encoded" claim

**Verdict: the claim is essentially TRUE for re-encodes, and the mechanism is understood;
but I could not find a single *authoritative* document that states it in those words.**
What I can establish from primary sources:

- CERTAIN — the technical definition of the profiles, from dovi_tool's own docs
  (`https://raw.githubusercontent.com/quietvoid/dovi_tool/main/docs/profiles.md`):
  ```
  ##### Profile 5
  `vdr_rpu_profile = 0`
  `bl_video_full_range_flag = 0`
  ##### Profile 7
  `vdr_rpu_profile = 1`
  `el_spatial_resampling_filter_flag = 1`
  `disable_residual_flag = 0`
  ##### Profile 8
  `vdr_rpu_profile = 1`
  `el_spatial_resampling_filter_flag = 0`
  ```
- CERTAIN — FFmpeg's `dovi_split` documentation confirms Profile 7 is genuinely
  dual-layer ("multi-layer HEVC bitstream", EL in `UNSPEC63`, RPU in `UNSPEC62`), and that
  `mode=bl` (the default) "drop[s] every UNSPEC63 (EL) and every UNSPEC62 (RPU). The output
  is a plain HEVC stream with no Dolby Vision markers."
  — `https://ffmpeg.org/ffmpeg-bitstream-filters.html`
- CERTAIN — FFmpeg's `dovi_rpu` BSF commit message explicitly says AV1-based Profile 10
  has no EL, i.e. EL is an HEVC-Profile-7-only construct.
- CERTAIN — dovi_tool's `-m 2` mode is documented as
  "Converts the RPU to be profile 8.1 compatible. Removes luma/chroma mapping for profile 7 FEL."
  This is the industry-standard *lossy downgrade* path: FEL → 8.1. It is a conversion, not
  a preservation, and it is the reason "hybrid" 8.1 files are ubiquitous.

So: a hybrid file (P7 MEL/FEL, or a P8.1 built by injecting RPU into an HDR10 base layer)
loses DV on re-encode unless the RPU is extracted and re-injected, **because the RPU is
per-frame metadata tied to the specific encoded frames, and for Profile 7 the EL is a
second video layer that no single-layer re-encode reproduces**. Downgrading to 8.1 with
`dovi_tool -m 2` is the accepted resolution. I could not source a verbatim sentence making
that argument in one place, so I rate the *sentence as commonly phrased* UNCERTAIN while
the *underlying mechanism* is CERTAIN.

---

### A8. Does recent FFmpeg have `dovi_rpu`? What does `strip=1` do? When was it added?

- **CERTAIN — yes.** `dovi_rpu` is registered as an FFBitStreamFilter for HEVC and AV1:
  `https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/bsf/dovi_rpu.c`
  (`const FFBitStreamFilter ff_dovi_rpu_bsf = { .p.name = "dovi_rpu", .p.codec_ids = dovi_rpu_codec_ids, ... }`).
- **CERTAIN — `strip=1` strips the configuration record *and* the RPU data blocks.**
  Verbatim doc text in A4.1. Default is `strip=0`. Since 2024-10-15 it also removes the EL.
- **CERTAIN — when it was added:** commit
  `b3d33f11fa42487ccc5acda9077dfd5a8d4af9a4`, "avcodec/bsf/dovi_rpu: add new bitstream filter",
  authored 2024-06-14, committed 2024-08-16. Message:
  > "This can be used to strip dovi metadata, or enable/disable dovi metadata compression.
  > Possibly more use cases in the future."
  Source: `https://api.github.com/repos/FFmpeg/FFmpeg/commits?path=libavcodec/bsf/dovi_rpu.c`
- **CERTAIN — first release containing it: FFmpeg 7.1.** I verified by fetching the file at
  each release tag: `n6.1` → 404, `n7.0` → 404, **`n7.1` → 200**, `n8.0` → 200, `n8.1` → 200.
  (URLs: `https://raw.githubusercontent.com/FFmpeg/FFmpeg/n7.1/libavcodec/bsf/dovi_rpu.c` etc.)
  Note: the 7.1 and 8.x sections of the Changelog do **not** list it
  (`https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/Changelog`), so the Changelog is
  not a reliable index for this feature; the source tree is.
- **CERTAIN — a second, newer BSF: `dovi_split`**, for Profile 7 multi-layer HEVC, with
  `mode` ∈ {`bl`, `bl_rpu`, `el`, `el_rpu`} (default `bl`). Commit `6026988b753e`
  (2026-05-16) "avcodec/bsf: add dovi_split BSF". Listed in the Changelog under
  `version 9.0:` as "Bitstream filter to split Dolby Vision multi-layer HEVC". Present in
  tag `n9.0`, absent in `n8.1`. Latest release line is 9.0 with `n9.1-dev` in progress.
  Sources: `https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/bsf/dovi_split.c`,
  `https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/Changelog`,
  `https://api.github.com/repos/FFmpeg/FFmpeg/tags?per_page=15`.
- **Related encoder-side availability (CERTAIN, verified per release tag):**
  `libx265` / `libaom-av1` / `libsvtav1` `"dolbyvision"` option: absent in n6.1 and n7.0,
  **present from n7.1 onward** (n7.1, n8.0, n8.1 all = present).
  Implementation commits: `39ca87ed1ef8` (2024-03-29) "avcodec/libx265: implement dolby
  vision coding", `8dea94a14642` (2024-03-22) "avcodec/libaomenc: implement dolby vision
  coding", `2f3c1e1641af` (2024-04-09) "avcodec/libsvtav1: implement dolby vision coding".
- **CERTAIN — supporting infrastructure commits:** `54e65aa38abb` (2021-11-17)
  "avutil: Add Dolby Vision RPU side data type" (this is the commit Trac #9131 points at);
  `78dc21b123e7` (2022-01-03) "lavu/frame: Add Dolby Vision metadata side data type";
  `fe0403373964` (2022-01-03) "lavc: Implement Dolby Vision RPU parsing";
  `bc68fd1050bd` "avcodec/hevcdec: Export Dolby Vision RPUs as side data" (referenced from
  Trac #5688 comment 6, `https://trac.ffmpeg.org/changeset/bc68fd1050bd82e59d8ce7da909a0bcaf2b61197/ffmpeg`);
  `89bdd9e1a507` (2026-06-03) "avcodec/hevc: look for the DOVI RPU in all NALs, not just
  the last one".
- **CERTAIN — 2026 work on proper DV enhancement-layer container support:**
  `d7c7ee4e2eec` "avformat: add AV_STREAM_GROUP_PARAMS_DOLBY_VISION",
  `199e49d9b663` "avformat/movenc: write hvcE box for Dolby Vision enhancement layer",
  `6ef1a9579f8d` "avformat/matroskaenc: write hvcE BlockAdditionMapping for Dolby Vision EL",
  `8c86d82703ae` "fate: add tests for Dolby Vision Profile 7 hvcE preservation"
  (all 2026-04-22/05-17). Source: the commit-search URL above. **This means Profile 7
  EL preservation in containers is being actively implemented right now** — an important
  thing for a "current state" report.

---

## Part B — HDR10+ (SMPTE ST 2094-40)

### B1. Where is HDR10+ dynamic metadata stored in HEVC?

**Claim B1.1 — In HEVC SEI as registered ITU-T T.35 user data, identified by country code
0xB5, terminal provider code 0x003C (Samsung), provider-oriented code 0x0001, application
identifier 0x4.** CERTAIN, from FFmpeg's parser —
`https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/itut35.c`:
```c
case ITU_T_T35_PROVIDER_CODE_SAMSUNG:
    if (bytestream2_get_bytes_left(&gb) < 3)
        return AVERROR_INVALIDDATA;
    provider_oriented_code = bytestream2_get_be16u(&gb);
    int application_identifier = bytestream2_get_byteu(&gb);

    if (provider_oriented_code != 1 || application_identifier != 4)
        return 0; // ignore
    break;
```
with, from `https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/itut35.h`:
```c
#define ITU_T_T35_COUNTRY_CODE_US 0xB5
// - US providers
#define ITU_T_T35_PROVIDER_CODE_SAMSUNG      0x003C
```
and the payload is then handed to `av_dynamic_hdr_plus_from_t35(...)`, whose output becomes
`AV_FRAME_DATA_DYNAMIC_HDR_PLUS` (see B3).

Every byte you asked about is therefore confirmed by a primary source: country code
**0xB5**, terminal provider code **0x003C**, provider oriented code **0x0001**,
application identifier **0x4**, interpreted per **CTA-861 Annex S** with **SMPTE ST 2094-40**
semantics.

Corroboration CERTAIN — the official AOM HDR10+ AV1 spec states the identical byte layout
(see B4), which is not surprising since it reuses the same T.35 structure.

**Claim B1.2 — the Wireshark-style summary is confirmed by the stale-metadata ticket.**
Trac #10541 (`https://trac.ffmpeg.org/ticket/10541`, status **new**) says verbatim:
> "AV_FRAME_DATA_DYNAMIC_HDR_PLUS (and probably few others) side data is not cleared when
> no longer signaled and returned stale last seen value. It is per frame HDR metadata and
> should no longer be attached if not present in user data."
That confirms per-frame carriage in the HEVC user-data SEI.

**Claim B1.3 — Trac #11504 documents exactly the field set you asked about, and a bug in it.**
`https://trac.ffmpeg.org/ticket/11504` (status **new**, 2025-03-11), verbatim:
> "1) Following 3 parameters are missing from corresponding struct:
> terminal_provide_code, terminal_provider_oriented_code, application_identifier.
> The AVDynamicHDRPlus struct doesn't have above three variables"
> "2) The member variable itu_t_t35_country_code is incorrectly set to 0."
This is a nice confirmation that FFmpeg's `AVDynamicHDRPlus` structurally omits the T.35
provider fields (it only stores `application_version` etc.), which is why round-tripping
HDR10+ has historically been lossy.

---

### B2. Does FFmpeg preserve HDR10+ metadata on transcode?

**Claim B2.1 — DECODE side: yes, since FFmpeg 4.4.** HDR10+ SEI is parsed and exposed as
`AV_FRAME_DATA_DYNAMIC_HDR_PLUS` frame side data.
- CERTAIN — commit `afbc6852b439` (2020-11-23) "avcodec/hevc_sei: add support for HDR10+ metadata"
  (source: `https://api.github.com/search/commits?q=repo:FFmpeg/FFmpeg+HDR10%2B+metadata`).
- CERTAIN — the side data type exists in tag `n4.4`:
  `https://raw.githubusercontent.com/FFmpeg/FFmpeg/n4.4/libavutil/frame.h` contains
  `AV_FRAME_DATA_DYNAMIC_HDR_PLUS` (grep count 1).
- CERTAIN — the HEVC SEI dispatcher reaches it: `libavcodec/h2645_sei.c` handles
  `case SEI_TYPE_USER_DATA_REGISTERED_ITU_T_T35:` and calls
  `ff_itut_t35_parse_buffer(...)` / `ff_itut_t35_parse_payload_to_struct(...)`
  (`https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/h2645_sei.c`).
- CERTAIN — parsing was later centralised in libavutil by commit `6f2413a203c7`
  (2023-03-16) "avcodec/avutil: move dynamic HDR10+ metadata parsing to libavutil", and the
  public API is `av_dynamic_hdr_plus_from_t35()` / `av_dynamic_hdr_plus_to_t35()` /
  `av_dynamic_hdr_plus_alloc()` / `av_dynamic_hdr_plus_create_side_data()`
  (`https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavutil/hdr_dynamic_metadata.h`).
  I read the implementation: `av_dynamic_hdr_plus_from_t35` starts parsing directly at
  `application_version` — i.e. it expects the 6-byte T.35 header to already have been
  consumed by the caller (`https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavutil/hdr_dynamic_metadata.c`).

**Claim B2.2 — ENCODE/transcode side: this is the weak link, and it is encoder-dependent.**
HDR10+ is not a generic passthrough. It survives only if the chosen encoder consumes
`AV_FRAME_DATA_DYNAMIC_HDR_PLUS`. I checked every relevant encoder wrapper for that symbol:
- CERTAIN — `libaomenc.c` **does** consume it (see B3/B4). ✔
- CERTAIN — `libx265.c`, `libsvtav1.c`, `nvenc.c`, `librav1e.c`, `libvvenc.c` contain **no**
  reference to `AV_FRAME_DATA_DYNAMIC_HDR_PLUS` (grep returned nothing for each).
  For libx265, HDR10+ can only come via x265's own `dhdr10-info` parameter — and note the
  SVT-AV1 feature request quotes `dhdr10-info={grading_info_hdr10_plus_metadata}` as part of
  an *x265* param string (`https://gitlab.com/AOMediaCodec/SVT-AV1/-/work_items/2132`), which
  is consistent with HDR10+ injection in x265 being an x265 feature, not an FFmpeg option.
- CERTAIN — `libx264.c` has HDR10 code (`CONFIG_LIBX264_HDR10`) but it is static-metadata
  (Mastering Display / CLL) handling, not HDR10+ dynamic metadata.
- So: re-encoding HDR10+ with `-c:v libx265`/`libsvtav1`/`nvenc` in FFmpeg will **not**
  carry the dynamic metadata through the standard side-data path; you must inject it with
  x265's own mechanism or re-inject it afterwards.

**Claim B2.3 — Relevant tickets.**
| # | Title | Status | URL |
|---|---|---|---|
| 11504 | Some of the hdr10+ sidedata parameter values are incorrect / missing | **new** | https://trac.ffmpeg.org/ticket/11504 |
| 10541 | HDR10+ not cleared between frames, stale data returned from SEI context | **new** | https://trac.ffmpeg.org/ticket/10541 |
| 8745 | When I play a HDR10+ video, it display wrong color | closed: **duplicate** | https://trac.ffmpeg.org/ticket/8745 |
| 8530 | HDR10+ metadata in nvenc and decoding support | closed: **invalid** | https://trac.ffmpeg.org/ticket/8530 |
| 7037 | ffmpeg destroys HDR metadata when encoding | **open** | https://trac.ffmpeg.org/ticket/7037 |
| 11193 | Dolby Vision metadata not written to MPEG-TS unlike MP4 (shows HDR10+ Profile B retained while DV is lost) | **new** | https://trac.ffmpeg.org/ticket/11193 |

#8530 is worth quoting because it is a maintainer/community position on HDR10+ encoder
support (UNCERTAIN as a policy statement — the ticket was closed `invalid`):
> "Google already fully wrote the code for their Google Videos and Youtube HDR10+ (works on
> Galaxy S10), and they want to submit code to us. As a whole implemenation could be too
> big, lets ask the author https://patchwork.ffmpeg.org/project/ffmpeg/patch/20200210194408.251496-1-moh.izadi@gmail.com/ to give us repo…"

---

### B3. `AV_PKT_DATA_DYNAMIC_HDR_PLUS` / `AV_FRAME_DATA_DYNAMIC_HDR_PLUS`; which encoders consume it?

**Claim B3.1 — Name correction (CERTAIN).** The *frame* type is spelled
`AV_FRAME_DATA_DYNAMIC_HDR_PLUS` (**= 17**, matching your number). The *packet* type is
spelled `AV_PKT_DATA_DYNAMIC_HDR10_PLUS` (**= 36**) — there is no
`AV_PKT_DATA_DYNAMIC_HDR_PLUS`. From
`https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/packet.h`:
```c
    /**
     * HDR10+ dynamic metadata associated with a video frame. The metadata is in
     * the form of the AVDynamicHDRPlus struct and contains
     * ...
     */
    AV_PKT_DATA_DYNAMIC_HDR10_PLUS,
```

**Claim B3.2 — when each was added (CERTAIN, verified per release tag):**
- `AV_FRAME_DATA_DYNAMIC_HDR_PLUS`: added with the HEVC SEI commit `afbc6852b439`
  (2020-11-23); present in **n4.4**.
  Source: `https://raw.githubusercontent.com/FFmpeg/FFmpeg/n4.4/libavutil/frame.h`.
- `AV_PKT_DATA_DYNAMIC_HDR10_PLUS`: **absent in n4.4, present in n5.0** and every later tag
  I checked (n5.0, n5.1, n6.0, n7.1, n8.1). It came in with commit `aca923b3653a`
  (2021-06-17) "avcodec: Pass HDR10+ metadata to packet side data in VP9 encoder".
  Sources: `https://raw.githubusercontent.com/FFmpeg/FFmpeg/n4.4/libavcodec/packet.h` (0 matches),
  `https://raw.githubusercontent.com/FFmpeg/FFmpeg/n5.0/libavcodec/packet.h` (1 match),
  commit search URL above.

**Claim B3.3 — What it does.** `AV_FRAME_DATA_DYNAMIC_HDR_PLUS` payload is an
`AVDynamicHDRPlus` (SMPTE ST 2094‑40 application 4 semantics). Verbatim from
`https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavutil/frame.h`:
> "HDR dynamic metadata associated with a video frame. The payload is an AVDynamicHDRPlus
> type and contains information for color volume transform - application 4 of SMPTE
> 2094-40:2016 standard."
It is created by the decoders (`ff_itut_t35_parse_payload_to_frame` →
`ff_frame_new_side_data_from_buf(avctx, frame, AV_FRAME_DATA_DYNAMIC_HDR_PLUS, &metadata.hdr_plus)`)
and converted to/from raw T.35 via `av_dynamic_hdr_plus_to_t35()` / `_from_t35()`.

**Claim B3.4 — Does any ENCODER consume it? YES — `libaom-av1`, and only recently.**
CERTAIN — `https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/libaomenc.c`
```c
static int add_hdr_plus(AVCodecContext *avctx, struct aom_image *img, const AVFrame *frame)
{
    // Check for HDR10+
    AVFrameSideData *side_data =
        av_frame_get_side_data(frame, AV_FRAME_DATA_DYNAMIC_HDR_PLUS);
    if (!side_data)
        return 0;
    ...
    res = aom_img_add_metadata(img, OBU_METADATA_TYPE_ITUT_T35,
                               hdr_plus_buf, hdr_plus_buf_size, AOM_MIF_ANY_FRAME);
```
and it writes the 6-byte T.35 header itself, explicitly citing the AOM spec:
```c
    // Extra bytes for the country code, provider code, provider oriented code and app id.
    const size_t hdr_plus_buf_size = payload_size + 6;
    ...
    // See "HDR10+ AV1 Metadata Handling Specification" v1.0.1, Section 2.1.
    bytestream_put_byte(&payload, ITU_T_T35_COUNTRY_CODE_US);
    bytestream_put_be16(&payload, ITU_T_T35_PROVIDER_CODE_SAMSUNG);
    bytestream_put_be16(&payload, 0x0001); // provider_oriented_code
    bytestream_put_byte(&payload, 0x04);   // application_identifier
```
**When:** commits `a28250008759` (2025-08-11) "avcodec/libaom: Add HDR10+ metadata support"
and `5e210f0552b2` "avcodec/libaom: Add test for HDR10+ metadata support"
(`https://api.github.com/search/commits?q=repo:FFmpeg/FFmpeg+HDR10%2B+metadata`).
**First release: FFmpeg 8.1.** Verified by tag: `add_hdr_plus` grep count is 0 in n7.1 and
n8.0, and **2 in n8.1**
(`https://raw.githubusercontent.com/FFmpeg/FFmpeg/n8.1/libavcodec/libaomenc.c`).
This matches the mailing-list patch thread title "[PATCH v2 1/2] avcodec/libaom: Add HDR10+
metadata support" seen in search results (I could not fetch the lists.ffmpeg.org page —
Anubis — but the merged commits are conclusive that the patch series landed).

**Claim B3.5 — Also CERTAIN: reading HDR10+ out of AV1.** Commit `d6d576505163`
(2023-03-05) "avcodec/av1dec: parse and export Metadata OBUs", and the related ML patch
titles "[PATCH] avcodec/av1dec: parse and export Metadata OBUs" and
"[PATCH 3/7] avformat/matroskadec: export Dynamic HDR10+ packet side data" (both seen in
search results). FFmpeg's `av1dec.c` calls the same T.35 dispatcher:
```c
FFITUTT35 itut35 = { .country_code = itut_t35->itu_t_t35_country_code };
ret = ff_itut_t35_parse_buffer(&itut35, itut_t35->payload, itut_t35->payload_size, ...);
ret = ff_itut_t35_parse_payload_to_frame(&itut35, &aux, avctx, frame);
```
`https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/av1dec.c`

**Claim B3.6 — no HDR10+ bitstream filter exists in FFmpeg.** I read the full BSF index of
`https://ffmpeg.org/ffmpeg-bitstream-filters.html` (40 filters, sections 2.1–2.40): there is
`dovi_rpu`, `dovi_split`, `av1_metadata`, `hevc_metadata`, `h264_metadata`, but **no**
`dynamic_hdr_plus`, `hdr10plus` or similar filter. The only relevant doc statement is a
`filter_units` example that treats dynamic HDR as SEI content to be removed:
> "To remove all prefix and suffix SEI from a HEVC stream, including Closed Captions and
> dynamic HDR: `ffmpeg -i INPUT -c:v copy -bsf:v 'filter_units=remove_types=39|40' OUTPUT`"
(UNCERTAIN caveat: SEI itself is NAL type 39/40; the individual HDR10+ message inside it
would need `hevc_metadata`-style editing, which FFmpeg does not provide.)

---

### B4. The AV1 OBU: can AV1 carry HDR10+?

**Claim B4.1 — YES, and it is fully specified by an official AOM document.**
CERTAIN — *HDR10+ AV1 Metadata Handling Specification*, v1.0.1, AOM Final Deliverable,
3 October 2023: `https://aomediacodec.github.io/av1-hdr10plus/`
(the Bikeshed source is
`https://raw.githubusercontent.com/AOMediaCodec/av1-hdr10plus/main/index.bs`, and the repo
is `https://github.com/AOMediaCodec/av1-hdr10plus` — "This is the official AOM repository
for the development of the specification for the use of AV1 and HDR10+").

Verbatim (from the `.bs` source and the rendered page):
> "**[HDR10+ metadata](...)** is placed in metadata OBUs of `metadata_type` equal to
> `METADATA_TYPE_ITUT_T35`."
> "An **HDR10+ Metadata OBU** is defined as HDR10+ Metadata carried in a Metadata OBU.
> The `metadata_type` of such Metadata OBU is set to `METADATA_TYPE_ITUT_T35` and the
> `itu_t_t35_country_code` of the corresponding Metadata ITUT T35 element is set to `0xB5`.
> The remaining syntax element of Metadata ITUT T35, `itu_t_t35_payload_bytes`, is
> interpreted using the syntax defined in Annex S of [CTA-861], starting with the
> `itu_t_t35_terminal_provider_code`, and the semantics defined in [ST-2094-40]."
> "According to the definition of the HDR10+ Metadata, the first 6 bytes of the
> `itu_t_t35_payload_bytes` of the HDR10+ Metadata OBU are set as follows:
> - `0x003C`, which corresponds to `itu_t_t35_terminal_provider_code` …
> - `0x0001`, which corresponds to `itu_t_t35_terminal_provider_oriented_code` …
> - `0x4`, which corresponds to `application_identifier` …
> - `0x1`, which corresponds to `application_mode` …"

Placement constraint (verbatim, CERTAIN):
> "for each frame with `show_frame = 1` or `show_existing_frame = 1`, there shall be one and
> only one HDR10+ metadata OBU preceding the Frame Header OBU for this frame and located
> after the last OBU of the previous frame (if any) or after the Sequence Header OBU (if
> any) or after the start of the temporal unit"
Colour config constraints (verbatim): `color_primaries = 9`, `transfer_characteristics = 16`,
`matrix_coefficients = 9`; recommendations `color_range = 0`, subsampling 0, `mono_chrome = 0`,
`chroma_sample_position = 2`.

ISOBMFF constraints (verbatim, CERTAIN) — useful because it explains why the metadata is
*not* in a sample group:
> "`AV1 Metadata sample group` defined in [AV1-ISOBMFF] shall not be used."
> "This specification requires that HDR10 Static Metadata and HDR10+ Metadata OBUs are
> unprotected."
> "An ISOBMFF file or CMAF AV1 track … should use the brand `cdm4` … in addition to the
> brand `av01`."

And the OBU type value itself: CERTAIN — `METADATA_TYPE_ITUT_T35` = **4**, from
`https://aomedia.googlesource.com/aom.git/+/refs/heads/main/aom/aom_codec.h`
(`OBU_METADATA_TYPE_ITUT_T35 = 4`). The AV1 spec page
`https://aomediacodec.github.io/av1-spec/` (v2023-05-25 internal working document; the
approved spec is the PDF at `https://aomediacodec.github.io/av1-spec/av1-spec.pdf`) has the
relevant sections "Metadata OBU syntax / Metadata ITUT T35 syntax" and
"Metadata OBU semantics / Metadata ITUT T35 semantics" in its table of contents, which I
read; the spec body was beyond the truncation point of my fetch, so the *numeric* value
above comes from libaom rather than from the spec text.

Corroborating CERTAIN fact — libaom's own decoder refuses to interpret the payload and
this is a deliberate, documented choice (commit message of `c1ddaff5b1ba`, Wan-Teh Chang,
2019-05-20):
> "Note: This function does not read `itu_t_t35_payload_bytes` because the exact syntax of
> `itu_t_t35_payload_bytes` is not defined in the spec."
> "If metadata_type is reserved for future use or a user private value, ignore the entire OBU."
Source: `https://aomedia.googlesource.com/aom.git/+/c1ddaff5b1ba046bb0fcc3b323bcc387b5e0b80c%5E%21/`

---

### B5. Does libaom-av1 support writing/reading HDR10+ metadata?

**Claim B5.1 — libaom the library: it can *carry* it, and the official AOM HDR10+ spec's
conformance suite is libaom-based, but libaom's own decoder ignores the payload by design.**
- CERTAIN (carriage): `https://aomedia.googlesource.com/aom.git/+/c1ddaff5b1ba046bb0fcc3b323bcc387b5e0b80c%5E%21/`
  shows `read_metadata_itut_t35` reading only the country code, and an explicit "ignore the
  entire OBU" rule for unknown metadata types.
- CERTAIN (official spec + conformance): the AOM HDR10+ spec points to
  `https://aomediacodec.github.io/av1-hdr10plus/conformance/` and a validator,
  "ComplianceWarden AOM AV1 HDR10+ `https://gpac.github.io/ComplianceWarden-wasm/av1hdr10plus.html`"
  (`https://raw.githubusercontent.com/AOMediaCodec/av1-hdr10plus/main/README.md`).
- CERTAIN (FFmpeg exposes writing via libaom): `add_hdr_plus()` in `libaomenc.c`
  (B3.4) proves the *encode* path exists in the library API used —
  `aom_img_add_metadata(img, OBU_METADATA_TYPE_ITUT_T35, ...)`.
- **NO SOURCE FOUND** for a dedicated libaom/AOM-issue-tracker item about HDR10+ writing.
  My searches for such issues did not return any aomedia issue URL, and I did not fetch
  `issues.aomedia.org` / `bugs.chromium.org/p/aomedia` successfully. I therefore make no
  claim about AOM bug IDs.
- Related CERTAIN issue I *did* retrieve: `https://github.com/AOMediaCodec/av1-hdr10plus/issues/5`
  ("Multi-layer coding, Metadata OBUs and extension header") — I saw this URL and title in
  search results; my HTML fetch of the repo/issue pages returned only site chrome
  (truncated), so I do not quote its contents.

**Claim B5.2 — the FFmpeg-side history of the libaom HDR10+ patch (CERTAIN, from git).**
`a28250008759` (2025-08-11) + `5e210f0552b2` (test) merged; present in **8.1**. The
mailing-list discussion ("[PATCH 1/2] avcodec/libaom: Add HDR10+ metadata support" /
"[PATCH v2 1/2] …") is at
`https://lists.ffmpeg.org/archives/list/ffmpeg-devel@ffmpeg.org/thread/3RPOTZJVYXXCEERL2DESX2BROKTOLNKF/`
— URL seen in search results, **not retrievable** (Anubis).

---

### B6. Does SVT-AV1 support HDR10+?

**Claim B6.1 — SVT-AV1 supports Dolby Vision RPU injection, but HDR10+ was still an open
feature request.**
- CERTAIN (DV, not HDR10+): FFmpeg's `libsvtav1.c` implements DV via
  `ff_dovi_rpu_generate(..., FF_DOVI_WRAP_T35, ...)` + `svt_add_metadata(headerPtr, EB_AV1_METADATA_TYPE_ITUT_T35, t35, size)`,
  and exposes `-dolbyvision` (commit `2f3c1e1641af`, 2024-04-09). See A1.1/A2.4 source URLs.
  SVT-AV1's own CLI equivalent (`--dolby-vision-rpu` / `--dolby-vision-profile`) is
  corroborated by the third-party downstream discussion
  `https://github.com/psy-ex/svt-av1-psy/discussions/47` ("Encode DoVi AV1 + HDR10+") —
  URL seen in search results; UNCERTAIN and I did not read it.
- CERTAIN (HDR10+ request, retrieved in full): SVT-AV1 GitLab work item **#2132**,
  "Featrue Request: Support HDR10Plus metadata injection":
  `https://gitlab.com/AOMediaCodec/SVT-AV1/-/work_items/2132`
  Verbatim:
  > "Hey folks, can we please get support for HDR10Plus metadata injection similar to x265
  > e.g. using ffmpeg: `x265_codec_params_hdr_10_plus = f'-x265-params "…
  > :dhdr10-info={grading_info_hdr10_plus_metadata}:dhdr10-opt=1" …'` Would be awesome to see
  > this feature, which would also make SVT-AV1 a comparable alternative to x265 if it comes
  > to HDR content processing."
  I did not retrieve a closing/merged state for this item, so: **SVT-AV1 HDR10+ injection is
  requested; I found no evidence it is implemented.** (Also note FFmpeg's `libsvtav1.c`
  contains no HDR10+ side-data handling at all — B2.2 — which is consistent.)
- Additional UNCERTAIN corroboration (URLs seen in search results only, not read):
  `https://gitlab.com/AOMediaCodec/SVT-AV1/-/work_items.atom?...label_name[]=Open to Contributions...`
  listing "SVT-AV1 work items", and
  `https://github.com/staxrip/staxrip/issues/1874` "SVT-AV1 with mp4box misses Dolby Vision metadata".

---

## Summary of the surprising/corrective findings

1. **"FFmpeg can't preserve DV on re-encode" is obsolete.** Since FFmpeg **7.1**,
   `-dolbyvision` (default `auto` = `FF_DOVI_AUTOMATIC`) on `libx265`, `libaom-av1` and
   `libsvtav1` re-emits RPU metadata exported by the decoder. It is still true for
   `libx264` and for all FFmpeg ≤ 7.0.
2. **`-dolbyvision` is a private per-encoder AVOption, not a generic one, and it is
   undocumented** in `ffmpeg-codecs.html`/`encoders.texi`. Only `dovi_rpu` and
   `dovi_split` are in `bitstream_filters.texi`.
3. **`AV_PKT_DATA_DYNAMIC_HDR_PLUS` does not exist** — the correct name is
   `AV_PKT_DATA_DYNAMIC_HDR10_PLUS` (value 36). `AV_FRAME_DATA_DYNAMIC_HDR_PLUS` = 17 is correct.
4. **HDR10+ *can* survive an FFmpeg transcode, but only to libaom-av1 in FFmpeg 8.1+**;
   it needs `-strict unofficial` to reach the MP4 DV box, and separate handling otherwise.
5. **AV1 has a first-class, officially specified HDR10+ carrier** (`metadata_obu` with
   `METADATA_TYPE_ITUT_T35` = 4, country code 0xB5) — the AOM *HDR10+ AV1 Metadata Handling
   Specification* v1.0.1 — and AV1 Dolby Vision has a registered MP4RA codec tag `dav1`
   ("AV1-related Dolby Vision consistent with 'av01'") which FFmpeg still rejects (ticket #10862).
6. **Profile 7 EL container support is being actively implemented in FFmpeg right now**
   (hvcE box / BlockAdditionMapping / `AV_STREAM_GROUP_PARAMS_DOLBY_VISION`, April–May 2026).

---

## Every URL I actually retrieved (fetched, or read via curl/API)

**FFmpeg documentation (rendered)**
- https://ffmpeg.org/ffmpeg-bitstream-filters.html
- https://ffmpeg.org/ffmpeg-codecs.html

**FFmpeg source (raw.githubusercontent.com, FFmpeg/FFmpeg master unless a tag is named)**
- .../master/libavcodec/options_table.h
- .../master/libavcodec/libx265.c
- .../master/libavcodec/libx264.c
- .../master/libavcodec/libaomenc.c
- .../master/libavcodec/libsvtav1.c
- .../master/libavcodec/nvenc.c
- .../master/libavcodec/librav1e.c
- .../master/libavcodec/libvvenc.c
- .../master/libavcodec/hevcdec.c  *(404 — file moved)*
- .../master/libavcodec/hevc/hevcdec.c
- .../master/libavcodec/hevc/sei.c
- .../master/libavcodec/hevc/parse.c
- .../master/libavcodec/hevc_sei.c  *(404 — moved to h2645_sei.c)*
- .../master/libavcodec/h2645_sei.c
- .../master/libavcodec/h2645_sei.h
- .../master/libavcodec/itut35.h
- .../master/libavcodec/itut35.c
- .../master/libavcodec/dovi_rpu.h
- .../master/libavcodec/dovi_rpu.c
- .../master/libavcodec/av1dec.c
- .../master/libavcodec/cbs_av1.h
- .../master/libavcodec/cbs_av1_syntax_template.c
- .../master/libavcodec/bsf/dovi_rpu.c
- .../master/libavcodec/bsf/dovi_split.c
- .../master/libavcodec/bsf/av1_metadata.c
- .../master/libavcodec/packet.h
- .../master/libavutil/frame.h
- .../master/libavutil/hdr_dynamic_metadata.h
- .../master/libavutil/hdr_dynamic_metadata.c
- .../master/libavformat/movenc.c
- .../master/libavformat/mov.c
- .../master/libavformat/isom.c
- .../master/libavformat/isom_tags.c
- .../master/Changelog
- .../master/doc/bitstream_filters.texi
- .../master/doc/ffmpeg-codecs.texi
- .../master/doc/encoders.texi
- .../master/doc/codecs.texi
- Tag checks: `.../n4.4/libavutil/frame.h`, `.../n4.4/libavcodec/packet.h`,
  `.../n5.0/libavcodec/packet.h`, `.../n5.1/libavcodec/packet.h`, `.../n6.0/libavcodec/packet.h`,
  `.../n7.1/libavcodec/packet.h`, `.../n8.1/libavcodec/packet.h`,
  `.../n6.1|n7.0|n7.1|n8.0|n8.1/libavcodec/bsf/dovi_rpu.c`,
  `.../n9.0|n9.1/libavcodec/bsf/dovi_split.c`,
  `.../n6.1|n7.0|n7.1|n8.0|n8.1/libavcodec/{libx265,libaomenc,libsvtav1}.c`

**FFmpeg GitHub API (curl)**
- https://api.github.com/repos/FFmpeg/FFmpeg/commits?path=libavcodec/bsf/dovi_rpu.c&per_page=100
- https://api.github.com/repos/FFmpeg/FFmpeg/commits?path=libavcodec/bsf/dovi_split.c&per_page=20
- https://api.github.com/repos/FFmpeg/FFmpeg/contents/libavcodec
- https://api.github.com/repos/FFmpeg/FFmpeg/contents/libavcodec/bsf
- https://api.github.com/repos/FFmpeg/FFmpeg/contents/libavcodec/hevc
- https://api.github.com/repos/FFmpeg/FFmpeg/contents/libavformat
- https://api.github.com/repos/FFmpeg/FFmpeg/tags?per_page=15
- https://api.github.com/search/commits?q=repo:FFmpeg/FFmpeg+HDR10%2B+metadata
- https://api.github.com/search/commits?q=repo:FFmpeg/FFmpeg+%22Dolby+Vision%22
- https://api.github.com/search/commits?q=repo:FFmpeg/FFmpeg+Dolby+Vision+profile+10
- https://api.github.com/search/commits?q=repo:FFmpeg/FFmpeg+dovi_rpu
- https://api.github.com/search/commits?q=repo:FFmpeg/FFmpeg+strip+DOVI+config+record+for+AV1 *(+ the two other query variants above)*

**FFmpeg Trac**
- https://trac.ffmpeg.org/ticket/7037 and https://trac.ffmpeg.org/ticket/7037?format=rss
- https://trac.ffmpeg.org/ticket/5688
- https://trac.ffmpeg.org/ticket/9131
- https://trac.ffmpeg.org/ticket/10862
- https://trac.ffmpeg.org/ticket/10490
- https://trac.ffmpeg.org/ticket/11150
- https://trac.ffmpeg.org/ticket/11193
- https://trac.ffmpeg.org/ticket/11504
- https://trac.ffmpeg.org/ticket/10541
- https://trac.ffmpeg.org/ticket/11617
- https://trac.ffmpeg.org/search?q=dolby+vision&noquickjump=1&ticket=on  (pages 1, 2, 3, 4)
- https://trac.ffmpeg.org/search?q=dovi&noquickjump=1&ticket=on  (pages 1, 2)
- https://trac.ffmpeg.org/search?q=hdr10%2B&noquickjump=1&ticket=on
- https://trac.ffmpeg.org/search?q=dovi_rpu&noquickjump=1&ticket=on
- https://trac.ffmpeg.org/changeset/54e65aa38abb37d6af92551b7e3adf6785f631ec/ffmpeg  *(redirected to git.ffmpeg.org, not followed)*
- https://trac.ffmpeg.org/changeset/1483cfa8177176b3d5d1c611424058bb9b59cf9f/ffmpeg  *(same)*

**FFmpeg mailing lists**
- https://ffmpeg.org/pipermail/ffmpeg-user/2019-December/046240.html
- https://lists.ffmpeg.org/pipermail/ffmpeg-devel/2025-June/344668.html *(Anubis-blocked)*
- https://lists.ffmpeg.org/archives/list/ffmpeg-devel@ffmpeg.org/message/A5CAOJJLYK34VYSIG2YJJ6QAVPXTNPKV/ *(Anubis-blocked)*
- https://lists.mplayerhq.hu/pipermail/ffmpeg-devel/2020-April/260361.html *(Anubis-blocked)*

**AOM / AV1 / AV1-ISOBMFF / HDR10+**
- https://aomediacodec.github.io/av1-spec/
- https://aomediacodec.github.io/av1-isobmff/
- https://aomediacodec.github.io/av1-hdr10plus/
- https://raw.githubusercontent.com/AOMediaCodec/av1-hdr10plus/main/README.md
- https://raw.githubusercontent.com/AOMediaCodec/av1-hdr10plus/main/index.bs
- https://github.com/AOMediaCodec/av1-hdr10plus
- https://aomedia.googlesource.com/aom.git/+/refs/heads/main/aom/aom_codec.h?format=TEXT
- https://aomedia.googlesource.com/aom.git/+/refs/heads/main/av1/common/enums.h (+ ?format=TEXT)
- https://aomedia.googlesource.com/aom.git/+/refs/heads/main/{av1/common/obu_util.h,av1/decoder/obu.h,av1/common/av1_common_int.h}?format=TEXT
- https://aomedia.googlesource.com/aom.git/+/c1ddaff5b1ba046bb0fcc3b323bcc387b5e0b80c%5E%21/
- https://raw.githubusercontent.com/AOMediaCodec/libaom/main/av1/common/enums.h *(404)*
- https://github.com/AOMediaCodec/av1-isobmff/issues/131 *(fetched; only site chrome returned)*

**dovi_tool / hdr10plus_tool / x265**
- https://github.com/quietvoid/dovi_tool
- https://raw.githubusercontent.com/quietvoid/dovi_tool/main/README.md
- https://raw.githubusercontent.com/quietvoid/dovi_tool/main/docs/profiles.md
- https://github.com/quietvoid/dovi_tool/discussions/78 *(fetched; only site chrome returned)*
- https://raw.githubusercontent.com/quietvoid/hdr10plus_tool/main/README.md
- https://raw.githubusercontent.com/quietvoid/hdr10plus_tool/main/README.md
- https://x265.readthedocs.io/en/master/cli.html
- https://x265.readthedocs.io/en/master/_sources/cli.rst.txt
- https://raw.githubusercontent.com/videolan/x265/master/doc/reST/cli.rst
- https://mailman.videolan.org/pipermail/x265-devel/2018-December/012324.html

**MP4RA / Matroska / other**
- https://github.com/mp4ra/mp4ra.github.io/issues/101
- https://api.github.com/repos/mp4ra/mp4ra.github.io/issues/101
- https://api.github.com/repos/HandBrake/HandBrake/issues/5820
- https://github.com/HandBrake/HandBrake/issues/5820
- https://gitlab.com/AOMediaCodec/SVT-AV1/-/work_items/2132
- https://raw.githubusercontent.com/ietf-wg-cellar/matroska-specification/master/codec_specs.md *(no dvcC matches)*
- https://datatracker.ietf.org/doc/html/draft-ietf-cellar-codec-19 *(seen in search results; not fetched)*
- https://forum.doom9.net/showpost.php?s=8675ef6d39d00f34225f9342d533f269&p=1987466&postcount=543

**Attempted and FAILED (so their content is NOT used):**
- https://www.dolby.com/us/en/technologies/dolby-vision/dolby-vision-bitstreams-within-the-iso-base-media-file-format-v2.1.2.pdf
  → redirects to `https://www.dolby.com/404`. The URL exists in search results; the document
  is no longer served there. **I have no readable Dolby ISOBMFF document, so no claim in this
  report rests on it.**
- https://superuser.com/questions/1861730/how-can-i-transcode-a-dolby-vision-video → HTTP 403
- https://forum.makemkv.com/forum/viewtopic.php?style=3&t=26514 → fetch timed out
- All `lists.ffmpeg.org` / `lists.mplayerhq.hu` pipermail pages → Anubis proof-of-work

---

## Search queries I ran

FFmpeg / Dolby Vision:
1. `ffmpeg trac dolby vision RPU`
2. `ffmpeg dovi_rpu bitstream filter`
3. `ffmpeg dolby vision profile 5 lose metadata transcode`
4. `dovi_tool extract-rpu inject-rpu workflow`
5. `ffmpeg trac ticket dolby vision`
6. `ffmpeg trac dovi rpu bitstream filter ticket`
7. `ffmpeg ticket dolby vision profile 5`
8. `ffmpeg -dolbyvision libx265 option`
9. `trac.ffmpeg.org ticket "Dolby Vision"`
10. `ffmpeg-devel mailing list Dolby Vision RPU preserve transcode`
11. `doom9 ffmpeg dolby vision rpu lost re-encode`
12. `reddit r/ffmpeg dolby vision ffmpeg re-encode lose`
13. `x265 --dolby-vision-rpu --dolby-vision-profile documentation 8.1 5.0`
14. `x265 dolby-vision-rpu option add version changelog`
15. `Dolby Vision streams within the ISOBMFF document`
16. `"Dolby Vision streams within the ISO base media file format" dvcC dvvC AV1`
17. `Dolby Vision AV1 profile 10 dvcC box dolby document`
18. `Dolby Vision bitstreams within the ISO base media file format pdf ott.dolby.com`
19. `MakeMKV Dolby Vision support forum re-encode loses DV`
20. `HandBrake does not support Dolby Vision github issue`
21. `reddit ffmpeg dolby vision re-encode loses DV profile 8.1 hybrid`
22. `doom9 ffmpeg dolby vision RPU inject x265 re-encode`
23. `reddit r/ffmpeg dolby vision lost after re-encode x265 rpu`
24. `doom9 forum ffmpeg dolby vision transcode rpu drop`
25. `site:forum.makemkv.com dolby vision ffmpeg re-encode`
26. `ffmpeg drops dolby vision rpu hdr10 fallback re-encode`
27. `makemkv forum Dolby Vision profile 8 hybrid re-encode ffmpeg`
28. `dovi_tool hybrid dolby vision profile 7 FEL re-encode x265`
29. `hybrid dolby vision profile 8.1 re-encode loses metadata`
30. `Makemkv forum Dolby Vision re-encode loses DV profile 7 FEL`

HDR10+ / AV1:
31. `ffmpeg hdr10+ sei dynamic metadata trac`
32. `AV_PKT_DATA_DYNAMIC_HDR_PLUS ffmpeg`
33. `AV1 metadata_obu metadata_itu_t_t35 HDR10+`
34. `libaom hdr10+ metadata_obu issue`
35. `trac.ffmpeg.org HDR10+ dynamic metadata`
36. `ffmpeg devel patch HDR10+ metadata libx265`
37. `AV1 dav1d dvcC dvvC Dolby Vision ISOBMFF`
38. `METADATA_TYPE_ITUT_T35 value 4 av1 metadata obu itu_t_t35_country_code`
39. `av1 spec metadata_obu metadata_type METADATA_TYPE_ITUT_T35 syntax`
40. `libaom metadata_obu itu_t_t35 hdr10plus github issue`
41. `SVT-AV1 hdr10plus issue github`
42. `HDR10+ SEI payload type 4 T.35 country code 0xB5 terminal provider 0x003C 0x0001`
43. `SMPTE ST 2094-40 application identifier 0x0001 provider oriented code`
44. `aomedia issue tracker hdr10+ metadata OBU`
45. `issues.aomedia.org hdr10plus`
46. `SVT-AV1 hdr10plus metadata support github issue`
47. `libaom AV1 encoder HDR10+ T.35 metadata writing support`

(Also, I used FFmpeg Trac's own in-site ticket search with the queries `dolby vision`, `dovi`,
`hdr10+`, `dovi_rpu` — those URLs are in the fetched-URL list above.)
