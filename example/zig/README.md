# zX12 Zig Example

This example shows how to use the zX12 library from Zig applications.

## Run this example
1. cd into this example

```bash
cd /example/zig
```

2. Run setup.sh or manually copy the referenced sample & schema

```bash
./setup.sh
```

3. Add the zX12 as a dependency (this will also generate a build.zig.zon)

```bash
zig fetch --save "git+https://github.com/LibrePPS/zX12#main"
```

4. Build and run

```
zig build run
```
