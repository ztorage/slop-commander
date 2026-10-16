"""Texture upscaling for the remake.

Default is an edge-aware pixel-art scaler (EPX/Scale2x applied repeatedly) followed by a
light smoothing pass, which keeps the hand-drawn 1993 texel art crisp instead of blurry.
If `realesrgan-ncnn-vulkan` is on PATH it is used instead (ML super-resolution).
"""
import os, shutil, subprocess, tempfile
import numpy as np
from PIL import Image, ImageFilter

REALESRGAN = shutil.which('realesrgan-ncnn-vulkan')


def _scale2x(a):
    """EPX / Scale2x on an HxWx4 uint8 array."""
    p = np.pad(a, ((1, 1), (1, 1), (0, 0)), mode='edge')
    P = p[1:-1, 1:-1]
    A = p[:-2, 1:-1]; B = p[1:-1, 2:]; C = p[1:-1, :-2]; D = p[2:, 1:-1]
    eq = lambda x, y: np.all(x == y, axis=-1)
    cond = ~eq(A, D) & ~eq(C, B)
    e0 = np.where((cond & eq(C, A))[..., None], A, P)
    e1 = np.where((cond & eq(A, B))[..., None], B, P)
    e2 = np.where((cond & eq(D, C))[..., None], C, P)
    e3 = np.where((cond & eq(B, D))[..., None], D, P)
    h, w = a.shape[:2]
    out = np.empty((h * 2, w * 2, 4), np.uint8)
    out[0::2, 0::2] = e0; out[0::2, 1::2] = e1
    out[1::2, 0::2] = e2; out[1::2, 1::2] = e3
    return out


def upscale_rgba(img, factor=4):
    if factor <= 1:
        return img
    if REALESRGAN and factor == 4:
        with tempfile.TemporaryDirectory() as td:
            src, dst = os.path.join(td, 'i.png'), os.path.join(td, 'o.png')
            img.save(src)
            r = subprocess.run([REALESRGAN, '-i', src, '-o', dst, '-n', 'realesrgan-x4plus-anime', '-s', '4'],
                               capture_output=True)
            if r.returncode == 0 and os.path.exists(dst):
                up = Image.open(dst).convert('RGBA')
                # keep the original hard alpha mask (scaled), ML models smear transparency
                alpha = img.getchannel('A').resize(up.size, Image.NEAREST)
                up.putalpha(alpha)
                return up
    a = np.asarray(img.convert('RGBA'))
    f = 1
    while f < factor:
        a = _scale2x(a); f *= 2
    out = Image.fromarray(a, 'RGBA')
    rgb = out.convert('RGB').filter(ImageFilter.SMOOTH)
    rgb.putalpha(out.getchannel('A'))
    return rgb
