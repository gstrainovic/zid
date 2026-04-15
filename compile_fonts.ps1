$files = Get-ChildItem -Recurse -Filter *.c -Path "libs/fancy-cat/deps/mupdf/generated/resources/fonts/urw"
foreach ($f in $files) {
    echo "Compiling $($f.FullName)"
    & zig cc -O2 -c -o "$($f.FullName).o" "$($f.FullName)"
}
$objects = Get-ChildItem -Recurse -Filter *.c.o -Path "libs/fancy-cat/deps/mupdf/generated/resources/fonts/urw"
foreach ($obj in $objects) {
    echo "Adding $($obj.Name) to libmupdf.a"
    & zig ar r "libs/fancy-cat/deps/mupdf/build/release/libmupdf.a" "$($obj.FullName)"
}
