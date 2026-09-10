# FFmpeg and sidecar / proprietary metadata tracks

**Scope:** which auxiliary data survives a transcode pipeline such as

```
ffmpeg -i input.mp4 -map 0:v:0 -map 0:a? -c:v libsvtav1 -crf 36 -cpu-used 8 -c:a copy output.mp4
```

**Evidence rules used:** every claim carries a URL I actually fetched (with `web_fetch`, or `curl` for
files that the fetch tool truncated/blocked), or is an explicit **local experiment** that I ran on
FFmpeg 8.1.2 (Homebrew, macOS) and label as such. Where I could not find a source I write
**no source found** instead of guessing. Claims are marked **CERTAIN** (primary source and/or
reproduced locally) or **UNCERTAIN** (single secondary source, user report, or inference).

---

## 0. Bottom line for the pipeline in question

| Payload | In a GoPro/iPhone/Insta360 MP4 | Survives `-map 0:v:0 -map 0:a? -c:v … -c:a copy`? |
|---|---|---|
| GoPro GPMF telemetry (`gpmd` track) | separate timed data track | **No — silently dropped** (not even a warning) |
| GoPro `tmcd` timecode track | separate data track | Not copied; FFmpeg instead **synthesises a fresh `tmcd`** track for the output video |
| GoPro `fdsc`/SOS track | separate data track | Dropped |
| MV-HEVC second view (Apple spatial video) | 2nd layer inside the same HEVC stream | **No — only the base view is decoded/encoded** (`vidx:0` default) |
| `vexu` / `st3d` / `sv3d` 3D + spherical metadata | boxes in the video track | Depends on side data; partial only (see C1/C2) |
| DJI `djmd` / `dbgi` telemetry | separate timed data tracks | Dropped; and FFmpeg has **no** `djmd`/`dbgi` support at all |
| Insta360 INSV proprietary tracks | inside an MP4-style container | No FFmpeg support for the proprietary parts |
| Samsung/Google motion photo video | MP4 appended to a JPEG | Invisible to FFmpeg (only the still JPEG is seen) |
| Ultra HDR gain map | second JPEG appended via MPF + GContainer XMP | **No support in FFmpeg at all** |
| AmbiX/FoA audio (4ch ACN/SN3D) | channel mapping of the audio codec | `-c:a copy` keeps it; re-encoding to Opus **fails outright** unless `-mapping_family 2` is set |

The critical, reproducible fact for the parent's pipeline: on a real GoPro file the `gpmd` track is
**gone** after that command, and the "obvious" fix `-map 0` **does not work** either — it aborts the
whole transcode with `Could not find tag for codec none in stream #2`.

---

## A) GoPro GPMF telemetry (`gpmd` track)

### A1. What is GPMF (and where is the official spec?)

- **CERTAIN** — GPMF = "GoPro Metadata Format or General Purpose Metadata Format".
  Verbatim: *"GPMF -- GoPro Metadata Format or General Purpose Metadata Format -- is a modified Key,
  Length, Value solution, with a 32-bit aligned payload, that is both compact, full extensible and
  somewhat human readable in a hex editor."*
  <https://raw.githubusercontent.com/gopro/gpmf-parser/main/README.md>
- **CERTAIN** — Official reference implementation / documentation repo:
  <https://github.com/gopro/gpmf-parser> (description: "Parser for GPMF™ formatted telemetry data
  used within GoPro® cameras.")
- **CERTAIN** — The GPMF introduction text also lives in the repo's `docs/` folder (GitHub Pages
  copy), 44,005 bytes, identical opening section:
  <https://raw.githubusercontent.com/gopro/gpmf-parser/main/docs/README.md>
  Confirmed to exist via <https://api.github.com/repos/gopro/gpmf-parser/contents/docs>.
- **CERTAIN** — The writer library's README explicitly defers the format description to gpmf-parser:
  *"The GPMF-parser readme contains an explanation of the GPMF structure."*
  <https://raw.githubusercontent.com/gopro/gpmf-write/main/README.md>
- **NO SOURCE FOUND — there is no standalone "GPMF Specification" PDF.** I enumerated every public
  repo in the GoPro GitHub organisation (`https://api.github.com/orgs/gopro/repos?per_page=100`) and
  the only GPMF-related repos are `gpmf-parser` and `gpmf-write`; the only GPMF documents in
  `gpmf-parser` are `README.md` and `docs/README.md` (plus `samples/SAMPLES.md`). Targeted web
  searches for a "GPMF Specification" PDF returned only these READMEs, mirrors and blog posts. The
  Trek View tutorial likewise treats the README as "the full GPMF specification"
  (<https://www.trekview.org/blog/injecting-camm-gpmd-telemetry-videos-part-5-gpmf/>). Treat
  `gpmf-parser/README.md` as the authoritative spec text.

### A2. How GPMF is carried in MP4

GoPro calls it a **`meta` track whose sample description is `gpmd`** — not `tmcd`. `tmcd` is a
*separate* timecode track.

**CERTAIN** — verbatim, `## MP4 Implementation` in the gpmf-parser README
(<https://raw.githubusercontent.com/gopro/gpmf-parser/main/README.md>):

> *"GPMF data is stored much like every other media track within the MP4, where the indexing and
> offsets are presented in the MP4 structure, not the data payload. GPMF storage is most similar to
> PCM audio, as it contains RAW uncompressed sensor data…"*

> *"Telemetry carrying MP4 files will have a minimum of four tracks: Video, audio, timecode and
> telemetry (GPMF). A fifth track ('SOS') is used in file recovery in HERO4 and HERO5, can be
> ignored."*

> ```
> ftyp [type 'mp41']
> mdat [all the data for all tracks are interleaved]
> moov [all the header/index info]
>   'trak' subtype 'vide', name "GoPro AVC", H.264 video data
>   'trak' subtype 'soun', name "GoPro AAC", to AAC audio data
>   'trak' subtype 'tmcd', name "GoPro TCD", starting timecode (time of day as frame since midnight)
>   'trak' subtype 'meta', name "GoPro MET", GPMF telemetry
> ```

> *"To confirm you have a GPMF style track, scan for the sample description atom which uses the type
> **`gpmd`** for GPMF data."*

and the full box tree (same URL):

> ```
> 'trak'
>    'tkhd' < track header data >
>    'mdia'
>       'mdhd' < media header data >
>       'hdlr' < ... Component type = 'mhlr', Component subtype = 'meta', ... Component name = "GoPro MET" ... >
>       'minf'
>          'gmhd'
>             'gmin' < media info data >
>             'gpmd' < the type for GPMF data >
>          'dinf' < data information >
>          'stbl' < sample table within >
>             'stsd' < sample description with data format 'gpmd', the type used for GPMF >
>             'stts' < GPMF sample duration for each payload >
>             'stsz' < GPMF byte size for each payload >
>             'stco' < GPMF byte offset with the MP4 for each payload >
> ```

- **CERTAIN** — Independent confirmation plus a real atom dump of a GoPro MAX file showing
  `stsd → gpmd`:
  <https://www.trekview.org/blog/injecting-camm-gpmd-telemetry-videos-part-5-gpmf/>.
  (Caveat: that blog once writes "the data type is `gpmf`" in prose; its own hex/atom dump says
  `gpmd`, and `gpmd` is what FFmpeg and GoPro use.)
- **CERTAIN (local experiment)** — `ffprobe` on `samples/hero8.mp4` from the official GoPro repo
  (<https://raw.githubusercontent.com/gopro/gpmf-parser/main/samples/hero8.mp4>, 4,402,730 bytes):

```
0  h264   video  avc1  handler_name=GoPro AVC
1  aac    audio  mp4a  handler_name=GoPro AAC
2  unknown data  tmcd  handler_name=GoPro TCD    <- timecode track
3  bin_data data gpmd  handler_name=GoPro MET    <- GPMF telemetry
4  unknown data  fdsc  handler_name=GoPro SOS    <- file-recovery track
```

So: **GoPro's telemetry track is `gpmd`; `tmcd` is the timecode track; `fdsc` is the SOS/recovery
track.** The "meta" name appears in the handler (`hdlr` subtype `meta`, name "GoPro MET"), and in
`gmhd`/`gmin`.

### A3. Does FFmpeg recognise/copy it? (the core question)

FFmpeg **knows** `gpmd` and can both read and **write** it back into MP4 — this has been true since
2017. What breaks is naive mapping.

- **CERTAIN** — The demuxer maps the `gpmd` fourcc to `AV_CODEC_ID_BIN_DATA`; master source,
  `libavformat/isom.c`:
  ```c
  const AVCodecTag ff_codec_movdata_tags[] = {
      { AV_CODEC_ID_BIN_DATA, MKTAG('g', 'p', 'm', 'd') },
      { AV_CODEC_ID_ITUT_T35, MKTAG('i', 't', '3', '5') },
      { AV_CODEC_ID_NONE, 0 },
  };
  ```
  <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/isom.c>
  (used from `mov.c` via `ff_codec_get_id(ff_codec_movdata_tags, format)` —
  <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/mov.c>)
- **CERTAIN** — Remuxing support for `gpmd` was added by commit
  `850a45aef10b50a2344a71055a30987aea23e48a`, *"lavf/movenc: support GPMF track (gpmd) remuxing"*,
  by Clément Bœsch `<cboesch@gopro.com>` (a GoPro employee), 2017-07-21, referencing
  <https://github.com/gopro/gpmf-parser>:
  <https://github.com/FFmpeg/FFmpeg/commit/850a45aef10b50a2344a71055a30987aea23e48a>
  (patch text fetched from `…/850a45ae….patch`).
  It adds `mov_write_gpmd_tag()`, the `stsd` branch, the `gmhd`/`gpmd` child box, the
  `minf`/`gmhd` branch, and the handler:
  ```c
  } else if (track->par->codec_tag == MKTAG('g','p','m','d')) {
      hdlr_type = "meta";
      descr = "GoPro MET"; // GoPro Metadata
  }
  ```
  Those hunks are still present in master:
  <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/movenc.c>
- **CERTAIN** — The patch was reviewed on ffmpeg-devel (msg-id thread "movenc: support GPMF track
  (gpmd) remuxing", Clément Bœsch replying to Derek Buitenhuis):
  <https://ffmpeg.org/pipermail/ffmpeg-devel/2017-July/213951.html>

**But the parent's pipeline drops it.** Two independent reasons:

1. `gpmd` is an `AVMEDIA_TYPE_DATA` stream, and `-map 0:v:0 -map 0:a?` only matches video/audio.
   **CERTAIN** — docs: *"Data or attachment streams are not automatically selected and can only be
   included using `-map`."* <https://ffmpeg.org/ffmpeg.html>
2. It is not copied implicitly either: with **no** `-map` at all, only the "best" video and audio
   are taken.

- **CERTAIN (local experiment, FFmpeg 8.1.2)** — on `hero8.mp4`:
  - `ffmpeg -i hero8.mp4 -map 0:v:0 -map 0:a? -c copy t1.mp4` → output streams: `h264`, `aac`,
    `tmcd`. **`gpmd` gone.** And the `tmcd` there is *generated*, not copied: adding
    `-write_tmcd 0` yields only `h264` + `aac`.
  - The parent's full command with `-c:v libsvtav1 -crf 36 -cpu-used 8 -c:a copy` → output streams:
    `av1`, `aac`, `tmcd`. **`gpmd` gone, no warning.**

**`-map 0` does NOT fix it** — it makes the run fail:

- **CERTAIN (local experiment)** — `ffmpeg -i hero8.mp4 -map 0 -c copy t2.mp4`:
  ```
  [mp4 @ …] Could not find tag for codec none in stream #2, codec not currently supported in container
  Could not write header for output file #0 (incorrect codec parameters ?): Invalid argument
  ```
  Stream #2 is the `tmcd` track, whose codec FFmpeg reports as `unknown`/`none`; the MP4 muxer has
  no tag for it (`mov_find_codec_tag()` returns 0 → `Could not find tag for codec %s in stream #%d,
  codec not currently supported in container`,
  <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/movenc.c>, search for that
  string). Same failure for an explicitly mapped `0:2` (`tmcd`) and `0:4` (`fdsc`).
- **CERTAIN** — this is exactly FFmpeg trac **#8338** (see A5) — opened 2019, still `new`.

**Working incantations** (all verified locally on the real GoPro file):

| Command fragment | Result |
|---|---|
| `-map 0:v -map 0:a -map 0:3 -c copy` | ✅ `gpmd` preserved (this is the workaround Carl Eugen Hoyos suggested in trac #8338 comment 5) |
| `-map 0:v:0 -map 0:a? -map 0:d:1 -c copy` (or transcode video + `-c:d copy`) | ✅ `gpmd` preserved |
| `-map 0 -map -0:2 -map -0:4 -c copy` (negative-map the two unsupported data tracks) | ✅ `gpmd` preserved |
| `-map 0:d?` | ❌ fails — the `d` specifier matches **all three** data streams incl. `tmcd`/`fdsc` |
| `-map 0` | ❌ fails (`codec none`) |
| `-map 0 -c copy -copy_unknown` | ❌ still fails |
| `-map 0 -c copy -ignore_unknown` | ❌ still fails |

**Bit-exactness:** **CERTAIN (local experiment)** — extracting the raw GPMF payload
(`-map 0:3 -c copy -f data x.gpmd`) gives 85,940 bytes, MD5 `68aa688af11fa8cf54d04c3c211878f3` from
the source and the identical MD5 after `-map 0:v -map 0:a -map 0:3 -c copy`; and MD5
`7a5b00cc696375d56d7c5390b79203fb` / 13,492 bytes matches between source and the AV1-transcoded
output when `-map 0:d:1` is used. GPMF is **not** re-encoded — it is either copied verbatim or lost.

### A4. Which flags control data/unknown tracks

**CERTAIN** — stream specifiers, verbatim from <https://ffmpeg.org/ffmpeg.html> (identical text in
<span>https://manpages.debian.org/trixie/ffmpeg/ffmpeg.1.en.html</span>):

> *"`stream_type` is one of following: 'v' or 'V' for video, 'a' for audio, 's' for subtitle,
> **'d' for data**, and **'t' for attachments**. 'v' matches all video streams, 'V' only matches
> video streams which are not attached pictures, video thumbnails or cover arts."*

**CERTAIN** — `-copy_unknown`, verbatim from <https://ffmpeg.org/ffmpeg.html>:

> *"**-copy_unknown** — Allow input streams with unknown type to be copied instead of failing if
> copying such streams is attempted."*
> *"**-ignore_unknown** — Ignore input streams with unknown type instead of failing if copying such
> streams is attempted."*

**CERTAIN** — both exist in fftools (`fftools/ffmpeg_opt.c`:
`{ "ignore_unknown", OPT_TYPE_BOOL, OPT_EXPERT, { &ignore_unknown_streams }, … }` /
`{ "copy_unknown", OPT_TYPE_BOOL, OPT_EXPERT, { &copy_unknown_streams }, … }`,
<https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/fftools/ffmpeg_opt.c>).

**Important nuance (CERTAIN, local experiment):** `-copy_unknown`/`-ignore_unknown` care about
streams of **unknown *type*** — i.e. streams whose media type FFmpeg could not classify. The GoPro
`tmcd`/`fdsc` streams *are* classified as `DATA` but have **codec id `none`**, which is a different
failure ("Could not find tag for **codec** none"), so neither flag helps. Both were tested and both
still abort.

**CERTAIN** — `-dn`, verbatim from <https://ffmpeg.org/ffmpeg.html>:

> *"**-dn** (input/output) — As an input option, blocks all data streams of a file from being
> filtered or being automatically selected or mapped for any output… As an output option, disables
> data recording i.e. automatic selection or mapping of any data stream. For full manual control see
> the `-map` option."*

`-map` documentation, same URL: *"To map ALL streams from the first input file to output:
`ffmpeg -i INPUT -map 0 output`"* — note that this "map everything" advice is precisely what fails on
a real GoPro file.

### A5. Known FFmpeg trac tickets about gpmd

- **CERTAIN** — **#8338 "GoPro metadata not properly handled"** (`avformat`, type `enhancement`,
  priority `wish`, status **new**; opened 2019-10-27 by `importon`, last modified 2024-08-07;
  keywords `mov GPMF TMCD`; "Reproduced by developer: no"):
  <https://trac.ffmpeg.org/ticket/8338>
  Ticket body (verbatim): *"Summary of the bug: I'm trying to swap out the video track of a GoPro
  mp4 file (0.mp4) with another (1.mp4) while keeping all the GPMF metadata in the 1st GoPro file.
  It results in error message "[mp4 @ …] Could not find tag for codec none in stream #2, codec not
  currently supported in container…"*
  Comment 5, Carl Eugen Hoyos (verbatim): *"I believe the following works as expected:
  `ffmpeg -i 0.MP4 -c copy -map 0:v -map 0:a -map 0:3 out.mp4`. The `fdsc` tag is unsupported
  afaict."*
  Mirror mails: <https://ffmpeg.org/pipermail/ffmpeg-trac/2024-August/070427.html>,
  <https://ffmpeg.org/pipermail/ffmpeg-trac/2024-August/070434.html>,
  <https://ffmpeg.org/pipermail/ffmpeg-trac/2022-November/063873.html> (the last one contains the
  2022 comment *"I tested the latest version of FFmpeg and this issue still occurs, ffmpeg refuses
  to copy the GPMD metadata stream with the same error message…"*, by Leseratte10).
  **Note:** that reporter's conclusion ("it just can't add it back to a video") is **not** accurate
  as a general statement — the 2017 movenc commit and my local test both show `gpmd` *can* be
  written into MP4; what actually fails is muxing the `tmcd`/`fdsc` tracks that `-map 0` drags in
  (UNCERTAIN for the reporter's intent, CERTAIN for my measured behaviour).
- **CERTAIN** — other trac items where `gpmd` appears (found via
  <https://trac.ffmpeg.org/search?q=gpmd>), but **none of them is "gpmd gets dropped"**:
  - #11642 *"ffmpeg -ss -c copy causes MP4 vobsub timestamps to be incorrectly shifted"* — a
    `bin_data (gpmd …)` line just appears in the log: <https://trac.ffmpeg.org/ticket/11642>
  - #8740 *"ffmpeg 4.2.3 bug: Do not overwrite the file even "y" is pressed"* — `gpmd` line in log:
    <https://trac.ffmpeg.org/ticket/8740>
  - #9390 *"Wrong FPS used for timecode computation mangles timecodes"* (closed: fixed) — GoPro 9
    timecode: <https://trac.ffmpeg.org/ticket/9390>
  - #10626 *"ffmpeg throws 'non-zero exit status …' for video files"* — user trying to extract GoPro
    GPS telemetry: <https://trac.ffmpeg.org/ticket/10626>
- **CERTAIN (negative result)** — there is **no** trac ticket about GPMF *decoding*; `grep -rn GPMF`
  over the whole FFmpeg master tree (I downloaded the master tarball, see URL ledger) finds **zero**
  hits — FFmpeg never parses GPMF payloads, it only carries the opaque `gpmd` payload.
- **UNCERTAIN / community-only** — Stack Overflow reports of the same class:
  - <https://stackoverflow.com/questions/67576853/copying-gopro-metadata-with-ffmpeg-could-not-find-tag-for-codec-none>
    — *"I am trying to use ffmpeg to copy the metadata of a gopro file… `-c copy -copy_unknown -map 0:v -map 0:a -map 0:2 -map 0:3 -map 0:4 -map_metadata 0` … error: Could not find tag for codec none in stream #2"*
  - <https://stackoverflow.com/questions/51354696/ffmpeg-concat-and-preserve-metadata-streams>
    — *"I need the telemetry data that is encoded in the metadata streams, and ffmpeg by default
    doesn't seem to preserve this."* (via `-f concat`, where the data streams degrade to
    *"Unknown: none"*).
  - <https://stackoverflow.com/questions/75727163/apple-avkit-avasset-tracks-method-does-not-see-all-tracks-in-gopro-mp4-files>
    — useful ffprobe dump of a HERO9 file showing `Data: none (gpmd / 0x646D7067) … handler_name :
    GoPro MET`.

---

## B) DJI and Insta360

### B1. DJI: metadata in tracks (`djmd` / `dbgi`)

- **CERTAIN** — FFmpeg trac **#11698 "DJI mov Prores RAW decoding issues"** (new, defect) contains a
  real `ffmpeg -i` log of a DJI Inspire 3 ProRes RAW `.MOV`:
  <https://trac.ffmpeg.org/ticket/11698>
  Verbatim from that log:
  > `Stream #0:1[0x2](eng): Data: none (djmd / 0x646D6A64), 72 kb/s` … `handler_name : DJI meta`
  > `Stream #0:2[0x3](eng): Data: none (dbgi / 0x69676264), 1752 kb/s` … `handler_name : DJI dbgi`
  > `Stream #0:3[0x5](eng): Data: none (tmcd / 0x64636D74), 0 kb/s` … `handler_name : TimeCodeHandler`

  So DJI ships **timed metadata *tracks*** (`djmd` = "DJI meta", `dbgi`) inside the MP4/MOV, not only
  boxes — and FFmpeg classifies them as `Data: none`, i.e. no codec id, which is exactly the state
  that makes them un-writable into MP4 by the mov muxer (see A3). The same ticket's later comment
  notes *"the DJI files carry `djmd` / `dbgi` private-data tracks the control sample lacks"*.
- **CERTAIN (negative result)** — FFmpeg master has **no** `djmd`, `dbgi`, `DJI` or `DJI meta`
  support: `grep -rn "djmd\|dbgi"` over the full master tree returns nothing. No `djmd` entry exists
  in `ff_codec_movdata_tags` (only `gpmd` and `it35`):
  <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/isom.c>
  and none in <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/isom_tags.c>.
- **CERTAIN (negative result)** — trac search for `djmd` returns exactly one hit (#11698) and it is
  not about metadata being dropped: <https://trac.ffmpeg.org/search?q=djmd>. Search `DJI` returns 30
  items, mostly colour/decode issues (<https://trac.ffmpeg.org/search?q=DJI>).
- **UNCERTAIN (third-party tool documentation)** — modern DJI drones embed protobuf telemetry in the
  `djmd`/`dbgi` timed-metadata track, and the practical way to read it is ExifTool (FFmpeg cannot):
  *"Newer DJI models (Air 3S, Mini 5 Pro, and others) record telemetry **inside the MP4** as DJI's
  `djmd`/`dbgi` protobuf timed-metadata track, with no sidecar `.SRT`."*
  <https://raw.githubusercontent.com/CallMarcus/dji-drone-metadata-embedder/master/docs/MP4_TIMED_METADATA.md>
- **NO SOURCE FOUND** — I found **no official DJI specification** for `djmd`/`dbgi`, and **no
  evidence** for a distinct modern "DJI meta **box**" (as opposed to the track/handler name "DJI
  meta" shown above). Older DJI models are widely reported to store telemetry in a sidecar `.SRT`,
  but I did not obtain a primary source for that here.
- **Conclusion (INFERRED, high confidence):** a `-map 0:v:0 -map 0:a?` pipeline discards DJI
  telemetry outright, and even `-map 0` will fail on such files for the same "codec none" reason as
  GoPro `tmcd`/`fdsc`.

### B2. Insta360 / `.insv`

- **CERTAIN (official, but only about file naming/existence)** — Insta360's X-series file-format
  article: 360° video is written as a **VID file in INSV format**; X3/X2/ONE X at 5.7K produce **two**
  VID files, while *"Unlike X3 which generates two VID files, X6, X5, X4 Air, and X4 generate only
  one VID file containing data from both lenses."*
  <https://onlinemanual.insta360.com/onex/en-us/operating-tutorials/storage/fileformat>
  (The `…/x5/en-us/faq/specs/fileformat` URL exists but is a JavaScript shell — no text content was
  retrievable: <https://onlinemanual.insta360.com/x5/en-us/faq/specs/fileformat>.)
- **CERTAIN (negative results)**
  - `grep -rni "insv\|insta360"` over the entire FFmpeg master tree returns **no** relevant hits
    (only unrelated `insve` tokens in MIPS assembly). FFmpeg has no Insta360/INSV support.
  - trac search for `insv`: **"No matches found"** — <https://trac.ffmpeg.org/search?q=insv>
- **UNCERTAIN (user report)** — direct FFmpeg use on `.insv` fails: *"I attempted to use FFmpeg to
  directly convert the INSV file to images, but I encountered errors, possibly due to the proprietary
  nature of the INSV format… This command did not work as expected and produced an error."* The
  accepted answer recommends exporting to MP4 with Insta360 Studio first:
  <https://stackoverflow.com/questions/78559313/how-to-extract-a-frame-from-an-insv-format-360-video-using-python>
- **UNCERTAIN (third-party issue text)** — `.insv` is described as *"360° video, stored as
  dual-fisheye (typically HEVC, plus a gyro/metadata track in an MP4-style container)"*, and for
  X3/X4 *"the two lenses [are stored] as separate video streams that must be demuxed and combined
  (hstack) before v360"*:
  <https://github.com/photoprism/photoprism/issues/5711>
  (fetched via the GitHub API: <https://api.github.com/repos/photoprism/photoprism/issues/5711>)
- **UNCERTAIN** — an in-flight investigation task in an unrelated project explicitly frames INSV
  metadata as not-yet-understood: *"Investigate the metadata contents of the video stream and
  `insv`"*: <https://gitlab.com/whitebox-aero/whitebox/-/work_items/68>
- **NO SOURCE FOUND** — no official Insta360 document describing INSV's internal box/track layout,
  and no FFmpeg ticket or mailing-list thread about Insta360 metadata. The claim "Insta360 metadata
  is in a proprietary track that FFmpeg drops" is therefore **INFERRED, not sourced**: FFmpeg has no
  Insta360 code at all, so any proprietary track is at best carried as an unknown data stream (and,
  per A3, un-writable to MP4) and at worst not parsed.

---

## C) Apple / Samsung / Google

### C1. Apple spatial video: MV-HEVC + `vexu`, and what a re-encode does

- **CERTAIN** — FFmpeg trac **#10579 "Apple HEVC Stereo Video support"** (new, enhancement, opened
  2023-09-23, last modified 2024-05-25), verbatim: *"Would be nice if FFmpeg would support Apple
  HEVC Stereo Video. This is only about recognizing, rendering and passthrough of the necessary
  information and support of the ISO Base Media File Format (boxtype 'vexu'). This bug is not about
  encoding such files."* It cites Apple's specs:
  <https://trac.ffmpeg.org/ticket/10579>
- **CERTAIN** — Apple's three specification PDFs all resolve (HTTP 200, `application/pdf`, 8 pages
  each — verified by fetching):
  - <https://developer.apple.com/av-foundation/HEVC-Stereo-Video-Profile.pdf>
  - <https://developer.apple.com/av-foundation/Stereo-Video-ISOBMFF-Extensions.pdf>
  - <https://developer.apple.com/av-foundation/Video-Contour-Map-Metadata.pdf>
  (I confirmed they are served as PDFs; I did not machine-extract their prose, so any *content* claim
  from them is **UNCERTAIN** here and I do not make one.)
- **CERTAIN — MV-HEVC decoding exists since the 7.1 cycle.** Commit
  `14746871e1d33de172d6cb32730d962068e3ccd2`, *"lavc/hevcdec: implement decoding MV-HEVC"*, Anton
  Khirnov, 2024-06-12:
  > *"At most two layers are supported. Aspects of this work were sponsored by Vimeo and Meta."*

  It adds to `Changelog` the line `- MV-HEVC decoding` and to `doc/decoders.texi` (verbatim):
  > *"The decoder supports MV-HEVC multiview streams with at most two views. Views to be output are
  > selected by supplying a list of view IDs to the decoder (the `view_ids` option). … **Only the
  > base layer is decoded by default.** … Note that if you are using the `ffmpeg` CLI tool, you should
  > be using view specifiers as documented in its manual, rather than the options documented here."*

  <https://github.com/FFmpeg/FFmpeg/commit/1474687> (patch fetched from `…/1474687.patch`)
- **CERTAIN (local experiment)** — FFmpeg 8.1.2 exposes exactly these decoder options:
  ```
  ffmpeg -h decoder=hevc
    -view_ids            Array of view IDs that should be decoded and output; a single -1 to decode all views
    -view_ids_available  Array of available view IDs is exported here
    -view_pos_available  Array of view positions for view_ids_available is exported here, as AVStereo3DView
  ```
- **CERTAIN — this is the decisive answer about re-encoding.** FFmpeg docs, `-map`, verbatim from
  <https://ffmpeg.org/ffmpeg.html>:
  > *"An optional **view_specifier** may be given after the stream specifier, which for multiview
  > video specifies the view to be used. The view specifier may have one of the following formats:
  > `view:` *view_id* … `vidx:` *view_idx* … `vpos:` *position* … **The default for transcoding is to
  > only use the base view, i.e. the equivalent of `vidx:0`. For streamcopy, view specifiers are not
  > supported and all views are always copied.**"*

  ⇒ **Re-encoding a spatial video with FFmpeg discards the second view unless you explicitly request
  it (`-map 0:v:view:all`, `-map 0:v:vidx:0 -map 0:v:vidx:1`, `-vpos:left/right`, …). A pure
  `-c copy` remux keeps both views.** (CERTAIN — direct doc quote; the transcode side of it is the
  documented default, and I could not obtain an Apple spatial sample to re-verify locally.)
- **CERTAIN — MV-HEVC *encoding* also exists**, at least via NVENC: commit
  `5083f4ad8e26806b2113d8001dcbf20e220a7309`, *"avcodec/nvenc: add MV-HEVC encoding support"*, Diego
  de Souza (NVIDIA), 2025-01-08:
  > *"Added support for MV-HEVC encoding for stereoscopic videos (2 views only). Compatible with the
  > framepack filter when using the AV_STEREO3D_FRAMESEQUENCE format."*

  <https://github.com/FFmpeg/FFmpeg/commit/5083f4ad>
  (Found first via <https://trac.ffmpeg.org/search?q=MV-HEVC>, which also lists
  `80a05bea` *"avutil: add an API to handle 3D Reference Displays Information"*: *"…2.3 of ITU-T
  H.265, it's required for proper signaling of MV-HEVC."*.)
- **CERTAIN — `vexu` writing support**: commit `6a428876fc4f1128644dcbc8e8fd814e1754262f`,
  *"avformat/movenc: add support for writting vexu boxes"*, James Almer, 2024-06-21
  <https://github.com/FFmpeg/FFmpeg/commit/6a428876>. Master `movenc.c` contains
  `mov_write_vexu_tag()` / `mov_write_vexu_proj_tag()` / `mov_write_eyes_tag()`; master `mov.c`
  contains `mov_read_vexu()` (handling child boxes `proj`, `eyes`, `pack`) registered as
  `{ MKTAG('v','e','x','u'), mov_read_vexu }, /* video extension usage */`.
  <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/movenc.c>,
  <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/mov.c>
- **UNCERTAIN (code-reading inference)** — the `vexu` round-trip is *partial*. `movenc` only writes
  `vexu` when the stream carries `AV_PKT_DATA_STEREO3D` and/or `AV_PKT_DATA_SPHERICAL` side data
  (`if (stereo3d || spherical_mapping) mov_write_vexu_tag(...)`), and `mov_write_vexu_tag()` writes
  only `proj` (from spherical) and `eyes` (from stereo3d) — it never writes `pack`. Apple's VEXU
  carries more (hero eye, camera baseline, disparity adjustment, "has additional views"). So
  remuxing an iPhone spatial video through FFmpeg is likely to lose or alter some VEXU semantics.
  No bug report or test confirming this was found — **no source found** for a definitive statement.
- **UNCERTAIN (user report, illustrative)** — a detailed Super User question shows FFmpeg 7.1
  output still not being accepted by QuickTime/Vision Pro, and needing an external tool (Mike
  Swanson's "Spatial") to inject VEXU attributes (`vexu:cameraBaseline`, `heroEyeIndicator`,
  `hasLeftEyeView`, `projectionKind=halfEquirectangular`, …). Its ffprobe dump shows
  `"view_ids_available": "0,1"`:
  <https://superuser.com/questions/1858318/how-to-make-apple-vision-pro-compatible-mv-hevc-files-with-x265-4-0-and-ffmpeg-7>
  (fetched through the Stack Exchange API because the site itself returned HTTP 403).

### C2. `st3d` / `sv3d` support

- **CERTAIN** — `st3d` (stereoscopic 3D) and `sv3d` (spherical video) are read **and** written by
  FFmpeg. Commit `b4189590a59159317f6316106e2f061e5c6df556`, *"movenc: Add support for writing st3d
  and sv3d boxes."*, Aaron Colwell (Google), 2017-03-27:
  <https://github.com/FFmpeg/FFmpeg/commit/b4189590>
- **CERTAIN** — commit `86dee47e397fe6bb0907adae8d4a54138a947646`, James Almer, 2017-03-27,
  *"avformat/movenc: allow st3d and sv3d mov atoms to be written in strict unofficial mode / They are
  unofficial extensions to the format for the time being, not an experimental feature."*
  <https://github.com/FFmpeg/FFmpeg/commit/86dee47e>
  (Companion commit `a715e5a2` *"restrict st3d and sv3d mov atoms to MODE_MP4"*, listed at
  <https://trac.ffmpeg.org/search?q=sv3d>.)
- **CERTAIN** — present in master: `mov_read_st3d` / `mov_read_sv3d` / `mov_read_vexu` registered in
  `libavformat/mov.c`, `mov_write_st3d_tag` / `mov_write_sv3d_tag` / `mov_write_vexu_tag` in
  `libavformat/movenc.c` (grep of master tree; URLs above).

### C3. Samsung / Google motion photos

- **CERTAIN (negative results)** — FFmpeg has **no** motion-photo support:
  - `grep -rni "motionphoto\|motion_photo\|MicroVideo"` over the whole master tree → **zero hits**.
  - trac search `motionphoto` → **"No matches found"** (<https://trac.ffmpeg.org/search?q=motionphoto>);
    `MicroVideo` → **"No matches found"** (<https://trac.ffmpeg.org/search?q=MicroVideo>).
- **CERTAIN — what the format actually is** (official Android spec, fetched):
  <https://developer.android.com/media/platform/motion-photo-format?hl=en>
  Verbatim:
  > *"Motion Photo files consist of a primary still image file, JPEG, HEIC, or AVIF, with a
  > secondary video file appended to it. The primary image contains Camera XMP metadata describing
  > how to display the still image file and video file contents, and Container XMP metadata
  > describing how to locate the video file contents. The image file may have a gainmap, as is the
  > case with Ultra HDR JPEGs."*

  > *"Name: Camera:MicroVideo … **These properties were part of the Microvideo V1 specification. They
  > are deleted in this specification and must be ignored if present.** In particular, the
  > MicroVideoOffset attribute is replaced by the GContainer:ItemLength value for locating the video
  > data in the file."*

  > *"Camera:MotionPhoto Integer 0: Indicates that the file shouldn't be treated as a Motion Photo.
  > 1: … should be treated as a Motion Photo. … **This field is therefore not definitive and readers
  > must always confirm that a video is present.**"*

  Namespaces: camera = `http://ns.google.com/photos/1.0/camera/`, container =
  `http://ns.google.com/photos/1.0/container/`.
- **CERTAIN (behaviour, via user report)** — FFmpeg sees only the still image: on a Samsung Galaxy
  S21 Ultra motion photo, `ffmpeg -i 20240623_233601.jpg` shows a single `Video: mjpeg (Baseline)`
  stream with `Duration: 00:00:00.04`, and mapping/encoding yields silent MP4s with no motion
  ("*I can only get still MP4's out of it, with none of the video*"):
  <https://superuser.com/questions/1853741/cant-get-ffmpeg-to-convert-samsung-motion-photos-from-jpeg-to-mp4>
  Combined with the negative source/format evidence above this makes "FFmpeg cannot see or preserve
  the motion-photo video, and re-encoding produces a still-only file" **CERTAIN**.
- **UNCERTAIN** — whether Samsung's "Motion Photo" is byte-for-byte the Google/Android spec. The
  Android spec is Google's; I found **no** Samsung document, so I only claim the *observable*
  behaviour above.

### C4. Google Pixel motion photos / Ultra HDR gain maps

- **CERTAIN — the gain map is a second JPEG appended to the primary JPEG**, official spec
  (*Ultra HDR Image Format v1.1*, fetched):
  <https://developer.android.com/media/platform/hdr-image-format?hl=en>
  Verbatim:
  > *"The encoded gain map must be stored in a secondary image item as a JPEG. … After the gain map is
  > stored in a secondary image, it is appended to a primary image with MPF and GContainer XMP
  > metadata."*

  > *"Item:Semantic — **GainMap**: Indicates that the media item is a gain map. The directory might
  > contain at most one "GainMap" item."*

  > *"The XMP namespace URI for the gain map metadata XMP extension is
  > `http://ns.adobe.com/hdr-gain-map/1.0/`. The default namespace prefix is `hdrgm`."*

  Also: *"ISO 21496-1 provides an alternative encapsulation mechanism for encoding gain map metadata
  in an image file."* (That is the same ISO standard referenced externally, e.g.
  <https://github.com/mpv-player/mpv/issues/18072> — seen in search results, not fetched.)
- **CERTAIN (negative result)** — FFmpeg has **no** gain-map/Ultra HDR support: over the entire
  master tree, `grep -rni "gain_map\|gainmap\|ultrahdr\|ultra hdr\|GContainer\|hdrgm"` returns a
  single irrelevant hit (a comment `transient_gain_mapped` in `libavcodec/aacps.c`). trac search
  `UltraHDR` returns only a 2024 VDD meeting note (<https://trac.ffmpeg.org/search?q=UltraHDR>).
- **Conclusion (INFERRED, but effectively certain):** any FFmpeg re-encode of an Ultra HDR JPEG
  destroys the gain map — FFmpeg decodes only the base JPEG (the gain map lives in a second file
  appended after the JPEG's EOI marker, located via MPF/GContainer XMP) and has no code to read,
  carry or write it. **No source found** for a dedicated public statement/bug report about this; the
  conclusion rests on the official format definition plus the zero-hit source grep.

---

## D) Spatial / ambisonic audio

### D1. First-order ambisonics (AmbiX, 4ch ACN/SN3D) in Opus

- **CERTAIN — FFmpeg has first-class ambisonic channel layouts** in the new channel-layout API.
  `libavutil/channel_layout.h`, verbatim:
  > *"Range of channels between `AV_CHAN_AMBISONIC_BASE` and `AV_CHAN_AMBISONIC_END` represent
  > Ambisonic components using the ACN system. Given a channel id `<i>` … the ACN index of the channel
  > `<n>` is `<n> = <i> - AV_CHAN_AMBISONIC_BASE`."*

  > *"`AV_CHANNEL_ORDER_AMBISONIC` — The audio is represented as the decomposition of the sound field
  > into spherical harmonics. Each channel corresponds to a single expansion component. Channels are
  > ordered according to ACN (Ambisonic Channel Number). … **Normalization is assumed to be SN3D
  > (Schmidt Semi-Normalization) as defined in AmbiX format $ 2.1.**"*

  > ```c
  > #define AV_CHANNEL_LAYOUT_AMBISONIC_FIRST_ORDER \
  >     { /* .order */ AV_CHANNEL_ORDER_AMBISONIC, \
  >       /* .nb_channels */ 4, \
  >       /* .u.mask */ { 0 }, \
  >       /* .opaque */ NULL }
  > ```

  <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavutil/channel_layout.h>
  Also `<n>th` order parsing: `av_channel_layout_from_string()` accepts *"the ambisonic order followed
  by optional non-diegetic channels (eg. "ambisonic 2+stereo")"* (same header), and
  `av_channel_layout_ambisonic_order()` exists (added 2024-05-23, lavu 59.20.100, per
  <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/doc/APIchanges>).
- **CERTAIN** — `libavutil/channel_layout.c` prints/parses these as `AMBI<n>` (short) and
  `ambisonic ACN <n>` (long), and accepts the literal string prefix `"ambisonic "`
  (<https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavutil/channel_layout.c>, included in
  the master tarball I fetched).
- **CERTAIN (negative, local experiment)** — the *user-facing* channel-layout reference does not
  document ambisonics: `ffmpeg -layouts` prints no ambisonic entry, and `ffmpeg-utils.html` has no
  occurrence of "ambisonic" at all (<https://ffmpeg.org/ffmpeg-utils.html> — fetched and grepped).
  The only official documentation of the `ambisonic N` syntax is the libavutil header above.
- **CERTAIN (local experiment, FFmpeg 8.1.2) — practical behaviour:**

| Test | Result |
|---|---|
| `ffmpeg -f lavfi -i aevalsrc=…:c="ambisonic 1" -c:a pcm_s16le out.wav` | runs, but the muxed file probes back as `channel_layout=unknown` (WAV does not carry it) |
| … `-c:a libopus` (default `-mapping_family -1`) | ❌ **hard error:** `[libopus] Invalid channel layout ambisonic 1 for specified mapping family -1.` → *"Error while opening encoder"* |
| … `-c:a libopus -mapping_family 2` | ✅ works; output probes back as `codec_name=opus, channels=4, channel_layout=ambisonic 1` (warning: `Unknown channel mapping family 2. Output channel layout may be invalid.`) |
| … `-c:a libopus -mapping_family 3` | ❌ `Failed to create encoder: request not implemented` |
| `-c:a copy` of that ambisonic Ogg/Opus | ✅ `channel_layout=ambisonic 1` preserved |
| re-encoding that file with plain `-c:a libopus` | ❌ fails with the same "mapping family -1" error |
| any pipeline that inserts `auto_aresample` (e.g. mono source → `-channel_layout "ambisonic 1"`, or `-c:a opus` native encoder) | ❌ `[SWR] Output channel layout 'ambisonic 1' is not supported` / `Input channel layout 'ambisonic 1' is not supported` |

  ⇒ **`-c:a copy` preserves AmbiX/FoA; re-encoding is not "silently destroyed" — it fails loudly
  unless you set `-mapping_family 2`. But libswresample cannot handle ambisonic layouts at all, so
  any resampling path breaks.** (CERTAIN for FFmpeg 8.1.2 on macOS; the exact error text is
  reproduced above so it can be re-checked on the build in question.)
- **UNCERTAIN** — whether the Opus-in-MP4 / other muxer paths treat `mapping_family 2` files
  correctly. Not tested.

### D2. Does re-encoding destroy spatial audio metadata?

- Answer for the codecs above, **CERTAIN (local)**: for Opus the "spatial" information is the Opus
  channel-mapping family plus the layout, and FFmpeg refuses to re-encode an ambisonic layout with
  the default mapping family rather than silently flattening it. For plain channel-based audio the
  layout is a property of the stream, and the CLI documents: *"**-channel_layout** … Set the audio
  channel layout. **For output streams it is set by default to the input channel layout.** For input
  streams it overrides the channel layout of the input. Not all decoders respect the overridden
  channel layout."* — <https://ffmpeg.org/ffmpeg.html> (also in
  <https://manpages.debian.org/trixie/ffmpeg/ffmpeg.1.en.html>).
  ⇒ `-c:a copy` keeps the declared layout; a re-encode defaults to inheriting it but is at the mercy
  of encoder/sample-format negotiation.
- **CERTAIN** — IAMF has explicit ambisonics support in FFmpeg (`-stream_group … audio_element_type=scene`
  / `ambisonics_mode` / `demixing_matrix`) — <https://ffmpeg.org/ffmpeg.html> and
  <https://trac.ffmpeg.org/search?q=ambisonic> (commits adding Projection-mode ambisonic IAMF Audio
  Elements, `av_channel_layout_ambisonic_order()` usage in `iamf_parse`, and an `aacenc` hack:
  *"AAC can't signal such layouts, so this is merely a hack to allow such streams to be passed to the
  encoder…"*). So for AAC, marking a stream as ambisonic is **not** preserved by the bitstream —
  **CERTAIN from that commit message**, which is itself evidence that AAC cannot carry ambisonic
  layout information.

### D3. `-channel_layout` vs `ch_layout` — the premise needs correcting

- **CERTAIN — the deprecation happened in the *library API*, not the CLI.** `doc/APIchanges`,
  verbatim:
  > *"2022-03-15 - cdba98bb80 - lavu 57.24.100 - channel_layout.h frame.h opt.h — Add new channel
  > layout API based on the AVChannelLayout struct. Add support for Ambisonic audio. **Deprecate
  > previous channel layout API based on uint64 bitmasks.** Add AV_OPT_TYPE_CHLAYOUT option type,
  > deprecate AV_OPT_TYPE_CHANNEL_LAYOUT. Update AVFrame for the new channel layout API: add
  > ch_layout, deprecate channels/channel_layout."*

  and immediately before it: *"Update AVCodec for the new channel layout API: add ch_layouts,
  deprecate channel_layouts."*
  <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/doc/APIchanges>
  (lavu 57.24.100 — the 5.1 cycle, not 6.x. The old `AVCodecContext.channel_layout` uint64 field is
  gone from current master: a grep for `channel_layout;` in
  <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/avcodec.h> finds nothing.)
- **CERTAIN — on the CLI both spellings exist and *neither* is deprecated**; in master
  `doc/ffmpeg.texi`:
  > `@item -ch_layout[:stream_specifier] layout (input/output,per-stream)`
  > `Alias for @code{-channel_layout}.`
  > `@item -channel_layout[:stream_specifier] layout (input/output,per-stream)`
  > `Set the audio channel layout. …`

  and in `fftools/ffmpeg_opt.c` the `ch_layout` entry carries
  `.u1.name_canon = "channel_layout"` while `channel_layout` carries
  `.u1.names_alt = alt_channel_layout` with `alt_channel_layout[] = { "ch_layout", NULL }` — i.e.
  `-ch_layout` is the alias and `-channel_layout` is the canonical name.
  <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/doc/ffmpeg.texi>,
  <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/fftools/ffmpeg_opt.c>
  (Both texts are reproduced on <https://ffmpeg.org/ffmpeg.html> and
  <https://manpages.debian.org/trixie/ffmpeg/ffmpeg.1.en.html>.)
- **CERTAIN** — the only *layout-macro* deprecations currently in the header are unrelated
  `*_BACK`/`7POINT1_TOP_BACK` aliases guarded by `FF_API_CHANNEL_LAYOUT_BACK`
  (`libavutil/channel_layout.h`, and the 2026-08-23 entry in `doc/APIchanges`).

---

## E) Local verification log (FFmpeg 8.1.2, macOS/arm64, Homebrew build `--enable-libsvtav1`)

Test asset: the official GoPro sample
<https://raw.githubusercontent.com/gopro/gpmf-parser/main/samples/hero8.mp4> (4,402,730 bytes).

```
ffprobe -hide_banner -v error -show_entries stream=index,codec_type,codec_name,codec_tag_string \
        -of compact hero8.mp4
stream|0|h264|video|avc1        (handler_name=GoPro AVC)
stream|1|aac|audio|mp4a         (handler_name=GoPro AAC)
stream|2|unknown|data|tmcd      (handler_name=GoPro TCD)
stream|3|bin_data|data|gpmd     (handler_name=GoPro MET)
stream|4|unknown|data|fdsc      (handler_name=GoPro SOS)
```

| # | Command (abridged) | Outcome |
|---|---|---|
| 1 | `-map 0:v:0 -map 0:a? -c copy` | streams: h264, aac, tmcd ⇒ **gpmd dropped** |
| 2 | `-map 0 -c copy` | ❌ `Could not find tag for codec none in stream #2` |
| 3 | `-map 0 -c copy -movflags use_metadata_tags` | ❌ same failure |
| 4 | *(no map)* `-c copy` | streams: h264, aac, tmcd ⇒ gpmd dropped |
| 5 | `-map 0:v -map 0:a -map 0:3 -c copy` | ✅ h264, aac, **gpmd**, tmcd |
| 6 | `-map 0:v -map 0:a -map 0:d? -c copy` | ❌ `codec none` (the `d` specifier matches tmcd+fdsc too) |
| 7 | `-map 0:v:0 -map 0:a? -c copy -write_tmcd 0` | streams: h264, aac ⇒ proves the tmcd in #1 is **generated** |
| 8 | `-map 0 -c copy -ignore_unknown` | ❌ same failure |
| 9 | `-map 0 -c copy -copy_unknown` | ❌ same failure |
| 10 | `-map 0:v -map 0:a -map 0:4 -c copy` (`fdsc`) | ❌ `codec none` |
| 11 | `-map 0:v -map 0:a -map 0:2 -c copy` (`tmcd`) | ❌ `codec none` |
| 12 | extract `-map 0:3 -c copy -f data src.gpmd` | 85,940 B, MD5 `68aa688af11fa8cf54d04c3c211878f3` |
| 13 | same extraction from #5's output | **identical MD5/size** ⇒ byte-exact copy |
| 14 | **parent's exact command** (`-map 0:v:0 -map 0:a? -c:v libsvtav1 -crf 36 -cpu-used 8 -c:a copy`) | streams: **av1, aac, tmcd** ⇒ gpmd dropped, no warning |
| 15 | same + `-map 0:3 -c:d copy` | streams: av1, aac, **gpmd**, tmcd |
| 16 | same + `-map 0:d:1` | streams: av1, aac, **gpmd**, tmcd |
| 17 | gpmd payload MD5, source vs #15 output | both `7a5b00cc696375d56d7c5390b79203fb`, 13,492 B ⇒ byte-exact |
| 18 | `-map 0 -map -0:2 -map -0:4 -c copy` | ✅ works; gpmd preserved |
| 19 | `ffmpeg -h decoder=hevc` | shows `-view_ids`, `-view_ids_available`, `-view_pos_available` |
| 20 | `ffmpeg -layouts` | **no** ambisonic entry |
| 21 | ambisonic Opus tests (see D1) | default `-mapping_family` ⇒ hard error; `-mapping_family 2` ⇒ OK; `-c:a copy` ⇒ preserved |

---

## F) Every URL I actually fetched/opened

**GoPro / GPMF**
1. <https://github.com/gopro/gpmf-parser>
2. <https://raw.githubusercontent.com/gopro/gpmf-parser/main/README.md>
3. <https://raw.githubusercontent.com/gopro/gpmf-parser/main/docs/README.md>
4. <https://raw.githubusercontent.com/gopro/gpmf-write/main/README.md>
5. <https://api.github.com/repos/gopro/gpmf-parser/contents/>
6. <https://api.github.com/repos/gopro/gpmf-parser/contents/docs>
7. <https://api.github.com/repos/gopro/gpmf-parser/contents/samples>
8. <https://api.github.com/repos/gopro/gpmf-write/contents/>
9. <https://api.github.com/orgs/gopro/repos?per_page=100>
10. <https://raw.githubusercontent.com/gopro/gpmf-parser/main/samples/hero8.mp4> (real test asset)
11. <https://www.trekview.org/blog/injecting-camm-gpmd-telemetry-videos-part-5-gpmf/>

**FFmpeg tracker & mailing lists**
12. <https://trac.ffmpeg.org/ticket/8338>
13. <https://trac.ffmpeg.org/ticket/10579>
14. <https://trac.ffmpeg.org/ticket/11698>
15. <https://trac.ffmpeg.org/ticket/11642>, <https://trac.ffmpeg.org/ticket/8740>,
    <https://trac.ffmpeg.org/ticket/9390>, <https://trac.ffmpeg.org/ticket/10626> (linked from search hits)
16. <https://trac.ffmpeg.org/search?q=gpmd> · `?q=GPMF` · `?q=GoPro+telemetry` · `?q=MV-HEVC` ·
    `?q=spatial+video` · `?q=insv` · `?q=motionphoto` · `?q=MicroVideo` · `?q=gain+map` ·
    `?q=UltraHDR` · `?q=djmd` · `?q=DJI` · `?q=vexu` · `?q=st3d` · `?q=sv3d` · `?q=ambisonic` ·
    `?q=framepack` · `?q=stereo3d` · `?q=hevc_stereo` · `?q=ambisonic+ACN` · `?q=hero+eyes`
17. <https://ffmpeg.org/pipermail/ffmpeg-trac/2024-August/070427.html>
18. <https://ffmpeg.org/pipermail/ffmpeg-trac/2024-August/070434.html>
19. <https://ffmpeg.org/pipermail/ffmpeg-trac/2022-November/063873.html>
20. <https://ffmpeg.org/pipermail/ffmpeg-trac/2024-August/thread.html>
21. <https://ffmpeg.org/pipermail/ffmpeg-devel/2017-July/213951.html>
22. <https://ffmpeg.org/pipermail/ffmpeg-user/2024-January/057517.html> (MV-HEVC question, Jan 2024)

**FFmpeg documentation**
23. <https://ffmpeg.org/ffmpeg.html>
24. <https://ffmpeg.org/ffmpeg-utils.html>
25. <https://manpages.debian.org/trixie/ffmpeg/ffmpeg.1.en.html>

**FFmpeg source & commits**
26. <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/movenc.c>
27. <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/mov.c>
28. <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/isom.c>
29. <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/isom_tags.c>
30. <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavutil/channel_layout.h>
31. <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavutil/channel_layout.c>
32. <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/fftools/ffmpeg_opt.c>
33. <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/fftools/ffmpeg_mux_init.c>
34. <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/avcodec.h>
35. <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/doc/APIchanges>
36. <https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/doc/ffmpeg.texi>
37. <https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/refs/heads/master> (full master tree, grepped locally)
38. <https://github.com/FFmpeg/FFmpeg/commit/850a45aef10b50a2344a71055a30987aea23e48a> (+ `…/850a45ae….patch`)
39. <https://github.com/FFmpeg/FFmpeg/commit/1474687> (= `14746871e1d33de172d6cb32730d962068e3ccd2`; + `…/1474687.patch`)
40. <https://github.com/FFmpeg/FFmpeg/commit/6a428876> (= `6a428876fc4f1128644dcbc8e8fd814e1754262f`; + `.patch`)
41. <https://github.com/FFmpeg/FFmpeg/commit/5083f4ad> (= `5083f4ad8e26806b2113d8001dcbf20e220a7309`; + `.patch`)
42. <https://github.com/FFmpeg/FFmpeg/commit/b4189590> (= `b4189590a59159317f6316106e2f061e5c6df556`; + `.patch`)
43. <https://github.com/FFmpeg/FFmpeg/commit/86dee47e> (= `86dee47e397fe6bb0907adae8d4a54138a947646`; + `.patch`)

**Apple**
44. <https://developer.apple.com/av-foundation/HEVC-Stereo-Video-Profile.pdf>
45. <https://developer.apple.com/av-foundation/Stereo-Video-ISOBMFF-Extensions.pdf>
46. <https://developer.apple.com/av-foundation/Video-Contour-Map-Metadata.pdf>

**Android**
47. <https://developer.android.com/media/platform/motion-photo-format?hl=en>
48. <https://developer.android.com/media/platform/hdr-image-format?hl=en>

**Stack Exchange (via API + canonical links)**
49. <https://api.stackexchange.com/2.3/search/advanced?order=desc&sort=relevance&q=gopro%20metadata%20ffmpeg&site=stackoverflow&filter=withbody>
50. <https://stackoverflow.com/questions/67576853/copying-gopro-metadata-with-ffmpeg-could-not-find-tag-for-codec-none>
51. <https://stackoverflow.com/questions/51354696/ffmpeg-concat-and-preserve-metadata-streams>
52. <https://stackoverflow.com/questions/65376581/write-live-photo-metadata-to-video-using-ffmpeg>
53. <https://stackoverflow.com/questions/75727163/apple-avkit-avasset-tracks-method-does-not-see-all-tracks-in-gopro-mp4-files>
54. <https://stackoverflow.com/questions/78559313/how-to-extract-a-frame-from-an-insv-format-360-video-using-python>
55. <https://superuser.com/questions/1858318/how-to-make-apple-vision-pro-compatible-mv-hevc-files-with-x265-4-0-and-ffmpeg-7>
56. <https://superuser.com/questions/1853741/cant-get-ffmpeg-to-convert-samsung-motion-photos-from-jpeg-to-mp4>
    (both via <https://api.stackexchange.com/2.3/questions/{id}?site=superuser&filter=withbody>)

**Others**
57. <https://github.com/photoprism/photoprism/issues/5711> and
    <https://api.github.com/repos/photoprism/photoprism/issues/5711>
58. <https://raw.githubusercontent.com/CallMarcus/dji-drone-metadata-embedder/master/docs/MP4_TIMED_METADATA.md>
59. <https://onlinemanual.insta360.com/onex/en-us/operating-tutorials/storage/fileformat>
60. <https://onlinemanual.insta360.com/x5/en-us/faq/specs/fileformat> (fetched, JS shell only)
61. <https://gitlab.com/whitebox-aero/whitebox/-/work_items/68>

**Fetched but blocked / unusable (stated for completeness, NOT used as evidence):**
- <https://lists.ffmpeg.org/pipermail/ffmpeg-user/2024-January/057517.html> — Anubis anti-bot challenge
- <https://lists.ffmpeg.org/lore/ffmpeg-user/1ec0a907-cc97-4840-8115-d05ab8cadc62@betaapp.fastmail.com/> — Anubis
- <https://lists.mplayerhq.hu/pipermail/ffmpeg-devel/2017-July/213951.html> — Anubis (used the ffmpeg.org mirror instead)
- <https://superuser.com/questions/1853741> direct — HTTP 403 Cloudflare (used the SE API instead)
- <https://developer.android.com/media/platform/motion-photo-format> default fetch — returned only nav chrome (used `?hl=en` via curl instead)

---

## G) Search queries I ran

`web_search` (batched):
1. "GoPro GPMF specification github gopro/gpmf-parser"
2. "GPMF specification PDF GoPro metadata format"
3. "ffmpeg gpmd track"
4. "ffmpeg trac gopro telemetry gpmf"
5. "ffmpeg copy gpmd stream"
6. "ffmpeg -copy_unknown documentation"
7. "ffmpeg stream specifiers data attachments -map 0:d"
8. "ffmpeg trac ticket gpmd dropped"
9. "\"GPMF\" specification PDF \"General Purpose Metadata Format\" GoPro developer"
10. "gpmf-parser README gpmd handler MP4 structure"
11. "\"GPMF Specification\" GoPro pdf github gopro gpmf-parser docs"
12. "gpmf-parser docs GPMF_Specification"
13. "ffmpeg dji metadata box mp4 djmd"
14. "ffmpeg insta360 insv metadata track"
15. "ffmpeg MV-HEVC support trac spatial video"
16. "ffmpeg ambisonic channel layout ACN SN3D"
17. "ffmpeg insta360 insv not supported proprietary format"
18. "Insta360 insv file format documentation official"
19. "ffmpeg Ultra HDR gain map support"
20. "Android motion photo MicroVideo XMP specification"
21. "ffmpeg Ultra HDR gain map preserve re-encode"
22. "ffmpeg spatial video MV-HEVC decode 8.0 ffprobe"
23. "ffmpeg extract GoPro GPS telemetry gpmd command"
24. "ffmpeg Samsung motion photo mp4 dropped metadata"
25. "GoPro GPMF specification document \"GPMF Specification\" pdf"
26. "ffmpeg-devel gpmd GPMF patch remux"
27. "Insta360 insv format mp4 container specification gyro track"
28. "DJI drone mp4 metadata box vs track telemetry extraction"
29. "\"GPMF Specification\" gopro docs pdf metadata format description"
30. "ffmpeg trac gpmd stream copy -map 0 data track"
31. "Insta360 developer SDK insv file format specification"
32. "insv file format structure reverse engineered github"
33. "\"GPMF_Specification\" OR \"GPMF Specification.pdf\" GoPro"
34. "\"gpmd\" ffmpeg \"-map 0\" copy telemetry lost forum"
35. "GoPro forum ffmpeg telemetry gpmd not copied mp4"
36. "ffmpeg spatial video vexu st3d write second view"
37. "\"djmd\" DJI metadata track format exiftool"
38. "Android Ultra HDR Image Format v1.0 gain map specification developer.android.com"
39. "Insta360 official insv file format documentation firmware"
40. "ffmpeg can not open insv insta360 convert to mp4 ffmpeg error"
41. "GPMF specification official document GoPro developer PDF spec"

FFmpeg trac `search?q=` (listed in F16). GitHub code search was done locally over the downloaded
master tarball with `grep`, which is stronger than the web code search.

---

## H) Explicit "no source found" list

- A standalone/official **"GPMF Specification" PDF** — not found; GoPro publishes only
  `gpmf-parser` and `gpmf-write` (+ their READMEs).
- Any **FFmpeg trac ticket or mailing-list thread about Insta360/`.insv`** — none exists
  (`q=insv` → "No matches found").
- Any **official DJI document describing `djmd`/`dbgi`**, and any evidence of a modern "DJI meta
  **box**" distinct from the `djmd` *track* / "DJI meta" handler name.
- Any **trac ticket or public bug report about Ultra HDR gain maps being lost** by FFmpeg — none
  found; my conclusion there is inferred from the official format + zero-hit source grep.
- Any **public statement/bug report confirming that FFmpeg's VEXU round-trip drops specific Apple
  fields** (hero eye, baseline, disparity) — my note on `vexu` being partial is a code-reading
  inference, not a sourced claim.
- Any **official Insta360 document describing the internal ISOBV/INSV box or track layout**.
- Any **source confirming Samsung "Motion Photo" is the Android/Google spec** byte-for-byte.

---

## I) Practical recommendations for the pipeline

1. **Keep the telemetry:** add an explicit data-stream map and a copy codec for it, e.g.
   `-map 0:v:0 -map 0:a? -map 0:d:1 -c:v libsvtav1 -crf 36 -cpu-used 8 -c:a copy -c:d copy`
   (or `-map 0:3`, but absolute indices are fragile). Verified byte-exact for `gpmd`.
   For a "keep everything you can" variant: `-map 0 -map -0:2 -map -0:4 -c copy` (i.e. exclude the
   `tmcd`/`fdsc` `codec none` tracks that make `-map 0` fail).
2. **Never rely on `-map 0`** for GoPro/DJI files: it aborts the whole run
   (`Could not find tag for codec none`). `-copy_unknown`/`-ignore_unknown` do **not** help.
   `-map 0:d?` is actively harmful — it selects the unsupported tracks too.
3. **Verify, don't assume:** compare `ffprobe -show_streams` of input and output, and diff the
   extracted payload (`-map 0:d:N -c copy -f data payload.bin` + `md5`). The failure mode here is
   *silent*: FFmpeg exits 0 in the parent's pipeline while the telemetry is gone.
4. **Spatial video:** a transcode keeps only the base view by default — request views explicitly
   (`-map 0:v:view:all`, `-vpos:left/right`, or the `view_ids` decoder option), or keep `-c copy`.
   Also expect VEXU/`pack` metadata not to round-trip perfectly.
5. **Motion photos / Ultra HDR:** FFmpeg cannot preserve these at all (no support in master); the
   video and gain map must be carried through by other tooling (e.g. ExifTool / libultrahdr).
6. **Ambisonic audio:** keep `-c:a copy`; if you must re-encode Opus, add `-mapping_family 2`, and
   avoid any filter path that triggers `aresample` (swresample rejects ambisonic layouts).
