import ctypes
import json
import datetime as dt

lib = ctypes.CDLL('./libzx12.so')

lib.loadSchema.restype = ctypes.c_int
lib.argtypes = [ctypes.c_char_p, ctypes.c_char_p]

lib.parseFromSchema.restype = ctypes.c_void_p
lib.parseFromSchema.argtypes = [ctypes.c_void_p, ctypes.c_void_p]

lib.freeSchema.restype = ctypes.c_int
lib.freeSchema.argtypes = [ctypes.c_void_p]

lib.freeBuffer.restype = ctypes.c_int
lib.freeBuffer.argtypes = [ctypes.c_void_p]

lib.getBufferSize.restype = ctypes.c_int
lib.getBufferSize.argtypes = [ctypes.c_void_p]


def loadSchema(schema:str, name:str) -> int:
    return lib.loadSchema(schema.encode('utf-8'), name.encode('utf-8'))

def freeSchema(schema_name:str) -> int:
    return lib.freeSchema(schema_name.encode('utf-8'))

def parseFromSchema(schema_name:str, x12_data:str) -> str:
    out_ptr = lib.parseFromSchema(schema_name.encode('utf-8'), x12_data.encode('utf-8'))
    out_len = lib.getBufferSize(out_ptr)
    output_message_str = ctypes.create_string_buffer(out_len)
    ctypes.memmove(output_message_str, out_ptr, out_len)
    lib.freeBuffer(out_ptr)
    return output_message_str.raw

if __name__ == '__main__':
    x12_data = open("../../samples/readme_sample.x12","r").read()
    schema_path = "/Absoulte/path/to/schema/schema/837p.json" #Change this to your schema path
    schema_name = "837p"
    # Load schema
    load = loadSchema(schema_path, schema_name)
    if load != 0:
        print("Error loading schema")
        exit(1)
    # Parse
    out = parseFromSchema(schema_name, x12_data)
    # pretty print the json
    print(json.dumps(json.loads(out), indent=4))
    # Free schema
    freeSchema(schema_name)
