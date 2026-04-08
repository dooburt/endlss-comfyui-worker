#!/usr/bin/env bash
# v14 smoke tests — auto-polling version
# Requires: RUNPOD_API_KEY env var set

IMAGE_ENDPOINT="8lgc121i8czhwh"
VIDEO_ENDPOINT="rvrwlzxuxbfo3h"

poll_job() {
    local ENDPOINT=$1
    local JOB_ID=$2
    local LABEL=$3
    local MAX_POLLS=${4:-120}  # default 120 polls (10 mins at 5s intervals)

    echo "Polling $LABEL job: $JOB_ID"
    for i in $(seq 1 $MAX_POLLS); do
        RESULT=$(curl -s "https://api.runpod.ai/v2/${ENDPOINT}/status/${JOB_ID}" \
            -H "Authorization: Bearer $RUNPOD_API_KEY")

        STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','UNKNOWN'))" 2>/dev/null)

        if [ "$STATUS" = "COMPLETED" ] || [ "$STATUS" = "FAILED" ]; then
            echo ""
            echo "=== $LABEL result ($STATUS) ==="
            # Truncate base64 data for readability
            echo "$RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
# Truncate long base64 strings
if 'output' in data and 'images' in data['output']:
    for img in data['output']['images']:
        if 'data' in img and len(img['data']) > 200:
            img['data'] = img['data'][:100] + '...[TRUNCATED]...' + img['data'][-100:]
print(json.dumps(data, indent=2))
"
            return 0
        fi

        printf "\r  Poll %d/%d — status: %s" "$i" "$MAX_POLLS" "$STATUS"
        sleep 5
    done

    echo ""
    echo "=== $LABEL: timed out after $MAX_POLLS polls ==="
    return 1
}

# --- Test 1: flux-schnell (image) ---
echo "=== Test 1: flux-schnell (image endpoint, async) ==="
echo "Submitting job..."

RESPONSE=$(curl -s -X POST "https://api.runpod.ai/v2/${IMAGE_ENDPOINT}/run" \
  -H "Authorization: Bearer $RUNPOD_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "input": {
      "workflow": {
        "6": {"inputs": {"text": "a golden retriever in a sunflower field", "clip": ["11", 0]}, "class_type": "CLIPTextEncode"},
        "8": {"inputs": {"samples": ["13", 0], "vae": ["10", 0]}, "class_type": "VAEDecode"},
        "9": {"inputs": {"filename_prefix": "ComfyUI", "images": ["8", 0]}, "class_type": "SaveImage"},
        "10": {"inputs": {"vae_name": "ae.safetensors"}, "class_type": "VAELoader"},
        "11": {"inputs": {"clip_name1": "clip_l.safetensors", "clip_name2": "t5xxl_fp8_e4m3fn.safetensors", "type": "flux"}, "class_type": "DualCLIPLoader"},
        "13": {"inputs": {"seed": 0, "steps": 4, "cfg": 1, "sampler_name": "euler", "scheduler": "simple", "denoise": 1, "model": ["14", 0], "positive": ["16", 0], "negative": ["17", 0], "latent_image": ["15", 0]}, "class_type": "KSampler"},
        "14": {"inputs": {"unet_name": "flux1-schnell.safetensors", "weight_dtype": "default"}, "class_type": "UNETLoader"},
        "15": {"inputs": {"width": 512, "height": 512, "batch_size": 1}, "class_type": "EmptyLatentImage"},
        "16": {"inputs": {"guidance": 3.5, "conditioning": ["6", 0]}, "class_type": "FluxGuidance"},
        "17": {"inputs": {"text": "", "clip": ["11", 0]}, "class_type": "CLIPTextEncode"}
      }
    }
  }')

IMAGE_JOB_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

if [ -n "$IMAGE_JOB_ID" ]; then
    echo "Submitted: $IMAGE_JOB_ID"
    poll_job "$IMAGE_ENDPOINT" "$IMAGE_JOB_ID" "flux-schnell" 120
else
    echo "Failed to submit image job:"
    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
fi

echo ""
echo "=== Test 2: hunyuan-i2v (video endpoint, async) ==="
echo "Submitting job..."

WORKFLOW=$(cat /home/dooburt/Projects/endlss/backend/src/workflows/hunyuan-i2v.json)

RESPONSE=$(curl -s -X POST "https://api.runpod.ai/v2/${VIDEO_ENDPOINT}/run" \
  -H "Authorization: Bearer $RUNPOD_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "
import json, sys
workflow = json.loads('''${WORKFLOW}''')
payload = {
    'input': {
        'images': [{'name': 'input.png', 'image': 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAMklEQVR4nGI5ZdXAQEvARFPTRy0YtWDUglELRi0YtWDUglELRi0YtWDUAioCQAAAAP//E24Bx3jUKuYAAAAASUVORK5CYII='}],
        'workflow': workflow
    }
}
print(json.dumps(payload))
")")

VIDEO_JOB_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

if [ -n "$VIDEO_JOB_ID" ]; then
    echo "Submitted: $VIDEO_JOB_ID"
    poll_job "$VIDEO_ENDPOINT" "$VIDEO_JOB_ID" "hunyuan-i2v" 240
else
    echo "Failed to submit video job:"
    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
fi
