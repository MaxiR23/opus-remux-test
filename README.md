# opus-remux-test

Experimental WebM/Opus to CAF remuxer. Validates the full pipeline in GitHub Actions (macOS runner).

## What it tests

1. **EBML parsing** - Extracts OpusHead + Opus packets from WebM container
2. **CAF muxing** - Writes valid CAF file with desc, chan, kuki, pakt, data chunks
3. **afinfo validation** - Apple's native tool verifies the CAF structure
4. **AVFoundation loading** - Checks if AVURLAsset accepts the file as playable

All results in Actions logs. No device needed.

## Architecture

```
WebM/Opus input
      |
  WebMDemuxer.swift    Parse EBML -> OpusHead + raw Opus packets
      |
  CAFMuxer.swift       Write CAF: desc + chan + kuki + pakt + data
      |
  /tmp/output.caf      Validate with afinfo + AVFoundation
```

## Files

```
Sources/OpusRemuxTest/
  main.swift           Test runner (download, demux, mux, validate)
  WebMDemuxer.swift    EBML parser
  CAFMuxer.swift       CAF writer
  RemuxError.swift     Error types
Package.swift          Swift Package manifest
```

## Run

**GitHub Actions (automatic):** Push to main or trigger manually. Optionally pass a WebM URL.

**Local (if you have macOS):**
```bash
swift run
# or with a custom URL:
swift run OpusRemuxTest "https://example.com/audio.webm"
```

## What to look for in logs

```
[PASS] afinfo accepted the CAF file     -> CAF structure is valid
[PASS] AVURLAsset loaded successfully   -> AVPlayer will accept it
  playable: true                        -> can be played
  duration: 5.0s                        -> correct duration
  tracks: 1                             -> audio track found
```

If both pass, the remux works and we can move to Phase 2 (progressive streaming on iOS).
