#!/usr/bin/env bash
set -e  # Stop the script immediately if compilation or git fails

# 1. Read and increment the build attempt counter
COUNTER_FILE=".build_attempt"
if [ -f "$COUNTER_FILE" ]; then
    attempt=$(cat "$COUNTER_FILE")
else
    attempt=0
fi

build_attempt=$((attempt + 1))

echo "========================================"
echo " Starting Build Attempt #${build_attempt}"
echo "========================================"

# 2. Clean and compile the package
echo "[*] Cleaning and compiling package..."
make clean
make package FINALPACKAGE=1

# 3. Move the packages directory to parent
echo "[*] Moving packages folder..."
rm -rf ../packages
mv packages ..

# 4. Save the updated build counter
echo "$build_attempt" > "$COUNTER_FILE"

# 5. Stage, commit, and push
echo "[*] Staging, committing, and pushing to Git..."
git add -A . ../packages
git commit -m "build $build_attempt"
git push

echo "========================================"
echo " Build #${build_attempt} completed and pushed successfully!"
echo "========================================"
