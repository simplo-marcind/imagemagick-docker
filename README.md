[![Docker Automated build](https://img.shields.io/docker/automated/dpokidov/imagemagick.svg)](https://hub.docker.com/r/dpokidov/imagemagick/)
[![Docker Pulls](https://img.shields.io/docker/pulls/dpokidov/imagemagick)](https://hub.docker.com/r/dpokidov/imagemagick/)
![ci](https://github.com/dooman87/imagemagick-docker/workflows/ci/badge.svg)

# imagemagick-docker

## Overview

Delivers the latest version of the [ImageMagick](https://github.com/ImageMagick/ImageMagick) 7 to your environment in a Docker container.

The purpose of this image is to be able to run the latest version of ImageMagick in stable
Linux environment to support next generation image format that could be used on Web. 

## Usage

By default, a container will run convert command

```
$ docker run -v /your/images:/imgs dpokidov/imagemagick /imgs/sample.png -resize 100x100 /imgs/resized-sample.png
```

You can change entrypoint and pass other IM commands to execute. For instance,

```
$ docker run --entrypoint=identify -v /your/images:/imgs dpokidov/imagemagick /imgs/sample.png
```

## Base images 

There are three base images: Debian Trixie, Debian Bullseye (default), and Ubuntu Focal.  

Use tags to switch between base images. 

All images support the same set of formats:

| Base Image      | Jpeg | PNG | WebP | AVIF | JPEG XL | JpegXR  | PDF  | TIFF |
|-----------------|:----:|:---:|:----:|:----:|:-------:|:-------:|:----:|:----:|
| Debian Bullseye | ✅    |  ✅  |  ✅   |  ✅   |    ✅    |    ✅    |  ✅   |  ✅   |
| Debian Trixie   | ✅    |  ✅  |  ✅   |  ✅   |    ✅    |    ✅    |  ✅   |  ✅   |
| Ubuntu Focal    |  ✅   |  ✅  |  ✅   |  ✅   |    ✅    |    ✅    |  ✅   |  ✅   |

Debian Trixie is using a different entrypoint - `magick` oppose to `convert` in older images.

## JPG converter server (Debian Trixie)

The Trixie image starts a Python HTTP server on port 80 that converts any uploaded image
(HEIC, PNG, WebP, AVIF, JPEG XL, TIFF, GIF, PDF, ...) to JPG. For multi-frame inputs (GIF, PDF, TIFF) the first frame/page is used.

```
$ docker run -p 8080:80 dpokidov/imagemagick:latest-trixie
$ curl -F file=@photo.heic -o photo.jpg http://localhost:8080/convert
$ curl -F file=@photo.heic -F quality=80 -o photo.jpg http://localhost:8080/convert
$ curl --data-binary @photo.heic -H "Content-Type: image/heic" -o photo.jpg http://localhost:8080/convert
```

Open `http://localhost:8080/` for an upload form. Settings via environment variables: `PORT` (80), `MAX_UPLOAD_MB` (100), `CONVERT_TIMEOUT` (120 s).

The server replaces the `magick` entrypoint. To run ImageMagick commands use `--entrypoint magick`:

```
$ docker run --rm --entrypoint magick -v /your/images:/imgs dpokidov/imagemagick:latest-trixie /imgs/sample.png /imgs/sample.webp
```

The image ships a restrictive `policy.xml` (resource limits, no `MVG`, `MSL`, `URL`, `@file` etc.) because the server handles untrusted uploads.
