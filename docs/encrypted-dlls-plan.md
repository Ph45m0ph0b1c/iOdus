# Plan: games with encrypted DLLs

Status: investigation done, nothing built.

## The problem

Some packages keep PE files (`.exe` and `.dll`) encrypted on disk. The backend
(`xodus-cli run`) decrypts them when the game starts:

- `--materialize-chain` writes real decrypted files only for the `.exe` images
  and the entry image (`launch_file_maps` in `crates/xodus-cli/src/commands/run.rs`).
- For the other encrypted files, the backend gives Wine a map from the NT path
  to an open file descriptor with the decrypted bytes: `WINE_DLL_FILE_MAP` and
  `WINE_EXE_FILE_MAP`. On macOS, the decrypted bytes are on a RAM disk
  (`hdiutil attach ram://`, HFS, `nobrowse`).
- The Xodus Wine reads these maps in its own `ntdll`
  (`dlls/ntdll/unix/loader.c: open_mapped_dll_file`, and `get_mapped_exe_file`
  with named server handles from `wine-memfd-filename.patch`).

GPTK Wine 7.7 has a prebuilt `ntdll` and `wineserver` that do not read these
maps. So Wine loads the encrypted bytes of the DLL, and the game fails.

## Option A: a custom Wine (not recommended)

Build Wine from the CrossOver 22 source (the base of GPTK 3.0 Wine 7.7), port
the file-map patches from Wine 11 to the 7.7 `ntdll` and `wineserver`, and add
D3DMetal from GPTK. This is a large task: the patches touch the unix loader and
the server protocol of a much older Wine, the build is long, and iOdus must
then ship its own Wine and keep it current.

## Option B: decrypted files in the launch view (recommended)

No Wine change. The backend already makes a launch view on the RAM disk for
`--materialize-chain`. Extend it:

1. Add `--materialize-all` to `xodus-cli run` (iodus-xodus repo). With it,
   `launch_file_maps` treats every encrypted PE file as a real image: it writes
   the decrypted bytes to the same relative path in the launch view on the RAM
   disk, as it does now for `.exe` files.
2. The file maps then have no entries for those files. Wine loads plain files.
3. iOdus passes `--materialize-all` in place of `--materialize-chain`.
4. Size: the RAM disk must hold all encrypted PE files of the package. The
   backend already sizes it from `keep_encrypted` segments; check the size of
   large games and show an error if the Mac does not have enough memory.
5. The decrypted files exist only on the RAM disk while the game runs. The
   backend unmounts and detaches it at the end (existing cleanup).

## Tests

- Unit tests in the backend: `launch_file_maps` with `materialize_all` has no
  DLL mappings; the launch view has a file for each encrypted entry.
- A live test needs a game with encrypted DLLs that the user owns. The user
  starts it from iOdus (a normal game start). "Forza Horizon 6" is installed;
  check first if it uses anti-cheat, because anti-cheat can block Wine.
