import os
import platform
import subprocess
from setuptools import setup, find_packages
from setuptools.command.build_py import build_py


class ZigBuilder(build_py):
    def run(self):
        # Get the directory of the setup.py script
        setup_dir = os.getenv("ZX12_PATH", os.getcwd())

        # Run zig build
        try:
            subprocess.check_call(
                [
                    "zig",
                    "build-lib",
                    "./src/main.zig",
                    "-lc",
                    "-OReleaseFast",
                    "-femit-bin=./zig-out/lib/libzx12.so",
                    "-dynamic",
                ],
                cwd=setup_dir,
            )
            subprocess.check_call(
                [
                    "zig",
                    "build-lib",
                    "./src/main.zig",
                    "-lc",
                    "-OReleaseFast",
                    "-femit-bin=./zig-out/lib/libzx12.dll",
                    "-dynamic",
                    "-target",
                    "x86_64-windows-gnu",
                ],
                cwd=setup_dir,
            )
            subprocess.check_call(
                [
                    "zig",
                    "build-lib",
                    "./src/main.zig",
                    "-lc",
                    "-OReleaseFast",
                    "-femit-bin=./zig-out/lib/libzx12.dylib",
                    "-dynamic",
                    "-target",
                    "x86_64-macos",
                ],
                cwd=setup_dir,
            )

            subprocess.check_call(
                [
                    "zig",
                    "build-lib",
                    "./src/main.zig",
                    "-lc",
                    "-OReleaseFast",
                    "-femit-bin=./zig-out/lib/libzx12_arm64.dylib",
                    "-dynamic",
                    "-target",
                    "aarch64-macos",
                ],
                cwd=setup_dir,
            )
        except subprocess.CalledProcessError as e:
            print(f"Error during zig build: {e}")
            raise

        # Copy the built library to the package directory
        lib_names = [
            "libzx12.so",
            "libzx12.dll",
            "libzx12.dylib",
            "libzx12_arm64.dylib",
        ]
        for lib_name in lib_names:
            lib_path = os.path.join(setup_dir, "zig-out", "lib", lib_name)
            target_path = os.path.join(setup_dir, "python", "zx12", lib_name)
            self.copy_file(lib_path, target_path)

        super().run()


setup(
    name="zx12",
    version="0.1.0",
    packages=find_packages(where="python"),
    package_dir={"": "python"},
    package_data={
        "zx12": ["libzx12.so", "libzx12.dll", "libzx12.dylib", "libzx12_arm64.dylib"],
    },
    cmdclass={
        "build_py": ZigBuilder,
    },
    zip_safe=False,
)
