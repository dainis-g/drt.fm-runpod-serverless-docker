"""
Patch the built-in worker-comfyui handler to also return video files.

The default handler only collects SaveImage outputs (under the "images" key).
VHS_VideoCombine outputs its files under a "gifs" key (legacy name — actual
format is mp4/webm/etc depending on workflow config). This patch adds handling
for that key so video files are returned in the API response as "videos".

Applied at Docker build time via: python patch_handler_video.py
"""

import re

HANDLER_PATH = "/handler.py"

with open(HANDLER_PATH, "r") as f:
    code = f.read()

# 1. After the "images" processing block, add "gifs" (video) processing.
#    We insert it right before the "other_keys" warning check.
old_other_keys = '''            # Check for other output types
            other_keys = [k for k in node_output.keys() if k != "images"]'''

new_video_block = '''            # Handle video outputs from VHS_VideoCombine (uses "gifs" key)
            if "gifs" in node_output:
                print(
                    f"worker-comfyui - Node {node_id} contains {len(node_output['gifs'])} video(s)"
                )
                for video_info in node_output["gifs"]:
                    filename = video_info.get("filename")
                    subfolder = video_info.get("subfolder", "")
                    vid_type = video_info.get("type")

                    if vid_type == "temp":
                        print(
                            f"worker-comfyui - Skipping video {filename} because type is 'temp'"
                        )
                        continue

                    if not filename:
                        warn_msg = f"Skipping video in node {node_id} due to missing filename: {video_info}"
                        print(f"worker-comfyui - {warn_msg}")
                        errors.append(warn_msg)
                        continue

                    video_bytes = get_image_data(filename, subfolder, vid_type)

                    if video_bytes:
                        file_extension = os.path.splitext(filename)[1] or ".mp4"

                        if os.environ.get("BUCKET_ENDPOINT_URL"):
                            try:
                                with tempfile.NamedTemporaryFile(
                                    suffix=file_extension, delete=False
                                ) as temp_file:
                                    temp_file.write(video_bytes)
                                    temp_file_path = temp_file.name

                                print(f"worker-comfyui - Uploading video {filename} to S3...")
                                s3_url = rp_upload.upload_image(job_id, temp_file_path)
                                os.remove(temp_file_path)
                                print(
                                    f"worker-comfyui - Uploaded video {filename} to S3: {s3_url}"
                                )
                                video_output_data.append(
                                    {
                                        "filename": filename,
                                        "type": "s3_url",
                                        "data": s3_url,
                                    }
                                )
                            except Exception as e:
                                error_msg = f"Error uploading video {filename} to S3: {e}"
                                print(f"worker-comfyui - {error_msg}")
                                errors.append(error_msg)
                                if "temp_file_path" in locals() and os.path.exists(
                                    temp_file_path
                                ):
                                    try:
                                        os.remove(temp_file_path)
                                    except OSError as rm_err:
                                        print(
                                            f"worker-comfyui - Error removing temp file {temp_file_path}: {rm_err}"
                                        )
                        else:
                            try:
                                base64_video = base64.b64encode(video_bytes).decode(
                                    "utf-8"
                                )
                                video_output_data.append(
                                    {
                                        "filename": filename,
                                        "type": "base64",
                                        "data": base64_video,
                                    }
                                )
                                print(f"worker-comfyui - Encoded video {filename} as base64")
                            except Exception as e:
                                error_msg = f"Error encoding video {filename} to base64: {e}"
                                print(f"worker-comfyui - {error_msg}")
                                errors.append(error_msg)
                    else:
                        error_msg = f"Failed to fetch video data for {filename} from /view endpoint."
                        errors.append(error_msg)

            # Check for other output types
            other_keys = [k for k in node_output.keys() if k not in ("images", "gifs")]'''

if old_other_keys not in code:
    print("ERROR: Could not find the 'other_keys' anchor in handler.py")
    print("The handler.py format may have changed. Manual patching required.")
    exit(1)

code = code.replace(old_other_keys, new_video_block)

# 2. Add video_output_data list initialization alongside output_data
code = code.replace(
    "    output_data = []\n    errors = []",
    "    output_data = []\n    video_output_data = []\n    errors = []"
)

# 3. Add videos to the final result alongside images
code = code.replace(
    '''    if output_data:
        final_result["images"] = output_data''',
    '''    if output_data:
        final_result["images"] = output_data

    if video_output_data:
        final_result["videos"] = video_output_data'''
)

# 4. Update the "no output" checks to also consider video data
code = code.replace(
    "    if not output_data and errors:",
    "    if not output_data and not video_output_data and errors:"
)
code = code.replace(
    "    elif not output_data and not errors:",
    "    elif not output_data and not video_output_data and not errors:"
)
code = code.replace(
    '''    print(f"worker-comfyui - Job completed. Returning {len(output_data)} image(s).")''',
    '''    print(f"worker-comfyui - Job completed. Returning {len(output_data)} image(s), {len(video_output_data)} video(s).")'''
)

with open(HANDLER_PATH, "w") as f:
    f.write(code)

print("SUCCESS: handler.py patched with video (gifs) output support")
print(f"  - Added VHS_VideoCombine 'gifs' key handling")
print(f"  - Videos returned in output.videos[] array")
print(f"  - Same base64/S3 upload logic as images")
