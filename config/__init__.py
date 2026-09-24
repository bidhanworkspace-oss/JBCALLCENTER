import sys
import oracledb

oracledb.version = "8.3.0"
oracledb.is_thin = True
sys.modules["cx_Oracle"] = oracledb