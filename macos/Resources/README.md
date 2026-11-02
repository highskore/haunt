# Resources

`openai-mark.png` (18×18) and `openai-mark@2x.png` (36×36) are the OpenAI mark, used as the Codex row
icon. They are unmodified copies of the template images (white on transparent) that OpenAI's Codex.app
ships for its menu bar:

- `/Applications/Codex.app/Contents/Resources/chatgptTemplate.png`,
  sha256 `98d26a9580680c0ddd73d1ca3dbe35e2cccdc110502ed2e97d750c0836bad25a`
- `/Applications/Codex.app/Contents/Resources/chatgptTemplate@2x.png`,
  sha256 `e87df5988826d9cf4a77b651c65c1924054bd1b8d4127334aad5b44e9fb5a318`

They come from Codex.app 26.715.31925 (bundle id `com.openai.codex`, signed by team `2DC432GLL2`).
Haunt loads both as one template image, tints it to the row's text colour, and draws it at its native
18 pt on whole pixels, so neither scale is resampled. The mark belongs to OpenAI. It is used here only
to identify Codex sessions.
