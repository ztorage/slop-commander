"""GIF-style LZW (LSB-first, 9..12-bit codes, 256=clear, 257=end) used by RealSpace TXMP 'LZ'."""
def decode(buf, expected=None):
    out = bytearray()
    bitpos, nbits = 0, 9
    dict_ = [bytes([i]) for i in range(256)] + [b'', b'']
    prev = None
    total = len(buf) * 8
    while bitpos + nbits <= total:
        v = int.from_bytes(buf[bitpos >> 3:(bitpos >> 3) + 3], 'little')
        code = (v >> (bitpos & 7)) & ((1 << nbits) - 1)
        bitpos += nbits
        if code == 256:
            dict_ = dict_[:258]; nbits = 9; prev = None; continue
        if code == 257:
            break
        if prev is None:
            entry = dict_[code]
        elif code < len(dict_):
            entry = dict_[code]
            dict_.append(prev + entry[:1])
        else:
            entry = prev + prev[:1]
            dict_.append(entry)
        out += entry
        prev = entry
        if len(dict_) >= (1 << nbits) and nbits < 12:
            nbits += 1
        if expected and len(out) >= expected:
            break
    return bytes(out)
