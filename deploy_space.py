"""Create (or update) a Hugging Face Docker Space from this repository.

Configuration comes from environment variables (set by the GitHub workflow):

  HF_TOKEN          required  Hugging Face token with WRITE access (GitHub secret)
  SPACE_ID          optional  "username/space-name"; default: "<your HF username>/etm-muscriptor"
  SPACE_HARDWARE    optional  cpu-basic (free, default) | t4-small | l4x1 | a10g-small ...  (GPUs are paid)
  MUSCRIPTOR_MODEL  optional  small | medium | large   (default: small on CPU, medium on GPU)
  SPACE_PRIVATE     optional  "true" (default) or "false"
"""
import os
import sys

from huggingface_hub import HfApi, SpaceHardware


def main() -> None:
    token = os.environ.get("HF_TOKEN", "").strip()
    if not token:
        sys.exit("HF_TOKEN is missing. Add it under GitHub > Settings > Secrets and variables > Actions.")

    api = HfApi(token=token)

    user = api.whoami()["name"]
    space_id = os.environ.get("SPACE_ID", "").strip() or f"{user}/etm-muscriptor"
    hardware = os.environ.get("SPACE_HARDWARE", "").strip() or "cpu-basic"
    model = os.environ.get("MUSCRIPTOR_MODEL", "").strip() or ("small" if hardware.startswith("cpu") else "medium")
    private = os.environ.get("SPACE_PRIVATE", "true").strip().lower() != "false"

    if model not in ("small", "medium", "large"):
        sys.exit(f"MUSCRIPTOR_MODEL must be small, medium or large (got {model!r}).")

    print(f"Space: {space_id} | hardware: {hardware} | model: {model} | private: {private}")

    api.create_repo(space_id, repo_type="space", space_sdk="docker", private=private, exist_ok=True)
    api.update_repo_settings(space_id, repo_type="space", private=private)

    # The weights are gated: the Space needs a token that has accepted the model licenses.
    api.add_space_secret(space_id, "HF_TOKEN", token)
    api.add_space_variable(space_id, "MUSCRIPTOR_MODEL", model)

    if hardware != "cpu-basic":
        api.request_space_hardware(space_id, SpaceHardware(hardware))

    api.upload_folder(
        folder_path=".",
        repo_id=space_id,
        repo_type="space",
        commit_message="Deploy from GitHub Actions",
        ignore_patterns=[
            ".git/**",
            ".github/**",
            "tests/**",
            "**/__pycache__/**",
            "**/node_modules/**",
            ".venv/**",
            "deploy.sh",
            "swarm.yml",
            ".pre-commit-config.yaml",
        ],
    )

    print(f"\nDone. Open: https://huggingface.co/spaces/{space_id}")
    print("The first build takes a while (Node + PyTorch + MuseScore). Watch the 'Logs' tab on the Space.")


if __name__ == "__main__":
    main()
