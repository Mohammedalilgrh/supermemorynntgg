#!/bin/bash

# Batch Viral Video Processor
# Reads JSON from stdin and processes all videos

set -e

# Read JSON from stdin
JSON_INPUT=$(cat)

# Parse total videos
TOTAL=$(echo "$JSON_INPUT" | jq '.videos | length')
echo "Processing $TOTAL videos" >&2

# Results array
RESULTS="[]"

# Process each video
for i in $(seq 0 $((TOTAL - 1))); do
    VIDEO_URL=$(echo "$JSON_INPUT" | jq -r ".videos[$i].video_files[0].link")
    VIDEO_ID=$(echo "$JSON_INPUT" | jq -r ".videos[$i].id")
    
    if [ "$VIDEO_URL" != "null" ] && [ -n "$VIDEO_URL" ]; then
        echo "Processing video $((i+1))/$TOTAL: $VIDEO_ID" >&2
        RESULT=$(/scripts/viral_processor.sh "$VIDEO_URL" "$VIDEO_ID" "/tmp/viral_output")
        RESULTS=$(echo "$RESULTS" | jq ". += [$RESULT]")
    fi
done

# Output final JSON
cat << EOF
{
    "total_processed": $TOTAL,
    "videos": $RESULTS,
    "output_dir": "/tmp/viral_output"
}
EOF
