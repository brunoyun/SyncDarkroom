#!/bin/bash
# Downloads the smart-search (CLIP) model into Models/, which is bundled into the app.
# The files are pinned to a revision and checked against their SHA-256, and are not kept in git.
#   - Apple MobileCLIP-S0 (Core ML), https://huggingface.co/apple/coreml-mobileclip
#     (Apple Sample Code License — see Models/LICENSE-MobileCLIP.txt once downloaded)
#   - OpenAI CLIP tokenizer merges, https://huggingface.co/openai/clip-vit-base-patch32 (MIT)
set -euo pipefail
cd "$(dirname "$0")/.."

MOBILECLIP_REV=3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947
CLIP_REV=3d74acf9a28c67741b2f4f2ea7635f0aaf6f0268
DEST=Models

FILES=(
  "apple/coreml-mobileclip|$MOBILECLIP_REV|mobileclip_s0_image.mlpackage/Manifest.json|fe07dde983dae92c1799132816ce55f9ff8487f2681b530abf7222025aa27fa4"
  "apple/coreml-mobileclip|$MOBILECLIP_REV|mobileclip_s0_image.mlpackage/Data/com.apple.CoreML/model.mlmodel|2c1afa132c41c6535817cc67894bd7484bc2cbd084ed5e2f12b24f611af17591"
  "apple/coreml-mobileclip|$MOBILECLIP_REV|mobileclip_s0_image.mlpackage/Data/com.apple.CoreML/weights/weight.bin|87d8f63997bbd2f38ba7defeaaa2c571928bdece56aa9629542198b3ce906ed6"
  "apple/coreml-mobileclip|$MOBILECLIP_REV|mobileclip_s0_text.mlpackage/Manifest.json|a7cb0864a627468a953afd107262097ad74a0fcf82e49df7e00b9c86385bb7db"
  "apple/coreml-mobileclip|$MOBILECLIP_REV|mobileclip_s0_text.mlpackage/Data/com.apple.CoreML/model.mlmodel|81eba836ff4dbc8ae021d70006288b533ba7eed3c2973d245b0d5ea047305bfd"
  "apple/coreml-mobileclip|$MOBILECLIP_REV|mobileclip_s0_text.mlpackage/Data/com.apple.CoreML/weights/weight.bin|34723e51445b2630106e94e1fdbebed80e7676b404fb839f4eb9bec97bdcad68"
  "openai/clip-vit-base-patch32|$CLIP_REV|merges.txt|f526393189112391ce6f9795d4695f704121ce452c3aad1f5335cc41337eba85"
)

for entry in "${FILES[@]}"; do
  IFS='|' read -r repo rev path sha <<< "$entry"
  out="$DEST/$path"
  [[ "$path" == "merges.txt" ]] && out="$DEST/clip-merges.txt"
  if [[ -f "$out" ]] && [[ "$(shasum -a 256 "$out" | cut -d' ' -f1)" == "$sha" ]]; then continue; fi
  mkdir -p "$(dirname "$out")"
  echo "Downloading $repo/$path"
  curl -fL --retry 3 -o "$out.part" "https://huggingface.co/$repo/resolve/$rev/$path"
  actual="$(shasum -a 256 "$out.part" | cut -d' ' -f1)"
  if [[ "$actual" != "$sha" ]]; then
    echo "error: checksum mismatch for $path ($actual)" >&2
    rm -f "$out.part"
    exit 1
  fi
  mv "$out.part" "$out"
done

if [[ ! -f "$DEST/LICENSE-MobileCLIP.txt" ]]; then
  curl -fsL "https://huggingface.co/apple/coreml-mobileclip/resolve/$MOBILECLIP_REV/README.md" -o "$DEST/LICENSE-MobileCLIP.txt" || true
fi
echo "Models ready in $DEST/"
