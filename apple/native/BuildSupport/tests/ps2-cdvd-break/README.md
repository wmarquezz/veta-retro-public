CDVDFSV regression (Mac component, no phone or game needed)

run.py takes --source (source under test), --base-source (source from which the existing Mac reference build was made), --build (reference CMake build with play-gl-interactive), and --out (new disposable directory). It compiles real Iop_Cdvdfsv.cpp and IopBios.cpp, then links against the existing core dependencies. The source and baseline must have matching revision/ABI. It neither edits them nor accesses a device or ROM.

Twenty checks call registered SIF RPC modules through a fake SIF transport, with a real initialized PS2 VM/CDVDMAN. They verify default error 0, CdBreak ABRT=1, non-consuming error reads, status/DiskReady preservation, seek/read/init clearing, one completion when aborting an asynchronous read, subsequent successful read, stream abort/start behavior, new ZIP save/load and old ZIP lacking LastError. The test uses a mailbox initialization barrier before accessing VM state. No guest or production save is modified.

Expected fixed result: exit 0, 20 PASS, 0 FAIL. Pinned baseline: exit 1, 11 PASS, 9 FAIL. Gameplay, rendering, sound and full commercial compatibility require separate validation. This test specifically covers HLE RPC semantics; the unmodified CCdvdman direct IOP interface is outside its scope.
