import ctypes
import json
import platform
from importlib import resources


class ZX12Error(Exception):
    """Exception raised for zX12 errors"""

    pass


class Schema:
    """Wrapper for ZX12 schema handle"""

    def __init__(self, lib, schema_ptr):
        """
        Initialize schema wrapper

        Args:
            lib: Reference to zX12 library
            schema_ptr: Pointer to schema from zx12_load_schema
        """
        self.lib = lib
        self.schema_ptr = schema_ptr
        self._freed = False

    def __del__(self):
        """Free schema on destruction"""
        self.free()

    def __enter__(self):
        """Context manager support"""
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager cleanup"""
        self.free()

    def free(self):
        """Explicitly free the schema"""
        if not self._freed and self.schema_ptr:
            self.lib.zx12_free_schema(self.schema_ptr)
            self._freed = True
            self.schema_ptr = None


class ZX12:
    """Python wrapper for zX12 C library"""

    # Error codes (must match zx12.h)
    SUCCESS = 0
    OUT_OF_MEMORY = 1
    INVALID_ISA = 2
    FILE_NOT_FOUND = 3
    PARSE_ERROR = 4
    SCHEMA_LOAD_ERROR = 5
    UNKNOWN_HL_LEVEL = 6
    PATH_CONFLICT = 7
    INVALID_ARGUMENT = 8
    UNKNOWN_ERROR = 99

    def __init__(self, lib_path=None):
        """
        Initialize zX12 library

        Args:
            lib_path: Path to libzx12 shared library. If not provided, it will be loaded from the package.
        """
        if lib_path is None:
            lib_name = "libzx12.so"
            if platform.system() == "Windows":
                lib_name = "libzx12.dll"
            elif platform.system() == "Darwin":
                # check if arm64
                if platform.machine() == "arm64":
                    lib_name = "libzx12_arm64.dylib"
                else:
                    lib_name = "libzx12.dylib"

            # Use importlib.resources to find the library within the package
            with resources.path("zx12", lib_name) as path:
                lib_path = str(path)

        # Load shared library
        self.lib = ctypes.CDLL(lib_path)

        # Define return types and argument types
        self.lib.zx12_init.restype = ctypes.c_int
        self.lib.zx12_init.argtypes = []

        self.lib.zx12_deinit.restype = None
        self.lib.zx12_deinit.argtypes = []

        self.lib.zx12_process_document.restype = ctypes.c_int
        self.lib.zx12_process_document.argtypes = [
            ctypes.c_char_p,  # x12_file_path
            ctypes.c_char_p,  # schema_path
            ctypes.POINTER(ctypes.c_void_p),  # output_ptr
        ]

        self.lib.zx12_process_from_memory.restype = ctypes.c_int
        self.lib.zx12_process_from_memory.argtypes = [
            ctypes.POINTER(ctypes.c_ubyte),  # x12_data
            ctypes.c_size_t,  # x12_length
            ctypes.c_char_p,  # schema_path
            ctypes.POINTER(ctypes.c_void_p),  # output_ptr
        ]

        self.lib.zx12_get_output.restype = ctypes.c_char_p
        self.lib.zx12_get_output.argtypes = [ctypes.c_void_p]

        self.lib.zx12_get_output_length.restype = ctypes.c_size_t
        self.lib.zx12_get_output_length.argtypes = [ctypes.c_void_p]

        self.lib.zx12_free_output.restype = None
        self.lib.zx12_free_output.argtypes = [ctypes.c_void_p]

        self.lib.zx12_get_version.restype = ctypes.c_char_p
        self.lib.zx12_get_version.argtypes = []

        self.lib.zx12_get_error_message.restype = ctypes.c_char_p
        self.lib.zx12_get_error_message.argtypes = [ctypes.c_int]

        self.lib.zx12_load_schema.restype = ctypes.c_int
        self.lib.zx12_load_schema.argtypes = [
            ctypes.c_char_p,  # file_path
            ctypes.POINTER(ctypes.c_void_p),  # schema_ptr
        ]

        self.lib.zx12_free_schema.restype = None
        self.lib.zx12_free_schema.argtypes = [ctypes.c_void_p]

        self.lib.zx12_process_document_with_schema.restype = ctypes.c_int
        self.lib.zx12_process_document_with_schema.argtypes = [
            ctypes.c_char_p,  # x12_file_path
            ctypes.c_void_p,  # schema
            ctypes.POINTER(ctypes.c_void_p),  # output_ptr
        ]

        self.lib.zx12_process_from_memory_with_schema.restype = ctypes.c_int
        self.lib.zx12_process_from_memory_with_schema.argtypes = [
            ctypes.POINTER(ctypes.c_ubyte),  # x12_data
            ctypes.c_size_t,  # x12_length
            ctypes.c_void_p,  # schema
            ctypes.POINTER(ctypes.c_void_p),  # output_ptr
        ]

        # Initialize library
        result = self.lib.zx12_init()
        if result != self.SUCCESS:
            raise ZX12Error(f"Failed to initialize library: {self._get_error(result)}")

    def __del__(self):
        """Cleanup library on destruction"""
        if hasattr(self, "lib"):
            self.lib.zx12_deinit()

    def __enter__(self):
        """Context manager support"""
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager cleanup"""
        self.__del__()

    def _get_error(self, error_code):
        """Get error message for error code"""
        msg = self.lib.zx12_get_error_message(error_code)
        return msg.decode("utf-8") if msg else f"Unknown error {error_code}"

    def get_version(self):
        """Get library version string"""
        version = self.lib.zx12_get_version()
        return version.decode("utf-8")

    def load_schema(self, schema_path):
        """
        Load an X12 schema from file

        Args:
            schema_path: Path to schema JSON file

        Returns:
            Schema: Schema object that can be used with process_file_with_schema

        Raises:
            ZX12Error: If schema loading fails

        Example:
            with zx12.load_schema("schema/837p.json") as schema:
                result = zx12.process_file_with_schema("input.x12", schema)
        """
        schema_ptr = ctypes.c_void_p()

        result = self.lib.zx12_load_schema(
            schema_path.encode("utf-8"),
            ctypes.byref(schema_ptr),
        )

        if result != self.SUCCESS:
            raise ZX12Error(f"Failed to load schema: {self._get_error(result)}")

        return Schema(self.lib, schema_ptr)

    def process_file(self, x12_file_path, schema_path):
        """
        Process X12 file and return JSON

        Args:
            x12_file_path: Path to X12 file
            schema_path: Path to schema JSON file

        Returns:
            dict: Parsed JSON data

        Raises:
            ZX12Error: If processing fails
        """
        output = ctypes.c_void_p()

        result = self.lib.zx12_process_document(
            x12_file_path.encode("utf-8"),
            schema_path.encode("utf-8"),
            ctypes.byref(output),
        )

        if result != self.SUCCESS:
            raise ZX12Error(self._get_error(result))

        try:
            # Get JSON string
            json_str = self.lib.zx12_get_output(output)
            if not json_str:
                raise ZX12Error("Failed to get output")

            # Decode and parse JSON
            json_data = json_str.decode("utf-8")
            return json.loads(json_data)
        finally:
            # Always free output
            self.lib.zx12_free_output(output)

    def process_file_with_schema(self, x12_file_path, schema):
        """
        Process X12 file with pre-loaded schema and return JSON

        Args:
            x12_file_path: Path to X12 file
            schema: Schema object from load_schema()

        Returns:
            dict: Parsed JSON data

        Raises:
            ZX12Error: If processing fails

        Example:
            schema = zx12.load_schema("schema/837p.json")
            result1 = zx12.process_file_with_schema("input1.x12", schema)
            result2 = zx12.process_file_with_schema("input2.x12", schema)
            schema.free()
        """
        if schema._freed:
            raise ZX12Error("Schema has already been freed")

        output = ctypes.c_void_p()

        result = self.lib.zx12_process_document_with_schema(
            x12_file_path.encode("utf-8"),
            schema.schema_ptr,
            ctypes.byref(output),
        )

        if result != self.SUCCESS:
            raise ZX12Error(self._get_error(result))

        try:
            # Get JSON string
            json_str = self.lib.zx12_get_output(output)
            if not json_str:
                raise ZX12Error("Failed to get output")

            # Decode and parse JSON
            json_data = json_str.decode("utf-8")
            return json.loads(json_data)
        finally:
            # Always free output
            self.lib.zx12_free_output(output)

    def process_string_with_schema(self, x12_data, schema):
        """
        Process X12 data from string with pre-loaded schema and return JSON

        Args:
            x12_data: X12 data as string
            schema: Schema object from load_schema()

        Returns:
            dict: Parsed JSON data

        Raises:
            ZX12Error: If processing fails

        Example:
            schema = zx12.load_schema("schema/837p.json")
            result1 = zx12.process_string_with_schema(x12_data1, schema)
            result2 = zx12.process_string_with_schema(x12_data2, schema)
            schema.free()
        """
        if schema._freed:
            raise ZX12Error("Schema has already been freed")

        x12_bytes = x12_data.encode("utf-8")
        x12_array = (ctypes.c_ubyte * len(x12_bytes))(*x12_bytes)
        output = ctypes.c_void_p()

        result = self.lib.zx12_process_from_memory_with_schema(
            x12_array, len(x12_bytes), schema.schema_ptr, ctypes.byref(output)
        )

        if result != self.SUCCESS:
            raise ZX12Error(self._get_error(result))

        try:
            # Get JSON string
            json_str = self.lib.zx12_get_output(output)
            if not json_str:
                raise ZX12Error("Failed to get output")

            # Decode and parse JSON
            json_data = json_str.decode("utf-8")
            return json.loads(json_data)
        finally:
            # Always free output
            self.lib.zx12_free_output(output)

    def process_string(self, x12_data, schema_path):
        """
        Process X12 data from string and return JSON

        Args:
            x12_data: X12 data as string
            schema_path: Path to schema JSON file

        Returns:
            dict: Parsed JSON data

        Raises:
            ZX12Error: If processing fails
        """
        x12_bytes = x12_data.encode("utf-8")
        x12_array = (ctypes.c_ubyte * len(x12_bytes))(*x12_bytes)
        output = ctypes.c_void_p()

        result = self.lib.zx12_process_from_memory(
            x12_array, len(x12_bytes), schema_path.encode("utf-8"), ctypes.byref(output)
        )

        if result != self.SUCCESS:
            raise ZX12Error(self._get_error(result))

        try:
            # Get JSON string
            json_str = self.lib.zx12_get_output(output)
            if not json_str:
                raise ZX12Error("Failed to get output")

            # Decode and parse JSON
            json_data = json_str.decode("utf-8")
            return json.loads(json_data)
        finally:
            # Always free output
            self.lib.zx12_free_output(output)
