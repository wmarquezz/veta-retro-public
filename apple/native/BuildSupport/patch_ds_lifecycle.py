"""Allow the pinned DeSmuME core to reinitialize after closing a game."""
from pathlib import Path


def apply(source: Path):
    for slot in (1, 2):
        path = source / f"desmume/src/slot{slot}.cpp"
        text = path.read_text()
        marker = f"static bool slot{slot}_initialized = false;"
        if marker in text:
            continue
        old = "static bool initialized = false;\n\tif(initialized) return;\n\tinitialized = true;"
        if text.count(old) != 1:
            raise ValueError(f"Unexpected slot{slot} initialization in pinned source")
        text = text.replace(f"void slot{slot}_Init()\n{{", marker + f"\n\nvoid slot{slot}_Init()\n{{")
        text = text.replace(old, f"if(slot{slot}_initialized) return;\n\tslot{slot}_initialized = true;")
        if slot == 1:
            text = text.replace("delete slot1_List[i];", "delete slot1_List[i];\n\t\tslot1_List[i] = NULL;")
        old = f"void slot{slot}_Shutdown()\n{{"
        if text.count(old) != 1:
            raise ValueError(f"Unexpected slot{slot} shutdown in pinned source")
        text = text.replace(old, old + f"\n\t// VETA: a later game may initialize this same core image again.\n\tslot{slot}_device = NULL;\n\tslot{slot}_selected_type = NDS_SLOT{slot}_NONE;\n\tslot{slot}_initialized = false;")
        path.write_text(text)

    path = source / "desmume/src/render3D.cpp"
    text = path.read_text()
    marker = "// VETA: do not retain the renderer deleted during shutdown."
    if marker not in text:
        old = "void Render3D_DeInit()\n{\n\tgpu3D->NDS_3D_Close();\n\tdelete BaseRenderer;\n\tBaseRenderer = NULL;\n}"
        if text.count(old) != 1:
            raise ValueError("Unexpected renderer shutdown in pinned source")
        new = old[:-1] + "\t" + marker + "\n\tCurrentRenderer = NULL;\n\tgpu3D = &gpu3DNull;\n\tcur3DCore = RENDERID_NULL;\n}"
        path.write_text(text.replace(old, new))


if __name__ == "__main__":
    import sys
    apply(Path(sys.argv[1]))
