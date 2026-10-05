# Releasing a new version

1. Bump `VERSION` near the top of `install.sh`.
2. Commit, then tag the commit, using the version from step 1:

   ```bash
   git tag v1.0.0
   ```

3. Build the zip from the tag. It contains `install.sh`, `README.md` and `LICENSE` with LF line endings and the executable bit set. `test/` and the git files are left out.

   ```bash
   git archive --format=zip --prefix=pi-srt-stream-node/ -o dist/pi-srt-stream-node-v1.0.0.zip v1.0.0
   ```

4. Push the code and tags to GitHub:

   ```bash
   git push --follow-tags
   ```

5. On Fourthwall, upload the new zip to the product, replacing the old file.
