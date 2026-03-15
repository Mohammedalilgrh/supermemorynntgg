#!/bin/sh

AR_TEXT="$1"
EN_TEXT="$2"
OUT="/tmp/tts_output.mp3"

AR_AUDIO="/tmp/ar.mp3"
EN_AUDIO="/tmp/en.mp3"
MERGED="/tmp/merged.mp3"

echo "Generating Arabic voice..."

edge-tts \
--voice ar-SA-HamedNeural \
--rate="+5%" \
--text "$AR_TEXT" \
--write-media "$AR_AUDIO"

echo "Generating English voice..."

edge-tts \
--voice en-GB-RyanNeural \
--rate="+5%" \
--text "$EN_TEXT" \
--write-media "$EN_AUDIO"

echo "Merging audio..."

ffmpeg -y \
-i "$AR_AUDIO" \
-i "$EN_AUDIO" \
-filter_complex "[0:a][1:a]concat=n=2:v=0:a=1[a]" \
-map "[a]" \
"$OUT"

echo "Audio created:"
echo "$OUT"
