import ctypes
import json
import datetime

class ZX12:
    def __init__(self, lib_path='./libzx12.so'):
        self.lib = ctypes.CDLL(lib_path)
        
        # Set up function prototypes
        self.lib.zx12_create_context.restype = ctypes.c_void_p
        
        self.lib.zx12_destroy_context.argtypes = [ctypes.c_void_p]
        
        self.lib.zx12_load_schema.argtypes = [
            ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, 
            ctypes.c_char_p, ctypes.c_size_t
        ]
        self.lib.zx12_load_schema.restype = ctypes.c_int
        
        self.lib.zx12_parse_x12.argtypes = [
            ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t,
            ctypes.c_char_p, ctypes.c_size_t, 
            ctypes.POINTER(ctypes.c_size_t), ctypes.POINTER(ctypes.c_size_t)
        ]
        self.lib.zx12_parse_x12.restype = ctypes.c_int
        
        self.lib.zx12_get_buffer_data.argtypes = [
            ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t
        ]
        self.lib.zx12_get_buffer_data.restype = ctypes.c_int
        
        self.lib.zx12_free_buffer.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        self.lib.zx12_free_buffer.restype = ctypes.c_int
        
        self.lib.zx12_get_error_message.argtypes = [ctypes.c_int]
        self.lib.zx12_get_error_message.restype = ctypes.c_char_p
        
        # Create context
        self.ctx = self.lib.zx12_create_context()
        if not self.ctx:
            raise Exception("Failed to create ZX12 context")
    
    def __del__(self):
        if hasattr(self, 'ctx') and self.ctx:
            self.lib.zx12_destroy_context(self.ctx)
    
    def load_schema(self, path, name):
        path_bytes = path.encode('utf-8')
        name_bytes = name.encode('utf-8')
        result = self.lib.zx12_load_schema(
            self.ctx, 
            path_bytes, len(path_bytes),
            name_bytes, len(name_bytes)
        )
        if result != 0:
            error_msg = self.lib.zx12_get_error_message(result).decode('utf-8')
            raise Exception(f"Failed to load schema: {error_msg}")
        return True
    
    def parse_x12(self, schema_name, x12_data):
        schema_bytes = schema_name.encode('utf-8')
        x12_bytes = x12_data.encode('utf-8')
        buffer_id = ctypes.c_size_t()
        buffer_len = ctypes.c_size_t()
        
        result = self.lib.zx12_parse_x12(
            self.ctx,
            schema_bytes, len(schema_bytes),
            x12_bytes, len(x12_bytes),
            ctypes.byref(buffer_id), ctypes.byref(buffer_len)
        )
        if result != 0:
            error_msg = self.lib.zx12_get_error_message(result).decode('utf-8')
            raise Exception(f"Failed to parse X12 data: {error_msg}")
        
        # Get parsed data
        output_buffer = ctypes.create_string_buffer(buffer_len.value)
        result = self.lib.zx12_get_buffer_data(
            self.ctx, 
            buffer_id.value, 
            output_buffer, 
            buffer_len.value
        )
        if result != 0:
            error_msg = self.lib.zx12_get_error_message(result).decode('utf-8')
            raise Exception(f"Failed to get buffer data: {error_msg}")
        
        # Free the buffer
        self.lib.zx12_free_buffer(self.ctx, buffer_id.value)
        
        # Return parsed JSON
        return output_buffer.raw[:buffer_len.value].decode('utf-8')

#837P
x12_data = open("../../samples/837p_example.x12","r").read()
schema_path = "/home/jjw07006/Deveolpment/zX12/schema/837p.json" #Change this to your schema path
schema_name = "837p"

with open("./837p.json", "w+") as f:
    zx12 = ZX12()
    zx12.load_schema(schema_path, schema_name)
    parsed_data = zx12.parse_x12(schema_name, x12_data)
    f.write(json.dumps(json.loads(parsed_data), indent=2))






