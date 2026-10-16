"""Optional AI upscaling for the 2D art (`tools/extract.py --ai`), run locally.

Pipeline: a 1x de-dither model (removes the 256-colour dither pattern), then a 4x
super-resolution model. Both are community models from OpenModelDB, downloaded on first use
into a per-user cache (never into the repository) and verified by SHA-256:

  1x-DitherDeleterV3-Smooth  ESRGAN   WTFPL             https://openmodeldb.info/models/1x-DitherDeleterV3-Smooth
  4x-UltraSharpV2            DAT      CC-BY-NC-SA-4.0   https://openmodeldb.info/models/4x-UltraSharpV2

Needs `pip install -r tools/requirements-ai.txt` (PyTorch + spandrel). Runs on Apple Silicon
(MPS), CUDA or, slowly, the CPU. Results are cached by input so re-extracting is quick.
Override the cache folder with $SC_CACHE.
"""
import hashlib, os, subprocess, sys, urllib.request
import numpy as np
from PIL import Image

PIPELINE = 'dd3+usv2-1'
MODELS = {
    'dedither': {
        'file': '1x-DitherDeleterV3-Smooth.pth',
        'url': 'https://drive.usercontent.google.com/download?id=1C6RTSFkBnidfBxBI6HjasgUEIgAzG3l3&export=download&confirm=t',
        'sha256': '1e98cb5427d16baeb83033c574d1ca4d8dadf05dd043b32c3ba98f75e30f6205',
    },
    'upscale': {
        'file': '4x-UltraSharpV2.safetensors',
        'url': 'https://huggingface.co/Kim2091/UltraSharpV2/resolve/main/4x-UltraSharpV2.safetensors',
        'sha256': '2b5db674aa8f3864a696dccd1d07d7cc0500fbf220f35044cd30eee9a7f971a7',
    },
}
PAD = 8            # edge padding so borders get the same treatment as the interior
TILE = 256         # larger images are processed in overlapping tiles
OVERLAP = 16

_state = {}


def cache_dir():
    if os.environ.get('SC_CACHE'):
        base = os.environ['SC_CACHE']
    elif sys.platform == 'darwin':
        base = os.path.expanduser('~/Library/Caches/sc-remake')
    else:
        base = os.path.join(os.environ.get('XDG_CACHE_HOME', os.path.expanduser('~/.cache')), 'sc-remake')
    os.makedirs(base, exist_ok=True)
    return base


def available():
    try:
        import torch, spandrel  # noqa: F401
        return True
    except ImportError:
        return False


def _sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def _download(url, dest):
    """HTTPS download; python.org builds on macOS often lack CA certificates, so use certifi's
    when installed and fall back to the system curl."""
    try:
        import ssl
        try:
            import certifi
            ctx = ssl.create_default_context(cafile=certifi.where())
        except ImportError:
            ctx = ssl.create_default_context()
        with urllib.request.urlopen(url, context=ctx) as r, open(dest, 'wb') as f:
            while chunk := r.read(1 << 20):
                f.write(chunk)
    except Exception:
        if subprocess.run(['curl', '-fsSL', '-o', dest, url]).returncode != 0:
            raise


def _fetch(spec, log):
    path = os.path.join(cache_dir(), 'models', spec['file'])
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path) and _sha256(path) == spec['sha256']:
        return path
    log(f'  downloading {spec["file"]} ...')
    tmp = path + '.part'
    _download(spec['url'], tmp)
    if _sha256(tmp) != spec['sha256']:
        os.remove(tmp)
        raise RuntimeError(f'{spec["file"]}: checksum mismatch (download failed or the file changed upstream)')
    os.replace(tmp, path)
    return path


def _load(log=print):
    if 'models' in _state:
        return _state
    import torch
    from spandrel import ModelLoader
    dev = torch.device('mps' if torch.backends.mps.is_available() else 'cuda' if torch.cuda.is_available() else 'cpu')
    _state['torch'] = torch
    _state['device'] = dev
    _state['models'] = [ModelLoader().load_from_file(_fetch(MODELS[k], log)).to(dev).eval()
                        for k in ('dedither', 'upscale')]
    log(f'  AI upscaler ready ({dev})')
    return _state


def _run(model, rgb):
    """float32 HxWx3 in [0, 1] -> model output, tiled for large inputs."""
    torch, dev = _state['torch'], _state['device']
    h, w = rgb.shape[:2]
    s = model.scale
    if h * w <= TILE * TILE * 2:
        with torch.no_grad():
            y = model(torch.from_numpy(rgb).permute(2, 0, 1)[None].to(dev))
        return y[0].permute(1, 2, 0).clamp(0, 1).float().cpu().numpy()
    out = np.zeros((h * s, w * s, 3), np.float32)
    weight = np.zeros((h * s, w * s, 1), np.float32)
    step = TILE - OVERLAP
    for y0 in range(0, max(h - OVERLAP, 1), step):
        for x0 in range(0, max(w - OVERLAP, 1), step):
            y1, x1 = min(y0 + TILE, h), min(x0 + TILE, w)
            t = _run(model, rgb[y0:y1, x0:x1])
            out[y0 * s:y1 * s, x0 * s:x1 * s] += t
            weight[y0 * s:y1 * s, x0 * s:x1 * s] += 1
    return out / np.maximum(weight, 1)


def upscale_rgb(rgb_u8):
    """HxWx3 uint8 -> 4Hx4Wx3 uint8 through de-dither + 4x."""
    st = _load()
    a = np.pad(rgb_u8, ((PAD, PAD), (PAD, PAD), (0, 0)), mode='edge').astype(np.float32) / 255
    for m in st['models']:
        a = _run(m, a)
    s = a.shape[0] // (rgb_u8.shape[0] + 2 * PAD)
    a = a[PAD * s:a.shape[0] - PAD * s, PAD * s:a.shape[1] - PAD * s]
    return (a * 255 + 0.5).astype(np.uint8)


def upscale_mask(alpha_u8, factor=4):
    """Alpha edges for the upscaled art: the pixel staircase is rounded off (Lanczos + blur), and
    the edge sits a fraction of a pixel outside the original one, so two layers that meet edge to
    edge (hair over a face, a head over a jacket) overlap instead of leaving a see-through seam."""
    from PIL import ImageFilter
    a = Image.fromarray(alpha_u8, 'L').resize((alpha_u8.shape[1] * factor, alpha_u8.shape[0] * factor), Image.LANCZOS)
    a = a.filter(ImageFilter.GaussianBlur(factor * 0.4))
    a = np.asarray(a).astype(np.float32) / 255
    a = np.clip((a - 0.3) * 2.2 + 0.5, 0, 1)
    return (a * 255 + 0.5).astype(np.uint8)


def crossfade_mask(alpha_u8, factor=4):
    """A wide, soft version of the mask, for edges that lie over another layer: the overlay fades
    into what is beneath it instead of ending in a visible cut."""
    from PIL import ImageFilter
    a = Image.fromarray(alpha_u8, 'L').resize((alpha_u8.shape[1] * factor, alpha_u8.shape[0] * factor), Image.BILINEAR)
    a = a.filter(ImageFilter.GaussianBlur(factor * 1.2))
    a = np.asarray(a).astype(np.float32) / 255
    return np.clip((a - 0.5) * 1.3 + 0.5, 0, 1)


def upscale_rgba(rgba_u8, mask_u8=None, under_u8=None):
    """RGBA uint8 (transparent texels already bled) -> 4x RGBA. `mask_u8` is the alpha to use
    (e.g. an overlay's own mask when the RGB is the overlay composited over its base); where
    `under_u8` (coverage of the layers beneath) is set, the edge cross-fades instead."""
    mask = rgba_u8[..., 3] if mask_u8 is None else mask_u8
    key = hashlib.sha1(PIPELINE.encode() + bytes(str(rgba_u8.shape), 'ascii') + rgba_u8.tobytes()
                       + mask.tobytes()).hexdigest()
    path = os.path.join(cache_dir(), 'results', key[:2], key + '.png')
    out = np.empty((rgba_u8.shape[0] * 4, rgba_u8.shape[1] * 4, 4), np.uint8)
    if os.path.exists(path):          # the cache holds the (expensive) colour; alpha is rebuilt
        out[..., :3] = np.asarray(Image.open(path).convert('RGB'))
    else:
        out[..., :3] = upscale_rgb(rgba_u8[..., :3])
        os.makedirs(os.path.dirname(path), exist_ok=True)
        Image.fromarray(out[..., :3], 'RGB').save(path)
    if mask.min() == 255:
        out[..., 3] = 255
    else:
        crisp = upscale_mask(mask).astype(np.float32) / 255
        if under_u8 is not None and under_u8.any():
            u = np.asarray(Image.fromarray(under_u8, 'L').resize((out.shape[1], out.shape[0]), Image.BILINEAR)).astype(np.float32) / 255
            crisp = crisp * (1 - u) + crossfade_mask(mask) * u
        out[..., 3] = (crisp * 255 + 0.5).astype(np.uint8)
    return out
