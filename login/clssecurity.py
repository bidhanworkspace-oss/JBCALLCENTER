import hashlib, binascii, os
import base64
from Cryptodome.Cipher import AES
from Cryptodome import Random
from django.conf import settings

class clsSecurity:

  @staticmethod
  def encodepassstring(strpwd):
    
    salt = hashlib.sha256(os.urandom(60)).hexdigest().encode('ascii')
    pwdhash = hashlib.pbkdf2_hmac('sha512', strpwd.encode('utf-8'), 
                        salt, 100000)
    pwdhash = binascii.hexlify(pwdhash)
    encodepwd = (salt + pwdhash).decode('ascii')
    return encodepwd

  @staticmethod
  def verifypassstring(storedpassword,providedpassword):
    salt = storedpassword[:64]
    storedpassword = storedpassword[64:]
    pwdhash = hashlib.pbkdf2_hmac('sha512', 
                                providedpassword.encode('utf-8'), 
                                salt.encode('ascii'), 
                                100000)
    pwdhash = binascii.hexlify(pwdhash).decode('ascii')

    return pwdhash == storedpassword

  @staticmethod
  def encrypturlvalue(inputstring):
      key = settings.URL_ENCRYPT_KEY
      block_size = 16
      iv = Random.new().read(block_size)
      cipher = AES.new(key, AES.MODE_CFB, iv)
      msg = iv + cipher.encrypt(inputstring.encode())
      return msg.hex()

  @staticmethod
  def decrypturlvalue(encrytedstring):
      key = settings.URL_ENCRYPT_KEY
      block_size = 16
      iv = Random.new().read(block_size)
      cipher = AES.new(key, AES.MODE_CFB, iv)
      rec = cipher.decrypt(bytes.fromhex(encrytedstring))[len(iv):]
      return rec.decode()


  @staticmethod
  def pwdvalidator(pwd):

    ispwdvalid=False
    uppercnt=0
    lowercnt=0
    digitcnt=0
    specialcnt=0

    if len(pwd)>=8:

            for char in pwd:
              if char.isupper():
                 uppercnt = uppercnt + 1
              elif char.islower():
                 lowercnt = lowercnt + 1        
              elif not char.isdigit() and not char.isalpha():
                 specialcnt = specialcnt + 1
              elif char.isdigit():
                 digitcnt = digitcnt + 1
              else:
                ispwdvalid=False


            if uppercnt>0 and lowercnt>0 and digitcnt>0 and specialcnt>0 :
                ispwdvalid=True
            else:
                ispwdvalid=False

    if len(pwd)<8:
     ispwdvalid=False

    return ispwdvalid

  @staticmethod
  def encodestr(inputstring):
      
      encrypted_string = base64.b64encode(inputstring.encode("utf-8")).decode("ascii")
      return encrypted_string
  
  @staticmethod
  def decodestr(encrytedstring):
      decrypted_string = base64.b64decode(encrytedstring).decode("ascii")
      return decrypted_string

  @staticmethod
  def encodestr85(inputstring):
      encrypted_string = base64.b85encode(inputstring).decode("ascii")
      return encrypted_string

  @staticmethod
  def decodestr85(encrytedstring):
      decrypted_string = base64.b85decode(encrytedstring).decode("ascii")
      return decrypted_string


  @staticmethod
  def encryptejanatavalue(key,inputstring):
      key = str(key).encode('utf-8')
      block_size = 16
      iv = Random.new().read(block_size)
      cipher = AES.new(key, AES.MODE_CFB, iv)
      msg = iv + cipher.encrypt(inputstring.encode())
      return msg.hex()

  @staticmethod
  def decryptejanatavalue(key,encrytedstring):
      key = str(key).encode('utf-8')
      block_size = 16
      iv = Random.new().read(block_size)
      cipher = AES.new(key, AES.MODE_CFB, iv)
      rec = cipher.decrypt(bytes.fromhex(encrytedstring))[len(iv):]
      return rec.decode()

  @staticmethod
  def checknid(ejanatanid,nationalididdoc,nationalidassociate,nationalidconvertedfromcbs):
    checknidvalue= False
    if ejanatanid == nationalididdoc or ejanatanid == nationalidassociate or ejanatanid == nationalidconvertedfromcbs : 
        checknidvalue = True
    else:
        checknidvalue = False

    if checknidvalue == False and len(ejanatanid) == 13 and len(nationalididdoc) == 17 :
        if ejanatanid == nationalididdoc[-13:] :
            checknidvalue = True

    return checknidvalue