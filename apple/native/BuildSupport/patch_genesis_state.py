"""Restore derived interlace state from the existing Genesis Plus GX snapshot.

The pinned core resets the system before loading; field parity is already in
the saved VDP status, but the original loader discards it on its next frame.
No serialized fields, layout or state version are changed.
"""
from pathlib import Path


def patch_genesis_state(source: Path):
    path = source / "core/vdp_ctrl.c"
    data = path.read_bytes()
    newline = b"\r\n" if b"\r\n" in data else b"\n"
    text = data.decode().replace("\r\n", "\n")
    marker = "/* VETA: reconstruct saved interlace mode and field parity. */"
    if marker in text:
        return
    anchor = """    /* reinitialize rendering functions */
    update_bg_pattern_cache = update_bg_pattern_cache_m5;
    parse_satb = parse_satb_m5;
    render_bg = (reg[11] & 0x04) ? (config.enhanced_vscroll ? render_bg_m5_vs_enhanced : render_bg_m5_vs) : render_bg_m5;
    render_obj = (reg[12] & 0x08) ? render_obj_m5_ste : render_obj_m5;
"""
    replacement = """    /* VETA: reconstruct saved interlace mode and field parity. */
    interlaced = (reg[12] & 0x02) >> 1;
    im2_flag = ((reg[12] & 0x06) == 0x06);
    odd_frame = interlaced ? ((status >> 4) & 1) : 0;
    bitmap.viewport.changed |= 1;

    /* reinitialize rendering functions */
    update_bg_pattern_cache = update_bg_pattern_cache_m5;
    parse_satb = im2_flag ? parse_satb_m5_im2 : parse_satb_m5;
    render_bg = im2_flag ? ((reg[11] & 0x04) ? render_bg_m5_im2_vs : render_bg_m5_im2)
                        : ((reg[11] & 0x04) ? (config.enhanced_vscroll ? render_bg_m5_vs_enhanced : render_bg_m5_vs) : render_bg_m5);
    render_obj = im2_flag ? ((reg[12] & 0x08) ? render_obj_m5_im2_ste : render_obj_m5_im2)
                         : ((reg[12] & 0x08) ? render_obj_m5_ste : render_obj_m5);
"""
    if text.count(anchor) != 1:
        raise RuntimeError("Pinned Genesis VDP loader changed; review the state patch")
    path.write_bytes(text.replace(anchor, replacement).encode().replace(b"\n", newline))


if __name__ == "__main__":
    import sys
    patch_genesis_state(Path(sys.argv[1]))
