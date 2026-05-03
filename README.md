# RunPod Serverless Deployment

Two Docker images for ComfyUI Serverless endpoints on RunPod:
- **Dockerfile.image** → Pony text-to-image + FaceDetailer + Upscale
- **Dockerfile.video** → Wan 2.2 image-to-video + text-to-video

Built on `runpod/worker-comfyui:5.8.5-base` (correct serverless base with built-in handler).

---

## Step 1: Push to GitHub

```bash
cd lib/services/runpod/real/serverless
git init
git add .
git commit -m "Initial commit — image + video Dockerfiles"
git branch -M main
git remote add origin https://github.com/YOUR_USER/drtfm-runpod-workers.git
git push -u origin main
```

## Step 2: Add GitHub Secrets

Go to **Settings → Secrets and variables → Actions → New repository secret** and add:

| Secret | Description |
|---|---|
| `DOCKERHUB_USERNAME` | Your Docker Hub username |
| `DOCKERHUB_TOKEN` | Docker Hub Access Token (Hub → Account Settings → Security → New Access Token) |
| `CIVITAI_TOKEN` | CivitAI API token (for gated Pony model downloads) |
| `HF_TOKEN` | HuggingFace token (for gated video model downloads) |

## Step 3: Run the Build

1. Go to **Actions** tab in GitHub.
2. Click **Build & Push Image Gen Docker** → **Run workflow** → tag: `latest`.
3. Wait for it to finish (~15-30 min for image, ~45-90 min for video).
4. Repeat with **Build & Push Video Gen Docker**.
5. Verify images exist at `hub.docker.com/r/YOUR_USER/comfyui-image-gen` and `comfyui-video-gen`.

## Step 4: Create RunPod Template

1. Go to [RunPod Console → Templates](https://runpod.io/console/serverless/user/templates) → **New Template**.
2. Set:
   - **Template Name**: `drtfm-image-gen`
   - **Template Type**: `Serverless` ⚠️ (NOT Pod)
   - **Container Image**: `YOUR_USER/comfyui-image-gen:latest`
   - **Container Disk**: `30 GB`
3. Click **Save Template**.
4. Repeat for video: name `drtfm-video-gen`, image `YOUR_USER/comfyui-video-gen:latest`, disk `50 GB`.

## Step 5: Create RunPod Endpoint

1. Go to [Serverless → Endpoints](https://www.runpod.io/console/serverless/user/endpoints) → **New Endpoint**.
2. Set:
   - **Endpoint Name**: `api-image-gen`
   - **Select Template**: `drtfm-image-gen`
   - **Active Workers**: `0`
   - **Max Workers**: `3`
   - **GPUs/Worker**: `1`
   - **Select GPU**: `RTX 4090` (add `RTX 3090`, `L4`, `A5000` as fallbacks)
   - **Idle Timeout**: `5` seconds
   - **FlashBoot**: `Enabled` ✅
   - **Network Volume**: None (not needed for launch)
3. Click **Deploy**.
4. Note down the **Endpoint ID** from the endpoint detail page.
5. Repeat for video with template `drtfm-video-gen`.

## Step 6: Test the Endpoint

Test with a minimal Pony workflow (no face fix, no LoRA — just raw txt2img):

```bash
# Replace ENDPOINT_ID and YOUR_API_KEY
curl -X POST "https://api.runpod.ai/v2/ENDPOINT_ID/run" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d '{
    "input": {
      "workflow": {
        "4": {
          "class_type": "CheckpointLoaderSimple",
          "inputs": { "ckpt_name": "cyberrealisticPony_v141.safetensors" }
        },
        "5": {
          "class_type": "EmptyLatentImage",
          "inputs": { "width": 512, "height": 512, "batch_size": 1 }
        },
        "6": {
          "class_type": "CLIPTextEncode",
          "inputs": { "text": "score_9, score_8_up, 1girl, portrait, natural lighting", "clip": ["4", 1] }
        },
        "7": {
          "class_type": "CLIPTextEncode",
          "inputs": { "text": "worst quality, blurry", "clip": ["4", 1] }
        },
        "3": {
          "class_type": "KSampler",
          "inputs": {
            "seed": 42,
            "steps": 20,
            "cfg": 7.0,
            "sampler_name": "euler_ancestral",
            "scheduler": "normal",
            "denoise": 1.0,
            "model": ["4", 0],
            "positive": ["6", 0],
            "negative": ["7", 0],
            "latent_image": ["5", 0]
          }
        },
        "8": {
          "class_type": "VAEDecode",
          "inputs": { "samples": ["3", 0], "vae": ["4", 2] }
        },
        "9": {
          "class_type": "SaveImage",
          "inputs": { "filename_prefix": "Test", "images": ["8", 0] }
        }
      }
    }
  }'
```

You'll get back a job ID:
```json
{"id": "abc-123-def", "status": "IN_QUEUE"}
```

Poll for the result:
```bash
curl "https://api.runpod.ai/v2/ENDPOINT_ID/status/JOB_ID" \
  -H "Authorization: Bearer YOUR_API_KEY"
```

When `status` changes to `COMPLETED`, the response will contain the image as base64. If it stays `IN_QUEUE` for more than ~60 seconds on a cold start, check the worker logs in the RunPod console.

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| Stays `IN_QUEUE` forever | Wrong base image or missing Python deps | Verify image is built FROM `worker-comfyui:5.8.5-base` |
| `FAILED` with node error | Custom node not installed or dep missing | Check worker logs, add missing `pip install` to Dockerfile |
| `FAILED` with CUDA error | GPU architecture mismatch | Restrict GPU types to RTX 4090/3090/A5000 |
| Image builds but no models found | Wrong model path in Dockerfile | Models must be under `/comfyui/models/` |

---

## Adding LoRAs Later (Without Rebuild)

When you need to add new LoRAs for SEO pages:
1. Create a **Network Volume** in RunPod (same region as your endpoint GPU).
2. Start a temporary Pod, mount the volume, download LoRAs to `/runpod-volume/models/loras/`.
3. Edit your endpoint → Advanced → attach the Network Volume.
4. ComfyUI will detect LoRAs from both Docker image and Network Volume.
