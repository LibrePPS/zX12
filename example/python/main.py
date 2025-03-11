import ctypes
import json
import datetime as dt

lib = ctypes.CDLL('./libzx12.so')
lib.parse837.restype = ctypes.c_void_p
lib.parse837.argtypes = [ctypes.c_void_p, ctypes.c_int]

lib.getBufferSz.restype = ctypes.c_int
lib.getBufferSz.argtypes = [ctypes.c_void_p]

lib.free837.restype = None
lib.free837.argtypes = [ctypes.c_void_p]

def parse837(data:str) -> str:
    data_len = len(data)
    out_json = lib.parse837(data.replace("\n","").encode('utf-8'), data_len)
    #Get the size of the output buffer
    out_len = lib.getBufferSz(out_json)
    #Create a buffer to store the output message
    output_message_str = ctypes.create_string_buffer(out_len)
    #Copy the output message from the shared library to the buffer
    ctypes.memmove(output_message_str, out_json, out_len)
    #Free the memory allocated by the shared library
    lib.free837(out_json)
    return output_message_str.raw

if __name__ == '__main__':
    x12_data = """ISA*00*          *00*          *ZZ*SENDER         *ZZ*RECEIVER       *230101*1200*^*00501*000000001*0*P*:~
GS*HC*SENDER*RECEIVER*20230101*1200*1*X*005010X223A2~
ST*837*0001*005010X223A2~
BHT*0019*00*123*20230101*1200*CH~
NM1*41*2*HOSPITAL INC*****46*123456789~
PER*IC*CONTACT*TE*5551234~
NM1*40*2*INSURANCE CO*****46*987654321~
HL*1**20*1~
NM1*85*2*GENERAL HOSPITAL*****XX*1234567890~
N3*555 HOSPITAL DRIVE~
N4*SOMECITY*CA*90001~
REF*EI*987654321~
HL*2*1*22*1~
SBR*P*18*******MB~
NM1*IL*1*PATIENT*JOHN****MI*123456789A~
N3*123 PATIENT ST~
N4*SOMECITY*CA*90001~
DMG*D8*19500501*M~
CLM*4567832*25000.00***11:B:1*Y*A*Y*Y*A::1*Y*::3~
DTP*434*RD8*20221201-20221210~
HI*ABK:I269*ABF:I4891*ABF:E119*ABF:Z9911~
HI*BE:01:::450.00*BE:02:::600.00*BE:30:::120.00~
HI*BH:A1:D8:20221201*BH:A2:D8:20221130*BH:45:D8:20221201~
HI*BI:70:D8:20221125-20221130*BI:71:D8:20221101-20221110~
LX*1~
SV2*0120*HC:99231*15000.00*UN*10***1~
DTP*472*D8*20221201~
LX*2~
SV2*0270*HC:85025*500.00*UN*5***2~
DTP*472*D8*20221202~
LX*3~
SV2*0450*HC:99291*9500.00*UN*1***3~
DTP*472*D8*20221205~
SE*31*0001~
GE*1*1~
IEA*1*000000001~
"""

    x12_json = json.loads(parse837(x12_data))
    print(json.dumps(x12_json, indent=4))

    