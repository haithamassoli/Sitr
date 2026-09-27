# Sitr Music helper notices

The backend code in this directory is adapted from [nomusic](https://github.com/ibraheemtuffaha/nomusic), commit `9cc511fe697fb6c0372b639406fc53581cbcf531`. The upstream README declares the MIT License. Changes include packaging as a macOS helper, bundling one model and its audio tools, and restricting browser origins.

Copyright (c) nomusic contributors. Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

The helper also bundles [Demucs](https://github.com/facebookresearch/demucs), [PyTorch](https://pytorch.org/), [yt-dlp](https://github.com/yt-dlp/yt-dlp) and its EJS scripts, [FFmpeg](https://ffmpeg.org/) via imageio-ffmpeg, [FFprobe](https://github.com/SavageCore/node-ffprobe-installer) from `@ffprobe-installer/darwin-arm64` 5.0.1, and [Deno](https://deno.com/). The bundled FFmpeg executable reports GPL-2.0-or-later; FFprobe reports LGPL-2.1-or-later. Their license texts are in `licenses/`.

**Model weights:** the `htdemucs` weights are not included in the app. On first use the helper downloads `955717e8-8726e21a.th` from Meta's official Demucs server (`dl.fbaipublicfiles.com`) through Demucs itself, which verifies the file hash, and stores it in the helper's Application Support folder.

**FFmpeg source code (GPL/LGPL):** the bundled `ffmpeg` is FFmpeg 7.1 built with `--enable-gpl`, as shipped by imageio-ffmpeg 0.6.0; the bundled `ffprobe` is FFmpeg n4.4.1 from `@ffprobe-installer/darwin-arm64` 5.0.1. Their corresponding source code is available at https://ffmpeg.org/releases/ffmpeg-7.1.tar.xz and https://ffmpeg.org/releases/ffmpeg-4.4.1.tar.xz, with build details at https://github.com/imageio/imageio-binaries and https://github.com/SavageCore/node-ffprobe-installer. On request, the Sitr maintainers will provide a copy of that source code for at least three years from each release. License texts are in `licenses/`.
